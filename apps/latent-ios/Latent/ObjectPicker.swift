import CoreGraphics
import CoreVideo
import Foundation
import CoreML
import Vision

/// Picking a whole object (a person, an animal, a thing) by tapping it, with Apple's Vision
/// foreground segmentation: no download, any iPhone on iOS 26.
enum ObjectPicker {
    /// Coverage 0…1 per pixel of `image` for the object Vision finds at `p` (0…1 across and down),
    /// or nil when there's none there.
    static func object(in image: CGImage, at p: CGPoint) throws -> (values: [Float], width: Int, height: Int)? {
        let request = VNGenerateForegroundInstanceMaskRequest()
        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        try handler.perform([request])
        guard let found = request.results?.first, let label = label(found.instanceMask, near: p) else { return nil }
        let buf = try found.generateScaledMaskForImage(forInstances: IndexSet(integer: label), from: handler)
        return floats(buf)
    }

    /// The instance under `p`, else the nearest within a few percent of the picture.
    private static func label(_ labels: CVPixelBuffer, near p: CGPoint) -> Int? {
        CVPixelBufferLockBaseAddress(labels, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(labels, .readOnly) }
        let w = CVPixelBufferGetWidth(labels), h = CVPixelBufferGetHeight(labels)
        let row = CVPixelBufferGetBytesPerRow(labels)
        guard let base = CVPixelBufferGetBaseAddress(labels)?.assumingMemoryBound(to: UInt8.self), w > 0, h > 0 else { return nil }
        let cx = Int(p.x * CGFloat(w)), cy = Int(p.y * CGFloat(h))
        let reach = Swift.max(w, h) / 25
        var best: (Int, Int)?
        for dy in -reach...reach {
            for dx in -reach...reach {
                let x = cx + dx, y = cy + dy
                guard (0..<w).contains(x), (0..<h).contains(y) else { continue }
                let v = Int(base[y * row + x])
                let d = dx * dx + dy * dy
                if v != 0, d < (best?.1 ?? .max) { best = (v, d) }
            }
        }
        return best?.0
    }

