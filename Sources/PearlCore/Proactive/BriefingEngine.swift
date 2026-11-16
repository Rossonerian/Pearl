import Foundation
import UserNotifications

/// Represents a prioritized proactive nudge or contextual recommendation.
public struct ProactiveNudge: Sendable, Codable, Identifiable, Equatable {
    public let id: String
    public let category: String
    public let title: String
    public let message: String
    public let priority: TaskPriority
    public let createdAt: Date
    
    public init(
        id: String = UUID().uuidString,
        category: String,
        title: String,
        message: String,
        priority: TaskPriority,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.category = category
        self.title = title
        self.message = message
        self.priority = priority
        self.createdAt = createdAt
    }
}

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
        guard Bundle.main.bundleIdentifier != nil else { return false }
        return Bundle.main.bundleURL.pathExtension.lowercased() == "app" &&
               !PearlStoragePaths.isRunningTests
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
    
    // MARK: - Proactive Nudges & Quiet Hours
    
    /// Determines whether the given date/time falls within quiet hours.
    /// Handles overnight wrap-around (e.g. 22:00 -> 08:00) as well as daytime intervals (e.g. 13:00 -> 15:00).
    nonisolated public func isQuietHours(
        at date: Date = Date(),
        quietStartHour: Int = 22,
        quietEndHour: Int = 8
    ) -> Bool {
        guard quietStartHour != quietEndHour else { return false }
        let calendar = Calendar.current
        let hour = calendar.component(.hour, from: date)
        
        if quietStartHour < quietEndHour {
            return hour >= quietStartHour && hour < quietEndHour
        } else {
            return hour >= quietStartHour || hour < quietEndHour
        }
    }
    
    /// Evaluates environmental and contextual signals to produce prioritized proactive nudges.
    /// Quiet hours suppress routine notifications, allowing only emergency critical battery warnings (< 10%).
    public func evaluateNudges(
        referenceDate: Date = Date(),
        batteryPercent: Int? = nil,
        isCharging: Bool = false,
        nextEventTitle: String? = nil,
        minutesToNextEvent: Int? = nil,
        quietStartHour: Int = 22,
        quietEndHour: Int = 8
    ) async throws -> [ProactiveNudge] {
        var nudges: [ProactiveNudge] = []
        let quiet = isQuietHours(at: referenceDate, quietStartHour: quietStartHour, quietEndHour: quietEndHour)
        
        // Critical emergency battery (< 10% and not charging) is ALWAYS emitted, even during quiet hours
        if let battery = batteryPercent, !isCharging, battery < 10 {
            nudges.append(ProactiveNudge(
                category: "battery",
                title: "Critical Battery",
                message: "Battery is critically low (\(battery)%). Plug in immediately.",
                priority: .urgent,
                createdAt: referenceDate
            ))
        }
        
        // If quiet hours are active, suppress all normal/high nudges
        if quiet {
            return nudges
        }
        
        // Outside quiet hours, evaluate:
        // 1. Impending meeting (starts within 15 minutes, >= 0) -> .high nudge
        if let mins = minutesToNextEvent, mins >= 0 && mins <= 15 {
            let title = nextEventTitle ?? "Upcoming Event"
            let msg = mins == 0 ? "Meeting '\(title)' is starting now." : "Meeting '\(title)' starts in \(mins) minute\(mins == 1 ? "" : "s")."
            nudges.append(ProactiveNudge(
                category: "calendar",
                title: "Upcoming Meeting: \(title)",
                message: msg,
                priority: .high,
                createdAt: referenceDate
            ))
        }
        
        // 2. Overdue tasks -> .urgent / .high nudge summarizing overdue items
        let overdue = try await taskStore.getOverdueTasks(asOf: referenceDate)
        if !overdue.isEmpty {
            let hasUrgent = overdue.contains { $0.priority == .urgent }
            let priority: TaskPriority = hasUrgent ? .urgent : .high
            let summary = overdue.prefix(3).map { $0.title }.joined(separator: ", ")
            let more = overdue.count > 3 ? " and \(overdue.count - 3) more" : ""
            nudges.append(ProactiveNudge(
                category: "tasks",
                title: "Overdue Tasks (\(overdue.count))",
                message: "\(overdue.count) overdue task(s): \(summary)\(more).",
                priority: priority,
                createdAt: referenceDate
            ))
        }
        
        // 3. Low battery (<= 20% and not charging; < 10% already emitted above with .urgent)
        if let battery = batteryPercent, !isCharging, battery >= 10 && battery <= 20 {
            nudges.append(ProactiveNudge(
                category: "battery",
                title: "Low Battery",
                message: "Battery level is low (\(battery)%). Connect to power soon.",
                priority: .high,
                createdAt: referenceDate
            ))
        }
        
        return nudges
    }
}
