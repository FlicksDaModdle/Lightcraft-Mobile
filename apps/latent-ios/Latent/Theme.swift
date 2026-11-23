import SwiftUI
import UIKit

/// Latent's colours: near-black chrome around the photo, one dark grey surface for the panel and bars.
enum Theme {
    static let photoBackground = Color.black
    static let surface = Color(red: 0.105, green: 0.105, blue: 0.11)
    static let separator = Color.white.opacity(0.08)
    static let selectedCell = Color.white.opacity(0.10)
    static let accent = Color(red: 0.16, green: 0.47, blue: 0.96)
    static let secondaryText = Color(white: 0.62)
    static let track = Color(white: 0.32)
    static let thumb = Color(white: 0.86)

    /// The colour mixer's eight bands, as the engine orders them.
    static let bands: [Color] = [
        Color(red: 230 / 255, green: 70 / 255, blue: 70 / 255),
        Color(red: 240 / 255, green: 150 / 255, blue: 50 / 255),
        Color(red: 235 / 255, green: 215 / 255, blue: 60 / 255),
        Color(red: 80 / 255, green: 200 / 255, blue: 90 / 255),
        Color(red: 70 / 255, green: 205 / 255, blue: 205 / 255),
        Color(red: 70 / 255, green: 120 / 255, blue: 235 / 255),
        Color(red: 150 / 255, green: 90 / 255, blue: 220 / 255),
        Color(red: 225 / 255, green: 80 / 255, blue: 180 / 255),
    ]

    static func band(_ i: Int) -> Color { bands[((i % bands.count) + bands.count) % bands.count] }

    /// The colours along a slider's track, or nil for a plain grey one.
    static func stops(_ track: Track) -> [Color]? {
        switch track {
        case .plain, .centered: return nil
        case .temp: return [Color(red: 0.29, green: 0.37, blue: 0.85), Color(white: 0.55), Color(red: 0.86, green: 0.78, blue: 0.3)]
        case .tint: return [Color(red: 0.32, green: 0.68, blue: 0.33), Color(white: 0.55), Color(red: 0.78, green: 0.32, blue: 0.78)]
        case .gradient(let from, let to): return [Color(hex: from), Color(hex: to)]
        case .sat(let b): return [Color(white: 0.45), band(b)]
        case .lum(let b): return [band(b).opacity(0.35), band(b), Color.white.opacity(0.9)]
        case .hue(let b): return [band(b - 1), band(b), band(b + 1)]
        case .rainbow: return (0...12).map { Color(hue: Double($0) / 12, saturation: 0.85, brightness: 0.95) }
        }
    }
}

extension Color {
    /// `#rrggbb`; grey when it can't be read.
    init(hex: String) {
        let s = hex.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        guard s.count == 6, let v = UInt32(s, radix: 16) else {
            self = Color(white: 0.5)
            return
        }
        self = Color(red: Double((v >> 16) & 0xff) / 255, green: Double((v >> 8) & 0xff) / 255, blue: Double(v & 0xff) / 255)
    }
}

extension View {
    /// Glass shapes inside blend and morph into each other on iOS 26 (Liquid Glass container).
    @ViewBuilder
    func latentGlassGroup(spacing: CGFloat = 10) -> some View {
        #if compiler(>=6.2)
        if #available(iOS 26.0, *) {
            GlassEffectContainer(spacing: spacing) { self }
        } else {
            self
        }
        #else
        self
        #endif
    }

    /// Ties a glass shape to others with the same id, so one morphs into the next on iOS 26.
    @ViewBuilder
    func latentGlassID(_ id: String, in namespace: Namespace.ID) -> some View {
        #if compiler(>=6.2)
        if #available(iOS 26.0, *) {
            self.glassEffectID(id, in: namespace)
        } else {
            self
        }
        #else
        self
        #endif
    }
}

extension View {
    /// The filled, tinted glass button for a sheet's confirm action on iOS 26.
    @ViewBuilder
    func latentProminentGlass() -> some View {
        #if compiler(>=6.2)
        if #available(iOS 26.0, *) {
            self.buttonStyle(.glassProminent).tint(Theme.accent)
        } else {
            self.fontWeight(.semibold).tint(Theme.accent)
        }
        #else
        self.fontWeight(.semibold).tint(Theme.accent)
        #endif
    }
}

extension Animation {
    /// The springy motion glass moves with.
    static let glass = Animation.spring(response: 0.38, dampingFraction: 0.78)
}

/// A colour taken from a photo for the editor's background: the photo's own hue, vivid parts
/// counting most, kept dark so the photo stays what the eye judges.
enum Ambient {
    static func color(of image: CGImage) -> Color? {
        let n = 24
        var px = [UInt8](repeating: 0, count: n * n * 4)
        guard let space = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        let drawn: Bool = px.withUnsafeMutableBytes { buf in
            guard let ctx = CGContext(
                data: buf.baseAddress, width: n, height: n, bitsPerComponent: 8, bytesPerRow: n * 4, space: space,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
            else { return false }
            ctx.interpolationQuality = .medium
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: n, height: n))
            return true
        }
        guard drawn else { return nil }
        var r = 0.0, g = 0.0, b = 0.0, total = 0.0
        for i in stride(from: 0, to: px.count, by: 4) {
            let R = Double(px[i]) / 255, G = Double(px[i + 1]) / 255, B = Double(px[i + 2]) / 255
            let hi = Swift.max(R, G, B), lo = Swift.min(R, G, B)
            let sat = hi > 0 ? (hi - lo) / hi : 0
            let weight = 0.12 + sat * hi
            r += R * weight
            g += G * weight
            b += B * weight
            total += weight
        }
        guard total > 0 else { return nil }
        var h: CGFloat = 0, s: CGFloat = 0, v: CGFloat = 0, a: CGFloat = 0
        UIColor(red: r / total, green: g / total, blue: b / total, alpha: 1).getHue(&h, saturation: &s, brightness: &v, alpha: &a)
        return Color(hue: Double(h), saturation: Double(Swift.min(s * 0.85, 0.5)), brightness: Double(0.11 + 0.1 * v))
    }
}

extension View {
    /// Liquid Glass on iOS 26 (when built with its SDK); the frosted material before that.
    @ViewBuilder
    func latentGlass<S: Shape>(in shape: S, tint: Color? = nil, interactive: Bool = false) -> some View {
        #if compiler(>=6.2)
        if #available(iOS 26.0, *) {
            self.glassEffect(Glass.regular.tint(tint).interactive(interactive), in: shape)
        } else {
            self.background(.ultraThinMaterial, in: shape)
        }
        #else
        self.background(.ultraThinMaterial, in: shape)
        #endif
    }
}
