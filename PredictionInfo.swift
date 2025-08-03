import Foundation
import Combine

class PredictionInfo: ObservableObject {
    @Published var landingTime: Date? = nil
    @Published var arrivalTime: TimeInterval? = nil // in seconds, nil if not available
}
