import SwiftUI

/// The editor: the photo as large as the screen allows, and below it one glass card with the
/// current mode's controls (sliders and tools, presets, or crop), then the modes.
struct EditorView: View {
    @StateObject private var model: EditorModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.verticalSizeClass) private var verticalSize
    @AppStorage("histogramShown") private var showHistogram = true
    @State private var naming = false
    @State private var newPresetName = ""
    @State private var renamingMask = false
    @State private var maskName = ""
    @State private var describing = false
    @State private var description = ""
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
        Group {
            if model.tool == .curve && chrome {
                curveScreen
            } else {
                editScreen
            }
        }
        .background(Color.black.ignoresSafeArea())
        .overlay(alignment: .top) { toast }
        .statusBarHidden(!chrome)
        .animation(.easeInOut(duration: 0.22), value: chrome)
        .animation(.easeInOut(duration: 0.18), value: focused)
        .animation(.easeInOut(duration: 0.25), value: model.tool == .curve)
        .preferredColorScheme(.dark)
        .onAppear { model.open() }
        .onDisappear { Thumbnails.shared.forget(model.photo.id) }
    }

    /// The curve on its own screen: the photo with a large graph over it, and the channels below.
    private var curveScreen: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Button { model.tool = .light } label: { glassIcon("chevron.left", weight: .semibold) }
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
            }
            .font(.system(size: 17, weight: .medium))
            .foregroundStyle(.white)
            .padding(.horizontal, 16)
            .frame(height: 52)
            HistogramView(bins: model.histogram, hdrStops: model.showingHDR ? model.headroom : nil)
                .frame(height: 64)
                .padding(.horizontal, 24)
                .padding(.bottom, 8)
            GeometryReader { geo in
                let side = Swift.min(geo.size.width - 40, geo.size.height - 8)
                ZStack(alignment: .bottom) {
                    photoArea
                    CurveEditor(model: model)
                        .frame(width: side, height: side)
                        .padding(.bottom, 4)
                }
                .frame(width: geo.size.width, height: geo.size.height)
            }
            VStack(spacing: 14) {
                HStack {
                    Text("Curve").font(.system(size: 17, weight: .semibold)).foregroundStyle(Theme.secondaryText)
                    Spacer()
                    Button { model.tool = .light } label: {
                        Text("Done")
                            .font(.system(size: 16, weight: .semibold))
                            .padding(.horizontal, 22)
                            .frame(height: 38)
                            .latentGlass(in: Capsule(), interactive: true)
                    }
                    .foregroundStyle(.white)
                }
                HStack(spacing: 0) {
                    ForEach(curveChannels.indices, id: \.self) { i in
                        let ch = curveChannels[i]
                        let color = Color(red: ch.color.0, green: ch.color.1, blue: ch.color.2)
                        Button { model.curveChannel = i } label: {
                            Circle()
                                .fill(model.curveChannel == i ? color : .clear)
                                .overlay(Circle().strokeBorder(color, lineWidth: 3))
                                .frame(width: 28, height: 28)
                                .frame(width: 64, height: 44)
                        }
                        .accessibilityLabel(Text(ch.label))
                        .accessibilityAddTraits(model.curveChannel == i ? .isSelected : [])
                    }
                    Spacer()
                    Button { model.resetCurve() } label: {
                        Image(systemName: "arrow.counterclockwise").font(.system(size: 18, weight: .semibold)).frame(width: 44, height: 44)
                    }
                    .foregroundStyle(.white)
                    .accessibilityLabel(Text("Reset curve"))
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 16)
            .background {
                RoundedRectangle(cornerRadius: 28, style: .continuous)
                    .fill(Color.black.opacity(0.2))
                    .latentGlass(in: RoundedRectangle(cornerRadius: 28, style: .continuous), tint: Color.black.opacity(0.3))
            }
            .padding(.horizontal, 8)
            .padding(.top, 8)
            .padding(.bottom, 4)
        }
    }

    private var editScreen: some View {
        VStack(spacing: 0) {
            if chrome {
                topBar.opacity(focused ? 0 : 1)
            }
            photoArea
            if chrome {
                card
                    .padding(.horizontal, 8)
                    .padding(.top, 6)
                Group {
                    if model.mode == .presets {
                        PresetsBar(cancel: { withAnimation { model.cancelPresets() } }, done: { withAnimation { model.donePresets() } })
                    } else {
                        ModeBar(mode: model.mode) { m in
                            if m.available {
                                withAnimation(.easeInOut(duration: 0.2)) { model.mode = m }
                            } else {
                                model.toast = "\(m.label) is not in Latent yet. It's coming in a later build."
                            }
                        }
                    }
                }
                .opacity(focused ? 0 : 1)
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
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
                if model.mode == .crop && chrome {
                    if let full = model.fullImage {
                        CropEditor(model: model, image: full, size: geo.size)
                    } else {
                        ProgressView().tint(.white).frame(width: geo.size.width, height: geo.size.height)
                    }
                } else if let img = showingOriginal ? (model.original ?? model.image) : model.image {
                    Image(decorative: img, scale: 1)
                        .resizable()
                        .interpolation(.high)
                        .allowedDynamicRange(model.showingHDR && !showingOriginal ? .high : .standard)
                        .scaledToFit()
                        .frame(width: geo.size.width, height: geo.size.height)
                } else {
                    ProgressView().tint(.white).frame(width: geo.size.width, height: geo.size.height)
                }
                if model.mode == .masks && chrome, let img = model.image, model.currentMask != nil {
                    MaskCanvas(model: model, imageSize: CGSize(width: img.width, height: img.height), size: geo.size)
                }
                if showHistogram && chrome && model.tool != .curve && model.mode != .crop && model.mode != .masks && !focused {
                    HistogramView(bins: model.histogram, hdrStops: model.showingHDR ? model.headroom : nil)
                        .frame(height: model.showingHDR ? 62 : 50)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(Color.black.opacity(0.45), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                        .frame(maxWidth: geo.size.width * 0.72)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.leading, 12)
                        .padding(.top, 8)
                        .allowsHitTesting(false)
                        .transition(.opacity)
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
            .onTapGesture { if model.mode != .crop && model.mode != .masks { chromeHidden.toggle() } }
            .onLongPressGesture(minimumDuration: 0.3, maximumDistance: 24, perform: {}, onPressingChanged: { pressing in
                hold?.cancel()
                if pressing && model.mode != .crop && model.mode != .masks {
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
            case .masks: masksPanel
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
            if model.tool == .grading {
                // the wheel scrolls away with the sliders under it; swipe beside it to scroll
                GeometryReader { g in
                    ScrollView {
                        VStack(spacing: 0) {
                            let side = Swift.min(g.size.width - 120, 270)
                            GradingWheel(model: model)
                                .frame(width: side, height: side)
                                .padding(.vertical, 14)
                                .opacity(focused && model.active != "wheel" ? 0 : 1)
                            ForEach(model.visible) { slider($0) }
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.bottom, 8)
                    }
                    .scrollIndicators(.visible)
                }
                .frame(height: 300)
            } else if model.tool != .curve {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(model.visible) { slider($0) }
                    }
                    .padding(.vertical, 4)
                }
                .scrollIndicators(.visible)
                .frame(height: model.tool == .light ? 150 : 168)
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
            Toggle(isOn: Binding(get: { model.hdr }, set: { model.setHDR($0) })) {
                Text("HDR").font(.system(size: 15))
            }
            .toggleStyle(.switch)
            .tint(Theme.accent)
            .fixedSize()
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

    // MARK: masks

    private var masksPanel: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Text("Masks").font(.system(size: 17, weight: .semibold))
                Spacer()
                if model.aiBusy {
                    ProgressView().tint(.white).scaleEffect(0.8)
                }
                if model.currentMask != nil {
                    Button { model.maskOverlay.toggle() } label: {
                        Image(systemName: model.maskOverlay ? "eye" : "eye.slash").font(.system(size: 15, weight: .semibold)).frame(width: 36, height: 32)
                    }
                    .accessibilityLabel(Text(model.maskOverlay ? "Hide the overlay" : "Show the overlay"))
                }
                Menu {
                    Button { model.addMask("brush") } label: { Label("Brush", systemImage: "paintbrush.pointed") }
                    Button { model.addMask("linear") } label: { Label("Linear gradient", systemImage: "rectangle.split.1x2") }
                    Button { model.addMask("radial") } label: { Label("Radial gradient", systemImage: "circle.dashed") }
                    Divider()
                    Button { model.addMask("subject") } label: { Label("Subject", systemImage: "person.crop.rectangle") }
                    Button { model.addMask("sky") } label: { Label("Sky", systemImage: "cloud.sun") }
                    Button { model.addMask("background") } label: { Label("Background", systemImage: "photo") }
                    Divider()
                    Button { model.addAIMask("object") } label: { Label("Select object (AI)", systemImage: "hand.tap") }
                    Button {
                        model.refreshAIModel()
                        if model.aiModel.installed {
                            description = ""
                            describing = true
                        } else {
                            model.showAIModels = true
                        }
                    } label: { Label("Describe (AI)\u{2026}", systemImage: "text.magnifyingglass") }
                    Button { model.refreshAIModel(); model.showAIModels = true } label: { Label("AI models\u{2026}", systemImage: "cpu") }
                } label: {
                    Label("Add", systemImage: "plus").font(.system(size: 14, weight: .medium))
                        .padding(.horizontal, 12)
                        .frame(height: 32)
                        .latentGlass(in: Capsule(), interactive: true)
                }
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 16)
            .padding(.top, 12)
            .opacity(focused ? 0 : 1)
            if model.masks.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "circle.dashed.inset.filled").font(.system(size: 30, weight: .light)).foregroundStyle(Theme.secondaryText)
                    Text("Add a mask to change one part of the photo: paint it with a brush, or draw a linear or radial gradient.")
                        .font(.system(size: 14))
                        .foregroundStyle(Theme.secondaryText)
                        .multilineTextAlignment(.center)
                }
                .padding(.horizontal, 30)
                .frame(height: 200)
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(model.masks) { m in
                            let on = m.id == model.selectedMask
                            Button { model.selectMask(m.id) } label: {
                                HStack(spacing: 6) {
                                    Image(systemName: maskSymbol(m.kind)).font(.system(size: 12, weight: .semibold))
                                    Text(m.name).font(.system(size: 14, weight: on ? .semibold : .regular))
                                    if !m.visible { Image(systemName: "eye.slash").font(.system(size: 11)) }
                                }
                                .foregroundStyle(on ? Color.black : Color.white)
                                .padding(.horizontal, 12)
                                .frame(height: 32)
                                .background(on ? Color.white : Color.white.opacity(0.1), in: Capsule())
                            }
                        }
                    }
                    .padding(.horizontal, 16)
                }
                .padding(.top, 10)
                .opacity(focused ? 0 : 1)
                if let m = model.currentMask {
                    HStack {
                        Text(maskHint(m)).font(.system(size: 13)).foregroundStyle(Theme.secondaryText).lineLimit(2)
                        Spacer()
                        Menu {
                            Button { model.maskCommand("mask.visible", ["visible": !m.visible]) } label: {
                                Label(m.visible ? "Hide" : "Show", systemImage: m.visible ? "eye.slash" : "eye")
                            }
                            Button { model.maskCommand("mask.invert") } label: { Label("Invert", systemImage: "circle.righthalf.filled") }
                            Button {
                                maskName = m.name
                                renamingMask = true
                            } label: { Label("Rename", systemImage: "pencil") }
                            Button(role: .destructive) { model.maskCommand("mask.delete") } label: { Label("Delete", systemImage: "trash") }
                        } label: {
                            Image(systemName: "ellipsis").font(.system(size: 16, weight: .semibold)).frame(width: 40, height: 32)
                        }
                        .foregroundStyle(.white)
                        .accessibilityLabel(Text("\(m.name) options"))
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 6)
                    .opacity(focused ? 0 : 1)
                    ScrollView {
                        LazyVStack(spacing: 0) {
                            if m.kind == "brush" { brushControls }
                            if m.kind == "object" {
                                Picker("Taps", selection: $model.objectExclude) {
                                    Text("Add").tag(false)
                                    Text("Leave out").tag(true)
                                }
                                .pickerStyle(.segmented)
                                .padding(.horizontal, 20)
                                .padding(.vertical, 6)
                            }
                            if m.kind == "radial" {
                                maskShapeSlider("Feather", key: "feather", m: m, min: 0, max: 100)
                            }
                            ForEach(maskAdjustments, id: \.key) { a in
                                let c = model.maskControl(a)
                                LatentSlider(
                                    control: c,
                                    onBegin: { model.beginMask(a.key) },
                                    onChange: { model.adjustMask(a.key, $0) },
                                    onEnd: { model.end() },
                                    onReset: {
                                        model.beginMask(a.key)
                                        model.adjustMask(a.key, 0)
                                        model.end()
                                    })
                                    .opacity(focused && model.active != c.id ? 0 : 1)
                            }
                        }
                        .padding(.vertical, 4)
                    }
                    .frame(height: 176)
                } else {
                    Text("Pick a mask above, or add one.")
                        .font(.system(size: 14))
                        .foregroundStyle(Theme.secondaryText)
                        .frame(height: 120)
                }
            }
        }
        .padding(.bottom, 4)
        .alert("Describe what to select", isPresented: $describing) {
            TextField("For example: the car", text: $description)
            Button("Cancel", role: .cancel) {}
            Button("Select") { model.addAIMask("prompt", text: description) }
        } message: {
            Text("The AI model finds every match in the photo.")
        }
        .sheet(isPresented: $model.showAIModels) { AIModelsSheet(model: model) }
        .alert("Rename mask", isPresented: $renamingMask) {
            TextField("Name", text: $maskName)
            Button("Cancel", role: .cancel) {}
            Button("Rename") { model.maskCommand("mask.rename", ["name": maskName]) }
        }
    }

    private func maskSymbol(_ kind: String) -> String {
        switch kind {
        case "brush": "paintbrush.pointed"
        case "linear": "rectangle.split.1x2"
        case "radial": "circle.dashed"
        default: "circle.dashed.inset.filled"
        }
    }

    private func maskHint(_ m: MaskItem) -> String {
        switch m.kind {
        case "brush": model.brushErase ? "Erasing: drag over the photo to take the mask away." : "Painting: drag over the photo to add to the mask."
        case "linear": "Drag across the photo: full effect where you start, none where you stop."
        case "radial": "Drag out from a centre to draw it; drag inside it to move it."
        case "object": model.objectExclude ? "Tap parts to leave out of the selection." : "Tap what to select; tap again to add more of it."
        case "sky": "Bright, smooth sky reaching the top of the photo, found without AI."
        case "subject": "The photo's main subject, found without AI."
        case "background": "Everything but the main subject, found without AI."
        default: m.kindLabel
        }
    }

    private var brushControls: some View {
        VStack(spacing: 0) {
            Picker("Brush", selection: $model.brushErase) {
                Text("Paint").tag(false)
                Text("Erase").tag(true)
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, 20)
            .padding(.vertical, 6)
            settingSlider("Size", value: $model.brushSize, min: 0.005, max: 0.3, scale: 100, decimals: 1)
            settingSlider("Feather", value: $model.brushFeather, min: 0, max: 100, scale: 1, decimals: 0)
            settingSlider("Flow", value: $model.brushFlow, min: 1, max: 100, scale: 1, decimals: 0)
        }
    }

    /// A slider for a tool setting (not an edit): no undo step, no render.
    private func settingSlider(_ label: String, value: Binding<Double>, min: Double, max: Double, scale: Double, decimals: Int) -> some View {
        let c = Control(id: "setting.\(label)", label: label, min: min * scale, max: max * scale, defaultValue: value.wrappedValue * scale,
                        step: decimals == 0 ? 1 : 0.1, decimals: decimals, value: value.wrappedValue * scale, track: .plain)
        return LatentSlider(control: c, onBegin: {}, onChange: { value.wrappedValue = $0 / scale }, onEnd: {}, onReset: {})
    }

    /// A slider for a number in the selected mask's shape (a radial's feather).
    private func maskShapeSlider(_ label: String, key: String, m: MaskItem, min: Double, max: Double) -> some View {
        let c = Control(id: "shape.\(key)", label: label, min: min, max: max, defaultValue: 50, step: 1, decimals: 0, value: m.number(key, 50), track: .plain)
        return LatentSlider(
            control: c,
            onBegin: { model.beginMask(label) },
            onChange: { v in
                var shape = m.shape
                shape[key] = v
                model.updateMaskShape(shape)
            },
            onEnd: { model.end() },
            onReset: {})
    }

    // MARK: presets

    private var presetsPanel: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                if !model.presetGroup.isEmpty {
                    Button { withAnimation(.easeInOut(duration: 0.2)) { model.presetGroup = "" } } label: {
                        Image(systemName: "chevron.left").font(.system(size: 17, weight: .semibold)).frame(width: 30, height: 36)
                    }
                    .accessibilityLabel(Text("Groups"))
                }
                Text(model.presetGroup.isEmpty ? "Presets" : model.presetGroup)
                    .font(.system(size: 17, weight: .semibold))
                Spacer()
                if model.presetGroup.isEmpty {
                    Button {
                        newPresetName = ""
                        naming = true
                    } label: {
                        Label("New", systemImage: "plus").font(.system(size: 14, weight: .medium))
                            .padding(.horizontal, 12)
                            .frame(height: 32)
                            .latentGlass(in: Capsule(), interactive: true)
                    }
                    .accessibilityLabel(Text("Save the current edit as a preset"))
                }
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 16)
            .padding(.top, 12)
            .padding(.bottom, 8)
            .opacity(focused ? 0 : 1)
            Rectangle().fill(Theme.separator).frame(height: 1).opacity(focused ? 0 : 1)
            ScrollView {
                LazyVStack(spacing: 0) {
                    if model.presetGroup.isEmpty {
                        ForEach(model.presetGroups, id: \.self) { g in
                            Button { withAnimation(.easeInOut(duration: 0.2)) { model.presetGroup = g } } label: {
                                HStack(spacing: 14) {
                                    PresetThumb(photo: model.photo.id, preset: model.presets(in: g).first?.id)
                                    Text(g).font(.system(size: 16))
                                    Spacer()
                                    Text("\(model.presets(in: g).count)").font(.system(size: 14)).foregroundStyle(Theme.secondaryText)
                                    Image(systemName: "chevron.right").font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.secondaryText)
                                }
                                .padding(.horizontal, 16)
                                .frame(height: 64)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .foregroundStyle(.white)
                        }
                    } else {
                        ForEach(model.presets(in: model.presetGroup)) { p in
                            presetRow(p)
                        }
                    }
                }
                .padding(.vertical, 4)
            }
            .frame(height: model.appliedPreset == nil ? 250 : 196)
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
        .padding(.bottom, 4)
        .alert("New preset", isPresented: $naming) {
            TextField("Name", text: $newPresetName)
            Button("Cancel", role: .cancel) {}
            Button("Save") { model.createPreset(newPresetName) }
        } message: {
            Text("Saves this photo's edit as a preset in User Presets.")
        }
    }

    private func presetRow(_ p: Preset) -> some View {
        let on = model.appliedPreset == p.id
        return HStack(spacing: 14) {
            Button { model.apply(p) } label: {
                HStack(spacing: 14) {
                    PresetThumb(photo: model.photo.id, preset: p.id)
                        .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(Color.white, lineWidth: on ? 2 : 0))
                    Text(p.name).font(.system(size: 16, weight: on ? .semibold : .regular))
                    if p.favorite { Image(systemName: "star.fill").font(.system(size: 11)).foregroundStyle(Theme.secondaryText) }
                    Spacer()
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            Menu {
                Button { model.setFavorite(p, !p.favorite) } label: {
                    Label(p.favorite ? "Remove from Favorites" : "Add to Favorites", systemImage: p.favorite ? "star.slash" : "star")
                }
                if !p.builtin {
                    Button(role: .destructive) { model.deletePreset(p) } label: { Label("Delete", systemImage: "trash") }
                }
            } label: {
                Image(systemName: "ellipsis").font(.system(size: 16, weight: .semibold)).frame(width: 40, height: 44)
            }
            .accessibilityLabel(Text("\(p.name) options"))
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 16)
        .frame(height: 66)
        .accessibilityAddTraits(on ? .isSelected : [])
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
/// double-tap a point to take it away; the curve's two ends stay. With HDR on, the left and lower
/// half of the graph is SDR (up to white) and the rest the range above white, up to the headroom:
/// points there shape only the HDR highlights, and past the last point the curve goes on at slope 1.
struct CurveEditor: View {
    @ObservedObject var model: EditorModel
    @State private var dragging: Int?
    @State private var working: [CGPoint] = []

    /// The share of the graph SDR takes (all of it without HDR).
    private var share: CGFloat { model.hdr ? 0.5 : 1 }
    /// The display-encoded value of the HDR peak, where the graph ends.
    private var top: CGFloat {
        guard model.hdr else { return 1 }
        let peak = pow(2, Swift.min(Swift.max(model.headroom, 0.1), 5))
        return CGFloat(1.055 * pow(peak, 1 / 2.4) - 0.055)
    }

    /// Encoded curve value → 0…1 along an axis.
    private func axis(_ v: CGFloat) -> CGFloat {
        v <= 1 ? v * share : share + (v - 1) / Swift.max(top - 1, 1e-3) * (1 - share)
    }

    /// 0…1 along an axis → encoded value.
    private func value(_ a: CGFloat) -> CGFloat {
        let a = Swift.min(Swift.max(a, 0), 1)
        return a <= share ? a / share : 1 + (a - share) / Swift.max(1 - share, 1e-3) * (top - 1)
    }

    var body: some View {
        let ch = curveChannels[model.curveChannel]
        let color = Color(red: ch.color.0, green: ch.color.1, blue: ch.color.2)
        GeometryReader { geo in
            let size = geo.size
            let pts = dragging == nil ? model.curvePoints : working
            let toView = { (p: CGPoint) in CGPoint(x: axis(p.x) * size.width, y: (1 - axis(p.y)) * size.height) }
            ZStack {
                Rectangle().strokeBorder(Color.white.opacity(0.3), lineWidth: 1)
                Path { path in
                    for i in 1..<4 {
                        let f = CGFloat(i) / 4
                        path.move(to: CGPoint(x: size.width * f, y: 0))
                        path.addLine(to: CGPoint(x: size.width * f, y: size.height))
                        path.move(to: CGPoint(x: 0, y: size.height * f))
                        path.addLine(to: CGPoint(x: size.width, y: size.height * f))
                    }
                }
                .stroke(Color.white.opacity(0.25), lineWidth: 1)
                Path { path in
                    path.move(to: CGPoint(x: 0, y: size.height))
                    path.addLine(to: CGPoint(x: size.width, y: 0))
                }
                .stroke(Color.white.opacity(0.18), style: StrokeStyle(lineWidth: 1, dash: [4, 4]))
                Path { path in
                    let n = 160
                    for i in 0...n {
                        let x = value(CGFloat(i) / CGFloat(n))
                        let p = toView(CGPoint(x: x, y: Swift.min(Swift.max(curveValue(pts, x), 0), top)))
                        if i == 0 { path.move(to: p) } else { path.addLine(to: p) }
                    }
                }
                .stroke(color, lineWidth: 2.5)
                .shadow(color: .black.opacity(0.5), radius: 2)
                if model.hdr {
                    Path { path in
                        path.move(to: CGPoint(x: share * size.width, y: 0))
                        path.addLine(to: CGPoint(x: share * size.width, y: size.height))
                        path.move(to: CGPoint(x: 0, y: (1 - share) * size.height))
                        path.addLine(to: CGPoint(x: size.width, y: (1 - share) * size.height))
                    }
                    .stroke(Color.white.opacity(0.5), lineWidth: 1)
                    HStack(spacing: 0) {
                        Text("SDR").frame(maxWidth: .infinity)
                        Text("HDR").frame(maxWidth: .infinity)
                    }
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(.white)
                    .shadow(color: .black.opacity(0.6), radius: 2)
                    .frame(maxHeight: .infinity, alignment: .bottom)
                    .padding(.bottom, 10)
                }
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

    /// The curve at encoded `x`, as the engine renders it: below white the SDR points' curve; above
    /// it the whole curve, continuing from the SDR curve's value at white, at slope 1 past its end.
    private func curveValue(_ pts: [CGPoint], _ x: CGFloat) -> CGFloat {
        let sdr = pts.filter { $0.x <= 1 + 1e-6 }
        let low = MonotoneCurve(sdr.count >= 2 ? sdr : [CGPoint(x: 0, y: 0), CGPoint(x: 1, y: 1)])
        if x <= 1 || !model.hdr { return CGFloat(low(Double(Swift.min(x, 1)))) }
        let all = pts.sorted { $0.x < $1.x }
        let ext = { (v: CGFloat) -> CGFloat in
            guard let last = all.last else { return v }
            if v >= last.x { return last.y + (v - last.x) }
            return CGFloat(MonotoneCurve(all)(Double(v)))
        }
        return CGFloat(low(1)) + ext(x) - ext(1)
    }

    private func nearest(_ q: CGPoint, in pts: [CGPoint], size: CGSize) -> Int? {
        var best: (Int, CGFloat)?
        for (i, p) in pts.enumerated() {
            let d = hypot(axis(p.x) * size.width - q.x, (1 - axis(p.y)) * size.height - q.y)
            if d < 28, d < (best?.1 ?? .infinity) { best = (i, d) }
        }
        return best?.0
    }

    private func unit(_ q: CGPoint, _ size: CGSize) -> CGPoint {
        CGPoint(x: value(q.x / Swift.max(size.width, 1)), y: value(1 - q.y / Swift.max(size.height, 1)))
    }

    /// The SDR end (white, x = 1) keeps its place across while there is an HDR range beyond it.
    private func isWhiteEnd(_ p: CGPoint) -> Bool { model.hdr && abs(p.x - 1) < 1e-6 }

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
                if isWhiteEnd(working[i]) {
                    p.x = 1
                } else {
                    // a point stays between its neighbours
                    let lo = i == 0 ? 0 : working[i - 1].x + 0.01
                    let hi = i == working.count - 1 ? top : working[i + 1].x - 0.01
                    p.x = lo <= hi ? Swift.min(Swift.max(p.x, lo), hi) : working[i].x
                }
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
        guard let i = nearest(q, in: pts, size: size), i != 0, i != pts.count - 1, !isWhiteEnd(pts[i]) else { return }
        pts.remove(at: i)
        model.beginCurve()
        model.setCurve(pts)
        model.end()
    }
}

/// A preset's preview on the photo, loaded in the background.
struct PresetThumb: View {
    let photo: UInt64
    let preset: String?
    @State private var image: CGImage?

    var body: some View {
        RoundedRectangle(cornerRadius: 6, style: .continuous)
            .fill(Color(white: 0.16))
            .frame(width: 52, height: 52)
            .overlay {
                if let image {
                    Image(decorative: image, scale: 1).resizable().scaledToFill().frame(width: 52, height: 52).transition(.opacity)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            .task(id: preset) {
                guard let preset else { return }
                image = Thumbnails.shared.cachedPreset(photo, preset: preset)
                if image == nil {
                    let img = await Thumbnails.shared.preset(photo, preset: preset, longEdge: 156)
                    withAnimation(.easeOut(duration: 0.2)) { image = img }
                }
            }
            .accessibilityHidden(true)
    }
}

/// Presets' own bottom bar: put back the edit as it was, or keep it.
struct PresetsBar: View {
    let cancel: () -> Void
    let done: () -> Void

    var body: some View {
        HStack {
            Button(action: cancel) { Image(systemName: "xmark").font(.system(size: 18, weight: .semibold)).frame(width: 52, height: 40) }
                .accessibilityLabel(Text("Cancel presets"))
            Spacer()
            Text("Presets").font(.system(size: 16, weight: .semibold))
            Spacer()
            Button(action: done) { Image(systemName: "checkmark").font(.system(size: 18, weight: .semibold)).frame(width: 52, height: 40) }
                .accessibilityLabel(Text("Keep presets"))
        }
        .foregroundStyle(.white)
        .padding(6)
        .latentGlass(in: Capsule(), interactive: true)
        .padding(.horizontal, 14)
        .padding(.top, 8)
        .padding(.bottom, 4)
    }
}

/// The crop box over the whole photo: drag a corner or an edge to resize, inside to move. The
/// photo outside is dimmed; thirds lines show while dragging. Straighten turns the box over the
/// photo. The engine (`crop.drag`) keeps the box on the photo and to the aspect lock.
struct CropEditor: View {
    @ObservedObject var model: EditorModel
    let image: CGImage
    let size: CGSize
    @State private var drag: (handle: String, from: CGPoint, start: CGRect)?

    /// Where the photo sits in the view, fitted.
    private var fitted: CGRect {
        let iw = CGFloat(image.width)
        let ih = CGFloat(image.height)
        guard iw > 0, ih > 0 else { return .zero }
        let s = Swift.min((size.width - 32) / iw, (size.height - 32) / ih)
        let w = iw * s
        let h = ih * s
        return CGRect(x: (size.width - w) / 2, y: (size.height - h) / 2, width: w, height: h)
    }

    /// Straightened-frame point (0…1) → view point: turned back by the angle about the centre (in
    /// pixel proportions), then mirrored as the photo is.
    private func toView(_ p: CGPoint) -> CGPoint {
        let f = fitted
        let a = -model.cropAngle * .pi / 180
        let (w, h) = (f.width, f.height)
        let dx = (p.x - 0.5) * w
        let dy = (p.y - 0.5) * h
        var x = (dx * cos(a) - dy * sin(a)) / w + 0.5
        var y = (dx * sin(a) + dy * cos(a)) / h + 0.5
        if model.flipH { x = 1 - x }
        if model.flipV { y = 1 - y }
        return CGPoint(x: f.minX + x * w, y: f.minY + y * h)
    }

    /// The inverse of `toView`.
    private func toFrame(_ q: CGPoint) -> CGPoint {
        let f = fitted
        let (w, h) = (Swift.max(f.width, 1), Swift.max(f.height, 1))
        var x = (q.x - f.minX) / w
        var y = (q.y - f.minY) / h
        if model.flipH { x = 1 - x }
        if model.flipV { y = 1 - y }
        let a = model.cropAngle * .pi / 180
        let dx = (x - 0.5) * w
        let dy = (y - 0.5) * h
        return CGPoint(x: (dx * cos(a) - dy * sin(a)) / w + 0.5, y: (dx * sin(a) + dy * cos(a)) / h + 0.5)
    }

    private var corners: [CGPoint] {
        let r = model.cropRect
        return [CGPoint(x: r.minX, y: r.minY), CGPoint(x: r.maxX, y: r.minY), CGPoint(x: r.maxX, y: r.maxY), CGPoint(x: r.minX, y: r.maxY)].map(toView)
    }

    var body: some View {
        let f = fitted
        let q = corners
        ZStack {
            Image(decorative: image, scale: 1)
                .resizable()
                .interpolation(.high)
                .frame(width: f.width, height: f.height)
                .position(x: f.midX, y: f.midY)
            // dim outside the box
            Path { p in
                p.addRect(CGRect(origin: .zero, size: size))
                p.addLines(q)
                p.closeSubpath()
            }
            .fill(Color.black.opacity(0.6), style: FillStyle(eoFill: true))
            Path { p in
                p.addLines(q)
                p.closeSubpath()
            }
            .stroke(Color.white, lineWidth: 1)
            // thirds
            Path { p in
                for t in [1.0 / 3, 2.0 / 3] {
                    let l = CGFloat(t)
                    p.move(to: lerp(q[0], q[3], l))
                    p.addLine(to: lerp(q[1], q[2], l))
                    p.move(to: lerp(q[0], q[1], l))
                    p.addLine(to: lerp(q[3], q[2], l))
                }
            }
            .stroke(Color.white.opacity(drag == nil ? 0.35 : 0.7), lineWidth: 0.75)
            // corner brackets
            Path { p in
                for i in 0..<4 {
                    let c = q[i]
                    let a = q[(i + 1) % 4]
                    let b = q[(i + 3) % 4]
                    p.move(to: towards(c, a, 22))
                    p.addLine(to: c)
                    p.addLine(to: towards(c, b, 22))
                }
            }
            .stroke(Color.white, style: StrokeStyle(lineWidth: 4, lineCap: .square, lineJoin: .miter))
        }
        .frame(width: size.width, height: size.height)
        .contentShape(Rectangle())
        .gesture(
            DragGesture(minimumDistance: 2)
                .onChanged { g in
                    if drag == nil {
                        let handle = hit(g.startLocation, q)
                        drag = (handle, toFrame(g.startLocation), model.cropRect)
                        model.beginCrop()
                    }
                    guard let d = drag else { return }
                    model.dragCrop(d.handle, from: d.from, to: toFrame(g.location), start: d.start)
                }
                .onEnded { _ in
                    drag = nil
                    model.end()
                }
        )
        .accessibilityLabel(Text("Crop box"))
        .accessibilityHint(Text("Drag a corner or an edge to crop; drag inside to move the crop."))
    }

    private func lerp(_ a: CGPoint, _ b: CGPoint, _ t: CGFloat) -> CGPoint { CGPoint(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t) }

    private func towards(_ a: CGPoint, _ b: CGPoint, _ d: CGFloat) -> CGPoint {
        let len = Swift.max(hypot(b.x - a.x, b.y - a.y), 1)
        return CGPoint(x: a.x + (b.x - a.x) / len * Swift.min(d, len / 3), y: a.y + (b.y - a.y) / len * Swift.min(d, len / 3))
    }

    /// Which handle a touch at `p` takes: a corner, then an edge, else the whole box.
    private func hit(_ p: CGPoint, _ q: [CGPoint]) -> String {
        let cornerNames = ["topLeft", "topRight", "bottomRight", "bottomLeft"]
        if let i = q.indices.min(by: { hypot(q[$0].x - p.x, q[$0].y - p.y) < hypot(q[$1].x - p.x, q[$1].y - p.y) }),
           hypot(q[i].x - p.x, q[i].y - p.y) < 40 {
            return cornerNames[i]
        }
        let edgeNames = ["top", "right", "bottom", "left"]
        var best: (Int, CGFloat)?
        for i in 0..<4 {
            let d = distance(p, q[i], q[(i + 1) % 4])
            if d < 28, d < (best?.1 ?? .infinity) { best = (i, d) }
        }
        if let b = best { return edgeNames[b.0] }
        return "move"
    }

    private func distance(_ p: CGPoint, _ a: CGPoint, _ b: CGPoint) -> CGFloat {
        let dx = b.x - a.x
        let dy = b.y - a.y
        let len2 = Swift.max(dx * dx + dy * dy, 1e-6)
        let t = Swift.min(Swift.max(((p.x - a.x) * dx + (p.y - a.y) * dy) / len2, 0), 1)
        return hypot(p.x - (a.x + t * dx), p.y - (a.y + t * dy))
    }
}

/// Drawing the selected mask on the photo: a brush paints (or erases) where you drag; a linear
/// gradient runs from where you start to where you stop; a radial is drawn out from its centre,
/// or moved by dragging inside it. Outlines show the gradients; the red overlay shows the result.
struct MaskCanvas: View {
    @ObservedObject var model: EditorModel
    let imageSize: CGSize
    let size: CGSize
    @State private var stroke: [CGPoint] = []
    @State private var start: (mask: MaskItem, at: CGPoint)?

    /// Where the picture sits in the view, fitted.
    private var fitted: CGRect {
        guard imageSize.width > 0, imageSize.height > 0 else { return .zero }
        let s = Swift.min(size.width / imageSize.width, size.height / imageSize.height)
        let w = imageSize.width * s
        let h = imageSize.height * s
        return CGRect(x: (size.width - w) / 2, y: (size.height - h) / 2, width: w, height: h)
    }

    private func toMask(_ q: CGPoint) -> CGPoint {
        let f = fitted
        return model.toMask(CGPoint(x: (q.x - f.minX) / Swift.max(f.width, 1), y: (q.y - f.minY) / Swift.max(f.height, 1)))
    }

    private func toView(_ m: CGPoint) -> CGPoint {
        let f = fitted
        let u = model.fromMask(m)
        return CGPoint(x: f.minX + u.x * f.width, y: f.minY + u.y * f.height)
    }

    /// View points per unit of the photo's long edge.
    private var perLongEdge: CGFloat {
        let f = fitted
        let a = model.photoAspect
        let perWidth = f.width / Swift.max(model.cropRect.width, 1e-6)
        return a >= 1 ? perWidth : perWidth / Swift.max(a, 1e-6)
    }

    var body: some View {
        let m = model.currentMask
        ZStack {
            if let m {
                outline(m)
            }
            if !stroke.isEmpty {
                Path { p in p.addLines(stroke) }
                    .stroke(Color.white.opacity(0.7), style: StrokeStyle(lineWidth: Swift.max(2, model.brushSize * perLongEdge * 2), lineCap: .round, lineJoin: .round))
                    .opacity(0.35)
            }
        }
        .frame(width: size.width, height: size.height)
        .contentShape(Rectangle())
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { g in
                    guard let m = model.currentMask else { return }
                    switch m.kind {
                    case "object":
                        break
                    case "brush":
                        if stroke.isEmpty { model.beginMask("Brush") }
                        stroke.append(g.location)
                    case "linear":
                        if start == nil {
                            start = (m, g.startLocation)
                            model.beginMask("Linear Gradient")
                        }
                        let a = toMask(g.startLocation)
                        let b = toMask(g.location)
                        model.updateMaskShape(["kind": "linear", "start": ["x": a.x, "y": a.y], "end": ["x": b.x, "y": b.y]])
                    case "radial":
                        if start == nil {
                            start = (m, g.startLocation)
                            model.beginMask("Radial Gradient")
                        }
                        guard let s = start else { return }
                        var shape = s.mask.shape
                        let c0 = s.mask.point("center") ?? CGPoint(x: 0.5, y: 0.5)
                        let cv = toView(c0)
                        let rx = s.mask.number("rx", 0.2)
                        let inside = hypot(s.at.x - cv.x, s.at.y - cv.y) < CGFloat(rx) * perLongEdge * 0.8
                        if inside {
                            // move it
                            let d0 = toMask(s.at)
                            let d1 = toMask(g.location)
                            shape["center"] = ["x": c0.x + d1.x - d0.x, "y": c0.y + d1.y - d0.y]
                        } else {
                            // draw a new one out from where the drag began
                            let c = toMask(s.at)
                            let r = Swift.max(Double(hypot(g.location.x - s.at.x, g.location.y - s.at.y) / perLongEdge), 0.02)
                            let ratio = s.mask.number("ry", 0.16) / Swift.max(rx, 1e-3)
                            shape["center"] = ["x": c.x, "y": c.y]
                            shape["rx"] = r
                            shape["ry"] = r * ratio
                        }
                        model.updateMaskShape(shape)
                    default:
                        break
                    }
                }
                .onEnded { g in
                    if model.currentMask?.kind == "object", hypot(g.translation.width, g.translation.height) < 10 {
                        model.objectPoint(toMask(g.location))
                    }
                    if !stroke.isEmpty {
                        model.brushStroke(stroke.map(toMask))
                        stroke = []
                        model.end()
                    }
                    if start != nil {
                        start = nil
                        model.end()
                    }
                }
        )
        .accessibilityLabel(Text("Mask drawing area"))
    }

    @ViewBuilder
    private func outline(_ m: MaskItem) -> some View {
        switch m.kind {
        case "linear":
            if let a = m.point("start"), let b = m.point("end") {
                let va = toView(a)
                let vb = toView(b)
                let dx = vb.x - va.x
                let dy = vb.y - va.y
                let len = Swift.max(hypot(dx, dy), 1)
                let n = CGPoint(x: -dy / len * 2000, y: dx / len * 2000)
                ZStack {
                    Path { p in
                        p.move(to: CGPoint(x: va.x - n.x, y: va.y - n.y))
                        p.addLine(to: CGPoint(x: va.x + n.x, y: va.y + n.y))
                        p.move(to: CGPoint(x: vb.x - n.x, y: vb.y - n.y))
                        p.addLine(to: CGPoint(x: vb.x + n.x, y: vb.y + n.y))
                    }
                    .stroke(Color.white, lineWidth: 1.5)
                    Path { p in
                        p.move(to: va)
                        p.addLine(to: vb)
                    }
                    .stroke(Color.white.opacity(0.8), style: StrokeStyle(lineWidth: 1, dash: [5, 4]))
                    Circle().fill(Color.white).frame(width: 12, height: 12).position(va)
                    Circle().strokeBorder(Color.white, lineWidth: 2).frame(width: 12, height: 12).position(vb)
                }
                .clipShape(Rectangle().path(in: fitted))
                .shadow(color: .black.opacity(0.5), radius: 1.5)
            }
        case "object":
            let pts = (m.shape["hint"] as? [[String: Any]] ?? []).map { ($0, false) } + (m.shape["exclude"] as? [[String: Any]] ?? []).map { ($0, true) }
            ZStack {
                ForEach(Array(pts.enumerated()), id: \.offset) { _, e in
                    let x = (e.0["x"] as? NSNumber)?.doubleValue ?? 0
                    let y = (e.0["y"] as? NSNumber)?.doubleValue ?? 0
                    Circle()
                        .fill(e.1 ? Color.red : Color.green)
                        .overlay(Circle().strokeBorder(Color.white, lineWidth: 2))
                        .frame(width: 14, height: 14)
                        .position(toView(CGPoint(x: x, y: y)))
                }
            }
            .shadow(color: .black.opacity(0.5), radius: 1.5)
        case "radial":
            if let c = m.point("center") {
                let vc = toView(c)
                let rx = CGFloat(m.number("rx", 0.2)) * perLongEdge
                let ry = CGFloat(m.number("ry", 0.16)) * perLongEdge
                ZStack {
                    Ellipse()
                        .stroke(Color.white, lineWidth: 1.5)
                        .frame(width: rx * 2, height: ry * 2)
                        .rotationEffect(.degrees(m.number("angle", 0)))
                        .position(vc)
                    Circle().fill(Color.white).frame(width: 10, height: 10).position(vc)
                }
                .shadow(color: .black.opacity(0.5), radius: 1.5)
            }
        default:
            EmptyView()
        }
    }
}

/// How to add the SAM 3 model for AI masks (Select object, Describe), and whether it is in place.
struct AIModelsSheet: View {
    @ObservedObject var model: EditorModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section {
                    HStack {
                        Image(systemName: model.aiModel.installed ? "checkmark.circle.fill" : "exclamationmark.circle")
                            .foregroundStyle(model.aiModel.installed ? .green : .orange)
                        Text(model.aiModel.installed ? "SAM 3 is installed" : "SAM 3 is not installed")
                        Spacer()
                        if model.aiModel.loaded { Text("Loaded").foregroundStyle(.secondary) }
                    }
                    Button("Check again") { model.refreshAIModel() }
                } footer: {
                    Text("Sky, Subject and Background work without it. Select object and Describe use it.")
                }
                Section("Add the model") {
                    step(1, "On huggingface.co, open facebook/sam3 and accept Meta's licence (\(model.aiModel.license)).")
                    step(2, "Download three files from it: model.safetensors (3.4 GB), vocab.json and merges.txt.")
                    step(3, "In the Files app, open On My iPhone \u{203A} Latent \u{203A} Models \u{203A} SAM3, and move the three files there.")
                    step(4, "Come back here and tap Check again.")
                    if let url = URL(string: "shareddocuments://" + Engine.aiModelFolder.path) {
                        Link(destination: url) { Label("Open the SAM3 folder in Files", systemImage: "folder") }
                    }
                    if let url = URL(string: "https://huggingface.co/facebook/sam3") {
                        Link(destination: url) { Label("facebook/sam3 on Hugging Face", systemImage: "safari") }
                    }
                }
                Section {
                    Text("The model is Meta's, under its own licence, not Latent's; Latent only reads it from your phone. It needs about 3.5 GB of memory while it runs, so it suits phones with 8 GB (iPhone 15 Pro and later). The first selection after opening a photo takes longest.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    if let url = model.aiModel.licenseURL {
                        Link("Read the licence", destination: url).font(.footnote)
                    }
                }
            }
            .navigationTitle("AI models")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
        .onAppear { model.refreshAIModel() }
    }

    private func step(_ n: Int, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Text("\(n)").font(.system(size: 13, weight: .bold)).frame(width: 22, height: 22).background(Circle().fill(Color.white.opacity(0.15)))
            Text(text).font(.system(size: 15))
        }
    }
}
