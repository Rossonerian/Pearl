import Foundation
import UserNotifications

/// Proactive Briefing Service for Pearl V3.
/// Synthesizes pending high-priority tasks and delivers zero-idle-CPU event-driven notifications.
public actor BriefingEngine {
    public static let shared = BriefingEngine()
    
    private let taskStore: TaskStore
    
    public init(taskStore: TaskStore = .shared) {
        self.taskStore = taskStore
    }
    
    // MARK: - Morning & Executive Briefing
    
    /// Generates a concise, executive morning briefing synthesizing pending high-priority tasks,
    /// overdue deadlines, and overall task agenda.
    public func generateMorningBriefing(
        referenceDate: Date = Date(),
        userName: String? = nil
    ) async throws -> String {
        let calendar = Calendar.current
        let hour = calendar.component(.hour, from: referenceDate)
        
        let greeting: String
        if hour >= 5 && hour < 12 {
            greeting = "Good morning"
        } else if hour >= 12 && hour < 17 {
            greeting = "Good afternoon"
        } else if hour >= 17 && hour < 22 {
            greeting = "Good evening"
        } else {
            greeting = "Working late"
        }
        
        let namePrefix = userName != nil ? ", \(userName!)" : ""
        let dayFormatter = DateFormatter()
        dayFormatter.dateFormat = "EEEE, MMMM d"
        let dateHeader = dayFormatter.string(from: referenceDate)
        
        let overdueTasks = try await taskStore.getOverdueTasks(asOf: referenceDate)
        let pendingTasks = try await taskStore.listTasks(status: .pending)
        
        if pendingTasks.isEmpty && overdueTasks.isEmpty {
            return """
            \(greeting)\(namePrefix)! It's \(dateHeader).
            Your agenda is completely clear with zero pending tasks. Have a wonderful and productive day!
            """
        }
        
        var sections: [String] = []
        sections.append("\(greeting)\(namePrefix)! Here is your executive briefing for \(dateHeader):")
        
        // 1. Overdue section
        if !overdueTasks.isEmpty {
            var overdueLines: [String] = []
            overdueLines.append("⚠️ Overdue Items (\(overdueTasks.count)):")
            for task in overdueTasks.prefix(5) {
                let dueStr = task.dueDate != nil ? " (was due \(TaskDateFormatter.displayString(from: task.dueDate!)))" : ""
                overdueLines.append("  • \(task.priority.badge) \(task.title)\(dueStr)")
            }
            if overdueTasks.count > 5 {
                overdueLines.append("  ... and \(overdueTasks.count - 5) more overdue item(s)")
            }
            sections.append(overdueLines.joined(separator: "\n"))
        }
        
        // 2. High & Urgent Priority focus
        let urgentTasks = pendingTasks.filter { $0.priority == .urgent && !overdueTasks.contains($0) }
        let highTasks = pendingTasks.filter { $0.priority == .high && !overdueTasks.contains($0) }
        let priorityFocus = urgentTasks + highTasks
        
        if !priorityFocus.isEmpty {
            var focusLines: [String] = []
            focusLines.append("🎯 Priority Focus (\(priorityFocus.count)):")
            for task in priorityFocus.prefix(5) {
                var detail = ""
                if let due = task.dueDate {
                    detail = " (Due: \(TaskDateFormatter.displayString(from: due)))"
                }
                focusLines.append("  • \(task.priority.badge) \(task.title)\(detail)")
            }
            if priorityFocus.count > 5 {
                focusLines.append("  ... and \(priorityFocus.count - 5) more high-priority item(s)")
            }
            sections.append(focusLines.joined(separator: "\n"))
        }
        
        // 3. Due today (if not already listed in overdue or priority focus)
        let dueTodayTasks = pendingTasks.filter { task in
            guard let due = task.dueDate else { return false }
            return calendar.isDate(due, inSameDayAs: referenceDate) &&
                   !overdueTasks.contains(task) &&
                   !priorityFocus.contains(task)
        }
        
        if !dueTodayTasks.isEmpty {
            var todayLines: [String] = []
            todayLines.append("📅 Also Due Today (\(dueTodayTasks.count)):")
            for task in dueTodayTasks.prefix(3) {
                todayLines.append("  • \(task.priority.badge) \(task.title) (Due: \(TaskDateFormatter.displayString(from: task.dueDate!)))")
            }
            if dueTodayTasks.count > 3 {
                todayLines.append("  ... and \(dueTodayTasks.count - 3) more item(s) due today")
            }
            sections.append(todayLines.joined(separator: "\n"))
        }
        
        // 4. Executive summary metrics
        let mediumCount = pendingTasks.filter { $0.priority == .medium }.count
        let lowCount = pendingTasks.filter { $0.priority == .low }.count
        let urgentCount = pendingTasks.filter { $0.priority == .urgent }.count
        let highCount = pendingTasks.filter { $0.priority == .high }.count
        
        var summaryParts: [String] = []
        if urgentCount > 0 { summaryParts.append("\(urgentCount) urgent") }
        if highCount > 0 { summaryParts.append("\(highCount) high") }
        if mediumCount > 0 { summaryParts.append("\(mediumCount) medium") }
        if lowCount > 0 { summaryParts.append("\(lowCount) low") }
        
        let breakdown = summaryParts.isEmpty ? "0 items" : summaryParts.joined(separator: ", ")
        sections.append("📊 Summary: \(pendingTasks.count) active task(s) (\(breakdown)).")
        
        return sections.joined(separator: "\n\n")
    }
    
    // MARK: - Event-Driven Notifications (0.0% Idle CPU Invariant)
    
    private var isNotificationCenterAvailable: Bool {
        return Bundle.main.bundleIdentifier != nil
    }
    
    public enum NotificationScheduleResult: Sendable, Equatable {
        case scheduled(identifier: String, fireDate: Date)
        case alreadyPassed
        case noDueDate
        case unauthorized
        case failed(reason: String)
    }
    
    /// Registers a scheduled macOS UserNotification for an impending deadline without continuous polling.
    /// The notification is scheduled natively with `usernoted`, guaranteeing 0.0% idle CPU usage.
    ///
    /// - Parameters:
    ///   - task: The task item to monitor.
    ///   - leadTime: Seconds before deadline to fire the notification (default: 900s = 15 minutes).
    /// - Returns: `NotificationScheduleResult` indicating scheduling status.
    public func scheduleDeadlineNotification(
        for task: TaskItem,
        leadTime: TimeInterval = 900
    ) async -> NotificationScheduleResult {
        guard isNotificationCenterAvailable else {
            return .failed(reason: "UserNotifications requires an application bundle with a bundle identifier")
        }
        guard let due = task.dueDate else {
            return .noDueDate
        }
        
        let fireDate = due.addingTimeInterval(-leadTime)
        let now = Date()
        
        // If the fire date has already passed:
        if fireDate <= now {
            if due > now {
                // Deadline is imminent (within leadTime), schedule immediate notification in 1 second
                return await scheduleTriggerNotification(
                    for: task,
                    fireDate: now.addingTimeInterval(1.0),
                    subtitle: "Imminent Deadline (Due in \(Int(due.timeIntervalSince(now) / 60))m)"
                )
            } else {
                return .alreadyPassed
            }
        }
        
        let minutes = Int(leadTime / 60)
        let leadDesc = minutes > 0 ? "\(minutes)m" : "\(Int(leadTime))s"
        return await scheduleTriggerNotification(
            for: task,
            fireDate: fireDate,
            subtitle: "Deadline in \(leadDesc)"
        )
    }
    
    private func scheduleTriggerNotification(
        for task: TaskItem,
        fireDate: Date,
        subtitle: String
    ) async -> NotificationScheduleResult {
        guard isNotificationCenterAvailable else {
            return .failed(reason: "UserNotifications requires an application bundle with a bundle identifier")
        }
        let identifier = "pearl.task.\(task.id.uuidString)"
        
        do {
            let center = UNUserNotificationCenter.current()
            
            // Check authorization or request if undetermined
            let settings = await center.notificationSettings()
            if settings.authorizationStatus == .denied {
                return .unauthorized
            }
            
            if settings.authorizationStatus == .notDetermined {
                let granted = try await center.requestAuthorization(options: [.alert, .sound, .badge])
                if !granted {
                    return .unauthorized
                }
            }
            
            let content = UNMutableNotificationContent()
            content.title = "Impending Task Deadline: \(task.title)"
            content.subtitle = "\(subtitle) • \(task.priority.displayName) Priority"
            if let notes = task.notes, !notes.isEmpty {
                content.body = notes
            } else if let due = task.dueDate {
                content.body = "Due at \(TaskDateFormatter.displayString(from: due))"
            }
            content.sound = .default
            content.userInfo = [
                "taskId": task.id.uuidString,
                "priority": task.priority.rawValue
            ]
            
            let interval = max(1.0, fireDate.timeIntervalSince(Date()))
            let trigger = UNTimeIntervalNotificationTrigger(timeInterval: interval, repeats: false)
            let request = UNNotificationRequest(identifier: identifier, content: content, trigger: trigger)
            
            try await center.add(request)
            return .scheduled(identifier: identifier, fireDate: fireDate)
        } catch {
            return .failed(reason: error.localizedDescription)
        }
    }
    
    /// Cancels any scheduled notification for the given task UUID.
    public func cancelDeadlineNotification(taskId: UUID) async {
        guard isNotificationCenterAvailable else { return }
        let identifier = "pearl.task.\(taskId.uuidString)"
        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: [identifier])
    }
    
    /// Scans pending tasks and schedules notifications for all upcoming deadlines.
    /// Event-driven: once registered, the system kernel/usernoted handles the trigger with 0.0% CPU overhead.
    public func scheduleAllPendingDeadlineNotifications(
        leadTime: TimeInterval = 900
    ) async throws -> [UUID: NotificationScheduleResult] {
        let pending = try await taskStore.listTasks(status: .pending)
        var results: [UUID: NotificationScheduleResult] = [:]
        
        for task in pending where task.dueDate != nil {
            let res = await scheduleDeadlineNotification(for: task, leadTime: leadTime)
            results[task.id] = res
        }
        
        return results
    }
}
