import SwiftUI
import UIKit

/// A develop slider: name and value above, a thin track with a ring for the thumb below. Drag
/// anywhere on the track to move the value from where it is; double-tap to put it back.
struct LatentSlider: View {
    let control: Control
    let onBegin: () -> Void
    let onChange: (Double) -> Void
    let onEnd: () -> Void
    let onReset: () -> Void

    @State private var start: Double?
    private let haptics = UISelectionFeedbackGenerator()

    var body: some View {
        VStack(spacing: 6) {
            HStack {
                Text(control.label)
                    .foregroundStyle(Color(white: 0.92))
                Spacer()
                Text(control.format(control.value))
                    .monospacedDigit()
                    .foregroundStyle(control.changed ? Color.white : Theme.secondaryText)
            }
            .font(.system(size: 15))
            GeometryReader { geo in
                track(width: geo.size.width)
                    .overlay {
                        // a UIKit pan that only starts on a sideways move, so a vertical swipe
                        // scrolls the panel instead of being caught by the slider
                        SidewaysPan(
                            began: { beginDrag() },
                            moved: { dx in moveDrag(dx, width: geo.size.width) },
                            ended: { endDrag() },
                            doubleTapped: {
                                haptics.selectionChanged()
                                onReset()
                            })
                    }
            }
            .frame(height: 30)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 6)
        .contentShape(Rectangle())
        .onTapGesture(count: 2) {
            haptics.selectionChanged()
            onReset()
        }
        .accessibilityElement()
        .accessibilityLabel(Text(control.label))
        .accessibilityValue(Text(control.format(control.value)))
        .accessibilityAdjustableAction { direction in
            let step = Swift.max(control.step, (control.max - control.min) / 100)
            onBegin()
            onChange(direction == .increment ? Swift.min(control.value + step, control.max) : Swift.max(control.value - step, control.min))
            onEnd()
        }
    }

    private func track(width: CGFloat) -> some View {
        let x = CGFloat(control.position(control.value)) * width
        let x0 = CGFloat(control.position(control.defaultValue)) * width
        return ZStack(alignment: .leading) {
            if let stops = Theme.stops(control.track) {
                Capsule().fill(LinearGradient(colors: stops, startPoint: .leading, endPoint: .trailing)).frame(height: 2)
            } else {
                Capsule().fill(Theme.track).frame(height: 2)
                // the stretch moved from the default, so a changed slider reads at a glance
                Rectangle().fill(Color.white.opacity(0.85)).frame(width: abs(x - x0), height: 2).offset(x: Swift.min(x, x0))
            }
            // the track breaks around the thumb
            Circle().fill(Theme.surface).frame(width: 32, height: 32).offset(x: x - 16)
            Circle()
                .strokeBorder(start != nil ? Color.white : Theme.thumb, lineWidth: 2)
                .frame(width: 24, height: 24)
                .offset(x: x - 12)
        }
        .frame(height: 30)
    }

    private func beginDrag() {
        start = control.position(control.value)
        haptics.prepare()
        onBegin()
    }

    private func moveDrag(_ dx: CGFloat, width: CGFloat) {
        guard let s = start, width > 0 else { return }
        let v = control.value(at: s + Double(dx / width))
        guard v != control.value else { return }
        let crossed = (control.value - control.defaultValue) * (v - control.defaultValue) <= 0 && control.changed
        if crossed || v == control.defaultValue { haptics.selectionChanged() }
        onChange(v)
    }

    private func endDrag() {
        if start != nil { onEnd() }
        start = nil
    }
}

/// The red, green and blue histograms of the rendered photo, drawn over each other.
struct HistogramView: View {
    let bins: [UInt32]

    var body: some View {
        Canvas { ctx, size in
            let n = bins.count / 3
            guard n > 1 else { return }
            let peak = Double(bins.dropFirst(1).dropLast(1).max() ?? 1)
            // the brightest few bins can dwarf the rest: scale to a soft peak
            let top = Swift.max(1, peak * 0.85)
            let colors: [Color] = [Color(red: 1, green: 0.27, blue: 0.27), Color(red: 0.3, green: 0.9, blue: 0.35), Color(red: 0.3, green: 0.45, blue: 1)]
            var fill = Path()
            for c in 0..<3 {
                var line = Path()
                for i in 0..<n {
                    let v = Swift.min(Double(bins[c * n + i]) / top, 1)
                    let p = CGPoint(x: size.width * CGFloat(i) / CGFloat(n - 1), y: size.height * (1 - CGFloat(v)))
                    if i == 0 { line.move(to: p) } else { line.addLine(to: p) }
                }
                if c == 0 {
                    fill = line
                    fill.addLine(to: CGPoint(x: size.width, y: size.height))
                    fill.addLine(to: CGPoint(x: 0, y: size.height))
                    fill.closeSubpath()
                    ctx.fill(fill, with: .color(Color(white: 0.55).opacity(0.35)))
                }
                ctx.stroke(line, with: .color(colors[c].opacity(0.9)), lineWidth: 1.4)
            }
            ctx.stroke(Path { $0.move(to: CGPoint(x: 0, y: size.height)); $0.addLine(to: CGPoint(x: size.width, y: size.height)) }, with: .color(Color(white: 0.4)), lineWidth: 1)
        }
        .accessibilityHidden(true)
    }
}

/// A transparent UIKit view that reports sideways drags (and double taps). A drag that starts
/// mostly vertical never begins here, so the scroll view around it gets it.
struct SidewaysPan: UIViewRepresentable {
    let began: () -> Void
    let moved: (CGFloat) -> Void
    let ended: () -> Void
    let doubleTapped: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIView(context: Context) -> UIView {
        let view = UIView()
        view.backgroundColor = .clear
        let pan = UIPanGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.pan(_:)))
        pan.delegate = context.coordinator
        view.addGestureRecognizer(pan)
        let tap = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.tap))
        tap.numberOfTapsRequired = 2
        view.addGestureRecognizer(tap)
        return view
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        context.coordinator.parent = self
    }

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        var parent: SidewaysPan

        init(_ parent: SidewaysPan) { self.parent = parent }

        func gestureRecognizerShouldBegin(_ g: UIGestureRecognizer) -> Bool {
            guard let pan = g as? UIPanGestureRecognizer else { return true }
            let v = pan.velocity(in: pan.view)
            return abs(v.x) > abs(v.y)
        }

        @objc func pan(_ g: UIPanGestureRecognizer) {
            switch g.state {
            case .began: parent.began()
            case .changed: parent.moved(g.translation(in: g.view).x)
            case .ended, .cancelled, .failed: parent.ended()
            default: break
            }
        }

        @objc func tap() { parent.doubleTapped() }
    }
}
