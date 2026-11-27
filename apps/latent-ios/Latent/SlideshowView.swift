import AVFoundation
import Photos
import SwiftUI

/// A slideshow of photos with their edits: each shown for a while, crossfading into the next, full screen, and
/// saved as a video when asked. The timing is the engine's slideshow settings (`slideshow.playback`), so it matches
/// the desktop's.
struct SlideshowView: View {
    let photos: [Photo]
    @Environment(\.dismiss) private var dismiss
    @State private var order: [Photo] = []
    @State private var index = 0
    @State private var current: CGImage?
    @State private var playing = true
    @State private var controls = true
    @State private var duration = 4.0
    @State private var fade = 1.0
    @State private var repeats = true
    @State private var saving: Double?
    @State private var message: String?
    @State private var timer: Task<Void, Never>?

    var body: some View {
        GeometryReader { geo in
            ZStack {
                Color.black.ignoresSafeArea()
                if let current {
                    Image(decorative: current, scale: 1)
                        .resizable()
                        .scaledToFit()
                        .frame(width: geo.size.width, height: geo.size.height)
                        .id(index)
                        .transition(.opacity)
                }
                if controls { overlay }
            }
            .contentShape(Rectangle())
            .onTapGesture { withAnimation(.easeInOut(duration: 0.2)) { controls.toggle() } }
            .task {
                loadSettings()
                order = photos
                await show(0, size: geo.size)
                schedule(size: geo.size)
            }
            .onChange(of: playing) { _, on in if on { schedule(size: geo.size) } else { timer?.cancel() } }
        }
        .statusBarHidden(!controls)
        .onDisappear { timer?.cancel() }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text("Slideshow, photo \(index + 1) of \(max(order.count, 1))"))
    }

    private var overlay: some View {
        VStack {
            HStack {
                Button { dismiss() } label: {
                    Image(systemName: "xmark").font(.system(size: 16, weight: .semibold)).frame(width: 44, height: 44)
                        .latentGlass(in: Circle(), interactive: true)
                }
                .accessibilityLabel(Text("Close"))
                Spacer()
                Text("\(index + 1) of \(order.count)").font(.system(size: 14, weight: .semibold)).monospacedDigit()
                    .padding(.horizontal, 12).frame(height: 36).latentGlass(in: Capsule())
                Spacer()
                Menu {
                    Picker("Each photo", selection: $duration) {
                        ForEach([2.0, 3, 4, 6, 8, 12], id: \.self) { Text("\(Int($0)) seconds").tag($0) }
                    }
                    Picker("Crossfade", selection: $fade) {
                        Text("None").tag(0.0)
                        Text("Short").tag(0.5)
                        Text("Medium").tag(1.0)
                        Text("Long").tag(2.0)
                    }
                    Toggle("Repeat", isOn: $repeats)
                    Button { order.shuffle() } label: { Label("Shuffle", systemImage: "shuffle") }
                } label: {
                    Image(systemName: "slider.horizontal.3").font(.system(size: 16, weight: .semibold)).frame(width: 44, height: 44)
                        .latentGlass(in: Circle(), interactive: true)
                }
                .accessibilityLabel(Text("Slideshow settings"))
                .onChange(of: duration) { _, _ in saveSettings() }
                .onChange(of: fade) { _, _ in saveSettings() }
                .onChange(of: repeats) { _, _ in saveSettings() }
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 16)
            Spacer()
            if let message {
                Text(message).font(.system(size: 13)).foregroundStyle(.white)
                    .padding(.horizontal, 14).padding(.vertical, 8).latentGlass(in: Capsule())
            }
            HStack(spacing: 14) {
                Button { playing.toggle() } label: {
                    Image(systemName: playing ? "pause.fill" : "play.fill").font(.system(size: 20, weight: .semibold))
                        .frame(width: 56, height: 56).latentGlass(in: Circle(), interactive: true)
                }
                .accessibilityLabel(Text(playing ? "Pause" : "Play"))
                Button { saveVideo() } label: {
                    Group {
                        if let saving {
                            ProgressView(value: saving).frame(width: 120)
                        } else {
                            Label("Save video", systemImage: "film").font(.system(size: 15, weight: .semibold))
                        }
                    }
                    .padding(.horizontal, 18).frame(height: 56)
                    .latentGlass(in: Capsule(), interactive: true)
                }
                .disabled(saving != nil)
            }
            .foregroundStyle(.white)
            .padding(.bottom, 20)
        }
        .transition(.opacity)
    }

    // MARK: playing

    private func show(_ i: Int, size: CGSize) async {
        guard order.indices.contains(i) else { return }
        let id = order[i].id
        let scale = UIScreen.main.scale
        let px = CGSize(width: size.width * scale, height: size.height * scale)
        let img = await Task.detached(priority: .userInitiated) { Engine.shared.render(id, fitting: px)?.image }.value
        withAnimation(.easeInOut(duration: fade)) {
            index = i
            current = img
        }
    }

    private func schedule(size: CGSize) {
        timer?.cancel()
        timer = Task {
            while !Task.isCancelled && playing {
                try? await Task.sleep(for: .seconds(duration))
                guard !Task.isCancelled, playing else { return }
                var next = index + 1
                if next >= order.count {
                    guard repeats else {
                        playing = false
                        return
                    }
                    next = 0
                }
                await show(next, size: size)
            }
        }
    }

    // MARK: settings

    private func loadSettings() {
        let p = ((try? Engine.shared.run("slideshow.playback")) as? [String: Any]) ?? [:]
        let s = (p["playback"] as? [String: Any]) ?? p
        if let d = (s["slideDuration"] as? NSNumber)?.doubleValue, d > 0 { duration = d }
        if let f = (s["fadeDuration"] as? NSNumber)?.doubleValue { fade = f }
        if let r = s["repeat"] as? Bool { repeats = r }
        if s["randomOrder"] as? Bool == true { order.shuffle() }
    }

    private func saveSettings() {
        _ = try? Engine.shared.run("slideshow.playback", ["slideDuration": duration, "fadeDuration": Swift.min(fade, duration), "repeat": repeats])
    }

    // MARK: video

    /// Write the slideshow as a 1080p video and save it to the photo library.
    private func saveVideo() {
        let ids = order.map(\.id)
        let (slide, cross) = (duration, Swift.min(fade, duration / 2))
        saving = 0
        message = nil
        Task {
            do {
                let url = try await SlideshowVideo.write(ids, slide: slide, fade: cross) { p in saving = p }
                try await PHPhotoLibrary.shared().performChanges {
                    PHAssetChangeRequest.creationRequestForAssetFromVideo(atFileURL: url)
                }
                try? FileManager.default.removeItem(at: url)
                message = "Saved to your photo library"
                UINotificationFeedbackGenerator().notificationOccurred(.success)
            } catch {
                message = error.localizedDescription
            }
            saving = nil
        }
    }
}

