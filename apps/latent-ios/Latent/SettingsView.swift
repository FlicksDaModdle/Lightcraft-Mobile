import SwiftUI

/// Settings: the optional AI models (download or delete each), face models, place names, export defaults and
/// presets, the library's housekeeping, and About.
struct SettingsView: View {
    @ObservedObject var library: Library
    @ObservedObject private var export = ExportPrefs.shared
    @Environment(\.dismiss) private var dismiss
    @State private var models: [ModelState] = []
    @State private var model: ModelSpec?
    @State private var faceModels: [(id: String, name: String, installed: Bool)] = []
    @State private var placeNames = false
    @State private var editingExport = false
    @State private var confirmEmpty = false
    @State private var notice: String?
    @State private var gpu = true
    @State private var showAbout = false

    struct ModelState: Identifiable {
        let spec: ModelSpec
        let installed: Bool
        var id: String { spec.name }
    }

    private let specs: [ModelSpec] = [DepthModel, InpaintModel, InpaintModelLite, SelectionModel, DenoiseModel]

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    ForEach(models) { m in
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(m.spec.title)
                                Text(m.installed ? "Installed" : m.spec.size).font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            if m.installed {
                                Button("Delete", role: .destructive) {
                                    m.spec.remove()
                                    refresh()
                                }
                                .buttonStyle(.borderless)
                            } else {
                                Button("Get") { model = m.spec }.buttonStyle(.borderless)
                            }
                        }
                    }
                } header: {
                    Text("AI models")
                } footer: {
                    Text("Each runs on this iPhone and is downloaded only when you ask. Deleting one frees its space; the feature then asks for it again.")
                }

                Section {
                    ForEach(faceModels, id: \.id) { f in
                        HStack {
                            Text(f.name)
                            Spacer()
                            if f.installed {
                                Button("Delete", role: .destructive) {
                                    _ = try? Engine.shared.run("faces.models.remove", ["id": f.id])
                                    refresh()
                                }
                                .buttonStyle(.borderless)
                            } else {
                                Text("Not installed").foregroundStyle(.secondary)
                            }
                        }
                    }
                    HStack {
                        Text("Place names (GeoNames)")
                        Spacer()
                        Text(placeNames ? "Downloaded" : "Not downloaded").foregroundStyle(.secondary)
                    }
                } header: {
                    Text("People and Places")
                } footer: {
                    Text("Face models are downloaded from the People tab, place names from the Places tab. Place names: GeoNames, CC-BY 4.0.")
                }

                Section("Export") {
                    Button { editingExport = true } label: {
                        HStack {
                            Text("Default export settings").foregroundStyle(.primary)
                            Spacer()
                            Text(export.settings.summary).foregroundStyle(.secondary).lineLimit(1)
                        }
                    }
                    NavigationLink("Export presets") { ExportPresetsView() }
                }

                Section {
                    Toggle("Render on the GPU", isOn: $gpu)
                        .onChange(of: gpu) { _, on in _ = try? Engine.shared.run("app.gpu", ["enabled": on]) }
                    Button("Empty Recently Deleted", role: .destructive) { confirmEmpty = true }
                    if let notice { Text(notice).font(.footnote).foregroundStyle(.secondary) }
                } header: {
                    Text("Library")
                } footer: {
                    Text("\(library.photos.count) photos. Photos you remove stay in Recently Deleted until it is emptied.")
                }

                Section {
                    Button("About Silverbath") { showAbout = true }
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .onAppear(perform: refresh)
            .sheet(isPresented: $showAbout) { AboutView() }
            .sheet(item: Binding(get: { model.map(SpecItem.init) }, set: { model = $0?.spec })) { item in
                ModelSheet(item.spec) { refresh() }
            }
            .sheet(isPresented: $editingExport) {
                ExportOptionsView(settings: $export.settings, count: 0) { editingExport = false }
            }
            .confirmationDialog("Delete the photos in Recently Deleted for good?", isPresented: $confirmEmpty, titleVisibility: .visible) {
                Button("Empty Recently Deleted", role: .destructive) {
                    do {
                        _ = try Engine.shared.run("library.emptyRecentlyDeleted")
                        notice = "Recently Deleted is empty."
                        library.reload()
                    } catch {
                        notice = error.localizedDescription
                    }
                }
            } message: {
                Text("This can't be undone.")
            }
        }
    }

    private func refresh() {
        models = specs.map { ModelState(spec: $0, installed: $0.installed) }
        let list = ((try? Engine.shared.run("faces.models.list")) as? [String: Any]) ?? [:]
        faceModels = ((list["models"] as? [[String: Any]]) ?? []).filter { ["yunet-2023mar", "sface-2021dec"].contains($0["id"] as? String ?? "") }.map {
            ($0["id"] as? String ?? "", $0["name"] as? String ?? "", $0["installed"] as? Bool ?? false)
        }
        placeNames = ((try? Engine.shared.run("metadata.placeNamesStatus")) as? [String: Any])?["downloaded"] as? Bool ?? false
        gpu = ((try? Engine.shared.run("app.gpu", ["wait": false])) as? [String: Any])?["enabled"] as? Bool ?? true
    }
}

