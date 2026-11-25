import AVFoundation
import CoreML
import CoreVideo
import ImageIO
import SwiftUI
import UIKit

/// A photo's depth map: one byte a pixel, 0 nearest … 255 farthest, over the photo as the camera
/// stood it (before the user's own rotation), with a histogram for the Focus Range bar.
struct DepthMap: Sendable {
    let width: Int
    let height: Int
    let data: [UInt8]
    /// "camera" (the iPhone recorded it) or "estimated" (the depth model made it).
    let source: String

    /// 64 bins from near to far, each 0…1 of the fullest.
    var histogram: [Double] {
        var bins = [Int](repeating: 0, count: 64)
        for v in data { bins[Int(v) >> 2] += 1 }
        let top = Double(bins.max() ?? 1)
        return bins.map { top > 0 ? Double($0) / top : 0 }
    }

    /// The depth (0 near … 1 far) at a point of the map (0…1 across and down), averaged a little.
    func depth(at p: CGPoint) -> Double? {
        guard width > 0, height > 0, p.x.isFinite, p.y.isFinite else { return nil }
        let cx = Int((p.x * CGFloat(width)).rounded(.down)), cy = Int((p.y * CGFloat(height)).rounded(.down))
        var sum = 0, n = 0
        for y in Swift.max(cy - 2, 0)...Swift.min(cy + 2, height - 1) {
            for x in Swift.max(cx - 2, 0)...Swift.min(cx + 2, width - 1) {
                sum += Int(data[y * width + x])
                n += 1
            }
        }
        return n > 0 ? Double(sum) / Double(n) / 255 : nil
    }

    /// From raw values where bigger means nearer (disparity, or the model's relative depth): the
    /// 2nd and 98th percentiles span near to far, so a few outliers don't flatten the rest.
    init?(nearness values: [Float], width: Int, height: Int, source: String) {
        guard width > 0, height > 0, values.count == width * height else { return nil }
        let finite = values.filter(\.isFinite).sorted()
        guard finite.count > 16 else { return nil }
        let lo = finite[finite.count / 50], hi = finite[finite.count - 1 - finite.count / 50]
        let span = Swift.max(hi - lo, 1e-6)
        data = values.map { v in
            guard v.isFinite else { return 255 }
            let near = Swift.min(Swift.max((v - lo) / span, 0), 1)
            return UInt8(((1 - near) * 255).rounded())
        }
        self.width = width
        self.height = height
        self.source = source
    }

    init(width: Int, height: Int, data: [UInt8], source: String) {
        self.width = width
        self.height = height
        self.data = data
        self.source = source
    }
}

