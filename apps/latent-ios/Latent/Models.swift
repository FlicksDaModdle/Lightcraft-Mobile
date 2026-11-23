import CoreGraphics
import Foundation

/// A photo in the library.
struct Photo: Identifiable, Hashable {
    let id: UInt64
    let fileName: String
    let edited: Bool

    init?(_ json: Any) {
        guard let d = json as? [String: Any], let id = (d["id"] as? NSNumber)?.uint64Value else { return nil }
        self.id = id
        fileName = d["fileName"] as? String ?? ""
        edited = d["edited"] as? Bool ?? false
    }
}

/// How a slider's track is coloured.
enum Track: Equatable {
    case plain, centered, temp, tint, rainbow
    case gradient(String, String)
    case hue(Int), sat(Int), lum(Int)

    init(_ json: Any?) {
        let d = json as? [String: Any] ?? [:]
        let band = (d["band"] as? NSNumber)?.intValue ?? 0
        switch d["kind"] as? String {
        case "centered": self = .centered
        case "temp": self = .temp
        case "tint": self = .tint
        case "rainbow": self = .rainbow
        case "gradient": self = .gradient(d["from"] as? String ?? "#808080", d["to"] as? String ?? "#808080")
        case "hue": self = .hue(band)
        case "sat": self = .sat(band)
        case "lum": self = .lum(band)
        default: self = .plain
        }
    }
}

/// One develop slider, as the engine describes it (`develop.controls`).
struct Control: Identifiable, Equatable {
    let id: String
    let label: String
    let section: String
    let min: Double
    let max: Double
    let defaultValue: Double
    let step: Double
    let decimals: Int
    let track: Track
    var value: Double

    init?(_ json: Any) {
        guard let d = json as? [String: Any], let id = d["id"] as? String else { return nil }
        self.id = id
        label = d["label"] as? String ?? id
        section = d["section"] as? String ?? ""
        min = (d["min"] as? NSNumber)?.doubleValue ?? 0
        max = (d["max"] as? NSNumber)?.doubleValue ?? 1
        defaultValue = (d["default"] as? NSNumber)?.doubleValue ?? 0
        step = (d["step"] as? NSNumber)?.doubleValue ?? 1
        decimals = (d["decimals"] as? NSNumber)?.intValue ?? 0
        track = Track(d["track"])
        value = (d["value"] as? NSNumber)?.doubleValue ?? defaultValue
    }

    /// A slider the app makes itself (the crop's straighten angle, a preset's amount).
    init(id: String, label: String, min: Double, max: Double, defaultValue: Double, step: Double, decimals: Int, value: Double) {
        self.id = id
        self.label = label
        section = ""
        self.min = min
        self.max = max
        self.defaultValue = defaultValue
        self.step = step
        self.decimals = decimals
        track = .centered
        self.value = value
    }

    var changed: Bool { abs(value - defaultValue) > 1e-9 }

    /// The value as the panel shows it: its decimals, a plus sign on two-sided sliders, no "-0".
    func format(_ v: Double) -> String {
        var s = String(format: "%.\(decimals)f", v)
        if !s.contains(where: { "123456789".contains($0) }) {
            s = s.replacingOccurrences(of: "-", with: "")
            return s
        }
        if v > 0 && min < 0 { s = "+" + s }
        return s
    }

    // The Kelvin temperature has the middle of its track at 7000 K and a logarithmic right half,
    // like the engine's ControlSpec::position.
    private static let kelvinCentre = 7000.0
    private static let kelvinKnee = 1000.0
    private var kelvin: (centre: Double, right: Double)? {
        guard id == "wb.temp", min < Self.kelvinCentre, Self.kelvinCentre < max else { return nil }
        return (Self.kelvinCentre, log(1 + (max - Self.kelvinCentre) / Self.kelvinKnee))
    }