private struct SpecItem: Identifiable {
    let spec: ModelSpec
    var id: String { spec.name }
}

// MARK: export presets

/// Named export settings, to switch between quickly (kept on this iPhone).
@MainActor
final class ExportPresets: ObservableObject {
    static let shared = ExportPresets()
    struct Preset: Codable, Identifiable, Equatable {
        var name: String
        var settings: ExportSettings
        var id: String { name }
    }

    @Published private(set) var presets: [Preset] = []

    private init() {
        if let d = UserDefaults.standard.data(forKey: "exportPresets"), let p = try? JSONDecoder().decode([Preset].self, from: d) {
            presets = p
        } else {
            // a few to start from
            var social = ExportSettings()
            social.longEdge = 2048
            social.quality = 85
            social.metadata = "copyright"
            social.removeLocation = true
            var full = ExportSettings()
            full.quality = 95
            var print = ExportSettings()
            print.format = "tiff"
            print.colorSpace = "adobeRgb"
            print.hdr = false
            presets = [Preset(name: "Sharing online", settings: social), Preset(name: "Full quality JPG", settings: full), Preset(name: "Print (TIFF)", settings: print)]
        }
    }

    func save(_ name: String, _ settings: ExportSettings) {
        let n = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !n.isEmpty else { return }
        presets.removeAll { $0.name == n }
        presets.append(Preset(name: n, settings: settings))
        store()
    }

    func delete(_ name: String) {
        presets.removeAll { $0.name == name }
        store()
    }

    private func store() {
        if let d = try? JSONEncoder().encode(presets) { UserDefaults.standard.set(d, forKey: "exportPresets") }
    }
}

struct ExportPresetsView: View {
    @ObservedObject private var presets = ExportPresets.shared
    @ObservedObject private var export = ExportPrefs.shared
    @State private var naming = false
    @State private var name = ""

    var body: some View {
        List {
            Section {
                ForEach(presets.presets) { p in
                    Button {
                        export.settings = p.settings
                        UISelectionFeedbackGenerator().selectionChanged()
                    } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(p.name).foregroundStyle(.primary)
                                Text(p.settings.summary).font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            if p.settings == export.settings { Image(systemName: "checkmark").foregroundStyle(Theme.accent) }
                        }
                    }
                }
                .onDelete { idx in idx.map { presets.presets[$0].name }.forEach(presets.delete) }
            } footer: {
                Text("Tap one to export with it from now on. Swipe to delete.")
            }
            Section {
                Button { name = ""; naming = true } label: { Label("Save the current settings as a preset", systemImage: "plus") }
            }
        }
        .navigationTitle("Export presets")
        .alert("Save preset", isPresented: $naming) {
            TextField("Name", text: $name)
            Button("Save") { presets.save(name, export.settings) }
            Button("Cancel", role: .cancel) {}
        }
    }
}