enum DepthMaps {
    /// Where depth maps are kept: Application Support/Depth, one file per photo.
    static var folder: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = base.appendingPathComponent("Depth", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private static func file(_ id: UInt64) -> URL { folder.appendingPathComponent("\(id).depth") }

    /// A depth map made before (file: width and height as 4-byte little-endian, a source byte, the bytes).
    static func cached(_ id: UInt64) -> DepthMap? {
        guard let d = try? Data(contentsOf: file(id)), d.count > 9 else { return nil }
        let u32 = { (o: Int) in d[o..<(o + 4)].enumerated().reduce(0) { $0 | Int($1.element) << (8 * $1.offset) } }
        let (w, h) = (u32(0), u32(4))
        guard w > 0, h > 0, d.count == 9 + w * h else { return nil }
        return DepthMap(width: w, height: h, data: [UInt8](d[9...]), source: d[8] == 1 ? "camera" : "estimated")
    }

    static func save(_ id: UInt64, _ m: DepthMap) {
        var d = Data()
        for v in [m.width, m.height] { for i in 0..<4 { d.append(UInt8((v >> (8 * i)) & 0xff)) } }
        d.append(m.source == "camera" ? 1 : 0)
        d.append(contentsOf: m.data)
        try? d.write(to: file(id), options: .atomic)
    }

    static func forget(_ id: UInt64) { try? FileManager.default.removeItem(at: file(id)) }

    /// Hand a photo's saved depth map to the engine (before rendering or exporting it).
    static func load(_ id: UInt64) {
        if let m = cached(id) { Engine.shared.setDepth(id, m) }
    }

    /// The photo file's own path, from the engine.
    static func path(of id: UInt64) -> URL? {
        let info = (try? Engine.shared.run("photo.inspect", ["id": id])) as? [String: Any]
        guard let src = info?["source"] as? [String: Any], let p = src["path"] as? String, !p.isEmpty else { return nil }
        return URL(fileURLWithPath: p)
    }

    // MARK: from the camera

    /// The depth the iPhone recorded with the photo (Portrait shots, and others where it captured
    /// depth), turned upright.
    static func fromCamera(_ url: URL) -> DepthMap? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        for type in [kCGImageAuxiliaryDataTypeDisparity, kCGImageAuxiliaryDataTypeDepth] {
            guard let info = CGImageSourceCopyAuxiliaryDataInfoAtIndex(src, 0, type) as? [AnyHashable: Any],
                  var depth = try? AVDepthData(fromDictionaryRepresentation: info)
            else { continue }
            depth = depth.converting(toDepthDataType: kCVPixelFormatType_DisparityFloat32)
            let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any]
            if let raw = props?[kCGImagePropertyOrientation] as? UInt32, let o = CGImagePropertyOrientation(rawValue: raw) {
                depth = depth.applyingExifOrientation(o)
            }
            let buf = depth.depthDataMap
            if let m = floats(buf).flatMap({ DepthMap(nearness: $0.values, width: $0.w, height: $0.h, source: "camera") }) { return m }
        }
        return nil
    }

    private static func floats(_ buf: CVPixelBuffer) -> (values: [Float], w: Int, h: Int)? {
        CVPixelBufferLockBaseAddress(buf, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buf, .readOnly) }
        let w = CVPixelBufferGetWidth(buf), h = CVPixelBufferGetHeight(buf)
        let row = CVPixelBufferGetBytesPerRow(buf)
        guard let base = CVPixelBufferGetBaseAddress(buf), w > 0, h > 0 else { return nil }
        let format = CVPixelBufferGetPixelFormatType(buf)
        var out = [Float](repeating: 0, count: w * h)
        for y in 0..<h {
            let line = base.advanced(by: y * row)
            for x in 0..<w {
                switch format {
                case kCVPixelFormatType_DisparityFloat32, kCVPixelFormatType_DepthFloat32, kCVPixelFormatType_OneComponent32Float:
                    out[y * w + x] = line.assumingMemoryBound(to: Float.self)[x]
                case kCVPixelFormatType_DisparityFloat16, kCVPixelFormatType_DepthFloat16, kCVPixelFormatType_OneComponent16Half:
                    out[y * w + x] = Float(line.assumingMemoryBound(to: Float16.self)[x])
                case kCVPixelFormatType_OneComponent8:
                    out[y * w + x] = Float(line.assumingMemoryBound(to: UInt8.self)[x])
                default:
                    return nil
                }
            }
        }
        return (out, w, h)
    }

    // MARK: estimated

    /// Make a depth map with the depth model (Depth Anything V2 Small) from the photo file.
    static func estimate(_ url: URL) throws -> DepthMap {
        guard let model = DepthModel.load() else { throw EngineError(message: "The depth model isn't installed.") }
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(src, 0, [
                  kCGImageSourceCreateThumbnailFromImageAlways: true,
                  kCGImageSourceCreateThumbnailWithTransform: true,
                  kCGImageSourceThumbnailMaxPixelSize: 1024,
              ] as CFDictionary)
        else { throw EngineError(message: "This photo couldn't be read for depth.") }
        let desc = model.modelDescription
        guard let input = desc.inputDescriptionsByName.first(where: { $0.value.type == .image }),
              let constraint = input.value.imageConstraint
        else { throw EngineError(message: "The depth model has an unexpected input.") }
        let value = try MLFeatureValue(cgImage: image, constraint: constraint, options: [
            .cropAndScale: VNImageCropAndScaleOptionScaleFill,
        ])
        let out = try model.prediction(from: MLDictionaryFeatureProvider(dictionary: [input.key: value]))
        guard let name = desc.outputDescriptionsByName.keys.sorted().first, let f = out.featureValue(for: name) else {
            throw EngineError(message: "The depth model gave nothing back.")
        }
        var result: (values: [Float], w: Int, h: Int)?
        if let buf = f.imageBufferValue {
            result = floats(buf)
        } else if let a = f.multiArrayValue {
            let dims = a.shape.map(\.intValue)
            let (h, w) = (dims.count >= 2 ? dims[dims.count - 2] : 0, dims.last ?? 0)
            if w > 0, h > 0, a.count >= w * h {
                let start = a.count - w * h
                result = ((0..<(w * h)).map { a[start + $0].floatValue }, w, h)
            }
        }
        guard let r = result, let m = DepthMap(nearness: r.values, width: r.w, height: r.h, source: "estimated") else {
            throw EngineError(message: "The depth model's answer couldn't be read.")
        }
        return m
    }
}

/// `VNImageCropAndScaleOption.scaleFill` without importing Vision: stretch the photo to the input.
private let VNImageCropAndScaleOptionScaleFill = 2

// MARK: optional models

