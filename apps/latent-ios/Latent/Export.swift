import Photos
import SwiftUI
import UIKit
import UniformTypeIdentifiers

// MARK: settings

/// How photos are exported: kept between launches, shared by every way out (Photos, Files, share).
struct ExportSettings: Codable, Equatable {
    var format = "jpeg"
    /// Long edge in pixels; 0 is the photo's full size.
    var longEdge = 0
    var quality = 90
    var hdr = true
    var watermark = false
    var watermarkText = ""
    var metadata = "all"
    var removeLocation = false
    var colorSpace = "srgb"

    static let formats: [(id: String, label: String)] = [
        ("jpeg", "JPG"), ("png", "PNG"), ("tiff", "TIFF"), ("avif", "AVIF"), ("jxl", "JPEG XL"),
    ]
    static let sizes = [0, 4096, 3072, 2048, 1600, 1080]
    static let qualities = [100, 95, 90, 80, 70, 60, 50]
    static let metadataChoices: [(id: String, label: String)] = [
        ("all", "Everything"), ("allExceptCamera", "All but camera info"), ("copyright", "Copyright only"), ("none", "None"),
    ]
    static let colorSpaces: [(id: String, label: String)] = [
        ("srgb", "sRGB"), ("displayP3", "Display P3"), ("adobeRgb", "Adobe RGB"), ("proPhoto", "ProPhoto RGB"), ("rec2020", "Rec. 2020"),
    ]

    var formatLabel: String { Self.formats.first { $0.id == format }?.label ?? format.uppercased() }
    var lossy: Bool { ["jpeg", "avif", "jxl"].contains(format) }
    static func sizeLabel(_ edge: Int) -> String { edge == 0 ? "Full size" : "\(edge) px long edge" }

    /// One line for the share screen: "JPG · Full size · 90%".
    var summary: String {
        var parts = [formatLabel, longEdge == 0 ? "Full size" : "\(longEdge) px"]
        if lossy { parts.append("\(quality)%") }
        if watermark && !watermarkText.isEmpty { parts.append("Watermark") }
        return parts.joined(separator: " \u{00B7} ")
    }

    /// The engine's export options.
    var options: [String: Any] {
        var o: [String: Any] = [
            "format": format, "quality": quality, "hdr": hdr, "metadata": metadata,
            "removeLocation": removeLocation, "colorSpace": colorSpace,
        ]
        if longEdge > 0 { o["resize"] = ["mode": "longEdge", "value": longEdge, "dontEnlarge": true] }
        let text = watermarkText.trimmingCharacters(in: .whitespaces)
        if watermark && !text.isEmpty {
            o["watermark"] = ["text": text, "size": 0.035, "opacity": 0.85, "anchor": "bottomRight", "insetX": 0.03, "insetY": 0.03, "shadow": true]
        }
        return o
    }
}

@MainActor
final class ExportPrefs: ObservableObject {
    static let shared = ExportPrefs()
    @Published var settings: ExportSettings { didSet { save() } }

    private init() {
        let data = UserDefaults.standard.data(forKey: "exportSettings")
        settings = data.flatMap { try? JSONDecoder().decode(ExportSettings.self, from: $0) } ?? ExportSettings()
    }

    private func save() {
        if let data = try? JSONEncoder().encode(settings) { UserDefaults.standard.set(data, forKey: "exportSettings") }
    }
}

// MARK: doing it

struct ExportedFile: Sendable {
    let url: URL
    let name: String
    let data: Data
}

