import CoreGraphics
import CoreTransferable
import Foundation
import SwiftUI
import UniformTypeIdentifiers

/// The photos in the library, and adding more.
@MainActor
final class Library: ObservableObject {
    @Published private(set) var photos: [Photo] = []
    @Published private(set) var importing = false
    @Published var notice: String?
    @Published var filter: LibraryFilter = .all
    @Published var sort: LibrarySort = .newest

    /// The photos the filter lets through, in the chosen order.
    var shown: [Photo] {
        let kept = photos.filter(filter.keeps)
        switch sort {
        case .newest: return kept.sorted { ($0.captured, $0.id) > ($1.captured, $1.id) }
        case .oldest: return kept.sorted { ($0.captured, $0.id) < ($1.captured, $1.id) }
        case .added: return kept.sorted { $0.id > $1.id }
        case .name: return kept.sorted { $0.fileName.localizedStandardCompare($1.fileName) == .orderedAscending }
        }
    }

    init() {
        notice = Engine.shared.problem
        reload()
    }

    func reload() {
        do {
            let r = try Engine.shared.run("catalog.query", ["limit": 1_000_000])
            let list = (r as? [String: Any])?["photos"] as? [Any] ?? []
            photos = list.compactMap(Photo.init)
        } catch {
            notice = error.localizedDescription
        }
    }

    /// Add files the picker copied into the Import folder.
    func add(_ urls: [URL]) {
        Task { _ = await importFiles(urls) }
    }

    /// Add files and return the new photos' ids.
    func importFiles(_ urls: [URL]) async -> [UInt64] {
        guard !urls.isEmpty else { return [] }
        importing = true
        let paths = urls.map(\.path)
        let result: Result<Any, Error> = await Task.detached(priority: .userInitiated) {
            Result { try Engine.shared.run("library.import", ["paths": paths]) }
        }.value
        importing = false
        reload()
        switch result {
        case .success(let v):
            return ((v as? [String: Any])?["imported"] as? [NSNumber])?.map(\.uint64Value) ?? []
        case .failure(let e):
            notice = e.localizedDescription
            return []
        }
    }

    func photo(_ id: UInt64) -> Photo? { photos.first { $0.id == id } }

    func rate(_ p: Photo, _ stars: Int) { change("photo.rate", ["rating": stars, "ids": [p.id]]) }
    func flag(_ p: Photo, _ flag: String) { change("photo.flag", ["flag": flag, "ids": [p.id]]) }

    // MARK: several photos at once

    /// Whether edits have been copied (from the editor or a photo's menu), so they can be pasted.
    var canPaste: Bool { EditorModel.copied }

    /// Copy photo `p`'s edits (all but crop, masks and spots), to paste on others.
    func copyEdits(_ p: Photo) {
        do {
            try Engine.shared.run("library.select", ["ids": [p.id], "active": p.id])
            try Engine.shared.run("develop.copy")
            EditorModel.copied = true
            notice = nil
        } catch {
            notice = error.localizedDescription
        }
    }

    func pasteEdits(_ ids: [UInt64]) { bulk("develop.paste", ["ids": ids], ids) }
    func applyPreset(_ preset: String, to ids: [UInt64]) { bulk("preset.apply", ["id": preset, "ids": ids], ids) }
    func resetEdits(_ ids: [UInt64]) { bulk("develop.reset", ["ids": ids], ids) }

    func remove(_ ids: [UInt64]) {
        change("photo.delete", ["ids": ids])
        ids.forEach(Thumbnails.shared.forget)
    }

    /// The presets, for the menu of several photos.
    func presets() -> [Preset] {
        ((try? Engine.shared.run("presets.list")) as? [Any] ?? []).compactMap(Preset.init)
    }

    private func bulk(_ command: String, _ params: [String: Any], _ ids: [UInt64]) {
        ids.forEach(Thumbnails.shared.forget)
        change(command, params)
    }

    /// Take a photo out of the library (the engine keeps it in Recently Deleted).
    func remove(_ p: Photo) {
        change("photo.delete", ["ids": [p.id]])
        Thumbnails.shared.forget(p.id)
    }

    private func change(_ command: String, _ params: [String: Any]) {
        do {
            try Engine.shared.run(command, params)
        } catch {
            notice = error.localizedDescription
        }
        reload()
    }

    /// Where picked photos are copied before they are added: Documents/Import (shown in Files).
    nonisolated static var importFolder: URL {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let dir = docs.appendingPathComponent("Import", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }
}

/// A photo the Photos picker handed over as a file (raw files stay raw), copied into the Import folder.
struct PickedFile: Transferable {
    let url: URL

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(importedContentType: .image) { received in
            let dest = Library.importFolder.appendingPathComponent(received.file.lastPathComponent)
            var target = dest
            var n = 1
            while FileManager.default.fileExists(atPath: target.path) {
                let base = dest.deletingPathExtension().lastPathComponent
                target = dest.deletingLastPathComponent().appendingPathComponent("\(base)-\(n)").appendingPathExtension(dest.pathExtension)
                n += 1
            }
            try FileManager.default.copyItem(at: received.file, to: target)
            return PickedFile(url: target)
        }
    }
}

