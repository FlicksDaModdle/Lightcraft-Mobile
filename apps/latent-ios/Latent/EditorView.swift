import SwiftUI
import UniformTypeIdentifiers

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
    /// Describe was chosen to add to (or take from) a mask: the op; nil makes a new mask.
    @State private var describeOp: String?
    @State private var chromeHidden = false
    @State private var showingOriginal = false
    @State private var hold: Task<Void, Never>?
    /// Pinch zoom: the scale and where the zoomed photo has been moved to.
    @State private var zoom: CGFloat = 1
    @State private var pan: CGSize = .zero
    @State private var pinchStart: (zoom: CGFloat, pan: CGSize)?
    @State private var panStart: CGSize?
    @State private var importingLUTs = false
    @AppStorage("editorBackground") private var background = EditorBackground.photo.rawValue
    /// The colour taken from the photo, for the "From photo" background.
    @State private var ambient: Color?
    @Namespace private var glass
    @State private var sharing = false
    @State private var info: InfoBox?
    @State private var savingPreset = false
    @State private var presetName = ""
    /// The library's photos, for sharing several at once.
    private let library: [Photo]

    init(photo: Photo, library: [Photo] = []) {
        _model = StateObject(wrappedValue: EditorModel(photo: photo))
        self.library = library.isEmpty ? [photo] : library
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
        .background(backdrop.ignoresSafeArea())
        .animation(.easeInOut(duration: 0.3), value: background)
        .task(id: model.image.map(ObjectIdentifier.init)) {
            guard background == EditorBackground.photo.rawValue, let img = model.image else { return }
            // wait for the slider to settle, then take the colour off the main thread
            try? await Task.sleep(nanoseconds: 250_000_000)
            guard !Task.isCancelled else { return }
            let c = await Task.detached(priority: .utility) { Ambient.color(of: img) }.value
            withAnimation(.easeInOut(duration: 0.8)) { ambient = c }
        }
        .overlay(alignment: .top) { toast }
        .animation(.glass, value: model.toast)
        .sheet(isPresented: $model.showDepthModel) {
            ModelSheet(DepthModel) { model.estimateDepth() }
        }
        .sheet(isPresented: $model.showInpaintModel) {
            ModelSheet(InpaintModel) { model.inpaintModelInstalled() }
        }
        .sheet(isPresented: $sharing) {
            ShareView(photos: library, current: model.photo.id)
                .presentationDragIndicator(.visible)
        }
        .sheet(item: $info) { box in
            PhotoInfoView(info: box.info).presentationDetents([.medium, .large])
        }
        .alert("New preset", isPresented: $savingPreset) {
            TextField("Name", text: $presetName)
            Button("Cancel", role: .cancel) {}
            Button("Save") { model.createPreset(presetName) }
        } message: {
            Text("Saves this photo's edits (but not crop, masks or spots) as a preset.")
        }
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
                Group {
                    if model.mode == .crop { cropHeader } else { topBar }
                }
                .opacity(focused ? 0 : 1)
            }
            photoArea
            if chrome {
                card
                    .padding(.horizontal, 8)
                    .padding(.top, 6)
                Group {
                    if model.profilesOpen && model.mode == .edit {
                        PresetsBar(title: "Profile", cancel: { model.cancelProfiles() }, done: { model.doneProfiles() })
                            .latentGlassID("bottomBar", in: glass)
                    } else if model.mode == .remove {
                        PresetsBar(title: "Remove", cancel: { withAnimation(.glass) { model.cancelRemove() } }, done: { withAnimation(.glass) { model.doneRemove() } })
                            .latentGlassID("bottomBar", in: glass)
                    } else if model.mode == .masks {
                        PresetsBar(title: "Masking", cancel: { withAnimation(.glass) { model.cancelMasks() } }, done: { withAnimation(.glass) { model.doneMasks() } })
                            .latentGlassID("bottomBar", in: glass)
                    } else if model.mode == .crop {
                        PresetsBar(title: "Crop", cancel: { withAnimation(.glass) { model.cancelCrop() } }, done: { withAnimation(.glass) { model.doneCrop() } })
                            .latentGlassID("bottomBar", in: glass)
                    } else if model.mode == .presets {
                        PresetsBar(cancel: { withAnimation(.glass) { model.cancelPresets() } }, done: { withAnimation(.glass) { model.donePresets() } })
                            .latentGlassID("bottomBar", in: glass)
                    } else {
                        ModeBar(mode: model.mode, glassID: "bottomBar", namespace: glass) { m in
                            if m.available {
                                UISelectionFeedbackGenerator().selectionChanged()
                                withAnimation(.glass) { model.mode = m }
                            } else {
                                model.toast = "\(m.label) is not in Latent yet. It's coming in a later build."
                            }
                        }
                    }
                }
                .latentGlassGroup()
                .opacity(focused ? 0 : 1)
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
    }

    /// What's behind the photo: a chosen grey, or a dark colour taken from the photo with a
    /// soft glow in the middle.
    @ViewBuilder private var backdrop: some View {
        let choice = EditorBackground(rawValue: background) ?? .photo
        if choice == .photo {
            let base = ambient ?? choice.color
            ZStack {
                base
                RadialGradient(colors: [base.opacity(0), Color.black.opacity(0.45)], center: .center, startRadius: 80, endRadius: 620)
                LinearGradient(colors: [Color.white.opacity(0.05), .clear], startPoint: .top, endPoint: .center)
            }
        } else {
            choice.color
        }
    }

    // MARK: top

    /// Crop's own top: the shape's name, and undo.
    private var cropHeader: some View {
        ZStack {
            Text(model.cropTitle)
                .font(.system(size: 17, weight: .semibold))
                .contentTransition(.interpolate)
                .animation(.glass, value: model.cropTitle)
            HStack(spacing: 4) {
                Spacer()
                Button { model.undo() } label: {
                    Image(systemName: "arrow.uturn.backward").frame(width: 44, height: 44).latentGlass(in: Circle(), interactive: true)
                }
                .disabled(!model.canUndo)
                .accessibilityLabel(Text("Undo"))
            }
        }
        .font(.system(size: 17, weight: .medium))
        .foregroundStyle(.white)
        .padding(.horizontal, 16)
        .frame(height: 52)
    }

    private var topBar: some View {
        HStack(spacing: 10) {
            Button { dismiss() } label: { glassIcon("chevron.left", weight: .semibold) }
                .accessibilityLabel(Text("Back"))
            Spacer()
            HStack(spacing: 4) {
                Button { model.undo() } label: {
                    Image(systemName: "arrow.uturn.backward")
                        .frame(width: 44, height: 44)
                        .latentGlass(in: Circle(), interactive: true)
                        .latentGlassID("undo", in: glass)
                }
                .disabled(!model.canUndo)
                .accessibilityLabel(Text("Undo"))
                if model.canRedo {
                    Button { model.redo() } label: {
                        Image(systemName: "arrow.uturn.forward")
                            .frame(width: 44, height: 44)
                            .latentGlass(in: Circle(), interactive: true)
                            .latentGlassID("redo", in: glass)
                    }
                    .accessibilityLabel(Text("Redo"))
                    .transition(.scale(scale: 0.4).combined(with: .opacity))
                }
            }
            .latentGlassGroup(spacing: 14)
            .animation(.glass, value: model.canRedo)
            HStack(spacing: 0) {
                Button { sharing = true } label: { Image(systemName: "square.and.arrow.up").frame(width: 42, height: 44) }
                    .accessibilityLabel(Text("Share"))
                Button { model.saveToPhotos() } label: {
                    Group {
                        if model.saving {
                            ProgressView().tint(.white)
                        } else {
                            Image(systemName: "square.and.arrow.down")
                        }
                    }
                    .frame(width: 42, height: 44)
                }
                .disabled(model.saving)
                .accessibilityLabel(Text("Save to Photos"))
            }
            .padding(.horizontal, 4)
            .latentGlass(in: Capsule(), interactive: true)
            moreMenu
        }
        .font(.system(size: 17, weight: .medium))
        .foregroundStyle(.white)
        .padding(.horizontal, 16)
        .frame(height: 52)
    }

    private var moreMenu: some View {
        Menu {
            ControlGroup {
                Button { if let d = model.info() { info = InfoBox(info: d) } } label: { Label("Info", systemImage: "info.circle") }
                Button { showHistogram.toggle() } label: {
                    Label(showHistogram ? "Hide histogram" : "Histogram", systemImage: "chart.bar.xaxis")
                }
                Button { sharing = true } label: { Label("Export", systemImage: "square.and.arrow.up") }
            }
            Menu {
                Toggle(isOn: $showHistogram) { Label("Histogram", systemImage: "chart.bar.xaxis") }
                Picker(selection: $background) {
                    ForEach(EditorBackground.allCases) { b in
                        Text(b.label).tag(b.rawValue)
                    }
                } label: {
                    Label("Background", systemImage: "square.fill.on.square")
                }
                .pickerStyle(.menu)
            } label: {
                Label("View options", systemImage: "eye")
            }
            Section {
                Button { model.copySettings() } label: { Label("Copy edits", systemImage: "doc.on.doc") }
                Button { model.pasteSettings() } label: { Label("Paste edits", systemImage: "doc.on.clipboard") }
                    .disabled(!model.canPaste)
                Button { model.applyPrevious() } label: { Label("Apply from previous photo", systemImage: "arrow.uturn.left.square") }
                Button {
                    presetName = ""
                    savingPreset = true
                } label: { Label("Create preset", systemImage: "plus.circle") }
            }
            Section {
                Button { model.auto() } label: { Label("Auto settings", systemImage: "wand.and.stars") }
                Button(role: .destructive) { model.resetAll() } label: { Label("Reset all edits", systemImage: "arrow.counterclockwise") }
            }
        } label: {
            glassIcon("ellipsis")
        }
        .accessibilityLabel(Text("More"))
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
                    // the photo and what is drawn on it zoom together
                    ZStack {
                        Image(decorative: img, scale: 1)
                            .resizable()
                            .interpolation(.high)
                            .allowedDynamicRange(model.showingHDR && !showingOriginal ? .high : .standard)
                            .scaledToFit()
                            .shadow(color: .black.opacity(background == EditorBackground.black.rawValue || zoom > 1 ? 0 : 0.35), radius: 16, y: 6)
                            .frame(width: geo.size.width, height: geo.size.height)
                        if model.showDepth, model.tool == .blur, let dv = model.depthView {
                            Image(decorative: dv, scale: 1)
                                .resizable()
                                .interpolation(.high)
                                .scaledToFit()
                                .frame(width: geo.size.width, height: geo.size.height)
                                .transition(.opacity)
                                .allowsHitTesting(false)
                        }
                        if model.mode == .masks && chrome, model.currentMask != nil {
                            MaskCanvas(model: model, imageSize: CGSize(width: img.width, height: img.height), size: geo.size, zoom: zoom)
                        }
                        if model.mode == .remove && chrome {
                            SpotCanvas(model: model, imageSize: CGSize(width: img.width, height: img.height), size: geo.size, zoom: zoom)
                        }
                    }
                    .scaleEffect(zoom)
                    .offset(pan)
                } else {
                    ProgressView().tint(.white).frame(width: geo.size.width, height: geo.size.height)
                }
                if model.mode == .masks && chrome && !focused {
                    HStack(alignment: .bottom) {
                        maskSideTools
                        Spacer()
                        maskColumn
                    }
                    .padding(.horizontal, 10)
                    .padding(.bottom, 10)
                    .frame(width: geo.size.width, height: geo.size.height, alignment: .bottom)
                    .transition(.opacity)
                }
                if zoom > 1.01 {
                    HStack(spacing: 6) {
                        Button { resetZoom() } label: {
                            Text("\(Int((zoom * 100).rounded()))%")
                                .font(.system(size: 13, weight: .semibold))
                                .monospacedDigit()
                                .contentTransition(.numericText())
                                .padding(.horizontal, 12)
                                .frame(height: 30)
                                .latentGlass(in: Capsule(), interactive: true)
                        }
                        .accessibilityLabel(Text("Zoom \(Int((zoom * 100).rounded())) percent. Fit the photo"))
                    }
                    .foregroundStyle(.white)
                    .latentGlassGroup()
                    .frame(maxWidth: .infinity, alignment: .trailing)
                    .padding(.trailing, 12)
                    .padding(.top, 8)
                    .transition(.opacity.combined(with: .scale(scale: 0.8)))
                }
                if showHistogram && chrome && model.tool != .curve && model.mode != .crop && model.mode != .masks && model.mode != .remove && !focused && zoom <= 1.01 {
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
                        .contentTransition(.numericText())
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
            .clipped()
            .gesture(pinch(geo.size))
            .simultaneousGesture(panWhenZoomed(geo.size), including: zoom > 1.01 && !drawsOnPhoto ? .all : .subviews)
            .onTapGesture(count: 2) { at in
                guard model.mode != .crop else { return }
                withAnimation(.glass) {
                    if zoom > 1.01 {
                        zoom = 1
                        pan = .zero
                    } else {
                        // zoom in on the tapped point
                        let z: CGFloat = 2.5
                        let c = CGPoint(x: geo.size.width / 2, y: geo.size.height / 2)
                        zoom = z
                        pan = clampPan(CGSize(width: -(at.x - c.x) * (z - 1), height: -(at.y - c.y) * (z - 1)), geo.size, z)
                    }
                }
                model.zoomChanged(zoom)
            }
            .onTapGesture { at in
                if model.tapToFocus && model.tool == .blur {
                    if let u = shownPoint(at, in: geo.size) { model.focus(atShown: u) }
                    return
                }
                if !drawsOnPhoto && model.mode != .crop { chromeHidden.toggle() }
            }
            .onChange(of: model.mode) { _, m in if m == .crop { resetZoom() } }
            .onLongPressGesture(minimumDuration: 0.3, maximumDistance: 24, perform: {}, onPressingChanged: { pressing in
                hold?.cancel()
                if pressing && model.mode != .crop && !drawsOnPhoto {
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
            .accessibilityHint(Text("Tap to hide the controls. Touch and hold to see the original. Pinch or double-tap to zoom."))
            .accessibilityZoomAction { action in
                withAnimation(.glass) {
                    zoom = Swift.min(Swift.max(zoom * (action.direction == .zoomIn ? 1.5 : 1 / 1.5), 1), 8)
                    if zoom <= 1.01 { pan = .zero }
                }
                model.zoomChanged(zoom)
            }
        }
    }

    /// Masks and Remove draw with one finger, so there the photo moves with two.
    private var drawsOnPhoto: Bool { model.mode == .masks || model.mode == .remove }

    /// Where a tap on the photo area lands on the shown picture (0…1 across and down), the zoom
    /// undone; nil off the picture.
    private func shownPoint(_ at: CGPoint, in size: CGSize) -> CGPoint? {
        guard let img = model.image, img.width > 0, img.height > 0 else { return nil }
        let cx = size.width / 2
        let cy = size.height / 2
        let qx: CGFloat = cx + (at.x - cx - pan.width) / zoom
        let qy: CGFloat = cy + (at.y - cy - pan.height) / zoom
        let scale: CGFloat = Swift.min(size.width / CGFloat(img.width), size.height / CGFloat(img.height))
        let fw: CGFloat = CGFloat(img.width) * scale
        let fh: CGFloat = CGFloat(img.height) * scale
        let u = CGPoint(x: (qx - (size.width - fw) / 2) / fw, y: (qy - (size.height - fh) / 2) / fh)
        return (0...1).contains(u.x) && (0...1).contains(u.y) ? u : nil
    }

    private func resetZoom() {
        withAnimation(.glass) {
            zoom = 1
            pan = .zero
        }
        model.zoomChanged(1)
    }

    /// Keep the zoomed photo covering the view.
    private func clampPan(_ p: CGSize, _ size: CGSize, _ z: CGFloat) -> CGSize {
        let mx = size.width * (z - 1) / 2
        let my = size.height * (z - 1) / 2
        return CGSize(width: Swift.min(Swift.max(p.width, -mx), mx), height: Swift.min(Swift.max(p.height, -my), my))
    }

    /// Two fingers: zoom around the point between them, and move with them.
    private func pinch(_ size: CGSize) -> PinchPan {
        PinchPan(
            began: {
                // the crop box has the photo to itself
                guard model.mode != .crop else { return }
                pinchStart = (zoom, pan)
                model.pinching = true
            },
            changed: { scale, now, start in
                guard let s = pinchStart else { return }
                let z = Swift.min(Swift.max(s.zoom * scale, 1), 8)
                let c = CGPoint(x: size.width / 2, y: size.height / 2)
                // the photo point that was between the fingers when the pinch began follows them
                let px = (start.x - c.x - s.pan.width) / s.zoom
                let py = (start.y - c.y - s.pan.height) / s.zoom
                zoom = z
                pan = clampPan(CGSize(width: now.x - c.x - px * z, height: now.y - c.y - py * z), size, z)
            },
            ended: {
                guard pinchStart != nil else { return }
                pinchStart = nil
                model.pinching = false
                if zoom < 1.05 {
                    resetZoom()
                } else {
                    model.zoomChanged(zoom)
                }
            })
    }

    /// One finger moves a zoomed photo (when nothing is drawn with it).
    private func panWhenZoomed(_ size: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 8)
            .onChanged { v in
                guard zoom > 1.01, pinchStart == nil, !drawsOnPhoto else { return }
                if panStart == nil { panStart = pan }
                let s = panStart ?? .zero
                pan = clampPan(CGSize(width: s.width + v.translation.width, height: s.height + v.translation.height), size, zoom)
            }
            .onEnded { _ in panStart = nil }
    }

    // MARK: the card

    private var card: some View {
        VStack(spacing: 0) {
            Group {
                switch model.mode {
                case .presets: presetsPanel
                case .crop: cropPanel
                case .masks: masksPanel
                case .remove: removePanel
                default:
                    if model.profilesOpen {
                        profilesPanel
                    } else {
                        editPanel
                        ToolStrip(model: model).opacity(focused ? 0 : 1)
                    }
                }
            }
            .id(model.mode)
            .transition(.asymmetric(
                insertion: .opacity.combined(with: .scale(scale: 0.97, anchor: .bottom)).combined(with: .offset(y: 8)),
                removal: .opacity))
        }
        .animation(.glass, value: model.mode)
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
            .opacity(focused && model.active != c.id ? 0 : (c.section == "lensBlur" && !model.blurOn ? 0.35 : 1))
            .disabled(c.section == "lensBlur" && !model.blurOn)
    }

    private var editPanel: some View {
        VStack(spacing: 0) {
            Group {
                switch model.tool {
                case .color: colorHeader
                case .mixer: stepHeader("Color mix")
                case .grading: stepHeader("Color grading")
                case .light: lightHeader
                case .blur:
                    blurHeader
                    if model.blurOn { depthControls }
                case .curve: curveHeader
                default: EmptyView()
                }
                if !model.tool.tabs.isEmpty { tabs }
                if model.tool == .mixer { bandChips }
                if model.tool == .grading { rangeChips }
            }
            .opacity(focused ? 0 : 1)
            if model.tool == .grading {
                // the wheel scrolls away with the sliders under it; swipe beside it, left or right, for
                // the next range
                GeometryReader { g in
                    ScrollView {
                        VStack(spacing: 0) {
                            let side = Swift.min(g.size.width - 170, 190)
                            TabView(selection: Binding(get: { model.gradingRange }, set: { r in
                                UISelectionFeedbackGenerator().selectionChanged()
                                withAnimation(.glass) { model.gradingRange = r }
                            })) {
                                ForEach(gradingRanges.indices, id: \.self) { i in
                                    VStack(spacing: 6) {
                                        GradingWheel(model: model, rangeIndex: i)
                                            .frame(width: side, height: side)
                                        Text(gradingRanges[i].label)
                                            .font(.system(size: 12, weight: .semibold))
                                            .foregroundStyle(Theme.secondaryText)
                                    }
                                    .frame(maxWidth: .infinity)
                                    .contentShape(Rectangle())
                                    .tag(i)
                                }
                            }
                            .tabViewStyle(.page(indexDisplayMode: .never))
                            .frame(height: side + 30)
                            .padding(.top, 10)
                            .opacity(focused && model.active != "wheel" ? 0 : 1)
                            HStack(spacing: 6) {
                                ForEach(gradingRanges.indices, id: \.self) { i in
                                    Capsule()
                                        .fill(i == model.gradingRange ? Color.white : Color.white.opacity(0.3))
                                        .frame(width: i == model.gradingRange ? 16 : 6, height: 6)
                                }
                            }
                            .padding(.bottom, 8)
                            .animation(.glass, value: model.gradingRange)
                            .accessibilityHidden(true)
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

    /// Blur: apply it, and choose what stays sharp.
    private var blurHeader: some View {
        HStack(spacing: 10) {
            Toggle(isOn: Binding(get: { model.blurOn }, set: { model.setBlur($0) })) {
                Text("Lens blur").font(.system(size: 15, weight: .semibold))
            }
            .toggleStyle(.switch)
            .tint(Theme.accent)
            .fixedSize()
            Spacer()
            Menu {
                Section("Keep sharp") {
                    Button { model.setFocus(shape: "auto") } label: { focusLabel("The subject", "person.crop.rectangle", on: model.focusMask == nil && model.focusShape == "auto") }
                    Button { model.setFocus(shape: "round") } label: { focusLabel("A circle in the middle", "circle", on: model.focusMask == nil && model.focusShape == "round") }
                    Button { model.setFocus(shape: "wide") } label: { focusLabel("A wide oval", "capsule", on: model.focusMask == nil && model.focusShape == "wide") }
                    Button { model.setFocus(shape: "tall") } label: { focusLabel("A tall oval", "capsule.portrait", on: model.focusMask == nil && model.focusShape == "tall") }
                }
                if !model.masks.isEmpty {
                    Section("Or a mask") {
                        ForEach(model.masks) { m in
                            Button { model.setFocus(mask: m.id) } label: { focusLabel(m.name, maskSymbol(m.kind), on: model.focusMask == m.id) }
                        }
                    }
                }
                Section {
                    Button { model.findBlurSubject() } label: { Label("Find the subject with AI", systemImage: "sparkles") }
                }
            } label: {
                Label(focusTitle, systemImage: "scope").font(.system(size: 13, weight: .medium)).lineLimit(1)
                    .padding(.horizontal, 12).frame(height: 32)
                    .latentGlass(in: Capsule(), interactive: true)
            }
            .disabled(!model.blurOn)
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 16)
        .padding(.top, 12)
        .padding(.bottom, 4)
    }

    /// Blur by depth: Subject or Depth, the Focus Range over the photo's depths, tap to focus,
    /// and the depth map itself.
    @ViewBuilder
    private var depthControls: some View {
        if model.depth != nil {
            VStack(spacing: 10) {
                Picker("Blur by", selection: Binding(get: { model.depthBlur }, set: { $0 ? model.useDepth() : model.useSubject() })) {
                    Text("Subject").tag(false)
                    Text("Depth").tag(true)
                }
                .pickerStyle(.segmented)
                if model.depthBlur, let d = model.depth {
                    HStack(spacing: 8) {
                        Text("Focus range").font(.system(size: 15, weight: .semibold))
                        if d.source == "estimated" { tag("Estimated") }
                        Spacer()
                        Button { withAnimation(.glass) { model.tapToFocus.toggle() } } label: {
                            Image(systemName: "scope")
                                .frame(width: 36, height: 32)
                                .latentGlass(in: Capsule(), tint: model.tapToFocus ? Theme.accent : nil, interactive: true)
                        }
                        .accessibilityLabel(Text(model.tapToFocus ? "Tap the photo to focus there" : "Tap to focus"))
                        Button { withAnimation(.glass) { model.showDepth.toggle() } } label: {
                            Image(systemName: model.showDepth ? "square.3.layers.3d.down.right.slash" : "square.3.layers.3d.down.right")
                                .frame(width: 36, height: 32)
                                .latentGlass(in: Capsule(), tint: model.showDepth ? Theme.accent : nil, interactive: true)
                        }
                        .accessibilityLabel(Text(model.showDepth ? "Show the photo" : "Show the depth map"))
                        Menu {
                            Button { model.estimateDepth() } label: { Label(d.source == "estimated" ? "Estimate again" : "Estimate with the depth model", systemImage: "wand.and.rays") }
                            Button { model.showDepthModel = true } label: { Label("Depth model\u{2026}", systemImage: "cpu") }
                            Button(role: .destructive) { model.removeDepth() } label: { Label("Remove the depth map", systemImage: "trash") }
                        } label: {
                            Image(systemName: "ellipsis").frame(width: 36, height: 32).latentGlass(in: Capsule(), interactive: true)
                        }
                        .accessibilityLabel(Text("Depth options"))
                    }
                    .font(.system(size: 14, weight: .semibold))
                    FocusRangeBar(
                        histogram: d.histogram,
                        lo: model.focalDistance - model.focalRange / 2,
                        hi: model.focalDistance + model.focalRange / 2,
                        begin: { model.beginFocusRange() },
                        change: { model.setFocusRange($0, $1) },
                        end: { model.end() })
                    if model.tapToFocus {
                        Text("Tap the photo where it should be sharp.")
                            .font(.system(size: 12)).foregroundStyle(Theme.secondaryText)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 16)
            .padding(.bottom, 4)
            .opacity(focused && model.active != "focus.range" ? 0 : 1)
            .animation(.glass, value: model.depthBlur)
        } else {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Blur by depth").font(.system(size: 14, weight: .semibold))
                    Text(model.depthBusy ? "Looking for depth\u{2026}" : "This photo has no depth recorded. Estimate it to blur by distance.")
                        .font(.system(size: 12)).foregroundStyle(Theme.secondaryText)
                }
                Spacer()
                if model.depthBusy {
                    ProgressView().tint(.white)
                } else {
                    Button { model.estimateDepth() } label: {
                        Label(DepthModel.installed ? "Estimate" : "Get model", systemImage: "square.3.layers.3d.down.right")
                            .font(.system(size: 13, weight: .semibold))
                            .padding(.horizontal, 12).frame(height: 32)
                            .latentGlass(in: Capsule(), tint: Theme.accent.opacity(0.8), interactive: true)
                    }
                }
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 16)
            .padding(.bottom, 6)
            .opacity(focused ? 0 : 1)
        }
    }

    private var focusTitle: String {
        if model.depthBlur { return "By depth" }
        if let id = model.focusMask, let m = model.masks.first(where: { $0.id == id }) { return m.name }
        switch model.focusShape {
        case "round": return "Circle"
        case "wide": return "Wide oval"
        case "tall": return "Tall oval"
        default: return "Subject"
        }
    }

    @ViewBuilder
    private func focusLabel(_ text: String, _ symbol: String, on: Bool) -> some View {
        if on { Label(text, systemImage: "checkmark") } else { Label(text, systemImage: symbol) }
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
            stepButton("Profile", symbol: "camera.filters") { model.openProfiles() }
                .accessibilityLabel(Text("Profile"))
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
            if let m = model.currentMask {
                maskHeader(m)
                    .opacity(focused ? 0 : 1)
                partsRow(m)
                    .opacity(focused ? 0 : 1)
                ScrollView {
                    LazyVStack(spacing: 0) {
                        partControls
                        let keys = Set(maskGroups[model.maskGroup].keys)
                        ForEach(maskAdjustments.filter { keys.contains($0.key) }, id: \.key) { a in
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
                .frame(height: 168)
                maskGroupStrip(m)
                    .opacity(focused ? 0 : 1)
            } else {
                createGrid
            }
        }
        .padding(.bottom, 4)
        .animation(.glass, value: model.selectedMask)
        .animation(.glass, value: model.selectedPart)
        .alert("Describe what to select", isPresented: $describing) {
            TextField("For example: the car", text: $description)
            Button("Cancel", role: .cancel) {}
            Button("Select") {
                if let op = describeOp {
                    model.addPart("prompt", op: op, text: description)
                } else {
                    model.addAIMask("prompt", text: description)
                }
            }
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

    /// No mask yet: every way to make one.
    private var createGrid: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Create a mask").font(.system(size: 17, weight: .semibold))
                Spacer()
                Button { model.refreshAIModel(); model.showAIModels = true } label: {
                    Label("AI model", systemImage: "cpu").font(.system(size: 13, weight: .medium))
                        .padding(.horizontal, 10).frame(height: 30)
                        .latentGlass(in: Capsule(), interactive: true)
                }
            }
            .foregroundStyle(.white)
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 5), spacing: 8) {
                ForEach(maskTools, id: \.kind) { t in
                    Button { choose(t.kind, op: nil) } label: {
                        VStack(spacing: 6) {
                            Image(systemName: t.symbol).font(.system(size: 20)).frame(height: 26)
                            Text(t.label).font(.system(size: 11)).lineLimit(1).minimumScaleFactor(0.7)
                        }
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity, minHeight: 64)
                        .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                        .overlay(alignment: .topTrailing) {
                            if t.ai {
                                Text("AI").font(.system(size: 8, weight: .heavy)).padding(.horizontal, 4).padding(.vertical, 2)
                                    .background(Theme.accent, in: Capsule()).padding(4)
                            }
                        }
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(Text(t.ai ? "\(t.label), uses the AI model" : t.label))
                }
            }
            Text("Each mask gets its own adjustments. Once it's made, add to it or take from it with more tools.")
                .font(.system(size: 12))
                .foregroundStyle(Theme.secondaryText)
        }
        .padding(.horizontal, 14)
        .padding(.top, 14)
        .padding(.bottom, 6)
    }

    /// Make a mask (op nil) or add a part to the selected one.
    private func choose(_ kind: String, op: String?) {
        if kind == "prompt" {
            model.refreshAIModel()
            guard model.aiModel.installed else {
                model.showAIModels = true
                return
            }
            describeOp = op
            description = ""
            describing = true
            return
        }
        withAnimation(.glass) {
            if let op { model.addPart(kind, op: op) } else { model.addMask(kind) }
        }
    }

    @ViewBuilder
    private func toolMenu(op: String?) -> some View {
        Section("Automatic") {
            ForEach(maskTools.filter { ["subject", "sky", "background"].contains($0.kind) }, id: \.kind) { t in
                Button { choose(t.kind, op: op) } label: { Label(t.label, systemImage: t.symbol) }
            }
        }
        Section("Draw") {
            ForEach(maskTools.filter { ["brush", "linear", "radial"].contains($0.kind) }, id: \.kind) { t in
                Button { choose(t.kind, op: op) } label: { Label(maskKindLabel(t.kind), systemImage: t.symbol) }
            }
        }
        Section("By colour, brightness or depth") {
            ForEach(maskTools.filter { ["colorRange", "luminanceRange", "depthRange"].contains($0.kind) }, id: \.kind) { t in
                Button { choose(t.kind, op: op) } label: { Label(t.label, systemImage: t.symbol) }
            }
        }
        Section("With the AI model") {
            ForEach(maskTools.filter(\.ai), id: \.kind) { t in
                Button { choose(t.kind, op: op) } label: { Label(t.kind == "prompt" ? "Describe\u{2026}" : "Select object", systemImage: t.symbol) }
            }
            Button { model.refreshAIModel(); model.showAIModels = true } label: { Label("AI model\u{2026}", systemImage: "cpu") }
        }
    }

    @ViewBuilder
    private func maskActions(_ m: MaskItem) -> some View {
        Button {
            maskName = m.name
            renamingMask = true
        } label: { Label("Rename", systemImage: "pencil") }
        Button { model.maskCommand("mask.duplicate") } label: { Label("Duplicate", systemImage: "plus.square.on.square") }
        Button { model.maskCommand("mask.duplicate", ["invert": true]) } label: { Label("Duplicate and invert", systemImage: "square.on.square.intersection.dashed") }
        Button { model.maskCommand("mask.invert") } label: { Label(m.invert ? "Don't invert" : "Invert", systemImage: "circle.righthalf.filled") }
        Button { model.maskCommand("mask.visible", ["visible": !m.visible]) } label: {
            Label(m.visible ? "Hide its effect" : "Show its effect", systemImage: m.visible ? "eye.slash" : "eye")
        }
        Divider()
        Button(role: .destructive) { withAnimation(.glass) { model.maskCommand("mask.delete") } } label: { Label("Delete mask", systemImage: "trash") }
    }

    private func maskHeader(_ m: MaskItem) -> some View {
        HStack(spacing: 10) {
            Menu { maskActions(m) } label: {
                HStack(spacing: 6) {
                    Text(m.name).font(.system(size: 17, weight: .semibold)).lineLimit(1)
                    Image(systemName: "chevron.down").font(.system(size: 12, weight: .bold)).foregroundStyle(Theme.secondaryText)
                }
            }
            .accessibilityLabel(Text("\(m.name), mask options"))
            if m.invert { tag("Inverted") }
            if !m.visible { tag("Hidden") }
            Spacer()
            if model.aiBusy { ProgressView().tint(.white).scaleEffect(0.8) }
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 16)
        .padding(.top, 12)
    }

    private func tag(_ text: String) -> some View {
        Text(text).font(.system(size: 11, weight: .semibold)).foregroundStyle(Theme.secondaryText)
            .padding(.horizontal, 7).padding(.vertical, 3)
            .background(Color.white.opacity(0.08), in: Capsule())
    }

    /// The mask's parts (tap to edit one; hold for its options), then Add and Subtract.
    private func partsRow(_ m: MaskItem) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(Array(m.parts.enumerated()), id: \.offset) { i, part in
                    partChip(part, index: i)
                }
                Menu { toolMenu(op: "add") } label: {
                    Label("Add", systemImage: "plus").font(.system(size: 13, weight: .semibold))
                        .padding(.horizontal, 10).frame(height: 30)
                        .latentGlass(in: Capsule(), interactive: true)
                }
                Menu { toolMenu(op: "subtract") } label: {
                    Label("Subtract", systemImage: "minus").font(.system(size: 13, weight: .semibold))
                        .padding(.horizontal, 10).frame(height: 30)
                        .latentGlass(in: Capsule(), interactive: true)
                }
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 16)
        }
        .padding(.top, 10)
    }

    private func partChip(_ part: MaskPart, index i: Int) -> some View {
        let on = i == model.selectedPart
        let subtracts = part.op == "subtract" && i > 0
        return Button { model.selectedPart = i } label: {
            HStack(spacing: 5) {
                Image(systemName: opSymbol(part.op, first: i == 0)).font(.system(size: 11, weight: .bold))
                    .foregroundStyle(subtracts ? Color(red: 1, green: 0.45, blue: 0.4) : (on ? Color.black : Theme.secondaryText))
                Image(systemName: maskSymbol(part.kind)).font(.system(size: 12, weight: .semibold))
                Text(part.label).font(.system(size: 13, weight: on ? .semibold : .regular)).lineLimit(1)
                if part.invert { Image(systemName: "circle.righthalf.filled").font(.system(size: 10)) }
            }
            .foregroundStyle(on ? Color.black : Color.white)
            .padding(.horizontal, 10)
            .frame(height: 30)
            .background(on ? Color.white : Color.white.opacity(0.1), in: Capsule())
        }
        .contextMenu {
            Button { model.selectedPart = i; model.partCommand("invert") } label: { Label("Invert part", systemImage: "circle.righthalf.filled") }
            Button { model.selectedPart = i; model.partCommand("duplicate") } label: { Label("Duplicate part", systemImage: "plus.square.on.square") }
            if i > 0 {
                Button { model.selectedPart = i; model.partCommand("op", op: "add") } label: { Label("Add to the mask", systemImage: "plus.circle") }
                Button { model.selectedPart = i; model.partCommand("op", op: "subtract") } label: { Label("Take from the mask", systemImage: "minus.circle") }
                Button { model.selectedPart = i; model.partCommand("op", op: "intersect") } label: { Label("Keep only where both", systemImage: "circle.circle") }
            }
            Button(role: .destructive) { model.selectedPart = i; model.partCommand("delete") } label: { Label("Delete part", systemImage: "trash") }
        }
        .accessibilityLabel(Text("\(part.label), \(i == 0 ? "base" : part.op)"))
        .accessibilityAddTraits(on ? .isSelected : [])
    }

    private func opSymbol(_ op: String, first: Bool) -> String {
        if first { return "circle.fill" }
        switch op {
        case "subtract": return "minus.circle.fill"
        case "intersect": return "circle.circle.fill"
        default: return "plus.circle.fill"
        }
    }

    /// The selected part's own settings: brush, object taps, feather, colour or brightness range.
    @ViewBuilder
    private var partControls: some View {
        if let part = model.currentPart {
            switch part.kind {
            case "brush":
                brushControls
            case "object":
                Picker("Taps", selection: $model.objectExclude) {
                    Text("Add").tag(false)
                    Text("Leave out").tag(true)
                }
                .pickerStyle(.segmented)
                .padding(.horizontal, 20)
                .padding(.vertical, 6)
            case "radial":
                partSlider("Feather", key: "feather", part: part, min: 0, max: 100, scale: 1, fallback: 50)
            case "colorRange":
                Picker("Taps", selection: $model.addColorSample) {
                    Text("Pick a colour").tag(false)
                    Text("Add a colour").tag(true)
                }
                .pickerStyle(.segmented)
                .padding(.horizontal, 20)
                .padding(.vertical, 6)
                partSlider("Refine", key: "refine", part: part, min: 0, max: 100, scale: 1, fallback: 50)
            case "depthRange":
                if model.depth == nil {
                    HStack {
                        Text("No depth map for this photo yet.").font(.system(size: 13)).foregroundStyle(Theme.secondaryText)
                        Spacer()
                        Button { model.estimateDepth() } label: {
                            Label(DepthModel.installed ? "Estimate" : "Get model", systemImage: "square.3.layers.3d.down.right")
                                .font(.system(size: 13, weight: .semibold)).padding(.horizontal, 12).frame(height: 30)
                                .latentGlass(in: Capsule(), interactive: true)
                        }
                        .foregroundStyle(.white)
                    }
                    .padding(.horizontal, 20)
                    .padding(.vertical, 6)
                }
                partSlider("Nearest", key: "lo", part: part, min: 0, max: 100, scale: 100, fallback: 0)
                partSlider("Farthest", key: "hi", part: part, min: 0, max: 100, scale: 100, fallback: 0.3)
                partSlider("Soften", key: "feather", part: part, min: 0, max: 100, scale: 100, fallback: 0.1)
            case "luminanceRange":
                partSlider("From", key: "lo", part: part, min: 0, max: 100, scale: 100, fallback: 0.6)
                partSlider("To", key: "hi", part: part, min: 0, max: 100, scale: 100, fallback: 1)
                partSlider("Soften dark end", key: "lo_feather", part: part, min: 0, max: 100, scale: 100, fallback: 0.1)
                partSlider("Soften bright end", key: "hi_feather", part: part, min: 0, max: 100, scale: 100, fallback: 0.1)
            default:
                EmptyView()
            }
            Text(maskHint(part))
                .font(.system(size: 12))
                .foregroundStyle(Theme.secondaryText)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 20)
                .padding(.vertical, 4)
                .opacity(focused ? 0 : 1)
        }
    }

    private func maskHint(_ p: MaskPart) -> String {
        switch p.kind {
        case "brush": return model.brushErase ? "Erasing: drag over the photo to take the mask away." : "Painting: drag over the photo to add to the mask."
        case "linear": return "Drag across the photo: full effect where you start, none where you stop."
        case "radial": return "Drag out from a centre to draw it; drag inside it to move it."
        case "object": return model.objectExclude ? "Tap parts to leave out of the selection." : "Tap what to select; tap again to add more of it."
        case "colorRange": return model.addColorSample ? "Tap another colour to include it too (up to five)." : "Tap a colour in the photo; everything that colour is selected."
        case "luminanceRange": return "Tap the photo to pick a brightness; it selects from dark (0) to bright (100)."
        case "depthRange": return "Tap the photo to pick a distance; it selects from near (0) to far (100)."
        case "sky": return "Bright, smooth sky reaching the top of the photo, found without AI."
        case "subject": return "The photo's main subject, found without AI."
        case "background": return "Everything but the main subject, found without AI."
        default: return p.label
        }
    }

    /// Light, Color, Effects, Detail, Optics, and Reset.
    private func maskGroupStrip(_ m: MaskItem) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 2) {
                ForEach(maskGroups.indices, id: \.self) { i in
                    maskGroupButton(i, m)
                }
                Rectangle().fill(Theme.separator).frame(width: 1, height: 30).padding(.horizontal, 4)
                Button { model.resetMaskAdjustments() } label: {
                    VStack(spacing: 4) {
                        Image(systemName: "arrow.counterclockwise").font(.system(size: 18)).frame(height: 22)
                        Text("Reset").font(.system(size: 11))
                        Color.clear.frame(width: 4, height: 4)
                    }
                    .foregroundStyle(m.edited ? Color.white : Theme.secondaryText)
                    .frame(width: 60, height: 56)
                }
                .buttonStyle(.plain)
                .disabled(!m.edited)
                .accessibilityLabel(Text("Reset this mask's adjustments"))
            }
            .padding(.horizontal, 10)
        }
        .padding(.top, 2)
    }

    private func maskGroupButton(_ i: Int, _ m: MaskItem) -> some View {
        let g = maskGroups[i]
        let on = model.maskGroup == i
        let edited = g.keys.contains { abs(m.adjust[$0] ?? 0) > 1e-9 }
        return Button {
            UISelectionFeedbackGenerator().selectionChanged()
            withAnimation(.glass) { model.maskGroup = i }
        } label: {
            VStack(spacing: 4) {
                Image(systemName: g.symbol).font(.system(size: 18)).frame(height: 22)
                    .symbolEffect(.bounce, value: on)
                Text(g.label).font(.system(size: 11))
                Circle().fill(edited ? Theme.secondaryText : .clear).frame(width: 4, height: 4)
            }
            .foregroundStyle(on ? Color.white : Theme.secondaryText)
            .frame(width: 60, height: 56)
            .background {
                if on {
                    RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color.white.opacity(0.08))
                        .latentGlass(in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                        .matchedGeometryEffect(id: "maskGroup", in: glass)
                }
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(g.label))
        .accessibilityAddTraits(on ? .isSelected : [])
    }

    /// The column over the photo's right side: + for a new mask, then each mask's picture.
    private var maskColumn: some View {
        VStack(spacing: 8) {
            Menu { toolMenu(op: nil) } label: {
                Image(systemName: "plus")
                    .font(.system(size: 18, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 44, height: 44)
                    .latentGlass(in: Circle(), tint: Theme.accent, interactive: true)
            }
            .accessibilityLabel(Text("New mask"))
            if !model.masks.isEmpty {
                ScrollView(.vertical, showsIndicators: false) {
                    VStack(spacing: 8) {
                        ForEach(model.masks.reversed()) { m in maskThumb(m) }
                    }
                    .padding(.vertical, 2)
                }
                .frame(height: CGFloat(Swift.min(model.masks.count, 4)) * 52)
            }
        }
        .padding(6)
        .latentGlass(in: RoundedRectangle(cornerRadius: 28, style: .continuous))
    }

    private func maskThumb(_ m: MaskItem) -> some View {
        let on = m.id == model.selectedMask
        return Button {
            withAnimation(.glass) { model.selectMask(m.id) }
        } label: {
            ZStack {
                Color.black
                if let img = model.maskThumbs[m.id] {
                    Image(decorative: img, scale: 1).resizable().scaledToFill()
                } else {
                    Image(systemName: maskSymbol(m.kind)).font(.system(size: 15)).foregroundStyle(.white)
                }
                if !m.visible {
                    Color.black.opacity(0.5)
                    Image(systemName: "eye.slash").font(.system(size: 13, weight: .semibold)).foregroundStyle(.white)
                }
            }
            .frame(width: 44, height: 44)
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(on ? Theme.accent : Color.white.opacity(0.25), lineWidth: on ? 2.5 : 1))
            .scaleEffect(on ? 1.06 : 1)
        }
        .buttonStyle(.plain)
        .contextMenu { maskActions(m) }
        .accessibilityLabel(Text(m.name))
        .accessibilityAddTraits(on ? .isSelected : [])
    }

    /// Bottom left over the photo: the overlay, how it's drawn, and delete.
    private var maskSideTools: some View {
        VStack(spacing: 8) {
            Button { withAnimation(.glass) { model.maskOverlay.toggle() } } label: {
                Image(systemName: model.maskOverlay ? "circle.dashed.inset.filled" : "circle.dashed")
                    .contentTransition(.symbolEffect(.replace))
                    .frame(width: 44, height: 44)
                    .latentGlass(in: Circle(), interactive: true)
            }
            .accessibilityLabel(Text(model.maskOverlay ? "Hide the overlay" : "Show the overlay"))
            Menu {
                Picker("Show as", selection: $model.maskLook.view) {
                    Text("Colour over the photo").tag("color")
                    Text("Colour over black & white").tag("colorOnBw")
                    Text("Photo on black").tag("imageOnBlack")
                    Text("Photo on white").tag("imageOnWhite")
                    Text("White on black").tag("whiteOnBlack")
                }
                .pickerStyle(.menu)
                Picker("Colour", selection: $model.maskLook.rgb) {
                    Text("Red").tag(UInt32(0xEB4040))
                    Text("Green").tag(UInt32(0x3CD26E))
                    Text("Blue").tag(UInt32(0x3C8CFF))
                    Text("Yellow").tag(UInt32(0xFFD23C))
                    Text("White").tag(UInt32(0xFFFFFF))
                }
                .pickerStyle(.menu)
                Picker("Opacity", selection: $model.maskLook.opacity) {
                    ForEach([25, 50, 75, 100], id: \.self) { Text("\($0)%").tag($0) }
                }
                .pickerStyle(.menu)
            } label: {
                Image(systemName: "paintpalette")
                    .frame(width: 44, height: 44)
                    .latentGlass(in: Circle(), interactive: true)
            }
            .accessibilityLabel(Text("Overlay options"))
            if model.currentMask != nil {
                Button(role: .destructive) { withAnimation(.glass) { model.maskCommand("mask.delete") } } label: {
                    Image(systemName: "trash")
                        .frame(width: 44, height: 44)
                        .latentGlass(in: Circle(), interactive: true)
                }
                .accessibilityLabel(Text("Delete mask"))
            }
        }
        .font(.system(size: 16, weight: .semibold))
        .foregroundStyle(.white)
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

    /// A slider for a number in the selected part's shape (shown × `scale`).
    private func partSlider(_ label: String, key: String, part: MaskPart, min: Double, max: Double, scale: Double, fallback: Double) -> some View {
        let c = Control(id: "shape.\(key)", label: label, min: min, max: max, defaultValue: fallback * scale, step: 1, decimals: 0,
                        value: part.number(key, fallback) * scale, track: .plain)
        return LatentSlider(
            control: c,
            onBegin: { model.beginMask(label) },
            onChange: { v in
                var shape = part.shape
                shape[key] = v / scale
                model.updateMaskShape(shape)
            },
            onEnd: { model.end() },
            onReset: {
                model.beginMask(label)
                var shape = part.shape
                shape[key] = fallback
                model.updateMaskShape(shape)
                model.end()
            })
    }

    // MARK: remove

    private var removePanel: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                ForEach(spotModes, id: \.id) { m in
                    let on = model.spotMode == m.id
                    Button { withAnimation(.glass) { model.setSpotMode(m.id) } } label: {
                        VStack(spacing: 5) {
                            Image(systemName: m.symbol).font(.system(size: 19)).frame(height: 24)
                                .symbolEffect(.bounce, value: on)
                            Text(m.label).font(.system(size: 11))
                        }
                        .foregroundStyle(on ? Color.white : Theme.secondaryText)
                        .frame(maxWidth: .infinity, minHeight: 58)
                        .background {
                            if on {
                                RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color.white.opacity(0.08))
                                    .latentGlass(in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                                    .matchedGeometryEffect(id: "spotMode", in: glass)
                            }
                        }
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(Text(m.label))
                    .accessibilityAddTraits(on ? .isSelected : [])
                }
            }
            .padding(.horizontal, 12)
            .padding(.top, 10)
            .opacity(focused ? 0 : 1)
            spotSlider("Size", key: "size", value: model.spotSize, min: 0.3, max: 20, scale: 100, decimals: 1)
            spotSlider("Feather", key: "feather", value: model.spotFeather, min: 0, max: 100, scale: 1, decimals: 0)
            spotSlider("Opacity", key: "opacity", value: model.spotOpacity, min: 1, max: 100, scale: 1, decimals: 0)
            HStack(spacing: 10) {
                Button { withAnimation(.glass) { model.showSpots.toggle() } } label: {
                    Image(systemName: model.showSpots ? "circle.dashed.inset.filled" : "circle.dashed")
                        .contentTransition(.symbolEffect(.replace))
                        .frame(width: 40, height: 40)
                        .latentGlass(in: Circle(), interactive: true)
                }
                .accessibilityLabel(Text(model.showSpots ? "Hide the spots" : "Show the spots"))
                if let i = model.selectedSpot, model.spots.indices.contains(i) {
                    if ["heal", "clone", "remove"].contains(model.spots[i].mode) {
                        Button { model.newSource() } label: {
                            Label("New source", systemImage: "arrow.triangle.2.circlepath").font(.system(size: 13, weight: .semibold))
                                .padding(.horizontal, 12).frame(height: 40)
                                .latentGlass(in: Capsule(), interactive: true)
                        }
                    }
                    Button(role: .destructive) { withAnimation(.glass) { model.deleteSpot() } } label: {
                        Image(systemName: "trash").frame(width: 40, height: 40).latentGlass(in: Circle(), interactive: true)
                    }
                    .accessibilityLabel(Text("Delete spot"))
                }
                Spacer()
                Menu {
                    Button { model.findDust() } label: { Label("Find sensor dust", systemImage: "sparkle.magnifyingglass") }
                    Button { model.selectedSpot = nil } label: { Label("Deselect", systemImage: "xmark.circle") }
                        .disabled(model.selectedSpot == nil)
                } label: {
                    Image(systemName: "ellipsis").font(.system(size: 16, weight: .semibold)).frame(width: 40, height: 40)
                        .latentGlass(in: Circle(), interactive: true)
                }
                .accessibilityLabel(Text("More remove options"))
            }
            .font(.system(size: 15, weight: .semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 16)
            .padding(.top, 4)
            .opacity(focused ? 0 : 1)
            Text(removeHint)
                .font(.system(size: 12))
                .foregroundStyle(Theme.secondaryText)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 20)
                .padding(.vertical, 8)
                .opacity(focused ? 0 : 1)
        }
        .animation(.glass, value: model.selectedSpot)
    }

    private var removeHint: String {
        if model.selectedSpot != nil {
            return "Drag the spot to move it, or its pin to take from somewhere else. Tap elsewhere for a new spot."
        }
        switch model.spotMode {
        case "heal": return "Brush over a blemish; it's replaced with texture from nearby, blended to match."
        case "clone": return "Brush over something; it's covered with an exact copy from nearby."
        case "fill": return "Brush over something; it's rebuilt from the surroundings, with no single source."
        case "generate":
            return InpaintModel.installed
                ? "Brush over something, generously; the AI model rebuilds what was behind it. Zoom in for small things."
                : "Needs the AI remove model (tap AI remove again to get it). Until then these spots fill from the surroundings."
        default: return "Tap or brush over what to take away. Pinch to zoom in for small things."
        }
    }

    /// A Remove setting: for the next spot, and the selected one.
    private func spotSlider(_ label: String, key: String, value: Double, min: Double, max: Double, scale: Double, decimals: Int) -> some View {
        let c = Control(id: "spot.\(label)", label: label, min: min, max: max, defaultValue: value * scale,
                        step: decimals == 0 ? 1 : 0.1, decimals: decimals, value: value * scale, track: .plain)
        let editing = model.selectedSpot != nil
        return LatentSlider(
            control: c,
            onBegin: { if editing { model.beginSpot(label) } },
            onChange: { model.spotSetting(key, $0 / scale) },
            onEnd: { if editing { model.end() } },
            onReset: {})
            .opacity(focused && model.active != c.id ? 0 : 1)
    }

    // MARK: profiles

    private var profilesPanel: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(model.profileGroups, id: \.self) { g in
                            let on = model.profileGroup == g
                            Button { withAnimation(.glass) { model.profileGroup = g } } label: {
                                Text(g).font(.system(size: 13, weight: on ? .semibold : .regular))
                                    .foregroundStyle(on ? Color.black : Color.white)
                                    .padding(.horizontal, 12).frame(height: 30)
                                    .background(on ? Color.white : Color.white.opacity(0.1), in: Capsule())
                            }
                        }
                    }
                    .padding(.leading, 16)
                }
                Button { importingLUTs = true } label: {
                    Image(systemName: "square.and.arrow.down")
                        .font(.system(size: 15, weight: .semibold))
                        .frame(width: 38, height: 32)
                        .latentGlass(in: Capsule(), interactive: true)
                }
                .foregroundStyle(.white)
                .padding(.trailing, 14)
                .accessibilityLabel(Text("Import LUTs"))
            }
            .padding(.top, 12)
            .opacity(focused ? 0 : 1)
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: 10) {
                    ForEach(model.profiles(in: model.profileGroup)) { p in profileCell(p) }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
            }
            .frame(height: 132)
            .opacity(focused ? 0 : 1)
            LatentSlider(
                control: model.profileAmountControl,
                onBegin: { model.beginProfileAmount() },
                onChange: { model.setProfileAmount($0) },
                onEnd: { model.end() },
                onReset: {
                    model.beginProfileAmount()
                    model.setProfileAmount(100)
                    model.end()
                })
            Text("Import .cube LUTs from Files (single files, folders or .zip); they work like the built-in profiles.")
                .font(.system(size: 12))
                .foregroundStyle(Theme.secondaryText)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 20)
                .padding(.vertical, 6)
                .opacity(focused ? 0 : 1)
        }
        .fileImporter(isPresented: $importingLUTs, allowedContentTypes: [UTType(filenameExtension: "cube") ?? .data, .zip, .folder, .data], allowsMultipleSelection: true) { r in
            if case .success(let urls) = r { model.importLUTs(urls) }
        }
    }

    private func profileCell(_ p: ProfileItem) -> some View {
        let on = p.id == model.profileID
        return Button { model.applyProfile(p) } label: {
            VStack(spacing: 6) {
                ProfileThumb(photo: model.photo.id, profile: p.id)
                    .frame(width: 84, height: 84)
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(on ? Theme.accent : Color.white.opacity(0.12), lineWidth: on ? 2.5 : 1))
                    .overlay(alignment: .topTrailing) {
                        if p.favorite { Image(systemName: "heart.fill").font(.system(size: 10)).foregroundStyle(.white).padding(5).shadow(radius: 2) }
                    }
                    .scaleEffect(on ? 1.04 : 1)
                Text(p.name).font(.system(size: 11, weight: on ? .semibold : .regular)).lineLimit(1).frame(width: 84)
                    .foregroundStyle(on ? Color.white : Theme.secondaryText)
            }
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button { model.favoriteProfile(p) } label: { Label(p.favorite ? "Remove from favorites" : "Add to favorites", systemImage: p.favorite ? "heart.slash" : "heart") }
            if p.imported {
                Button(role: .destructive) { model.deleteProfile(p) } label: { Label("Delete LUT", systemImage: "trash") }
            }
        }
        .accessibilityLabel(Text(p.name))
        .accessibilityAddTraits(on ? .isSelected : [])
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
            StraightenDial(
                angle: model.cropAngle,
                begin: { model.beginAngle() },
                change: { model.setAngle($0) },
                end: { model.end() })
                .frame(height: 62)
                .padding(.top, 8)
            HStack(spacing: 10) {
                roundTool(model.aspectLocked ? "rectangle.portrait.rotate" : "rectangle.portrait.rotate", "Swap orientation") {
                    model.cropCommand("crop.rotateAspect")
                }
                roundTool(model.aspectLocked ? "lock.fill" : "lock.open", model.aspectLocked ? "Unlock aspect" : "Lock aspect") {
                    model.toggleAspectLock()
                }
                .symbolEffect(.bounce, value: model.aspectLocked)
                Spacer()
                roundTool("rotate.right", "Rotate") { model.cropCommand("photo.rotateRight") }
                Menu {
                    Button { model.cropCommand("photo.flipHorizontal") } label: { Label("Flip horizontal", systemImage: "arrow.left.and.right.righttriangle.left.righttriangle.right") }
                    Button { model.cropCommand("photo.flipVertical") } label: { Label("Flip vertical", systemImage: "arrow.up.and.down.righttriangle.up.righttriangle.down") }
                    Button { model.cropCommand("photo.rotateLeft") } label: { Label("Rotate left", systemImage: "rotate.left") }
                    Button { model.cropCommand("crop.autoStraighten") } label: { Label("Auto straighten", systemImage: "level") }
                    Divider()
                    Button(role: .destructive) { model.cropCommand("crop.reset") } label: { Label("Reset crop", systemImage: "arrow.counterclockwise") }
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.system(size: 18, weight: .semibold))
                        .frame(width: 50, height: 50)
                        .latentGlass(in: Circle(), interactive: true)
                }
                .accessibilityLabel(Text("More crop options"))
            }
            .foregroundStyle(.white)
            .latentGlassGroup(spacing: 12)
            .padding(.horizontal, 16)
            .padding(.top, 4)
            .opacity(focused ? 0 : 1)
            cropTabs.opacity(focused ? 0 : 1)
            if model.cropTab == 0 {
                aspectRow
                    .opacity(focused ? 0 : 1)
                    .transition(.opacity.combined(with: .move(edge: .leading)))
            } else {
                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(model.geometryControls) { c in slider(c) }
                    }
                }
                .frame(maxHeight: 170)
                .transition(.opacity.combined(with: .move(edge: .trailing)))
            }
        }
        .padding(.bottom, 8)
        .animation(.glass, value: model.cropTab)
    }

    private var cropTabs: some View {
        HStack(spacing: 28) {
            ForEach(Array(["Aspect", "Geometry"].enumerated()), id: \.offset) { i, name in
                Button { model.cropTab = i } label: {
                    VStack(spacing: 6) {
                        Text(name).font(.system(size: 16, weight: model.cropTab == i ? .semibold : .regular))
                            .foregroundStyle(model.cropTab == i ? Color.white : Theme.secondaryText)
                        Capsule().fill(model.cropTab == i ? Color.white : .clear).frame(width: 40, height: 2.5)
                    }
                }
                .accessibilityAddTraits(model.cropTab == i ? .isSelected : [])
            }
        }
        .padding(.top, 12)
    }

    /// Original, then the ratio menus and the vertical-video shape.
    private var aspectRow: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 4) {
                aspectCell("Original", "photo", on: model.shapeName == "Original") { model.originalShape() }
                Rectangle().fill(Theme.separator).frame(width: 1, height: 40).padding(.horizontal, 6)
                Menu {
                    ForEach(cropRatios) { r in
                        Button { model.chooseShape(r) } label: { Label(r.name, systemImage: r.symbol) }
                    }
                } label: {
                    aspectLabel("Ratios", "rectangle.stack", on: cropRatios.contains { $0.name == model.shapeName })
                }
                Menu {
                    Section("Sizes photo-sharing apps use") {
                        ForEach(socialShapes) { r in
                            Button { model.chooseShape(r) } label: {
                                Label {
                                    Text(r.name)
                                    if let ratio = r.ratio { Text(ratio) }
                                } icon: {
                                    Image(systemName: r.symbol)
                                }
                            }
                        }
                    }
                } label: {
                    aspectLabel("Social posts", "person.2.crop.square.stack", on: socialShapes.contains { $0.name == model.shapeName })
                }
                aspectCell("Vertical video", "play.rectangle", on: model.shapeName == verticalVideo.name) { model.chooseShape(verticalVideo) }
                aspectCell("Free", "crop", on: !model.aspectLocked) {
                    if model.aspectLocked { model.toggleAspectLock() }
                }
            }
            .padding(.horizontal, 12)
        }
        .padding(.top, 10)
    }

    private func aspectCell(_ title: String, _ symbol: String, on: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) { aspectLabel(title, symbol, on: on) }
            .buttonStyle(.plain)
    }

    private func aspectLabel(_ title: String, _ symbol: String, on: Bool) -> some View {
        VStack(spacing: 6) {
            Image(systemName: symbol).font(.system(size: 21)).frame(height: 26)
                .symbolEffect(.bounce, value: on)
            Text(title).font(.system(size: 12)).lineLimit(1)
        }
        .foregroundStyle(on ? Color.white : Theme.secondaryText)
        .frame(minWidth: 74, minHeight: 66)
        .padding(.horizontal, 4)
        .background {
            if on {
                RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color.white.opacity(0.08))
                    .latentGlass(in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(on ? .isSelected : [])
    }

    private func roundTool(_ symbol: String, _ label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 18, weight: .medium))
                .frame(width: 50, height: 50)
                .latentGlass(in: Circle(), interactive: true)
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
                .transition(.asymmetric(
                    insertion: .scale(scale: 0.6, anchor: .top).combined(with: .opacity).combined(with: .offset(y: -20)),
                    removal: .scale(scale: 0.9, anchor: .top).combined(with: .opacity)))
                .task(id: text) {
                    try? await Task.sleep(nanoseconds: 2_400_000_000)
                    withAnimation(.glass) { model.toast = nil }
                }
        }
    }
}

