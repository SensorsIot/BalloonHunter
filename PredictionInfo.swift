import Foundation
import Combine

class PredictionInfo: ObservableObject {
    @Published var landingTime: Date? = nil
    @Published var arrivalTime: Date? = nil // wall clock time, nil if not available
    @Published var routeDistanceMeters: Double? = nil // meters, nil if not available
}
