import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

/// The two places photos come from: Latent's own library, and the photos on this iPhone.
enum HomeTab: String, Hashable {
    case library, device, people, places, search
}

/// The home screen: the system's Liquid Glass tab bar (Camera Roll first, Library, and Search on its own
/// at the end), each tab with Latent's glass top bar over its grid.
struct LibraryView: View {
    @StateObject private var library = Library()
    /// The camera roll first: what's on the iPhone, ready to open.
    @State private var tab: HomeTab = .device
    @State private var open: Photo?
    @State private var picked: [PhotosPickerItem] = []
    @State private var pickingPhotos = false
    @State private var pickingFiles = false
    @State private var sharing: Photo?
    @State private var showAbout = false
    @State private var showSettings = false
    @State private var showAlbums = false
    @State private var query = ""

    var body: some View {
        TabView(selection: $tab) {
            Tab("Camera Roll", systemImage: "photo.on.rectangle.angled", value: HomeTab.device) {
                VStack(spacing: 0) {
                    topBar
                    DeviceView(library: library) { photo in open = photo }
                }
                .background(Color.black.ignoresSafeArea())
            }
            Tab("Library", systemImage: "photo.stack", value: HomeTab.library) {
                VStack(spacing: 0) {
                    topBar
                    LibraryGrid(library: library, open: $open, sharing: $sharing, browseDevice: { tab = .device }, addPhotos: { pickingPhotos = true })
                }
                .background(Color.black.ignoresSafeArea())
            }
            Tab("People", systemImage: "person.2", value: HomeTab.people) {
                PeopleView(library: library, open: $open)
            }
            Tab("Places", systemImage: "map", value: HomeTab.places) {
                PlacesView(library: library, open: $open)
            }
            Tab(value: HomeTab.search, role: .search) {
                NavigationStack {
                    SearchGrid(library: library, query: query, open: $open, sharing: $sharing)
                        .navigationTitle("Search")
                        .background(Color.black.ignoresSafeArea())
                }
                .searchable(text: $query, prompt: Text("File name, camera, place, person or keyword"))
            }
        }
        .tabBarMinimizeBehavior(.onScrollDown)
        .tint(Theme.accent)
        .preferredColorScheme(.dark)
        .onChange(of: tab) { _, _ in UISelectionFeedbackGenerator().selectionChanged() }
        .photosPicker(isPresented: $pickingPhotos, selection: $picked, matching: .images, photoLibrary: .shared())
        .fileImporter(isPresented: $pickingFiles, allowedContentTypes: [.image, .rawImage], allowsMultipleSelection: true) { result in
            guard case .success(let urls) = result else { return }
            library.add(urls.compactMap(Self.copyIn))
        }
        .onChange(of: picked) { _, items in
            guard !items.isEmpty else { return }
            picked = []
            Task {
                var urls: [URL] = []
                for item in items {
                    if let file = try? await item.loadTransferable(type: PickedFile.self) { urls.append(file.url) }
                }
                library.add(urls)
            }
        }
        .fullScreenCover(item: $open, onDismiss: { library.reload() }) { photo in
            EditorView(photo: photo, library: library.shown)
        }
        .sheet(item: $sharing) { photo in
            ShareView(photos: library.shown, current: photo.id).presentationDragIndicator(.visible)
        }
        .sheet(isPresented: $showAbout) { AboutView() }
        .sheet(isPresented: $showSettings) { SettingsView(library: library) }
        .sheet(isPresented: $showAlbums) { AlbumsView(library: library, open: $open) }
        .alert("Silverbath", isPresented: Binding(get: { library.notice != nil }, set: { if !$0 { library.notice = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(library.notice ?? "")
        }
    }

    /// Copy a file the Files picker chose into the Import folder.
    private static func copyIn(_ url: URL) -> URL? {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        var target = Library.importFolder.appendingPathComponent(url.lastPathComponent)
        var n = 1
        while FileManager.default.fileExists(atPath: target.path) {
            let base = url.deletingPathExtension().lastPathComponent
            target = Library.importFolder.appendingPathComponent("\(base)-\(n)").appendingPathExtension(url.pathExtension)
            n += 1
        }
        do {
            try FileManager.default.copyItem(at: url, to: target)
            return target
        } catch {
            return nil
        }
    }

    private var topBar: some View {
        HStack(spacing: 12) {
            Image("Mark")
                .resizable()
                .frame(width: 40, height: 40)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Color.white.opacity(0.12)))
                .accessibilityLabel(Text("Silverbath"))
            Spacer()
            HStack(spacing: 0) {
                Button { showAlbums = true } label: {
                    Image(systemName: "rectangle.stack").frame(width: 48, height: 44)
                }
                .accessibilityLabel(Text("Albums"))
                Menu {
                    Button { pickingPhotos = true } label: { Label("Add from Photos", systemImage: "photo.on.rectangle") }
                    Button { pickingFiles = true } label: { Label("Add from Files", systemImage: "folder") }
                } label: {
                    Group {
                        if library.importing {
                            ProgressView().tint(.white)
                        } else {
                            Image(systemName: "plus")
                        }
                    }
                    .frame(width: 48, height: 44)
                }
                .disabled(library.importing)
                .accessibilityLabel(Text("Add photos"))
                Menu {
                    Picker(selection: $library.sort) {
                        ForEach(LibrarySort.allCases) { Text($0.label).tag($0) }
                    } label: {
                        Label("Sort", systemImage: "arrow.up.arrow.down")
                    }
                    .pickerStyle(.menu)
                    Divider()
                    Button { showSettings = true } label: { Label("Settings", systemImage: "gearshape") }
                    Button { showAbout = true } label: { Label("About Silverbath", systemImage: "info.circle") }
                } label: {
                    Image(systemName: "ellipsis").frame(width: 48, height: 44)
                }
                .accessibilityLabel(Text("More"))
            }
            .font(.system(size: 18, weight: .semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 4)
            .latentGlass(in: Capsule(), interactive: true)
        }
        .padding(.horizontal, 16)
        .padding(.top, 4)
        .padding(.bottom, 8)
    }

}

/// Latent's own photos: the filter as the title, the count, sort, and the grid.
struct LibraryGrid: View {
    @ObservedObject var library: Library
    @Binding var open: Photo?
    @Binding var sharing: Photo?
    let browseDevice: () -> Void
    let addPhotos: () -> Void
    /// Choosing several photos, to paste edits, apply a preset or export them together.
    @State private var selecting = false
    @State private var selected: Set<UInt64> = []
    @State private var exporting = false
    @State private var merging = false
    @State private var slideshow: [Photo]?
    @State private var addingToAlbum: [UInt64]?
    @State private var keywording: [UInt64]?

    private let columns = Array(repeating: GridItem(.flexible(), spacing: 2), count: 4)

    var body: some View {
        let shown = library.shown
        ScrollView {
            header(count: shown.count)
            if library.photos.isEmpty {
                empty
            } else if shown.isEmpty {
                Text("No photos here yet.")
                    .foregroundStyle(Theme.secondaryText)
                    .padding(.top, 80)
            } else {
                LazyVGrid(columns: columns, spacing: 2) {
                    ForEach(shown) { photo in
                        Button {
                            if selecting {
                                UISelectionFeedbackGenerator().selectionChanged()
                                if selected.contains(photo.id) { selected.remove(photo.id) } else { selected.insert(photo.id) }
                            } else {
                                open = photo
                            }
                        } label: {
                            LibraryCell(photo: photo)
                                .overlay(alignment: .bottomTrailing) {
                                    if selecting {
                                        Image(systemName: selected.contains(photo.id) ? "checkmark.circle.fill" : "circle")
                                            .font(.system(size: 20, weight: .semibold))
                                            .symbolRenderingMode(.palette)
                                            .foregroundStyle(.white, selected.contains(photo.id) ? Theme.accent : Color.black.opacity(0.3))
                                            .shadow(color: .black.opacity(0.4), radius: 2)
                                            .padding(5)
                                    }
                                }
                                .overlay {
                                    if selecting && selected.contains(photo.id) { Color.white.opacity(0.15) }
                                }
                        }
                            .buttonStyle(.plain)
                            .contextMenu { menu(photo) } preview: {
                                ContextPreview(photo: photo)
                            }
                            .accessibilityLabel(Text(photo.fileName))
                            .accessibilityValue(Text([photo.edited ? "Edited" : nil, photo.isRaw ? "Raw" : nil, selecting && selected.contains(photo.id) ? "Selected" : nil].compactMap { $0 }.joined(separator: ", ")))
                            .accessibilityAddTraits(selecting && selected.contains(photo.id) ? .isSelected : [])
                    }
                }
                .animation(.glass, value: shown.map(\.id))
                .padding(.bottom, selecting ? 80 : 0)
            }
        }
        .scrollIndicators(.hidden)
        .refreshable { library.reload() }
        .overlay(alignment: .bottom) {
            if selecting { selectionBar.transition(.move(edge: .bottom).combined(with: .opacity)) }
        }
        .animation(.glass, value: selecting)
        .fullScreenCover(item: Binding(get: { slideshow.map(SlideshowItem.init) }, set: { slideshow = $0?.photos })) { s in
            SlideshowView(photos: s.photos)
        }
        .sheet(item: Binding(get: { addingToAlbum.map(IDList.init) }, set: { addingToAlbum = $0?.ids })) { l in
            AddToAlbumSheet(ids: l.ids, library: library).presentationDetents([.medium, .large])
        }
        .sheet(item: Binding(get: { keywording.map(IDList.init) }, set: { keywording = $0?.ids })) { l in
            KeywordSheet(ids: l.ids, library: library).presentationDetents([.medium, .large])
        }
        .sheet(isPresented: $merging) {
            MergeView(ids: library.shown.map(\.id).filter { selected.contains($0) }) { id in
                library.reload()
                selecting = false
                selected = []
                if let id { library.notice = nil; open = library.photos.first { $0.id == id } }
            }
        }
        .sheet(isPresented: $exporting) {
            let chosen = shown.filter { selected.contains($0.id) }
            ShareView(photos: chosen, current: chosen.first?.id ?? 0, all: true).presentationDragIndicator(.visible)
        }
    }

    /// What to do with the chosen photos.
    private var selectionBar: some View {
        let ids = library.shown.map(\.id).filter { selected.contains($0) }
        return HStack(spacing: 8) {
            Text(ids.isEmpty ? "Choose photos" : "\(ids.count) chosen")
                .font(.system(size: 14, weight: .semibold))
                .monospacedDigit()
                .foregroundStyle(.white)
                .padding(.leading, 6)
            Spacer()
            Button { library.pasteEdits(ids) } label: { barIcon("doc.on.clipboard") }
                .disabled(ids.isEmpty || !library.canPaste)
                .accessibilityLabel(Text("Paste edits"))
            Menu {
                ForEach(library.presets()) { p in
                    Button(p.name) { library.applyPreset(p.id, to: ids) }
                }
            } label: { barIcon("camera.filters") }
                .disabled(ids.isEmpty)
                .accessibilityLabel(Text("Apply a preset"))
            Button { exporting = true } label: { barIcon("square.and.arrow.up") }
                .disabled(ids.isEmpty)
                .accessibilityLabel(Text("Export"))
            Button { merging = true } label: { barIcon("square.stack.3d.down.forward") }
                .disabled(ids.count < 2)
                .accessibilityLabel(Text("Merge to HDR or panorama"))
            Menu {
                Button { selected = Set(library.shown.map(\.id)) } label: { Label("Choose all", systemImage: "checkmark.circle") }
                Button { slideshow = library.shown.filter { selected.contains($0.id) } } label: { Label("Play as a slideshow", systemImage: "play.rectangle") }
                    .disabled(ids.isEmpty)
                Button { addingToAlbum = ids } label: { Label("Add to an album", systemImage: "rectangle.stack.badge.plus") }
                    .disabled(ids.isEmpty)
                Button { keywording = ids } label: { Label("Keywords", systemImage: "tag") }
                    .disabled(ids.isEmpty)
                Divider()
                Button { library.stack(ids); selected = [] } label: { Label("Stack them", systemImage: "square.stack.3d.up") }
                    .disabled(ids.count < 2)
                Button { library.unstack(ids); selected = [] } label: { Label("Unstack", systemImage: "square.stack.3d.up.slash") }
                    .disabled(ids.isEmpty)
                Button {
                    let n = library.autoStack(ids)
                    library.notice = n > 0 ? "Made \(n) stack\(n == 1 ? "" : "s") of shots taken close together" : "No shots taken close together"
                    selected = []
                } label: { Label("Stack shots taken together", systemImage: "clock.badge.checkmark") }
                    .disabled(ids.count < 2)
                Divider()
                Button { library.resetEdits(ids) } label: { Label("Reset edits", systemImage: "arrow.uturn.backward") }
                    .disabled(ids.isEmpty)
                Button(role: .destructive) {
                    library.remove(ids)
                    selected = []
                } label: { Label("Remove from Silverbath", systemImage: "trash") }
                    .disabled(ids.isEmpty)
            } label: { barIcon("ellipsis") }
                .accessibilityLabel(Text("More"))
        }
        .padding(8)
        .latentGlass(in: Capsule())
        .latentGlassGroup()
        .padding(.horizontal, 14)
        .padding(.bottom, 8)
    }

    private func barIcon(_ symbol: String) -> some View {
        Image(systemName: symbol)
            .font(.system(size: 16, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: 42, height: 42)
            .latentGlass(in: Circle(), interactive: true)
    }

    private func header(count: Int) -> some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 2) {
                Menu {
                    Picker("Show", selection: $library.filter) {
                        ForEach(LibraryFilter.allCases) { f in
                            Label(f.label, systemImage: f.symbol).tag(f)
                        }
                    }
                } label: {
                    HStack(spacing: 8) {
                        Text(library.filter.label).font(.system(size: 30, weight: .bold))
                        Image(systemName: "chevron.down").font(.system(size: 16, weight: .bold)).foregroundStyle(Theme.secondaryText)
                    }
                    .foregroundStyle(.white)
                    .contentTransition(.interpolate)
                }
                Text(count == library.photos.count ? "\(count) photos" : "\(count) of \(library.photos.count)")
                    .font(.system(size: 14))
                    .foregroundStyle(Theme.secondaryText)
                    .monospacedDigit()
                    .contentTransition(.numericText())
            }
            Spacer()
            if !library.photos.isEmpty {
                Button {
                    selecting.toggle()
                    if !selecting { selected = [] }
                } label: {
                    Text(selecting ? "Done" : "Select")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 14)
                        .frame(height: 42)
                        .latentGlass(in: Capsule(), tint: selecting ? Theme.accent : nil, interactive: true)
                }
                .buttonStyle(.plain)
            }
            Menu {
                Picker("Sort", selection: $library.sort) {
                    ForEach(LibrarySort.allCases) { Text($0.label).tag($0) }
                }
                Divider()
                Button { slideshow = library.shown } label: { Label("Play as a slideshow", systemImage: "play.rectangle") }
                    .disabled(library.shown.isEmpty)
            } label: {
                Image(systemName: "arrow.up.arrow.down")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 42, height: 42)
                    .latentGlass(in: Circle(), interactive: true)
            }
            .accessibilityLabel(Text("Sort"))
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 12)
        .animation(.glass, value: library.filter)
    }

    @ViewBuilder
    private func menu(_ photo: Photo) -> some View {
        Button { open = photo } label: { Label("Edit", systemImage: "slider.horizontal.3") }
        Button { sharing = photo } label: { Label("Share\u{2026}", systemImage: "square.and.arrow.up") }
        if let st = photo.stack {
            Button { library.toggleStack(photo) } label: {
                Label(st.collapsed ? "Open the stack" : "Fold up the stack", systemImage: "square.stack.3d.up")
            }
            if !st.top {
                Button { library.makeTop(photo) } label: { Label("Put on top of the stack", systemImage: "arrow.up.to.line") }
            }
        }
        Button { library.copyEdits(photo) } label: { Label("Copy edits", systemImage: "doc.on.doc") }
        if library.canPaste {
            Button { library.pasteEdits([photo.id]) } label: { Label("Paste edits", systemImage: "doc.on.clipboard") }
        }
        Divider()
        Button { library.flag(photo, photo.flag == "pick" ? "none" : "pick") } label: {
            Label(photo.flag == "pick" ? "Unflag" : "Pick", systemImage: photo.flag == "pick" ? "flag.slash" : "flag")
        }
        Button { library.flag(photo, photo.flag == "reject" ? "none" : "reject") } label: {
            Label(photo.flag == "reject" ? "Not rejected" : "Reject", systemImage: "xmark.circle")
        }
        Menu {
            ForEach(0...5, id: \.self) { n in
                Button { library.rate(photo, n) } label: {
                    if photo.rating == n {
                        Label(n == 0 ? "No stars" : String(repeating: "\u{2605}", count: n), systemImage: "checkmark")
                    } else {
                        Text(n == 0 ? "No stars" : String(repeating: "\u{2605}", count: n))
                    }
                }
            }
        } label: {
            Label("Rate", systemImage: "star")
        }
        Divider()
        Button(role: .destructive) { library.remove(photo) } label: { Label("Remove from Silverbath", systemImage: "trash") }
    }

    private var empty: some View {
        VStack(spacing: 16) {
            Image(systemName: "photo.stack")
                .font(.system(size: 46, weight: .light))
                .foregroundStyle(Theme.secondaryText)
                .symbolEffect(.pulse)
            Text("Your library is empty").font(.system(size: 20, weight: .semibold))
            Text("Open a photo from this iPhone, or add some to start editing.")
                .font(.system(size: 15))
                .foregroundStyle(Theme.secondaryText)
                .multilineTextAlignment(.center)
            HStack(spacing: 10) {
                Button(action: browseDevice) {
                    Label("Open the camera roll", systemImage: "photo.on.rectangle.angled").padding(.horizontal, 16).frame(height: 44)
                        .latentGlass(in: Capsule(), tint: Theme.accent.opacity(0.8), interactive: true)
                }
                Button(action: addPhotos) {
                    Label("Add", systemImage: "plus").padding(.horizontal, 16).frame(height: 44)
                        .latentGlass(in: Capsule(), interactive: true)
                }
            }
            .font(.system(size: 15, weight: .semibold))
            .foregroundStyle(.white)
            .latentGlassGroup()
        }
        .padding(28)
        .frame(maxWidth: .infinity)
        .latentGlass(in: RoundedRectangle(cornerRadius: 30, style: .continuous))
        .padding(.horizontal, 20)
        .padding(.top, 60)
    }
}

