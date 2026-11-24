import Photos
import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// The photos on this iPhone, newest first. Tapping one copies its original (the raw file when
/// there is one) into Latent and opens it; photos already brought in open straight away.
@MainActor
final class DeviceAlbum: ObservableObject {
    @Published private(set) var status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
    @Published private(set) var assets: PHFetchResult<PHAsset>?
    /// The photo being copied in.
    @Published private(set) var bringing: String?
    let images = PHCachingImageManager()

    var allowed: Bool { status == .authorized || status == .limited }

    func start() async {
        if status == .notDetermined {
            status = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
        }
        load()
    }

    func load() {
        status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        guard allowed else { return }
        let o = PHFetchOptions()
        o.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
        o.predicate = NSPredicate(format: "mediaType == %d", PHAssetMediaType.image.rawValue)
        assets = PHAsset.fetchAssets(with: o)
    }

    // MARK: which photos are already in Latent

    private static let key = "deviceImports"

    static func imported(_ asset: PHAsset) -> UInt64? {
        let map = UserDefaults.standard.dictionary(forKey: key) as? [String: NSNumber]
        return map?[asset.localIdentifier]?.uint64Value
    }

    private static func remember(_ asset: PHAsset, _ id: UInt64) {
        var map = UserDefaults.standard.dictionary(forKey: key) ?? [:]
        map[asset.localIdentifier] = NSNumber(value: id)
        UserDefaults.standard.set(map, forKey: key)
    }

    /// The photo in Latent for this asset, copying it in first if needed.
    func bring(_ asset: PHAsset, into library: Library) async -> Photo? {
        if let id = Self.imported(asset), let p = library.photo(id) { return p }
        bringing = asset.localIdentifier
        defer { bringing = nil }
        do {
            let url = try await Self.copyOriginal(asset)
            guard let id = await library.importFiles([url]).first, let p = library.photo(id) else { return nil }
            Self.remember(asset, id)
            return p
        } catch {
            library.notice = error.localizedDescription
            return nil
        }
    }

    /// Write the asset's original file (its raw file, if it has one) into the Import folder.
    private static func copyOriginal(_ asset: PHAsset) async throws -> URL {
        let resources = PHAssetResource.assetResources(for: asset)
        let isRaw = { (r: PHAssetResource) in
            UTType(filenameExtension: (r.originalFilename as NSString).pathExtension)?.conforms(to: .rawImage) ?? false
        }
        guard let resource = resources.first(where: { ($0.type == .alternatePhoto || $0.type == .photo) && isRaw($0) })
            ?? resources.first(where: { $0.type == .photo })
            ?? resources.first(where: { $0.type == .fullSizePhoto })
            ?? resources.first
        else {
            throw EngineError(message: "This photo has no file Latent can open.")
        }
        let name = resource.originalFilename.isEmpty ? "Photo.jpg" : resource.originalFilename
        let dest = Library.importFolder.appendingPathComponent(name)
        var target = dest
        var n = 1
        while FileManager.default.fileExists(atPath: target.path) {
            let base = dest.deletingPathExtension().lastPathComponent
            target = dest.deletingLastPathComponent().appendingPathComponent("\(base)-\(n)").appendingPathExtension(dest.pathExtension)
            n += 1
        }
        let options = PHAssetResourceRequestOptions()
        options.isNetworkAccessAllowed = true
        try await PHAssetResourceManager.default().writeData(for: resource, toFile: target, options: options)
        return target
    }
}

struct DeviceView: View {
    @ObservedObject var library: Library
    let open: (Photo) -> Void
    @StateObject private var album = DeviceAlbum()

    private let columns = Array(repeating: GridItem(.flexible(), spacing: 2), count: 4)