    private static func floats(_ buf: CVPixelBuffer) -> (values: [Float], width: Int, height: Int)? {
        CVPixelBufferLockBaseAddress(buf, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buf, .readOnly) }
        let w = CVPixelBufferGetWidth(buf), h = CVPixelBufferGetHeight(buf)
        let row = CVPixelBufferGetBytesPerRow(buf)
        guard let base = CVPixelBufferGetBaseAddress(buf), w > 0, h > 0 else { return nil }
        let eight = CVPixelBufferGetPixelFormatType(buf) == kCVPixelFormatType_OneComponent8
        var out = [Float](repeating: 0, count: w * h)
        for y in 0..<h {
            let line = base.advanced(by: y * row)
            for x in 0..<w {
                out[y * w + x] = eight ? Float(line.assumingMemoryBound(to: UInt8.self)[x]) / 255 : line.assumingMemoryBound(to: Float.self)[x]
            }
        }
        return (out, w, h)
    }

    /// The coverage as `side × side` bytes over the photo (stretched to a square), the way the
    /// engine stores segmentations. `place` maps a point of that square to the picture.
    static func grid(_ c: (values: [Float], width: Int, height: Int), side: Int, place: (CGPoint) -> CGPoint) -> [UInt8] {
        var out = [UInt8](repeating: 0, count: side * side)
        for gy in 0..<side {
            for gx in 0..<side {
                let q = place(CGPoint(x: (CGFloat(gx) + 0.5) / CGFloat(side), y: (CGFloat(gy) + 0.5) / CGFloat(side)))
                let x = Swift.min(Swift.max(Int(q.x * CGFloat(c.width)), 0), c.width - 1)
                let y = Swift.min(Swift.max(Int(q.y * CGFloat(c.height)), 0), c.height - 1)
                out[gy * side + gx] = UInt8(Swift.min(Swift.max(c.values[y * c.width + x], 0), 1) * 255)
            }
        }
        return out
    }

    /// Spot points that cover the object with a little to spare, and their radius (a fraction
    /// of the long edge): a grid of round dabs over the object, so the fix reaches past its edge.
    static func spot(_ c: (values: [Float], width: Int, height: Int)) -> (points: [CGPoint], size: Double)? {
        let (w, h) = (c.width, c.height)
        let long = CGFloat(Swift.max(w, h))
        let area = c.values.reduce(0) { $0 + ($1 > 0.5 ? 1 : 0) }
        guard area > 0 else { return nil }
        // big enough dabs that a person takes a few hundred, small enough to keep close to the edge
        var r = Swift.max(long * 0.015, CGFloat(area).squareRoot() / 10)
        var pts: [CGPoint] = []
        for _ in 0..<4 {
            pts = []
            let step = r * 0.8
            var y = step / 2
            while y < CGFloat(h) {
                var x = step / 2
                while x < CGFloat(w) {
                    // inside, or within half a step of it
                    if covered(c, x, y, step / 2) { pts.append(CGPoint(x: x / CGFloat(w), y: y / CGFloat(h))) }
                    x += step
                }
                y += step
            }
            if pts.count <= 400 { break }
            r *= 1.4
        }
        guard !pts.isEmpty else { return nil }
        return (pts, Double(r / long * 1.2))
    }

    private static func covered(_ c: (values: [Float], width: Int, height: Int), _ x: CGFloat, _ y: CGFloat, _ reach: CGFloat) -> Bool {
        for (dx, dy) in [(0, 0), (-1, 0), (1, 0), (0, -1), (0, 1)] as [(CGFloat, CGFloat)] {
            let px = Int(x + dx * reach), py = Int(y + dy * reach)
            guard (0..<c.width).contains(px), (0..<c.height).contains(py) else { continue }
            if c.values[py * c.width + px] > 0.5 { return true }
        }
        return false
    }
}

/// Tap-to-select with SAM 2.1 (the object selection model): the picture is encoded once per photo,
/// then each set of taps gives a mask in a few tens of milliseconds.
enum Sam2 {
    private static let lock = NSLock()
    private static var encoded: (key: String, features: MLFeatureProvider)?

