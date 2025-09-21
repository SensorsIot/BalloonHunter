import Foundation
import Combine
import OSLog

// MARK: - APRS Data Models

struct SondeHubSondeData: Codable {
    let serial: String
    let type: String
    let frequency: Double
    let datetime: String
    let lat: Double
    let lon: Double
    let alt: Double
    let vel_h: Double
    let vel_v: Double
    let temp: Double?
    let humidity: Double?
    let pressure: Double?
}

// Site response is a dictionary with serial numbers as keys and sonde data as values
typealias SondeHubSiteResponse = [String: SondeHubSondeData]

// MARK: - APRS Telemetry Service

@MainActor
final class APRSTelemetryService: ObservableObject {

    // MARK: - Published Properties (compatible with BLE service)
    @Published var latestTelemetry: TelemetryData? = nil
    @Published var connectionStatus: ConnectionStatus = .disconnected
    var lastTelemetryUpdateTime: Date? = nil

    // APRS-specific published state
    var currentStationId: String = "06610" // Default to Payerne
    var lastSondeSerial: String? = nil
    var pollCadence: TimeInterval = 60.0
    private var apiCallCount: Int = 0
    var lastApiError: String? = nil

    // Sonde name mismatch tracking (display only)
    @Published var bleSerialName: String? = nil
    @Published var aprsSerialName: String? = nil

    // Compatible telemetry stream with BLE service
    let telemetryData = PassthroughSubject<TelemetryData, Never>()

    // MARK: - Private State
    private var pollingTimer: Timer?
    private var isPollingActive: Bool = false
    private var cancellables = Set<AnyCancellable>()
    private let session = URLSession.shared

    // MARK: - Dependencies
    private let userSettings: UserSettings

    // MARK: - Constants
    private static let sondeHubBaseURL = "https://api.v2.sondehub.org"
    private static let fastPollInterval: TimeInterval = 15.0
    private static let landedThreshold: TimeInterval = 120.0
    private static let landedConfirmationWindow: TimeInterval = 1_800.0
    private static let landedConfirmationInterval: TimeInterval = 300.0
    private static let apiTimeout: TimeInterval = 30.0

    init(userSettings: UserSettings) {
        self.userSettings = userSettings

        // Initialize station ID from user settings
        currentStationId = userSettings.stationId

        appLog("APRSTelemetryService: Initialized with station ID \(currentStationId)", category: .service, level: .info)

        // Set initial connection status
        connectionStatus = .disconnected

        // Subscribe to station ID changes
        userSettings.$stationId
            .receive(on: DispatchQueue.main)
            .sink { [weak self] newStationId in
                self?.updateStationId(newStationId)
            }
            .store(in: &cancellables)
    }

    // MARK: - Public Interface

    /// Start APRS telemetry polling (called when BLE telemetry becomes stale)
    func startPolling() {
        guard !isPollingActive else {
            appLog("APRSTelemetryService: Polling already active, ignoring start request", category: .service, level: .debug)
            return
        }

        isPollingActive = true
        pollCadence = Self.fastPollInterval
        connectionStatus = .connecting

        appLog("APRSTelemetryService: Starting APRS polling every \(Int(pollCadence))s for station \(currentStationId)", category: .service, level: .info)

        // Immediate fetch + start timer
        Task {
            await fetchLatestTelemetry()
        }
        startPollingTimer()
    }

    /// Stop APRS telemetry polling (called when BLE telemetry resumes)
    func stopPolling() {
        guard isPollingActive else {
            appLog("APRSTelemetryService: Polling not active, ignoring stop request", category: .service, level: .debug)
            return
        }

        isPollingActive = false
        connectionStatus = .disconnected
        pollingTimer?.invalidate()
        pollingTimer = nil

        appLog("APRSTelemetryService: Stopped APRS polling (BLE telemetry resumed)", category: .service, level: .info)
    }

    /// Update station ID and restart polling if active
    func updateStationId(_ newStationId: String) {
        guard newStationId != currentStationId else { return }

        let wasPolling = isPollingActive

        if wasPolling {
            stopPolling()
        }

        currentStationId = newStationId
        lastSondeSerial = nil

        appLog("APRSTelemetryService: Station ID changed to \(newStationId)", category: .service, level: .info)

        if wasPolling {
            startPolling()
        }
    }


    /// Enable APRS polling (called by state machine)
    func enablePolling() {
        if !isPollingActive {
            startPolling()
        }
    }

    /// Disable APRS polling (called by state machine)
    func disablePolling() {
        if isPollingActive {
            stopPolling()
        }
    }