/// A Core ML model Latent downloads on request: where it comes from, and where it lives once
/// compiled for this iPhone.
struct ModelSpec: Sendable {
    let name: String
    let title: String
    let blurb: String
    let credit: String
    let repo: String
    /// The packages' folders in the repository (a model may come in parts).
    let packages: [String]
    let files: [String]
    let size: String
    /// Set when the repository has the package zipped: that file's path (the packages are then
    /// the `.mlpackage` folders inside it).
    var archive: String? = nil
    /// The archive's full address, when it is not in `repo`'s files (a release of this app's repository).
    var archiveURL: String? = nil
    /// Where the model may run: some lose precision on the Neural Engine.
    var computeUnits: MLComputeUnits = .all

    var folder: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = base.appendingPathComponent("Models", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Where part `i`, compiled for this iPhone, lives.
    func compiled(_ i: Int) -> URL {
        let part = packages.count > 1 ? "-\(i)" : ""
        return folder.appendingPathComponent("\(name)\(part).mlmodelc", isDirectory: true)
    }

    var installed: Bool { packages.indices.allSatisfy { FileManager.default.fileExists(atPath: compiled($0).path) } }

    func load(_ part: Int = 0) -> MLModel? { LoadedModels.load(self, part) }

    func remove() {
        for i in packages.indices {
            LoadedModels.forget(compiled(i).path)
            try? FileManager.default.removeItem(at: compiled(i))
        }
    }

    static let coreFiles = ["Manifest.json", "Data/com.apple.CoreML/model.mlmodel", "Data/com.apple.CoreML/weights/weight.bin"]
}

/// Models loaded once and shared (Core ML predictions may run from several threads).
enum LoadedModels {
    private static let lock = NSLock()
    private static var models: [String: MLModel] = [:]

    static func load(_ spec: ModelSpec, _ part: Int) -> MLModel? {
        let url = spec.compiled(part)
        lock.lock()
        defer { lock.unlock() }
        if let m = models[url.path] { return m }
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let c = MLModelConfiguration()
        c.computeUnits = spec.computeUnits
        let m = try? MLModel(contentsOf: url, configuration: c)
        models[url.path] = m
        return m
    }

    static func forget(_ name: String) {
        lock.lock()
        models[name] = nil
        lock.unlock()
    }
}

/// Apple's Core ML conversion of Depth Anything V2 Small (Apache-2.0).
let DepthModel = ModelSpec(
    name: "DepthAnythingV2SmallF16",
    title: "Depth model",
    blurb: "Estimates how far away everything in a photo is, so Lens Blur can blur by distance in photos the iPhone didn't record depth for. It runs on this iPhone; nothing is uploaded.",
    credit: "Depth Anything V2 Small, converted for Core ML by Apple, from Hugging Face. Licence: Apache 2.0.",
    repo: "https://huggingface.co/apple/coreml-depth-anything-v2-small",
    packages: ["DepthAnythingV2SmallF16.mlpackage"],
    files: ModelSpec.coreFiles,
    size: "50 MB")

/// Big LaMa, the full inpainting model, at 800 × 800 in a Core ML conversion (Apache-2.0).
let InpaintModel = ModelSpec(
    name: "BigLaMa800",
    title: "AI remove model",
    blurb: "Rebuilds what's behind something you brush away (a person, a sign, a car) from what's around it, inventing detail where needed. This is the full model at its larger working size, for sharper, cleaner fills. It runs on this iPhone; nothing is uploaded.",
    credit: "LaMa (Suvorov et al., Samsung AI), the full Big LaMa model, in an 800 × 800 Core ML conversion from Hugging Face (mlboydaisuke/coreml-zoo). Licence: Apache 2.0.",
    repo: "https://huggingface.co/mlboydaisuke/coreml-zoo",
    packages: ["LaMa.mlpackage"],
    files: [],
    size: "196 MB",
    archive: "lama/LaMa.mlpackage.zip")

/// The smaller LaMa (dilated, 6-bit, 512 × 512): still used when it's what's installed.
let InpaintModelLite = ModelSpec(
    name: "LaMaDilated",
    title: "AI remove model (small)",
    blurb: "Rebuilds what's behind something you brush away (a person, a sign, a car) from what's around it, inventing detail where needed. It runs on this iPhone; nothing is uploaded.",
    credit: "LaMa (Suvorov et al., Samsung AI), dilated variant, in a 6-bit Core ML conversion from Hugging Face (Dadm-n/lama-dilated-coreml). Licence: Apache 2.0.",
    repo: "https://huggingface.co/Dadm-n/lama-dilated-coreml",
    packages: ["Resources/LaMa.mlpackage"],
    files: ModelSpec.coreFiles,
    size: "40 MB")

/// SAM 2.1 Small (Meta), in Apple's Core ML conversion (Apache-2.0): tap an object to select it.
/// Three parts: the picture's encoder, the taps' encoder, and the decoder that makes the mask.
let SelectionModel = ModelSpec(
    name: "SAM2_1Small",
    title: "Object selection model",
    blurb: "Selects exactly what you tap (a person, a bike, a cup, a cloud) with clean edges, for masks and for Remove. Tap more to add to it or to leave parts out. It runs on this iPhone; nothing is uploaded.",
    credit: "SAM 2.1 Small by Meta, converted for Core ML by Apple, from Hugging Face. Licence: Apache 2.0.",
    repo: "https://huggingface.co/apple/coreml-sam2.1-small",
    packages: ["SAM2_1SmallImageEncoderFLOAT16.mlpackage", "SAM2_1SmallPromptEncoderFLOAT16.mlpackage", "SAM2_1SmallMaskDecoderFLOAT16.mlpackage"],
    files: ModelSpec.coreFiles,
    size: "94 MB")

/// NAFNet (megvii-research, MIT), trained on smartphone photos, converted to Core ML by this app's Models
/// workflow and published on a release of its repository: AI denoise.
let DenoiseModel = ModelSpec(
    name: "NAFNetSIDDw32",
    title: "AI denoise model",
    blurb: "Cleans noise from photos taken in low light, keeping fine detail. Denoising a photo takes a little while (longer for large raw files); the Denoise slider then mixes the clean picture in. It runs on this iPhone; nothing is uploaded.",
    credit: "NAFNet (Chen et al., megvii-research), trained on the SIDD smartphone photos, converted for Core ML from the NAFNet project's own weights. Licence: MIT.",
    repo: "https://github.com/megvii-research/NAFNet",
    packages: ["NAFNet-SIDD-w32.mlpackage"],
    files: [],
    size: "59 MB",
    archive: "NAFNet-SIDD-w32.mlpackage.zip",
    archiveURL: "https://github.com/FlicksDaModdle/Lightcraft-Mobile/releases/download/models-nafnet-sidd-w32-v1/NAFNet-SIDD-w32.mlpackage.zip",
    computeUnits: .cpuAndGPU)

/// AI denoise: runs the denoise model over a photo, tile by tile, through the engine (which cuts the tiles and
/// takes the result back), and keeps the result so it is there next time.
enum AIDenoise {
    static let tile = 512
    nonisolated(unsafe) private static var model: MLModel?
    nonisolated(unsafe) private static var onProgress: ((Double) -> Void)?

