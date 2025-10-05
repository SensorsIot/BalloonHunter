// BalloonHunterApp.swift
// App entry point. Injects environment objects and creates the window.

/*
# AI Assistant Guidelines

Your role: act as a competent Swift programmer to complete this project according to the Functional Specification Document (FSD).

## 1. Follow the FSD
- Follow the FSD: Treat the FSD as the source of truth. Identify missing features or mismatches in the code and implement fixes directly.
- Implement unambiguous tasks immediately (new methods, data model updates, UI changes).
- Check for Next Task: After each task is completed, review the FSD to identify the next highest-priority task or feature to implement.
- Do not create new files without first asking and justifying why.

## 2. Coding Standards
- Use modern Swift idioms: async/await, SwiftData, SwiftUI property wrappers.
- Prefer Apple-native tools; ask before adding third-party dependencies. As a general rule, we prefer native solutions.
- Write maintainable code: separate views, models, and services clearly and place them in the appropriate files.
- Comments: keep minimal, but explain non-obvious logic or trade-offs, or to flag a `TODO` or `FIXME`.

## 3. Decision Making
- For low-level details: decide and implement directly.
- For high-impact design or ambiguous FSD items: Stop and ask, briefly presenting options and trade-offs. When you do, use this format:   `QUESTION: [Brief, clear question] OPTIONS: 1. [Option A and its trade-offs] 2. [Option B and its trade-offs]`
 This applies only to ambiguous FSD items or architectural forks (e.g., choosing between two different data persistence strategies).


## 4. Quality
- Include basic error handling where appropriate.
- Debugging: Add temporary debugging `print()` statements to verify the execution of new features; remove them once confirmed.
- Completion: Once all items in the FSD have been implemented, state "FSD complete. Awaiting further instructions or new requirements."
*/


import SwiftUI
import Combine
import UIKit // Import UIKit for UIApplication
import OSLog // Import OSLog for appLog function
import UserNotifications // Import for notification handling
import MapKit // Import for Apple Maps integration
import CoreBluetooth // Import for BLE state checks

@main
struct BalloonHunterApp: App {
    @Environment(\.scenePhase) var scenePhase
    @StateObject var appServices: AppServices
    @StateObject var serviceCoordinator: ServiceCoordinator
    @StateObject var mapPresenter: MapPresenter
    @StateObject var appSettings: AppSettings
    @State private var animateLoading = false
    @State private var notificationDelegate: NotificationDelegate?
    
    init() {
        let services = AppServices()
        let coordinator = ServiceCoordinator(
            bleCommunicationService: services.bleCommunicationService,
            currentLocationService: services.currentLocationService,
            persistenceService: services.persistenceService,
            predictionCache: services.predictionCache,
            routingCache: services.routingCache,
            predictionService: services.predictionService,
            balloonPositionService: services.balloonPositionService,
            balloonTrackService: services.balloonTrackService,
            landingPointTrackingService: services.landingPointTrackingService,
            routeCalculationService: services.routeCalculationService,
            navigationService: services.navigationService,
            userSettings: services.userSettings
        )
        let presenter = MapPresenter(
            coordinator: coordinator,
            balloonTrackService: services.balloonTrackService,
            balloonPositionService: services.balloonPositionService,
            landingPointTrackingService: services.landingPointTrackingService,
            currentLocationService: services.currentLocationService,
            aprsService: services.aprsService,
            routeCalculationService: services.routeCalculationService,
            predictionService: services.predictionService
        )
        _appServices = StateObject(wrappedValue: services)
        _serviceCoordinator = StateObject(wrappedValue: coordinator)
        _mapPresenter = StateObject(wrappedValue: presenter)
        _appSettings = StateObject(wrappedValue: AppSettings())
    }

    // Simplified startup - ServiceCoordinator handles all timing
    
