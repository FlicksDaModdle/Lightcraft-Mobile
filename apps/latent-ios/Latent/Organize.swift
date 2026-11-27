import SwiftUI

// MARK: albums

/// The library's albums and smart albums, and making new ones.
struct AlbumsView: View {
    @ObservedObject var library: Library
    @Binding var open: Photo?
    @Environment(\.dismiss) private var dismiss
    @State private var naming = false
    @State private var newName = ""
    @State private var makingSmart = false
    @State private var shown: Album?
    private let columns = [GridItem(.adaptive(minimum: 150), spacing: 12)]

    var body: some View {
        NavigationStack {
            ScrollView {
                let all = library.albums.flatMap(\.flattened)
                if all.isEmpty {
                    ContentUnavailableView("No albums yet", systemImage: "rectangle.stack",
                                           description: Text("Make an album to gather photos by hand, or a smart album that fills itself, such as every five-star photo or every raw from this year."))
                        .padding(.top, 40)
                }
                LazyVGrid(columns: columns, spacing: 14) {
                    ForEach(all) { a in
                        Button { shown = a } label: { AlbumTile(album: a, library: library) }
                            .buttonStyle(.plain)
                            .contextMenu {
                                Button { library.deleteAlbum(a.id) } label: { Label("Delete album", systemImage: "trash") }
                            }
                    }
                }
                .padding(14)
            }
            .background(Color.black.ignoresSafeArea())
            .navigationTitle("Albums")
            .navigationBarTitleDisplayMode(.inline)
            .navigationDestination(item: $shown) { a in AlbumGrid(album: a, library: library, open: $open, close: { dismiss() }) }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } }
                ToolbarItem(placement: .primaryAction) {
                    Menu {
                        Button { newName = ""; naming = true } label: { Label("New album", systemImage: "rectangle.stack.badge.plus") }
                        Button { makingSmart = true } label: { Label("New smart album", systemImage: "gearshape.2") }
                    } label: { Image(systemName: "plus") }
                    .accessibilityLabel(Text("New album"))
                }
            }
            .alert("New album", isPresented: $naming) {
                TextField("Name", text: $newName)
                Button("Make") { library.createAlbum(newName) }
                Button("Cancel", role: .cancel) {}
            }
            .sheet(isPresented: $makingSmart) { SmartAlbumForm(library: library) }
        }
    }
}

/// An album's cover and name.
struct AlbumTile: View {
    let album: Album
    @ObservedObject var library: Library

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Group {
                if let p = (album.cover.flatMap(library.photo)) ?? library.photos(inAlbum: album.id).first {
                    ThumbView(photo: p)
                } else {
                    Color(white: 0.12).aspectRatio(1, contentMode: .fit)
                        .overlay(Image(systemName: album.smart ? "gearshape.2" : "photo.on.rectangle").font(.system(size: 28)).foregroundStyle(Theme.secondaryText))
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            HStack(spacing: 4) {
                if album.smart { Image(systemName: "gearshape.2").font(.system(size: 11)) }
                Text(album.name).font(.system(size: 14, weight: .semibold)).lineLimit(1)
            }
            Text("\(album.count)").font(.system(size: 12)).foregroundStyle(Theme.secondaryText)
        }
        .foregroundStyle(.white)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("\(album.smart ? "Smart album" : "Album") \(album.name), \(album.count) photos"))
    }
}

/// The photos of one album.
struct AlbumGrid: View {
    let album: Album
    @ObservedObject var library: Library
    @Binding var open: Photo?
    let close: () -> Void
    @State private var photos: [Photo] = []
    @State private var renaming = false
    @State private var name = ""
    private let columns = Array(repeating: GridItem(.flexible(), spacing: 2), count: 4)

    var body: some View {
        ScrollView {
            if album.smart && !album.rulesText.isEmpty {
                Text(album.rulesText).font(.system(size: 13)).foregroundStyle(Theme.secondaryText)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(14)
            }
            LazyVGrid(columns: columns, spacing: 2) {
                ForEach(photos) { p in
                    Button {
                        close()
                        open = p
                    } label: { LibraryCell(photo: p) }
                        .buttonStyle(.plain)
                        .contextMenu {
                            if !album.smart {
                                Button {
                                    library.remove([p.id], fromAlbum: album.id)
                                    photos = library.photos(inAlbum: album.id)
                                } label: { Label("Take out of this album", systemImage: "minus.circle") }
                            }
                        }
                        .accessibilityLabel(Text(p.fileName))
                }
            }
        }
        .background(Color.black.ignoresSafeArea())
        .navigationTitle(album.name)
        .onAppear { photos = library.photos(inAlbum: album.id) }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button("Rename") { name = album.name; renaming = true }
            }
        }
        .alert("Rename album", isPresented: $renaming) {
            TextField("Name", text: $name)
            Button("Rename") { library.renameAlbum(album.id, name) }
            Button("Cancel", role: .cancel) {}
        }
    }
}

