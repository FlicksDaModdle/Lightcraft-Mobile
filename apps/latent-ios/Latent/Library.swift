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
        guard !urls.isEmpty else { return }
        importing = true
        let paths = urls.map(\.path)
        Task {
            let result: Result<Any, Error> = await Task.detached(priority: .userInitiated) {
                Result { try Engine.shared.run("library.import", ["paths": paths]) }
            }.value
            importing = false
            if case .failure(let e) = result { notice = e.localizedDescription }
            reload()
        }
    }

    /// Where picked photos are copied before they are added: Documents/Import (shown in Files).
    static var importFolder: URL {
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

    /// Forget a photo's thumbnail (after it was edited).
    func forget(_ id: UInt64) { cache.removeObject(forKey: NSNumber(value: id)) }
}
