import Foundation
import Combine
import MapKit
import SwiftUI

@MainActor
final class AnnotationService: ObservableObject {
    @Published var annotations: [MapAnnotationItem] = []
    private let isFinalApproachSubject = PassthroughSubject<Bool, Never>()
    var isFinalApproach: AnyPublisher<Bool, Never> { isFinalApproachSubject.eraseToAnyPublisher() }

    // Update the annotations list based on latest data.
    func updateAnnotations(
        telemetry: TelemetryData?,
        userLocation: LocationData?,
        prediction: PredictionData?
    ) {
        var items: [MapAnnotationItem] = []
        // Add user annotation if available
        if let userLoc = userLocation {
            items.append(MapAnnotationItem(coordinate: CLLocationCoordinate2D(latitude: userLoc.latitude, longitude: userLoc.longitude), kind: .user))
        }
        // Add balloon annotation if telemetry available
        if let tel = telemetry {
            items.append(MapAnnotationItem(coordinate: CLLocationCoordinate2D(latitude: tel.latitude, longitude: tel.longitude), kind: .balloon))
        }
        // Add burst point (prediction)
        if let burst = prediction?.burstPoint {
            items.append(MapAnnotationItem(coordinate: burst, kind: .burst))
        }
        // Add landing point (prediction)
        if let landing = prediction?.landingPoint {
            items.append(MapAnnotationItem(coordinate: landing, kind: .landing))
        }
        // Add landed annotation if vertical speed negative (descending/landed)
        if let tel = telemetry, tel.verticalSpeed < 0 {
            items.append(MapAnnotationItem(coordinate: CLLocationCoordinate2D(latitude: tel.latitude, longitude: tel.longitude), kind: .landed))
            isFinalApproachSubject.send(true)
        } else {
            isFinalApproachSubject.send(false)
        }
        self.annotations = items
    }
}
