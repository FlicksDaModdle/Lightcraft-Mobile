import SwiftUI

/// The editor: the photo as large as the screen allows, and below it one glass card with the
/// current mode's controls (sliders and tools, presets, or crop), then the modes.
struct EditorView: View {
    @StateObject private var model: EditorModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.verticalSizeClass) private var verticalSize
    @AppStorage("showHistogram") private var showHistogram = false
    @State private var chromeHidden = false
    @State private var showingOriginal = false
    @State private var hold: Task<Void, Never>?

    init(photo: Photo) {
        _model = StateObject(wrappedValue: EditorModel(photo: photo))
    }

    /// Sideways, or after a tap on the photo, the photo is shown alone.
    private var chrome: Bool { !chromeHidden && verticalSize != .compact }
    /// A slider is being dragged: only it stays, so the whole photo can be judged.
    private var focused: Bool { model.active != nil }

    var body: some View {
        VStack(spacing: 0) {
            if chrome {
                topBar.opacity(focused ? 0 : 1)
                if showHistogram {
                    HistogramView(bins: model.histogram)
                        .frame(height: 56)
                        .padding(.horizontal, 24)
                        .padding(.bottom, 6)
                        .opacity(focused ? 0 : 1)
                }
            }
            photoArea
            if chrome {
                card
                    .padding(.horizontal, 8)
                    .padding(.top, 6)
                ModeBar(mode: model.mode) { m in
                    if m.available {
                        withAnimation(.easeInOut(duration: 0.2)) { model.mode = m }
                        if m == .presets { model.loadPresets() }
                    } else {
                        model.toast = "\(m.label) is not in Latent yet. It's coming in a later build."
                    }
                }
                .opacity(focused ? 0 : 1)
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .background(Color.black.ignoresSafeArea())
        .overlay(alignment: .top) { toast }
        .statusBarHidden(!chrome)
        .animation(.easeInOut(duration: 0.22), value: chrome)
        .animation(.easeInOut(duration: 0.18), value: focused)
        .preferredColorScheme(.dark)
        .onAppear { model.open() }
        .onDisappear { Thumbnails.shared.forget(model.photo.id) }
    }

    // MARK: top

    private var topBar: some View {
        HStack(spacing: 10) {
            Button { dismiss() } label: { glassIcon("chevron.left", weight: .semibold) }
                .accessibilityLabel(Text("Back"))
            Spacer()
            HStack(spacing: 0) {
                Button { model.undo() } label: { Image(systemName: "arrow.uturn.backward").frame(width: 44, height: 44) }
                    .disabled(!model.canUndo)
                    .accessibilityLabel(Text("Undo"))
                Button { model.redo() } label: { Image(systemName: "arrow.uturn.forward").frame(width: 44, height: 44) }
                    .disabled(!model.canRedo)
                    .accessibilityLabel(Text("Redo"))
            }
            .padding(.horizontal, 4)
            .latentGlass(in: Capsule(), interactive: true)
            Menu {
                Button { model.auto() } label: { Label("Auto settings", systemImage: "wand.and.stars") }
                Toggle(isOn: $showHistogram) { Label("Show histogram", systemImage: "chart.bar.xaxis") }
                Button(role: .destructive) { model.resetAll() } label: { Label("Reset all edits", systemImage: "arrow.counterclockwise") }
            } label: {
                glassIcon("ellipsis")
            }
            .accessibilityLabel(Text("More"))
        }
        .font(.system(size: 17, weight: .medium))
        .foregroundStyle(.white)
        .padding(.horizontal, 16)
        .frame(height: 52)
    }

    private func glassIcon(_ name: String, weight: Font.Weight = .medium) -> some View {
        Image(systemName: name)
            .font(.system(size: 17, weight: weight))
            .frame(width: 44, height: 44)
            .latentGlass(in: Circle(), interactive: true)
    }

    private var photoArea: some View {
        GeometryReader { geo in
            ZStack(alignment: .top) {
                if let img = showingOriginal ? (model.original ?? model.image) : model.image {
                    Image(decorative: img, scale: 1)
                        .resizable()
                        .interpolation(.high)
                        .scaledToFit()
                        .frame(width: geo.size.width, height: geo.size.height)
                } else {
                    ProgressView().tint(.white).frame(width: geo.size.width, height: geo.size.height)
                }
                if let readout = model.readout {
                    Text(readout)
                        .font(.system(size: 14, weight: .semibold))
                        .monospacedDigit()
                        .padding(.horizontal, 14)
                        .padding(.vertical, 7)
                        .latentGlass(in: Capsule())
                        .padding(.top, 10)
                        .transition(.opacity)
                }
                if showingOriginal {
                    Text("Original")
                        .font(.system(size: 12, weight: .semibold))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .latentGlass(in: Capsule())
                        .padding(.top, 10)
                }
            }
            .contentShape(Rectangle())
            .onTapGesture { chromeHidden.toggle() }
            .onLongPressGesture(minimumDuration: 0.3, maximumDistance: 24, perform: {}, onPressingChanged: { pressing in
                hold?.cancel()
                if pressing {
                    // a hold, not a tap: show the photo as it was
                    hold = Task {
                        try? await Task.sleep(nanoseconds: 250_000_000)
                        guard !Task.isCancelled else { return }
                        model.loadOriginal()
                        showingOriginal = true
                    }
                } else {
                    showingOriginal = false
                }
            })
            .accessibilityLabel(Text("Photo"))
            .accessibilityHint(Text("Tap to hide the controls. Touch and hold to see the original."))
        }
    }

    // MARK: the card

    private var card: some View {
        VStack(spacing: 0) {
            switch model.mode {
            case .presets: presetsPanel
            case .crop: cropPanel
            default:
                editPanel
                ToolStrip(model: model).opacity(focused ? 0 : 1)
            }
        }
        .background {
            RoundedRectangle(cornerRadius: 28, style: .continuous)
                .fill(Color.black.opacity(0.2))
                .latentGlass(in: RoundedRectangle(cornerRadius: 28, style: .continuous), tint: Color.black.opacity(0.3))
                .opacity(focused ? 0 : 1)
        }
    }

    private func slider(_ c: Control) -> some View {
        LatentSlider(
            control: c,
            onBegin: { model.begin(c) },
            onChange: { model.set(c, $0) },
            onEnd: { model.end() },
            onReset: { model.reset(c) })
            .opacity(focused && model.active != c.id ? 0 : 1)
    }

    private var editPanel: some View {
        VStack(spacing: 0) {
            Group {
                switch model.tool {
                case .color: colorHeader
                case .mixer: stepHeader("Color mix")
                case .grading: stepHeader("Color grading")
                case .light: lightHeader
                case .curve: curveHeader
                default: EmptyView()
                }
                if !model.tool.tabs.isEmpty { tabs }
                if model.tool == .mixer { bandChips }
                if model.tool == .grading { rangeChips }
            }
            .opacity(focused ? 0 : 1)
            if model.tool == .curve {
                CurveEditor(model: model)
                    .frame(height: 196)
                    .padding(.horizontal, 20)
                    .padding(.vertical, 8)
            } else if model.tool == .grading {
                GradingWheel(model: model)
                    .frame(height: 132)
                    .padding(.vertical, 6)
                    .opacity(focused && model.active != "wheel" ? 0 : 1)
            }
            if model.tool != .curve {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(model.visible) { slider($0) }
                    }
                    .padding(.vertical, 4)
                }
                .scrollIndicators(.visible)
                .frame(height: model.tool == .grading ? 150 : (model.tool == .light ? 150 : 168))
            }
        }
    }

    private var tabs: some View {
        Picker("Section", selection: $model.tab) {
            ForEach(Array(model.tool.tabs.enumerated()), id: \.offset) { i, tab in
                Text(tab.name).tag(i)
            }
        }
        .pickerStyle(.segmented)
        .padding(.horizontal, 20)
        .padding(.top, 12)
        .padding(.bottom, 2)
    }

    private var colorHeader: some View {
        VStack(spacing: 10) {
            HStack(spacing: 10) {
                Toggle(isOn: Binding(get: { model.bw }, set: { model.setBW($0) })) {
                    Text("B&W").font(.system(size: 15))
                }
                .toggleStyle(.switch)
                .tint(Theme.accent)
                .fixedSize()
                Spacer()
                stepButton("Grading", symbol: "circle.lefthalf.filled") { model.tool = .grading }
                stepButton("Color mix", symbol: "paintpalette") { model.tool = .mixer }
            }
            HStack(spacing: 8) {
                Text("White balance").font(.system(size: 14)).foregroundStyle(Theme.secondaryText)
                Menu {
                    ForEach(whiteBalanceModes, id: \.mode) { wb in
                        Button { model.setWhiteBalance(wb.mode) } label: {
                            if wb.mode == model.wbMode { Label(wb.label, systemImage: "checkmark") } else { Text(wb.label) }
                        }
                    }
                } label: {
                    HStack(spacing: 4) {
                        Text(whiteBalanceModes.first { $0.mode == model.wbMode }?.label ?? "Custom")
                        Image(systemName: "chevron.down").font(.system(size: 11, weight: .semibold))
                    }
                    .font(.system(size: 15))
                    .foregroundStyle(.white)
                }
                Spacer()
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, 14)
    }

    private func stepButton(_ title: String, symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: symbol)
                .font(.system(size: 13, weight: .medium))
                .padding(.horizontal, 12)
                .frame(height: 32)
                .latentGlass(in: Capsule(), interactive: true)
        }
        .foregroundStyle(.white)
    }

    private var lightHeader: some View {
        HStack {
            Spacer()
            stepButton("Curve", symbol: "chart.line.uptrend.xyaxis") { model.tool = .curve }
        }
        .padding(.horizontal, 20)
        .padding(.top, 12)
    }

    private var curveHeader: some View {
        HStack(spacing: 14) {
            Button { model.tool = .light } label: {
                Label("Curve", systemImage: "chevron.left").font(.system(size: 15, weight: .semibold))
            }
            .foregroundStyle(.white)
            Spacer()
            ForEach(curveChannels.indices, id: \.self) { i in
                let ch = curveChannels[i]
                let color = Color(red: ch.color.0, green: ch.color.1, blue: ch.color.2)
                Button { model.curveChannel = i } label: {
                    Circle()
                        .fill(model.curveChannel == i ? color : .clear)
                        .overlay(Circle().strokeBorder(color, lineWidth: 2.5))
                        .frame(width: 22, height: 22)
                        .overlay(Circle().strokeBorder(Color.white.opacity(model.curveChannel == i ? 0.9 : 0), lineWidth: 1.5).padding(-4))
                        .frame(width: 34, height: 34)
                }
                .accessibilityLabel(Text(ch.label))
                .accessibilityAddTraits(model.curveChannel == i ? .isSelected : [])
            }
            Button { model.resetCurve() } label: {
                Image(systemName: "arrow.counterclockwise").font(.system(size: 15, weight: .semibold)).frame(width: 34, height: 34)
            }
            .foregroundStyle(.white)
            .accessibilityLabel(Text("Reset curve"))
        }
        .padding(.horizontal, 20)
        .padding(.top, 10)
    }

    private func stepHeader(_ title: String) -> some View {
        HStack {
            Button { model.tool = .color } label: {
                Label(title, systemImage: "chevron.left")
                    .font(.system(size: 15, weight: .semibold))
            }
            .foregroundStyle(.white)
            Spacer()
        }
        .padding(.horizontal, 20)
        .padding(.top, 14)
    }

    private var bandChips: some View {
        HStack(spacing: 0) {
            ForEach(mixerBands.indices, id: \.self) { i in
                Button { model.mixerBand = i } label: {
                    Circle()
                        .fill(Theme.band(i))
                        .frame(width: 24, height: 24)
                        .overlay(Circle().strokeBorder(Color.white, lineWidth: model.mixerBand == i ? 2.5 : 0).padding(-4))
                        .frame(maxWidth: .infinity, minHeight: 40)
                }
                .accessibilityLabel(Text(mixerBands[i].capitalized))
                .accessibilityAddTraits(model.mixerBand == i ? .isSelected : [])
            }
        }
        .padding(.horizontal, 14)
        .padding(.top, 8)
    }

    private var rangeChips: some View {
        Picker("Range", selection: $model.gradingRange) {
            ForEach(gradingRanges.indices, id: \.self) { i in Text(gradingRanges[i].label).tag(i) }
        }
        .pickerStyle(.segmented)
        .padding(.horizontal, 20)
        .padding(.top, 10)
    }

    // MARK: presets

    private var presetsPanel: some View {
        VStack(spacing: 0) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(model.presetGroups, id: \.self) { g in
                        Button { model.presetGroup = g } label: {
                            Text(g)
                                .font(.system(size: 14, weight: model.presetGroup == g ? .semibold : .regular))
                                .foregroundStyle(model.presetGroup == g ? Color.black : Color.white)
                                .padding(.horizontal, 14)
                                .frame(height: 32)
                                .background(model.presetGroup == g ? Color.white : Color.white.opacity(0.1), in: Capsule())
                        }
                    }
                }
                .padding(.horizontal, 16)
            }
            .padding(.top, 14)
            .opacity(focused ? 0 : 1)
            ScrollView {
                LazyVGrid(columns: [GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8)], spacing: 8) {
                    ForEach(model.presets.filter { $0.group == model.presetGroup }) { p in
                        Button { model.apply(p) } label: {
                            HStack {
                                Text(p.name).font(.system(size: 14)).lineLimit(1)
                                Spacer(minLength: 4)
                                if model.appliedPreset == p.id { Image(systemName: "checkmark").font(.system(size: 12, weight: .bold)) }
                            }
                            .foregroundStyle(.white)
                            .padding(.horizontal, 12)
                            .frame(height: 40)
                            .background(Color.white.opacity(model.appliedPreset == p.id ? 0.18 : 0.07), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                        }
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
            }
            .frame(height: 150)
            .opacity(focused ? 0 : 1)
            if model.appliedPreset != nil {
                LatentSlider(
                    control: model.amountControl,
                    onBegin: { model.beginAmount() },
                    onChange: { model.setAmount($0) },
                    onEnd: { model.end() },
                    onReset: {
                        model.beginAmount()
                        model.setAmount(100)
                        model.end()
                    })
            }
        }
        .padding(.bottom, 6)
    }

    // MARK: crop

    private var cropPanel: some View {
        VStack(spacing: 0) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(cropAspects, id: \.value) { a in
                        let on = model.aspectChoice == a.value
                        Button { model.setAspect(a.value) } label: {
                            Text(a.label)
                                .font(.system(size: 14, weight: on ? .semibold : .regular))
                                .foregroundStyle(on ? Color.black : Color.white)
                                .padding(.horizontal, 14)
                                .frame(height: 32)
                                .background(on ? Color.white : Color.white.opacity(0.1), in: Capsule())
                        }
                    }
                }
                .padding(.horizontal, 16)
            }
            .padding(.top, 14)
            .opacity(focused ? 0 : 1)
            HStack(spacing: 0) {
                cropTool("rotate.left", "Rotate") { model.cropCommand("photo.rotateLeft") }
                cropTool("arrow.left.and.right.righttriangle.left.righttriangle.right", "Flip") { model.cropCommand("photo.flipHorizontal") }
                cropTool("rectangle.portrait.rotate", "Swap") { model.cropCommand("crop.rotateAspect") }
                cropTool("level", "Auto") { model.cropCommand("crop.autoStraighten") }
                cropTool("arrow.counterclockwise", "Reset") { model.cropCommand("crop.reset") }
            }
            .padding(.horizontal, 8)
            .padding(.top, 10)
            .opacity(focused ? 0 : 1)
            LatentSlider(
                control: model.angleControl,
                onBegin: { model.beginAngle() },
                onChange: { model.setAngle($0) },
                onEnd: { model.end() },
                onReset: {
                    model.beginAngle()
                    model.setAngle(0)
                    model.end()
                })
                .padding(.vertical, 6)
        }
        .padding(.bottom, 8)
    }

    private func cropTool(_ symbol: String, _ label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 5) {
                Image(systemName: symbol).font(.system(size: 19)).frame(height: 24)
                Text(label).font(.system(size: 11))
            }
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity, minHeight: 54)
        }
        .accessibilityLabel(Text(label))
    }

    @ViewBuilder private var toast: some View {
        if let text = model.toast {
            Text(text)
                .font(.system(size: 14, weight: .medium))
                .multilineTextAlignment(.center)
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .latentGlass(in: Capsule())
                .padding(.top, 54)
                .padding(.horizontal, 24)
                .transition(.move(edge: .top).combined(with: .opacity))
                .task(id: text) {
                    try? await Task.sleep(nanoseconds: 2_400_000_000)
                    withAnimation { model.toast = nil }
                }
        }
    }
}