    static var folder: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = base.appendingPathComponent("Denoised", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    static func file(_ id: UInt64) -> URL { folder.appendingPathComponent("\(id).ltdn") }

    static func saved(_ id: UInt64) -> Bool { FileManager.default.fileExists(atPath: file(id).path) }

    /// Load a photo's saved denoised picture into the engine (off the main thread: the file is large).
    static func load(_ id: UInt64) async -> Bool {
        guard saved(id) else { return false }
        return await Task.detached(priority: .utility) { Engine.shared.loadDenoised(id, from: file(id)) }.value
    }

    static func forget(_ id: UInt64) {
        Engine.shared.forgetDenoised(id)
        try? FileManager.default.removeItem(at: file(id))
    }

    /// Denoise photo `id`; `progress` hears 0…1 on the main thread.
    static func run(_ id: UInt64, progress: @escaping @MainActor (Double) -> Void) async throws {
        guard let m = DenoiseModel.load() else { throw EngineError(message: "The AI denoise model isn't installed.") }
        try await Task.detached(priority: .userInitiated) {
            model = m
            onProgress = { v in Task { @MainActor in progress(v) } }
            defer { model = nil; onProgress = nil }
            try Engine.shared.denoise(id, tile: tile, model: { input, size, out in
                guard let input, let out, let m = AIDenoise.model else { return false }
                return AIDenoise.predict(m, input, Int(size), out)
            }, progress: { done, total in
                AIDenoise.onProgress?(total > 0 ? Double(done) / Double(total) : 0)
            })
            _ = Engine.shared.saveDenoised(id, to: file(id))
        }.value
    }

    /// One tile through the model: `3 × size × size` planar values in and out.
    nonisolated static func predict(_ m: MLModel, _ input: UnsafePointer<Float>, _ size: Int, _ out: UnsafeMutablePointer<Float>) -> Bool {
        let n = 3 * size * size
        guard let arr = try? MLMultiArray(shape: [1, 3, NSNumber(value: size), NSNumber(value: size)], dataType: .float32) else { return false }
        arr.withUnsafeMutableBufferPointer(ofType: Float.self) { b, _ in
            b.baseAddress?.update(from: input, count: n)
        }
        guard let features = try? MLDictionaryFeatureProvider(dictionary: ["image": MLFeatureValue(multiArray: arr)]),
              let result = try? m.prediction(from: features),
              let y = result.featureValue(for: "denoised")?.multiArrayValue, y.count == n else { return false }
        switch y.dataType {
        case .float32:
            y.withUnsafeBufferPointer(ofType: Float.self) { b in
                if let base = b.baseAddress { out.update(from: base, count: n) }
            }
        case .float16:
            y.withUnsafeBufferPointer(ofType: Float16.self) { b in
                for i in 0..<n { out[i] = Float(b[i]) }
            }
        default:
            for i in 0..<n { out[i] = y[i].floatValue }
        }
        return true
    }
}

/// Downloads a model's files, then compiles it for this iPhone.
@MainActor
final class ModelDownload: ObservableObject {
    let spec: ModelSpec
    @Published private(set) var progress: Double?
    @Published private(set) var problem: String?
    @Published private(set) var installed: Bool
    /// Which part is downloading, of how many.
    @Published private(set) var part = (0, 1)
    private var observation: NSKeyValueObservation?