enum Exporter {
    /// Export each photo into a fresh temporary folder, one after another. `progress` hears the
    /// number about to start (1-based).
    static func run(_ ids: [UInt64], settings: ExportSettings, progress: @MainActor @escaping (Int) -> Void = { _ in }) async throws -> [ExportedFile] {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("Export-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let options = settings.options
        var out: [ExportedFile] = []
        var used = Set<String>()
        for (i, id) in ids.enumerated() {
            await progress(i + 1)
            let (name, data) = try await Task.detached(priority: .userInitiated) {
                try Engine.shared.export(id, options: options)
            }.value
            var unique = name
            var n = 2
            while used.contains(unique.lowercased()) {
                let u = URL(fileURLWithPath: name)
                unique = "\(u.deletingPathExtension().lastPathComponent)-\(n).\(u.pathExtension)"
                n += 1
            }
            used.insert(unique.lowercased())
            let url = folder.appendingPathComponent(unique)
            try data.write(to: url)
            out.append(ExportedFile(url: url, name: unique, data: data))
        }
        return out
    }

    /// Add the files to the Photos library (asks for permission the first time).
    static func saveToPhotos(_ files: [ExportedFile]) async throws {
        let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
        guard status == .authorized || status == .limited else {
            throw EngineError(message: "Latent isn't allowed to add photos. Turn it on in Settings › Privacy & Security › Photos › Latent.")
        }
        try await PHPhotoLibrary.shared().performChanges {
            for f in files {
                let request = PHAssetCreationRequest.forAsset()
                let o = PHAssetResourceCreationOptions()
                o.originalFilename = f.name
                request.addResource(with: .photo, fileURL: f.url, options: o)
            }
        }
    }

    /// Put the files on the clipboard as images.
    static func copy(_ files: [ExportedFile]) {
        UIPasteboard.general.items = files.map { f -> [String: Any] in
            let type = UTType(filenameExtension: f.url.pathExtension) ?? .image
            return [type.identifier: f.data]
        }
    }
}

// MARK: the share screen

/// What a finished export is for.
private enum Destination {
    case photos, files, share, copy
}

private struct Files: Identifiable {
    let id = UUID()
    let urls: [URL]
}

/// The share screen: the photos to send along a strip (the open one chosen), the ways to send
/// them, and the export settings.
struct ShareView: View {
    let photos: [Photo]
    let current: UInt64

    @ObservedObject private var prefs = ExportPrefs.shared
    @Environment(\.dismiss) private var dismiss
    @State private var chosen: Set<UInt64>
    @State private var working: String?
    @State private var notice: String?
    @State private var sharing: Files?
    @State private var filing: Files?
    @State private var options: Destination?
    @State private var previews: [UInt64: CGImage] = [:]

    init(photos: [Photo], current: UInt64) {
        self.photos = photos
        self.current = current
        _chosen = State(initialValue: [current])
    }

    private var ordered: [UInt64] { photos.map(\.id).filter { chosen.contains($0) } }
    private var allChosen: Bool { !photos.isEmpty && chosen.count == photos.count }

    var body: some View {
        VStack(spacing: 0) {
            header
            strip
            Divider().overlay(Theme.separator).padding(.horizontal, 16)
            actions
            Divider().overlay(Theme.separator).padding(.horizontal, 16)
            rows
            Spacer(minLength: 0)
        }
        .background(Theme.surface.ignoresSafeArea())
        .overlay { if let working { progress(working) } }
        .overlay(alignment: .bottom) {
            if let notice {
                Text(notice)
                    .font(.system(size: 15, weight: .semibold))
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 18)
                    .padding(.vertical, 12)
                    .latentGlass(in: Capsule())
                    .padding(.bottom, 24)
                    .padding(.horizontal, 24)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                    .accessibilityAddTraits(.updatesFrequently)
            }
        }
        .animation(.easeInOut(duration: 0.2), value: notice)
        .animation(.easeInOut(duration: 0.2), value: working)
        .sheet(item: $sharing) { f in ActivityView(items: f.urls).ignoresSafeArea() }
        .sheet(item: $filing) { f in FilesExporter(urls: f.urls).ignoresSafeArea() }
        .sheet(isPresented: Binding(get: { options != nil }, set: { if !$0 { options = nil } })) {
            ExportOptionsView(settings: $prefs.settings, count: max(chosen.count, 1)) {
                let d = options ?? .share
                options = nil
                Task {
                    // let the settings sheet close before the next one opens
                    try? await Task.sleep(nanoseconds: 450_000_000)
                    send(to: d)
                }
            }
        }
        .preferredColorScheme(.dark)
    }