    /// Logits (`side × side`, over the picture stretched to a square, above 0 inside) for the
    /// taps: `points` 0…1 across and down the picture, `true` to include, `false` to leave out.
    static func select(_ image: CGImage, key: String, points: [(CGPoint, Bool)]) throws -> (values: [Float], side: Int)? {
        guard let encoder = SelectionModel.load(0), let prompts = SelectionModel.load(1), let decoder = SelectionModel.load(2), !points.isEmpty else { return nil }
        guard let input = encoder.modelDescription.inputDescriptionsByName.first(where: { $0.value.type == .image }),
              let constraint = input.value.imageConstraint
        else { throw EngineError(message: "The selection model has an unexpected input.") }
        let features: MLFeatureProvider
        lock.lock()
        let hit = encoded?.key == key ? encoded?.features : nil
        lock.unlock()
        if let hit {
            features = hit
        } else {
            let v = try MLFeatureValue(cgImage: image, constraint: constraint, options: [.cropAndScale: 2])
            features = try encoder.prediction(from: MLDictionaryFeatureProvider(dictionary: [input.key: v]))
            lock.lock()
            encoded = (key, features)
            lock.unlock()
        }
        // the taps, in the encoder's pixels
        let (sw, sh) = (Float(constraint.pixelsWide), Float(constraint.pixelsHigh))
        let n = points.count
        let coords = try MLMultiArray(shape: [1, NSNumber(value: n), 2], dataType: .float32)
        let labels = try MLMultiArray(shape: [1, NSNumber(value: n)], dataType: .int32)
        for (i, (p, include)) in points.enumerated() {
            coords[[0, NSNumber(value: i), 0]] = NSNumber(value: Float(p.x) * sw)
            coords[[0, NSNumber(value: i), 1]] = NSNumber(value: Float(p.y) * sh)
            labels[[0, NSNumber(value: i)]] = NSNumber(value: include ? 1 : 0)
        }
        let names = prompts.modelDescription.inputDescriptionsByName
        let pointsName = names.keys.first { $0.contains("point") } ?? "points"
        let labelsName = names.keys.first { $0.contains("label") } ?? "labels"
        let encodedTaps = try prompts.prediction(from: MLDictionaryFeatureProvider(dictionary: [pointsName: coords, labelsName: labels]))
        // everything the decoder asks for, from the picture's features or the taps'
        var inputs: [String: Any] = [:]
        for name in decoder.modelDescription.inputDescriptionsByName.keys {
            if let v = features.featureValue(for: name) ?? encodedTaps.featureValue(for: name) ?? encodedTaps.featureValue(for: name + "s") {
                inputs[name] = v
            }
        }
        let out = try decoder.prediction(from: MLDictionaryFeatureProvider(dictionary: inputs))
        let outNames = decoder.modelDescription.outputDescriptionsByName.keys
        guard let masksName = outNames.first(where: { $0.contains("mask") }), let masks = out.featureValue(for: masksName)?.multiArrayValue else { return nil }
        let scores = outNames.first(where: { $0.contains("score") }).flatMap { out.featureValue(for: $0)?.multiArrayValue }
        let dims = masks.shape.map(\.intValue)
        guard dims.count == 4 else { return nil }
        let (k, h, w) = (dims[1], dims[2], dims[3])
        // the candidate the model rates best
        var best = 0
        if let scores, scores.count >= k {
            for i in 1..<k where scores[i].floatValue > scores[best].floatValue { best = i }
        }
        let st = masks.strides.map(\.intValue)
        var values = [Float](repeating: 0, count: h * w)
        for y in 0..<h {
            for x in 0..<w {
                values[y * w + x] = element(masks, best * st[1] + y * st[2] + x * st[3])
            }
        }
        return (values, w == h ? w : Swift.min(w, h))
    }

    /// One element at a memory offset (strides included), whatever the array's number type.
    private static func element(_ a: MLMultiArray, _ offset: Int) -> Float {
        switch a.dataType {
        case .float16: return Float(a.dataPointer.assumingMemoryBound(to: Float16.self)[offset])
        case .double: return Float(a.dataPointer.assumingMemoryBound(to: Double.self)[offset])
        case .int32: return Float(a.dataPointer.assumingMemoryBound(to: Int32.self)[offset])
        default: return a.dataPointer.assumingMemoryBound(to: Float.self)[offset]
        }
    }

    /// Forget the encoded picture (the photo changed).
    static func forget() {
        lock.lock()
        encoded = nil
        lock.unlock()
    }

    /// Logits to coverage 0…1.
    static func coverage(_ logits: [Float]) -> [Float] { logits.map { 1 / (1 + exp(-$0)) } }

    /// A square grid (over the stretched picture) resampled to the picture's own shape, `long`
    /// pixels on its long edge.
    static func unstretched(_ values: [Float], side: Int, aspect: CGFloat, long: Int = 512) -> (values: [Float], width: Int, height: Int) {
        let w = aspect >= 1 ? long : Swift.max(Int(CGFloat(long) * aspect), 1)
        let h = aspect >= 1 ? Swift.max(Int(CGFloat(long) / aspect), 1) : long
        var out = [Float](repeating: 0, count: w * h)
        for y in 0..<h {
            for x in 0..<w {
                let gx = Swift.min(Int((CGFloat(x) + 0.5) / CGFloat(w) * CGFloat(side)), side - 1)
                let gy = Swift.min(Int((CGFloat(y) + 0.5) / CGFloat(h) * CGFloat(side)), side - 1)
                out[y * w + x] = values[gy * side + gx]
            }
        }
        return (out, w, h)
    }
}