    init(_ spec: ModelSpec) {
        self.spec = spec
        installed = spec.installed
    }

    func start() {
        guard progress == nil else { return }
        problem = nil
        progress = 0
        let spec = spec
        Task {
            do {
                if let archive = spec.archive {
                    // one zip holding the package(s)
                    guard let url = URL(string: spec.archiveURL ?? "\(spec.repo)/resolve/main/\(archive)") else { throw EngineError(message: "Bad model address.") }
                    let zip = try await fetch(url, tracked: true)
                    progress = 1
                    let out = FileManager.default.temporaryDirectory.appendingPathComponent("\(spec.name)-unzipped", isDirectory: true)
                    try? FileManager.default.removeItem(at: out)
                    try await Task.detached(priority: .userInitiated) { try Unzip.extract(zip, into: out) }.value
                    try? FileManager.default.removeItem(at: zip)
                    for (i, package) in spec.packages.enumerated() {
                        // the package may sit in a folder inside the zip
                        let found = FileManager.default.enumerator(at: out, includingPropertiesForKeys: nil)?
                            .compactMap { $0 as? URL }.first { $0.lastPathComponent == package }
                        guard let pkg = found else { throw EngineError(message: "The download didn't hold the model.") }
                        let built = try await Task.detached(priority: .userInitiated) { try MLModel.compileModel(at: pkg) }.value
                        try? FileManager.default.removeItem(at: spec.compiled(i))
                        try FileManager.default.moveItem(at: built, to: spec.compiled(i))
                    }
                    try? FileManager.default.removeItem(at: out)
                }
                for (i, package) in spec.packages.enumerated() where spec.archive == nil {
                    part = (i, spec.packages.count)
                    let pkg = FileManager.default.temporaryDirectory.appendingPathComponent("\(spec.name)-\(i).mlpackage", isDirectory: true)
                    try? FileManager.default.removeItem(at: pkg)
                    // the weights are nearly all of it: they get the bar
                    for f in spec.files {
                        guard let url = URL(string: "\(spec.repo)/resolve/main/\(package)/\(f)") else { continue }
                        let dest = pkg.appendingPathComponent(f)
                        try FileManager.default.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
                        let tmp = try await fetch(url, tracked: f.hasSuffix("weight.bin"))
                        try FileManager.default.moveItem(at: tmp, to: dest)
                    }
                    let built = try await Task.detached(priority: .userInitiated) { try MLModel.compileModel(at: pkg) }.value
                    try? FileManager.default.removeItem(at: spec.compiled(i))
                    try FileManager.default.moveItem(at: built, to: spec.compiled(i))
                    try? FileManager.default.removeItem(at: pkg)
                }
                progress = 1
                installed = true
                progress = nil
            } catch {
                problem = error.localizedDescription
                progress = nil
            }
        }
    }

    private func fetch(_ url: URL, tracked: Bool) async throws -> URL {
        try await withCheckedThrowingContinuation { done in
            let task = URLSession.shared.downloadTask(with: url) { file, response, error in
                if let error { return done.resume(throwing: error) }
                guard let file, (response as? HTTPURLResponse)?.statusCode == 200 else {
                    return done.resume(throwing: EngineError(message: "The download didn't come through. Check your connection and try again."))
                }
                // keep the file: the system deletes it when this returns
                let keep = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
                do {
                    try FileManager.default.moveItem(at: file, to: keep)
                    done.resume(returning: keep)
                } catch {
                    done.resume(throwing: error)
                }
            }
            if tracked {
                observation = task.progress.observe(\.fractionCompleted) { [weak self] p, _ in
                    let f = p.fractionCompleted
                    Task { @MainActor in self?.progress = Swift.min(f, 0.99) }
                }
            }
            task.resume()
        }
    }

    func remove() {
        spec.remove()
        installed = false
    }
}

/// Getting (or removing) an optional model.
struct ModelSheet: View {
    @StateObject private var download: ModelDownload
    @Environment(\.dismiss) private var dismiss
    let installed: () -> Void

    init(_ spec: ModelSpec, installed: @escaping () -> Void) {
        _download = StateObject(wrappedValue: ModelDownload(spec))
        self.installed = installed
    }

