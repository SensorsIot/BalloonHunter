import Foundation
import Combine
import OSLog

// MARK: - Internal APRS Parsing Structure
// Pure three-channel architecture - no legacy TelemetryData

// MARK: - APRS Data Models

struct SondeHubSondeData: Codable {
    let serial: String
    let type: String
    let frequency: Double?
    let tx_frequency: Double?
    let datetime: String
    let lat: Double
    let lon: Double
    let alt: Double
    let vel_h: Double?  // Optional - iMet sondes may not have velocity data
    let vel_v: Double?  // Optional - iMet sondes may not have velocity data
    let temp: Double?
    let humidity: Double?
    let pressure: Double?
    let uploader_position: String?

    // Computed property to get the best available frequency
    var effectiveFrequency: Double {
        return tx_frequency ?? frequency ?? 0.0
    }

    // Check if sonde is currently flying (above 500m altitude)
    var isFlying: Bool {
        return alt > 500
    }
}

// Site response is a dictionary with serial numbers as keys and sonde data as values
typealias SondeHubSiteResponse = [String: SondeHubSondeData]

/// SondeHub APRS telemetry point (from telemetry endpoint)
struct SondeHubAPRSPoint: Codable {
    let serial: String?
    let datetime: String?
    let lat: Double?
    let lon: Double?
    let alt: Double?
    let vel_v: Double?
    let vel_h: Double?

    var timestamp: Date? {
        guard let datetime = datetime else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: datetime) {
            return date
        }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: datetime)
    }
}

// MARK: - APRS Telemetry Service

@MainActor
final class APRSDataService: ObservableObject {

    // MARK: - Three-Channel Architecture (compatible with BLE service)
    @Published var latestPosition: PositionData? = nil
    let positionDataStream = PassthroughSubject<PositionData, Never>()

    @Published var latestRadioChannel: RadioChannelData? = nil
    let radioChannelDataStream = PassthroughSubject<RadioChannelData, Never>()

    // MARK: - Legacy Properties (state machine compatibility)
    // Legacy latestTelemetry removed - use latestPosition and latestRadioChannel
    @Published var connectionStatus: ConnectionStatus = .disconnected
    var lastTelemetryUpdateTime: Date? = nil

    // APRS-specific published state
    var currentStationId: String = "06610" // Default to Payerne
    var lastSondeSerial: String? = nil
    var pollCadence: TimeInterval = 60.0
    private var apiCallCount: Int = 0
    var lastApiError: String? = nil

    // User-specified sonde serial override (set via startup popup)
    // When set, APRS will fetch this specific sonde using /sonde/{serial} endpoint
    var overrideSondeSerial: String? = nil

    // Sonde name mismatch tracking (display only)
    @Published var bleSerialName: String? = nil
    @Published var aprsSerialName: String? = nil

    // Available sondes from station (for selection popup)
    @Published var availableSondes: [SondeHubSondeData] = []

    // Compatible telemetry stream with BLE service
    // Legacy telemetryData stream removed - use three-channel streams

    // MARK: - Private State
    private var pollingTimer: Timer?
    private var isPollingActive: Bool = false
    private var cancellables = Set<AnyCancellable>()
    private let session = URLSession.shared
    private var hasLoggedSondeMismatch: Bool = false

    // MARK: - Dependencies
    private let userSettings: UserSettings

    // MARK: - Constants
    private static let sondeHubBaseURL = "https://api.v2.sondehub.org"
    private static let fastPollInterval: TimeInterval = 15.0
    private static let slowPollInterval: TimeInterval = 60.0
    private static let landedConfirmationInterval: TimeInterval = 300.0
    private static let verySlowPollInterval: TimeInterval = 3600.0  // 1 hour
    private static let apiTimeout: TimeInterval = 5.0  // For regular polling endpoint
    private static let aprsApiTimeout: TimeInterval = 30.0  // For APRS telemetry fetch (typically ~9s, allow buffer)

