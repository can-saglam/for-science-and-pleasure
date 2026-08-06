import MapKit
import SwiftData
import SwiftUI

/// Detail sheet — a soft wash of the item's color at the top, quiet
/// metadata, the map, and a pair of equal actions. A pencil in the toolbar
/// flips the whole sheet into an edit form.
struct ItemDetailView: View {
    @Bindable var item: Item
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var context
    @Environment(\.openURL) private var openURL
    @State private var confetti = false
    @State private var editing = false
    @State private var calendarState: CalendarState = .idle
    @State private var detent: PresentationDetent = .medium

    private enum CalendarState {
        case idle, added, failed
    }

    private var dateLine: String? {
        switch (item.startsOn, item.endsOn) {
        case let (s?, e?) where s == e:
            return DayString.date(s)?.formatted(date: .abbreviated, time: .omitted)
        case let (s?, e?):
            let from = DayString.date(s)?.formatted(date: .abbreviated, time: .omitted) ?? s
            let to = DayString.date(e)?.formatted(date: .abbreviated, time: .omitted) ?? e
            return "\(from) – \(to)"
        case let (s?, nil):
            return "From \(DayString.date(s)?.formatted(date: .abbreviated, time: .omitted) ?? s)"
        case let (nil, e?):
            return "Until \(DayString.date(e)?.formatted(date: .abbreviated, time: .omitted) ?? e)"
        default:
            return nil
        }
    }

    private var heroURL: URL? {
        item.imageUrl.flatMap(URL.init(string:))
    }

    /// Text accompanying a shared link — enough to make sense in a chat.
    private var shareMessage: String {
        var lines = [item.title]
        let place = [item.venue, item.area].compactMap(\.self).joined(separator: ", ")
        if !place.isEmpty { lines.append(place) }
        if let dateLine { lines.append(dateLine) }
        return lines.joined(separator: "\n")
    }