    var body: some View {
        Group {
            if album.allowed, let assets = album.assets {
                ScrollView {
                    header(count: assets.count)
                    LazyVGrid(columns: columns, spacing: 2) {
                        ForEach(0..<assets.count, id: \.self) { i in
                            let asset = assets.object(at: i)
                            Button {
                                Task {
                                    if let p = await album.bring(asset, into: library) { open(p) }
                                }
                            } label: {
                                AssetThumb(asset: asset, manager: album.images, bringing: album.bringing == asset.localIdentifier,
                                           edited: DeviceAlbum.imported(asset).flatMap(library.photo)?.edited ?? false)
                            }
                            .buttonStyle(.plain)
                            .disabled(album.bringing != nil)
                            .accessibilityLabel(Text(asset.creationDate.map { $0.formatted(date: .abbreviated, time: .shortened) } ?? "Photo"))
                        }
                    }
                }
                .scrollIndicators(.hidden)
                .refreshable { album.load() }
            } else if album.status == .notDetermined || (album.allowed && album.assets == nil) {
                VStack(spacing: 12) {
                    ProgressView().tint(.white)
                    Text("Looking for photos on this iPhone\u{2026}").font(.system(size: 15)).foregroundStyle(Theme.secondaryText)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                denied
            }
        }
        .task { await album.start() }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.willEnterForegroundNotification)) { _ in album.load() }
    }

    private func header(count: Int) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("Camera Roll").font(.system(size: 30, weight: .bold))
                Text(album.status == .limited ? "\(count) photos you allowed" : "\(count) photos")
                    .font(.system(size: 14))
                    .foregroundStyle(Theme.secondaryText)
                    .monospacedDigit()
            }
            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 12)
    }

    private var denied: some View {
        VStack(spacing: 14) {
            Image(systemName: "photo.badge.exclamationmark")
                .font(.system(size: 44, weight: .light))
                .foregroundStyle(Theme.secondaryText)
            Text("Latent can't see your photos").font(.system(size: 20, weight: .semibold))
            Text("Allow access in Settings to browse this iPhone's photos here. You can still add photos with + at the top.")
                .font(.system(size: 15))
                .foregroundStyle(Theme.secondaryText)
                .multilineTextAlignment(.center)
            Button {
                if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
            } label: {
                Text("Open Settings").font(.system(size: 15, weight: .semibold)).padding(.horizontal, 20).frame(height: 44)
                    .latentGlass(in: Capsule(), tint: Theme.accent.opacity(0.8), interactive: true)
            }
            .foregroundStyle(.white)
        }
        .padding(28)
        .latentGlass(in: RoundedRectangle(cornerRadius: 30, style: .continuous))
        .padding(.horizontal, 20)
        .frame(maxHeight: .infinity)
    }
}

/// A square thumbnail of a photo on the iPhone, marked when it's already in Latent.
struct AssetThumb: View {
    let asset: PHAsset
    let manager: PHCachingImageManager
    let bringing: Bool
    var edited = false
    @State private var image: UIImage?

    var body: some View {
        Color(white: 0.12)
            .aspectRatio(1, contentMode: .fit)
            .overlay {
                if let image {
                    Image(uiImage: image).resizable().scaledToFill().transition(.opacity)
                } else {
                    Shimmer()
                }
            }
            .clipped()
            .overlay(alignment: .topLeading) {
                if edited {
                    Image(systemName: "slider.horizontal.3")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(.white)
                        .padding(5)
                        .background(Color.black.opacity(0.5), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                        .padding(5)
                        .accessibilityLabel(Text("Edited"))
                } else if DeviceAlbum.imported(asset) != nil {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 14, weight: .semibold))
                        .symbolRenderingMode(.palette)
                        .foregroundStyle(.white, Theme.accent)
                        .padding(5)
                }
            }
            .overlay {
                if bringing {
                    ZStack {
                        Color.black.opacity(0.4)
                        ProgressView().tint(.white)
                    }
                }
            }
            .task(id: asset.localIdentifier) {
                let img = await load()
                withAnimation(.easeOut(duration: 0.2)) { image = img }
            }
    }

    private func load() async -> UIImage? {
        await withCheckedContinuation { done in
            let o = PHImageRequestOptions()
            o.deliveryMode = .highQualityFormat
            o.resizeMode = .fast
            o.isNetworkAccessAllowed = true
            let side = 120 * UIScreen.main.scale
            manager.requestImage(for: asset, targetSize: CGSize(width: side, height: side), contentMode: .aspectFill, options: o) { img, _ in
                done.resume(returning: img)
            }
        }
    }
}
