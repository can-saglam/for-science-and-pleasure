import AuthenticationServices
import CoreLocation
import MapKit
import SwiftData
import SwiftUI
import UserNotifications

extension OnboardingView {
    // MARK: Home

    enum HomeVariant { case finding, confirm, manual }
    var homeVariant: HomeVariant {
        if guessing, !guessSlow { return .finding }
        if guessed, !manualHome, picked != nil { return .confirm }
        return .manual
    }

    var homePage: some View {
        VStack(alignment: .leading, spacing: 18) {
            switch homeVariant {
            case .finding: headline("Finding\nyour city…")
            case .confirm: headline("Looks like\n\(picked?.locality ?? ""), right?")
            case .manual: headline("Where do you\ngo out?")
            }
            lede("Your picks come from this city, and the map opens on it.")

            switch homeVariant {
            case .finding:
                ProgressView().controlSize(.small).padding(.vertical, 8)

            case .confirm:
                quiet("Somewhere else") {
                    manualHome = true
                    picked = nil
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { focus = .city }
                }

            case .manual:
                slab {
                    HStack(spacing: 10) {
                        TextField("", text: $cityDraft, prompt: AppBackground.fieldPrompt("City"))
                            .font(.title3)
                            .foregroundStyle(AppBackground.ink)
                            .textInputAutocapitalization(.words)
                            .autocorrectionDisabled()
                            .submitLabel(.search)
                            .focused($focus, equals: .city)
                            .onSubmit { Task { await lookupCity() } }
                        if locating {
                            ProgressView().controlSize(.small)
                        } else {
                            CitySearchButton(enabled: !cityDraft.trimmingCharacters(in: .whitespaces).isEmpty) {
                                Task { await lookupCity() }
                            }
                        }
                    }
                    .padding(.horizontal, 18)
                    .padding(.vertical, 15)
                }

                if !matches.isEmpty {
                    slab {
                        VStack(spacing: 0) {
                            ForEach(matches, id: \.self) { m in
                                Button {
                                    Haptics.tap()
                                    pick(m)
                                } label: {
                                    HStack {
                                        VStack(alignment: .leading, spacing: 2) {
                                            Text(m.locality).font(.body.weight(.medium))
                                            Text(m.country).font(.caption).foregroundStyle(AppBackground.secondaryInk)
                                        }
                                        Spacer()
                                        if picked == m {
                                            Image(systemName: "checkmark").font(.body.weight(.semibold))
                                        }
                                    }
                                    .contentShape(Rectangle())
                                    .padding(.horizontal, 16)
                                    .padding(.vertical, 12)
                                }
                                .buttonStyle(.plain)
                                if m != matches.last {
                                    Divider().padding(.leading, 16)
                                }
                            }
                        }
                    }
                }

                HStack(spacing: 8) {
                    if !LocationStore.shared.denied, matches.isEmpty {
                        chip(locating ? "Locating…" : "Use my location", icon: "location") {
                            Task { await useLocation() }
                        }
                        .disabled(locating)
                    }
                    // Never a dead end: offline, or a city the geocoder
                    // can't place, shouldn't hold the whole first run.
                    if picked == nil {
                        quiet("Skip for now") { skipHome() }
                    }
                }
            }

            noteLine
        }
        .animation(ease, value: homeVariant)
        .animation(ease, value: matches)
    }

    /// Carries on without a home. Remembered per account so the gate
    /// doesn't bring the page back every launch; Settings can set it.
    func skipHome() {
        if !preview { OnboardingGate.skipHome() }
        advance()
    }

    func pick(_ home: HomeStore.Home) {
        picked = home
        note = nil
        frame(home, wide: wholeCities.contains(home))
        focus = nil
        // Start the city search now, not on "Set as home" — a cold miss
        // is a model call and the name page is the wait.
        fetchStarters(for: home)
    }

    /// Before a city is picked, the map opens on the phone's own country
    /// rather than the whole world, so the zoom into home is a short one.
    /// Any miss (offline, no region set) leaves the world view.
    func frameCountry() async {
        guard picked == nil, let code = Locale.current.region?.identifier,
              let country = Locale.current.localizedString(forRegionCode: code)
        else { return }
        let request = MKLocalSearch.Request()
        request.naturalLanguageQuery = country
        request.resultTypes = .address
        guard let region = try? await MKLocalSearch(request: request).start().boundingRegion,
              picked == nil
        else { return }
        camera = .region(region)
    }

    /// `wide`: a whole city taken in place of one of its wards.
    func frame(_ home: HomeStore.Home, wide: Bool = false) {
        guard let c = home.coordinate else { return }
        let isLondon = home.locality.compare("London", options: .caseInsensitive) == .orderedSame
        let span: CLLocationDistance = isLondon || wide ? 60_000 : 22_000
        withAnimation(reduceMotion ? nil : .easeInOut(duration: 1.0)) {
            camera = .region(MKCoordinateRegion(center: c, latitudinalMeters: span, longitudinalMeters: span))
        }
    }

