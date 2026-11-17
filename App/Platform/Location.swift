import CoreLocation
import Domain
import MapKit
import PresentationKit

/// One-shot "where am I" for the gym picker. Nothing is stored: the position is used to look up nearby gyms and dropped.
@MainActor
final class CurrentLocation: NSObject, CLLocationManagerDelegate {
    private let manager = CLLocationManager()
    private var continuation: CheckedContinuation<(latitude: Double, longitude: Double), Error>?

    override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyHundredMeters
    }

    static var isDenied: Bool {
        let status = CLLocationManager().authorizationStatus
        return status == .denied || status == .restricted
    }

    func once() async throws -> (latitude: Double, longitude: Double) {
        if Self.isDenied { throw ConnectionFailure.permissionDenied }
        return try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
            switch manager.authorizationStatus {
            case .notDetermined: manager.requestWhenInUseAuthorization()
            default: manager.requestLocation()
            }
        }
    }

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let status = manager.authorizationStatus
        MainActor.assumeIsolated {
            switch status {
            case .authorizedWhenInUse, .authorizedAlways: if continuation != nil { self.manager.requestLocation() }
            case .denied, .restricted: finish(.failure(ConnectionFailure.permissionDenied))
            default: break
            }
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let last = locations.last else { return }
        MainActor.assumeIsolated { finish(.success((last.coordinate.latitude, last.coordinate.longitude))) }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        MainActor.assumeIsolated { finish(.failure(error)) }
    }

    private func finish(_ result: Result<(latitude: Double, longitude: Double), Error>) {
        continuation?.resume(with: result)
        continuation = nil
    }
}

/// Keyless gym finder over MapKit (`MKLocalSearch`, fitness-centre points of interest): the default. The Google Places
/// proxy (`PlacesProxyGymLocator`) replaces it where the backend is configured.
struct MapKitGymLocator: GymLocating {
    func gyms(near latitude: Double, longitude: Double, radiusMeters: Double) async throws -> [GymVenue] {
        let request = MKLocalSearch.Request()
        request.naturalLanguageQuery = "gym"
        request.region = MKCoordinateRegion(center: CLLocationCoordinate2D(latitude: latitude, longitude: longitude),
                                            latitudinalMeters: radiusMeters * 2, longitudinalMeters: radiusMeters * 2)
        request.pointOfInterestFilter = MKPointOfInterestFilter(including: [.fitnessCenter])
        let response = try await MKLocalSearch(request: request).start()
        return response.mapItems.prefix(15).compactMap { item in
            guard let name = item.name else { return nil }
            let coordinate = item.placemark.coordinate
            // MapKit has no stable place id: a rounded coordinate is stable enough to recognise the same gym again.
            return GymVenue(id: String(format: "mk:%.4f,%.4f", coordinate.latitude, coordinate.longitude), name: name,
                            latitude: coordinate.latitude, longitude: coordinate.longitude, radiusMeters: 120)
        }
    }
}
