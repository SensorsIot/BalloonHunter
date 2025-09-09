import Foundation
import OSLog

enum LogCategory: String {
    case event = "Event"
    case policy = "Policy"
    case service = "Service"
    case ui = "UI"
    case cache = "Cache"
    case general = "General"
}

nonisolated func appLog(_ message: String, category: LogCategory, level: OSLogType = .default) {
    let logger = Logger(subsystem: "com.yourcompany.BalloonHunter", category: category.rawValue)
    switch level {
    case OSLogType.debug: logger.debug("\(message)")
    case OSLogType.info: logger.info("\(message)")
    case OSLogType.error: logger.error("\(message)")
    case OSLogType.fault: logger.fault("\(message)")
    default: logger.log("\(message)")
    }
}
