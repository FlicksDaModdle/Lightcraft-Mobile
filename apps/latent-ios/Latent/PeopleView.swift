import SwiftUI

/// People: the faces in the library, found and recognised on this iPhone by two small optional models, and named
/// by the user. Look-alike unnamed faces sit next to each other, so a few taps name a person in many photos.
struct PeopleView: View {
    @ObservedObject var library: Library
    @Binding var open: Photo?
    @StateObject private var faces = Faces()
    @State private var chosen: Set<FaceRef> = []
    @State private var naming = false
    @State private var name = ""
    @State private var person: String?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    if !faces.ready {
                        setup
                    } else {
                        progress
                        people
                        unnamed
                    }
                }
                .padding(.horizontal, 14)
                .padding(.bottom, chosen.isEmpty ? 20 : 90)
            }
            .scrollIndicators(.hidden)
            .background(Color.black.ignoresSafeArea())
            .navigationTitle("People")
            .navigationDestination(item: $person) { name in
                PersonView(name: name, library: library, open: $open)
            }
            .overlay(alignment: .bottom) {
                if !chosen.isEmpty { nameBar }
            }
            .alert("Who is this?", isPresented: $naming) {
                TextField("Name", text: $name)
                Button("Name") {
                    faces.name(Array(chosen), as: name) { library.reload() }
                    chosen = []
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("\(chosen.count) face\(chosen.count == 1 ? "" : "s")")
            }
        }
        .onAppear { faces.start() }
        .onDisappear { faces.stop() }
    }

    // MARK: setup

    private var setup: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Find people in your photos", systemImage: "person.crop.rectangle.stack")
                .font(.system(size: 20, weight: .bold))
            Text("Two small models find the faces in your photos and tell who looks like whom. They run on this iPhone; no photo or face leaves it. You name the people; nobody is named for you.")
                .font(.system(size: 14))
                .foregroundStyle(Theme.secondaryText)
            ForEach(faces.models, id: \.id) { m in
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text(m.name).font(.system(size: 15, weight: .semibold))
                        Spacer()
                        if m.installed {
                            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                        } else if let f = faces.downloading[m.id] {
                            ProgressView(value: f).frame(width: 80)
                        } else {
                            Text(ByteCountFormatter.string(fromByteCount: Int64(m.size), countStyle: .file))
                                .font(.system(size: 13)).foregroundStyle(Theme.secondaryText)
                        }
                    }
                    Text("\(m.licence): \(m.notice)").font(.system(size: 12)).foregroundStyle(Theme.secondaryText)
                }
                .padding(12)
                .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            }
            if let e = faces.error {
                Label(e, systemImage: "exclamationmark.triangle.fill").font(.system(size: 13)).foregroundStyle(.red)
            }
            Button {
                faces.download()
            } label: {
                Text(faces.downloading.isEmpty ? "Download and start" : "Downloading\u{2026}")
                    .font(.system(size: 16, weight: .semibold))
                    .frame(maxWidth: .infinity)
                    .frame(height: 48)
                    .latentGlass(in: Capsule(), tint: Theme.accent, interactive: true)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.white)
            .disabled(!faces.downloading.isEmpty)
            Text("By downloading you accept the models' licences above.")
                .font(.system(size: 12))
                .foregroundStyle(Theme.secondaryText)
        }
        .padding(.top, 8)
    }

    // MARK: people and faces

    @ViewBuilder
    private var progress: some View {
        if faces.pending > 0 {
            HStack(spacing: 10) {
                ProgressView().tint(.white)
                Text("Looking for faces: \(faces.pending) photo\(faces.pending == 1 ? "" : "s") to go")
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.secondaryText)
            }
            .padding(.top, 4)
        }
    }

    private var names: [(name: String, count: Int)] {
        var count: [String: Int] = [:]
        for p in library.photos { for n in p.people { count[n, default: 0] += 1 } }
        return count.map { ($0.key, $0.value) }.sorted { $0.count != $1.count ? $0.count > $1.count : $0.name < $1.name }
    }

    @ViewBuilder
    private var people: some View {
        let list = names
        if !list.isEmpty {
            Text("People").font(.system(size: 18, weight: .bold))
            ScrollView(.horizontal) {
                HStack(spacing: 14) {
                    ForEach(list, id: \.name) { p in
                        Button { person = p.name } label: {
                            VStack(spacing: 6) {
                                PersonCover(name: p.name, library: library)
                                    .frame(width: 76, height: 76)
                                    .clipShape(Circle())
                                Text(p.name).font(.system(size: 13, weight: .medium)).lineLimit(1)
                                Text("\(p.count)").font(.system(size: 11)).foregroundStyle(Theme.secondaryText)
                            }
                            .frame(width: 84)
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.white)
                        .accessibilityLabel(Text("\(p.name), \(p.count) photos"))
                    }
                }
            }
            .scrollIndicators(.hidden)
        }
    }

    private let columns = Array(repeating: GridItem(.flexible(), spacing: 8), count: 4)

    @ViewBuilder
    private var unnamed: some View {
        HStack {
            Text("Unnamed faces").font(.system(size: 18, weight: .bold))
            Spacer()
            if faces.total > 0 { Text("\(faces.total)").foregroundStyle(Theme.secondaryText) }
        }
        if faces.unnamed.isEmpty {
            Text(faces.pending > 0 ? "Faces show up here as they are found." : "No unnamed faces. Faces in photos you bring in will show up here.")
                .font(.system(size: 14))
                .foregroundStyle(Theme.secondaryText)
        } else {
            Text("Tap the faces of one person, then name them. Look-alikes are next to each other.")
                .font(.system(size: 13))
                .foregroundStyle(Theme.secondaryText)
            LazyVGrid(columns: columns, spacing: 10) {
                ForEach(faces.unnamed) { f in
                    Button {
                        UISelectionFeedbackGenerator().selectionChanged()
                        if chosen.contains(f.ref) { chosen.remove(f.ref) } else { chosen.insert(f.ref) }
                    } label: {
                        VStack(spacing: 3) {
                            FaceThumb(face: f)
                                .aspectRatio(1, contentMode: .fit)
                                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                                .overlay {
                                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                                        .stroke(chosen.contains(f.ref) ? Theme.accent : .clear, lineWidth: 3)
                                }
                                .overlay(alignment: .bottomTrailing) {
                                    if chosen.contains(f.ref) {
                                        Image(systemName: "checkmark.circle.fill").foregroundStyle(.white, Theme.accent).padding(4)
                                    }
                                }
                            Text(f.suggestion ?? " ")
                                .font(.system(size: 11))
                                .foregroundStyle(Theme.secondaryText)
                                .lineLimit(1)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(Text(f.suggestion.map { "Face, maybe \($0)" } ?? "Face"))
                    .accessibilityAddTraits(chosen.contains(f.ref) ? .isSelected : [])
                }
            }
        }
    }

    /// Name the chosen faces, or take the name suggested for them.
    private var nameBar: some View {
        let suggestion = faces.commonSuggestion(chosen)
        return HStack(spacing: 8) {
            Text("\(chosen.count) chosen").font(.system(size: 14, weight: .semibold)).padding(.leading, 6)
            Spacer()
            if let suggestion {
                Button {
                    faces.name(Array(chosen), as: suggestion) { library.reload() }
                    chosen = []
                } label: {
                    Text("This is \(suggestion)").font(.system(size: 14, weight: .semibold)).lineLimit(1)
                        .padding(.horizontal, 14).frame(height: 42)
                        .latentGlass(in: Capsule(), interactive: true)
                }
                .buttonStyle(.plain)
            }
            Button {
                name = ""
                naming = true
            } label: {
                Text("Name").font(.system(size: 14, weight: .semibold))
                    .padding(.horizontal, 16).frame(height: 42)
                    .latentGlass(in: Capsule(), tint: Theme.accent, interactive: true)
            }
            .buttonStyle(.plain)
            Button { chosen = [] } label: {
                Image(systemName: "xmark").font(.system(size: 14, weight: .bold)).frame(width: 42, height: 42)
                    .latentGlass(in: Circle(), interactive: true)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text("Clear the choice"))
        }
        .foregroundStyle(.white)
        .padding(8)
        .latentGlass(in: Capsule())
        .padding(.horizontal, 14)
        .padding(.bottom, 8)
    }
}

/// One face region: the photo and the region's number in it.
struct FaceRef: Hashable {
    let photo: UInt64
    let index: Int
}

/// A face to show: where it is in its photo (0…1 of the upright photo) and who it may be.
struct FaceItem: Identifiable {
    let ref: FaceRef
    let view: CGRect
    let suggestion: String?
    var id: FaceRef { ref }

    init?(_ json: Any) {
        guard let d = json as? [String: Any], let photo = (d["photo"] as? NSNumber)?.uint64Value,
              let index = (d["index"] as? NSNumber)?.intValue else { return nil }
        ref = FaceRef(photo: photo, index: index)
        let r = (d["view"] as? [String: Any]) ?? (d["rect"] as? [String: Any]) ?? [:]
        let v = { (k: String) in (r[k] as? NSNumber)?.doubleValue ?? 0 }
        view = CGRect(x: v("x0"), y: v("y0"), width: max(v("x1") - v("x0"), 0.01), height: max(v("y1") - v("y0"), 0.01))
        suggestion = ((d["suggestion"] as? [String: Any])?["name"] as? String)
    }
}

/// The face models and the background search for faces.
@MainActor
final class Faces: ObservableObject {
    struct Model {
        let id: String, name: String, licence: String, notice: String, size: Int, installed: Bool, role: String
    }

    @Published private(set) var models: [Model] = []
    @Published private(set) var ready = false
    @Published private(set) var downloading: [String: Double] = [:]
    @Published private(set) var pending = 0
    @Published private(set) var unnamed: [FaceItem] = []
    @Published private(set) var total = 0
    @Published var error: String?
    private var timer: Timer?
    private var lastIndexed = -1

    /// The detector and recogniser the app uses.
    private let wanted = ["yunet-2023mar", "sface-2021dec"]

    func start() {
        refreshModels()
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        tick()
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    private func refreshModels() {
        let list = ((try? Engine.shared.run("faces.models.list")) as? [String: Any]) ?? [:]
        let rows = (list["models"] as? [[String: Any]]) ?? []
        models = rows.filter { wanted.contains($0["id"] as? String ?? "") }.map { r in
            let l = r["licence"] as? [String: Any] ?? [:]
            return Model(id: r["id"] as? String ?? "", name: r["name"] as? String ?? "", licence: l["name"] as? String ?? "",
                         notice: l["notice"] as? String ?? "", size: (r["sizeBytes"] as? NSNumber)?.intValue ?? 0,
                         installed: r["installed"] as? Bool ?? false, role: r["role"] as? String ?? "")
        }
        let installed = models.count == wanted.count && models.allSatisfy(\.installed)
        if installed && !(list["enabled"] as? Bool ?? false) {
            _ = try? Engine.shared.run("faces.enable", ["enabled": true])
        }
        ready = installed
    }

    func download() {
        error = nil
        for m in models where !m.installed {
            do {
                _ = try Engine.shared.run("faces.models.download", ["id": m.id, "acknowledged": true])
                downloading[m.id] = 0
            } catch {
                self.error = error.localizedDescription
            }
        }
    }

    private func tick() {
        if !downloading.isEmpty {
            let d = ((try? Engine.shared.run("faces.models.downloads")) as? [String: Any]) ?? [:]
            for row in (d["downloads"] as? [[String: Any]]) ?? [] {
                guard let id = row["id"] as? String, downloading[id] != nil else { continue }
                let bytes = (row["bytes"] as? NSNumber)?.doubleValue ?? 0, all = (row["total"] as? NSNumber)?.doubleValue ?? 0
                switch row["state"] as? String {
                case "failed":
                    error = row["error"] as? String ?? "The download failed."
                    downloading[id] = nil
                case "installed", "done", "cancelled":
                    downloading[id] = nil
                default:
                    downloading[id] = all > 0 ? bytes / all : 0
                }
            }
            refreshModels()
        }
        guard ready else { return }
        let p = ((try? Engine.shared.run("faces.pump", ["pace": "normal"])) as? [String: Any]) ?? [:]
        pending = (p["pendingPhotos"] as? NSNumber)?.intValue ?? 0
        let indexed = (p["indexedFaces"] as? NSNumber)?.intValue ?? 0
        if indexed != lastIndexed || unnamed.isEmpty {
            lastIndexed = indexed
            loadUnnamed()
        }
    }

    func loadUnnamed() {
        let u = ((try? Engine.shared.run("faces.unnamed", ["limit": 400])) as? [String: Any]) ?? [:]
        unnamed = ((u["faces"] as? [Any]) ?? []).compactMap(FaceItem.init)
        total = (u["total"] as? NSNumber)?.intValue ?? unnamed.count
    }

    /// The name suggested for every one of `faces`, if they all agree.
    func commonSuggestion(_ faces: Set<FaceRef>) -> String? {
        let names = Set(unnamed.filter { faces.contains($0.ref) }.map { $0.suggestion ?? "" })
        guard names.count == 1, let n = names.first, !n.isEmpty else { return nil }
        return n
    }

    func name(_ faces: [FaceRef], as name: String, then: () -> Void) {
        let n = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !n.isEmpty else { return }
        do {
            _ = try Engine.shared.run("faces.nameFaces", ["faces": faces.map { ["photo": $0.photo, "index": $0.index] }, "name": n])
            UINotificationFeedbackGenerator().notificationOccurred(.success)
        } catch {
            self.error = error.localizedDescription
        }
        loadUnnamed()
        then()
    }
}

/// A face cut from its photo.
struct FaceThumb: View {
    let face: FaceItem
    @State private var image: CGImage?

    var body: some View {
        Color(white: 0.12)
            .overlay {
                if let image { Image(decorative: image, scale: 1).resizable().scaledToFill() }
            }
            .clipped()
            .task(id: face.ref) { image = await FaceCrops.crop(face.ref.photo, face.view) }
    }
}

/// A person's first face, round.
struct PersonCover: View {
    let name: String
    @ObservedObject var library: Library
    @State private var image: CGImage?

    var body: some View {
        Color(white: 0.15)
            .overlay {
                if let image { Image(decorative: image, scale: 1).resizable().scaledToFill() } else {
                    Image(systemName: "person.fill").font(.system(size: 30)).foregroundStyle(Theme.secondaryText)
                }
            }
            .task(id: name) {
                let r = ((try? Engine.shared.run("faces.person", ["name": name, "more": 0])) as? [String: Any]) ?? [:]
                if let f = ((r["confirmed"] as? [Any]) ?? []).compactMap(FaceItem.init).first {
                    image = await FaceCrops.crop(f.ref.photo, f.view)
                }
            }
    }
}

/// Faces cut from the photos as they were taken (before edits, so the face boxes line up).
enum FaceCrops {
    @MainActor private static var cache: [String: CGImage] = [:]

    @MainActor static func crop(_ photo: UInt64, _ view: CGRect) async -> CGImage? {
        let key = "\(photo) \(view)"
        if let c = cache[key] { return c }
        let img = await Task.detached(priority: .utility) { () -> CGImage? in
            // big enough that a small face is still sharp at the size it is shown
            let side = view.width < 0.1 ? 2400.0 : 1200.0
            guard let r = Engine.shared.render(photo, fitting: CGSize(width: side, height: side), original: true) else { return nil }
            let full = r.image
            let w = CGFloat(full.width), h = CGFloat(full.height)
            // a square around the face, a little larger than it
            let side2 = max(view.width * w, view.height * h) * 1.5
            let cx = view.midX * w, cy = view.midY * h
            let box = CGRect(x: cx - side2 / 2, y: cy - side2 / 2, width: side2, height: side2).integral
                .intersection(CGRect(x: 0, y: 0, width: w, height: h))
            return full.cropping(to: box)
        }.value
        if let img { cache[key] = img }
        return img
    }
}

/// The photos of one person.
struct PersonView: View {
    let name: String
    @ObservedObject var library: Library
    @Binding var open: Photo?
    @State private var renaming = false
    @State private var newName = ""
    private let columns = Array(repeating: GridItem(.flexible(), spacing: 2), count: 4)

    var body: some View {
        let shown = library.photos.filter { p in p.people.contains { $0.caseInsensitiveCompare(name) == .orderedSame } }
        ScrollView {
            LazyVGrid(columns: columns, spacing: 2) {
                ForEach(shown) { p in
                    Button { open = p } label: { LibraryCell(photo: p) }
                        .buttonStyle(.plain)
                        .accessibilityLabel(Text(p.fileName))
                }
            }
        }
        .background(Color.black.ignoresSafeArea())
        .navigationTitle(name)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button("Rename") {
                    newName = name
                    renaming = true
                }
            }
        }
        .alert("Rename \(name)", isPresented: $renaming) {
            TextField("Name", text: $newName)
            Button("Rename") {
                _ = try? Engine.shared.run("faces.renamePerson", ["from": name, "to": newName, "merge": true])
                library.reload()
            }
            Button("Cancel", role: .cancel) {}
        }
    }
}
