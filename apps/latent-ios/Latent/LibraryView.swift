import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

/// The two places photos come from: Latent's own library, and the photos on this iPhone.
enum HomeTab: String, CaseIterable, Identifiable {
    case library, device
    var id: String { rawValue }
    var label: String { self == .library ? "Library" : "On iPhone" }
    var symbol: String { self == .library ? "photo.stack" : "iphone" }
}

/// The home screen: a glass top bar, the chosen tab's grid, and a floating glass tab bar.
struct LibraryView: View {
    @StateObject private var library = Library()
    @State private var tab: HomeTab = .library
    @State private var open: Photo?
    @State private var picked: [PhotosPickerItem] = []
    @State private var pickingPhotos = false
    @State private var pickingFiles = false
    @State private var sharing: Photo?
    @State private var showAbout = false
    @Namespace private var glass

    var body: some View {
        ZStack(alignment: .bottom) {
            VStack(spacing: 0) {
                topBar
                Group {
                    switch tab {
                    case .library:
                        LibraryGrid(library: library, open: $open, sharing: $sharing, browseDevice: { withAnimation(.glass) { tab = .device } }, addPhotos: { pickingPhotos = true })
                    case .device:
                        DeviceView(library: library) { photo in open = photo }
                    }
                }
                .transition(.opacity)
            }
            tabBar
        }
        .background(Color.black.ignoresSafeArea())
        .preferredColorScheme(.dark)
        .animation(.glass, value: tab)
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
        .alert("Latent", isPresented: Binding(get: { library.notice != nil }, set: { if !$0 { library.notice = nil } })) {
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
                .accessibilityLabel(Text("Latent"))
            Spacer()
            HStack(spacing: 0) {
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
                    Button { showAbout = true } label: { Label("About Latent", systemImage: "info.circle") }
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

    private var tabBar: some View {
        HStack(spacing: 4) {
            ForEach(HomeTab.allCases) { t in
                VStack(spacing: 3) {
                    Image(systemName: t.symbol).font(.system(size: 20, weight: .medium))
                        .symbolEffect(.bounce, value: tab == t)
                    Text(t.label).font(.system(size: 11, weight: .semibold))
                }
                .foregroundStyle(tab == t ? Theme.accent : .white)
                .frame(width: 104, height: 54)
                .background {
                    if tab == t {
                        Capsule()
                            .fill(Color.white.opacity(0.12))
                            .matchedGeometryEffect(id: "tab", in: glass)
                    }
                }
                .contentShape(Capsule())
                // a plain tap, not a button inside interactive glass, so the touch always lands
                .onTapGesture { choose(t) }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(Text(t.label))
                .accessibilityAddTraits(tab == t ? [.isButton, .isSelected] : .isButton)
                .accessibilityAction { choose(t) }
            }
        }
        .padding(5)
        .latentGlass(in: Capsule())
        .shadow(color: .black.opacity(0.35), radius: 18, y: 8)
        .padding(.bottom, 8)
        .zIndex(1)
    }

    private func choose(_ t: HomeTab) {
        guard tab != t else { return }
        UISelectionFeedbackGenerator().selectionChanged()
        withAnimation(.glass) { tab = t }
    }
}

/// Latent's own photos: the filter as the title, the count, sort, and the grid.
struct LibraryGrid: View {
    @ObservedObject var library: Library
    @Binding var open: Photo?
    @Binding var sharing: Photo?
    let browseDevice: () -> Void
    let addPhotos: () -> Void

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
                        Button { open = photo } label: { LibraryCell(photo: photo) }
                            .buttonStyle(.plain)
                            .contextMenu { menu(photo) } preview: {
                                ContextPreview(photo: photo)
                            }
                            .accessibilityLabel(Text(photo.fileName))
                            .accessibilityValue(Text(photo.edited ? "Edited" : ""))
                    }
                }
                .animation(.glass, value: shown.map(\.id))
            }
            Color.clear.frame(height: 90)
        }
        .scrollIndicators(.hidden)
        .refreshable { library.reload() }
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
            Menu {
                Picker("Sort", selection: $library.sort) {
                    ForEach(LibrarySort.allCases) { Text($0.label).tag($0) }
                }
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
        Button(role: .destructive) { library.remove(photo) } label: { Label("Remove from Latent", systemImage: "trash") }
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
                    Label("Browse this iPhone", systemImage: "iphone").padding(.horizontal, 16).frame(height: 44)
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
                            Text("Latent").font(.system(size: 20, weight: .semibold))
                            Text("Version \(version)").font(.system(size: 14)).foregroundStyle(Theme.secondaryText)
                        }
                    }
                    .padding(.vertical, 4)
                }
                Section {
                    Text("Latent is built on the open-source LightCraft engine, \u{00A9} 2026 ArtCraft Team and the LightCraft contributors, used under the MIT License (it is also available under the Apache License 2.0).")
                        .font(.system(size: 14))
                    if let url = URL(string: "https://github.com/FlicksDaModdle/Lightcraft-Mobile") {
                        Link("LightCraft source and licence", destination: url)
                    }
                } header: {
                    Text("Open source")
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