/// One square thumbnail with its edited, pick and star marks.
struct LibraryCell: View {
    let photo: Photo

    var body: some View {
        ThumbView(photo: photo)
            .overlay(alignment: .topLeading) {
                if photo.edited {
                    Image(systemName: "slider.horizontal.3")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(.white)
                        .padding(5)
                        .background(Color.black.opacity(0.5), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                        .padding(5)
                        .accessibilityHidden(true)
                }
            }
            .overlay(alignment: .topTrailing) {
                if photo.isRaw { RawBadge() }
            }
            .overlay(alignment: .bottomTrailing) {
                if let st = photo.stack, st.top {
                    HStack(spacing: 2) {
                        Image(systemName: st.collapsed ? "square.stack.3d.up.fill" : "square.stack.3d.up")
                        Text("\(st.count)")
                    }
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 5).padding(.vertical, 3)
                    .background(Color.black.opacity(0.55), in: Capsule())
                    .padding(5)
                    .accessibilityLabel(Text("Stack of \(st.count)"))
                }
            }
            .overlay(alignment: .bottomLeading) {
                HStack(spacing: 3) {
                    if photo.flag == "pick" { Image(systemName: "flag.fill") }
                    if photo.flag == "reject" { Image(systemName: "xmark.circle.fill") }
                    if photo.rating > 0 { Text(String(repeating: "\u{2605}", count: photo.rating)) }
                }
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(.white)
                .shadow(color: .black.opacity(0.8), radius: 2)
                .padding(5)
                .accessibilityHidden(true)
            }
            .opacity(photo.flag == "reject" ? 0.45 : 1)
    }
}

