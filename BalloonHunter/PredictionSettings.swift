// PredictionSettings.swift
// Shared settings for prediction parameters (burstAltitude, ascentRate, descentRate)

import Foundation
import SwiftUI

class PredictionSettings: ObservableObject {
    @AppStorage("burstAltitude") var burstAltitude: Double = 35000
    @AppStorage("ascentRate") var ascentRate: Double = 5
    @AppStorage("descentRate") var descentRate: Double = 5

    static let shared = PredictionSettings()
}
