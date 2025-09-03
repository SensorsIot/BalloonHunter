import Foundation

class AnnotationService {
    enum AppState: String {
        case startup
        case longRangeTracking
        case other
    }
    
    var appState: AppState = .startup
    var telemetryHistory: [String] = []
    
    func updateState(telemetry: String?, userLocation: String?, prediction: String?, route: String?) {
        print("[DEBUG][AnnotationService] updateState called!")
        print("[DEBUG][AnnotationService] telemetry=\(String(describing: telemetry)), userLocation=\(String(describing: userLocation)), prediction=\(String(describing: prediction)), route=\(String(describing: route)), telemetryHistory.count=\(telemetryHistory.count)")
        print("[DEBUG][AnnotationService] current appState: \(self.appState.rawValue)")
        
        if appState == .startup && telemetry != nil {
            appState = .longRangeTracking
            print("[DEBUG][AnnotationService] State transitioned: .startup → .longRangeTracking (telemetry != nil)")
        }
        
        // Other update logic here
    }
}