/// Thumbnails, rendered by the engine a few at a time and kept in memory.
final class Thumbnails: @unchecked Sendable {
    static let shared = Thumbnails()

    private let cache = NSCache<NSNumber, CGImageBox>()
    private let queue: OperationQueue = {
        let q = OperationQueue()
        q.maxConcurrentOperationCount = 3
        q.qualityOfService = .userInitiated
        return q
    }()

    final class CGImageBox {
        let image: CGImage
        init(_ image: CGImage) { self.image = image }
    }

    func cached(_ id: UInt64) -> CGImage? { cache.object(forKey: NSNumber(value: id))?.image }

    func load(_ id: UInt64, longEdge: Int) async -> CGImage? {
        if let hit = cached(id) { return hit }
        return await withCheckedContinuation { done in
            queue.addOperation {
                let img = Engine.shared.thumbnail(id, longEdge: longEdge)
                if let img { self.cache.setObject(CGImageBox(img), forKey: NSNumber(value: id)) }
                done.resume(returning: img)
            }
        }
    }

    /// A profile's preview on a photo, cached with the preset previews.
    func profile(_ id: UInt64, profile: String, longEdge: Int) async -> CGImage? {
        let key = "profile:\(id)/\(profile)" as NSString
        if let hit = presetCache.object(forKey: key) { return hit.image }
        return await withCheckedContinuation { done in
            queue.addOperation {
                let img = Engine.shared.profileThumbnail(id, profile: profile, longEdge: longEdge)
                if let img { self.presetCache.setObject(CGImageBox(img), forKey: key) }
                done.resume(returning: img)
            }
        }
    }

    func cachedProfile(_ id: UInt64, profile: String) -> CGImage? { presetCache.object(forKey: "profile:\(id)/\(profile)" as NSString)?.image }

    /// A preset's preview on a photo, cached until [`forgetPresets`].
    func preset(_ id: UInt64, preset: String, longEdge: Int) async -> CGImage? {
        let key = "\(id)/\(preset)" as NSString
        if let hit = presetCache.object(forKey: key) { return hit.image }
        return await withCheckedContinuation { done in
            queue.addOperation {
                let img = Engine.shared.presetThumbnail(id, preset: preset, longEdge: longEdge)
                if let img { self.presetCache.setObject(CGImageBox(img), forKey: key) }
                done.resume(returning: img)
            }
        }
    }

    func cachedPreset(_ id: UInt64, preset: String) -> CGImage? { presetCache.object(forKey: "\(id)/\(preset)" as NSString)?.image }

    /// Forget the preset previews (the photo's edit changed under them).
    func forgetPresets() { presetCache.removeAllObjects() }

    private let presetCache = NSCache<NSString, CGImageBox>()

    /// Forget a photo's thumbnail (after it was edited).
    func forget(_ id: UInt64) { cache.removeObject(forKey: NSNumber(value: id)) }
}

/// Which photos the library shows.
enum LibraryFilter: String, CaseIterable, Identifiable {
    case all, edited, unedited, picks, rated
    var id: String { rawValue }
    var label: String {
        switch self {
        case .all: return "All photos"
        case .edited: return "Edited"
        case .unedited: return "Not edited"
        case .picks: return "Picks"
        case .rated: return "Rated"
        }
    }
    var symbol: String {
        switch self {
        case .all: return "photo.on.rectangle"
        case .edited: return "slider.horizontal.3"
        case .unedited: return "photo"
        case .picks: return "flag.fill"
        case .rated: return "star.fill"
        }
    }
    func keeps(_ p: Photo) -> Bool {
        switch self {
        case .all: return true
        case .edited: return p.edited
        case .unedited: return !p.edited
        case .picks: return p.flag == "pick"
        case .rated: return p.rating > 0
        }
    }
}

enum LibrarySort: String, CaseIterable, Identifiable {
    case newest, oldest, added, name
    var id: String { rawValue }
    var label: String {
        switch self {
        case .newest: return "Newest first"
        case .oldest: return "Oldest first"
        case .added: return "Recently added"
        case .name: return "File name"
        }
    }
}

/// Photo Merge: HDR from bracketed shots, a panorama from overlapping ones, or both.
enum Merging {
    nonisolated(unsafe) private static var onProgress: ((Double, String) -> Void)?
    nonisolated(unsafe) static var cancelled = false

    /// Run `command` (merge.hdr, merge.panorama, merge.hdrPanorama) with `options` on `ids`; returns the new photo.
    static func run(_ command: String, ids: [UInt64], options: [String: Any], progress: @escaping @MainActor (Double, String) -> Void) async throws -> UInt64? {
        var params = options
        params["ids"] = ids
        let p = params
        cancelled = false
        return try await Task.detached(priority: .userInitiated) {
            onProgress = { f, stage in Task { @MainActor in progress(f, stage) } }
            defer { onProgress = nil }
            let out = try Engine.shared.merge(command, p) { fraction, stage in
                Merging.onProgress?(Double(fraction), stage.map { String(cString: $0) } ?? "")
                return !Merging.cancelled
            }
            return (out["id"] as? NSNumber)?.uint64Value
        }.value
    }
}
