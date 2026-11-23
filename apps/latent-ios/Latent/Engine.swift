import CoreGraphics
import Foundation

/// An error the engine reported, in its own words.
struct EngineError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

/// A rendered photo and its red, green and blue histograms (256 bins each).
struct Rendered: @unchecked Sendable {
    let image: CGImage
    let histogram: [UInt32]
    /// Above 1 for an HDR render: how much brighter than SDR white its highlights may be.
    var peak: Float = 1
}

/// How a mask overlay is drawn: the engine's view, a colour (0xRRGGBB) and opacity (0…100).
struct MaskLook: Equatable, Sendable {
    var view = "color"
    var rgb: UInt32 = 0xEB4040
    var opacity = 50
}

/// The LightCraft engine, through the C bridge. Every edit is an engine command, the same commands
/// the desktop app and the command line use. Safe to call from any thread (the engine locks).
final class Engine: @unchecked Sendable {
    static let shared = Engine()

    private let core: OpaquePointer
    /// Why the library couldn't be opened, if it couldn't (an empty one is used instead).
    let problem: String?

    private init() {
        var problemText: UnsafeMutablePointer<CChar>? = nil
        core = latent_open(nil, &problemText)
        if let p = problemText {
            problem = String(cString: p)
            latent_string_free(p)
        } else {
            problem = nil
        }
        latent_set_ai_model_dir(core, Self.aiModelFolder.path)
    }

