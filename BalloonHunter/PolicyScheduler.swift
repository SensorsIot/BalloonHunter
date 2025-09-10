import Foundation
import Combine
import os

actor PolicyScheduler {
    private var lastExecutionTime: [String: Date] = [:]
    private var lastThrottleTime: [String: Date] = [:]
    private var currentTasks: [String: Task<Void, Never>] = [:]
    private var coalescingBuffer: [String: Any] = [:]
    private var backoffMultipliers: [String: Double] = [:]
    
    private let maxBackoffMultiplier: Double = 32.0
    private let baseBackoffInterval: TimeInterval = 1.0
    
    enum ThrottleType {
        case leading
        case trailing
    }
    
    enum SchedulingDecision {
        case executed
        case skippedCooldown(remainingTime: TimeInterval)
        case skippedThrottle(remainingTime: TimeInterval)
        case skippedBackoff(nextAttemptTime: Date)
        case cancelled
    }

    func cooldown(key: String, cooldownDuration: TimeInterval, operation: @escaping () async -> Void) async -> SchedulingDecision {
        let now = Date()
        if let lastTime = lastExecutionTime[key], now.timeIntervalSince(lastTime) < cooldownDuration {
            let remainingTime = cooldownDuration - now.timeIntervalSince(lastTime)
            appLog("PolicyScheduler: Skipping \(key) due to cooldown, \(String(format: "%.1f", remainingTime))s remaining", category: .general, level: .debug)
            return .skippedCooldown(remainingTime: remainingTime)
        }
        lastExecutionTime[key] = now
        await operation()
        appLog("PolicyScheduler: Executed \(key) after cooldown", category: .general, level: .debug)
        return .executed
    }
    
    func throttle(key: String, interval: TimeInterval, type: ThrottleType = .trailing, operation: @escaping () async -> Void) -> SchedulingDecision {
        let now = Date()
        
        switch type {
        case .leading:
            if let lastTime = lastThrottleTime[key], now.timeIntervalSince(lastTime) < interval {
                let remainingTime = interval - now.timeIntervalSince(lastTime)
                return .skippedThrottle(remainingTime: remainingTime)
            }
            lastThrottleTime[key] = now
            Task { await operation() }
            return .executed
            
        case .trailing:
            currentTasks[key]?.cancel()
            let newTask = Task {
                do {
                    try await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
                    if !Task.isCancelled {
                        await operation()
                        self.setLastThrottleTime(key: key, time: Date())
                    }
                } catch {
                    return
                }
                self.removeTask(key: key)
            }
            currentTasks[key] = newTask
            return .executed
        }
    }
    
    private func setLastThrottleTime(key: String, time: Date) {
        lastThrottleTime[key] = time
    }
    
    private func removeTask(key: String) {
        currentTasks.removeValue(forKey: key)
    }

    func latestWins(key: String, operation: @escaping () async -> Void) -> SchedulingDecision {
        currentTasks[key]?.cancel()

        let newTask = Task {
            await operation()
            if !Task.isCancelled {
                self.removeTask(key: key)
            }
        }
        currentTasks[key] = newTask
        return .executed
    }
    
    func debounce(key: String, delay: TimeInterval, operation: @escaping () async -> Void) -> SchedulingDecision {
        currentTasks[key]?.cancel()

        let newTask = Task {
            do {
                try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                if !Task.isCancelled {
                    await operation()
                }
            } catch {
                return
            }
            self.removeTask(key: key)
        }
        currentTasks[key] = newTask
        return .executed
    }
    
    func coalesce<T: Equatable>(key: String, value: T, windowDuration: TimeInterval, operation: @escaping (T) -> Void) {
        coalescingBuffer[key] = value
        
        currentTasks[key]?.cancel()
        
        let newTask = Task {
            do {
                try await Task.sleep(nanoseconds: UInt64(windowDuration * 1_000_000_000))
                if !Task.isCancelled,
                   let latestValue = self.getCoalescedValue(key: key) as? T {
                    operation(latestValue)
                }
            } catch {
                return
            }
            self.clearCoalescedValue(key: key)
            self.removeTask(key: key)
        }
        currentTasks[key] = newTask
    }
    
    private func getCoalescedValue(key: String) -> Any? {
        return coalescingBuffer[key]
    }
    
    private func clearCoalescedValue(key: String) {
        coalescingBuffer.removeValue(forKey: key)
    }
    
    func withBackoff(key: String, operation: @escaping () async throws -> Void) async throws -> SchedulingDecision {
        let multiplier = backoffMultipliers[key] ?? 1.0
        let backoffDelay = baseBackoffInterval * multiplier
        
        if let lastTime = lastExecutionTime[key] {
            let timeSinceLastExecution = Date().timeIntervalSince(lastTime)
            if timeSinceLastExecution < backoffDelay {
                let nextAttemptTime = lastTime.addingTimeInterval(backoffDelay)
                appLog("PolicyScheduler: Skipping \(key) due to backoff, next attempt at \(nextAttemptTime)", category: .general, level: .debug)
                return .skippedBackoff(nextAttemptTime: nextAttemptTime)
            }
        }
        
        lastExecutionTime[key] = Date()
        
        do {
            try await operation()
            backoffMultipliers[key] = 1.0
            appLog("PolicyScheduler: Successfully executed \(key), reset backoff", category: .general, level: .debug)
            return .executed
        } catch {
            let newMultiplier = min(multiplier * 2.0, maxBackoffMultiplier)
            backoffMultipliers[key] = newMultiplier
            appLog("PolicyScheduler: Failed to execute \(key), increased backoff to \(String(format: "%.1f", newMultiplier))x", category: .general, level: .debug)
            throw error
        }
    }
    
    func cancelAll(keyPrefix: String? = nil) {
        if let prefix = keyPrefix {
            let keysToCancel = currentTasks.keys.filter { $0.hasPrefix(prefix) }
            for key in keysToCancel {
                currentTasks[key]?.cancel()
                currentTasks.removeValue(forKey: key)
            }
        } else {
            for task in currentTasks.values {
                task.cancel()
            }
            currentTasks.removeAll()
        }
    }
    
    func getStats() -> [String: Any] {
        return [
            "activeTasks": currentTasks.count,
            "trackedCooldowns": lastExecutionTime.count,
            "activeBackoffs": backoffMultipliers.filter { $0.value > 1.0 }.count,
            "coalescingBufferSize": coalescingBuffer.count
        ]
    }
}
