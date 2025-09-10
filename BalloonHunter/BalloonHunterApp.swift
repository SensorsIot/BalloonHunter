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

@main
struct BalloonHunterApp: App {
    @Environment(\.scenePhase) var scenePhase
    @StateObject var serviceManager = ServiceManager()
    @StateObject var appSettings = AppSettings()
    @StateObject var userSettings = UserSettings()
    @State private var startupCompleted = false

    var body: some Scene {
        WindowGroup {
            if startupCompleted {
                TrackingMapView()
                    .environmentObject(serviceManager.mapState)
                    .environmentObject(appSettings)
                    .environmentObject(userSettings)
                    .environmentObject(serviceManager)
                    .onAppear {
                        serviceManager.initializeEventDrivenFlow()
                    }
            } else {
                StartupView()
                    .environmentObject(serviceManager)
                    .environmentObject(userSettings)
                    .onReceive(NotificationCenter.default.publisher(for: .startupCompleted)) { _ in
                        appLog("BalloonHunterApp: Received startupCompleted notification.", category: .lifecycle, level: .info)
                        startupCompleted = true
                    }
            }
        }
        .onChange(of: scenePhase) { oldScenePhase, newScenePhase in
            if newScenePhase == .inactive {
                serviceManager.persistenceService.saveOnAppClose(balloonTrackService: serviceManager.balloonTrackService)
                appLog("BalloonHunterApp: App became inactive, saved data.", category: .lifecycle, level: .info)
            }
        }
    }
}
