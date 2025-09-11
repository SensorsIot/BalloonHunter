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
    @StateObject var domainModel = DomainModel()
    @StateObject var balloonTracker: BalloonTracker
    @StateObject var appSettings = AppSettings()
    @State private var locationReady = false
    @State private var animateLoading = false
    @State private var minimumDisplayTimeElapsed = false
    
    init() {
        let model = DomainModel()
        _domainModel = StateObject(wrappedValue: model)
        _balloonTracker = StateObject(wrappedValue: BalloonTracker(domainModel: model))
        _appSettings = StateObject(wrappedValue: AppSettings())
    }

    private func checkAndHideLogo() {
        // Logo will hide automatically when both locationReady AND minimumDisplayTimeElapsed are true
        // due to the condition: if !locationReady || !minimumDisplayTimeElapsed
        if locationReady && minimumDisplayTimeElapsed {
            appLog("BalloonHunterApp: Both location and minimum display time ready - hiding logo.", category: .lifecycle, level: .info)
        }
    }
    
    var body: some Scene {
        WindowGroup {
            ZStack {
                // TrackingMapView always present (building in background)
                TrackingMapView()
                    .environmentObject(balloonTracker.mapState)
                    .environmentObject(appSettings)
                    .environmentObject(balloonTracker.userSettings)
                    .environmentObject(balloonTracker)
                    .environmentObject(domainModel)
                    .onAppear {
                        // Initialize simplified architecture
                        balloonTracker.initialize()
                    }
                
                // Logo overlay (shown until location ready AND minimum 2 seconds elapsed)
                if !locationReady || !minimumDisplayTimeElapsed {
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
                        
                        // Subtle progress indicator
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
                        .padding(.bottom, 50)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color.black)
                    .onAppear {
                        animateLoading = true
                        // Start 2-second minimum display timer (non-blocking)
                        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
                            minimumDisplayTimeElapsed = true
                            checkAndHideLogo()
                        }
                    }
                }
                
                // Invisible startup view running in background
                StartupView()
                    .environmentObject(balloonTracker)
                    .environmentObject(balloonTracker.userSettings)
                    .opacity(0)
            }
            .onReceive(NotificationCenter.default.publisher(for: .locationReady)) { _ in
                appLog("BalloonHunterApp: Received locationReady notification.", category: .lifecycle, level: .info)
                locationReady = true
                checkAndHideLogo()
            }
        }
        .onChange(of: scenePhase) { oldScenePhase, newScenePhase in
            if newScenePhase == .inactive {
                // Save data on app close using the track service
                balloonTracker.persistenceService.saveOnAppClose(balloonTrackService: balloonTracker.balloonTrackService)
                appLog("BalloonHunterApp: App became inactive, saved data.", category: .lifecycle, level: .info)
            }
        }
    }
}
