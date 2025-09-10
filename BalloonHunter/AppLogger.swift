import Foundation
import OSLog

enum LogCategory: String {
    case event = "Event"
    case policy = "Policy"
    case service = "Service"
    case ui = "UI"
    case cache = "Cache"
    case general = "General"
    case persistence = "Persistence"
    case ble = "BLE"
    case lifecycle = "Lifecycle"
}

nonisolated func appLog(_ message: String, category: LogCategory, level: OSLogType = .default) {
    let timestamp = DateFormatter.logTimestamp.string(from: Date.now)
    let timestampedMessage = "[\(timestamp)] \(message)"
    
    let logger = Logger(subsystem: "com.yourcompany.BalloonHunter", category: category.rawValue)
    switch level {
    case OSLogType.debug: logger.debug("\(timestampedMessage)")
    case OSLogType.info: logger.info("\(timestampedMessage)")
    case OSLogType.error: logger.error("\(timestampedMessage)")
    case OSLogType.fault: logger.fault("\(timestampedMessage)")
    default: logger.log("\(timestampedMessage)")
    }
}

extension DateFormatter {
    nonisolated(unsafe) static let logTimestamp: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss.SSS"
        return formatter
    }()
}
