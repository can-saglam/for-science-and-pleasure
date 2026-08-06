import MapKit
import SwiftUI

/// Native map of everything with a pin — each one wearing its item's color.
/// Zoomed out, nearby pins merge into counted bubbles; tapping one dives in.
struct MapPinsView: View {
    let items: [Item]
    let onSelect: (Item) -> Void

    // An explicit region, never .automatic: the automatic camera re-frames
    // whenever annotations change, and clustering changes annotations with
    // zoom — together they feed back into an infinite re-render loop.
    @State private var camera: MapCameraPosition = .automatic
    @State private var span: MKCoordinateSpan?

    private static func region(fitting coords: [CLLocationCoordinate2D]) -> MKCoordinateRegion {
        guard let minLat = coords.map(\.latitude).min(),
              let maxLat = coords.map(\.latitude).max(),
              let minLon = coords.map(\.longitude).min(),
              let maxLon = coords.map(\.longitude).max()
        else {
            return MKCoordinateRegion(
                center: CLLocationCoordinate2D(latitude: 51.5074, longitude: -0.1278),
                span: MKCoordinateSpan(latitudeDelta: 0.25, longitudeDelta: 0.25)
            )
        }
        return MKCoordinateRegion(
            center: CLLocationCoordinate2D(
                latitude: (minLat + maxLat) / 2,
                longitude: (minLon + maxLon) / 2
            ),
            span: MKCoordinateSpan(
                latitudeDelta: max((maxLat - minLat) * 1.35, 0.03),
                longitudeDelta: max((maxLon - minLon) * 1.35, 0.03)
            )
        )
    }

    /// Items paired with their coordinates up front — no force unwraps in
    /// the map builder, which can re-evaluate while items are being edited.
    private var pinned: [(item: Item, coordinate: CLLocationCoordinate2D)] {
        items.compactMap { item in
            item.coordinate.map { (item, $0) }
        }
    }

    private struct Cluster: Identifiable {
        let id: String
        let members: [(item: Item, coordinate: CLLocationCoordinate2D)]

        var center: CLLocationCoordinate2D {
            let count = Double(members.count)
            return CLLocationCoordinate2D(
                latitude: members.map(\.coordinate.latitude).reduce(0, +) / count,
                longitude: members.map(\.coordinate.longitude).reduce(0, +) / count
            )
        }
    }

    /// Grid clustering driven by the camera span: pins sharing a cell merge.
    /// Close up (below ~2 km of visible map) everything shows individually,
    /// so stacked venues on one street can still be told apart.
    private var clusters: [Cluster] {
        guard let span, span.latitudeDelta > 0.02 else {
            return pinned.map { Cluster(id: $0.item.id.uuidString, members: [$0]) }
        }
        let cellLat = span.latitudeDelta / 7
        let cellLon = span.longitudeDelta / 6
        var groups: [String: [(item: Item, coordinate: CLLocationCoordinate2D)]] = [:]
        for pin in pinned {
            let row = Int(floor(pin.coordinate.latitude / cellLat))
            let col = Int(floor(pin.coordinate.longitude / cellLon))
            groups["\(row)|\(col)", default: []].append(pin)
        }
        return groups.map { Cluster(id: $0.key, members: $0.value) }
    }

    var body: some View {
        Map(position: $camera) {
            UserAnnotation()
            ForEach(clusters) { cluster in
                if cluster.members.count == 1, let pin = cluster.members.first {
                    Annotation(pin.item.title, coordinate: pin.coordinate) {
                        Button {
                            Haptics.tap()
                            onSelect(pin.item)
                        } label: {
                            ZStack {
                                Circle()
                                    .fill(pin.item.accentColor)
                                Circle()
                                    .strokeBorder(.white, lineWidth: 2.5)
                            }
                            .frame(width: 20, height: 20)
                            .shadow(color: .black.opacity(0.25), radius: 3, y: 1)
                        }
                        .buttonStyle(.plain)
                    }
                } else {
                    Annotation("", coordinate: cluster.center) {
                        Button {
                            zoom(into: cluster)
                        } label: {
                            ZStack {
                                Circle()
                                    .fill(.white.opacity(0.94))
                                Text("\(cluster.members.count)")
                                    .font(.caption.weight(.bold))
                                    .foregroundStyle(AppBackground.base)
                            }
                            .frame(width: 30, height: 30)
                            .shadow(color: .black.opacity(0.25), radius: 3, y: 1)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("\(cluster.members.count) saves here — zoom in")
                    }
                }
            }
        }
        .onAppear {
            let region = Self.region(fitting: pinned.map(\.coordinate))
            camera = .region(region)
            span = region.span
        }
        .onMapCameraChange(frequency: .onEnd) { context in
            // Panning can't change the (absolute) grid — only meaningful
            // zoom changes are worth a re-cluster.
            let new = context.region.span
            if let old = span,
               abs(new.latitudeDelta - old.latitudeDelta) < old.latitudeDelta * 0.05 {
                return
            }
            span = new
        }
        .mapControls {
            MapUserLocationButton()
            MapCompass()
        }
        .overlay(alignment: .bottomLeading) {
            let missing = items.count - pinned.count
            if missing > 0 {
                Text("\(missing) without a location")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .glassEffect(.regular, in: .capsule)
                    .padding(12)
            }
        }
        .ignoresSafeArea(edges: .bottom)
    }

    private func zoom(into cluster: Cluster) {
        Haptics.tap()
        guard let span else { return }
        withAnimation(.snappy) {
            camera = .region(MKCoordinateRegion(
                center: cluster.center,
                span: MKCoordinateSpan(
                    latitudeDelta: span.latitudeDelta / 3.2,
                    longitudeDelta: span.longitudeDelta / 3.2
                )
            ))
        }
    }
}