    var body: some Scene {
        WindowGroup {
            Group {
                if serviceCoordinator.isStartupComplete {
                    // Main app UI after startup complete
                    TrackingMapView()
                        .environmentObject(mapPresenter)
                        .environmentObject(appServices)
                        .environmentObject(appSettings)
                        .environmentObject(appServices.userSettings)
                        .environmentObject(serviceCoordinator)
                        .environmentObject(appServices.bleCommunicationService)
                        .environmentObject(appServices.balloonTrackService)
                        .environmentObject(appServices.landingPointTrackingService)
                        .environmentObject(appServices.balloonPositionService)
                        .environmentObject(serviceCoordinator.predictionService)
                        .environmentObject(appServices.routeCalculationService)
                } else {
                    // Logo and startup sequence
                    VStack {
                        Spacer()
                        
                        Image(systemName: "balloon.fill")
                            .font(.system(size: 80))
                            .foregroundColor(.blue)
                            .scaleEffect(animateLoading ? 1.1 : 1.0)
                            .animation(.easeInOut(duration: 1.5).repeatForever(autoreverses: true), value: animateLoading)
                        
                        Text("BalloonHunter")
                            .font(.largeTitle)
                            .fontWeight(.bold)
                            .foregroundColor(.white)
                            .padding(.top, 20)
                        
                        Text("Weather Balloon Tracking")
                            .font(.subheadline)
                            .foregroundColor(.gray)
                            .padding(.top, 5)
                        
                        Text("by HB9BLA")
                            .font(.caption)
                            .foregroundColor(.gray)
                            .padding(.top, 2)
                        
                        Spacer()
                        
                        // Progress indicator
                        VStack(spacing: 15) {
                            Text(serviceCoordinator.startupProgress)
                                .font(.subheadline)
                                .foregroundColor(.gray)
                            
                            HStack(spacing: 8) {
                                ForEach(0..<3) { index in
                                    Circle()
                                        .fill(Color.blue.opacity(0.6))
                                        .frame(width: 8, height: 8)
                                        .scaleEffect(animateLoading ? 1.3 : 0.7)
                                        .animation(
                                            Animation.easeInOut(duration: 0.6)
                                                .repeatForever()
                                                .delay(Double(index) * 0.2),
                                            value: animateLoading
                                        )
                                }
                            }
                        }
                        .padding(.bottom, 50)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color.black)
                    .onAppear {
                        animateLoading = true
                    }
                }
            }
            .onAppear {
                // Request notification permissions
                requestNotificationPermissions()

                // Set up notification handling
                setupNotificationHandling()

                // Initialize services
                appServices.initialize()
                serviceCoordinator.setAppSettings(appSettings)
                appServices.routeCalculationService.setAppSettings(appSettings)
                serviceCoordinator.initialize()

                // Start the 8-step startup sequence
                Task {
                    await serviceCoordinator.performCompleteStartupSequence()
                }
            }
        }
        .onChange(of: scenePhase) { oldScenePhase, newScenePhase in
            if newScenePhase == .inactive {
                // Save data on app close using the track service
                appServices.persistenceService.saveOnAppClose(
                    balloonTrackService: appServices.balloonTrackService,
                    landingPointTrackingService: appServices.landingPointTrackingService
                )
                appLog("BalloonHunterApp: App became inactive, saved data.", category: .lifecycle, level: .info)
            }

            if newScenePhase == .active && (oldScenePhase == .background || oldScenePhase == .inactive) {
                // App returned to foreground - refresh services and state
                appLog("BalloonHunterApp: App became active, refreshing services.", category: .lifecycle, level: .info)

                Task {
                    await handleForegroundResume()
                }
            }
        }
    }

    // MARK: - Foreground Resume

    private func handleForegroundResume() async {
        appLog("BalloonHunterApp: === Foreground Resume Sequence Started ===", category: .lifecycle, level: .info)

        // 1. Fetch current user location for map/routing
        appLog("BalloonHunterApp: Step 1 - Requesting current user location", category: .lifecycle, level: .info)
        appServices.currentLocationService.requestCurrentLocation()

        // 2. Trigger state machine evaluation
        // Note: Continuous BLE scanning handles reconnection automatically
        // State machine will check current conditions and transition if needed
        appLog("BalloonHunterApp: Step 2 - Triggering state machine evaluation", category: .lifecycle, level: .info)
        let previousState = appServices.balloonPositionService.currentState
        appServices.balloonPositionService.triggerStateEvaluation()

        // 4. If state didn't change, refresh current state to ensure services are active
        // This handles edge cases where timers/services need to be restarted
        if appServices.balloonPositionService.currentState == previousState {
            appLog("BalloonHunterApp: Step 4 - State unchanged (\(previousState)), refreshing service configuration", category: .lifecycle, level: .info)
            appServices.balloonPositionService.refreshCurrentState()
        } else {
            appLog("BalloonHunterApp: Step 4 - State changed: \(previousState) → \(appServices.balloonPositionService.currentState)", category: .lifecycle, level: .info)
        }

        // State machine now controls all service activation based on current state
        appLog("BalloonHunterApp: === Foreground Resume Complete - State Machine in Control ===", category: .lifecycle, level: .info)
    }

    // MARK: - Notification Handling

    private func requestNotificationPermissions() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { granted, error in
            if granted {
                appLog("BalloonHunterApp: Notification permissions granted", category: .lifecycle, level: .info)
            } else {
                appLog("BalloonHunterApp: Notification permissions denied", category: .lifecycle, level: .error)
            }
        }
    }

    private func setupNotificationHandling() {
        let center = UNUserNotificationCenter.current()
        notificationDelegate = NotificationDelegate()
        center.delegate = notificationDelegate
    }

}

// MARK: - Notification Delegate

class NotificationDelegate: NSObject, UNUserNotificationCenterDelegate {

    // Handle notification tap
    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse, withCompletionHandler completionHandler: @escaping () -> Void) {

        let userInfo = response.notification.request.content.userInfo

        // User tapped the notification - open Apple Maps with new destination
        if let latitude = userInfo["latitude"] as? Double,
           let longitude = userInfo["longitude"] as? Double {

            let newDestination = CLLocationCoordinate2D(latitude: latitude, longitude: longitude)

            DispatchQueue.main.async {
                // Open Apple Maps with new destination
                let placemark = MKPlacemark(coordinate: newDestination)
                let mapItem = MKMapItem(placemark: placemark)
                mapItem.name = "Updated Balloon Landing Site"

                // Use persisted transport mode from UserDefaults
                let persistedTransportMode = AppSettings.getPersistedTransportMode()
                let directionsMode: String
                switch persistedTransportMode {
                case .car:
                    directionsMode = MKLaunchOptionsDirectionsModeDriving
                case .bike:
                    if #available(iOS 14.0, *) {
                        directionsMode = MKLaunchOptionsDirectionsModeCycling
                    } else {
                        directionsMode = MKLaunchOptionsDirectionsModeWalking // Fallback for older iOS
                    }
                }

                let launchOptions = [
                    MKLaunchOptionsDirectionsModeKey: directionsMode
                ]

                mapItem.openInMaps(launchOptions: launchOptions)

                appLog("BalloonHunterApp: Opened Apple Maps from notification", category: .lifecycle, level: .info)
            }
        }

        completionHandler()
    }

    // Show notification even when app is in foreground
    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification, withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound])
    }
}