/// A smart album's rules, in plain choices.
struct SmartAlbumForm: View {
    @ObservedObject var library: Library
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var rating = 0
    @State private var flag = "any"
    @State private var kind = "any"
    @State private var edited = "any"
    @State private var keyword = ""
    @State private var camera = ""
    @State private var useDates = false
    @State private var from = Calendar.current.date(byAdding: .year, value: -1, to: .now) ?? .now
    @State private var to = Date.now

    var body: some View {
        NavigationStack {
            Form {
                Section { TextField("Name", text: $name) }
                Section("Photos that are") {
                    Picker("Rated at least", selection: $rating) {
                        Text("Any rating").tag(0)
                        ForEach(1...5, id: \.self) { Text(String(repeating: "\u{2605}", count: $0)).tag($0) }
                    }
                    Picker("Flag", selection: $flag) {
                        Text("Any").tag("any")
                        Text("Picked").tag("pick")
                        Text("Rejected").tag("reject")
                        Text("Not flagged").tag("none")
                    }
                    Picker("Kind", selection: $kind) {
                        Text("Any").tag("any")
                        Text("Raw").tag("raw")
                        Text("Not raw").tag("image")
                    }
                    Picker("Edited", selection: $edited) {
                        Text("Either").tag("any")
                        Text("Edited").tag("yes")
                        Text("Not edited").tag("no")
                    }
                    TextField("With keyword", text: $keyword)
                    TextField("Camera", text: $camera)
                }
                Section("Taken") {
                    Toggle("Between dates", isOn: $useDates)
                    if useDates {
                        DatePicker("From", selection: $from, displayedComponents: .date)
                        DatePicker("To", selection: $to, displayedComponents: .date)
                    }
                }
            }
            .navigationTitle("New smart album")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Make") {
                        library.createSmartAlbum(name, rules: rules)
                        dismiss()
                    }
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
    }

    private var rules: [String: Any] {
        var r: [String: Any] = [:]
        if rating > 0 { r["rating"] = rating; r["ratingOp"] = "atLeast" }
        if flag != "any" { r["flag"] = flag }
        if kind != "any" { r["kind"] = kind }
        if edited != "any" { r["edited"] = edited == "yes" }
        let k = keyword.trimmingCharacters(in: .whitespaces)
        if !k.isEmpty { r["keyword"] = k }
        let c = camera.trimmingCharacters(in: .whitespaces)
        if !c.isEmpty { r["camera"] = c }
        if useDates {
            let f = DateFormatter()
            f.calendar = Calendar(identifier: .gregorian)
            f.locale = Locale(identifier: "en_US_POSIX")
            f.dateFormat = "yyyy-MM-dd"
            r["dateFrom"] = f.string(from: from)
            r["dateTo"] = f.string(from: to)
        }
        return r
    }
}

/// Put photos in an album, or a new one.
struct AddToAlbumSheet: View {
    let ids: [UInt64]
    @ObservedObject var library: Library
    @Environment(\.dismiss) private var dismiss
    @State private var naming = false
    @State private var newName = ""

