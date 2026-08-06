import CoreLocation
import Observation

/// One coarse fix, fetched when the Places tab appears — enough to say
/// "1.2 km away" on cards without tracking anyone around town.
@Observable
final class LocationStore: NSObject, CLLocationManagerDelegate {
    static let shared = LocationStore()

    private let manager = CLLocationManager()
    private(set) var location: CLLocation?

    override private init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyHundredMeters
    }

    func refresh() {
        switch manager.authorizationStatus {
        case .notDetermined:
            // CWG_NO_PROMPTS keeps automated screenshot runs alert-free.
            guard ProcessInfo.processInfo.environment["CWG_NO_PROMPTS"] == nil else { return }
            manager.requestWhenInUseAuthorization()
        case .authorizedWhenInUse, .authorizedAlways:
            manager.requestLocation()
        default:
            break
        }
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        if manager.authorizationStatus == .authorizedWhenInUse
            || manager.authorizationStatus == .authorizedAlways {
            manager.requestLocation()
        }
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        location = locations.last
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {}
}
