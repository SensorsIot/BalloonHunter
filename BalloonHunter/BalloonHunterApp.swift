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
    @StateObject var appServices: AppServices
    @StateObject var serviceCoordinator: ServiceCoordinator
    @StateObject var appSettings = AppSettings()
    @State private var animateLoading = false
    
    init() {
        let services = AppServices()
        _appServices = StateObject(wrappedValue: services)
        _serviceCoordinator = StateObject(wrappedValue: ServiceCoordinator(
            bleCommunicationService: services.bleCommunicationService,
            currentLocationService: services.currentLocationService,
            persistenceService: services.persistenceService,
            predictionCache: services.predictionCache,
            routingCache: services.routingCache,
            balloonPositionService: services.balloonPositionService,
            balloonTrackService: services.balloonTrackService
        ))
        _appSettings = StateObject(wrappedValue: AppSettings())
    }

    // Simplified startup - ServiceCoordinator handles all timing
    
    var body: some Scene {
        WindowGroup {
            Group {
                if serviceCoordinator.isStartupComplete {
                    // Main app UI after startup complete
                    TrackingMapView()
                        .environmentObject(appServices)
                        .environmentObject(appSettings)
                        .environmentObject(appServices.userSettings)
                        .environmentObject(serviceCoordinator)
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
                // Initialize services
                appServices.initialize()
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
                serviceCoordinator.saveDataOnAppClose()
                appLog("BalloonHunterApp: App became inactive, saved data.", category: .lifecycle, level: .info)
            }
        }
    }
}
