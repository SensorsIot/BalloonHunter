import Foundation
import CoreLocation

@MainActor
final class DebugCSVLogger {
    static let shared = DebugCSVLogger()
    private init() {}

    private let fileName = "telemetry_log.csv"
    private var latestPredictedLanding: CLLocationCoordinate2D? = nil
    private let iso: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    func setLatestPredictedLanding(_ point: CLLocationCoordinate2D?) {
        latestPredictedLanding = point
    }

    func logPosition(_ p: PositionData) {
        // Skip Dev* sondes (case-insensitive)
        if p.sondeName.uppercased().hasPrefix("DEV") { return }

        let (url, isNew) = fileURL()
        ensureHeaderIfNeeded(url: url, isNew: isNew)

        let ts = iso.string(from: Date())
        let lp = latestPredictedLanding
        let fields: [String] = [
            ts,
            escape(p.sondeName),
            String(format: "%.6f", p.latitude),
            String(format: "%.6f", p.longitude),
            String(format: "%.1f", p.altitude),
            lp != nil ? String(format: "%.6f", lp!.latitude) : "",
            lp != nil ? String(format: "%.6f", lp!.longitude) : ""
        ]
        appendLine(url: url, line: fields.joined(separator: ","))
    }


    // MARK: - Helpers
    private func fileURL() -> (URL, Bool) {
        let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        let url = dir.appendingPathComponent(fileName)
        let exists = FileManager.default.fileExists(atPath: url.path)
        return (url, !exists)
    }

    private func ensureHeaderIfNeeded(url: URL, isNew: Bool) {
        if isNew {
            let header = "timestamp,sondeName,latitude,longitude,altitude,landingLat,landingLon\n"
            if let headerData = header.data(using: .utf8) { _ = try? headerData.write(to: url) }
        }
    }

    private func appendLine(url: URL, line: String) {
        guard let data = (line + "\n").data(using: .utf8) else { return }
        if let handle = try? FileHandle(forWritingTo: url) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            _ = try? handle.write(contentsOf: data)
        } else {
            // If file missing unexpectedly, create with header and line
            ensureHeaderIfNeeded(url: url, isNew: true)
            _ = try? data.write(to: url)
        }
    }

    private func escape(_ s: String) -> String {
        if s.contains(",") || s.contains("\"") { return "\"" + s.replacingOccurrences(of: "\"", with: "\"\"") + "\"" }
        return s
    }
}
