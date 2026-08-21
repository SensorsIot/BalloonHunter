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
            .sheet(isPresented: $serviceCoordinator.showSondeSelectionPopup) {
                SondeSelectionSheet(
                    availableSondes: serviceCoordinator.availableSondesForSelection,
                    selectedSondeSerial: $serviceCoordinator.selectedSondeSerial,
                    countdown: serviceCoordinator.sondeSelectionCountdown,
                    isRefreshing: serviceCoordinator.isRefreshingSondeList,
                    onConfirm: { serviceCoordinator.confirmSondeSelection() },
                    onSkip: { serviceCoordinator.skipSondeSelection() },
                    onStartEditing: { serviceCoordinator.userDidStartEditingSondeName() }
                )
                .presentationDetents([.large])
                .interactiveDismissDisabled()
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

            if newScenePhase == .background {
                // Foreground-only: stop continuous hunter-position tracking so there
                // is no background-location footprint.
                appServices.currentLocationService.stopForegroundTracking()
            }

            if newScenePhase == .active && (oldScenePhase == .background || oldScenePhase == .inactive) {
                // App returned to foreground - refresh services and state
                appLog("BalloonHunterApp: App became active, refreshing services.", category: .lifecycle, level: .info)
                // Resume continuous hunter-position tracking.
                appServices.currentLocationService.startForegroundTracking()

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
        let currentState = appServices.balloonPositionService.currentState

        // 3. Check CURRENT state after evaluation - if flying, fill track gaps
        // This ensures we make decisions based on reality NOW, not what happened before backgrounding
        if currentState == .liveBLEFlying || currentState == .aprsFlying {
            appLog("BalloonHunterApp: Step 3 - Currently flying (\(currentState)) - triggering APRS fetch with forced track-based landing detection", category: .lifecycle, level: .info)
            await MainActor.run {
                appServices.balloonTrackService.fillTrackGapsFromAPRS(forceDetection: true)
            }
        } else {
            appLog("BalloonHunterApp: Step 3 - Not flying (\(currentState)) - skipping forced detection", category: .lifecycle, level: .info)
        }

        // 4. If state didn't change, refresh current state to ensure services are active
        // This handles edge cases where timers/services need to be restarted
        if currentState == previousState {
            appLog("BalloonHunterApp: Step 4 - State unchanged (\(previousState)), refreshing service configuration", category: .lifecycle, level: .info)
            appServices.balloonPositionService.refreshCurrentState()
        } else {
            appLog("BalloonHunterApp: Step 4 - State changed: \(previousState) → \(currentState)", category: .lifecycle, level: .info)
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

// MARK: - Sonde Selection Sheet

struct SondeSelectionSheet: View {
    let availableSondes: [SondeHubSondeData]
    @Binding var selectedSondeSerial: String?
    let countdown: Int
    var isRefreshing: Bool = false
    let onConfirm: () -> Void
    let onSkip: () -> Void
    let onStartEditing: () -> Void

    @State private var manualSerial: String = ""
    @FocusState private var isTextFieldFocused: Bool

    var body: some View {
        NavigationView {
            VStack(spacing: 16) {
                // Header
                VStack(spacing: 8) {
                    Image(systemName: "antenna.radiowaves.left.and.right")
                        .font(.system(size: 40))
                        .foregroundColor(.blue)

                    Text("Select Sonde")
                        .font(.title2)
                        .fontWeight(.bold)

                    if isRefreshing {
                        HStack(spacing: 6) {
                            ProgressView().scaleEffect(0.7)
                            Text("Updating from SondeHub…")
                        }
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                    } else {
                        Text("\(availableSondes.count) sonde\(availableSondes.count == 1 ? "" : "s") available (last 24h)")
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                    }
                }
                .padding(.top, 16)

                // Sonde List
                if !availableSondes.isEmpty {
                    List(availableSondes, id: \.serial) { sonde in
                        SondeRowView(
                            sonde: sonde,
                            isSelected: selectedSondeSerial == sonde.serial
                        )
                        .contentShape(Rectangle())
                        .onTapGesture {
                            selectedSondeSerial = sonde.serial
                            manualSerial = ""
                            onStartEditing()
                        }
                    }
                    .listStyle(.plain)
                    .frame(maxHeight: 250)
                } else {
                    Text("No sondes found")
                        .foregroundColor(.secondary)
                        .padding()
                }

                // Manual entry
                VStack(alignment: .leading, spacing: 4) {
                    Text("Or enter serial manually:")
                        .font(.caption)
                        .foregroundColor(.secondary)

                    TextField("e.g., V3240531", text: $manualSerial)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(.body, design: .monospaced))
                        .autocapitalization(.allCharacters)
                        .disableAutocorrection(true)
                        .focused($isTextFieldFocused)
                        .onChange(of: manualSerial) { _, newValue in
                            if !newValue.isEmpty {
                                selectedSondeSerial = newValue.uppercased()
                                onStartEditing()
                            }
                        }
                        .onChange(of: isTextFieldFocused) { _, isFocused in
                            if isFocused {
                                onStartEditing()
                            }
                        }
                }
                .padding(.horizontal, 20)

                // Countdown
                if countdown > 0 {
                    Text("Auto-continuing in \(countdown)s...")
                        .font(.subheadline)
                        .foregroundColor(.orange)
                }

                // Buttons
                VStack(spacing: 12) {
                    Button(action: onConfirm) {
                        Text("Use Selected")
                            .font(.headline)
                            .frame(maxWidth: .infinity)
                            .padding()
                            .background(selectedSondeSerial != nil ? Color.blue : Color.gray)
                            .foregroundColor(.white)
                            .cornerRadius(12)
                    }
                    .disabled(selectedSondeSerial == nil)

                    Button(action: onSkip) {
                        Text("Skip")
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                    }
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 20)
            }
        }
    }
}

// MARK: - Sonde Row View

struct SondeRowView: View {
    let sonde: SondeHubSondeData
    let isSelected: Bool

    var body: some View {
        HStack(spacing: 12) {
            // Selection indicator
            Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                .foregroundColor(isSelected ? .blue : .gray)
                .font(.title3)

            // Sonde info
            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text(sonde.serial)
                        .font(.system(.body, design: .monospaced))
                        .fontWeight(.semibold)

                    Text(sonde.type)
                        .font(.caption)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.blue.opacity(0.2))
                        .cornerRadius(4)
                }

                HStack(spacing: 8) {
                    // Time
                    Label(formatSondeTime(sonde.datetime), systemImage: "clock")
                        .font(.caption)
                        .foregroundColor(.secondary)

                    // Altitude
                    Label("\(Int(sonde.alt))m", systemImage: "arrow.up")
                        .font(.caption)
                        .foregroundColor(.secondary)

                    // Frequency
                    if sonde.effectiveFrequency > 0 {
                        Text(String(format: "%.2f", sonde.effectiveFrequency))
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
            }

            Spacer()
        }
        .padding(.vertical, 4)
        .background(isSelected ? Color.blue.opacity(0.1) : Color.clear)
        .cornerRadius(8)
    }

    private func formatSondeTime(_ dateString: String) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]

        var date: Date?
        date = formatter.date(from: dateString)
        if date == nil {
            formatter.formatOptions = [.withInternetDateTime]
            date = formatter.date(from: dateString)
        }

        guard let sondeDate = date else { return dateString }

        let calendar = Calendar.current

        if calendar.isDateInToday(sondeDate) {
            let timeFormatter = DateFormatter()
            timeFormatter.dateFormat = "HH:mm"
            return timeFormatter.string(from: sondeDate)
        } else if calendar.isDateInYesterday(sondeDate) {
            let timeFormatter = DateFormatter()
            timeFormatter.dateFormat = "HH:mm"
            return "Yesterday \(timeFormatter.string(from: sondeDate))"
        } else {
            let dateFormatter = DateFormatter()
            dateFormatter.dateFormat = "MMM d HH:mm"
            return dateFormatter.string(from: sondeDate)
        }
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
