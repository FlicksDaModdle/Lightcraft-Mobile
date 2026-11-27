import MapKit
import SwiftUI

/// Places: a map of where the library's photos were taken, from their GPS positions, and the town and country
/// filled in from them (offline, with the GeoNames place names, downloaded once) so search finds them by place.
struct PlacesView: View {
    @ObservedObject var library: Library
    @Binding var open: Photo?
    @State private var camera: MapCameraPosition = .automatic
    @State private var spot: Spot?
    @State private var span = 1.0
    @State private var status: String?
    @State private var working = false

    /// Photos taken close together, as one pin.
    struct Spot: Identifiable, Hashable {
        let id: String
        let coordinate: CLLocationCoordinate2D
        let photos: [Photo]
        static func == (a: Spot, b: Spot) -> Bool { a.id == b.id }
        func hash(into h: inout Hasher) { h.combine(id) }
    }

    /// The photos with a position, grouped on a grid about a tenth of the map's width.
    private var spots: [Spot] {
        let cell = max(span / 10, 0.0005)
        var groups: [String: [Photo]] = [:]
        for p in library.photos {
            guard let g = p.gps else { continue }
            let key = "\(Int((g.lat / cell).rounded(.down))) \(Int((g.lon / cell).rounded(.down)))"
            groups[key, default: []].append(p)
        }
        return groups.map { key, photos in
            let lat = photos.compactMap { $0.gps?.lat }.reduce(0, +) / Double(photos.count)
            let lon = photos.compactMap { $0.gps?.lon }.reduce(0, +) / Double(photos.count)
            return Spot(id: key, coordinate: CLLocationCoordinate2D(latitude: lat, longitude: lon), photos: photos.sorted { $0.captured > $1.captured })
        }
    }

    var body: some View {
        NavigationStack {
            let located = library.photos.filter { $0.gps != nil }
            ZStack(alignment: .top) {
                Map(position: $camera) {
                    ForEach(spots) { s in
                        Annotation("", coordinate: s.coordinate) {
                            Button { spot = s } label: { SpotPin(spot: s) }
                                .buttonStyle(.plain)
                                .accessibilityLabel(Text("\(s.photos.count) photos\(s.photos.first.map { $0.city.isEmpty ? "" : " in \($0.city)" } ?? "")"))
                        }
                    }
                }
                .mapStyle(.standard(elevation: .realistic, pointsOfInterest: .excludingAll))
                .onMapCameraChange(frequency: .onEnd) { c in span = c.region.span.longitudeDelta }
                .ignoresSafeArea(edges: .bottom)
                if located.isEmpty {
                    Text("Photos with a location show up on the map. Photos from the camera bring theirs when Location Services were on.")
                        .font(.system(size: 14))
                        .multilineTextAlignment(.center)
                        .padding(14)
                        .latentGlass(in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                        .padding(20)
                }
                if let status {
                    Text(status)
                        .font(.system(size: 13))
                        .padding(.horizontal, 14).padding(.vertical, 8)
                        .latentGlass(in: Capsule())
                        .padding(.top, 8)
                        .transition(.opacity)
                }
            }
            .navigationTitle("Places")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        fillPlaceNames(located.map(\.id))
                    } label: {
                        if working { ProgressView() } else { Label("Add place names", systemImage: "character.textbox") }
                    }
                    .disabled(working || located.isEmpty)
                    .accessibilityLabel(Text("Add town and country names from the locations"))
                }
            }
            .sheet(item: $spot) { s in
                SpotSheet(spot: s, open: $open)
                    .presentationDetents([.medium, .large])
            }
        }
    }

    /// Fill in town, region and country from each photo's position (downloading the place names first if needed).
    private func fillPlaceNames(_ ids: [UInt64]) {
        working = true
        status = nil
        Task {
            defer { working = false }
            func downloaded() -> Bool {
                ((try? Engine.shared.run("metadata.placeNamesStatus")) as? [String: Any])?["downloaded"] as? Bool ?? false
            }
            if !downloaded() {
                status = "Downloading place names (GeoNames, about 3 MB)\u{2026}"
                do { _ = try Engine.shared.run("metadata.downloadPlaceNames") } catch {
                    status = error.localizedDescription
                    return
                }
                for _ in 0..<120 where !downloaded() {
                    try? await Task.sleep(for: .seconds(1))
                }
                guard downloaded() else {
                    status = "The place names didn't download. Check the connection and try again."
                    return
                }
            }
            do {
                let r = try Engine.shared.run("metadata.reverseGeocode", ["ids": ids]) as? [String: Any] ?? [:]
                let changed = (r["changed"] as? NSNumber)?.intValue ?? 0
                status = changed > 0 ? "Added place names to \(changed) photo\(changed == 1 ? "" : "s"). Place names: GeoNames, CC-BY 4.0." : "Every photo already has its place names."
                library.reload()
            } catch {
                status = error.localizedDescription
            }
            try? await Task.sleep(for: .seconds(5))
            withAnimation { status = nil }
        }
    }
}

/// A pin: the newest photo of the spot, with how many there are.
struct SpotPin: View {
    let spot: PlacesView.Spot

    var body: some View {
        ThumbView(photo: spot.photos[0])
            .frame(width: 48, height: 48)
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(.white, lineWidth: 2))
            .overlay(alignment: .topTrailing) {
                if spot.photos.count > 1 {
                    Text("\(spot.photos.count)")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 5).padding(.vertical, 1)
                        .background(Theme.accent, in: Capsule())
                        .offset(x: 6, y: -6)
                }
            }
            .shadow(color: .black.opacity(0.4), radius: 3)
    }
}

/// The photos of one spot.
struct SpotSheet: View {
    let spot: PlacesView.Spot
    @Binding var open: Photo?
    @Environment(\.dismiss) private var dismiss
    private let columns = Array(repeating: GridItem(.flexible(), spacing: 2), count: 4)

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVGrid(columns: columns, spacing: 2) {
                    ForEach(spot.photos) { p in
                        Button {
                            dismiss()
                            open = p
                        } label: { LibraryCell(photo: p) }
                            .buttonStyle(.plain)
                            .accessibilityLabel(Text(p.fileName))
                    }
                }
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
        }
    }

    private var title: String {
        let p = spot.photos[0]
        let place = [p.city, p.country].filter { !$0.isEmpty }.joined(separator: ", ")
        return place.isEmpty ? "\(spot.photos.count) photos" : place
    }
}
