
import Foundation
import Combine

actor PolicyScheduler {
    private var lastExecutionTime: [String: Date] = [:]
    private var currentTasks: [String: Task<Void, Never>] = [:]

    func cooldown(key: String, cooldownDuration: TimeInterval, operation: @escaping () async -> Void) async {
        let now = Date()
        if let lastTime = lastExecutionTime[key], now.timeIntervalSince(lastTime) < cooldownDuration {
            // Still in cooldown period
            return
        }
        lastExecutionTime[key] = now
        await operation()
    }

    func latestWins(key: String, operation: @escaping () async -> Void) {
        // Cancel any existing task for this key
        currentTasks[key]?.cancel()

        // Create and store a new task
        let newTask = Task {
            await operation()
            // Remove task from dictionary when it completes or is cancelled
            if !Task.isCancelled {
                self.currentTasks.removeValue(forKey: key)
            }
        }
        currentTasks[key] = newTask
    }
    
    // Basic debounce for now, can be expanded with Combine's debounce operator in policies
    // This is more for conceptual centralization of timing logic if not using Combine's built-in debounce directly
    func debounce(key: String, delay: TimeInterval, operation: @escaping () async -> Void) {
        currentTasks[key]?.cancel() // Cancel previous debounce task

        let newTask = Task {
            do {
                try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                if !Task.isCancelled {
                    await operation()
                }
            } catch {} // Task.sleep throws on cancellation
            self.currentTasks.removeValue(forKey: key)
        }
        currentTasks[key] = newTask
    }
}
