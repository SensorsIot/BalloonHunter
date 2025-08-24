// BalloonHunterApp.swift
// App entry point. Injects environment objects and creates the window.
import SwiftUI

@main
struct BalloonHunterApp: App {
    // Service stubs
    @StateObject private var bleService = BLECommunicationService()
    @StateObject private var locationService = CurrentLocationService()
    @StateObject private var predictionService = PredictionService()
    @StateObject private var routeService = RouteCalculationService()
    @StateObject private var persistenceService = PersistenceService()
    @StateObject private var deviceSettings = DeviceSettings()

    var body: some Scene {
        WindowGroup {
            MapView()
                .environmentObject(bleService)
                .environmentObject(locationService)
                .environmentObject(predictionService)
                .environmentObject(routeService)
                .environmentObject(persistenceService)
                .environmentObject(deviceSettings)
        }
    }
}