/// The colour grading wheel for the chosen range: hue round the circle (red on the right), how
/// much from the middle outward. Drag the dot; double-tap to clear.
struct GradingWheel: View {
    @ObservedObject var model: EditorModel

    var body: some View {
        let range = gradingRanges[model.gradingRange].id
        let hue = model.controls["grading.\(range).hue"]?.value ?? 0
        let sat = model.controls["grading.\(range).sat"]?.value ?? 0
        GeometryReader { geo in
            let size = Swift.min(geo.size.width, geo.size.height)
            let r = size / 2
            let center = CGPoint(x: geo.size.width / 2, y: geo.size.height / 2)
            let a = hue * .pi / 180
            let knob = CGPoint(x: center.x + cos(a) * r * sat / 100, y: center.y - sin(a) * r * sat / 100)
            ZStack {
                Circle()
                    .fill(AngularGradient(colors: (0...12).map { Color(hue: 1 - Double($0) / 12, saturation: 0.9, brightness: 1) }, center: .center))
                    .overlay(Circle().fill(RadialGradient(colors: [.white, .white.opacity(0)], center: .center, startRadius: 0, endRadius: r)))
                    .frame(width: size, height: size)
                    .position(center)
                Circle()
                    .strokeBorder(Color.white, lineWidth: 2.5)
                    .background(Circle().fill(Color.black.opacity(0.25)))
                    .frame(width: 22, height: 22)
                    .shadow(color: .black.opacity(0.4), radius: 2)
                    .position(knob)
            }
            .contentShape(Circle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { g in
                        if model.active != "wheel" { model.beginWheel() }
                        let dx = g.location.x - center.x
                        let dy = center.y - g.location.y
                        var deg = atan2(dy, dx) * 180 / .pi
                        if deg < 0 { deg += 360 }
                        let s = Swift.min(hypot(dx, dy) / r * 100, 100)
                        model.setQuietly("grading.\(range).hue", deg.rounded())
                        model.setQuietly("grading.\(range).sat", s.rounded())
                        model.render()
                    }
                    .onEnded { _ in model.end() }
            )
            .onTapGesture(count: 2) {
                model.beginWheel()
                model.setQuietly("grading.\(range).hue", 0)
                model.setQuietly("grading.\(range).sat", 0)
                model.render()
                model.end()
            }
            .accessibilityLabel(Text("\(gradingRanges[model.gradingRange].label) wheel"))
            .accessibilityValue(Text("Hue \(Int(hue)), saturation \(Int(sat))"))
        }
    }
}