    /// Where the SAM 3 model files go: Documents/Models/SAM3, which the Files app shows as
    /// On My iPhone › Latent › Models › SAM3.
    static var aiModelFolder: URL {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let dir = docs.appendingPathComponent("Models/SAM3", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Take in finished background work: whether a mask changed, messages for the user, and
    /// whether more is coming.
    func poll() -> (changed: Bool, messages: [String], busy: Bool) {
        guard let out = latent_poll(core) else { return (false, [], false) }
        defer { latent_string_free(out) }
        let d = (try? JSONSerialization.jsonObject(with: Data(String(cString: out).utf8))) as? [String: Any] ?? [:]
        return (d["changed"] as? Bool ?? false, d["messages"] as? [String] ?? [], d["busy"] as? Bool ?? false)
    }

    /// Run an engine command and return its result (a JSON value as Foundation objects).
    @discardableResult
    func run(_ command: String, _ params: [String: Any] = [:]) throws -> Any {
        let data = try JSONSerialization.data(withJSONObject: params)
        let json = String(data: data, encoding: .utf8) ?? "{}"
        guard let out = latent_execute(core, command, json) else {
            throw EngineError(message: "\(command): the engine gave no answer")
        }
        defer { latent_string_free(out) }
        let answer = try JSONSerialization.jsonObject(with: Data(String(cString: out).utf8), options: [.fragmentsAllowed])
        guard let dict = answer as? [String: Any] else {
            throw EngineError(message: "\(command): the engine's answer could not be read")
        }
        if let error = dict["error"] as? String {
            throw EngineError(message: error)
        }
        return dict["ok"] ?? NSNull()
    }

    /// The photo with its edits (or, with `original`, without them), fitted inside `size` pixels.
    func render(_ id: UInt64, fitting size: CGSize, original: Bool = false) -> Rendered? {
        let w = UInt32(max(1, size.width.rounded()))
        let h = UInt32(max(1, size.height.rounded()))
        guard let img = latent_render(core, id, w, h, original) else { return nil }
        defer { latent_image_free(img) }
        return Self.convert(img.pointee)
    }

    /// The photo's HDR render (half-float, linear, highlights above SDR white), or nil when HDR is
    /// off for it or the engine has none.
    func renderHDR(_ id: UInt64, fitting size: CGSize) -> Rendered? {
        let w = UInt32(max(1, size.width.rounded()))
        let h = UInt32(max(1, size.height.rounded()))
        guard let img = latent_render_hdr(core, id, w, h) else { return nil }
        defer { latent_hdr_image_free(img) }
        let i = img.pointee
        let width = Int(i.width)
        let height = Int(i.height)
        guard width > 0, height > 0, let px = i.rgba16f, i.rgba16f_len >= width * height * 4 else { return nil }
        let data = Data(bytes: px, count: width * height * 8)
        let space = CGColorSpace(name: CGColorSpace.extendedLinearSRGB) ?? CGColorSpaceCreateDeviceRGB()
        let info = CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.floatComponents.rawValue | CGImageByteOrderInfo.order16Little.rawValue)
        guard let provider = CGDataProvider(data: data as CFData),
              let cg = CGImage(
                  width: width, height: height, bitsPerComponent: 16, bitsPerPixel: 64, bytesPerRow: width * 8, space: space,
                  bitmapInfo: info, provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
        else { return nil }
        var hist: [UInt32] = []
        if let bins = i.hist, i.hist_len > 0 { hist = Array(UnsafeBufferPointer(start: bins, count: i.hist_len)) }
        return Rendered(image: cg, histogram: hist, peak: i.peak)
    }

    /// The photo with a mask tinted red over it, for drawing masks.
    func renderMask(_ id: UInt64, mask: UInt32, fitting size: CGSize, look: MaskLook = MaskLook()) -> Rendered? {
        let w = UInt32(max(1, size.width.rounded()))
        let h = UInt32(max(1, size.height.rounded()))
        guard let img = latent_render_mask_as(core, id, w, h, mask, look.view, look.rgb, UInt8(clamping: look.opacity)) else { return nil }
        defer { latent_image_free(img) }
        return Self.convert(img.pointee)
    }

    /// Give a photo its depth map (nil takes it away).
    func setDepth(_ id: UInt64, _ m: DepthMap?) {
        guard let m else {
            latent_set_depth(core, id, 0, 0, nil, 0)
            return
        }
        m.data.withUnsafeBufferPointer { b in
            latent_set_depth(core, id, UInt32(m.width), UInt32(m.height), b.baseAddress, b.count)
        }
    }

    /// The depth map as the photo is framed: near white, far black.
    func renderDepth(_ id: UInt64, fitting size: CGSize) -> CGImage? {
        let w = UInt32(max(1, size.width.rounded()))
        let h = UInt32(max(1, size.height.rounded()))
        guard let img = latent_render_depth(core, id, w, h) else { return nil }
        defer { latent_image_free(img) }
        return Self.convert(img.pointee)?.image
    }

    /// The whole photo, not cropped or straightened: what the crop box is drawn over.
    func renderUncropped(_ id: UInt64, fitting size: CGSize) -> Rendered? {
        let w = UInt32(max(1, size.width.rounded()))
        let h = UInt32(max(1, size.height.rounded()))
        guard let img = latent_render_uncropped(core, id, w, h) else { return nil }
        defer { latent_image_free(img) }
        return Self.convert(img.pointee)
    }

    /// A preview of a creative profile (built in, or an imported LUT) on the photo (not changed).
    func profileThumbnail(_ id: UInt64, profile: String, longEdge: Int) -> CGImage? {
        guard let img = latent_profile_thumb(core, id, profile, UInt32(max(16, longEdge))) else { return nil }
        defer { latent_image_free(img) }
        return Self.convert(img.pointee)?.image
    }

    /// A preview of a preset on the photo (the photo is not changed).
    func presetThumbnail(_ id: UInt64, preset: String, longEdge: Int) -> CGImage? {
        guard let img = latent_preset_thumb(core, id, preset, UInt32(max(16, longEdge))) else { return nil }
        defer { latent_image_free(img) }
        return Self.convert(img.pointee)?.image
    }

    /// A thumbnail with the photo's edits.
    func thumbnail(_ id: UInt64, longEdge: Int) -> CGImage? {
        guard let img = latent_thumb(core, id, UInt32(max(16, longEdge))) else { return nil }
        defer { latent_image_free(img) }
        return Self.convert(img.pointee)?.image
    }

    /// Export a photo with its edits. `options` are the engine's export options (format, quality,
    /// resize, hdr, metadata, removeLocation, watermark, colorSpace…). Slow: call off the main thread.
    func export(_ id: UInt64, options: [String: Any]) throws -> (name: String, data: Data) {
        let json = String(data: try JSONSerialization.data(withJSONObject: options), encoding: .utf8) ?? "{}"
        var problem: UnsafeMutablePointer<CChar>? = nil
        guard let out = latent_export(core, id, json, &problem) else {
            let message = problem.map { String(cString: $0) } ?? "The photo couldn't be exported."
            if let problem { latent_string_free(problem) }
            throw EngineError(message: message)
        }
        defer { latent_export_free(out) }
        let name = out.pointee.name.map { String(cString: $0) } ?? "Photo"
        let data = out.pointee.bytes.map { Data(bytes: $0, count: out.pointee.len) } ?? Data()
        return (name, data)
    }

    private static func convert(_ img: LatentImage) -> Rendered? {
        let w = Int(img.width)
        let h = Int(img.height)
        guard w > 0, h > 0, let pixels = img.rgba, img.rgba_len >= w * h * 4 else { return nil }
        let data = Data(bytes: pixels, count: w * h * 4)
        let space = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        guard let provider = CGDataProvider(data: data as CFData),
              let cg = CGImage(
                  width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: w * 4, space: space,
                  bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                  provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
        else { return nil }
        var hist: [UInt32] = []
        if let bins = img.hist, img.hist_len > 0 {
            hist = Array(UnsafeBufferPointer(start: bins, count: img.hist_len))
        }
        return Rendered(image: cg, histogram: hist)
    }
}
