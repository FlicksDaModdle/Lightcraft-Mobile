import SwiftUI

/// The editor: histogram, the photo, the tool's sliders, the tools, and the editing modes.
struct EditorView: View {
    @StateObject private var model: EditorModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.verticalSizeClass) private var verticalSize
    @State private var chromeHidden = false
    @State private var showingOriginal = false
    @State private var hold: Task<Void, Never>?

    init(photo: Photo) {
        _model = StateObject(wrappedValue: EditorModel(photo: photo))
    }

    /// Sideways, or after a tap on the photo, the photo is shown alone.
    private var chrome: Bool { !chromeHidden && verticalSize != .compact }

    var body: some View {
        VStack(spacing: 0) {
            if chrome {
                topBar
                HistogramView(bins: model.histogram)
                    .frame(height: 70)
                    .padding(.horizontal, 24)
                    .padding(.top, 4)
                    .padding(.bottom, 10)
            }
            photoArea
            if chrome {
                VStack(spacing: 0) {
                    panel
                    ToolStrip(model: model)
                    Rectangle().fill(Theme.separator).frame(height: 0.5)
                    ModeBar { model.toast = "\($0) is not in Latent yet. It's coming in a later build." }
                }
                .background(Theme.surface)
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .background(Theme.photoBackground.ignoresSafeArea())
        .overlay(alignment: .top) { toast }
        .statusBarHidden(!chrome)
        .animation(.easeInOut(duration: 0.22), value: chrome)
        .preferredColorScheme(.dark)
        .onAppear { model.open() }
        .onDisappear { Thumbnails.shared.forget(model.photo.id) }
    }

    // MARK: parts

    private var topBar: some View {
        HStack(spacing: 22) {
            Button { dismiss() } label: { Image(systemName: "chevron.left").font(.system(size: 19, weight: .semibold)) }
                .accessibilityLabel(Text("Back"))
            Spacer()
            Button { model.undo() } label: { Image(systemName: "arrow.uturn.backward") }
                .disabled(!model.canUndo)
                .accessibilityLabel(Text("Undo"))
            Button { model.redo() } label: { Image(systemName: "arrow.uturn.forward") }
                .disabled(!model.canRedo)
                .accessibilityLabel(Text("Redo"))
            Menu {
                Button { model.auto() } label: { Label("Auto settings", systemImage: "wand.and.stars") }
                Button(role: .destructive) { model.resetAll() } label: { Label("Reset all edits", systemImage: "arrow.counterclockwise") }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .accessibilityLabel(Text("More"))
        }
        .font(.system(size: 19))
        .foregroundStyle(.white)
        .padding(.horizontal, 20)
        .frame(height: 44)
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
                if showingOriginal {
                    Text("Original")
                        .font(.system(size: 12, weight: .semibold))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(.ultraThinMaterial, in: Capsule())
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

    private var panel: some View {
        VStack(spacing: 0) {
            if model.tool == .color { colorHeader }
            if !model.tool.tabs.isEmpty { tabs }
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(model.visible) { c in
                        LatentSlider(
                            control: c,
                            onBegin: { model.begin(c) },
                            onChange: { model.set(c, $0) },
                            onEnd: { model.end() },
                            onReset: { model.reset(c) })
                    }
                }
                .padding(.vertical, 6)
            }
            .scrollIndicators(.visible)
        }
        .frame(height: 268)
    }

    private var tabs: some View {
        HStack(spacing: 28) {
            ForEach(Array(model.tool.tabs.enumerated()), id: \.offset) { i, tab in
                Button { model.tab = i } label: {
                    VStack(spacing: 6) {
                        Text(tab.name)
                            .font(.system(size: 15, weight: model.tab == i ? .medium : .regular))
                            .foregroundStyle(model.tab == i ? Color.white : Theme.secondaryText)
                        Capsule().fill(model.tab == i ? Color.white : .clear).frame(height: 2)
                    }
                    .fixedSize()
                }
                .accessibilityAddTraits(model.tab == i ? .isSelected : [])
            }
        }
        .padding(.top, 12)
        .padding(.bottom, 2)
    }

    private var colorHeader: some View {
        HStack(spacing: 12) {
            Toggle(isOn: Binding(get: { model.bw }, set: { model.setBW($0) })) {
                Text("B&W").font(.system(size: 15))
            }
            .toggleStyle(.switch)
            .tint(Theme.accent)
            .fixedSize()
            Spacer()
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
        }
        .padding(.horizontal, 20)
        .padding(.top, 12)
    }

    @ViewBuilder private var toast: some View {
        if let text = model.toast {
            Text(text)
                .font(.system(size: 14, weight: .medium))
                .multilineTextAlignment(.center)
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .background(.regularMaterial, in: Capsule())
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

/// The tools: Auto first, then the adjustment groups; the open one is highlighted and a dot marks
/// the ones that have changed the photo.
struct ToolStrip: View {
    @ObservedObject var model: EditorModel

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 2) {
                item("Auto", symbol: "wand.and.stars", selected: false, edited: false) { model.auto() }
                Rectangle().fill(Theme.separator).frame(width: 1, height: 32).padding(.horizontal, 4)
                ForEach(Tool.allCases) { t in
                    item(t.label, symbol: t.symbol, selected: model.tool == t, edited: model.edited(t)) { model.tool = t }
                }
            }
            .padding(.horizontal, 10)
        }
        .frame(height: 70)
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
            .background(selected ? Theme.selectedCell : .clear, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(label))
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// The editing modes. Only adjusting is in this build; the others say so.
struct ModeBar: View {
    let unavailable: (String) -> Void
    private let modes: [(name: String, symbol: String)] = [
        ("Quick actions", "sparkles"), ("Presets", "circle.hexagongrid"), ("Crop", "crop.rotate"),
        ("Edit", "slider.horizontal.3"), ("Masks", "circle.dashed.inset.filled"), ("Remove", "bandage"),
    ]

    var body: some View {
        HStack {
            ForEach(modes, id: \.name) { m in
                Button {
                    if m.name != "Edit" { unavailable(m.name) }
                } label: {
                    Image(systemName: m.symbol)
                        .font(.system(size: 20))
                        .foregroundStyle(m.name == "Edit" ? Color.white : Theme.secondaryText)
                        .frame(width: 50, height: 40)
                        .background(m.name == "Edit" ? Theme.accent : .clear, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                }
                .frame(maxWidth: .infinity)
                .accessibilityLabel(Text(m.name))
            }
        }
        .padding(.horizontal, 8)
        .frame(height: 58)
    }
}
