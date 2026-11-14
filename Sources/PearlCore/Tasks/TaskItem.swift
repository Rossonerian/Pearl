import Foundation

/// Priority level for tasks within Pearl V3.
public enum TaskPriority: String, Codable, Sendable, Comparable, CaseIterable, CustomStringConvertible {
    case low = "low"
    case medium = "medium"
    case high = "high"
    case urgent = "urgent"
    
    public var description: String {
        return rawValue
    }
    
    public var displayName: String {
        switch self {
        case .low: return "Low"
        case .medium: return "Medium"
        case .high: return "High"
        case .urgent: return "Urgent"
        }
    }
    
    public var badge: String {
        switch self {
        case .low: return "⚪️ [Low]"
        case .medium: return "🔵 [Medium]"
        case .high: return "🟠 [High]"
        case .urgent: return "🔴 [Urgent]"
        }
    }
    
    private var sortOrder: Int {
        switch self {
        case .low: return 0
        case .medium: return 1
        case .high: return 2
        case .urgent: return 3
        }
    }
    
    public static func < (lhs: TaskPriority, rhs: TaskPriority) -> Bool {
        return lhs.sortOrder < rhs.sortOrder
    }
    
    public static func fromString(_ str: String?) -> TaskPriority {
        guard let s = str?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() else {
            return .medium
        }
        return TaskPriority(rawValue: s) ?? .medium
    }
}

/// Lifecycle status of a task.
public enum TaskStatus: String, Codable, Sendable, CaseIterable, CustomStringConvertible {
    case pending = "pending"
    case completed = "completed"
    case cancelled = "cancelled"
    
    public var description: String {
        return rawValue
    }
    
    public var displayName: String {
        switch self {
        case .pending: return "Pending"
        case .completed: return "Completed"
        case .cancelled: return "Cancelled"
        }
    }
    
    public static func fromString(_ str: String?) -> TaskStatus? {
        guard let s = str?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(), !s.isEmpty else {
            return nil
        }
        return TaskStatus(rawValue: s)
    }
}

/// Represents an individual task item stored in SQLite.
public struct TaskItem: Identifiable, Codable, Sendable, Equatable {
    public let id: UUID
    public var title: String
    public var notes: String?
    public var priority: TaskPriority
    public var status: TaskStatus
    public var dueDate: Date?
    public var createdAt: Date
    public var updatedAt: Date
    public var completedAt: Date?
    
    public init(
        id: UUID = UUID(),
        title: String,
        notes: String? = nil,
        priority: TaskPriority = .medium,
        status: TaskStatus = .pending,
        dueDate: Date? = nil,
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        completedAt: Date? = nil
    ) {
        self.id = id
        self.title = title
        self.notes = notes
        self.priority = priority
        self.status = status
        self.dueDate = dueDate
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.completedAt = completedAt
    }
    
    /// Indicates whether this pending task is past its due date.
    public func isOverdue(asOf referenceDate: Date = Date()) -> Bool {
        guard status == .pending, let due = dueDate else { return false }
        return due < referenceDate
    }
    
    /// ISO-8601 string representation of due date.
    public var dueDateISO8601: String? {
        guard let due = dueDate else { return nil }
        return TaskDateFormatter.isoString(from: due)
    }
    
    /// ISO-8601 string representation of creation date.
    public var createdAtISO8601: String {
        return TaskDateFormatter.isoString(from: createdAt)
    }
    
    /// ISO-8601 string representation of update date.
    public var updatedAtISO8601: String {
        return TaskDateFormatter.isoString(from: updatedAt)
    }
    
    /// ISO-8601 string representation of completion date.
    public var completedAtISO8601: String? {
        guard let completed = completedAt else { return nil }
        return TaskDateFormatter.isoString(from: completed)
    }
    
    /// Human-readable concise single-line description of the task.
    public var formattedSummary: String {
        var parts: [String] = []
        parts.append("\(priority.badge) \(title)")
        
        if let due = dueDate {
            let dueStr = TaskDateFormatter.displayString(from: due)
            if isOverdue() {
                parts.append("(⚠️ Overdue: \(dueStr))")
            } else {
                parts.append("(Due: \(dueStr))")
            }
        }
        
        if status != .pending {
            parts.append("[\(status.displayName)]")
        }
        
        parts.append("(ID: \(id.uuidString.prefix(8)))")
        return parts.joined(separator: " ")
    }
}

/// Helper for standard ISO-8601 and friendly date conversions.
public enum TaskDateFormatter {
    private static let isoFormatterWithFractional: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    
    private static let standardISOFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()
    
    private static let displayDateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .short
        f.locale = Locale.current
        return f
    }()
    
    public static func isoString(from date: Date) -> String {
        return isoFormatterWithFractional.string(from: date)
    }
    
    public static func parseDate(_ string: String?) -> Date? {
        guard let str = string?.trimmingCharacters(in: .whitespacesAndNewlines), !str.isEmpty else {
            return nil
        }
        if let d = isoFormatterWithFractional.date(from: str) {
            return d
        }
        if let d = standardISOFormatter.date(from: str) {
            return d
        }
        // Try fallback date-only ISO-8601 (e.g. 2026-11-14)
        let dateOnlyFormatter = DateFormatter()
        dateOnlyFormatter.dateFormat = "yyyy-MM-dd"
        dateOnlyFormatter.locale = Locale(identifier: "en_US_POSIX")
        dateOnlyFormatter.timeZone = TimeZone.current
        if let d = dateOnlyFormatter.date(from: str) {
            // Set to end of that day (23:59:59)
            return Calendar.current.date(bySettingHour: 23, minute: 59, second: 59, of: d) ?? d
        }
        return nil
    }
    
    public static func displayString(from date: Date) -> String {
        return displayDateFormatter.string(from: date)
    }
}
