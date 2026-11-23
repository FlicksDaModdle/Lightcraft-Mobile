import PhotosUI
import SwiftUI

/// The grid of photos, with the button that adds more from the Photos library.
struct LibraryView: View {
    @StateObject private var library = Library()
    @State private var picked: [PhotosPickerItem] = []
    @State private var open: Photo?

    private let columns = Array(repeating: GridItem(.flexible(), spacing: 1.5), count: 4)

    var body: some View {
        NavigationStack {
            ScrollView {
                if library.photos.isEmpty {
                    empty
                } else {
                    LazyVGrid(columns: columns, spacing: 1.5) {
                        ForEach(library.photos) { photo in
                            Button { open = photo } label: { ThumbView(photo: photo) }
                                .buttonStyle(.plain)
                                .accessibilityLabel(Text(photo.fileName))
                        }
                    }
                }
            }
            .background(Color.black)
            .navigationTitle("All photos")
            .navigationBarTitleDisplayMode(.large)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    PhotosPicker(selection: $picked, matching: .images, photoLibrary: .shared()) {
                        if library.importing {
                            ProgressView()
                        } else {
                            Image(systemName: "plus")
                                .font(.system(size: 17, weight: .semibold))
                        }
                    }
                    .accessibilityLabel(Text("Add photos"))
                    .disabled(library.importing)
                }
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
                EditorView(photo: photo, library: library.photos)
            }
            .alert("Latent", isPresented: Binding(get: { library.notice != nil }, set: { if !$0 { library.notice = nil } })) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(library.notice ?? "")
            }
        }
    }

    private var empty: some View {
        VStack(spacing: 12) {
            Image(systemName: "photo.on.rectangle.angled")
                .font(.system(size: 44, weight: .light))
                .foregroundStyle(.secondary)
            Text("No photos yet")
                .font(.headline)
            Text("Tap + to add photos from your library.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 160)
    }
}

/// One square thumbnail, cropped to fill.
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
                }
            }
            .clipped()
            .task(id: photo.id) {
                image = Thumbnails.shared.cached(photo.id)
                if image == nil {
                    let img = await Thumbnails.shared.load(photo.id, longEdge: 360)
                    withAnimation(.easeOut(duration: 0.2)) { image = img }
                }
            }
    }
}