    var body: some View {
        let spec = download.spec
        NavigationStack {
            List {
                Section {
                    VStack(alignment: .leading, spacing: 8) {
                        Label(spec.title, systemImage: "cpu").font(.system(size: 18, weight: .semibold))
                        Text(spec.blurb).font(.system(size: 14)).foregroundStyle(Theme.secondaryText)
                    }
                    .padding(.vertical, 4)
                }
                Section {
                    if download.installed {
                        Label("Installed", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                        Button(role: .destructive) { download.remove() } label: { Label("Remove the model", systemImage: "trash") }
                    } else if let p = download.progress {
                        VStack(alignment: .leading, spacing: 8) {
                            ProgressView(value: p).tint(Theme.accent)
                            Text(p >= 1 ? "Preparing it for this iPhone\u{2026}" : "Downloading\u{2026} \(Int(p * 100))%" + (download.part.1 > 1 ? " (part \(download.part.0 + 1) of \(download.part.1))" : ""))
                                .font(.system(size: 13)).foregroundStyle(Theme.secondaryText).monospacedDigit()
                        }
                    } else {
                        Button { download.start() } label: { Label("Download (\(spec.size))", systemImage: "arrow.down.circle") }
                    }
                    if let problem = download.problem {
                        Text(problem).font(.system(size: 13)).foregroundStyle(.red)
                    }
                } footer: {
                    Text(spec.credit)
                }
                Section {
                    if let url = URL(string: spec.repo) {
                        Link(destination: url) { Label("About the model", systemImage: "safari") }
                    }
                }
            }
            .navigationTitle(spec.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
            .onChange(of: download.installed) { _, now in if now { installed() } }
        }
        .preferredColorScheme(.dark)
    }
}

// MARK: AI remove

enum Inpainting {
    /// Hand the engine the AI remove model when it's installed (else AI remove fills from the
    /// surroundings).
    static func register() {
        guard let model = current() else {
            latent_set_inpainter(nil, 0)
            return
        }
        let size = model.modelDescription.inputDescriptionsByName.values
            .compactMap { $0.multiArrayConstraint?.shape.last?.intValue ?? $0.imageConstraint?.pixelsWide }.max() ?? 512
        latent_set_inpainter(inpaintCallback, UInt32(size))
    }

    /// The best AI remove model installed: the full one, else the small one.
    static func current() -> MLModel? { InpaintModel.load() ?? InpaintModelLite.load() }

    static var installed: Bool { InpaintModel.installed || InpaintModelLite.installed }

    /// Run the model: `rgb` row-major size×size×3 and `hole` size×size in, `out` size×size×3 written.
    static func run(_ rgb: UnsafePointer<Float>, _ hole: UnsafePointer<Float>, _ size: Int, _ out: UnsafeMutablePointer<Float>) -> Bool {
        guard let model = current() else { return false }
        let inputs = model.modelDescription.inputDescriptionsByName
        if inputs.values.contains(where: { $0.type == .image }) {
            return runOnImages(model, rgb, hole, size, out)
        }
        // the picture has 3 channels, the hole 1
        guard let picture = inputs.first(where: { $0.value.multiArrayConstraint?.shape.dropFirst().first?.intValue == 3 }),
              let mask = inputs.first(where: { $0.key != picture.key }),
              let pc = picture.value.multiArrayConstraint, let mc = mask.value.multiArrayConstraint,
              let pa = try? MLMultiArray(shape: pc.shape, dataType: pc.dataType),
              let ma = try? MLMultiArray(shape: mc.shape, dataType: mc.dataType)
        else { return false }
        let n = size * size
        guard pa.count == 3 * n, ma.count == n else { return false }
        // channels first
        for c in 0..<3 {
            for i in 0..<n { set(pa, c * n + i, rgb[i * 3 + c]) }
        }
        for i in 0..<n { set(ma, i, hole[i]) }
        guard let result = try? model.prediction(from: MLDictionaryFeatureProvider(dictionary: [picture.key: pa, mask.key: ma])),
              let name = model.modelDescription.outputDescriptionsByName.keys.sorted().first,
              let o = result.featureValue(for: name)?.multiArrayValue, o.count >= 3 * n
        else { return false }
        let strides = o.strides.map(\.intValue)
        let dims = o.shape.map(\.intValue)
        guard dims.count >= 3 else { return false }
        let (sc, sy, sx) = (strides[dims.count - 3], strides[dims.count - 2], strides[dims.count - 1])
        for y in 0..<size {
            for x in 0..<size {
                for c in 0..<3 {
                    let v = get(o, c * sc + y * sy + x * sx)
                    // some conversions answer 0…255
                    out[(y * size + x) * 3 + c] = v > 1.5 ? v / 255 : v
                }
            }
        }
        return true
    }

    /// The same for a model that takes and gives pictures (an RGB picture and a grey mask).
    private static func runOnImages(_ model: MLModel, _ rgb: UnsafePointer<Float>, _ hole: UnsafePointer<Float>, _ size: Int, _ out: UnsafeMutablePointer<Float>) -> Bool {
        let inputs = model.modelDescription.inputDescriptionsByName
        guard let picture = inputs.first(where: { $0.value.type == .image && $0.value.imageConstraint?.pixelFormatType != kCVPixelFormatType_OneComponent8 }),
              let mask = inputs.first(where: { $0.key != picture.key }),
              let pc = picture.value.imageConstraint
        else { return false }
        let n = size * size
        var rgba = [UInt8](repeating: 255, count: n * 4)
        for i in 0..<n {
            for c in 0..<3 { rgba[i * 4 + c] = UInt8(Swift.min(Swift.max(rgb[i * 3 + c], 0), 1) * 255) }
        }
        var grey = (0..<n).map { UInt8(hole[$0] > 0.5 ? 255 : 0) }
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let pImg = rgba.withUnsafeMutableBytes({ b in
                  CGContext(data: b.baseAddress, width: size, height: size, bitsPerComponent: 8, bytesPerRow: size * 4, space: space,
                            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)?.makeImage()
              }),
              let mImg = grey.withUnsafeMutableBytes({ b in
                  CGContext(data: b.baseAddress, width: size, height: size, bitsPerComponent: 8, bytesPerRow: size, space: CGColorSpaceCreateDeviceGray(),
                            bitmapInfo: CGImageAlphaInfo.none.rawValue)?.makeImage()
              })
        else { return false }
        var values: [String: Any] = [:]
        do {
            values[picture.key] = try MLFeatureValue(cgImage: pImg, constraint: pc, options: [.cropAndScale: 2])
            if let mc = mask.value.imageConstraint {
                values[mask.key] = try MLFeatureValue(cgImage: mImg, constraint: mc, options: [.cropAndScale: 2])
            } else if let mc = mask.value.multiArrayConstraint {
                let ma = try MLMultiArray(shape: mc.shape, dataType: mc.dataType)
                guard ma.count == n else { return false }
                for i in 0..<n { set(ma, i, hole[i]) }
                values[mask.key] = ma
            }
            let result = try model.prediction(from: MLDictionaryFeatureProvider(dictionary: values))
            guard let name = model.modelDescription.outputDescriptionsByName.keys.sorted().first, let f = result.featureValue(for: name) else { return false }
            if let buf = f.imageBufferValue {
                return readImage(buf, size, out)
            }
            guard let o = f.multiArrayValue, o.count >= 3 * n else { return false }
            let dims = o.shape.map(\.intValue), st = o.strides.map(\.intValue)
            guard dims.count >= 3 else { return false }
            let (sc, sy, sx) = (st[dims.count - 3], st[dims.count - 2], st[dims.count - 1])
            for y in 0..<size {
                for x in 0..<size {
                    for c in 0..<3 {
                        let v = get(o, c * sc + y * sy + x * sx)
                        out[(y * size + x) * 3 + c] = v > 1.5 ? v / 255 : v
                    }
                }
            }
            return true
        } catch {
            return false
        }
    }

    /// An output picture (32BGRA or 32ARGB) into 0…1 RGB, resampled to `size` if it differs.
    private static func readImage(_ buf: CVPixelBuffer, _ size: Int, _ out: UnsafeMutablePointer<Float>) -> Bool {
        CVPixelBufferLockBaseAddress(buf, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buf, .readOnly) }
        let w = CVPixelBufferGetWidth(buf), h = CVPixelBufferGetHeight(buf), row = CVPixelBufferGetBytesPerRow(buf)
        guard let base = CVPixelBufferGetBaseAddress(buf)?.assumingMemoryBound(to: UInt8.self), w > 0, h > 0 else { return false }
        let format = CVPixelBufferGetPixelFormatType(buf)
        // where red, green and blue sit in each 4-byte pixel
        let order: [Int]
        switch format {
        case kCVPixelFormatType_32BGRA: order = [2, 1, 0]
        case kCVPixelFormatType_32ARGB: order = [1, 2, 3]
        case kCVPixelFormatType_32RGBA: order = [0, 1, 2]
        default: return false
        }
        for y in 0..<size {
            let sy = Swift.min(y * h / size, h - 1)
            for x in 0..<size {
                let sx = Swift.min(x * w / size, w - 1)
                let p = base + sy * row + sx * 4
                for c in 0..<3 { out[(y * size + x) * 3 + c] = Float(p[order[c]]) / 255 }
            }
        }
        return true
    }

    private static func set(_ a: MLMultiArray, _ i: Int, _ v: Float) {
        switch a.dataType {
        case .float16: a.dataPointer.assumingMemoryBound(to: Float16.self)[i] = Float16(v)
        case .double: a.dataPointer.assumingMemoryBound(to: Double.self)[i] = Double(v)
        default: a.dataPointer.assumingMemoryBound(to: Float.self)[i] = v
        }
    }

    private static func get(_ a: MLMultiArray, _ i: Int) -> Float {
        switch a.dataType {
        case .float16: return Float(a.dataPointer.assumingMemoryBound(to: Float16.self)[i])
        case .double: return Float(a.dataPointer.assumingMemoryBound(to: Double.self)[i])
        default: return a.dataPointer.assumingMemoryBound(to: Float.self)[i]
        }
    }
}

/// The C function the engine calls for AI remove.
private let inpaintCallback: LatentInpaintFn = { rgb, hole, size, out in
    guard let rgb, let hole, let out else { return false }
    return Inpainting.run(rgb, hole, Int(size), out)
}

/// The Focus Range bar: the photo's depths from near to far as a histogram, and the sharp range
/// over it. Drag the middle to move it, either end to widen or narrow it.
struct FocusRangeBar: View {
    let histogram: [Double]
    /// The range, 0 near … 100 far.
    let lo: Double
    let hi: Double
    let begin: () -> Void
    let change: (Double, Double) -> Void
    let end: () -> Void
    @State private var drag: (part: Int, lo: Double, hi: Double)?

