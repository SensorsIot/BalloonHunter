//
//  BalloonHunterApp.swift
//  BalloonHunter
//
//  Created by Andreas Spiess on 26.07.2025.
//

import SwiftUI

@main
struct BalloonHunterApp: App {
    @StateObject private var mainViewModel = MainViewModel()
    // Explicitly specify module to resolve ambiguity
    @StateObject private var predictionInfo = PredictionInfo()
    
    var body: some Scene {
        WindowGroup {
            let locationManager = LocationManager()
            MapView(viewModel: mainViewModel, locationManager: locationManager)
                .environmentObject(predictionInfo)
        }
    }
}