/// The tools: Auto first, then the adjustment groups; the open one is highlighted and a dot marks
/// the ones that have changed the photo.
struct ToolStrip: View {
    @ObservedObject var model: EditorModel

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 2) {
                item("Auto", symbol: "wand.and.stars", selected: false, edited: false) { model.auto() }
                Rectangle().fill(Theme.separator).frame(width: 1, height: 32).padding(.horizontal, 4)
                ForEach(Tool.strip) { t in
                    let on = model.tool == t || (t == .color && (model.tool == .mixer || model.tool == .grading)) || (t == .light && model.tool == .curve)
                    item(t.label, symbol: t.symbol, selected: on, edited: model.edited(t)) { model.tool = t }
                }
            }
            .padding(.horizontal, 10)
        }
        .frame(height: 74)
        .padding(.bottom, 4)
    }

    private func item(_ label: String, symbol: String, selected: Bool, edited: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 5) {
                Image(systemName: symbol).font(.system(size: 20)).frame(height: 24)
                Text(label).font(.system(size: 11))
                Circle().fill(edited ? Theme.secondaryText : .clear).frame(width: 4, height: 4)
            }
            .foregroundStyle(selected ? Color.white : Theme.secondaryText)
            .frame(width: 64, height: 62)
            .background {
                if selected {
                    RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Color.white.opacity(0.08))
                        .latentGlass(in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                }
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(label))
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// The editing modes, in a floating glass bar.
struct ModeBar: View {
    let mode: Mode
    let choose: (Mode) -> Void