/// The colour grading wheel for the chosen range: hue round the circle (red on the right), how
/// much from the middle outward. Drag the dot; double-tap to clear.
struct GradingWheel: View {
    @ObservedObject var model: EditorModel
    /// Which range this wheel shows (index into `gradingRanges`).
    var rangeIndex: Int? = nil

    var body: some View {
        let i = rangeIndex ?? model.gradingRange
        let range = gradingRanges[i].id
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
            .accessibilityLabel(Text("\(gradingRanges[i].label) wheel"))
            .accessibilityValue(Text("Hue \(Int(hue)), saturation \(Int(sat))"))
        }
    }
}

/// The tools: Auto first, then the adjustment groups; the open one is highlighted and a dot marks
/// the ones that have changed the photo.
struct ToolStrip: View {
    @ObservedObject var model: EditorModel
    @Namespace private var slide

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 2) {
                item("Auto", symbol: "wand.and.stars", selected: false, edited: false) { model.auto() }
                Rectangle().fill(Theme.separator).frame(width: 1, height: 32).padding(.horizontal, 4)
                ForEach(Tool.strip) { t in
                    let on = model.tool == t || (t == .color && (model.tool == .mixer || model.tool == .grading)) || (t == .light && model.tool == .curve)
                    item(t.label, symbol: t.symbol, selected: on, edited: model.edited(t)) {
                        UISelectionFeedbackGenerator().selectionChanged()
                        withAnimation(.glass) { model.tool = t }
                    }
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
                    .symbolEffect(.bounce, value: selected)
                Text(label).font(.system(size: 11))
                Circle().fill(edited ? Theme.secondaryText : .clear).frame(width: 4, height: 4)
            }
            .foregroundStyle(selected ? Color.white : Theme.secondaryText)
            .frame(width: 64, height: 62)
            .background {
                if selected {
                    RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Color.white.opacity(0.08))
                        .latentGlass(in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                        .matchedGeometryEffect(id: "selected", in: slide)
                }
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(label))
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// The editing modes, in a floating glass bar; the highlight slides to the chosen one.
struct ModeBar: View {
    let mode: Mode
    var glassID = "modeBar"
    let namespace: Namespace.ID
    let choose: (Mode) -> Void
    @Namespace private var slide

    init(mode: Mode, glassID: String = "modeBar", namespace: Namespace.ID, choose: @escaping (Mode) -> Void) {
        self.mode = mode
        self.glassID = glassID
        self.namespace = namespace
        self.choose = choose
    }

    var body: some View {
        HStack(spacing: 0) {
            ForEach(Mode.allCases, id: \.self) { m in
                Button { choose(m) } label: {
                    Image(systemName: m.symbol)
                        .font(.system(size: 19))
                        .foregroundStyle(m == mode ? Color.white : Color(white: m.available ? 0.8 : 0.5))
                        .symbolEffect(.bounce, value: m == mode)
                        .frame(width: 52, height: 40)
                        .background {
                            if m == mode {
                                Capsule()
                                    .fill(Theme.accent)
                                    .shadow(color: Theme.accent.opacity(0.45), radius: 8, y: 2)
                                    .matchedGeometryEffect(id: "selected", in: slide)
                            }
                        }
                }
                .frame(maxWidth: .infinity)
                .accessibilityLabel(Text(m.label))
                .accessibilityAddTraits(m == mode ? .isSelected : [])
            }
        }
        .padding(6)
        .latentGlass(in: Capsule(), interactive: true)
        .latentGlassID(glassID, in: namespace)
        .padding(.horizontal, 14)
        .padding(.top, 8)
        .padding(.bottom, 4)
        .animation(.glass, value: mode)
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
    var title = "Presets"
    let cancel: () -> Void
    let done: () -> Void

    var body: some View {
        HStack {
            Button(action: cancel) { Image(systemName: "xmark").font(.system(size: 18, weight: .semibold)).frame(width: 52, height: 40) }
                .accessibilityLabel(Text("Cancel"))
            Spacer()
            Text(title).font(.system(size: 16, weight: .semibold))
            Spacer()
            Button(action: done) { Image(systemName: "checkmark").font(.system(size: 18, weight: .semibold)).frame(width: 52, height: 40) }
                .accessibilityLabel(Text("Done"))
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
            // edge handles
            Path { p in
                for i in 0..<4 {
                    let a = q[i], b = q[(i + 1) % 4]
                    let mid = lerp(a, b, 0.5)
                    p.move(to: towards(mid, a, 11))
                    p.addLine(to: towards(mid, b, 11))
                }
            }
            .stroke(Color.white, style: StrokeStyle(lineWidth: 4, lineCap: .round))
            // a circle for profile photos, which are shown round
            if model.shapeName == "Profile photo" {
                let c = CGPoint(x: q.map(\.x).reduce(0, +) / 4, y: q.map(\.y).reduce(0, +) / 4)
                let rx = hypot(q[1].x - q[0].x, q[1].y - q[0].y) / 2
                let ry = hypot(q[3].x - q[0].x, q[3].y - q[0].y) / 2
                let turn = atan2(q[1].y - q[0].y, q[1].x - q[0].x)
                Path(ellipseIn: CGRect(x: -rx, y: -ry, width: rx * 2, height: ry * 2))
                    .applying(CGAffineTransform(rotationAngle: turn).concatenating(CGAffineTransform(translationX: c.x, y: c.y)))
                    .stroke(Color.white.opacity(0.85), style: StrokeStyle(lineWidth: 1.5, dash: [6, 4]))
                    .allowsHitTesting(false)
            }
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
    var zoom: CGFloat = 1
    @State private var stroke: [CGPoint] = []
    @State private var start: (part: MaskPart, at: CGPoint)?

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
        let m = model.currentPart
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
                    if model.pinching {
                        stroke = []
                        return
                    }
                    guard let m = model.currentPart else { return }
                    switch m.kind {
                    case "object", "colorRange":
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
                        var shape = s.part.shape
                        let c0 = s.part.point("center") ?? CGPoint(x: 0.5, y: 0.5)
                        let cv = toView(c0)
                        let rx = s.part.number("rx", 0.2)
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
                            let ratio = s.part.number("ry", 0.16) / Swift.max(rx, 1e-3)
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
                    let tap = hypot(g.translation.width, g.translation.height) < 10
                    if tap, model.currentPart?.kind == "object" { model.objectPoint(toMask(g.location)) }
                    if tap, model.currentPart?.kind == "colorRange" { model.sampleColor(toMask(g.location)) }
                    if tap, ["luminanceRange", "depthRange"].contains(model.currentPart?.kind ?? "") {
                        let f = fitted
                        model.pickRange(atShown: CGPoint(x: (g.location.x - f.minX) / Swift.max(f.width, 1), y: (g.location.y - f.minY) / Swift.max(f.height, 1)))
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
    private func outline(_ m: MaskPart) -> some View {
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

/// A dictionary that a sheet can be shown for.
struct InfoBox: Identifiable {
    let id = UUID()
    let info: [String: Any]
}

/// What surrounds the photo while editing.
enum EditorBackground: String, CaseIterable, Identifiable {
    case photo, charcoal, gray, neutral, black, white
    var id: String { rawValue }
    var label: String {
        switch self {
        case .photo: return "From photo"
        case .charcoal: return "Charcoal"
        case .gray: return "Dark gray"
        case .neutral: return "Neutral 18% gray"
        case .black: return "Black"
        case .white: return "White"
        }
    }
    var color: Color {
        switch self {
        case .photo: return Color(red: 0.075, green: 0.078, blue: 0.086)
        case .charcoal: return Color(red: 0.075, green: 0.078, blue: 0.086)
        case .gray: return Color(white: 0.17)
        // 18% reflectance is about 46% in sRGB: the grey a photo is judged against
        case .neutral: return Color(white: 0.46)
        case .black: return .black
        case .white: return Color(white: 0.96)
        }
    }
}

/// The straighten dial: ticks along a curve under the crop, turning as you drag sideways; the
/// angle in the middle. It catches at 0°.
struct StraightenDial: View {
    let angle: Double
    let begin: () -> Void
    let change: (Double) -> Void
    let end: () -> Void
    @State private var start: Double?

    var body: some View {
        GeometryReader { geo in
            let perDegree = geo.size.width / 44
            ZStack(alignment: .top) {
                Canvas { ctx, size in
                    let r = size.width * 1.15
                    let center = CGPoint(x: size.width / 2, y: size.height - 4 - r)
                    for d in -45...45 {
                        let theta = (Double(d) - angle) * Double(perDegree) / Double(r)
                        guard abs(theta) < 0.62 else { continue }
                        let out = CGPoint(x: center.x + r * CGFloat(sin(theta)), y: center.y + r * CGFloat(cos(theta)))
                        let inward = CGPoint(x: -CGFloat(sin(theta)), y: -CGFloat(cos(theta)))
                        let major = d % 10 == 0, mid = d % 5 == 0
                        let len: CGFloat = major ? 11 : mid ? 7 : 3
                        var p = Path()
                        p.move(to: out)
                        p.addLine(to: CGPoint(x: out.x + inward.x * len, y: out.y + inward.y * len))
                        let fade = 1 - Swift.min(abs(theta) / 0.62, 1)
                        ctx.stroke(p, with: .color(.white.opacity(0.2 + 0.8 * fade)), style: StrokeStyle(lineWidth: major ? 2 : 1.3, lineCap: .round))
                    }
                    // the marker the angle is read at
                    var m = Path()
                    m.move(to: CGPoint(x: size.width / 2, y: size.height))
                    m.addLine(to: CGPoint(x: size.width / 2, y: size.height - 16))
                    ctx.stroke(m, with: .color(Theme.accent), style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                }
                Text(label)
                    .font(.system(size: 15, weight: .semibold))
                    .monospacedDigit()
                    .contentTransition(.numericText(value: angle))
                    .padding(.top, 2)
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 2)
                    .onChanged { g in
                        if start == nil {
                            start = angle
                            begin()
                        }
                        var a = (start ?? 0) - Double(g.translation.width / perDegree)
                        a = Swift.min(Swift.max(a, -45), 45)
                        if abs(a) < 0.35 {
                            if angle != 0 { UIImpactFeedbackGenerator(style: .light).impactOccurred() }
                            a = 0
                        }
                        change((a * 10).rounded() / 10)
                    }
                    .onEnded { _ in
                        start = nil
                        end()
                    })
            .onTapGesture(count: 2) {
                begin()
                change(0)
                end()
            }
        }
        .accessibilityElement()
        .accessibilityLabel(Text("Straighten"))
        .accessibilityValue(Text(label))
        .accessibilityAdjustableAction { dir in
            begin()
            change(Swift.min(Swift.max(angle + (dir == .increment ? 0.5 : -0.5), -45), 45))
            end()
        }
    }

    private var label: String {
        abs(angle) < 0.05 ? "0\u{00B0}" : String(format: "%.1f\u{00B0}", angle)
    }
}

/// Remove's drawing area: tap or brush to add a spot; drag a spot to move it, or its source pin
/// to take from somewhere else.
struct SpotCanvas: View {
    @ObservedObject var model: EditorModel
    let imageSize: CGSize
    let size: CGSize
    var zoom: CGFloat = 1
    @State private var stroke: [CGPoint] = []
    /// What a drag moves ("target" or "source"), from where, and whether its undo step began.
    @State private var dragging: (kind: String, last: CGPoint, began: Bool)?

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

    private var perLongEdge: CGFloat {
        let f = fitted
        let a = model.photoAspect
        let perWidth = f.width / Swift.max(model.cropRect.width, 1e-6)
        return a >= 1 ? perWidth : perWidth / Swift.max(a, 1e-6)
    }

    private func radius(_ sp: SpotItem) -> CGFloat { Swift.max(CGFloat(sp.size) * perLongEdge, 3) }

    private func sourceCenter(_ sp: SpotItem) -> CGPoint? {
        guard let o = sp.source, sp.mode != "fill" else { return nil }
        let c = sp.center
        return toView(CGPoint(x: c.x + o.x, y: c.y + o.y))
    }

    /// The spot under a point, nearest first.
    private func hit(_ p: CGPoint) -> Int? {
        var best: (Int, CGFloat)?
        for (i, sp) in model.spots.enumerated() {
            let r = Swift.max(radius(sp), 16 / zoom)
            let d = sp.points.map { hypot(toView($0).x - p.x, toView($0).y - p.y) }.min() ?? .infinity
            if d <= r, d < (best?.1 ?? .infinity) { best = (i, d) }
        }
        return best?.0
    }

    var body: some View {
        ZStack {
            if model.showSpots || model.selectedSpot != nil {
                ForEach(Array(model.spots.enumerated()), id: \.offset) { i, sp in
                    if model.showSpots || i == model.selectedSpot { outline(sp, selected: i == model.selectedSpot) }
                }
            }
            if !stroke.isEmpty {
                Path { p in p.addLines(stroke) }
                    .stroke(Color.white.opacity(0.35), style: StrokeStyle(lineWidth: Swift.max(4, CGFloat(model.spotSize) * perLongEdge * 2), lineCap: .round, lineJoin: .round))
            }
        }
        .frame(width: size.width, height: size.height)
        .contentShape(Rectangle())
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { g in
                    if model.pinching {
                        stroke = []
                        return
                    }
                    if dragging == nil && stroke.isEmpty {
                        let p = g.startLocation
                        if let i = model.selectedSpot, model.spots.indices.contains(i), let src = sourceCenter(model.spots[i]),
                           hypot(src.x - p.x, src.y - p.y) < 22 / zoom {
                            dragging = ("source", p, false)
                        } else if let i = hit(p) {
                            if model.selectedSpot != i { model.selectedSpot = i }
                            dragging = ("target", p, false)
                        } else {
                            stroke = [p]
                            return
                        }
                    }
                    if let d = dragging {
                        guard hypot(g.location.x - d.last.x, g.location.y - d.last.y) > 0.5 else { return }
                        if !d.began { model.beginSpot(d.kind == "source" ? "Move Source" : "Move Spot") }
                        let a = toMask(d.last)
                        let b = toMask(g.location)
                        model.updateSpot([d.kind == "source" ? "moveSource" : "move": [Double(b.x - a.x), Double(b.y - a.y)]])
                        dragging = (d.kind, g.location, true)
                    } else if let last = stroke.last, hypot(g.location.x - last.x, g.location.y - last.y) > 3 / zoom {
                        stroke.append(g.location)
                    }
                }
                .onEnded { g in
                    if let d = dragging {
                        dragging = nil
                        if d.began { model.end() }
                        return
                    }
                    let pts = stroke
                    stroke = []
                    guard let first = pts.first, !model.pinching else { return }
                    if hypot(g.translation.width, g.translation.height) < 8 {
                        model.addSpot([toMask(first)])
                    } else {
                        model.addSpot(pts.map(toMask))
                    }
                }
        )
        .accessibilityLabel(Text("Remove drawing area"))
        .accessibilityHint(Text("Tap or brush over what to take away."))
    }

    @ViewBuilder
    private func outline(_ sp: SpotItem, selected: Bool) -> some View {
        let r = radius(sp)
        let line = 1.5 / zoom
        let pts = sp.points.map(toView)
        ZStack {
            shape(pts, r)
                .stroke(Color.white.opacity(selected ? 1 : 0.6), style: StrokeStyle(lineWidth: line, dash: selected ? [] : [4 / zoom, 3 / zoom]))
            if selected, let src = sourceCenter(sp), let tc = pts.isEmpty ? nil : CGPoint(x: pts.map(\.x).reduce(0, +) / CGFloat(pts.count), y: pts.map(\.y).reduce(0, +) / CGFloat(pts.count)) {
                let shifted = pts.map { CGPoint(x: $0.x + src.x - tc.x, y: $0.y + src.y - tc.y) }
                shape(shifted, r)
                    .stroke(Theme.accent, style: StrokeStyle(lineWidth: line, dash: [4 / zoom, 3 / zoom]))
                Path { p in
                    p.move(to: tc)
                    p.addLine(to: src)
                }
                .stroke(Color.white.opacity(0.7), style: StrokeStyle(lineWidth: line, dash: [3 / zoom, 3 / zoom]))
                Circle().fill(Theme.accent).overlay(Circle().strokeBorder(Color.white, lineWidth: 2 / zoom))
                    .frame(width: 16 / zoom, height: 16 / zoom).position(src)
            }
        }
        .shadow(color: .black.opacity(0.5), radius: 1.5 / zoom)
        .allowsHitTesting(false)
    }

    /// A round spot, or a brushed path as wide as the spot.
    private func shape(_ pts: [CGPoint], _ r: CGFloat) -> Path {
        if pts.count == 1, let c = pts.first {
            return Path(ellipseIn: CGRect(x: c.x - r, y: c.y - r, width: r * 2, height: r * 2))
        }
        var p = Path()
        p.addLines(pts)
        return p.strokedPath(StrokeStyle(lineWidth: r * 2, lineCap: .round, lineJoin: .round))
    }
}

/// A profile's preview on the photo.
struct ProfileThumb: View {
    let photo: UInt64
    let profile: String
    @State private var image: CGImage?

    var body: some View {
        ZStack {
            Color(white: 0.12)
            if let image {
                Image(decorative: image, scale: 1).resizable().scaledToFill().transition(.opacity)
            } else {
                Shimmer()
            }
        }
        .task(id: profile) {
            image = Thumbnails.shared.cachedProfile(photo, profile: profile)
            if image == nil {
                let img = await Thumbnails.shared.profile(photo, profile: profile, longEdge: 200)
                withAnimation(.easeOut(duration: 0.2)) { image = img }
            }
        }
    }
}

/// Two fingers on the photo: how far they've spread (scale), where they are now and where they
/// began, so the photo zooms around them and moves with them. A UIKit pinch, which reports where
/// the fingers are as they move.
struct PinchPan: UIGestureRecognizerRepresentable {
    let began: () -> Void
    let changed: (_ scale: CGFloat, _ now: CGPoint, _ start: CGPoint) -> Void
    let ended: () -> Void

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        var start: CGPoint = .zero

        // drawing, dragging sliders and the photo's own gestures carry on beside the pinch
        func gestureRecognizer(_ g: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool { true }
    }

    func makeCoordinator(converter: CoordinateSpaceConverter) -> Coordinator { Coordinator() }

    func makeUIGestureRecognizer(context: Context) -> UIPinchGestureRecognizer {
        let r = UIPinchGestureRecognizer()
        r.delegate = context.coordinator
        return r
    }

    func handleUIGestureRecognizerAction(_ recognizer: UIPinchGestureRecognizer, context: Context) {
        let at = context.converter.localLocation
        switch recognizer.state {
        case .began:
            context.coordinator.start = at
            began()
            changed(recognizer.scale, at, at)
        case .changed:
            // a finger lifted mid-pinch jumps the centre: follow only while both are down
            if recognizer.numberOfTouches >= 2 { changed(recognizer.scale, at, context.coordinator.start) }
        default:
            ended()
        }
    }
}
