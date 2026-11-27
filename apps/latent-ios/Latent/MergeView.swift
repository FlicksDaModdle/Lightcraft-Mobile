import SwiftUI

/// Photo Merge's options and progress, for photos chosen in the Library.
struct MergeView: View {
    let ids: [UInt64]
    let finished: (UInt64?) -> Void
    @Environment(\.dismiss) private var dismiss

    enum Kind: String, CaseIterable, Identifiable {
        case hdr = "merge.hdr", panorama = "merge.panorama", hdrPanorama = "merge.hdrPanorama"
        var id: String { rawValue }
        var title: String {
            switch self {
            case .hdr: "HDR"
            case .panorama: "Panorama"
            case .hdrPanorama: "HDR panorama"
            }
        }
        var about: String {
            switch self {
            case .hdr: "Bracketed shots of one scene, at different exposures, become one photo with detail in both the shadows and the highlights."
            case .panorama: "Overlapping shots, taken turning on the spot, are stitched into one wide photo."
            case .hdrPanorama: "Bracketed sets for each part of a panorama: each set is merged to HDR, then the sets are stitched."
            }
        }
        var hasHDR: Bool { self != .panorama }
        var hasPano: Bool { self != .hdr }
    }

    @State private var kind: Kind = .hdr
    @State private var align = true
    @State private var deghost = "none"
    @State private var projection = "auto"
    @State private var boundaryWarp = 0.0
    @State private var autoCrop = true
    @State private var fillEdges = false
    @State private var autoSettings = true
    @State private var stack = false
    @State private var progress: Double?
    @State private var stage = ""
    @State private var error: String?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("Merge", selection: $kind) {
                        ForEach(Kind.allCases) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    Text(kind.about).font(.footnote).foregroundStyle(.secondary)
                } footer: {
                    Text("\(ids.count) photos. The merged photo is a new raw (DNG) file added to your library; the originals stay as they are.")
                }
                if kind.hasHDR {
                    Section("HDR") {
                        Toggle("Line up the shots", isOn: $align)
                        Picker("Remove ghosts", selection: $deghost) {
                            Text("Off").tag("none")
                            Text("Low").tag("low")
                            Text("Medium").tag("medium")
                            Text("High").tag("high")
                        }
                    }
                }
                if kind.hasPano {
                    Section("Panorama") {
                        Picker("Projection", selection: $projection) {
                            Text("Automatic").tag("auto")
                            Text("Spherical").tag("spherical")
                            Text("Cylindrical").tag("cylindrical")
                            Text("Perspective").tag("perspective")
                        }
                        VStack(alignment: .leading) {
                            HStack {
                                Text("Fill the frame by warping")
                                Spacer()
                                Text("\(Int(boundaryWarp))").monospacedDigit().foregroundStyle(.secondary)
                            }
                            Slider(value: $boundaryWarp, in: 0...100, step: 1)
                                .accessibilityLabel(Text("Fill the frame by warping"))
                        }
                        Toggle("Crop the uneven edges", isOn: $autoCrop)
                        Toggle("Fill the uneven edges", isOn: $fillEdges)
                    }
                }
                Section {
                    Toggle("Auto settings on the result", isOn: $autoSettings)
                    Toggle("Stack the originals under it", isOn: $stack)
                }
                if let error {
                    Section { Label(error, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.red).textSelection(.enabled) }
                }
                if let progress {
                    Section {
                        ProgressView(value: progress) { Text(stage.isEmpty ? "Merging\u{2026}" : stage) }
                        Button("Stop", role: .destructive) { Merging.cancelled = true }
                    }
                }
            }
            .navigationTitle("Merge photos")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        Merging.cancelled = true
                        dismiss()
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Merge") { start() }
                        .disabled(progress != nil || ids.count < 2)
                }
            }
            .interactiveDismissDisabled(progress != nil)
        }
    }

    private func start() {
        var options: [String: Any] = ["autoSettings": autoSettings, "stack": stack]
        if kind.hasHDR { options["align"] = align; options["deghost"] = deghost }
        if kind.hasPano {
            options["projection"] = projection
            options["boundaryWarp"] = boundaryWarp
            options["autoCrop"] = autoCrop
            options["fillEdges"] = fillEdges
        }
        error = nil
        progress = 0
        Task {
            do {
                let id = try await Merging.run(kind.rawValue, ids: ids, options: options) { f, s in
                    progress = f
                    stage = s
                }
                UINotificationFeedbackGenerator().notificationOccurred(.success)
                finished(id)
                dismiss()
            } catch {
                self.error = error.localizedDescription
                progress = nil
            }
        }
    }
}