    /// Where `v` sits on the track, 0 at the left end to 1 at the right.
    func position(_ v: Double) -> Double {
        let v = Swift.min(Swift.max(v, min), max)
        let p: Double
        if let k = kelvin {
            p = v > k.centre ? 0.5 + 0.5 * log(1 + (v - k.centre) / Self.kelvinKnee) / k.right : 0.5 * (v - min) / (k.centre - min)
        } else {
            p = (v - min) / Swift.max(max - min, 1e-9)
        }
        return p.isFinite ? Swift.min(Swift.max(p, 0), 1) : 0
    }

    /// The value at track position `p`, on the control's steps.
    func value(at p: Double) -> Double {
        let p = Swift.min(Swift.max(p.isFinite ? p : 0, 0), 1)
        var v: Double
        if let k = kelvin {
            if p >= 1 { v = max } else if p > 0.5 { v = k.centre + Self.kelvinKnee * (exp((2 * p - 1) * k.right) - 1) } else { v = min + 2 * p * (k.centre - min) }
        } else {
            v = min + p * (max - min)
        }
        if step > 0 { v = (v / step).rounded() * step }
        return Swift.min(Swift.max(v, min), max)
    }
}

/// The editing tools along the bottom of the editor.
enum Tool: String, CaseIterable, Identifiable {
    case light, color, effects, detail, optics, geometry
    /// Steps inside Color, not in the strip.
    case mixer, grading, curve

    /// The tools along the strip.
    static let strip: [Tool] = [.light, .color, .effects, .detail, .optics, .geometry]

    var id: String { rawValue }

    var label: String {
        switch self {
        case .light: "Light"
        case .color: "Color"
        case .effects: "Effects"
        case .detail: "Detail"
        case .optics: "Optics"
        case .geometry: "Geometry"
        case .mixer: "Color mix"
        case .grading: "Color grading"
        case .curve: "Curve"
        }
    }

    var symbol: String {
        switch self {
        case .light: "sun.max"
        case .color: "thermometer.medium"
        case .effects: "camera.filters"
        case .detail: "triangle"
        case .optics: "camera.aperture"
        case .geometry: "perspective"
        case .mixer: "paintpalette"
        case .grading: "circle.lefthalf.filled"
        case .curve: "chart.line.uptrend.xyaxis"
        }
    }

    /// The engine sections whose sliders the tool shows.
    var sections: [String] {
        switch self {
        case .light: ["light"]
        case .color: ["color"]
        case .effects: ["effects", "vignette", "grain"]
        case .detail: ["detail"]
        case .optics: ["optics"]
        case .geometry: ["geometry"]
        case .mixer: ["mixer"]
        case .grading: ["grading"]
        case .curve: []
        }
    }

    /// Tabs across the top of the panel: a name and the control ids (by prefix) each shows.
    var tabs: [(name: String, prefixes: [String])] {
        switch self {
        case .effects: [("Effects", ["effects."]), ("Vignette", ["vignette."]), ("Grain", ["grain."])]
        case .detail:
            [("Sharpening", ["detail.sharpen"]), ("Noise", ["detail.nrLuminance", "detail.nrDetail", "detail.nrContrast"]), ("Color noise", ["detail.nrColor"])]
        default: []
        }
    }
}

/// White balance presets the engine knows (`develop.wb` modes).
let whiteBalanceModes: [(mode: String, label: String)] = [
    ("asShot", "As shot"), ("auto", "Auto"), ("daylight", "Daylight"), ("cloudy", "Cloudy"),
    ("shade", "Shade"), ("tungsten", "Tungsten"), ("fluorescent", "Fluorescent"), ("flash", "Flash"),
]

/// The colour mixer's bands, in the engine's order (control ids are `mixer.<band>.hue` and so on).
let mixerBands = ["red", "orange", "yellow", "green", "aqua", "blue", "purple", "magenta"]

/// The colour grading ranges (control ids `grading.<range>.hue`/`.sat`/`.lum`).
let gradingRanges: [(id: String, label: String)] = [("shadows", "Shadows"), ("midtones", "Midtones"), ("highlights", "Highlights"), ("global", "Global")]

