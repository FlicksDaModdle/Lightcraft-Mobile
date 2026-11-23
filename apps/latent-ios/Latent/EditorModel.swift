import CoreGraphics
import SwiftUI
import UIKit

/// One photo being edited: its sliders (from the engine), the render, and undo state.
@MainActor
final class EditorModel: ObservableObject {
    let photo: Photo

    @Published private(set) var image: CGImage?
    @Published private(set) var original: CGImage?
    @Published private(set) var histogram: [UInt32] = []
    @Published private(set) var controls: [String: Control] = [:]
    @Published private(set) var order: [String] = []
    @Published private(set) var bw = false
    @Published private(set) var wbMode = "asShot"
    @Published private(set) var canUndo = false
    @Published private(set) var canRedo = false
    @Published var tool: Tool = .light { didSet { if tool != oldValue { tab = 0 } } }
    @Published var tab = 0
    @Published var toast: String?
    /// The slider being dragged: everything else fades so the photo can be seen.
    @Published private(set) var active: String?
    @Published var mode: Mode = .edit
    @Published var mixerBand = 0
    @Published var gradingRange = 0
    @Published private(set) var presets: [Preset] = []
    @Published var presetGroup = ""
    @Published private(set) var appliedPreset: String?
    @Published private(set) var presetAmount = 100.0
    @Published private(set) var cropAngle = 0.0
    @Published private(set) var cropAspect: [Int]?
    @Published var curveChannel = 0
    /// Each channel's curve points (0…1 both ways); an empty list is the straight line.
    @Published private(set) var curves: [String: [CGPoint]] = [:]

    private var rendering = false
    private var dirty = false
    private let renderSize: CGSize

    init(photo: Photo) {
        self.photo = photo
        let screen = UIScreen.main.bounds.size
        let long = Swift.min(Swift.max(screen.width, screen.height) * UIScreen.main.scale, 2048)
        renderSize = CGSize(width: long, height: long)
    }

    func open() {
        attempt("library.select", ["ids": [photo.id], "active": photo.id])
        refresh()
        render()
    }

    /// The sliders the current tool (and tab) shows, in the engine's order.
    var visible: [Control] {
        let sections = Set(tool.sections)
        var prefixes = tool.tabs.indices.contains(tab) ? tool.tabs[tab].prefixes : nil
        if tool == .mixer { prefixes = ["mixer.\(mixerBands[mixerBand])."] }
        if tool == .grading {
            let r = gradingRanges[gradingRange].id
            prefixes = ["grading.\(r)."] + (r == "global" ? [] : ["grading.blending", "grading.balance"])
        }
        return order.compactMap { controls[$0] }.filter { c in
            sections.contains(c.section) && (prefixes?.contains(where: { c.id.hasPrefix($0) }) ?? true)
        }
    }

    /// Whether the tool has changed the photo (for the dot under it).
    func edited(_ t: Tool) -> Bool {
        var sections = Set(t.sections)
        if t == .color { sections.formUnion(["mixer", "grading"]) }
        return controls.values.contains { sections.contains($0.section) && $0.changed } || (t == .color && bw) || (t == .light && curveEdited)
    }

    // MARK: editing

    func begin(_ c: Control) {
        active = c.id
        attempt("develop.beginInteraction", ["label": c.label])
    }

    func set(_ c: Control, _ value: Double) {
        controls[c.id]?.value = value
        attempt("develop.set", ["control": c.id, "value": value])
        render()
    }

    func end() {
        active = nil
        attempt("develop.endInteraction")
        refreshHistory()
    }

    /// Set a control without a drag (the grading wheel sets two at once).
    func setQuietly(_ id: String, _ value: Double) {
        controls[id]?.value = value
        attempt("develop.set", ["control": id, "value": value])
    }

    func beginWheel() {
        active = "wheel"
        attempt("develop.beginInteraction", ["label": "Color Grading"])
    }

    // MARK: curve

    /// The points of the open channel; the two ends when it has none yet.
    var curvePoints: [CGPoint] {
        let pts = curves[curveChannels[curveChannel].id] ?? []
        return pts.count >= 2 ? pts.sorted { $0.x < $1.x } : [CGPoint(x: 0, y: 0), CGPoint(x: 1, y: 1)]
    }

    var curveEdited: Bool {
        curves.values.contains { pts in pts.count >= 2 && pts.contains { abs($0.x - $0.y) > 1e-6 } }
    }

    func beginCurve() {
        active = "curve"
        attempt("develop.beginInteraction", ["label": "Tone Curve"])
    }

    func setCurve(_ points: [CGPoint]) {
        let id = curveChannels[curveChannel].id
        curves[id] = points
        attempt("develop.curve", ["channel": id, "points": points.map { [Double($0.x), Double($0.y)] }])
        render()
    }

    func resetCurve() {
        command("curve.reset", ["channel": curveChannels[curveChannel].id])
    }

    /// What is being changed, for the label over the photo while dragging.
    var readout: String? {
        guard let a = active else { return nil }
        switch a {
        case "curve": return "Curve"
        case "wheel":
            let r = gradingRanges[gradingRange]
            let h = Int(controls["grading.\(r.id).hue"]?.value ?? 0)
            let s = Int(controls["grading.\(r.id).sat"]?.value ?? 0)
            return "\(r.label)  \(h)°  \(s)"
        case "preset.amount": return "Amount  \(Int(presetAmount))"
        case "crop.angle": return "Straighten  \(angleControl.format(cropAngle))°"
        default:
            guard let c = controls[a] else { return nil }
            return "\(c.label)  \(c.format(c.value))"
        }
    }

    // MARK: presets