/// A small "RAW" tag for a thumbnail's corner.
struct RawBadge: View {
    var body: some View {
        Text("RAW")
            .font(.system(size: 9, weight: .heavy))
            .tracking(0.4)
            .foregroundStyle(.white)
            .padding(.horizontal, 5)
            .padding(.vertical, 3)
            .background(Color.black.opacity(0.55), in: RoundedRectangle(cornerRadius: 5, style: .continuous))
            .padding(5)
            .accessibilityLabel(Text("Raw"))
    }
}

/// A larger preview for the touch-and-hold menu.
private struct ContextPreview: View {
    let photo: Photo
    @State private var image: CGImage?

    var body: some View {
        Group {
            if let image {
                Image(decorative: image, scale: 1).resizable().scaledToFit()
            } else {
                Color(white: 0.12).frame(width: 300, height: 300)
            }
        }
        .task {
            let id = photo.id
            image = await Task.detached(priority: .userInitiated) { Engine.shared.thumbnail(id, longEdge: 900) }.value
        }
    }
}

/// One square thumbnail, cropped to fill, with a soft shimmer while it loads.
struct ThumbView: View {
    let photo: Photo
    @State private var image: CGImage?

    var body: some View {
        Color(white: 0.12)
            .aspectRatio(1, contentMode: .fit)
            .overlay {
                if let image {
                    Image(decorative: image, scale: 1)
                        .resizable()
                        .scaledToFill()
                        .transition(.opacity)
                } else {
                    Shimmer()
                }
            }
            .clipped()
            // clipping hides the overflow of a filled picture but not its touches: keep them to the square
            .contentShape(Rectangle())
            .task(id: photo.id) {
                image = Thumbnails.shared.cached(photo.id)
                if image == nil {
                    let img = await Thumbnails.shared.load(photo.id, longEdge: 360)
                    withAnimation(.easeOut(duration: 0.25)) { image = img }
                }
            }
    }
}