/// Crop aspect choices: the engine's `crop.aspect` value and what the chip says.
let cropAspects: [(value: String, label: String)] = [
    ("original", "Original"), ("free", "Free"), ("1x1", "1:1"), ("4x5", "4:5"), ("5x7", "5:7"),
    ("2x3", "2:3"), ("3x4", "3:4"), ("9x16", "9:16"), ("16x9", "16:9"),
]

/// A preset from the engine (`presets.list`).
struct Preset: Identifiable, Hashable {
    let id: String
    let name: String
    let group: String

    init?(_ json: Any) {
        guard let d = json as? [String: Any], let id = d["id"] as? String else { return nil }
        self.id = id
        name = d["name"] as? String ?? id
        group = d["group"] as? String ?? ""
    }
}

/// The editing modes along the bottom.
enum Mode: String, CaseIterable {
    case quick, presets, crop, edit, masks, remove

    var label: String {
        switch self {
        case .quick: "Quick actions"
        case .presets: "Presets"
        case .crop: "Crop"
        case .edit: "Edit"
        case .masks: "Masks"
        case .remove: "Remove"
        }
    }

    var symbol: String {
        switch self {
        case .quick: "sparkles"
        case .presets: "circle.hexagongrid"
        case .crop: "crop.rotate"
        case .edit: "slider.horizontal.3"
        case .masks: "circle.dashed.inset.filled"
        case .remove: "bandage"
        }
    }

    /// Whether this build has the mode.
    var available: Bool { [.presets, .crop, .edit].contains(self) }
}

/// The point curve's channels: the engine's name, what it's called, and its colour.
let curveChannels: [(id: String, label: String, color: (Double, Double, Double))] = [
    ("master", "All", (0.92, 0.92, 0.92)), ("red", "Red", (0.9, 0.24, 0.24)),
    ("green", "Green", (0.25, 0.75, 0.3)), ("blue", "Blue", (0.28, 0.48, 0.95)),
]

/// A monotone cubic through the points (x ascending), the shape the engine draws the curve with.
struct MonotoneCurve {
    private let xs: [Double]
    private let ys: [Double]
    private let ms: [Double]

    init(_ points: [CGPoint]) {
        let p = points.sorted { $0.x < $1.x }
        xs = p.map { Double($0.x) }
        ys = p.map { Double($0.y) }
        let n = xs.count
        guard n >= 2 else {
            ms = []
            return
        }
        var d = [Double](repeating: 0, count: n - 1)
        for i in 0..<(n - 1) {
            let dx = xs[i + 1] - xs[i]
            d[i] = dx > 0 ? (ys[i + 1] - ys[i]) / dx : 0
        }
        var m = [Double](repeating: 0, count: n)
        m[0] = d[0]
        m[n - 1] = d[n - 2]
        if n > 2 {
            for i in 1..<(n - 1) { m[i] = d[i - 1] * d[i] <= 0 ? 0 : (d[i - 1] + d[i]) / 2 }
        }
        // Fritsch–Carlson: keep each piece from overshooting
        for i in 0..<(n - 1) where d[i] != 0 {
            let a = m[i] / d[i]
            let b = m[i + 1] / d[i]
            let s = a * a + b * b
            if s > 9 {
                let t = 3 / s.squareRoot()
                m[i] = t * a * d[i]
                m[i + 1] = t * b * d[i]
            }
        }
        ms = m
    }

    func callAsFunction(_ x: Double) -> Double {
        guard xs.count >= 2 else { return x }
        if x <= xs[0] { return ys[0] }
        if x >= xs[xs.count - 1] { return ys[ys.count - 1] }
        var i = 0
        while i < xs.count - 2 && x > xs[i + 1] { i += 1 }
        let h = xs[i + 1] - xs[i]
        guard h > 0 else { return ys[i] }
        let t = (x - xs[i]) / h
        let t2 = t * t
        let t3 = t2 * t
        return (2 * t3 - 3 * t2 + 1) * ys[i] + (t3 - 2 * t2 + t) * h * ms[i] + (-2 * t3 + 3 * t2) * ys[i + 1] + (t3 - t2) * h * ms[i + 1]
    }
}