    var presetGroups: [String] {
        var seen: [String] = []
        for p in presets where !seen.contains(p.group) { seen.append(p.group) }
        return seen
    }

    func loadPresets() {
        guard presets.isEmpty else { return }
        let list = (try? Engine.shared.run("presets.list")) as? [Any] ?? []
        presets = list.compactMap(Preset.init)
        if presetGroup.isEmpty { presetGroup = presetGroups.first ?? "" }
    }

    func apply(_ p: Preset) {
        appliedPreset = p.id
        presetAmount = 100
        command("preset.apply", ["id": p.id, "amount": 100])
    }

    var amountControl: Control {
        Control(id: "preset.amount", label: "Amount", min: 0, max: 200, defaultValue: 100, step: 1, decimals: 0, value: presetAmount)
    }

    func beginAmount() {
        active = "preset.amount"
        attempt("develop.beginInteraction", ["label": "Preset Amount"])
    }

    func setAmount(_ v: Double) {
        guard let id = appliedPreset else { return }
        presetAmount = v
        attempt("preset.apply", ["id": id, "amount": v])
        render()
    }

    // MARK: crop

    var angleControl: Control {
        Control(id: "crop.angle", label: "Straighten", min: -45, max: 45, defaultValue: 0, step: 0.1, decimals: 1, value: cropAngle)
    }

    func beginAngle() {
        active = "crop.angle"
        attempt("develop.beginInteraction", ["label": "Straighten"])
    }

    func setAngle(_ v: Double) {
        cropAngle = v
        attempt("crop.set", ["angle": v])
        render()
    }

    @Published private var chosenAspect: String?

    func setAspect(_ value: String) {
        chosenAspect = value
        command("crop.aspect", ["aspect": value])
    }
    func cropCommand(_ name: String) { command(name) }

    /// Which aspect chip is on.
    var aspectChoice: String {
        if let c = chosenAspect { return c }
        guard let a = cropAspect, a.count == 2, a[0] > 0, a[1] > 0 else { return "original" }
        let g = gcd(a[0], a[1])
        return "\(a[0] / g)x\(a[1] / g)"
    }

    private func gcd(_ a: Int, _ b: Int) -> Int { b == 0 ? Swift.max(a, 1) : gcd(b, a % b) }

    func reset(_ c: Control) {
        begin(c)
        set(c, c.defaultValue)
        end()
    }

    func auto() { command("develop.auto", toast: "Auto settings applied") }
    func resetAll() { command("develop.reset", toast: "Edits reset") }
    func undo() { command("edit.undo") }
    func redo() { command("edit.redo") }
    func setBW(_ on: Bool) { command("develop.treatment", ["bw": on]) }
    func setWhiteBalance(_ mode: String) { command("develop.wb", ["mode": mode]) }

    func command(_ name: String, _ params: [String: Any] = [:], toast message: String? = nil) {
        if attempt(name, params), let message { toast = message }
        refresh()
        render()
    }

    @discardableResult
    private func attempt(_ name: String, _ params: [String: Any] = [:]) -> Bool {
        do {
            try Engine.shared.run(name, params)
            return true
        } catch {
            toast = error.localizedDescription
            return false
        }
    }

    // MARK: state from the engine

    func refresh() {
        let list = (try? Engine.shared.run("develop.controls")) as? [Any] ?? []
        var map: [String: Control] = [:]
        var ids: [String] = []
        for c in list.compactMap(Control.init) where map[c.id] == nil {
            map[c.id] = c
            ids.append(c.id)
        }
        controls = map
        order = ids
        if let s = (try? Engine.shared.run("develop.get", ["id": photo.id])) as? [String: Any] {
            bw = (s["treatment"] as? String) == "bw"
            wbMode = ((s["wb"] as? [String: Any])?["mode"] as? String) ?? "asShot"
            let crop = s["crop"] as? [String: Any]
            cropAngle = ((crop?["geometry"] as? [String: Any])?["angle"] as? NSNumber)?.doubleValue ?? 0
            cropAspect = (crop?["aspect"] as? [NSNumber])?.map(\.intValue)
            let curve = s["curve"] as? [String: Any] ?? [:]
            var read: [String: [CGPoint]] = [:]
            for ch in curveChannels {
                let pts = (curve[ch.id] as? [[String: Any]] ?? []).compactMap { p -> CGPoint? in
                    guard let x = (p["x"] as? NSNumber)?.doubleValue, let y = (p["y"] as? NSNumber)?.doubleValue else { return nil }
                    return CGPoint(x: x, y: y)
                }
                read[ch.id] = pts
            }
            curves = read
        }
        refreshHistory()
    }

    private func refreshHistory() {
        guard let st = (try? Engine.shared.run("library.state")) as? [String: Any] else { return }
        canUndo = st["undo"] is String
        canRedo = st["redo"] is String
    }

    // MARK: rendering

    /// Render the photo again; while a render is running, the next one waits for it, and only the
    /// latest settings are rendered.
    func render() {
        if rendering {
            dirty = true
            return
        }
        rendering = true
        let id = photo.id
        let size = renderSize
        Task {
            let r = await Task.detached(priority: .userInitiated) { Engine.shared.render(id, fitting: size) }.value
            if let r {
                image = r.image
                histogram = r.histogram
            } else if image == nil {
                toast = "This photo could not be rendered"
            }
            rendering = false
            if dirty {
                dirty = false
                render()
            }
        }
    }

    /// The photo before any edit, for press-and-hold.
    func loadOriginal() {
        guard original == nil else { return }
        let id = photo.id
        let size = renderSize
        Task {
            original = await Task.detached(priority: .userInitiated) { Engine.shared.render(id, fitting: size, original: true)?.image }.value
        }
    }
}
