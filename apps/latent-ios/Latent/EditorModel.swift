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
            if mode == .crop {
                cropEntry = historyCursor()
                cropTab = 0
            }
            if mode == .remove {
                removeEntry = historyCursor()
                selectedSpot = nil
            }
            if mode == .masks {
                masksEntry = historyCursor()
                selectedPart = 0
                refreshThumbs()
            }
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
    @Published var selectedMask: UInt32? {
        didSet {
            if selectedMask != oldValue {
                selectedPart = 0
                render()
            }
        }
    }
    /// The part of the selected mask being edited (index into its parts).
    @Published var selectedPart = 0
    /// Which adjustment group the masks panel shows (index into `maskGroups`).
    @Published var maskGroup = 0
    /// How the selected mask is drawn over the photo.
    @Published var maskLook = EditorModel.savedMaskLook() {
        didSet {
            UserDefaults.standard.set(maskLook.view, forKey: "maskLook.view")
            UserDefaults.standard.set(Int(maskLook.rgb), forKey: "maskLook.rgb")
            UserDefaults.standard.set(maskLook.opacity, forKey: "maskLook.opacity")
            render()
        }
    }
    /// Small white-on-black pictures of each mask, for the masks column.
    @Published private(set) var maskThumbs: [UInt32: CGImage] = [:]
    /// Colour range: a tap adds a colour instead of replacing them.
    @Published var addColorSample = false
    private var masksEntry: Int?
    private var thumbTask: Task<Void, Never>?

    private static func savedMaskLook() -> MaskLook {
        let d = UserDefaults.standard
        var look = MaskLook()
        if let v = d.string(forKey: "maskLook.view") { look.view = v }
        if d.object(forKey: "maskLook.rgb") != nil { look.rgb = UInt32(clamping: d.integer(forKey: "maskLook.rgb")) }
        if d.object(forKey: "maskLook.opacity") != nil { look.opacity = d.integer(forKey: "maskLook.opacity") }
        return look
    }
    /// The red overlay showing where the selected mask applies.
    @Published var maskOverlay = true { didSet { render() } }
    @Published var brushErase = false
    /// Brush size (fraction of the long edge), feather and flow.
    @Published var brushSize = 0.04
    @Published var brushFeather = 50.0
    @Published var brushFlow = 100.0
    /// Object masks: taps leave a part out instead of adding it.
    @Published var objectExclude = false
    /// AI work (an object or a description being found) is running.
    @Published private(set) var aiBusy = false
    @Published var aiModel = AIModelStatus()
    @Published var showAIModels = false
    private var poller: Task<Void, Never>?
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
    private let baseRenderSize: CGSize
    /// Bigger renders while zoomed in, so the photo stays sharp.
    private var detail: CGFloat = 1
    private var renderSize: CGSize { CGSize(width: baseRenderSize.width * detail, height: baseRenderSize.height * detail) }

    init(photo: Photo) {
        self.photo = photo
        let screen = UIScreen.main.bounds.size
        let long = Swift.min(Swift.max(screen.width, screen.height) * UIScreen.main.scale, 2048)
        baseRenderSize = CGSize(width: long, height: long)
    }

    func open() {
        attempt("library.select", ["ids": [photo.id], "active": photo.id])
        loadDepth()
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
        if mode == .masks { refreshThumbs() }
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

    /// The part being edited (the first when the index is out of range).
    var currentPart: MaskPart? {
        guard let m = currentMask else { return nil }
        return m.parts.indices.contains(selectedPart) ? m.parts[selectedPart] : m.parts.first
    }

    /// Add a mask of `kind` and select it.
    func addMask(_ kind: String) {
        if maskTools.first(where: { $0.kind == kind })?.ai == true {
            addAIMask(kind)
            return
        }
        do {
            let r = try Engine.shared.run("mask.add", ["kind": kind]) as? [String: Any]
            refresh()
            selectedMask = (r?["activeMask"] as? NSNumber)?.uint32Value
            selectedPart = 0
            mode = .masks
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            if kind == "colorRange" { toast = "Tap a colour in the photo to select everywhere it appears." }
            if kind == "luminanceRange" { toast = "Tap the photo to pick a brightness, then adjust the range." }
            if kind == "depthRange" { toast = depth == nil ? "This photo has no depth map yet. Make one in Blur." : "Tap the photo to pick a depth, then adjust the range." }
            render()
            refreshThumbs()
        } catch {
            toast = error.localizedDescription
        }
    }

    /// Add a part to the selected mask: `op` "add", "subtract" or "intersect".
    func addPart(_ kind: String, op: String, text: String? = nil) {
        guard let id = selectedMask else { return }
        let ai = maskTools.first(where: { $0.kind == kind })?.ai ?? false
        if ai {
            refreshAIModel()
            guard aiModel.installed else {
                showAIModels = true
                return
            }
        }
        var p: [String: Any] = ["id": id, "op": op, "kind": kind]
        if let text { p["text"] = text }
        do {
            let r = try Engine.shared.run("mask.addComponent", p) as? [String: Any]
            refreshMasksOnly()
            refreshHistory()
            selectedPart = Swift.max((currentMask?.parts.count ?? 1) - 1, 0)
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            if kind == "object" { toast = op == "subtract" ? "Tap what to take out of the mask." : "Tap what to add to the mask." }
            if kind == "colorRange" { toast = "Tap a colour in the photo." }
            if r?["pending"] as? Bool == true { toast = "Looking for \u{201C}\(text ?? "")\u{201D}\u{2026}" }
            if ai { watchAI() }
            render()
            refreshThumbs()
        } catch {
            toast = error.localizedDescription
        }
    }

    /// Change the selected part: "invert", "duplicate", "delete", or "op" with `op`.
    func partCommand(_ action: String, op: String? = nil) {
        guard let id = selectedMask else { return }
        var p: [String: Any] = ["id": id, "component": selectedPart, "action": action]
        if let op { p["op"] = op }
        guard attempt("mask.component", p) else { return }
        refresh()
        if selectedMask != nil, !masks.contains(where: { $0.id == selectedMask }) { selectedMask = masks.last?.id }
        if action == "delete" { selectedPart = Swift.max(selectedPart - 1, 0) }
        if action == "duplicate" { selectedPart += 1 }
        render()
        refreshThumbs()
    }

    /// Colour range: take the colour at a point (mask coordinates).
    func sampleColor(_ at: CGPoint) {
        guard let id = selectedMask else { return }
        guard attempt("mask.sampleColor", ["id": id, "component": selectedPart, "x": at.x, "y": at.y, "add": addColorSample]) else { return }
        UISelectionFeedbackGenerator().selectionChanged()
        refreshMasksOnly()
        refreshHistory()
        render()
        refreshThumbs()
    }

    /// Set every adjustment of the selected mask back to none.
    func resetMaskAdjustments() {
        guard let id = selectedMask else { return }
        var values: [String: Double] = [:]
        for a in maskAdjustments { values[a.key] = 0 }
        if attempt("mask.adjust", ["id": id, "values": values]) {
            refreshMasksOnly()
            refreshHistory()
            render()
        }
    }

    /// ✕: take back every change made since Masking opened.
    func cancelMasks() {
        undoBack(to: masksEntry)
        mode = .edit
        refresh()
        render()
    }

    func doneMasks() { mode = .edit }

    /// Draw the small mask pictures again, a moment after the last change.
    func refreshThumbs() {
        thumbTask?.cancel()
        let id = photo.id
        let list = masks.map(\.id)
        thumbTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 250_000_000)
            guard !Task.isCancelled else { return }
            var out: [UInt32: CGImage] = [:]
            for m in list {
                let img = await Task.detached(priority: .utility) {
                    Engine.shared.renderMask(id, mask: m, fitting: CGSize(width: 132, height: 132), look: MaskLook(view: "whiteOnBlack", rgb: 0xFFFFFF, opacity: 100))?.image
                }.value
                if let img { out[m] = img }
            }
            guard !Task.isCancelled, let self else { return }
            self.maskThumbs = out
        }
    }

    func refreshAIModel() {
        aiModel = AIModelStatus((try? Engine.shared.run("segment.model.status")) ?? [:])
    }

    /// Masks that need the SAM 3 model: an object picked by tapping, or one described in words.
    /// Without the model, the AI models screen explains how to add it.
    func addAIMask(_ kind: String, text: String? = nil) {
        refreshAIModel()
        guard aiModel.installed else {
            showAIModels = true
            return
        }
        var p: [String: Any] = ["kind": kind]
        if let text { p["text"] = text }
        do {
            let r = try Engine.shared.run("mask.add", p) as? [String: Any]
            refresh()
            if let id = (r?["activeMask"] as? NSNumber)?.uint32Value { selectedMask = id }
            if kind == "object" { toast = "Tap what to select. The first selection loads the AI model, which takes a moment." }
            if r?["pending"] as? Bool == true { toast = "Looking for \u{201C}\(text ?? "")\u{201D}\u{2026}" }
            watchAI()
        } catch {
            toast = error.localizedDescription
        }
    }

    /// A tap on the photo for the selected Object mask (mask coordinates).
    func objectPoint(_ p: CGPoint) {
        refreshAIModel()
        if !aiModel.installed, SelectionModel.installed, currentPart?.kind == "object" {
            refineObject(p)
            return
        }
        guard let id = selectedMask else { return }
        do {
            try Engine.shared.run("mask.objectPoint", ["id": id, "x": p.x, "y": p.y, "exclude": objectExclude])
            refreshMasksOnly()
            refreshHistory()
            watchAI()
        } catch {
            toast = error.localizedDescription
        }
    }

    /// Poll the engine while AI work runs, then show the result (or what went wrong).
    func watchAI() {
        aiBusy = true
        poller?.cancel()
        poller = Task { [weak self] in
            var idle = 0
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 300_000_000)
                guard let self else { return }
                let r = await Task.detached { Engine.shared.poll() }.value
                if r.changed {
                    self.refreshMasksOnly()
                    self.refreshHistory()
                    self.render()
                    self.refreshThumbs()
                }
                if let m = r.messages.last { self.toast = m }
                idle = r.busy ? 0 : idle + 1
                if idle >= 2 {
                    self.aiBusy = false
                    self.render()
                    return
                }
            }
        }
    }

    func selectMask(_ id: UInt32) {
        attempt("mask.select", ["id": id])
        UISelectionFeedbackGenerator().selectionChanged()
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
        refreshThumbs()
    }

    /// Replace the selected part's shape: a gradient being drawn, a range being set.
    func updateMaskShape(_ shape: [String: Any]) {
        guard let id = selectedMask else { return }
        attempt("mask.update", ["id": id, "component": selectedPart, "shape": shape])
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
        undoBack(to: presetsEntry)
        appliedPreset = nil
        mode = .edit
        refresh()
        render()
    }

    /// Undo, one step at a time, back to a history position (stopping if the history stops moving back).
    private func undoBack(to entry: Int?) {
        guard let entry else { return }
        var last = Int.max
        while let c = historyCursor(), c > entry, c < last {
            last = c
            attempt("edit.undo")
        }
    }

    // MARK: crop mode

    private var cropEntry: Int?
    /// Aspect or Geometry.
    @Published var cropTab = 0
    /// The shape last chosen by name (Story, 4 × 5…), shown as the crop's title.
    @Published private(set) var shapeName: String?

    /// ✕: take back every change made since Crop opened.
    func cancelCrop() {
        undoBack(to: cropEntry)
        shapeName = nil
        mode = .edit
        refresh()
        render()
    }

    func doneCrop() { mode = .edit }

    func chooseShape(_ shape: CropShape) {
        var p: [String: Any] = ["aspect": shape.aspect]
        if shape.given { p["orientation"] = "given" }
        UISelectionFeedbackGenerator().selectionChanged()
        if attempt("crop.aspect", p) { shapeName = shape.name }
        refresh()
        render()
    }

    func originalShape() {
        if attempt("crop.aspect", ["aspect": "original"]) { shapeName = "Original" }
        refresh()
        render()
    }

    /// Lock the crop to its shape, or set it free.
    func toggleAspectLock() {
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        let wasLocked = cropAspect != nil
        if attempt("crop.aspect", ["aspect": "toggle"]) { shapeName = wasLocked ? nil : shapeName }
        refresh()
    }

    var aspectLocked: Bool { cropAspect != nil }

    /// The crop's title: the shape's name, or its ratio.
    var cropTitle: String {
        guard let a = cropAspect, a.count == 2, a[0] > 0, a[1] > 0 else { return "Free" }
        if let n = shapeName { return n }
        let g = gcd(a[0], a[1])
        let w = a[0] / g, h = a[1] / g
        return w <= 32 && h <= 32 ? "\(w) \u{00D7} \(h)" : "Custom"
    }

    /// The geometry sliders (perspective, rotation, scale…) for the crop's Geometry tab.
    var geometryControls: [Control] {
        order.compactMap { controls[$0] }.filter { Tool.geometry.sections.contains($0.section) }
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

    // MARK: blur

    /// Lens blur is on, and what stays sharp: a mask, or (none) the subject or a fixed shape.
    @Published private(set) var blurOn = false
    @Published private(set) var focusMask: UInt32?
    @Published private(set) var focusShape = "auto"

    private func mergeBlur(_ patch: [String: Any], _ label: String) {
        if attempt("develop.merge", ["settings": ["lens_blur": patch], "label": label]) {
            refresh()
            render()
        }
    }

    func setBlur(_ on: Bool) {
        var patch: [String: Any] = ["enabled": on]
        // switched on with nothing set yet: a blur you can see
        if on, (controls["lensBlur.amount"]?.value ?? 0) == 0 { patch["amount"] = 50.0 }
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        mergeBlur(patch, "Lens Blur")
    }

    /// Keep the subject (shape "auto"), a fixed shape ("round", "wide", "tall") or a mask sharp.
    func setFocus(shape: String? = nil, mask: UInt32? = nil) {
        var patch: [String: Any] = ["focus_mask": mask.map { NSNumber(value: $0) } ?? NSNull(), "focal_range": 0.0]
        if let shape { patch["shape"] = shape }
        mergeBlur(patch, "Lens Blur Focus")
    }

    /// Select the subject with the AI model, where the camera focused if the file says, and keep it sharp.
    func findBlurSubject() {
        refreshAIModel()
        guard aiModel.installed else {
            showAIModels = true
            return
        }
        do {
            try Engine.shared.run("lensBlur.findSubject")
            toast = "Finding the subject\u{2026}"
            refresh()
            watchAI()
            render()
        } catch {
            toast = error.localizedDescription
        }
    }

    // MARK: depth

    /// The photo's depth map, when it has one (from the iPhone, or estimated).
    @Published private(set) var depth: DepthMap?
    /// Looking for one, or estimating it.
    @Published private(set) var depthBusy = false
    @Published private(set) var focalDistance = 0.0
    @Published private(set) var focalRange = 0.0
    /// Blur by depth (a Focus Range) rather than by the subject.
    var depthBlur: Bool { depth != nil && focalRange > 0 && focusMask == nil && focusShape == "auto" }
    /// The next tap on the photo sets the focus distance.
    @Published var tapToFocus = false
    /// The photo is shown as its depth map (near white).
    @Published var showDepth = false { didSet { renderDepthView() } }
    @Published private(set) var depthView: CGImage?
    @Published var showDepthModel = false

    /// The saved depth map, else the one the iPhone recorded with the file.
    private func loadDepth() {
        let id = photo.id
        if let m = DepthMaps.cached(id) {
            depth = m
            Engine.shared.setDepth(id, m)
            return
        }
        depthBusy = true
        Task {
            let m = await Task.detached(priority: .utility) { () -> DepthMap? in
                guard let url = DepthMaps.path(of: id), let m = DepthMaps.fromCamera(url) else { return nil }
                DepthMaps.save(id, m)
                return m
            }.value
            depthBusy = false
            if let m {
                depth = m
                Engine.shared.setDepth(id, m)
                if blurOn { render() }
            }
        }
    }

    /// Estimate the depth with the depth model (getting it first if needed).
    func estimateDepth() {
        guard DepthModel.installed else {
            showDepthModel = true
            return
        }
        guard !depthBusy else { return }
        depthBusy = true
        let id = photo.id
        Task {
            let r: Result<DepthMap, Error> = await Task.detached(priority: .userInitiated) {
                Result {
                    guard let url = DepthMaps.path(of: id) else { throw EngineError(message: "This photo's file can't be found.") }
                    return try DepthMaps.estimate(url)
                }
            }.value
            depthBusy = false
            switch r {
            case .success(let m):
                DepthMaps.save(id, m)
                depth = m
                Engine.shared.setDepth(id, m)
                UINotificationFeedbackGenerator().notificationOccurred(.success)
                if focalRange == 0 { useDepth() } else { render() }
                renderDepthView()
            case .failure(let e):
                toast = e.localizedDescription
            }
        }
    }

    /// Forget the depth map (a new estimate can be made).
    func removeDepth() {
        DepthMaps.forget(photo.id)
        Engine.shared.setDepth(photo.id, nil)
        depth = nil
        showDepth = false
        let patch: [String: Any] = ["focal_range": 0.0]
        mergeBlur(patch, "Lens Blur Focus")
    }

    /// Blur by depth: a range around the nearest busy depths to start with.
    func useDepth() {
        guard let d = depth else { return }
        // start at the nearest fifth with something in it
        let h = d.histogram
        let first = h.firstIndex { $0 > 0.15 } ?? 0
        let c = Swift.min(Double(first) / Double(Swift.max(h.count, 1)) * 100 + 10, 90)
        var patch: [String: Any] = ["focal_distance": c, "focal_range": 20.0, "focus_mask": NSNull(), "shape": "auto", "enabled": true]
        if (controls["lensBlur.amount"]?.value ?? 0) == 0 { patch["amount"] = 50.0 }
        mergeBlur(patch, "Lens Blur Focus")
    }

    func useSubject() {
        let patch: [String: Any] = ["focal_range": 0.0]
        mergeBlur(patch, "Lens Blur Focus")
    }

    func beginFocusRange() {
        active = "focus.range"
        attempt("develop.beginInteraction", ["label": "Focus Range"])
    }

    /// The Focus Range moved (0 near … 100 far).
    func setFocusRange(_ lo: Double, _ hi: Double) {
        let lo = Swift.min(Swift.max(lo, 0), 100), hi = Swift.min(Swift.max(hi, lo + 1), 100)
        focalDistance = (lo + hi) / 2
        focalRange = hi - lo
        if attempt("develop.merge", ["settings": ["lens_blur": ["focal_distance": focalDistance, "focal_range": focalRange]], "label": "Focus Range"]) {
            render()
        }
    }

    /// A tap on the photo (shown picture, 0…1 across and down) with Tap to focus on.
    func focus(atShown u: CGPoint) {
        guard depth != nil else { return }
        Task {
            guard let v = await depthValue(atShown: u) else { return }
            let half = Swift.max(focalRange, 12) / 2
            let c = Swift.min(Swift.max(v * 100, half), 100 - half)
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            let patch: [String: Any] = ["focal_distance": c, "focal_range": half * 2, "focus_mask": NSNull(), "shape": "auto"]
            mergeBlur(patch, "Focus Here")
            tapToFocus = false
        }
    }

    /// The depth (0 near … 1 far) at a point of the shown picture, read from the depth map as the
    /// engine frames it (crop, rotation, straightening and flips included).
    func depthValue(atShown u: CGPoint) async -> Double? {
        let id = photo.id
        guard let img = await Task.detached(priority: .userInitiated, operation: { Engine.shared.renderDepth(id, fitting: CGSize(width: 320, height: 320)) }).value,
              let b = Self.pixel(img, at: u)
        else { return nil }
        // the view shows nearness as 1 − smoothstep(depth): undo the smoothstep
        let s = Swift.min(Swift.max(1 - (b.r + b.g + b.b) / 3, 0), 1)
        return 0.5 - sin(asin(1 - 2 * s) / 3)
    }

    /// The brightness (0…1 on the luminance range's scale, −8…+4 EV) at a point of the shown picture.
    func brightness(atShown u: CGPoint) async -> Double? {
        let id = photo.id
        guard let r = await Task.detached(priority: .userInitiated, operation: { Engine.shared.render(id, fitting: CGSize(width: 320, height: 320)) }).value,
              let p = Self.pixel(r.image, at: u)
        else { return nil }
        let lin = { (v: Double) in v <= 0.04045 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4) }
        let y = 0.2126 * lin(p.r) + 0.7152 * lin(p.g) + 0.0722 * lin(p.b)
        return Swift.min(Swift.max((log2(Swift.max(y, 1e-6)) + 8) / 12, 0), 1)
    }

    /// One pixel's colour (0…1) at a point of an image (0…1 across and down).
    static func pixel(_ img: CGImage, at u: CGPoint) -> (r: Double, g: Double, b: Double)? {
        guard img.width > 0, img.height > 0, (0...1).contains(u.x), (0...1).contains(u.y),
              let space = CGColorSpace(name: CGColorSpace.sRGB)
        else { return nil }
        var px = [UInt8](repeating: 0, count: 4)
        let ok: Bool = px.withUnsafeMutableBytes { buf in
            guard let ctx = CGContext(data: buf.baseAddress, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4, space: space,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
            else { return false }
            let x = Swift.min(Int(u.x * CGFloat(img.width)), img.width - 1)
            let y = Swift.min(Int(u.y * CGFloat(img.height)), img.height - 1)
            // draw so pixel (x, y) (top-down) lands on the one-pixel context
            ctx.draw(img, in: CGRect(x: -x, y: -(img.height - 1 - y), width: img.width, height: img.height))
            return true
        }
        guard ok else { return nil }
        return (Double(px[0]) / 255, Double(px[1]) / 255, Double(px[2]) / 255)
    }

    /// A tap with a brightness or depth range part selected: centre its range on what was tapped.
    func pickRange(atShown u: CGPoint) {
        guard let part = currentPart else { return }
        Task {
            var shape = part.shape
            switch part.kind {
            case "luminanceRange":
                guard let y = await brightness(atShown: u) else { return }
                let half = Swift.max(((part.number("hi", 1) - part.number("lo", 0.6)) / 2), 0.08)
                shape["lo"] = Swift.max(y - half, 0)
                shape["hi"] = Swift.min(y + half, 1)
            case "depthRange":
                guard let d = await depthValue(atShown: u) else {
                    toast = "This photo has no depth map yet. Make one in Blur."
                    return
                }
                let half = Swift.max(((part.number("hi", 0.3) - part.number("lo", 0)) / 2), 0.06)
                shape["lo"] = Swift.max(d - half, 0)
                shape["hi"] = Swift.min(d + half, 1)
            default:
                return
            }
            UISelectionFeedbackGenerator().selectionChanged()
            beginMask("Pick Range")
            updateMaskShape(shape)
            end()
        }
    }

    private func renderDepthView() {
        guard showDepth, depth != nil else {
            depthView = nil
            return
        }
        let id = photo.id
        let size = renderSize
        Task {
            depthView = await Task.detached(priority: .userInitiated) { Engine.shared.renderDepth(id, fitting: size) }.value
        }
    }

    // MARK: profiles

    /// The profile browser is open in place of the sliders.
    @Published var profilesOpen = false
    @Published private(set) var profiles: [ProfileItem] = []
    @Published private(set) var profileID = "lc.color"
    @Published private(set) var profileAmount = 100.0
    @Published var profileGroup = ""
    private var profilesEntry: Int?

    var profileName: String { profiles.first { $0.id == profileID }?.name ?? "Profile" }

    var profileGroups: [String] {
        var out: [String] = profiles.contains(where: \.favorite) ? ["Favorites"] : []
        for p in profiles where !out.contains(p.group) { out.append(p.group) }
        return out
    }

    func profiles(in group: String) -> [ProfileItem] {
        group == "Favorites" ? profiles.filter(\.favorite) : profiles.filter { $0.group == group }
    }

    func loadProfiles() {
        profiles = ((try? Engine.shared.run("profiles.list")) as? [Any] ?? []).compactMap(ProfileItem.init)
    }

    func openProfiles() {
        loadProfiles()
        profilesEntry = historyCursor()
        profileGroup = profiles.first { $0.id == profileID }?.group ?? profileGroups.first ?? ""
        withAnimation(.glass) { profilesOpen = true }
    }

    func cancelProfiles() {
        undoBack(to: profilesEntry)
        refresh()
        render()
        withAnimation(.glass) { profilesOpen = false }
    }

    func doneProfiles() { withAnimation(.glass) { profilesOpen = false } }

    func applyProfile(_ p: ProfileItem) {
        guard p.id != profileID else { return }
        UISelectionFeedbackGenerator().selectionChanged()
        command("develop.profile", ["id": p.id])
    }

    var profileAmountControl: Control {
        Control(id: "profile.amount", label: "Amount", min: 0, max: 200, defaultValue: 100, step: 1, decimals: 0, value: profileAmount)
    }

    func beginProfileAmount() {
        active = "profile.amount"
        attempt("develop.beginInteraction", ["label": "Profile Amount"])
    }

    func setProfileAmount(_ v: Double) {
        profileAmount = v
        if attempt("develop.profile", ["id": profileID, "amount": v]) { render() }
    }

    func favoriteProfile(_ p: ProfileItem) {
        attempt("profile.favorite", ["id": p.id, "favorite": !p.favorite])
        loadProfiles()
    }

    func deleteProfile(_ p: ProfileItem) {
        guard attempt("profile.deleteImported", ["id": p.id]) else { return }
        loadProfiles()
        refresh()
        render()
        if profiles(in: profileGroup).isEmpty { profileGroup = profileGroups.first ?? "" }
    }

    /// Import `.cube` LUTs (files, folders or zips the Files picker chose) as profiles.
    func importLUTs(_ urls: [URL]) {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("LUTs-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        var paths: [String] = []
        for u in urls {
            let scoped = u.startAccessingSecurityScopedResource()
            defer { if scoped { u.stopAccessingSecurityScopedResource() } }
            let dest = tmp.appendingPathComponent(u.lastPathComponent)
            if (try? FileManager.default.copyItem(at: u, to: dest)) != nil { paths.append(dest.path) }
        }
        guard !paths.isEmpty else {
            toast = "Those files couldn't be read."
            return
        }
        do {
            let r = try Engine.shared.run("profile.import", ["paths": paths]) as? [String: Any]
            let done = (r?["imported"] as? [[String: Any]]) ?? []
            let failed = (r?["failed"] as? [Any])?.count ?? 0
            loadProfiles()
            if let g = done.first?["group"] as? String { profileGroup = g }
            UINotificationFeedbackGenerator().notificationOccurred(done.isEmpty ? .error : .success)
            if done.isEmpty {
                toast = "No LUTs found. Latent reads .cube files, folders of them, and .zip files."
            } else {
                toast = "Imported \(done.count) LUT\(done.count == 1 ? "" : "s")" + (failed > 0 ? " (\(failed) couldn't be read)" : "")
            }
        } catch {
            toast = error.localizedDescription
        }
        try? FileManager.default.removeItem(at: tmp)
    }

    // MARK: picking an object

    /// What the next tap on the photo picks an object for: "remove", or a mask ("new", "add",
    /// "subtract"). Nil when taps do their usual thing.
    @Published var pickingObject: String?
    @Published private(set) var picking = false

    @Published var showSelectionModel = false

    func startPicking(_ purpose: String) {
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        pickingObject = purpose
        toast = SelectionModel.installed ? "Tap what to select." : "Tap a person, animal or thing. (The object selection model selects anything, more exactly.)"
    }

    /// The uncropped picture's cache key for the selection model (it has the flips).
    private var selectionKey: String { "\(photo.id)-\(flipH)-\(flipV)" }

    /// The object at `p` (picture coordinates, 0…1) as coverage, by the best way available: the
    /// selection model (a square grid over the stretched picture), else Vision (the picture's own
    /// pixels). `taps` are earlier ones to keep (selection model only).
    private func findObject(at p: CGPoint, taps: [(CGPoint, Bool)] = []) async -> Result<(values: [Float], width: Int, height: Int)?, Error> {
        let id = photo.id
        let key = selectionKey
        let useModel = SelectionModel.installed
        return await Task.detached(priority: .userInitiated) {
            Result {
                guard let img = Engine.shared.renderUncropped(id, fitting: CGSize(width: 1024, height: 1024))?.image else { return nil }
                if useModel {
                    guard let r = try Sam2.select(img, key: key, points: taps + [(p, true)]) else { return nil }
                    let c = Sam2.coverage(r.values)
                    // nothing selected comes back as an empty mask
                    guard c.contains(where: { $0 > 0.5 }) else { return nil }
                    return (c, r.side, r.side)
                }
                return try ObjectPicker.object(in: img, at: p)
            }
        }.value
    }

    /// Another tap on a selection-model object part: add it (or, with Leave out, take it away)
    /// and select again with every tap so far.
    func refineObject(_ m: CGPoint) {
        guard let part = currentPart, part.kind == "object", SelectionModel.installed else { return }
        let (fh, fv) = (flipH, flipV)
        let flip = { (q: CGPoint) in CGPoint(x: fh ? 1 - q.x : q.x, y: fv ? 1 - q.y : q.y) }
        let read = { (key: String) -> [CGPoint] in
            (part.shape[key] as? [[String: Any]] ?? []).compactMap { d in
                guard let x = (d["x"] as? NSNumber)?.doubleValue, let y = (d["y"] as? NSNumber)?.doubleValue else { return nil }
                return CGPoint(x: x, y: y)
            }
        }
        var hint = read("hint"), exclude = read("exclude")
        if objectExclude { exclude.append(m) } else { hint.append(m) }
        guard let first = hint.first else { return }
        let taps = hint.dropFirst().map { (flip($0), true) } + exclude.map { (flip($0), false) }
        let id = photo.id
        let key = selectionKey
        picking = true
        Task {
            let r: Result<(values: [Float], side: Int)?, Error> = await Task.detached(priority: .userInitiated) {
                Result {
                    guard let img = Engine.shared.renderUncropped(id, fitting: CGSize(width: 1024, height: 1024))?.image else { return nil }
                    return try Sam2.select(img, key: key, points: [(flip(first), true)] + taps)
                }
            }.value
            picking = false
            guard case .success(let found?) = r else {
                if case .failure(let e) = r { toast = e.localizedDescription }
                return
            }
            let c = (values: Sam2.coverage(found.values), width: found.side, height: found.side)
            guard let seg = Engine.shared.segmentation(side: 256, probs: ObjectPicker.grid(c, side: 256, place: flip)) else { return }
            var shape = part.shape
            shape["hint"] = hint.map { ["x": $0.x, "y": $0.y] }
            shape["exclude"] = exclude.map { ["x": $0.x, "y": $0.y] }
            shape["seg"] = seg
            shape["detail"] = [Any]()
            UISelectionFeedbackGenerator().selectionChanged()
            beginMask("Select Object")
            updateMaskShape(shape)
            end()
        }
    }

    /// The tap (shown picture, 0…1): find the object there and remove it, or mask it.
    func pickObject(atShown u: CGPoint) {
        guard let purpose = pickingObject else { return }
        pickingObject = nil
        let m = toMask(u)
        let (fh, fv) = (flipH, flipV)
        // the uncropped picture has the flips; mask coordinates don't
        let flip = { (q: CGPoint) in CGPoint(x: fh ? 1 - q.x : q.x, y: fv ? 1 - q.y : q.y) }
        picking = true
        let aspect = photoAspect
        Task {
            let found = await findObject(at: flip(m))
            picking = false
            guard case .success(let c?) = found else {
                if case .failure(let e) = found { toast = e.localizedDescription } else { toast = "No person, animal or thing found there. Try tapping its middle." }
                return
            }
            UINotificationFeedbackGenerator().notificationOccurred(.success)
            if purpose == "remove" {
                // the model's square grid back to the picture's shape, for round dabs
                let shaped = c.width == c.height && SelectionModel.installed ? Sam2.unstretched(c.values, side: c.width, aspect: aspect) : c
                guard let s = ObjectPicker.spot(shaped) else { return }
                let keep = (spotMode, spotSize)
                spotMode = InpaintModel.installed ? "generate" : "fill"
                spotSize = s.size
                addSpot(s.points.map(flip))
                (spotMode, spotSize) = keep
                if !InpaintModel.installed { toast = "Filled from the surroundings. Get the AI remove model for a better fill." }
            } else {
                let probs = ObjectPicker.grid(c, side: 256, place: flip)
                do {
                    let op = purpose == "new" ? "add" : purpose
                    let mid = try Engine.shared.objectFromCoverage(mask: purpose == "new" ? nil : selectedMask, op: op, side: 256, probs: probs, at: m)
                    refresh()
                    selectedMask = mid
                    selectedPart = Swift.max((currentMask?.parts.count ?? 1) - 1, 0)
                    if mode != .masks { mode = .masks }
                    render()
                    refreshThumbs()
                } catch {
                    toast = error.localizedDescription
                }
            }
        }
    }

    // MARK: zoom

    /// Two fingers are on the photo: drawing tools stop so the pinch doesn't paint.
    @Published var pinching = false

    /// The editor's zoom changed: render bigger past 1.5×, back to screen size near 1×.
    func zoomChanged(_ zoom: CGFloat) {
        let want: CGFloat = zoom > 1.5 ? Swift.min(2, 4096 / Swift.max(baseRenderSize.width, 1)) : 1
        guard abs(want - detail) > 0.01 else { return }
        detail = want
        render()
    }

    // MARK: remove

    @Published private(set) var spots: [SpotItem] = []
    @Published var selectedSpot: Int? {
        didSet {
            guard selectedSpot != oldValue else { return }
            attempt("spot.select", ["index": selectedSpot.map { $0 as Any } ?? NSNull()])
            if let i = selectedSpot, spots.indices.contains(i) {
                let sp = spots[i]
                spotMode = sp.mode
                spotSize = sp.size
                spotFeather = sp.feather
                spotOpacity = sp.opacity
            }
        }
    }
    /// Settings for the next spot (and the selected one).
    @Published var spotMode = "remove"
    @Published var spotSize = 0.02
    @Published var spotFeather = 50.0
    @Published var spotOpacity = 100.0
    /// Draw the spots' outlines over the photo.
    @Published var showSpots = true
    private var removeEntry: Int?

    /// A tap (one point) or a brushed path over what to take away, in mask coordinates.
    func addSpot(_ points: [CGPoint]) {
        guard !points.isEmpty else { return }
        do {
            let r = try Engine.shared.run("spot.add", [
                "mode": spotMode, "points": points.map { [Double($0.x), Double($0.y)] },
                "size": spotSize, "feather": spotFeather, "opacity": spotOpacity,
            ]) as? [String: Any]
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            refresh()
            if let i = (r?["index"] as? NSNumber)?.intValue { selectedSpot = i }
            render()
        } catch {
            toast = error.localizedDescription
        }
    }

    /// Change the selected spot (during a drag: between beginSpot and end).
    func updateSpot(_ params: [String: Any]) {
        guard let i = selectedSpot else { return }
        var p = params
        p["index"] = i
        attempt("spot.update", p)
        refreshSpots()
        render()
    }

    func beginSpot(_ label: String) {
        active = "spot.\(label)"
        attempt("develop.beginInteraction", ["label": label])
    }

    /// A setting slider moved: it sets the next spot, and the selected one.
    func spotSetting(_ key: String, _ value: Double) {
        switch key {
        case "size": spotSize = value
        case "feather": spotFeather = value
        default: spotOpacity = value
        }
        if selectedSpot != nil { updateSpot([key: value]) }
    }

    @Published var showInpaintModel = false

    /// The AI remove model just arrived: hand it to the engine and show the spots it rebuilds.
    func inpaintModelInstalled() {
        Inpainting.register()
        Thumbnails.shared.forgetPresets()
        render()
    }

    func setSpotMode(_ mode: String) {
        if mode == "generate", !InpaintModel.installed, spotMode == "generate" || selectedSpot == nil { showInpaintModel = true }
        spotMode = mode
        UISelectionFeedbackGenerator().selectionChanged()
        if selectedSpot != nil {
            attempt("spot.update", ["index": selectedSpot ?? 0, "mode": mode])
            refresh()
            render()
        }
    }

    func deleteSpot() {
        guard let i = selectedSpot else { return }
        if attempt("spot.delete", ["index": i]) {
            selectedSpot = nil
            refresh()
            render()
        }
    }

    /// Pick another source for the selected spot.
    func newSource() {
        guard let i = selectedSpot else { return }
        if attempt("spot.refreshSource", ["index": i]) {
            refresh()
            render()
        }
    }

    /// Find sensor dust and fix each speck.
    func findDust() {
        do {
            let r = try Engine.shared.run("spot.findDust", [:]) as? [String: Any]
            let n = (r?["added"] as? NSNumber)?.intValue ?? 0
            toast = n == 0 ? "No dust found" : "Fixed \(n) dust spot\(n == 1 ? "" : "s")"
            refresh()
            render()
        } catch {
            toast = error.localizedDescription
        }
    }

    func cancelRemove() {
        undoBack(to: removeEntry)
        selectedSpot = nil
        mode = .edit
        refresh()
        render()
    }

    func doneRemove() {
        selectedSpot = nil
        mode = .edit
    }

    private func refreshSpots() {
        guard let s = (try? Engine.shared.run("develop.get", ["id": photo.id])) as? [String: Any] else { return }
        spots = (s["spots"] as? [Any] ?? []).compactMap(SpotItem.init)
    }

    // MARK: export and settings between photos

    /// Edits were copied in this session (the engine keeps them until the app quits).
    private static var copied = false
    @Published private(set) var canPaste = EditorModel.copied
    /// A quick save is running.
    @Published private(set) var saving = false

    /// Save the photo to Photos with the export settings.
    func saveToPhotos() {
        guard !saving else { return }
        saving = true
        let id = photo.id
        let settings = ExportPrefs.shared.settings
        Task {
            do {
                let files = try await Exporter.run([id], settings: settings)
                try await Exporter.saveToPhotos(files)
                UINotificationFeedbackGenerator().notificationOccurred(.success)
                toast = "Saved to Photos (\(settings.summary))"
            } catch {
                UINotificationFeedbackGenerator().notificationOccurred(.error)
                toast = error.localizedDescription
            }
            saving = false
        }
    }

    func copySettings() {
        guard attempt("develop.copy") else { return }
        Self.copied = true
        canPaste = true
        toast = "Edits copied (crop, masks and spots stay with this photo)"
    }

    func pasteSettings() {
        guard attempt("develop.paste", ["ids": [photo.id]]) else { return }
        afterBulkChange("Edits pasted")
    }

    func applyPrevious() {
        guard attempt("develop.pastePrevious", ["ids": [photo.id]]) else { return }
        afterBulkChange("Edits from the previous photo applied")
    }

    private func afterBulkChange(_ message: String) {
        Thumbnails.shared.forgetPresets()
        refresh()
        render()
        toast = message
    }

    /// The photo's file and camera details.
    func info() -> [String: Any]? {
        (try? Engine.shared.run("photo.inspect", ["id": photo.id])) as? [String: Any]
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
            spots = (s["spots"] as? [Any] ?? []).compactMap(SpotItem.init)
            let prof = s["profile"] as? [String: Any] ?? [:]
            profileID = prof["id"] as? String ?? "lc.color"
            profileAmount = (prof["amount"] as? NSNumber)?.doubleValue ?? 100
            let lb = s["lens_blur"] as? [String: Any] ?? [:]
            blurOn = lb["enabled"] as? Bool ?? false
            focusMask = (lb["focus_mask"] as? NSNumber)?.uint32Value
            focusShape = lb["shape"] as? String ?? "auto"
            focalDistance = (lb["focal_distance"] as? NSNumber)?.doubleValue ?? 0
            focalRange = (lb["focal_range"] as? NSNumber)?.doubleValue ?? 0
            if let i = selectedSpot, !spots.indices.contains(i) { selectedSpot = nil }
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
        let look = maskLook
        Task {
            let wantHDR = hdr
            let r = await Task.detached(priority: .userInitiated) {
                if cropping { return Engine.shared.renderUncropped(id, fitting: size) }
                if let m = overlay { return Engine.shared.renderMask(id, mask: m, fitting: size, look: look) }
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