    /// Called during startup to prime APRS data (Step 2 of startup sequence)
    func primeStartupData() async {
        appLog("APRSTelemetryService: Priming startup data for station \(currentStationId)", category: .service, level: .info)

        do {
            let siteResponse = try await fetchSiteData()

            guard let latestSonde = findLatestSonde(from: Array(siteResponse.values)) else {
                appLog("APRSTelemetryService: No sondes found for startup priming", category: .service, level: .info)
                return
            }

            // Store the APRS serial for mismatch detection
            aprsSerialName = latestSonde.serial
            lastSondeSerial = latestSonde.serial

            appLog("APRSTelemetryService: Startup priming complete - found sonde \(latestSonde.serial)", category: .service, level: .info)

        } catch {
            appLog("APRSTelemetryService: Startup priming failed: \(error.localizedDescription)", category: .service, level: .error)
        }
    }

    /// Update BLE sonde name for display purposes
    func updateBLESondeName(_ sondeName: String) {
        bleSerialName = sondeName

        // Log mismatch for debugging (no resolution needed)
        if let aprsSerial = aprsSerialName, aprsSerial != sondeName {
            appLog("APRSTelemetryService: Sonde name difference - BLE: \(sondeName), APRS: \(aprsSerial)", category: .service, level: .info)
        }
    }

    // MARK: - Private Implementation

