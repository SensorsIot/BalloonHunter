import Foundation
import Combine

class PredictionInfo: ObservableObject {
    @Published var landingTime: Date? = nil
    @Published var arrivalTime: Date? = nil // wall clock time, nil if not available
}