    var body: some View {
        NavigationStack {
            List {
                Button { newName = ""; naming = true } label: { Label("New album", systemImage: "plus") }
                ForEach(library.albums.flatMap(\.flattened).filter { !$0.smart }) { a in
                    Button {
                        library.add(ids, toAlbum: a.id)
                        UINotificationFeedbackGenerator().notificationOccurred(.success)
                        dismiss()
                    } label: {
                        HStack {
                            Text(a.name)
                            Spacer()
                            Text("\(a.count)").foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .navigationTitle("Add \(ids.count) to an album")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
            .alert("New album", isPresented: $naming) {
                TextField("Name", text: $newName)
                Button("Make and add") {
                    library.createAlbum(newName, adding: ids)
                    dismiss()
                }
                Button("Cancel", role: .cancel) {}
            }
        }
    }
}

// MARK: keywords

/// The keywords of one or more photos: take some away, add new ones (with suggestions).
struct KeywordSheet: View {
    let ids: [UInt64]
    @ObservedObject var library: Library
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @State private var suggestions: [String] = []

    /// The keywords every one of the photos has.
    private var common: [String] {
        let sets = ids.compactMap(library.photo).map { Set($0.keywords) }
        guard var all = sets.first else { return [] }
        for s in sets.dropFirst() { all.formIntersection(s) }
        return all.sorted()
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    HStack {
                        TextField("Add a keyword", text: $text)
                            .textInputAutocapitalization(.never)
                            .onSubmit(add)
                            .onChange(of: text) { _, t in suggestions = library.suggestKeywords(for: ids, prefix: t) }
                        Button("Add", action: add).disabled(text.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                } footer: {
                    Text("Separate several with commas. Use | for a keyword inside another, like Places|Paris.")
                }
                if !common.isEmpty {
                    Section(ids.count == 1 ? "Keywords" : "On all \(ids.count) photos") {
                        FlowChips(words: common, symbol: "xmark") { w in library.removeKeywords([w], from: ids) }
                    }
                }
                let offered = suggestions.filter { !common.contains($0) }
                if !offered.isEmpty {
                    Section("Suggestions") {
                        FlowChips(words: offered, symbol: "plus") { w in
                            library.addKeywords([w], to: ids)
                            suggestions = library.suggestKeywords(for: ids, prefix: text)
                        }
                    }
                }
            }
            .navigationTitle("Keywords")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .onAppear { suggestions = library.suggestKeywords(for: ids) }
        }
    }

    private func add() {
        let words = text.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        guard !words.isEmpty else { return }
        library.addKeywords(words, to: ids)
        text = ""
        suggestions = library.suggestKeywords(for: ids)
    }
}

/// Words as tappable chips that wrap onto new lines.
struct FlowChips: View {
    let words: [String]
    let symbol: String
    let tap: (String) -> Void

    var body: some View {
        WrapLayout(spacing: 8) {
            ForEach(words, id: \.self) { w in
                Button { tap(w) } label: {
                    HStack(spacing: 4) {
                        Text(w)
                        Image(systemName: symbol).font(.system(size: 10, weight: .bold))
                    }
                    .font(.system(size: 14))
                    .padding(.horizontal, 10).padding(.vertical, 6)
                    .background(Color.white.opacity(0.1), in: Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text(symbol == "xmark" ? "Remove \(w)" : "Add \(w)"))
            }
        }
        .padding(.vertical, 4)
    }
}

/// Lays its views out in rows, starting a new row when one is full.
struct WrapLayout: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? 320
        var x: CGFloat = 0, y: CGFloat = 0, row: CGFloat = 0
        for v in subviews {
            let s = v.sizeThatFits(.unspecified)
            if x > 0 && x + s.width > width { x = 0; y += row + spacing; row = 0 }
            x += s.width + spacing
            row = max(row, s.height)
        }
        return CGSize(width: width, height: y + row)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, row: CGFloat = 0
        for v in subviews {
            let s = v.sizeThatFits(.unspecified)
            if x > bounds.minX && x + s.width > bounds.maxX { x = bounds.minX; y += row + spacing; row = 0 }
            v.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(s))
            x += s.width + spacing
            row = max(row, s.height)
        }
    }
}

// MARK: versions

/// A photo's saved versions: named sets of edits to switch between.
struct VersionsSheet: View {
    @ObservedObject var model: EditorModel
    @Environment(\.dismiss) private var dismiss
    @State private var naming = false
    @State private var name = ""
    @State private var renaming: Int?

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Button { name = ""; naming = true } label: { Label("Save the current edits as a version", systemImage: "plus") }
                } footer: {
                    Text("A version keeps a whole set of edits, such as a colour and a black-and-white look of the same photo. Choosing one puts its edits back; the photo's history keeps every step.")
                }
                if !model.versions.isEmpty {
                    Section("Versions") {
                        ForEach(Array(model.versions.enumerated()), id: \.offset) { i, v in
                            Button {
                                model.versionAction("version.restore", i)
                                dismiss()
                            } label: {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(v.name).foregroundStyle(.primary)
                                    if !v.created.isEmpty { Text(v.created).font(.caption).foregroundStyle(.secondary) }
                                }
                            }
                            .swipeActions {
                                Button(role: .destructive) { model.versionAction("version.delete", i) } label: { Label("Delete", systemImage: "trash") }
                                Button { model.versionAction("version.update", i) } label: { Label("Update", systemImage: "arrow.triangle.2.circlepath") }
                                    .tint(.blue)
                                Button { name = v.name; renaming = i } label: { Label("Rename", systemImage: "pencil") }
                                    .tint(.gray)
                            }
                        }
                    }
                }
            }
            .navigationTitle("Versions")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .onAppear { model.loadVersions() }
            .alert("Save a version", isPresented: $naming) {
                TextField("Name, like Warm or B&W", text: $name)
                Button("Save") { model.saveVersion(name) }
                Button("Cancel", role: .cancel) {}
            }
            .alert("Rename version", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
                TextField("Name", text: $name)
                Button("Rename") { if let i = renaming { model.versionAction("version.rename", i, name: name) } }
                Button("Cancel", role: .cancel) {}
            }
        }
    }
}