    private func startPollingTimer() {
        pollingTimer?.invalidate()
        pollingTimer = nil

        pollingTimer = Timer.scheduledTimer(withTimeInterval: pollCadence, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                await self?.fetchLatestTelemetry()
            }
        }
    }

    private func updatePollingInterval(_ interval: TimeInterval) {
        guard pollCadence != interval else { return }
        pollCadence = interval
        if isPollingActive {
            appLog("APRSTelemetryService: Adjusting polling interval to \(Int(interval))s", category: .service, level: .debug)
            startPollingTimer()
        }
    }

    private func adjustPollingCadence(for telemetry: TelemetryData) {
        guard isPollingActive else { return }
        let age = Date().timeIntervalSince(telemetry.timestamp)

        if age <= Self.landedThreshold {
            updatePollingInterval(Self.fastPollInterval)
        } else if age <= Self.landedConfirmationWindow {
            updatePollingInterval(Self.landedConfirmationInterval)
        } else {
            appLog("APRSTelemetryService: APRS data older than 30 minutes — stopping polling", category: .service, level: .info)
            stopPolling()
        }
    }

    private func fetchLatestTelemetry() async {
        appLog("APRSTelemetryService: Fetching telemetry for station \(currentStationId)", category: .service, level: .debug)

        do {
            let siteResponse = try await fetchSiteData()

            // Find the most recent sonde by timestamp
            guard let latestSonde = findLatestSonde(from: Array(siteResponse.values)) else {
                appLog("APRSTelemetryService: No sondes found for station \(currentStationId)", category: .service, level: .info)
                return
            }

            // Convert to TelemetryData and publish
            let telemetryData = try convertToTelemetryData(latestSonde)

            // Update state
            latestTelemetry = telemetryData
            lastTelemetryUpdateTime = Date()
            lastSondeSerial = latestSonde.serial
            connectionStatus = .connected
            lastApiError = nil

            // Publish through telemetry stream (compatible with BLE service)
            self.telemetryData.send(telemetryData)

            appLog("APRSTelemetryService: Published telemetry for sonde \(latestSonde.serial) at \(String(format: "%.5f, %.5f", latestSonde.lat, latestSonde.lon))", category: .service, level: .info)

            adjustPollingCadence(for: telemetryData)

        } catch APRSError.invalidPayload {
            appLog("APRSTelemetryService: Ignoring incomplete telemetry payload", category: .service, level: .info)
        } catch {
            appLog("APRSTelemetryService: Failed to fetch telemetry: \(error.localizedDescription)", category: .service, level: .error)

            connectionStatus = .failed(error.localizedDescription)
            lastApiError = error.localizedDescription
        }
    }

    private func fetchSiteData() async throws -> SondeHubSiteResponse {
        apiCallCount += 1

        let url = URL(string: "\(Self.sondeHubBaseURL)/sondes/site/\(currentStationId)")!
        var request = URLRequest(url: url)
        request.timeoutInterval = Self.apiTimeout
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("BalloonHunter iOS App", forHTTPHeaderField: "User-Agent")

        appLog("APRSTelemetryService: GET \(url.absoluteString)", category: .service, level: .debug)

        let (data, response) = try await session.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw APRSError.invalidResponse
        }

        guard httpResponse.statusCode == 200 else {
            throw APRSError.httpError(httpResponse.statusCode)
        }

        // Check if we received empty data
        if data.isEmpty {
            appLog("APRSTelemetryService: Received empty data from API", category: .service, level: .error)
            throw APRSError.noData
        }

        do {
            let siteResponse = try JSONDecoder().decode(SondeHubSiteResponse.self, from: data)

            // Log essential telemetry data only (debug level)
            let sondesSummary = siteResponse.map { (serial, data) in
                "\(serial): lat=\(String(format: "%.5f", data.lat)), lon=\(String(format: "%.5f", data.lon)), alt=\(String(format: "%.0f", data.alt))m, v_v=\(String(format: "%.1f", data.vel_v))m/s, v_h=\(String(format: "%.1f", data.vel_h))m/s, time=\(data.datetime)"
            }.joined(separator: " | ")
            appLog("APRSTelemetryService: Telemetry data: \(sondesSummary)", category: .service, level: .debug)
            appLog("APRSTelemetryService: Received data for \(siteResponse.count) sondes", category: .service, level: .debug)

            return siteResponse
        } catch {
            appLog("APRSTelemetryService: JSON decoding failed: \(error)", category: .service, level: .error)
            throw APRSError.decodingError(error.localizedDescription)
        }
    }

    private func findLatestSonde(from sondes: [SondeHubSondeData]) -> SondeHubSondeData? {
        // Find the sonde with the most recent timestamp
        return sondes.max { sonde1, sonde2 in
            let date1 = parseISO8601Date(sonde1.datetime) ?? Date.distantPast
            let date2 = parseISO8601Date(sonde2.datetime) ?? Date.distantPast
            return date1 < date2
        }
    }

    private func convertToTelemetryData(_ sonde: SondeHubSondeData) throws -> TelemetryData {
        let trimmedSerial = sonde.serial.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedType = sonde.type.trimmingCharacters(in: .whitespacesAndNewlines)
        let frequency = (sonde.frequency * 100).rounded() / 100.0
        let latitude = sonde.lat
        let longitude = sonde.lon

        let coordinatesValid = latitude.isFinite && longitude.isFinite && abs(latitude) <= 90 && abs(longitude) <= 180 && !(latitude == 0 && longitude == 0)

        guard !trimmedSerial.isEmpty,
              !trimmedType.isEmpty,
              frequency > 0,
              coordinatesValid else {
            throw APRSError.invalidPayload
        }

        var telemetry = TelemetryData()

        // Basic identification
        telemetry.sondeName = trimmedSerial
        telemetry.probeType = trimmedType.uppercased()
        telemetry.frequency = frequency

        // Position and motion
        telemetry.latitude = latitude
        telemetry.longitude = longitude
        telemetry.altitude = sonde.alt
        telemetry.horizontalSpeed = sonde.vel_h
        telemetry.verticalSpeed = sonde.vel_v

        // Environmental data (optional)
        telemetry.temperature = sonde.temp ?? 0.0
        telemetry.humidity = sonde.humidity ?? 0.0
        telemetry.pressure = sonde.pressure ?? 0.0

        // APRS data doesn't have these BLE-specific fields, set reasonable defaults
        telemetry.batteryVoltage = 0.0
        telemetry.batteryPercentage = 0
        telemetry.signalStrength = 0
        telemetry.buzmute = false
        telemetry.afcFrequency = 0
        telemetry.burstKillerEnabled = false
        telemetry.burstKillerTime = 0
        telemetry.softwareVersion = "APRS"

        // Timestamp
        if let timestamp = parseISO8601Date(sonde.datetime) {
            telemetry.timestamp = timestamp
        } else {
            telemetry.timestamp = Date()
            appLog("APRSTelemetryService: Failed to parse timestamp '\(sonde.datetime)', using current time", category: .service, level: .error)
        }

        return telemetry
    }

    private func parseISO8601Date(_ dateString: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]

        if let date = formatter.date(from: dateString) {
            return date
        }

        // Fallback without fractional seconds
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: dateString)
    }

    deinit {
        pollingTimer?.invalidate()
        pollingTimer = nil
    }
}

// MARK: - APRS Errors

enum APRSError: Error, LocalizedError {
    case invalidResponse
    case httpError(Int)
    case noData
    case networkUnavailable(String)
    case decodingError(String)
    case noSondesFound
    case invalidPayload

    var errorDescription: String? {
        switch self {
        case .invalidResponse:
            return "Invalid response from SondeHub API"
        case .httpError(let code):
            return "HTTP error \(code)"
        case .noData:
            return "No data received from SondeHub"
        case .networkUnavailable(let reason):
            return "Network unavailable: \(reason)"
        case .decodingError(let description):
            return "JSON decoding failed: \(description)"
        case .noSondesFound:
            return "No sondes found for station"
        case .invalidPayload:
            return "Received incomplete telemetry payload"
        }
    }
}