/// A light band sweeping across a placeholder.
struct Shimmer: View {
    @State private var phase: CGFloat = -1

    var body: some View {
        GeometryReader { geo in
            LinearGradient(colors: [.clear, Color.white.opacity(0.07), .clear], startPoint: .leading, endPoint: .trailing)
                .frame(width: geo.size.width * 0.8)
                .offset(x: phase * geo.size.width * 1.4)
        }
        .clipped()
        .allowsHitTesting(false)
        .onAppear {
            withAnimation(.linear(duration: 1.3).repeatForever(autoreverses: false)) { phase = 1 }
        }
    }
}

/// Version and the open-source notice.
struct AboutView: View {
    @Environment(\.dismiss) private var dismiss

    private var version: String {
        let v = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        let b = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?"
        return "\(v) (\(b))"
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    HStack(spacing: 14) {
                        Image("Mark").resizable().frame(width: 56, height: 56)
                            .clipShape(RoundedRectangle(cornerRadius: 13, style: .continuous))
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Silverbath").font(.system(size: 20, weight: .semibold))
                            Text("Version \(version)").font(.system(size: 14)).foregroundStyle(Theme.secondaryText)
                        }
                    }
                    .padding(.vertical, 4)
                }
                Section {
                    Text("Silverbath is built on the open-source LightCraft engine, \u{00A9} 2026 ArtCraft Team and the LightCraft contributors, used under the MIT License (it is also available under the Apache License 2.0).")
                        .font(.system(size: 14))
                    if let url = URL(string: "https://github.com/FlicksDaModdle/Lightcraft-Mobile") {
                        Link("LightCraft source and licence", destination: url)
                    }
                } header: {
                    Text("Open source")
                }
                Section {
                    Text("Downloaded only if you ask: the SAM 3 model for AI masks (SAM License, from Meta), the depth model for blur by depth (Depth Anything V2 Small in Apple's Core ML conversion, Apache License 2.0), the AI remove model (Big LaMa, in a Core ML conversion, Apache License 2.0), the object selection model (SAM 2.1 Small by Meta, in Apple's Core ML conversion, Apache License 2.0), and the AI denoise model (NAFNet by megvii-research, MIT License, converted to Core ML for this app).")
                        .font(.system(size: 14))
                } header: {
                    Text("AI models")
                }
            }
            .navigationTitle("About")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
        }
        .preferredColorScheme(.dark)
    }
}