    private var header: some View {
        HStack {
            Button { dismiss() } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 17, weight: .semibold))
                    .frame(width: 44, height: 44)
                    .latentGlass(in: Circle(), interactive: true)
            }
            .accessibilityLabel(Text("Close"))
            Spacer()
            Text(chosen.count <= 1 ? "Share photo" : "Share \(chosen.count) photos")
                .font(.system(size: 18, weight: .semibold))
                .contentTransition(.numericText())
            Spacer()
            Button {
                withAnimation(.snappy) { chosen = allChosen ? [current] : Set(photos.map(\.id)) }
            } label: {
                Text(allChosen ? "Just this" : "Select all")
                    .font(.system(size: 15, weight: .medium))
                    .padding(.horizontal, 14)
                    .frame(height: 36)
                    .overlay(Capsule().strokeBorder(Color.white.opacity(0.22)))
            }
            .disabled(photos.count < 2)
            .opacity(photos.count < 2 ? 0 : 1)
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 16)
        .padding(.top, 14)
    }

    private var strip: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(alignment: .top, spacing: 18) {
                    ForEach(photos) { photo in
                        cell(photo).id(photo.id)
                    }
                }
                .padding(.horizontal, 40)
                .frame(maxHeight: .infinity)
            }
            .onAppear { proxy.scrollTo(current, anchor: .center) }
        }
        .frame(maxHeight: 400)
        .padding(.vertical, 12)
    }

    private func cell(_ photo: Photo) -> some View {
        let on = chosen.contains(photo.id)
        return Button {
            UISelectionFeedbackGenerator().selectionChanged()
            withAnimation(.snappy(duration: 0.2)) {
                if on { chosen.remove(photo.id) } else { chosen.insert(photo.id) }
            }
        } label: {
            VStack(spacing: 14) {
                Group {
                    if let img = previews[photo.id] ?? Thumbnails.shared.cached(photo.id) {
                        Image(decorative: img, scale: 1).resizable().interpolation(.high).scaledToFit()
                    } else {
                        Color.white.opacity(0.06).aspectRatio(0.75, contentMode: .fit)
                    }
                }
                .frame(maxWidth: 260, maxHeight: 300)
                .padding(4)
                .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(on ? Theme.accent : .clear, lineWidth: 3))
                .scaleEffect(on ? 1 : 0.94)
                .shadow(color: .black.opacity(0.4), radius: 12, y: 6)
                Image(systemName: on ? "checkmark.square.fill" : "square")
                    .font(.system(size: 26, weight: .regular))
                    .symbolRenderingMode(.palette)
                    .foregroundStyle(on ? Color.white : Theme.secondaryText, on ? Theme.accent : .clear)
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(photo.fileName))
        .accessibilityAddTraits(on ? [.isSelected, .isButton] : .isButton)
        .task(id: photo.id) {
            guard previews[photo.id] == nil else { return }
            let id = photo.id
            let img = await Task.detached(priority: .userInitiated) { Engine.shared.thumbnail(id, longEdge: 900) }.value
            if let img { previews[id] = img }
        }
    }

    private var actions: some View {
        HStack(alignment: .top, spacing: 0) {
            circle("Share", "square.and.arrow.up", tint: Theme.accent) { send(to: .share) }
            circle("Export as\u{2026}", "ellipsis") { options = .share }
            circle("Copy", "doc.on.doc") { send(to: .copy) }
        }
        .padding(.vertical, 16)
        .disabled(chosen.isEmpty || working != nil)
    }

    private func circle(_ title: String, _ icon: String, tint: Color = .white, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 10) {
                Image(systemName: icon)
                    .font(.system(size: 22, weight: .medium))
                    .foregroundStyle(tint)
                    .frame(width: 64, height: 64)
                    .background(Circle().fill(Color.black.opacity(0.55)))
                    .overlay(Circle().strokeBorder(Color.white.opacity(0.1)))
                Text(title).font(.system(size: 14)).foregroundStyle(.white)
            }
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(.plain)
    }

    private var rows: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                row("Save to Photos", prefs.settings.summary, "square.and.arrow.down") { send(to: .photos) }
                Button { options = .photos } label: {
                    Image(systemName: "gearshape.fill").font(.system(size: 20)).frame(width: 52, height: 52)
                }
                .foregroundStyle(.white)
                .accessibilityLabel(Text("Export settings"))
            }
            row("Save to Files", "On this iPhone, iCloud Drive or another app", "folder") { send(to: .files) }
            row("Add watermark and share\u{2026}", prefs.settings.watermark ? "\u{201C}\(prefs.settings.watermarkText)\u{201D}" : nil, "signature") {
                prefs.settings.watermark = true
                options = .share
            }
        }
        .padding(.horizontal, 8)
        .padding(.top, 8)
        .disabled(chosen.isEmpty || working != nil)
    }

    private func row(_ title: String, _ detail: String?, _ icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 18) {
                Image(systemName: icon).font(.system(size: 21)).frame(width: 30)
                VStack(alignment: .leading, spacing: 3) {
                    Text(title).font(.system(size: 18))
                    if let detail, !detail.isEmpty {
                        Text(detail).font(.system(size: 13)).foregroundStyle(Theme.secondaryText).lineLimit(1)
                    }
                }
                Spacer(minLength: 0)
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 12)
            .frame(minHeight: 64)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func progress(_ text: String) -> some View {
        ZStack {
            Color.black.opacity(0.35).ignoresSafeArea()
            VStack(spacing: 14) {
                ProgressView().controlSize(.large).tint(.white)
                Text(text).font(.system(size: 15, weight: .semibold)).monospacedDigit()
            }
            .padding(28)
            .latentGlass(in: RoundedRectangle(cornerRadius: 24, style: .continuous))
        }
        .accessibilityElement(children: .combine)
    }

    private func send(to destination: Destination) {
        let ids = ordered
        guard !ids.isEmpty, working == nil else { return }
        let settings = prefs.settings
        let total = ids.count
        working = total == 1 ? "Exporting\u{2026}" : "Exporting 1 of \(total)\u{2026}"
        Task {
            do {
                let files = try await Exporter.run(ids, settings: settings) { n in
                    if total > 1 { working = "Exporting \(n) of \(total)\u{2026}" }
                }
                switch destination {
                case .photos:
                    working = "Saving\u{2026}"
                    try await Exporter.saveToPhotos(files)
                    working = nil
                    UINotificationFeedbackGenerator().notificationOccurred(.success)
                    show(total == 1 ? "Saved to Photos" : "Saved \(total) photos to Photos")
                case .files:
                    working = nil
                    filing = Files(urls: files.map(\.url))
                case .share:
                    working = nil
                    sharing = Files(urls: files.map(\.url))
                case .copy:
                    Exporter.copy(files)
                    working = nil
                    UINotificationFeedbackGenerator().notificationOccurred(.success)
                    show(total == 1 ? "Copied" : "Copied \(total) photos")
                }
            } catch {
                working = nil
                UINotificationFeedbackGenerator().notificationOccurred(.error)
                show(error.localizedDescription)
            }
        }
    }

    private func show(_ text: String) {
        notice = text
        Task {
            try? await Task.sleep(nanoseconds: 2_400_000_000)
            if notice == text { notice = nil }
        }
    }
}

