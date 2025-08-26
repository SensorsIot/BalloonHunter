// AppService.swift
// Centralized app state and service management for BalloonHunter

import SwiftUI

class AppService: ObservableObject {
    @Published var persistenceService = PersistenceService()
    @Published var bleService: BLECommunicationService
    @Published var locationService = CurrentLocationService()
    @Published var predictionService = PredictionService()
    @Published var routeService = RouteCalculationService()
    @Published var appSettings = AppSettings()
    @Published var userSettings = UserSettings()
    @Published var annotationService = AnnotationService()

    init() {
        print("[DEBUG] AppService init")
        bleService = BLECommunicationService(persistenceService: persistenceService)
    }
}
