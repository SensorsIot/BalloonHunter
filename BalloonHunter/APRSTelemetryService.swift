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
    @Published var telemetryAvailabilityState: Bool = false
    @Published var latestTelemetry: TelemetryData? = nil
    @Published var connectionStatus: ConnectionStatus = .disconnected
    @Published var lastTelemetryUpdateTime: Date? = nil
    @Published var isHealthy: Bool = false

    // APRS-specific published state
    @Published var currentStationId: String = "06610" // Default to Payerne
    @Published var lastSondeSerial: String? = nil
    @Published var pollCadence: TimeInterval = 60.0
    @Published var apiCallCount: Int = 0
    @Published var lastApiError: String? = nil

    // Sonde name mismatch tracking (display only)
    @Published var bleSerialName: String? = nil
    @Published var aprsSerialName: String? = nil

    // Compatible telemetry stream with BLE service
    let telemetryData = PassthroughSubject<TelemetryData, Never>()

    // MARK: - Private State
    private var pollingTimer: Timer?
    private var isPollingActive: Bool = false
    private var isBLETelemetryHealthy: Bool = false
    private var cancellables = Set<AnyCancellable>()
    private let session = URLSession.shared

    // MARK: - Dependencies
    private let userSettings: UserSettings

    // MARK: - Constants
    private static let sondeHubBaseURL = "https://api.v2.sondehub.org"
    private static let fastPollInterval: TimeInterval = 15.0
    private static let healthCheckInterval: TimeInterval = 60.0
    private static let apiTimeout: TimeInterval = 30.0

    init(userSettings: UserSettings) {
        self.userSettings = userSettings

        // Initialize station ID from user settings
        currentStationId = userSettings.stationId

        appLog("APRSTelemetryService: Initialized with station ID \(currentStationId)", category: .service, level: .info)

        // Set initial connection status
        connectionStatus = .disconnected
        isHealthy = false

        setupPolling()

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

    /// Notify service about BLE telemetry health status
    func updateBLETelemetryHealth(_ isHealthy: Bool) {
        let wasHealthy = isBLETelemetryHealthy
        isBLETelemetryHealthy = isHealthy

        if !wasHealthy && isHealthy {
            // BLE telemetry resumed - stop APRS polling
            stopPolling()

            // Switch to health check mode
            pollCadence = Self.healthCheckInterval
            if !isPollingActive {
                startHealthCheckMode()
            }
        } else if wasHealthy && !isHealthy {
            // BLE telemetry failed - start APRS polling
            startPolling()
        } else if !wasHealthy && !isHealthy {
            // Initial state or continued unhealthy state - ensure APRS polling is active
            if !isPollingActive {
                startPolling()
            }
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

    private func setupPolling() {
        // Start in health check mode
        pollCadence = Self.healthCheckInterval
        startHealthCheckMode()
    }

    private func startHealthCheckMode() {
        guard !isPollingActive else { return }

        appLog("APRSTelemetryService: Starting health check mode (every \(Int(Self.healthCheckInterval))s)", category: .service, level: .debug)

        // Health check timer
        pollingTimer = Timer.scheduledTimer(withTimeInterval: Self.healthCheckInterval, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                await self?.performHealthCheck()
            }
        }
    }

    private func startPollingTimer() {
        pollingTimer?.invalidate()
        pollingTimer = nil

        pollingTimer = Timer.scheduledTimer(withTimeInterval: pollCadence, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                await self?.fetchLatestTelemetry()
            }
        }
    }

    private func performHealthCheck() async {
        appLog("APRSTelemetryService: Performing health check for station \(currentStationId)", category: .service, level: .debug)

        do {
            let _ = try await fetchSiteData()
            if !isHealthy {
                isHealthy = true
                appLog("APRSTelemetryService: Health check passed", category: .service, level: .debug)
            }
        } catch {
            if isHealthy {
                isHealthy = false
                lastApiError = error.localizedDescription
                appLog("APRSTelemetryService: Health check failed: \(error.localizedDescription)", category: .service, level: .error)
            }
        }
    }

    private func fetchLatestTelemetry() async {
        appLog("APRSTelemetryService: Fetching telemetry for station \(currentStationId)", category: .service, level: .debug)

        do {
            let siteResponse = try await fetchSiteData()

            // Find the most recent sonde by timestamp
            guard let latestSonde = findLatestSonde(from: Array(siteResponse.values)) else {
                appLog("APRSTelemetryService: No sondes found for station \(currentStationId)", category: .service, level: .info)
                telemetryAvailabilityState = false
                return
            }

            // Convert to TelemetryData and publish
            let telemetryData = try convertToTelemetryData(latestSonde)

            // Update state
            latestTelemetry = telemetryData
            lastTelemetryUpdateTime = Date()
            telemetryAvailabilityState = true
            lastSondeSerial = latestSonde.serial
            connectionStatus = .connected
            isHealthy = true
            lastApiError = nil

            // Publish through telemetry stream (compatible with BLE service)
            self.telemetryData.send(telemetryData)

            appLog("APRSTelemetryService: Published telemetry for sonde \(latestSonde.serial) at \(String(format: "%.5f, %.5f", latestSonde.lat, latestSonde.lon))", category: .service, level: .info)

        } catch {
            appLog("APRSTelemetryService: Failed to fetch telemetry: \(error.localizedDescription)", category: .service, level: .error)

            telemetryAvailabilityState = false
            connectionStatus = .failed(error.localizedDescription)
            lastApiError = error.localizedDescription
            isHealthy = false
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
        var telemetry = TelemetryData()

        // Basic identification
        telemetry.sondeName = sonde.serial
        telemetry.probeType = sonde.type.uppercased()
        telemetry.frequency = sonde.frequency

        // Position and motion
        telemetry.latitude = sonde.lat
        telemetry.longitude = sonde.lon
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
        }
    }
}

