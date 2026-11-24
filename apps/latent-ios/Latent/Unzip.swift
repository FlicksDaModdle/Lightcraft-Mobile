import Compression
import Foundation

/// Unpacks a .zip archive (stored and deflated entries, as model downloads use) into a folder,
/// streaming each entry to disk so a large file needn't fit in memory.
enum Unzip {
    struct Failure: LocalizedError {
        let reason: String
        var errorDescription: String? { "The download couldn't be unpacked (\(reason))." }
    }

    static func extract(_ archive: URL, into folder: URL) throws {
        let h = try FileHandle(forReadingFrom: archive)
        defer { try? h.close() }
        let size = try h.seekToEnd()
        // the end-of-central-directory record is in the last 64 KiB + 22 bytes
        let tail = Swift.min(size, 65_557)
        try h.seek(toOffset: size - tail)
        let end = try h.read(upToCount: Int(tail)) ?? Data()
        guard let eocd = lastIndex(of: [0x50, 0x4b, 0x05, 0x06], in: end) else { throw Failure(reason: "no directory") }
        let count = Int(u16(end, eocd + 10))
        let dirSize = UInt64(u32(end, eocd + 12)), dirOffset = UInt64(u32(end, eocd + 16))
        guard dirOffset + dirSize <= size else { throw Failure(reason: "a damaged directory") }
        try h.seek(toOffset: dirOffset)
        let dir = try h.read(upToCount: Int(dirSize)) ?? Data()
        var p = 0
        for _ in 0..<count {
            guard p + 46 <= dir.count, u32(dir, p) == 0x0201_4b50 else { throw Failure(reason: "a damaged entry") }
            let method = u16(dir, p + 10)
            let packed = UInt64(u32(dir, p + 20)), unpacked = UInt64(u32(dir, p + 24))
            let nameLen = Int(u16(dir, p + 28)), extraLen = Int(u16(dir, p + 30)), commentLen = Int(u16(dir, p + 32))
            let local = UInt64(u32(dir, p + 42))
            guard p + 46 + nameLen <= dir.count else { throw Failure(reason: "a damaged name") }
            let name = String(decoding: dir[(dir.startIndex + p + 46)..<(dir.startIndex + p + 46 + nameLen)], as: UTF8.self)
            p += 46 + nameLen + extraLen + commentLen
            // skip macOS's resource forks and anything that would land outside the folder
            if name.hasPrefix("__MACOSX/") || name.contains("../") || name.hasPrefix("/") { continue }
            let dest = folder.appendingPathComponent(name)
            if name.hasSuffix("/") {
                try FileManager.default.createDirectory(at: dest, withIntermediateDirectories: true)
                continue
            }
            try FileManager.default.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
            // the local header's own name and extra lengths say where the data starts
            try h.seek(toOffset: local)
            guard let lh = try h.read(upToCount: 30), lh.count == 30, u32(lh, 0) == 0x0403_4b50 else { throw Failure(reason: "a damaged file header") }
            try h.seek(toOffset: local + 30 + UInt64(u16(lh, 26)) + UInt64(u16(lh, 28)))
            FileManager.default.createFile(atPath: dest.path, contents: nil)
            let out = try FileHandle(forWritingTo: dest)
            defer { try? out.close() }
            switch method {
            case 0: try copy(h, packed, to: out)
            case 8: try inflate(h, packed, to: out, expected: unpacked)
            default: throw Failure(reason: "an unsupported compression")
            }
        }
    }

    private static func copy(_ h: FileHandle, _ n: UInt64, to out: FileHandle) throws {
        var left = n
        while left > 0 {
            let chunk = try h.read(upToCount: Int(Swift.min(left, 1 << 20))) ?? Data()
            guard !chunk.isEmpty else { throw Failure(reason: "a short file") }
            try out.write(contentsOf: chunk)
            left -= UInt64(chunk.count)
        }
    }

    /// Raw deflate (what zip uses), streamed.
    private static func inflate(_ h: FileHandle, _ n: UInt64, to out: FileHandle, expected: UInt64) throws {
        let stream = UnsafeMutablePointer<compression_stream>.allocate(capacity: 1)
        defer { stream.deallocate() }
        guard compression_stream_init(stream, COMPRESSION_STREAM_DECODE, COMPRESSION_ZLIB) == COMPRESSION_STATUS_OK else {
            throw Failure(reason: "no decompressor")
        }
        defer { compression_stream_destroy(stream) }
        let outSize = 1 << 20
        let dst = UnsafeMutablePointer<UInt8>.allocate(capacity: outSize)
        defer { dst.deallocate() }
        var left = n, written: UInt64 = 0
        var finished = false
        while !finished {
            let chunk = left > 0 ? (try h.read(upToCount: Int(Swift.min(left, 1 << 20))) ?? Data()) : Data()
            left -= UInt64(chunk.count)
            let last = left == 0
            try chunk.withUnsafeBytes { (src: UnsafeRawBufferPointer) in
                stream.pointee.src_ptr = src.bindMemory(to: UInt8.self).baseAddress ?? UnsafePointer(dst)
                stream.pointee.src_size = chunk.count
                repeat {
                    stream.pointee.dst_ptr = dst
                    stream.pointee.dst_size = outSize
                    let status = compression_stream_process(stream, last ? Int32(COMPRESSION_STREAM_FINALIZE.rawValue) : 0)
                    let made = outSize - stream.pointee.dst_size
                    if made > 0 {
                        try out.write(contentsOf: Data(bytes: dst, count: made))
                        written += UInt64(made)
                    }
                    switch status {
                    case COMPRESSION_STATUS_END: finished = true
                    case COMPRESSION_STATUS_OK: break
                    default: throw Failure(reason: "damaged data")
                    }
                } while stream.pointee.src_size > 0 || (stream.pointee.dst_size == 0 && !finished)
            }
            if last && !finished && chunk.isEmpty { break }
        }
        guard expected == 0 || written == expected else { throw Failure(reason: "a short file") }
    }

    private static func u16(_ d: Data, _ o: Int) -> UInt16 {
        let i = d.startIndex + o
        return UInt16(d[i]) | UInt16(d[i + 1]) << 8
    }

    private static func u32(_ d: Data, _ o: Int) -> UInt32 {
        let i = d.startIndex + o
        return UInt32(d[i]) | UInt32(d[i + 1]) << 8 | UInt32(d[i + 2]) << 16 | UInt32(d[i + 3]) << 24
    }

    private static func lastIndex(of sig: [UInt8], in d: Data) -> Int? {
        guard d.count >= 22 else { return nil }
        var i = d.count - 22
        while i >= 0 {
            if d[d.startIndex + i] == sig[0], d[d.startIndex + i + 1] == sig[1], d[d.startIndex + i + 2] == sig[2], d[d.startIndex + i + 3] == sig[3] { return i }
            i -= 1
        }
        return nil
    }
}