/// Search: the library's photos whose file name, camera, title or keywords hold the query.
struct SearchGrid: View {
    @ObservedObject var library: Library
    let query: String
    @Binding var open: Photo?
    @Binding var sharing: Photo?
    private let columns = Array(repeating: GridItem(.flexible(), spacing: 2), count: 4)

    var body: some View {
        let q = query.trimmingCharacters(in: .whitespaces)
        let found = q.isEmpty ? [] : library.photos.filter { $0.matches(q) }
        ScrollView {
            if q.isEmpty {
                ContentUnavailableView("Search your library", systemImage: "magnifyingglass", description: Text("Find photos by file name, camera, title or keyword."))
                    .padding(.top, 80)
            } else if found.isEmpty {
                ContentUnavailableView.search(text: q).padding(.top, 80)
            } else {
                LazyVGrid(columns: columns, spacing: 2) {
                    ForEach(found) { photo in
                        Button { open = photo } label: { LibraryCell(photo: photo) }
                            .buttonStyle(.plain)
                            .contextMenu {
                                Button { open = photo } label: { Label("Edit", systemImage: "slider.horizontal.3") }
                                Button { sharing = photo } label: { Label("Share\u{2026}", systemImage: "square.and.arrow.up") }
                            }
                            .accessibilityLabel(Text(photo.fileName))
                    }
                }
            }
        }
        .scrollIndicators(.hidden)
    }
}

/// Photos to play as a slideshow, for a full-screen cover.
struct SlideshowItem: Identifiable {
    let photos: [Photo]
    var id: String { photos.map { String($0.id) }.joined(separator: ",") }
}

/// Photo ids for a sheet.
struct IDList: Identifiable {
    let ids: [UInt64]
    var id: String { ids.map(String.init).joined(separator: ",") }
}
