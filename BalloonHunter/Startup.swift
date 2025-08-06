import Foundation
import Combine

/// Centralizes all BLE and app startup state and actions (for use in ContentView)
class StartupManager: ObservableObject {
    @Published var deviceReady = false
    @Published var pendingSettingsRequest = false
    @Published var showBLEError = false
    @Published var showMenu = false

    private var cancellables: Set<AnyCancellable> = []

    init() {
        BLEManager.shared.$receivedText
            .receive(on: DispatchQueue.main)
            .sink { [weak self] receivedText in
                guard let self = self else { return }
                print("[StartupManager] receivedText changed: \(receivedText.prefix(80))")
                if !receivedText.isEmpty && !self.deviceReady {
                    self.deviceReady = true
                    print("[StartupManager] deviceReady set to true (first message received)")

                    // Issue '?' command right after device is ready
                    BLEManager.shared.sendCommand("?")
                    print("[StartupManager] Automatically sent '?' command after device became ready")
                    self.pendingSettingsRequest = true
                }
                if self.pendingSettingsRequest, receivedText.contains("\n"), receivedText.components(separatedBy: "\n").contains(where: { $0.hasSuffix("/o") }) {
                    print("[StartupManager] Settings response detected, clearing pending.")
                    self.pendingSettingsRequest = false
                }
            }
            .store(in: &cancellables)
    }
    
    func reset() {
        deviceReady = false
        pendingSettingsRequest = false
        showBLEError = false
        showMenu = false
    }
}