// MARK: export settings

/// The export settings: file type, size, quality, HDR, watermark, and more behind a link.
struct ExportOptionsView: View {
    @Binding var settings: ExportSettings
    let count: Int
    let confirm: () -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    field("File type", value: settings.formatLabel) {
                        Picker("File type", selection: $settings.format) {
                            ForEach(ExportSettings.formats, id: \.id) { Text($0.label).tag($0.id) }
                        }
                    }
                    field("Dimensions", value: ExportSettings.sizeLabel(settings.longEdge)) {
                        Picker("Dimensions", selection: $settings.longEdge) {
                            ForEach(ExportSettings.sizes, id: \.self) { Text(ExportSettings.sizeLabel($0)).tag($0) }
                        }
                    }
                    if settings.lossy {
                        field("Quality", value: "\(settings.quality)%") {
                            Picker("Quality", selection: $settings.quality) {
                                ForEach(ExportSettings.qualities, id: \.self) { Text("\($0)%").tag($0) }
                            }
                        }
                        .transition(.opacity.combined(with: .move(edge: .top)))
                    }
                    separator
                    toggle("HDR", isOn: $settings.hdr, note: hdrNote)
                    separator
                    toggle("Watermark", isOn: $settings.watermark, note: settings.watermark ? nil : "Your name or a short line in the corner of each photo.")
                    if settings.watermark {
                        TextField("Watermark text", text: $settings.watermarkText, prompt: Text("\u{00A9} Your name").foregroundColor(Theme.secondaryText))
                            .textInputAutocapitalization(.words)
                            .padding(.horizontal, 16)
                            .frame(height: 50)
                            .background(fieldBackground)
                            .transition(.opacity)
                    }
                    separator
                    NavigationLink {
                        MoreExportOptions(settings: $settings)
                    } label: {
                        HStack {
                            Text("More options").font(.system(size: 18))
                            Spacer()
                            Image(systemName: "chevron.right").foregroundStyle(Theme.secondaryText)
                        }
                        .foregroundStyle(.white)
                        .frame(height: 44)
                        .contentShape(Rectangle())
                    }
                    separator
                }
                .padding(20)
                .animation(.easeInOut(duration: 0.2), value: settings)
            }
            .background(Theme.surface.ignoresSafeArea())
            .navigationTitle(count == 1 ? "Export as\u{2026}" : "Export as\u{2026} (\(count))")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button { dismiss() } label: { Image(systemName: "xmark") }
                        .accessibilityLabel(Text("Cancel"))
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(action: confirm) {
                        Image(systemName: "checkmark").fontWeight(.semibold)
                    }
                    .tint(Theme.accent)
                    .accessibilityLabel(Text("Export"))
                }
            }
        }
        .preferredColorScheme(.dark)
    }

    private var hdrNote: String {
        switch settings.format {
        case "jpeg": return "For photos edited in HDR: a JPG with a gain map, so the bright highlights show on HDR screens and it still looks right everywhere else."
        case "tiff": return "For photos edited in HDR: a 32-bit floating-point TIFF that keeps the highlights above white."
        default: return "For photos edited in HDR: keeps the bright highlights (Rec. 2020 PQ). Photos edited in SDR export as SDR."
        }
    }

    private var separator: some View { Rectangle().fill(Theme.separator).frame(height: 1) }

    private var fieldBackground: some View {
        RoundedRectangle(cornerRadius: 12, style: .continuous)
            .fill(Color.white.opacity(0.05))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Color.white.opacity(0.14)))
    }

    private func field<Content: View>(_ title: String, value: String, @ViewBuilder menu: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.system(size: 15)).foregroundStyle(Theme.secondaryText)
            Menu {
                menu()
            } label: {
                HStack {
                    Text(value).foregroundStyle(.white)
                    Spacer()
                    Image(systemName: "chevron.down").font(.system(size: 14, weight: .semibold)).foregroundStyle(Theme.secondaryText)
                }
                .font(.system(size: 17))
                .padding(.horizontal, 16)
                .frame(height: 52)
                .background(fieldBackground)
                .contentShape(Rectangle())
            }
            .accessibilityLabel(Text("\(title): \(value)"))
        }
    }

    private func toggle(_ title: String, isOn: Binding<Bool>, note: String?) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Toggle(isOn: isOn) { Text(title).font(.system(size: 18)) }
                .tint(Theme.accent)
            if let note {
                Text(note).font(.system(size: 14)).foregroundStyle(Theme.secondaryText).fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

/// Metadata, location and colour space.
private struct MoreExportOptions: View {
    @Binding var settings: ExportSettings

    var body: some View {
        Form {
            Section {
                Picker("Include", selection: $settings.metadata) {
                    ForEach(ExportSettings.metadataChoices, id: \.id) { Text($0.label).tag($0.id) }
                }
                Toggle("Remove location", isOn: $settings.removeLocation).tint(Theme.accent)
            } header: {
                Text("Metadata")
            } footer: {
                Text("Camera details, capture settings, title, caption, keywords and copyright written into the file.")
            }
            Section {
                Picker("Colour space", selection: $settings.colorSpace) {
                    ForEach(ExportSettings.colorSpaces, id: \.id) { Text($0.label).tag($0.id) }
                }
            } header: {
                Text("Colour")
            } footer: {
                Text("sRGB looks right everywhere. Display P3 keeps the wider colours iPhone screens show.")
            }
        }
        .scrollContentBackground(.hidden)
        .background(Theme.surface.ignoresSafeArea())
        .navigationTitle("More options")
        .navigationBarTitleDisplayMode(.inline)
    }
}

// MARK: system sheets

/// The system share sheet.
struct ActivityView: UIViewControllerRepresentable {
    let items: [Any]
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }
    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}

