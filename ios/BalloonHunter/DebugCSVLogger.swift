import Foundation
import CoreLocation
import OSLog

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

    func purgeCSVLog() {
        let (url, _) = fileURL()
        try? FileManager.default.removeItem(at: url)
        appLog("DebugCSVLogger: Purged telemetry CSV log", category: .service, level: .debug)
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

/// Append-only record of every state-machine transition and balloon-phase
/// change, so a landing decision can be read after the fact instead of raced
/// against the device's os_log ring buffer (which drops info entries within an
/// hour). Written to `transitions.csv` in the app container.
///
/// Regularly deleted, two ways: purged when a new hunt starts (a fresh file per
/// sonde), and size-capped — when it exceeds `maxBytes` the oldest half is
/// dropped so it can never grow without bound the way telemetry_log.csv did.
@MainActor
final class TransitionLogger {
    static let shared = TransitionLogger()
    private init() {}

    private let fileName = "transitions.csv"
    /// Hard ceiling. At ~80 bytes/row this keeps ~3000 recent transitions.
    private let maxBytes = 256 * 1024
    private let iso: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    /// A state-machine transition, with the inputs that drove it.
    func logStateTransition(from: String, to: String,
                            ble: String, aprsAvailable: Bool, phase: String,
                            sonde: String, altitude: Double?, source: String) {
        append(kind: "state", from: from, to: to,
               detail: "ble=\(ble);aprs=\(aprsAvailable);phase=\(phase)",
               sonde: sonde, altitude: altitude, source: source)
    }

    /// A balloon-phase change, carrying the rule that caused a landing.
    func logPhaseChange(from: String, to: String, reason: String,
                        sonde: String, altitude: Double?, source: String) {
        append(kind: "phase", from: from, to: to,
               detail: "reason=\(reason)",
               sonde: sonde, altitude: altitude, source: source)
    }

    /// Start a fresh file for a new hunt.
    func purge() {
        try? FileManager.default.removeItem(at: fileURL())
        appLog("TransitionLogger: Purged transition log for new hunt", category: .service, level: .debug)
    }

    // MARK: - Helpers

    private func append(kind: String, from: String, to: String, detail: String,
                        sonde: String, altitude: Double?, source: String) {
        let url = fileURL()
        if !FileManager.default.fileExists(atPath: url.path) {
            let header = "timestamp,kind,from,to,detail,sonde,altitude,source\n"
            try? header.data(using: .utf8)?.write(to: url)
        }
        let alt = altitude.map { String(format: "%.0f", $0) } ?? ""
        let row = [iso.string(from: Date()), kind, from, to, escape(detail),
                   escape(sonde), alt, source].joined(separator: ",") + "\n"
        if let data = row.data(using: .utf8), let handle = try? FileHandle(forWritingTo: url) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            _ = try? handle.write(contentsOf: data)
        }
        rotateIfNeeded(url)
    }

    /// Drop the oldest half when the file passes the ceiling, keeping the header.
    private func rotateIfNeeded(_ url: URL) {
        guard let size = try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int,
              size > maxBytes,
              let content = try? String(contentsOf: url, encoding: .utf8) else { return }
        var lines = content.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        guard lines.count > 3 else { return }
        let header = lines.first ?? "timestamp,kind,from,to,detail,sonde,altitude,source"
        let body = Array(lines.dropFirst())
        let kept = Array(body.suffix(body.count / 2))
        let rebuilt = ([header] + kept).joined(separator: "\n")
        try? rebuilt.data(using: .utf8)?.write(to: url)
        appLog("TransitionLogger: Rotated transition log (kept \(kept.count) rows)", category: .service, level: .debug)
    }

    private func fileURL() -> URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
            .appendingPathComponent(fileName)
    }

    private func escape(_ s: String) -> String {
        if s.contains(",") || s.contains("\"") { return "\"" + s.replacingOccurrences(of: "\"", with: "\"\"") + "\"" }
        return s
    }
}
