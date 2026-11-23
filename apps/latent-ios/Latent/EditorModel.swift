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
        let prefixes = tool.tabs.indices.contains(tab) ? tool.tabs[tab].prefixes : nil
        return order.compactMap { controls[$0] }.filter { c in
            sections.contains(c.section) && (prefixes?.contains(where: { c.id.hasPrefix($0) }) ?? true)
        }
    }

    /// Whether the tool has changed the photo (for the dot under it).
    func edited(_ t: Tool) -> Bool {
        let sections = Set(t.sections)
        return controls.values.contains { sections.contains($0.section) && $0.changed } || (t == .color && bw)
    }

    // MARK: editing

    func begin(_ c: Control) { attempt("develop.beginInteraction", ["label": c.label]) }

    func set(_ c: Control, _ value: Double) {
        controls[c.id]?.value = value
        attempt("develop.set", ["control": c.id, "value": value])
        render()
    }

    func end() {
        attempt("develop.endInteraction")
        refreshHistory()
    }

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

    private func command(_ name: String, _ params: [String: Any] = [:], toast message: String? = nil) {
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