/// The Files "save to" picker, copying the files.
struct FilesExporter: UIViewControllerRepresentable {
    let urls: [URL]
    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        UIDocumentPickerViewController(forExporting: urls, asCopy: true)
    }
    func updateUIViewController(_ controller: UIDocumentPickerViewController, context: Context) {}
}

// MARK: info

/// A photo's file and camera details.
struct PhotoInfoView: View {
    let info: [String: Any]
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section("File") {
                    line("Name", info["file_name"] as? String)
                    line("Format", (info["format"] as? String)?.uppercased())
                    line("Dimensions", dimensions)
                    line("Size", size)
                    line("Captured", captured)
                }
                Section("Camera") {
                    line("Camera", meta["camera"] as? String)
                    line("Lens", meta["lens"] as? String)
                    line("Exposure", exposure)
                }
                if let place = place {
                    Section("Location") { line("Place", place) }
                }
            }
            .scrollContentBackground(.hidden)
            .background(Theme.surface.ignoresSafeArea())
            .navigationTitle("Info")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
        }
        .preferredColorScheme(.dark)
    }

    private var meta: [String: Any] { info["meta"] as? [String: Any] ?? [:] }

    private var dimensions: String? {
        guard let w = (info["width"] as? NSNumber)?.intValue, let h = (info["height"] as? NSNumber)?.intValue, w > 0, h > 0 else { return nil }
        let mp = Double(w * h) / 1_000_000
        return "\(w) \u{00D7} \(h)  (\(String(format: "%.1f", mp)) MP)"
    }

    private var size: String? {
        guard let b = (info["file_size"] as? NSNumber)?.int64Value, b > 0 else { return nil }
        return ByteCountFormatter.string(fromByteCount: b, countStyle: .file)
    }

    private var captured: String? {
        guard let s = info["captured"] as? String, !s.isEmpty else { return nil }
        let iso = ISO8601DateFormatter()
        for options: ISO8601DateFormatter.Options in [[.withInternetDateTime], [.withFullDate, .withTime, .withColonSeparatorInTime, .withDashSeparatorInDate]] {
            iso.formatOptions = options
            if let d = iso.date(from: s) { return d.formatted(date: .long, time: .shortened) }
        }
        return s
    }

    private var exposure: String? {
        var parts: [String] = []
        if let f = (meta["focal_mm"] as? NSNumber)?.doubleValue { parts.append("\(Int(f.rounded())) mm") }
        if let a = (meta["aperture"] as? NSNumber)?.doubleValue { parts.append(String(format: "f/%.1f", a)) }
        if let s = meta["shutter"] as? String, !s.isEmpty { parts.append(s.hasSuffix("s") ? s : "\(s) s") }
        if let iso = (meta["iso"] as? NSNumber)?.intValue { parts.append("ISO \(iso)") }
        return parts.isEmpty ? nil : parts.joined(separator: "  ")
    }

    private var place: String? {
        let parts = ["location", "city", "state", "country"].compactMap { meta[$0] as? String }.filter { !$0.isEmpty }
        return parts.isEmpty ? nil : parts.joined(separator: ", ")
    }

    @ViewBuilder
    private func line(_ label: String, _ value: String?) -> some View {
        if let value, !value.isEmpty {
            LabeledContent(label) {
                Text(value).multilineTextAlignment(.trailing).textSelection(.enabled)
            }
        }
    }
}