/// A slideshow as an H.264 video: each photo on black, fitted to 1920 × 1080, crossfading into the next.
enum SlideshowVideo {
    static let size = CGSize(width: 1920, height: 1080)
    static let fps: Int32 = 30

    static func write(_ ids: [UInt64], slide: Double, fade: Double, progress: @escaping @MainActor (Double) -> Void) async throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("Slideshow-\(UUID().uuidString).mp4")
        try await Task.detached(priority: .userInitiated) {
            let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
            let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
                AVVideoCodecKey: AVVideoCodecType.h264,
                AVVideoWidthKey: Int(size.width),
                AVVideoHeightKey: Int(size.height),
                AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: 12_000_000],
            ])
            input.expectsMediaDataInRealTime = false
            let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: Int(size.width),
                kCVPixelBufferHeightKey as String: Int(size.height),
            ])
            guard writer.canAdd(input) else { throw EngineError(message: "The video couldn't be started.") }
            writer.add(input)
            guard writer.startWriting() else { throw EngineError(message: writer.error?.localizedDescription ?? "The video couldn't be started.") }
            writer.startSession(atSourceTime: .zero)

            let slideFrames = Swift.max(Int(slide * Double(fps)), 1)
            let fadeFrames = Swift.min(Int(fade * Double(fps)), slideFrames / 2)
            var frame: Int64 = 0
            var previous: CGImage?
            for (i, id) in ids.enumerated() {
                guard let img = Engine.shared.render(id, fitting: size)?.image else { continue }
                for f in 0..<slideFrames {
                    // the first frames of each slide fade in from the last one
                    let t = (f < fadeFrames && previous != nil) ? Double(f + 1) / Double(fadeFrames + 1) : 1
                    while !input.isReadyForMoreMediaData { try await Task.sleep(for: .milliseconds(5)) }
                    guard let pool = adaptor.pixelBufferPool, let buffer = draw(img, over: t < 1 ? previous : nil, mix: t, pool: pool) else {
                        throw EngineError(message: "The video frame couldn't be drawn.")
                    }
                    adaptor.append(buffer, withPresentationTime: CMTime(value: frame, timescale: fps))
                    frame += 1
                }
                previous = img
                let done = Double(i + 1) / Double(ids.count)
                Task { @MainActor in progress(done) }
            }
            input.markAsFinished()
            await writer.finishWriting()
            if writer.status != .completed { throw EngineError(message: writer.error?.localizedDescription ?? "The video couldn't be finished.") }
        }.value
        return url
    }

    /// One frame: `image` fitted on black, over `under` faded out by `mix`.
    private static func draw(_ image: CGImage, over under: CGImage?, mix: Double, pool: CVPixelBufferPool) -> CVPixelBuffer? {
        var buffer: CVPixelBuffer?
        guard CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer) == kCVReturnSuccess, let buffer else { return nil }
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        guard let ctx = CGContext(data: CVPixelBufferGetBaseAddress(buffer), width: Int(size.width), height: Int(size.height), bitsPerComponent: 8,
                                  bytesPerRow: CVPixelBufferGetBytesPerRow(buffer), space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue) else { return nil }
        ctx.setFillColor(CGColor(gray: 0, alpha: 1))
        ctx.fill(CGRect(origin: .zero, size: size))
        ctx.interpolationQuality = .high
        func fit(_ img: CGImage) -> CGRect {
            let s = Swift.min(size.width / CGFloat(img.width), size.height / CGFloat(img.height))
            let w = CGFloat(img.width) * s, h = CGFloat(img.height) * s
            return CGRect(x: (size.width - w) / 2, y: (size.height - h) / 2, width: w, height: h)
        }
        if let under {
            ctx.setAlpha(1)
            ctx.draw(under, in: fit(under))
        }
        ctx.setAlpha(CGFloat(mix))
        ctx.draw(image, in: fit(image))
        return buffer
    }
}