    var body: some View {
        VStack(spacing: 6) {
            GeometryReader { geo in
                let w = geo.size.width, h = geo.size.height
                let x = { (v: Double) in CGFloat(v / 100) * w }
                ZStack(alignment: .topLeading) {
                    // the depths
                    Path { p in
                        let n = Swift.max(histogram.count, 1)
                        p.move(to: CGPoint(x: 0, y: h))
                        for (i, v) in histogram.enumerated() {
                            let x0 = CGFloat(i) / CGFloat(n) * w, x1 = CGFloat(i + 1) / CGFloat(n) * w
                            let y = h - CGFloat(Swift.max(v, 0.02)) * (h - 6)
                            p.addLine(to: CGPoint(x: x0, y: y))
                            p.addLine(to: CGPoint(x: x1, y: y))
                        }
                        p.addLine(to: CGPoint(x: w, y: h))
                        p.closeSubpath()
                    }
                    .fill(Color.white.opacity(0.35))
                    RoundedRectangle(cornerRadius: 6).fill(Color.white.opacity(0.06))
                    // the sharp range
                    let l = x(lo), r = x(hi)
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(Color.white.opacity(0.18))
                        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Color.white, lineWidth: 2.5))
                        .frame(width: Swift.max(r - l, 14), height: h)
                        .offset(x: l)
                    Circle().strokeBorder(Color.white, lineWidth: 2.5).frame(width: 22, height: 22)
                        .offset(x: (l + r) / 2 - 11, y: h / 2 - 11)
                    ForEach([l, r].indices, id: \.self) { i in
                        Capsule().fill(Color.white).frame(width: 8, height: h * 0.6)
                            .overlay(Capsule().fill(Color.black.opacity(0.25)).frame(width: 2, height: h * 0.3))
                            .offset(x: (i == 0 ? l : r) - 4, y: h * 0.2)
                    }
                }
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { g in
                            if drag == nil {
                                let sx = g.startLocation.x
                                let near = { (v: Double) in abs(sx - x(v)) < 22 }
                                // an end, else the middle (moves the whole range)
                                let part = near(lo) && !near(hi) ? 0 : (near(hi) && !near(lo) ? 1 : 2)
                                drag = (part, lo, hi)
                                begin()
                            }
                            guard let d = drag else { return }
                            let dv = Double(g.translation.width / Swift.max(w, 1)) * 100
                            switch d.part {
                            case 0: change(Swift.min(Swift.max(d.lo + dv, 0), d.hi - 2), d.hi)
                            case 1: change(d.lo, Swift.max(Swift.min(d.hi + dv, 100), d.lo + 2))
                            default:
                                let span = d.hi - d.lo
                                let nl = Swift.min(Swift.max(d.lo + dv, 0), 100 - span)
                                change(nl, nl + span)
                            }
                        }
                        .onEnded { _ in
                            drag = nil
                            end()
                        }
                )
            }
            .frame(height: 46)
            HStack {
                Text("Near")
                Spacer()
                Text("Far")
            }
            .font(.system(size: 12))
            .foregroundStyle(Theme.secondaryText)
        }
        .accessibilityElement()
        .accessibilityLabel(Text("Focus range"))
        .accessibilityValue(Text("From \(Int(lo)) to \(Int(hi)), near 0, far 100"))
        .accessibilityAdjustableAction { dir in
            begin()
            let step = dir == .increment ? 2.0 : -2.0
            let span = hi - lo
            let nl = Swift.min(Swift.max(lo + step, 0), 100 - span)
            change(nl, nl + span)
            end()
        }
    }
}
