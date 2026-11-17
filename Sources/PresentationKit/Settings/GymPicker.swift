import Domain
import Foundation
import Observation
import SwiftUI

/// "Which gym do you train at?" — nearby gyms from the app's locator (MapKit, or Google Places through our proxy).
/// Your position is read once, here, and not kept.
@MainActor
@Observable
public final class GymPickerViewModel {
    public enum State: Equatable {
        case locating
        case results([GymVenue])
        case empty
        case failed(ConnectionFailure)
        case unavailable
    }

    public private(set) var state: State = .locating
    public private(set) var chosen: GymVenue?
    public private(set) var origin: (latitude: Double, longitude: Double)?

    @ObservationIgnored private let locator: any GymLocating
    @ObservationIgnored private let currentLocation: () async throws -> (latitude: Double, longitude: Double)
    @ObservationIgnored private let onSelect: (GymVenue) async throws -> Void
    @ObservationIgnored private let radiusMeters: Double

    public init(locator: any GymLocating,
                currentLocation: @escaping () async throws -> (latitude: Double, longitude: Double),
                radiusMeters: Double = 3_000,
                onSelect: @escaping (GymVenue) async throws -> Void) {
        self.locator = locator
        self.currentLocation = currentLocation
        self.radiusMeters = radiusMeters
        self.onSelect = onSelect
    }

    public func load() async {
        state = .locating
        do {
            let here = try await currentLocation()
            origin = here
            let found = try await locator.gyms(near: here.latitude, longitude: here.longitude, radiusMeters: radiusMeters)
            let sorted = found.sorted {
                $0.distanceMeters(toLatitude: here.latitude, longitude: here.longitude) < $1.distanceMeters(toLatitude: here.latitude, longitude: here.longitude)
            }
            state = sorted.isEmpty ? .empty : .results(sorted)
        } catch let failure as ConnectionFailure {
            state = .failed(failure)
        } catch {
            state = .unavailable
        }
    }

    /// "350 m" / "1.2 km" from where the student stood when the list loaded.
    public func distanceText(for venue: GymVenue) -> String? {
        guard let origin else { return nil }
        let meters = venue.distanceMeters(toLatitude: origin.latitude, longitude: origin.longitude)
        return meters < 1_000 ? String(localized: "\(Int((meters / 10).rounded()) * 10) m")
                              : "\((meters / 1_000).formatted(.number.precision(.fractionLength(1)))) km"
    }

    public func choose(_ venue: GymVenue) async {
        do {
            try await onSelect(venue)
            chosen = venue
        } catch {
            state = .unavailable
        }
    }
}

public struct GymPickerView: View {
    private let model: GymPickerViewModel
    @Environment(\.dismiss) private var dismiss

    public init(model: GymPickerViewModel) { self.model = model }

    public var body: some View {
        NavigationStack {
            Group {
                switch model.state {
                case .locating:
                    ProgressView(String(localized: "Looking for gyms near you…")).frame(maxWidth: .infinity, maxHeight: .infinity)
                case .results(let gyms):
                    List(Array(gyms.enumerated()), id: \.element.id) { index, gym in
                        Button {
                            Task { await model.choose(gym); if model.chosen != nil { dismiss() } }
                        } label: {
                            HStack {
                                Text(verbatim: gym.name)
                                Spacer()
                                if let distance = model.distanceText(for: gym) { Text(verbatim: distance).foregroundStyle(.secondary) }
                            }
                        }
                        .foregroundStyle(.primary)
                        .accessibilityIdentifier("gym-option-\(index)")
                    }
                case .empty:
                    ContentUnavailableView(String(localized: "No gyms found"), systemImage: "mappin.slash",
                                           description: Text(String(localized: "Try again closer to your gym.")))
                case .failed(.permissionDenied):
                    ContentUnavailableView(String(localized: "Location is off"), systemImage: "location.slash",
                                           description: Text(String(localized: "Allow location for FitCoach in Settings to find your gym.")))
                case .failed, .unavailable:
                    ContentUnavailableView {
                        Label(String(localized: "Couldn't load gyms"), systemImage: "wifi.slash")
                    } actions: {
                        Button(String(localized: "Try again")) { Task { await model.load() } }
                    }
                }
            }
            .navigationTitle(String(localized: "My gym"))
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button(String(localized: "Cancel")) { dismiss() } } }
            .task { await model.load() }
        }
    }
}
