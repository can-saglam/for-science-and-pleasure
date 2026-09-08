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
    // Lets the locate-me control live outside the default top-right stack.
    @Namespace private var mapScope

    private static func region(fitting coords: [CLLocationCoordinate2D]) -> MKCoordinateRegion {
        guard let minLat = coords.map(\.latitude).min(),
              let maxLat = coords.map(\.latitude).max(),
              let minLon = coords.map(\.longitude).min(),
              let maxLon = coords.map(\.longitude).max()
        else {
            // Nothing pinned yet: open on home, wherever home is.
            return MKCoordinateRegion(
                center: HomeStore.shared.home.coordinate
                    ?? CLLocationCoordinate2D(latitude: 51.5074, longitude: -0.1278),
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
                // Wider sideways: a pin's title chip spans up to ~75 pt each
                // way, so edge pins need ~a fifth of the screen as margin or
                // their labels render half off-screen.
                longitudeDelta: max((maxLon - minLon) * 1.7, 0.03)
            )
        )
    }

    /// The opening frame is the city, not the region: ~40 km covers Greater
    /// London edge to edge (or any metro), while a sculpture park on the
    /// coast an hour away stays on the map but doesn't drag the first view
    /// out to show the whole south-east. Being "at home" for the user's own
    /// dot is the looser 100 km in `HomeStore` — a day trip is still home.
    private static let openingRadius: CLLocationDistance = 40_000

    /// What the map frames when it opens: the saves around home (a single
    /// Paris pin mustn't zoom a London library out to show both), plus the
    /// user when they're within the same radius. Away from home the map
    /// opens on home, not on the user — that's where the library is. A
    /// library with nothing near home at all frames whatever it has.
    private var openingCoordinates: [CLLocationCoordinate2D] {
        let home = HomeStore.shared
        let here = LocationStore.shared.location
        let all = pinned.map(\.coordinate)
        guard let homeCoord = home.home.coordinate else { return all }
        let homeLoc = CLLocation(latitude: homeCoord.latitude, longitude: homeCoord.longitude)
        func close(_ c: CLLocationCoordinate2D) -> Bool {
            CLLocation(latitude: c.latitude, longitude: c.longitude).distance(from: homeLoc) < Self.openingRadius
        }
        var near = all.filter(close)
        if near.isEmpty { return all }
        if let here, close(here.coordinate) { near.append(here.coordinate) }
        return near
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
        Map(position: $camera, scope: mapScope) {
            UserAnnotation()
            ForEach(clusters) { cluster in
                if cluster.members.count == 1, let pin = cluster.members.first {
                    // Empty title: Apple's own grey label draws at a fixed,
                    // distant offset and can't be styled — we render our own
                    // chip hugging the pin instead.
                    Annotation("", coordinate: pin.coordinate) {
                        Button {
                            Haptics.tap()
                            onSelect(pin.item)
                        } label: {
                            pinFace(pin.item)
                                .shadow(color: .black.opacity(0.4), radius: 4, y: 2)
                                // The visible dot is below Apple's 44 pt
                                // minimum — pad the tappable area out to it.
                                .padding(8)
                                .contentShape(.circle)
                        }
                        .buttonStyle(.plain)
                        // The chip hangs off the button as an overlay so the
                        // dot itself stays exactly on the coordinate.
                        .overlay(alignment: .bottom) {
                            Text(pin.item.title)
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(.white)
                                .lineLimit(2)
                                .multilineTextAlignment(.center)
                                .padding(.horizontal, 7)
                                .padding(.vertical, 3.5)
                                .background(
                                    .black.opacity(0.62),
                                    in: .rect(cornerRadius: 8, style: .continuous)
                                )
                                // A fixed-width invisible box: the overlay
                                // would otherwise propose the button's 44 pt
                                // and wrap every title. The visible chip still
                                // hugs its text inside it.
                                .frame(width: 150)
                                // Top of the chip sits just under the dot,
                                // eating most of the invisible tap padding.
                                .alignmentGuide(.bottom) { $0[.top] + 6 }
                                .allowsHitTesting(false)
                        }
                        .accessibilityLabel(pin.item.title)
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
                                    .font(.subheadline.weight(.bold))
                                    .foregroundStyle(AppBackground.base)
                            }
                            .frame(width: 34, height: 34)
                            .shadow(color: .black.opacity(0.4), radius: 4, y: 2)
                            .padding(6)
                            .contentShape(.circle)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("\(cluster.members.count) saves here. Zoom in")
                    }
                }
            }
        }
        .onAppear {
            let region = Self.region(fitting: openingCoordinates)
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
            MapCompass()
        }
        // Apple's own landmarks (Tower Bridge, big parks…) would compete
        // with our pins for attention — only the saves get to speak.
        .mapStyle(.standard(pointsOfInterest: .excludingAll))
        // A wash of the theme base over the map, so Midnight reads blue,
        // Forest green, Ink simply darker — instead of one grey for all.
        // Light enough that pins and chips keep their punch.
        .overlay {
            AppBackground.base
                .opacity(AppBackground.theme == .ink ? 0.24 : 0.18)
                .allowsHitTesting(false)
                .ignoresSafeArea()
        }
        // Mirror of the header's soft blur: the map fades into the tab bar
        // instead of ending against it with a hard edge.
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(.ultraThinMaterial)
                .mask(
                    LinearGradient(
                        stops: [
                            .init(color: .clear, location: 0),
                            .init(color: .black, location: 0.5),
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
                .frame(height: 170)
                .allowsHitTesting(false)
                .ignoresSafeArea(edges: .bottom)
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
        // Locate-me docks directly above the add button, at its exact size —
        // the bar reports the add button's real frame, so the two stay
        // aligned whatever the pill's text metrics are. Our own button, not
        // MapUserLocationButton: the system one draws its own dark backing
        // at its own size, which read as a double button inside the glass.
        .overlay {
            GeometryReader { geo in
                let plus = PlusButtonFrame.shared.rect
                if plus != .zero {
                    let local = geo.frame(in: .global)
                    Button {
                        Haptics.tap()
                        LocationStore.shared.refresh()
                        withAnimation(.snappy) {
                            camera = .userLocation(fallback: camera)
                        }
                    } label: {
                        Image(systemName: "location")
                            .font(.body.weight(.semibold))
                            .foregroundStyle(AppBackground.accent)
                            .frame(width: plus.width, height: plus.height)
                            .contentShape(.circle)
                    }
                    .buttonStyle(.plain)
                    .glassEffect(.regular, in: .circle)
                    .accessibilityLabel("Show my location")
                    .position(
                        x: plus.midX - local.minX,
                        y: plus.minY - 12 - plus.height / 2 - local.minY
                    )
                }
            }
        }
        .mapScope(mapScope)
        .ignoresSafeArea(edges: .bottom)
    }

    /// A pin's face: the item's own photo in a ringed circle when it has
    /// one — the saved thing looking back at you from the map — otherwise
    /// the accent-colored dot with the kind icon. The accent ring inside
    /// the white one keeps each pin's color present even on photo pins.
    @ViewBuilder
    private func pinFace(_ item: Item) -> some View {
        if let url = item.imageUrl.flatMap(URL.init(string:)) {
            CachedImage(url: url) { phase in
                if case .success(let image) = phase {
                    image.resizable().scaledToFill()
                } else {
                    item.accentColor
                }
            }
            .frame(width: 36, height: 36)
            .clipShape(.circle)
            .overlay(Circle().strokeBorder(item.accentColor, lineWidth: 1.5).padding(2.5))
            .overlay(Circle().strokeBorder(.white, lineWidth: 3))
        } else {
            ZStack {
                Circle()
                    .fill(item.accentColor)
                Circle()
                    .strokeBorder(.white, lineWidth: 3)
                // What the save *is* — cutlery for a restaurant, a palette
                // for a gallery, a leaf for a park — not which tab it's on.
                Image(systemName: item.glyph)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white)
            }
            .frame(width: 28, height: 28)
        }
    }

    /// One tap flies to the cluster's own bounding box — tight enough that
    /// clustering switches off (below the 0.02 threshold) and the members
    /// land as individual pins, instead of stepping down zoom by zoom.
    private func zoom(into cluster: Cluster) {
        Haptics.tap()
        let lats = cluster.members.map(\.coordinate.latitude)
        let lons = cluster.members.map(\.coordinate.longitude)
        let region = MKCoordinateRegion(
            center: cluster.center,
            span: MKCoordinateSpan(
                latitudeDelta: max((lats.max()! - lats.min()!) * 1.6, 0.012),
                longitudeDelta: max((lons.max()! - lons.min()!) * 1.9, 0.012)
            )
        )
        withAnimation(.snappy) {
            camera = .region(region)
        }
        // Re-cluster for the target zoom right away, so pins separate as
        // the camera flies instead of after it settles.
        span = region.span
    }
}