    private var showsHero: Bool { heroURL != nil && !editing }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    if let hero = heroURL, !editing {
                        heroHeader(hero)
                    }
                    VStack(alignment: .leading, spacing: 20) {
                        if !showsHero {
                            header
                        }
                        if editing {
                            ItemForm(item: item)
                                .transition(.opacity)
                        } else {
                            readingContent
                        }
                    }
                    .padding(20)
                }
            }
            // With a hero, the photo runs edge-to-edge under the controls.
            .ignoresSafeArea(edges: showsHero ? .top : [])
            .scrollDismissesKeyboard(.interactively)
            // Without a photo, the item's color breathes at the top instead.
            .background(alignment: .top) {
                if !showsHero {
                    LinearGradient(
                        colors: [item.accentColor.opacity(0.22), .clear],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                    .frame(height: 260)
                    .ignoresSafeArea()
                }
            }
            .background(AppBackground.sheet.ignoresSafeArea())
            .toolbarBackground(.hidden, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        Haptics.tap()
                        if editing {
                            item.updatedAt = .now
                            try? context.save()
                        }
                        withAnimation(.snappy) { editing.toggle() }
                    } label: {
                        if editing {
                            Text("Done").font(.subheadline.weight(.semibold))
                        } else {
                            Image(systemName: "pencil")
                        }
                    }
                    .accessibilityLabel(editing ? "Finish editing" : "Edit")
                }
                ToolbarItem(placement: .topBarLeading) {
                    if let url = item.url.flatMap(URL.init(string:)) {
                        ShareLink(item: url, message: Text(shareMessage)) {
                            Image(systemName: "square.and.arrow.up")
                        }
                    } else {
                        ShareLink(item: shareMessage) {
                            Image(systemName: "square.and.arrow.up")
                        }
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        Haptics.tap()
                        dismiss()
                    } label: {
                        Image(systemName: "xmark")
                    }
                }
            }
        }
        // Cards open as a half-height drawer first; drag up for the rest.
        .presentationDetents([.medium, .large], selection: $detent)
        .presentationDragIndicator(.visible)
        // The edit form needs the room, so entering edit expands the sheet.
        .onChange(of: editing) { _, isEditing in
            if isEditing { detent = .large }
        }
        // Edits are live on the model; if the sheet is swiped away mid-edit,
        // stamp and persist them just like tapping Done would.
        .onDisappear {
            if editing {
                item.updatedAt = .now
                try? context.save()
            }
        }
    }

    // MARK: - Header

    /// Full-bleed photo melting into the sheet through a theme-colored
    /// scrim, with the title and meta sitting on top of it.
    private func heroHeader(_ url: URL) -> some View {
        Color.clear
            .frame(height: 230)
            .overlay {
                AsyncImage(url: url) { phase in
                    if case .success(let image) = phase {
                        image.resizable().scaledToFill()
                    } else {
                        item.accentColor.opacity(0.25)
                    }
                }
            }
            .overlay {
                LinearGradient(
                    stops: [
                        // Darkened top keeps the floating controls legible.
                        .init(color: .black.opacity(0.35), location: 0),
                        .init(color: .clear, location: 0.32),
                        .init(color: AppBackground.sheet.opacity(0.7), location: 0.78),
                        .init(color: AppBackground.sheet, location: 1),
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
            }
            .clipped()
            // The filled image overflows the frame, and at fractional pixel
            // positions the clip edge and the gradient's edge round
            // differently, leaking a one-pixel line of raw photo just past
            // the bottom. A sheet-colored strip straddling the boundary
            // (1pt of overhang into the plain sheet below) buries it.
            .overlay(alignment: .bottom) {
                AppBackground.sheet.frame(height: 3).offset(y: 1)
            }
            .overlay(alignment: .bottomLeading) {
                header
                    .padding(.horizontal, 20)
                    .padding(.bottom, 6)
            }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(item.title)
                .font(.title2.weight(.semibold))
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                if let label = item.timeLabel {
                    Text(label)
                        .foregroundStyle(item.timeLabelIsUrgent ? .red : Color.secondary)
                }
                if item.timeLabel != nil && item.category != nil {
                    Text("·").foregroundStyle(.tertiary)
                }
                if let category = item.category {
                    Text(category).foregroundStyle(.secondary)
                }
            }
            .font(.subheadline.weight(.medium))
        }
    }

    // MARK: - Reading mode

    @ViewBuilder
    private var readingContent: some View {
        if let summary = item.summary {
            Text(summary)
                .fixedSize(horizontal: false, vertical: true)
        }

        VStack(alignment: .leading, spacing: 10) {
            metaRow("calendar", dateLine)
            metaRow("building.2", item.venue != item.title ? item.venue : nil)
            metaRow("map", item.area)
            metaRow("sterlingsign.circle", item.price)
        }

        if let lat = item.lat, let lng = item.lng {
            let coord = CLLocationCoordinate2D(latitude: lat, longitude: lng)
            Map(initialPosition: .region(.init(
                center: coord,
                span: .init(latitudeDelta: 0.012, longitudeDelta: 0.012)
            ))) {
                Marker(item.venue ?? item.title, coordinate: coord)
                    .tint(item.accentColor)
            }
            .frame(height: 190)
            .allowsHitTesting(false)
            .overlay(alignment: .bottomTrailing) {
                Label("Open in Google Maps", systemImage: "arrow.up.right")
                    .font(.caption.weight(.medium))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .glassEffect(.regular, in: .capsule)
                    .padding(8)
            }
            .clipShape(.rect(cornerRadius: 18, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .strokeBorder(.white.opacity(0.10), lineWidth: 1)
            )
            .contentShape(.rect(cornerRadius: 18, style: .continuous))
            .onTapGesture {
                if let maps = item.googleMapsURL {
                    Haptics.tap()
                    openURL(maps)
                }
            }
        }

        if let notes = item.notes, !notes.isEmpty {
            Text(notes)
                .font(.subheadline)
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.white.opacity(0.06), in: .rect(cornerRadius: 14, style: .continuous))
        }

        // Actions: an equal pair up top, the calendar as a quiet
        // third. No accent — the content above carries the color.
        VStack(spacing: 10) {
            HStack(spacing: 10) {
                if let url = item.url.flatMap(URL.init(string:)) {
                    Link(destination: url) {
                        Label("Open link", systemImage: "safari")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(AppBackground.base)
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.glassProminent)
                    .tint(.white)
                }

                if !item.isDone {
                    Button {
                        item.markDone()
                        confetti = true
                        Task {
                            try? await Task.sleep(for: .seconds(0.75))
                            dismiss()
                        }
                    } label: {
                        Label("We did go!", systemImage: "checkmark")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(AppBackground.base)
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.glassProminent)
                    .tint(.white)
                    .overlay {
                        ConfettiBurst(color: item.accentColor, fire: $confetti)
                    }
                    .sensoryFeedback(.success, trigger: confetti) { _, new in new }
                }
            }

            if item.startsOn != nil && !item.isDone {
                Button {
                    Haptics.tap()
                    Task {
                        do {
                            try await item.addToCalendar()
                            Haptics.success()
                            withAnimation(.snappy) { calendarState = .added }
                        } catch {
                            withAnimation(.snappy) { calendarState = .failed }
                        }
                    }
                } label: {
                    Label(
                        calendarState == .added ? "In calendar" : "Add to calendar",
                        systemImage: calendarState == .added ? "checkmark" : "calendar.badge.plus"
                    )
                    .font(.subheadline.weight(.medium))
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.glass)
                .disabled(calendarState == .added)
            }

            if calendarState == .failed {
                Text("Couldn't add — allow calendar access in Settings.")
                    .font(.footnote)
                    .foregroundStyle(.red)
            }
        }
        .controlSize(.large)
        .padding(.top, 4)
    }

    @ViewBuilder
    private func metaRow(_ symbol: String, _ text: String?) -> some View {
        if let text {
            Label {
                Text(text).foregroundStyle(.secondary)
            } icon: {
                Image(systemName: symbol)
                    .foregroundStyle(.white.opacity(0.45))
                    .frame(width: 20)
            }
            .font(.subheadline)
        }
    }

}
