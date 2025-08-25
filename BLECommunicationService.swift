import Combine
import SwiftUI

class BalloonViewModel: ObservableObject {
    @Published var balloonDescends: Bool = false
    
    func startDescent() {
        balloonDescends = true
    }
    
    func stopDescent() {
        balloonDescends = false
    }
}