    /// Location was already allowed — try to name the city before asking.
    /// A cold GPS start can take a while, and this runs behind the
    /// welcome page and the sign-in anyway, so give it a real chance.
    func guessHome() async {
        guessing = true
        defer { guessing = false; guessSlow = false }
        LocationStore.shared.refresh()
        // Nobody should watch a spinner for long: after a few seconds
        // the page opens the manual field while the guess keeps going.
        let slow = Task {
            try? await Task.sleep(for: .seconds(4))
            if !Task.isCancelled { guessSlow = true }
        }
        defer { slow.cancel() }
        guard let loc = await awaitFix(seconds: 12) else { return }
        await reverse(loc)
        // A late guess only lands if they haven't started typing.
        guard let first = matches.first, picked == nil, cityDraft.isEmpty else { return }
        pick(first)
        guessed = true
        manualHome = false
    }


    /// The chip: may raise the system permission prompt first. People
    /// read prompts at their own pace, so wait on the *answer*, then on
    /// the fix; only a denial or a genuinely missing fix gives up.
    func useLocation() async {
        locating = true
        defer { locating = false }
        note = nil
        LocationStore.shared.ask()
        if LocationStore.shared.authorization == .notDetermined {
            _ = await awaitAuthorizationAnswer(seconds: 90)
        }
        if LocationStore.shared.denied {
            note = "Location is off for this app. Type your city instead."
            return
        }
        if let loc = await awaitFix(seconds: 15) {
            await reverse(loc)
            if let first = matches.first { pick(first) }
            return
        }
        note = "Couldn't get a fix. Type your city instead."
    }

    /// Polls for a location until one arrives or `seconds` pass.
    func awaitFix(seconds: Double) async -> CLLocation? {
        let deadline = Date.now.addingTimeInterval(seconds)
        while Date.now < deadline {
            if let loc = LocationStore.shared.location { return loc }
            if LocationStore.shared.denied { return nil }
            try? await Task.sleep(for: .milliseconds(300))
        }
        return LocationStore.shared.location
    }

    /// Waits for the permission prompt to be answered either way.
    func awaitAuthorizationAnswer(seconds: Double) async -> Bool {
        let deadline = Date.now.addingTimeInterval(seconds)
        while Date.now < deadline {
            if LocationStore.shared.authorization != .notDetermined { return true }
            try? await Task.sleep(for: .milliseconds(300))
        }
        return false
    }

    func reverse(_ location: CLLocation) async {
        do {
            guard let request = MKReverseGeocodingRequest(location: location) else {
                note = "Couldn't read that location."
                return
            }
            request.preferredLocale = HomeStore.namesLocale
            present(try await request.mapItems)
        } catch {
            note = "Couldn't read that location. Type your city instead."
        }
    }

    func lookupCity() async {
        let query = cityDraft.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return }
        locating = true
        defer { locating = false }
        note = nil
        matches = []
        picked = nil
        do {
            guard let request = MKGeocodingRequest(addressString: query) else {
                note = "Couldn't look that up."
                return
            }
            request.preferredLocale = HomeStore.namesLocale
            present(try await request.mapItems)
            if matches.isEmpty {
                note = "No city matched “\(query)”. Try the city name on its own."
            } else if matches.count == 1, let only = matches.first {
                pick(only)
            }
        } catch {
            note = "Couldn't look that up. Check the connection and try again."
        }
    }

    /// A ward (Nakano, Hackney) is listed as its city (Tokyo, London):
    /// home is the city you go out in, and suggestions are per city.
    func present(_ items: [MKMapItem]) {
        var seen = Set<String>()
        var homes: [HomeStore.Home] = []
        for item in items {
            guard let found = HomeStore.from(item) else { continue }
            let city = HomeStore.widerCity(for: found)
            let home = city ?? found
            let key = "\(home.locality)|\(home.country)"
            guard seen.insert(key).inserted else { continue }
            if let city { wholeCities.insert(city) }
            homes.append(home)
        }
        matches = Array(homes.prefix(5))
    }

    func commitHome(_ home: HomeStore.Home) async {
        fetchStarters(for: home)
        if preview { advance(); return }
        busy = true
        defer { busy = false }
        if let error = await HomeStore.shared.save(home) {
            note = error
            return
        }
        Haptics.success()
        advance()
    }

    /// Ask the server for the city's suggestions now, so they're on the
    /// save page by the time it comes up; the same pool the empty library
    /// tabs use. The store keeps one fetch in flight per city.
    func fetchStarters(for home: HomeStore.Home) {
        suggestions.load(for: home)
    }
}
