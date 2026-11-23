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
    @Published var mode: Mode = .edit {
        didSet {
            guard mode != oldValue else { return }
            if mode == .presets { enterPresets() }
            // the crop box is drawn over the whole photo; every other mode shows the result
            render()
        }
    }
    /// Crop mode's picture: the whole photo, uncropped and unstraightened.
    @Published private(set) var fullImage: CGImage?
    /// The crop box in the straightened frame (0…1), and the flips, from the engine.
    @Published private(set) var cropRect = CGRect(x: 0, y: 0, width: 1, height: 1)
    @Published private(set) var flipH = false
    @Published private(set) var flipV = false
    @Published private(set) var masks: [MaskItem] = []
    @Published var selectedMask: UInt32? { didSet { if selectedMask != oldValue { render() } } }
    /// The red overlay showing where the selected mask applies.
    @Published var maskOverlay = true { didSet { render() } }
    @Published var brushErase = false
    /// Brush size (fraction of the long edge), feather and flow.
    @Published var brushSize = 0.04
    @Published var brushFeather = 50.0
    @Published var brushFlow = 100.0
    @Published var mixerBand = 0
    @Published var gradingRange = 0
    @Published private(set) var presets: [Preset] = []
    @Published var presetGroup = ""
    @Published private(set) var appliedPreset: String?
    @Published private(set) var presetAmount = 100.0
    @Published private(set) var cropAngle = 0.0
    @Published private(set) var cropAspect: [Int]?
    @Published var curveChannel = 0
    /// HDR editing is on for the photo; `headroom` is how many stops above white it may reach.
    @Published private(set) var hdr = false
    @Published private(set) var headroom = 3.0
    /// The picture on screen is an HDR render (and the histogram is the HDR one).
    @Published private(set) var showingHDR = false
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
                && (hdr || !c.id.hasPrefix("hdr."))
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

    // MARK: masks

    var currentMask: MaskItem? { masks.first { $0.id == selectedMask } }

    /// Add a mask of `kind` (brush, linear, radial) and select it.
    func addMask(_ kind: String) {
        do {
            let r = try Engine.shared.run("mask.add", ["kind": kind]) as? [String: Any]
            refresh()
            selectedMask = (r?["activeMask"] as? NSNumber)?.uint32Value
            mode = .masks
            render()
        } catch {
            toast = error.localizedDescription
        }
    }

    func selectMask(_ id: UInt32) {
        attempt("mask.select", ["id": id])
        selectedMask = id
    }

    func maskCommand(_ name: String, _ params: [String: Any] = [:]) {
        guard let id = selectedMask else { return }
        var p = params
        p["id"] = id
        command(name, p)
    }

    func maskControl(_ a: (key: String, label: String, min: Double, max: Double, step: Double, decimals: Int, track: Track)) -> Control {
        Control(id: "mask.\(a.key)", label: a.label, min: a.min, max: a.max, defaultValue: 0, step: a.step, decimals: a.decimals,
                value: currentMask?.adjust[a.key] ?? 0, track: a.track)
    }

    func beginMask(_ label: String) {
        active = "mask.\(label)"
        attempt("develop.beginInteraction", ["label": label])
    }

    /// Set one of the selected mask's adjustments (during a drag: between beginMask and end).
    func adjustMask(_ key: String, _ value: Double) {
        guard let id = selectedMask else { return }
        attempt("mask.adjust", ["id": id, "values": [key: value]])
        refreshMasksOnly()
        render()
    }

    /// Paint (or erase) one brush stroke through `points` (mask coordinates).
    func brushStroke(_ points: [CGPoint]) {
        guard let id = selectedMask, !points.isEmpty else { return }
        attempt("mask.brushStroke", [
            "id": id, "points": points.map { [Double($0.x), Double($0.y)] }, "size": brushSize, "feather": brushFeather,
            "flow": brushFlow, "erase": brushErase,
        ])
        refreshMasksOnly()
        refreshHistory()
        render()
    }

    /// Replace the selected mask's (first) shape: a gradient being drawn.
    func updateMaskShape(_ shape: [String: Any]) {
        guard let id = selectedMask else { return }
        attempt("mask.update", ["id": id, "shape": shape])
        refreshMasksOnly()
        render()
    }

    private func refreshMasksOnly() {
        guard let s = (try? Engine.shared.run("develop.get", ["id": photo.id])) as? [String: Any] else { return }
        masks = (s["masks"] as? [Any] ?? []).compactMap(MaskItem.init)
    }

    // Mask coordinates are on the photo as oriented, normalized to its width and height; the
    // editor shows it cropped, straightened and flipped. These go between the two (`u` is a point
    // on the shown picture, 0…1 across and down).

    /// Width over height of the whole oriented photo.
    var photoAspect: CGFloat {
        guard let img = image, cropRect.width > 0, cropRect.height > 0, img.height > 0 else { return 1 }
        return (CGFloat(img.width) / cropRect.width) / (CGFloat(img.height) / cropRect.height)
    }

    func toMask(_ u: CGPoint) -> CGPoint {
        let x = flipH ? 1 - u.x : u.x
        let y = flipV ? 1 - u.y : u.y
        let fx = cropRect.minX + x * cropRect.width
        let fy = cropRect.minY + y * cropRect.height
        let a = -cropAngle * .pi / 180
        let (w, h) = (photoAspect, CGFloat(1))
        let dx = (fx - 0.5) * w
        let dy = (fy - 0.5) * h
        return CGPoint(x: (dx * cos(a) - dy * sin(a)) / w + 0.5, y: (dx * sin(a) + dy * cos(a)) / h + 0.5)
    }

    func fromMask(_ m: CGPoint) -> CGPoint {
        let a = cropAngle * .pi / 180
        let (w, h) = (photoAspect, CGFloat(1))
        let dx = (m.x - 0.5) * w
        let dy = (m.y - 0.5) * h
        let fx = (dx * cos(a) - dy * sin(a)) / w + 0.5
        let fy = (dx * sin(a) + dy * cos(a)) / h + 0.5
        var x = (fx - cropRect.minX) / Swift.max(cropRect.width, 1e-6)
        var y = (fy - cropRect.minY) / Swift.max(cropRect.height, 1e-6)
        if flipH { x = 1 - x }
        if flipV { y = 1 - y }
        return CGPoint(x: x, y: y)
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
        case let m where m.hasPrefix("mask."):
            let key = String(m.dropFirst(5))
            if let a = maskAdjustments.first(where: { $0.key == key }) {
                let c = maskControl(a)
                return "\(c.label)  \(c.format(c.value))"
            }
            return nil
        default:
            guard let c = controls[a] else { return nil }
            return "\(c.label)  \(c.format(c.value))"
        }
    }

    // MARK: presets

    /// The groups, favourites first (when there are any), then as the engine lists them.
    var presetGroups: [String] {
        var seen: [String] = presets.contains { $0.favorite } ? [favoritesGroup] : []
        for p in presets where !seen.contains(p.group) { seen.append(p.group) }
        return seen
    }

    func presets(in group: String) -> [Preset] {
        group == favoritesGroup ? presets.filter(\.favorite) : presets.filter { $0.group == group }
    }

    /// Where the history stood when Presets opened: ✕ goes back there.
    private var presetsEntry: Int?

    private func historyCursor() -> Int? {
        ((try? Engine.shared.run("history.list")) as? [String: Any])?["cursor"] as? Int
    }

    private func enterPresets() {
        presetsEntry = historyCursor()
        appliedPreset = nil
        presetGroup = ""
        Thumbnails.shared.forgetPresets()
        loadPresets(force: true)
    }

    func loadPresets(force: Bool = false) {
        guard force || presets.isEmpty else { return }
        let list = (try? Engine.shared.run("presets.list")) as? [Any] ?? []
        presets = list.compactMap(Preset.init)
    }

    /// ✕: take back every preset applied since Presets opened.
    func cancelPresets() {
        if let entry = presetsEntry {
            // one undo at a time, stopping if the history stops moving back
            var last = Int.max
            while let c = historyCursor(), c > entry, c < last {
                last = c
                attempt("edit.undo")
            }
        }
        appliedPreset = nil
        mode = .edit
        refresh()
        render()
    }

    func donePresets() {
        appliedPreset = nil
        mode = .edit
    }

    func setFavorite(_ p: Preset, _ on: Bool) {
        attempt("preset.favorite", ["id": p.id, "favorite": on])
        loadPresets(force: true)
    }

    func deletePreset(_ p: Preset) {
        attempt("preset.delete", ["id": p.id])
        if appliedPreset == p.id { appliedPreset = nil }
        loadPresets(force: true)
    }

    /// Save the current edit as a preset in User Presets.
    func createPreset(_ name: String) {
        let n = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !n.isEmpty else { return }
        if attempt("preset.create", ["name": n]) { toast = "Saved preset \u{201C}\(n)\u{201D}" }
        loadPresets(force: true)
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
        // the box turns over the unturned photo: nothing to render
        refreshCrop()
    }

    /// Drag a crop handle (`topLeft`…`left`, or `move`) from `from` to `to`, both in the straightened
    /// frame, starting from the box as it was at the drag's start. The engine keeps it on the photo
    /// and to the aspect lock.
    func dragCrop(_ handle: String, from: CGPoint, to: CGPoint, start: CGRect) {
        attempt("crop.drag", [
            "handle": handle, "from": [from.x, from.y], "to": [to.x, to.y],
            "start": [start.minX, start.minY, start.maxX, start.maxY],
        ])
        refreshCrop()
    }

    func beginCrop() {
        active = "crop.box"
        attempt("develop.beginInteraction", ["label": "Crop"])
    }

    private func refreshCrop() {
        guard let s = (try? Engine.shared.run("develop.get", ["id": photo.id])) as? [String: Any] else { return }
        readCrop(s)
    }

    private func readCrop(_ s: [String: Any]) {
        let crop = s["crop"] as? [String: Any]
        let geo = crop?["geometry"] as? [String: Any]
        cropAngle = (geo?["angle"] as? NSNumber)?.doubleValue ?? 0
        cropAspect = (crop?["aspect"] as? [NSNumber])?.map(\.intValue)
        flipH = crop?["flip_h"] as? Bool ?? false
        flipV = crop?["flip_v"] as? Bool ?? false
        if let r = geo?["rect"] as? [String: Any] {
            let v = { (k: String) in CGFloat((r[k] as? NSNumber)?.doubleValue ?? 0) }
            cropRect = CGRect(x: v("x0"), y: v("y0"), width: v("x1") - v("x0"), height: v("y1") - v("y0"))
        }
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
    func setHDR(_ on: Bool) { command("develop.hdr", ["enabled": on], toast: on ? "HDR on" : "HDR off") }
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
            readCrop(s)
            masks = (s["masks"] as? [Any] ?? []).compactMap(MaskItem.init)
            if let sel = selectedMask, !masks.contains(where: { $0.id == sel }) { selectedMask = nil }
            let h = s["hdr"] as? [String: Any]
            hdr = h?["enabled"] as? Bool ?? false
            headroom = (h?["max_ev"] as? NSNumber)?.doubleValue ?? 3
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
        let cropping = mode == .crop
        let overlay: UInt32? = (mode == .masks && maskOverlay) ? selectedMask : nil
        Task {
            let wantHDR = hdr
            let r = await Task.detached(priority: .userInitiated) {
                if cropping { return Engine.shared.renderUncropped(id, fitting: size) }
                if let m = overlay { return Engine.shared.renderMask(id, mask: m, fitting: size) }
                return (wantHDR ? Engine.shared.renderHDR(id, fitting: size) : nil) ?? Engine.shared.render(id, fitting: size)
            }.value
            if cropping, let r {
                fullImage = r.image
            } else if let r {
                image = r.image
                histogram = r.histogram
                showingHDR = r.peak > 1
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