    // Polling thresholds
    private static let freshDataThreshold: TimeInterval = 120.0  // 2 minutes - fresh data
    private static let staleDataThreshold: TimeInterval = 1800.0 // 30 minutes - very slow polling

    init(userSettings: UserSettings) {
        self.userSettings = userSettings

        // Initialize station ID from user settings
        currentStationId = userSettings.stationId

        appLog("APRSDataService: Initialized with station ID \(currentStationId)", category: .service, level: .info)

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
            appLog("APRSDataService: Polling already active, ignoring start request", category: .service, level: .debug)
            return
        }

        isPollingActive = true
        pollCadence = Self.fastPollInterval
        connectionStatus = .connecting

        appLog("APRSDataService: Starting APRS polling every \(Int(pollCadence))s for station \(currentStationId)", category: .service, level: .info)

        // Immediate fetch + start timer
        Task {
            await fetchLatestTelemetry()
        }
        startPollingTimer()
    }

    /// Stop APRS telemetry polling (called when BLE telemetry resumes)
    func stopPolling() {
        guard isPollingActive else {
            appLog("APRSDataService: Polling not active, ignoring stop request", category: .service, level: .debug)
            return
        }

        isPollingActive = false
        connectionStatus = .disconnected
        pollingTimer?.invalidate()
        pollingTimer = nil

        appLog("APRSDataService: Stopped APRS polling (BLE telemetry resumed)", category: .service, level: .info)
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

        appLog("APRSDataService: Station ID changed to \(newStationId)", category: .service, level: .info)

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

    /// Force immediate APRS fetch (for foreground resume or manual refresh)
    func forceImmediateFetch() async {
        appLog("APRSDataService: Forcing immediate APRS fetch", category: .service, level: .info)
        await fetchLatestTelemetry()
    }

    // Removed: primeStartupData - startup now uses standard startPolling() for immediate telemetry

    /// Update BLE sonde name for display purposes
    func updateBLESondeName(_ sondeName: String) {
        bleSerialName = sondeName

        // Log mismatch once per session (no resolution needed)
        if let aprsSerial = aprsSerialName, aprsSerial != sondeName, !hasLoggedSondeMismatch {
            appLog("APRSDataService: Sonde name difference - BLE: \(sondeName), APRS: \(aprsSerial)", category: .service, level: .info)
            hasLoggedSondeMismatch = true
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

    private func adjustPollingCadenceForAPIEfficiency(aprsDataAge: TimeInterval) {
        guard isPollingActive else { return }

        // Adjust polling frequency based on data freshness (API efficiency only)
        if aprsDataAge <= Self.freshDataThreshold {
            // Fresh data - poll frequently
            updatePollingInterval(Self.fastPollInterval)
        } else if aprsDataAge <= Self.staleDataThreshold {
            // Stale data - poll less frequently to confirm landing
            updatePollingInterval(Self.landedConfirmationInterval)
        } else {
            // Very old data - poll once per hour to check for recovery
            updatePollingInterval(Self.verySlowPollInterval)
        }
    }

    private func updatePollingInterval(_ interval: TimeInterval) {
        guard pollCadence != interval else { return }
        pollCadence = interval
        if isPollingActive {
            appLog("APRSDataService: Adjusting polling interval to \(Int(interval))s for API efficiency", category: .service, level: .debug)
            startPollingTimer()
        }
    }

    private func fetchLatestTelemetry() async {
        // Reduced logging frequency for APRS fetches

        do {
            // If user specified an override sonde, fetch it directly using /sonde/{serial}
            if let override = overrideSondeSerial?.trimmingCharacters(in: .whitespacesAndNewlines).uppercased(),
               !override.isEmpty {
                try await fetchSondeBySerial(override)
                return
            }

            // Otherwise, use station-based fetch (default behavior)
            let siteResponse = try await fetchSiteData()

            // Filter out ground-based test sondes before selecting
            let flyingSondes = filterGroundTestSondes(from: Array(siteResponse.values))

            // Filter to sondes from the last 24 hours only
            let twentyFourHoursAgo = Date().addingTimeInterval(-24 * 60 * 60)
            let recentSondes = flyingSondes.filter { sonde in
                guard let sondeDate = parseISO8601Date(sonde.datetime) else { return false }
                return sondeDate > twentyFourHoursAgo
            }

            // Sort by datetime (most recent first) and store for selection popup
            let sortedSondes = recentSondes.sorted { sonde1, sonde2 in
                let date1 = parseISO8601Date(sonde1.datetime) ?? Date.distantPast
                let date2 = parseISO8601Date(sonde2.datetime) ?? Date.distantPast
                return date1 > date2
            }
            availableSondes = sortedSondes

            if sortedSondes.count > 1 {
                appLog("APRSDataService: \(sortedSondes.count) sondes available (last 24h): \(sortedSondes.map { $0.serial }.joined(separator: ", "))", category: .service, level: .info)
            }

            // Find the most recent sonde by timestamp
            guard let latestSonde = sortedSondes.first else {
                appLog("APRSDataService: No flying sondes found for station \(currentStationId)", category: .service, level: .info)
                return
            }

            // Convert to three-channel data directly
            let (positionData, radioChannelData) = try convertToThreeChannelData(latestSonde)

            // Update state
            latestPosition = positionData
            latestRadioChannel = radioChannelData
            lastTelemetryUpdateTime = Date()
            lastSondeSerial = latestSonde.serial
            connectionStatus = .connected
            lastApiError = nil

            // Publish through new three-channel streams
            self.positionDataStream.send(positionData)
            self.radioChannelDataStream.send(radioChannelData)

            // Three-channel architecture - telemetry synthesis removed

            appLog("APRSDataService: Published telemetry for sonde \(latestSonde.serial) at \(String(format: "%.5f, %.5f", latestSonde.lat, latestSonde.lon))", category: .service, level: .info)

            // Adjust polling frequency for API efficiency
            let aprsDataAge = Date().timeIntervalSince(positionData.timestamp)
            adjustPollingCadenceForAPIEfficiency(aprsDataAge: aprsDataAge)

            connectionStatus = .connected

        } catch APRSError.invalidPayload {
            appLog("APRSDataService: Ignoring incomplete telemetry payload", category: .service, level: .info)
        } catch {
            appLog("APRSDataService: Failed to fetch telemetry: \(error.localizedDescription)", category: .service, level: .error)

            connectionStatus = .failed(error.localizedDescription)
            lastApiError = error.localizedDescription
        }
    }

    /// Fetch telemetry for a specific sonde by serial
    /// First tries /sondes/telemetry (3-day limit), then falls back to /sonde/{serial} with streaming (for older sondes)
    private func fetchSondeBySerial(_ serial: String) async throws {
        apiCallCount += 1

        // First try /sondes/telemetry?serial=X&duration=3d - fast and limited data
        let telemetryUrl = URL(string: "\(Self.sondeHubBaseURL)/sondes/telemetry?serial=\(serial)&duration=3d")!
        var telemetryRequest = URLRequest(url: telemetryUrl)
        telemetryRequest.timeoutInterval = Self.aprsApiTimeout
        telemetryRequest.setValue("application/json", forHTTPHeaderField: "Accept")
        telemetryRequest.setValue("gzip, deflate", forHTTPHeaderField: "Accept-Encoding")
        telemetryRequest.setValue("BalloonHunter iOS App", forHTTPHeaderField: "User-Agent")

        appLog("APRSDataService: GET \(telemetryUrl.absoluteString) (override sonde - trying 3d first)", category: .service, level: .info)

        let (telemetryData, telemetryResponse) = try await URLSession.shared.data(for: telemetryRequest)

        guard let httpResponse = telemetryResponse as? HTTPURLResponse, httpResponse.statusCode == 200 else {
            appLog("APRSDataService: Telemetry endpoint failed for \(serial)", category: .service, level: .error)
            throw APRSError.invalidResponse
        }

        // Try to decode the telemetry response
        let decoder = JSONDecoder()
        if let telemetryResult = try? decoder.decode([String: [String: SondeHubSondeData]].self, from: telemetryData),
           let sondeData = telemetryResult[serial], !sondeData.isEmpty {
            // Found in 3-day telemetry!
            guard let latestPoint = sondeData.values.max(by: { point1, point2 in
                let date1 = parseISO8601Date(point1.datetime) ?? Date.distantPast
                let date2 = parseISO8601Date(point2.datetime) ?? Date.distantPast
                return date1 < date2
            }) else {
                throw APRSError.noSondesFound
            }
            appLog("APRSDataService: Found \(sondeData.count) points for override sonde \(serial) in 3d telemetry", category: .service, level: .info)
            try await publishSondeData(latestPoint)
            return
        }

        // Not found in 3-day window - try /sonde/{serial} with streaming to get just the first record
        appLog("APRSDataService: Sonde \(serial) not in 3d window, trying /sonde/{serial} with streaming", category: .service, level: .info)
        try await fetchSondeBySerialStreaming(serial)
    }

    /// Fetch sonde data using full download with tail extraction
    /// The /sonde/{serial} endpoint returns data oldest-first, so we need the LAST record (landing position)
    /// We download the full response but only parse the last few KB to get the final record
    private func fetchSondeBySerialStreaming(_ serial: String) async throws {
        let url = URL(string: "\(Self.sondeHubBaseURL)/sonde/\(serial)")!
        var request = URLRequest(url: url)
        request.timeoutInterval = 120  // Longer timeout for large response
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("gzip, deflate", forHTTPHeaderField: "Accept-Encoding")
        request.setValue("BalloonHunter iOS App", forHTTPHeaderField: "User-Agent")

        appLog("APRSDataService: GET \(url.absoluteString) (downloading for old sonde - need last record)", category: .service, level: .info)

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
            appLog("APRSDataService: HTTP error for sonde fetch", category: .service, level: .error)
            throw APRSError.invalidResponse
        }

        appLog("APRSDataService: Downloaded \(data.count) bytes for old sonde \(serial)", category: .service, level: .info)

        guard data.count > 10 else {
            appLog("APRSDataService: Response too small for sonde \(serial)", category: .service, level: .error)
            throw APRSError.noSondesFound
        }

        // Extract the last JSON object from the array
        // Response format: [{ first }, { ... }, { last }]
        // We need to find the last complete {...} object

        // Take the last 5KB of data to find the last record
        let tailSize = min(5000, data.count)
        let tailData = data.suffix(tailSize)

        // Find the last complete JSON object by searching backwards for "}]" then backwards for "{"
        guard let tailString = String(data: tailData, encoding: .utf8) else {
            appLog("APRSDataService: Could not decode tail data for \(serial)", category: .service, level: .error)
            throw APRSError.noSondesFound
        }

        // Find the last "}" before the closing "]"
        guard let lastBraceIndex = tailString.lastIndex(of: "}") else {
            appLog("APRSDataService: No closing brace found in tail for \(serial)", category: .service, level: .error)
            throw APRSError.noSondesFound
        }

        // Now find the matching "{" by counting backwards
        let stringUpToLastBrace = String(tailString[...lastBraceIndex])
        var braceCount = 0
        var objectStartIndex: String.Index?

        for index in stringUpToLastBrace.indices.reversed() {
            let char = stringUpToLastBrace[index]
            if char == "}" {
                braceCount += 1
            } else if char == "{" {
                braceCount -= 1
                if braceCount == 0 {
                    objectStartIndex = index
                    break
                }
            }
        }

        guard let startIdx = objectStartIndex else {
            appLog("APRSDataService: Could not find matching brace for last object in \(serial)", category: .service, level: .error)
            throw APRSError.noSondesFound
        }

        // Extract the last JSON object
        let lastObjectString = String(stringUpToLastBrace[startIdx...])
        guard let lastObjectData = lastObjectString.data(using: .utf8) else {
            throw APRSError.noSondesFound
        }

        let decoder = JSONDecoder()
        let sondeData = try decoder.decode(SondeHubSondeData.self, from: lastObjectData)

        appLog("APRSDataService: Extracted last record for old sonde \(serial) from \(sondeData.datetime ?? "unknown") at [\(sondeData.lat), \(sondeData.lon)]", category: .service, level: .info)
        try await publishSondeData(sondeData)
    }

    /// Publish sonde data to the three-channel streams
    private func publishSondeData(_ latestPoint: SondeHubSondeData) async throws {
        appLog("APRSDataService: Publishing data for override sonde \(latestPoint.serial)", category: .service, level: .info)

        // Convert to three-channel data
        let (positionData, radioChannelData) = try convertToThreeChannelData(latestPoint)

        // Update state
        latestPosition = positionData
        latestRadioChannel = radioChannelData
        lastTelemetryUpdateTime = Date()
        lastSondeSerial = latestPoint.serial
        connectionStatus = .connected
        lastApiError = nil

        // Publish through three-channel streams
        self.positionDataStream.send(positionData)
        self.radioChannelDataStream.send(radioChannelData)

        appLog("APRSDataService: Published telemetry for override sonde \(latestPoint.serial) at \(String(format: "%.5f, %.5f", latestPoint.lat, latestPoint.lon))", category: .service, level: .info)

        // Adjust polling frequency
        let aprsDataAge = Date().timeIntervalSince(positionData.timestamp)
        adjustPollingCadenceForAPIEfficiency(aprsDataAge: aprsDataAge)
    }

    private func fetchSiteData() async throws -> SondeHubSiteResponse {
        apiCallCount += 1

        let url = URL(string: "\(Self.sondeHubBaseURL)/sondes/site/\(currentStationId)")!
        var request = URLRequest(url: url)
        request.timeoutInterval = Self.apiTimeout
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("BalloonHunter iOS App", forHTTPHeaderField: "User-Agent")

        appLog("APRSDataService: GET \(url.absoluteString)", category: .service, level: .debug)

        let (data, response) = try await session.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw APRSError.invalidResponse
        }

        guard httpResponse.statusCode == 200 else {
            throw APRSError.httpError(httpResponse.statusCode)
        }

        // Check if we received empty data
        if data.isEmpty {
            appLog("APRSDataService: Received empty data from API", category: .service, level: .error)
            throw APRSError.noData
        }

        do {
            let siteResponse = try JSONDecoder().decode(SondeHubSiteResponse.self, from: data)

            // Log essential telemetry data only (debug level)
            let sondesSummary = siteResponse.map { (serial, data) in
                let freqStr = "freq=\(String(format: "%.2f", data.frequency ?? 0.0))/tx=\(String(format: "%.2f", data.tx_frequency ?? 0.0))/eff=\(String(format: "%.2f", data.effectiveFrequency))MHz"
                return "\(serial): lat=\(String(format: "%.5f", data.lat)), lon=\(String(format: "%.5f", data.lon)), alt=\(String(format: "%.0f", data.alt))m, v_v=\(String(format: "%.1f", data.vel_v ?? 0.0))m/s, v_h=\(String(format: "%.1f", data.vel_h ?? 0.0))m/s, \(freqStr), type=\(data.type), time=\(data.datetime)"
            }.joined(separator: " | ")
            appLog("APRSDataService: Telemetry data: \(sondesSummary)", category: .service, level: .debug)
            appLog("APRSDataService: Received data for \(siteResponse.count) sondes", category: .service, level: .debug)

            return siteResponse
        } catch {
            appLog("APRSDataService: JSON decoding failed: \(error)", category: .service, level: .error)
            throw APRSError.decodingError(error.localizedDescription)
        }
    }

    private func filterGroundTestSondes(from sondes: [SondeHubSondeData]) -> [SondeHubSondeData] {
        // Filter out ground-based test sondes (distance < 1km from uploader)
        return sondes.filter { sonde in
            guard let uploaderPosString = sonde.uploader_position else {
                // No uploader position available, include by default
                return true
            }

            // Parse uploader position "lat,lon"
            let components = uploaderPosString.split(separator: ",")
            guard components.count == 2,
                  let uploaderLat = Double(components[0]),
                  let uploaderLon = Double(components[1]) else {
                return true // Can't parse, include by default
            }

            // Calculate distance between sonde and uploader
            let distance = calculateDistance(
                lat1: sonde.lat, lon1: sonde.lon,
                lat2: uploaderLat, lon2: uploaderLon
            )

            // Filter out if distance < 1000 meters (1 km)
            let isGroundTest = distance < 1000.0

            if isGroundTest {
                appLog("APRSDataService: Ground test sonde \(sonde.serial) filtered out (distance: \(Int(distance))m from uploader)", category: .service, level: .info)
            }

            return !isGroundTest
        }
    }

    private func calculateDistance(lat1: Double, lon1: Double, lat2: Double, lon2: Double) -> Double {
        // Haversine formula for distance between two coordinates
        let earthRadius = 6371000.0 // meters

        let dLat = (lat2 - lat1) * .pi / 180.0
        let dLon = (lon2 - lon1) * .pi / 180.0

        let a = sin(dLat / 2) * sin(dLat / 2) +
                cos(lat1 * .pi / 180.0) * cos(lat2 * .pi / 180.0) *
                sin(dLon / 2) * sin(dLon / 2)

        let c = 2 * atan2(sqrt(a), sqrt(1 - a))

        return earthRadius * c
    }

    private func findLatestSonde(from sondes: [SondeHubSondeData]) -> SondeHubSondeData? {
        // Find the sonde with the most recent timestamp
        return sondes.max { sonde1, sonde2 in
            let date1 = parseISO8601Date(sonde1.datetime) ?? Date.distantPast
            let date2 = parseISO8601Date(sonde2.datetime) ?? Date.distantPast
            return date1 < date2
        }
    }

    private func convertToThreeChannelData(_ sonde: SondeHubSondeData) throws -> (PositionData, RadioChannelData) {
        let trimmedSerial = sonde.serial.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedType = sonde.type.trimmingCharacters(in: .whitespacesAndNewlines)
        // Always use exactly 2 decimal places for frequency consistency
        let frequency = round(sonde.effectiveFrequency * 100.0) / 100.0
        let latitude = sonde.lat
        let longitude = sonde.lon


        let coordinatesValid = latitude.isFinite && longitude.isFinite && abs(latitude) <= 90 && abs(longitude) <= 180 && !(latitude == 0 && longitude == 0)

        guard !trimmedSerial.isEmpty,
              !trimmedType.isEmpty,
              coordinatesValid else {
            throw APRSError.invalidPayload
        }

        // Parse timestamp
        let timestamp: Date
        if let parsedTimestamp = parseISO8601Date(sonde.datetime) {
            timestamp = parsedTimestamp
        } else {
            timestamp = Date()
            appLog("APRSDataService: Failed to parse timestamp '\(sonde.datetime)', using current time", category: .service, level: .error)
        }

        // Create PositionData directly
        let positionData = PositionData(
            sondeName: trimmedSerial,
            latitude: latitude,
            longitude: longitude,
            altitude: sonde.alt,
            verticalSpeed: sonde.vel_v ?? 0.0,
            horizontalSpeed: sonde.vel_h ?? 0.0,
            heading: 0.0, // Not provided by APRS
            temperature: sonde.temp ?? 0.0,
            humidity: sonde.humidity ?? 0.0,
            pressure: sonde.pressure ?? 0.0,
            timestamp: timestamp,
            apiCallTimestamp: Date(),
            burstKillerTime: 0,
            telemetrySource: .aprs
        )

        // Create RadioChannelData directly
        let radioData = RadioChannelData(
            sondeName: trimmedSerial,
            timestamp: timestamp,
            telemetrySource: .aprs,
            probeType: trimmedType.uppercased(),
            frequency: frequency,
            softwareVersion: "APRS", // Keep APRS as software version identifier
            batteryVoltage: 0.0, // Not provided by APRS
            batteryPercentage: 0, // Not provided by APRS
            signalStrength: 0, // Not provided by APRS
            buzmute: false, // Not provided by APRS
            afcFrequency: 0, // Not provided by APRS
            burstKillerEnabled: false, // Not provided by APRS
            burstKillerTime: 0 // Not provided by APRS
        )

        return (positionData, radioData)
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

    // MARK: - APRS Track Filling

    /// Round timestamp to nearest second for slot-based deduplication
    private func roundToSecond(_ date: Date) -> Date {
        let calendar = Calendar.current
        let components = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        return calendar.date(from: components) ?? date
    }

    /// Fetch APRS telemetry from SondeHub and fill gaps in local track
    /// This runs asynchronously and does not block the UI
    /// - Parameters:
    ///   - serial: Sonde serial number
    ///   - duration: How far back to fetch - default "3d" for maximum coverage
    ///   - localTrack: Current local track points with timestamps
    /// - Returns: New track points to add (returns empty array on error)
    func fetchAPRSTelemetryToFillGaps(
        serial: String,
        duration: String = "3d",
        localTrack: [BalloonTrackPoint]
    ) async -> [BalloonTrackPoint] {

        // Build URL with duration (SondeHub retains data for ~3 days)
        let url = URL(string: "\(Self.sondeHubBaseURL)/sondes/telemetry?serial=\(serial)&duration=\(duration)")!

        var request = URLRequest(url: url)
        request.timeoutInterval = Self.aprsApiTimeout  // Use longer timeout for APRS data fetch (typically ~9s response time)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("gzip, deflate", forHTTPHeaderField: "Accept-Encoding")
        request.setValue("BalloonHunter iOS App", forHTTPHeaderField: "User-Agent")

        appLog("APRSDataService: Fetching telemetry for \(serial) (duration: \(duration))", category: .service, level: .info)

        do {
            let (data, response) = try await session.data(for: request)

            guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
                appLog("APRSDataService: Fetch failed - invalid response", category: .service, level: .error)
                return []
            }

            let decoder = JSONDecoder()
            let nestedDict = try decoder.decode([String: [String: SondeHubAPRSPoint]].self, from: data)

            var aprsPoints: [SondeHubAPRSPoint] = []
            for (_, timestampDict) in nestedDict {
                for (_, point) in timestampDict {
                    aprsPoints.append(point)
                }
            }

            // Use rounded timestamps (to second) for slot-based filtering
            let localTimestamps = Set(localTrack.map { roundToSecond($0.timestamp) })
            let newPoints = aprsPoints.filter { point in
                guard let timestamp = point.timestamp else { return false }
                return !localTimestamps.contains(roundToSecond(timestamp))
            }

            let trackPoints = newPoints.compactMap { point -> BalloonTrackPoint? in
                guard let timestamp = point.timestamp,
                      let lat = point.lat,
                      let lon = point.lon,
                      let alt = point.alt else {
                    return nil
                }

                return BalloonTrackPoint(
                    latitude: lat,
                    longitude: lon,
                    altitude: alt,
                    timestamp: timestamp,
                    verticalSpeed: point.vel_v ?? 0.0,
                    horizontalSpeed: point.vel_h ?? 0.0
                )
            }

            appLog("APRSDataService: Added \(trackPoints.count) points (total received: \(aprsPoints.count))", category: .service, level: .info)
            return trackPoints

        } catch {
            appLog("APRSDataService: Fetch error: \(error)", category: .service, level: .error)
            return []
        }
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

