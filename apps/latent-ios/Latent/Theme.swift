import SwiftUI

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
