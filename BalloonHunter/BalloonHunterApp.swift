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
            // Use CurrentLocationService to get heading information for map orientation
            let locationService = CurrentLocationService()
            MapView(viewModel: mainViewModel, locationService: locationService)
                .environmentObject(predictionInfo)
        }
    }
}