    var body: some View {
        HStack(spacing: 0) {
            ForEach(Mode.allCases, id: \.self) { m in
                Button { choose(m) } label: {
                    Image(systemName: m.symbol)
                        .font(.system(size: 19))
                        .foregroundStyle(m == mode ? Color.white : Color(white: m.available ? 0.8 : 0.5))
                        .frame(width: 52, height: 40)
                        .background(m == mode ? Theme.accent : .clear, in: Capsule())
                }
                .frame(maxWidth: .infinity)
                .accessibilityLabel(Text(m.label))
                .accessibilityAddTraits(m == mode ? .isSelected : [])
            }
        }
        .padding(6)
        .latentGlass(in: Capsule(), interactive: true)
        .padding(.horizontal, 14)
        .padding(.top, 8)
        .padding(.bottom, 4)
    }
}

/// The point curve for the open channel: drag a point, touch empty space to add one (and drag it),
/// double-tap a point to take it away. The two ends stay.
struct CurveEditor: View {
    @ObservedObject var model: EditorModel
    @State private var dragging: Int?
    @State private var working: [CGPoint] = []

    var body: some View {
        let ch = curveChannels[model.curveChannel]
        let color = Color(red: ch.color.0, green: ch.color.1, blue: ch.color.2)
        GeometryReader { geo in
            let size = geo.size
            let pts = dragging == nil ? model.curvePoints : working
            let toView = { (p: CGPoint) in CGPoint(x: p.x * size.width, y: (1 - p.y) * size.height) }
            ZStack {
                RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.black.opacity(0.35))
                HistogramView(bins: model.histogram).opacity(0.35).padding(.bottom, 1)
                Path { path in
                    for i in 1..<4 {
                        let f = CGFloat(i) / 4
                        path.move(to: CGPoint(x: size.width * f, y: 0))
                        path.addLine(to: CGPoint(x: size.width * f, y: size.height))
                        path.move(to: CGPoint(x: 0, y: size.height * f))
                        path.addLine(to: CGPoint(x: size.width, y: size.height * f))
                    }
                }
                .stroke(Color.white.opacity(0.12), lineWidth: 1)
                Path { path in
                    path.move(to: CGPoint(x: 0, y: size.height))
                    path.addLine(to: CGPoint(x: size.width, y: 0))
                }
                .stroke(Color.white.opacity(0.18), style: StrokeStyle(lineWidth: 1, dash: [4, 4]))
                Path { path in
                    let curve = MonotoneCurve(pts)
                    for i in 0...120 {
                        let x = Double(i) / 120
                        let p = toView(CGPoint(x: x, y: Swift.min(Swift.max(curve(x), 0), 1)))
                        if i == 0 { path.move(to: p) } else { path.addLine(to: p) }
                    }
                }
                .stroke(color, lineWidth: 2.5)
                ForEach(pts.indices, id: \.self) { i in
                    Circle()
                        .fill(Color.black.opacity(0.6))
                        .overlay(Circle().strokeBorder(Color.white, lineWidth: 2))
                        .frame(width: dragging == i ? 22 : 16, height: dragging == i ? 22 : 16)
                        .position(toView(pts[i]))
                        .animation(.spring(response: 0.25, dampingFraction: 0.7), value: dragging)
                }
            }
            .contentShape(Rectangle())
            .gesture(drag(size))
            .simultaneousGesture(SpatialTapGesture(count: 2).onEnded { e in removePoint(near: e.location, size: size) })
            .accessibilityLabel(Text("\(ch.label) curve"))
            .accessibilityValue(Text("\(model.curvePoints.count) points"))
        }
    }

    private func nearest(_ q: CGPoint, in pts: [CGPoint], size: CGSize) -> Int? {
        var best: (Int, CGFloat)?
        for (i, p) in pts.enumerated() {
            let d = hypot(p.x * size.width - q.x, (1 - p.y) * size.height - q.y)
            if d < 28, d < (best?.1 ?? .infinity) { best = (i, d) }
        }
        return best?.0
    }

    private func unit(_ q: CGPoint, _ size: CGSize) -> CGPoint {
        CGPoint(x: Swift.min(Swift.max(q.x / size.width, 0), 1), y: Swift.min(Swift.max(1 - q.y / size.height, 0), 1))
    }

    private func drag(_ size: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { g in
                if dragging == nil {
                    var pts = model.curvePoints
                    if let i = nearest(g.startLocation, in: pts, size: size) {
                        dragging = i
                    } else {
                        let p = unit(g.startLocation, size)
                        let i = pts.firstIndex { $0.x > p.x } ?? pts.count
                        pts.insert(p, at: i)
                        dragging = i
                    }
                    working = pts
                    model.beginCurve()
                    model.setCurve(working)
                }
                guard let i = dragging, working.indices.contains(i) else { return }
                var p = unit(g.location, size)
                // a point stays between its neighbours; the ends keep to the edges' order
                let lo = i == 0 ? 0 : working[i - 1].x + 0.01
                let hi = i == working.count - 1 ? 1 : working[i + 1].x - 0.01
                p.x = lo <= hi ? Swift.min(Swift.max(p.x, lo), hi) : working[i].x
                working[i] = p
                model.setCurve(working)
            }
            .onEnded { _ in
                dragging = nil
                model.end()
            }
    }

    private func removePoint(near q: CGPoint, size: CGSize) {
        var pts = model.curvePoints
        guard let i = nearest(q, in: pts, size: size), i != 0, i != pts.count - 1 else { return }
        pts.remove(at: i)
        model.beginCurve()
        model.setCurve(pts)
        model.end()
    }
}
