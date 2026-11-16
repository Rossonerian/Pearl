import EventKit
import Foundation
import PearlCore

// MARK: - Local Calendar Store (Offline / Fallback)

public struct LocalCalendarEvent: Codable, Sendable {
    public let id: String
    public let title: String
    public let startDate: Date
    public let endDate: Date
    public let location: String?
    public let notes: String?
    public let calendarName: String?
    
    public init(
        id: String = UUID().uuidString,
        title: String,
        startDate: Date,
        endDate: Date,
        location: String? = nil,
        notes: String? = nil,
        calendarName: String? = "Pearl"
    ) {
        self.id = id
        self.title = title
        self.startDate = startDate
        self.endDate = endDate
        self.location = location
        self.notes = notes
        self.calendarName = calendarName
    }
}

public actor CalendarLocalStore {
    public static let shared = CalendarLocalStore()

    private let customStoreURL: URL?

    public init(localStoreURL: URL? = nil) {
        self.customStoreURL = localStoreURL
    }

    private var localStoreURL: URL {
        return customStoreURL ?? PearlStoragePaths.fileURL(named: "calendar_events.json")
    }
    
    public func loadEvents() -> [LocalCalendarEvent] {
        guard let data = try? Data(contentsOf: localStoreURL),
              let list = try? JSONDecoder().decode([LocalCalendarEvent].self, from: data) else {
            return []
        }
        return list
    }
    
    public func saveEvent(_ event: LocalCalendarEvent) {
        var events = loadEvents()
        events.removeAll(where: { $0.id == event.id })
        events.append(event)
        try? FileManager.default.createDirectory(
            at: localStoreURL.deletingLastPathComponent(),
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        if let data = try? JSONEncoder().encode(events) {
            try? data.write(to: localStoreURL, options: .atomic)
        }
    }
    
    public func removeEvent(id: String) {
        var events = loadEvents()
        events.removeAll(where: { $0.id == id })
        if let data = try? JSONEncoder().encode(events) {
            try? data.write(to: localStoreURL, options: .atomic)
        }
    }
}

// MARK: - Calendar Date Utilities

public enum CalendarDateHelper {
    public static func parseWindow(
        window: String?,
        startDateStr: String?,
        endDateStr: String?
    ) -> (start: Date, end: Date, description: String) {
        let calendar = Calendar.current
        let now = Date()
        
        // 1. Explicit start and end date
        if let s = startDateStr, let parsedStart = parseDate(s) {
            let parsedEnd: Date
            if let e = endDateStr, let pe = parseDate(e) {
                parsedEnd = pe
            } else {
                parsedEnd = calendar.date(byAdding: .hour, value: 1, to: parsedStart) ?? parsedStart.addingTimeInterval(3600)
            }
            let formatter = DateFormatter()
            formatter.dateStyle = .medium
            formatter.timeStyle = .short
            return (parsedStart, parsedEnd, "\(formatter.string(from: parsedStart)) to \(formatter.string(from: parsedEnd))")
        }
        
        let cleaned = (window ?? "today").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        
        if cleaned == "today" {
            let start = calendar.startOfDay(for: now)
            let end = calendar.date(bySettingHour: 23, minute: 59, second: 59, of: now) ?? now.addingTimeInterval(86400)
            return (start, end, "today")
        }
        
        if cleaned == "tomorrow" {
            guard let tomorrow = calendar.date(byAdding: .day, value: 1, to: now) else {
                return (now, now.addingTimeInterval(86400), "tomorrow")
            }
            let start = calendar.startOfDay(for: tomorrow)
            let end = calendar.date(bySettingHour: 23, minute: 59, second: 59, of: tomorrow) ?? tomorrow.addingTimeInterval(86400)
            return (start, end, "tomorrow")
        }
        
        if cleaned == "this week" {
            let start = calendar.startOfDay(for: now)
            let end = calendar.date(byAdding: .day, value: 7, to: start) ?? start.addingTimeInterval(7 * 86400)
            return (start, end, "this week")
        }
        
        // Parse "next N days" or "N days" or number "N"
        var days = 7
        let digits = cleaned.components(separatedBy: CharacterSet.decimalDigits.inverted).joined()
        if let num = Int(digits), num > 0 {
            days = num
        }
        
        let start = calendar.startOfDay(for: now)
        let end = calendar.date(byAdding: .day, value: days, to: start) ?? start.addingTimeInterval(Double(days) * 86400)
        return (start, end, "next \(days) days")
    }
    
    public static func parseDate(_ string: String) -> Date? {
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return nil }
        
        let calendar = Calendar.current
        let now = Date()
        let lower = trimmed.lowercased()
        
        // Check relative prefixes
        if lower.hasPrefix("today") {
            let timePart = trimmed.dropFirst(5).trimmingCharacters(in: CharacterSet(charactersIn: " at@"))
            if timePart.isEmpty {
                return calendar.startOfDay(for: now)
            }
            if let parsedTime = parseTimeOnDate(timePart, baseDate: now) {
                return parsedTime
            }
        }
        
        if lower.hasPrefix("tomorrow") {
            guard let tomorrow = calendar.date(byAdding: .day, value: 1, to: now) else { return nil }
            let timePart = trimmed.dropFirst(8).trimmingCharacters(in: CharacterSet(charactersIn: " at@"))
            if timePart.isEmpty {
                return calendar.startOfDay(for: tomorrow)
            }
            if let parsedTime = parseTimeOnDate(timePart, baseDate: tomorrow) {
                return parsedTime
            }
        }
        
        // ISO8601
        let isoFormatter = ISO8601DateFormatter()
        isoFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = isoFormatter.date(from: trimmed) { return d }
        isoFormatter.formatOptions = [.withInternetDateTime]
        if let d = isoFormatter.date(from: trimmed) { return d }
        
        // Standard formats
        let formatPatterns = [
            "yyyy-MM-dd HH:mm:ss",
            "yyyy-MM-dd HH:mm",
            "yyyy-MM-dd'T'HH:mm",
            "yyyy-MM-dd",
            "MM/dd/yyyy HH:mm",
            "MM/dd/yyyy",
            "h:mm a",
            "HH:mm"
        ]
        
        let df = DateFormatter()
        df.locale = Locale(identifier: "en_US_POSIX")
        for p in formatPatterns {
            df.dateFormat = p
            if let d = df.date(from: trimmed) {
                if p == "h:mm a" || p == "HH:mm" {
                    return parseTimeOnDate(trimmed, baseDate: now)
                }
                return d
            }
        }
        
        return nil
    }
    
    public static func parseTimeOnDate(_ timeStr: String, baseDate: Date) -> Date? {
        let calendar = Calendar.current
        let df = DateFormatter()
        df.locale = Locale(identifier: "en_US_POSIX")
        
        for p in ["h:mm a", "h a", "ha", "HH:mm", "H:mm"] {
            df.dateFormat = p
            if let t = df.date(from: timeStr) {
                let comp = calendar.dateComponents([.hour, .minute], from: t)
                var baseComp = calendar.dateComponents([.year, .month, .day], from: baseDate)
                baseComp.hour = comp.hour
                baseComp.minute = comp.minute
                baseComp.second = 0
                return calendar.date(from: baseComp)
            }
        }
        return nil
    }
    
    public static func parseDuration(_ durationStr: String?) -> TimeInterval {
        guard let d = durationStr?.lowercased().trimmingCharacters(in: .whitespacesAndNewlines), !d.isEmpty else {
            return 3600 // Default 1 hour
        }
        
        if d.hasSuffix("m") || d.hasSuffix("min") || d.hasSuffix("mins") || d.hasSuffix("minutes") {
            let digits = d.components(separatedBy: CharacterSet.decimalDigits.inverted).joined()
            if let minutes = Double(digits) {
                return minutes * 60
            }
        }
        
        if d.hasSuffix("h") || d.hasSuffix("hr") || d.hasSuffix("hrs") || d.hasSuffix("hours") {
            let digits = d.components(separatedBy: CharacterSet.decimalDigits.inverted).joined()
            if let hours = Double(digits) {
                return hours * 3600
            }
        }
        
        if let num = Double(d) {
            // If <= 12, assume hours; otherwise assume minutes
            if num <= 12 {
                return num * 3600
            } else {
                return num * 60
            }
        }
        
        return 3600
    }
}

// MARK: - Calendar Service Coordinator

public final class CalendarService: @unchecked Sendable {
    public static let shared = CalendarService()
    
    private let store = EKEventStore()
    private let lock = NSLock()
    
    public init() {}
    
    public func requestCalendarAccess() async -> Bool {
        let status = EKEventStore.authorizationStatus(for: .event)
        if #available(macOS 14.0, *) {
            if status == .fullAccess {
                return true
            }
            if status == .notDetermined {
                do {
                    return try await store.requestFullAccessToEvents()
                } catch {
                    return false
                }
            }
        } else {
            if status == .authorized {
                return true
            }
            if status == .notDetermined {
                return await withCheckedContinuation { continuation in
                    store.requestAccess(to: .event) { granted, _ in
                        continuation.resume(returning: granted)
                    }
                }
            }
        }
        return false
    }
    
    public func hasCalendarAccess() -> Bool {
        let status = EKEventStore.authorizationStatus(for: .event)
        if #available(macOS 14.0, *) {
            return status == .fullAccess
        } else {
            return status == .authorized
        }
    }
    
    public func ensureAccess() async -> Bool {
        if hasCalendarAccess() { return true }
        return await requestCalendarAccess()
    }
    
    public func fetchEvents(start: Date, end: Date) async -> [EKEvent] {
        guard await ensureAccess() else { return [] }
        
        return await Task.detached { [store] in
            let predicate = store.predicateForEvents(withStart: start, end: end, calendars: nil)
            return store.events(matching: predicate).sorted(by: { $0.startDate < $1.startDate })
        }.value
    }
    
    public func saveEvent(
        title: String,
        startDate: Date,
        endDate: Date,
        location: String?,
        notes: String?
    ) async throws -> String {
        guard await ensureAccess() else {
            throw CalendarError.permissionDenied
        }
        
        return try await Task.detached { [store] in
            guard let defaultCal = store.defaultCalendarForNewEvents ?? store.calendars(for: .event).first else {
                throw CalendarError.noDefaultCalendar
            }
            
            let event = EKEvent(eventStore: store)
            event.title = title
            event.startDate = startDate
            event.endDate = endDate
            event.location = location
            event.notes = notes
            event.calendar = defaultCal
            
            try store.save(event, span: .thisEvent, commit: true)
            return event.eventIdentifier
        }.value
    }
    
    public func deleteEvent(identifier: String) async throws -> Bool {
        guard await ensureAccess() else {
            throw CalendarError.permissionDenied
        }
        
        return try await Task.detached { [store] in
            guard let event = store.event(withIdentifier: identifier) else {
                return false
            }
            try store.remove(event, span: .thisEvent, commit: true)
            return true
        }.value
    }
    
    public func deleteEvent(matchingTitle title: String) async throws -> (deleted: Bool, title: String?, id: String?) {
        guard await ensureAccess() else {
            throw CalendarError.permissionDenied
        }
        
        return try await Task.detached { [store] in
            let now = Date()
            let calendar = Calendar.current
            let start = calendar.date(byAdding: .day, value: -30, to: now) ?? now.addingTimeInterval(-30 * 86400)
            let end = calendar.date(byAdding: .day, value: 60, to: now) ?? now.addingTimeInterval(60 * 86400)
            
            let predicate = store.predicateForEvents(withStart: start, end: end, calendars: nil)
            let matching = store.events(matching: predicate).filter {
                $0.title?.localizedCaseInsensitiveContains(title) == true
            }
            
            guard let eventToDelete = matching.first else {
                return (false, nil, nil)
            }
            
            let eventTitle = eventToDelete.title
            let eventID = eventToDelete.eventIdentifier
            try store.remove(eventToDelete, span: .thisEvent, commit: true)
            return (true, eventTitle, eventID)
        }.value
    }
}

public enum CalendarError: LocalizedError {
    case permissionDenied
    case noDefaultCalendar
    case eventNotFound(String)
    
    public var errorDescription: String? {
        switch self {
        case .permissionDenied:
            return "Calendar access was not granted by macOS. Please check System Settings > Privacy & Security > Calendars."
        case .noDefaultCalendar:
            return "No default calendar found on this Mac."
        case .eventNotFound(let query):
            return "Calendar event '\(query)' was not found."
        }
    }
}

// MARK: - Tool 1: list_calendar_events (Tier T0 Observe)

public final class ListCalendarEventsTool: PearlTool {
    public let name = "list_calendar_events"
    public let description = "List calendar events for a time window (e.g. today, tomorrow, next N days)"
    public let tier = ToolTier.t0Observe
    public let requiredTCC: [TCCService] = [.calendar]
    public let isReversible = false
    
    public var argumentDescriptors: [ToolArgumentDescriptor] {
        return [
            ToolArgumentDescriptor(
                name: "time_window",
                type: "string",
                description: "Window to query: 'today', 'tomorrow', 'this week', or 'next N days' (e.g. 'next 3 days')",
                isRequired: false
            ),
            ToolArgumentDescriptor(
                name: "start_date",
                type: "string",
                description: "Optional start date/time in ISO 8601 or 'yyyy-MM-dd HH:mm'",
                isRequired: false
            ),
            ToolArgumentDescriptor(
                name: "end_date",
                type: "string",
                description: "Optional end date/time in ISO 8601 or 'yyyy-MM-dd HH:mm'",
                isRequired: false
            )
        ]
    }
    
    public init() {}
    
    public func execute(args: [String: String], context: ToolExecutionContext) async throws -> ToolResult {
        let (start, end, windowDesc) = CalendarDateHelper.parseWindow(
            window: args["time_window"] ?? args["window"] ?? args["days"],
            startDateStr: args["start_date"] ?? args["start"],
            endDateStr: args["end_date"] ?? args["end"]
        )
        
        let ekEvents = await CalendarService.shared.fetchEvents(start: start, end: end)
        let localEvents = await CalendarLocalStore.shared.loadEvents().filter {
            $0.startDate < end && $0.endDate > start
        }
        
        let df = DateFormatter()
        df.dateStyle = .short
        df.timeStyle = .short
        
        var lines: [String] = []
        
        // Format EventKit events
        for (i, ev) in ekEvents.enumerated() {
            let title = ev.title ?? "Untitled Event"
            let sStr = df.string(from: ev.startDate)
            let eStr = df.string(from: ev.endDate)
            var locStr = ""
            if let loc = ev.location, !loc.isEmpty {
                locStr = " @ \(loc)"
            }
            let calName = ev.calendar?.title ?? "Calendar"
            lines.append("\(i + 1). [\(calName)] \(title)\(locStr) (\(sStr) – \(eStr)) [ID: \(ev.eventIdentifier ?? "")]")
        }
        
        // Include local fallback events not in EventKit
        let existingTitles = Set(ekEvents.compactMap { $0.title?.lowercased() })
        var localCount = 0
        for ev in localEvents where !existingTitles.contains(ev.title.lowercased()) {
            localCount += 1
            let sStr = df.string(from: ev.startDate)
            let eStr = df.string(from: ev.endDate)
            var locStr = ""
            if let loc = ev.location, !loc.isEmpty {
                locStr = " @ \(loc)"
            }
            let idx = ekEvents.count + localCount
            lines.append("\(idx). [Local] \(ev.title)\(locStr) (\(sStr) – \(eStr)) [ID: \(ev.id)]")
        }
        
        if lines.isEmpty {
            if !CalendarService.shared.hasCalendarAccess() {
                return ToolResult(
                    success: true,
                    message: "No calendar events found for \(windowDesc). (Note: macOS Calendar permission not granted; checked local store)."
                )
            }
            return ToolResult(success: true, message: "No calendar events found for \(windowDesc).")
        }
        
        let totalCount = lines.count
        let header = "Calendar events for \(windowDesc) (\(totalCount) found):\n"
        return ToolResult(success: true, message: header + lines.joined(separator: "\n"))
    }
}

// MARK: - Tool 2: check_calendar_availability (Tier T0 Observe)

public final class CheckCalendarAvailabilityTool: PearlTool {
    public let name = "check_calendar_availability"
    public let description = "Check for schedule conflicts within a specific date/time range"
    public let tier = ToolTier.t0Observe
    public let requiredTCC: [TCCService] = [.calendar]
    public let isReversible = false
    
    public var argumentDescriptors: [ToolArgumentDescriptor] {
        return [
            ToolArgumentDescriptor(
                name: "start_date",
                type: "string",
                description: "Start date/time of slot to check (e.g. '2026-11-14 14:00', 'today 3pm', or ISO 8601)",
                isRequired: true
            ),
            ToolArgumentDescriptor(
                name: "end_date",
                type: "string",
                description: "End date/time of slot to check",
                isRequired: false
            ),
            ToolArgumentDescriptor(
                name: "duration",
                type: "string",
                description: "Duration of proposed slot (e.g. '30m', '1h', '45'). Defaults to 1h if end_date omitted.",
                isRequired: false
            )
        ]
    }
    
    public init() {}
    
    public func execute(args: [String: String], context: ToolExecutionContext) async throws -> ToolResult {
        guard let startStr = args["start_date"] ?? args["start"] ?? args["time"] ?? args["date"],
              let startDate = CalendarDateHelper.parseDate(startStr) else {
            return ToolResult(success: false, message: "Missing or invalid 'start_date' for availability check.")
        }
        
        let endDate: Date
        if let endStr = args["end_date"] ?? args["end"], let parsedEnd = CalendarDateHelper.parseDate(endStr) {
            endDate = parsedEnd
        } else {
            let duration = CalendarDateHelper.parseDuration(args["duration"])
            endDate = startDate.addingTimeInterval(duration)
        }
        
        guard endDate > startDate else {
            return ToolResult(success: false, message: "End date must be after start date.")
        }
        
        let ekEvents = await CalendarService.shared.fetchEvents(start: startDate, end: endDate)
        let localEvents = await CalendarLocalStore.shared.loadEvents().filter {
            $0.startDate < endDate && $0.endDate > startDate
        }
        
        var conflicts: [String] = []
        let df = DateFormatter()
        df.dateStyle = .none
        df.timeStyle = .short
        
        for ev in ekEvents {
            if !ev.isAllDay && ev.startDate < endDate && ev.endDate > startDate {
                let title = ev.title ?? "Busy"
                conflicts.append("'\(title)' (\(df.string(from: ev.startDate)) – \(df.string(from: ev.endDate)))")
            }
        }
        
        for ev in localEvents {
            if ev.startDate < endDate && ev.endDate > startDate {
                conflicts.append("'\(ev.title)' (\(df.string(from: ev.startDate)) – \(df.string(from: ev.endDate)))")
            }
        }
        
        let fullFormatter = DateFormatter()
        fullFormatter.dateStyle = .medium
        fullFormatter.timeStyle = .short
        let slotDesc = "\(fullFormatter.string(from: startDate)) to \(df.string(from: endDate))"
        
        if conflicts.isEmpty {
            return ToolResult(
                success: true,
                message: "Slot is available. No conflicting events found for \(slotDesc)."
            )
        } else {
            let conflictList = conflicts.joined(separator: ", ")
            return ToolResult(
                success: true,
                message: "Schedule conflict detected for \(slotDesc): \(conflicts.count) event(s) conflict: \(conflictList)."
            )
        }
    }
}

// MARK: - Tool 3: create_calendar_event (Tier T1 Reversible)

public final class CreateCalendarEventTool: PearlTool {
    public let name = "create_calendar_event"
    public let description = "Create a calendar event with title, start date, end date, location, and notes with instant undo"
    public let tier = ToolTier.t1Reversible
    public let requiredTCC: [TCCService] = [.calendar]
    public let isReversible = true
    
    public var argumentDescriptors: [ToolArgumentDescriptor] {
        return [
            ToolArgumentDescriptor(
                name: "title",
                type: "string",
                description: "Title or summary of the event",
                isRequired: true
            ),
            ToolArgumentDescriptor(
                name: "start_date",
                type: "string",
                description: "Start date/time (ISO 8601, 'yyyy-MM-dd HH:mm', or 'today 14:00')",
                isRequired: true
            ),
            ToolArgumentDescriptor(
                name: "end_date",
                type: "string",
                description: "End date/time of the event (optional if duration provided)",
                isRequired: false
            ),
            ToolArgumentDescriptor(
                name: "duration",
                type: "string",
                description: "Duration of the event (e.g. '30m', '1h', '90m'). Defaults to 1h.",
                isRequired: false
            ),
            ToolArgumentDescriptor(
                name: "location",
                type: "string",
                description: "Physical location or meeting URL",
                isRequired: false
            ),
            ToolArgumentDescriptor(
                name: "notes",
                type: "string",
                description: "Notes or description for the event",
                isRequired: false
            )
        ]
    }
    
    public init() {}
    
    public func execute(args: [String: String], context: ToolExecutionContext) async throws -> ToolResult {
        let title = args["title"] ?? args["name"] ?? args["text"] ?? "Pearl Event"
        
        guard let startStr = args["start_date"] ?? args["start"] ?? args["time"],
              let startDate = CalendarDateHelper.parseDate(startStr) else {
            return ToolResult(success: false, message: "Missing or invalid 'start_date' for event creation.")
        }
        
        let endDate: Date
        if let endStr = args["end_date"] ?? args["end"], let parsedEnd = CalendarDateHelper.parseDate(endStr) {
            endDate = parsedEnd
        } else {
            let duration = CalendarDateHelper.parseDuration(args["duration"])
            endDate = startDate.addingTimeInterval(duration)
        }
        
        let location = args["location"]
        let notes = args["notes"] ?? args["description"]
        
        var createdEventID: String? = nil
        var destination = "Apple Calendar"
        
        do {
            createdEventID = try await CalendarService.shared.saveEvent(
                title: title,
                startDate: startDate,
                endDate: endDate,
                location: location,
                notes: notes
            )
        } catch {
            // Fallback to local store
            destination = "Local Calendar"
            let localEvent = LocalCalendarEvent(
                title: title,
                startDate: startDate,
                endDate: endDate,
                location: location,
                notes: notes
            )
            await CalendarLocalStore.shared.saveEvent(localEvent)
            createdEventID = localEvent.id
        }
        
        // Also save copy into local store for consistent offline lookup
        let localEvent = LocalCalendarEvent(
            id: createdEventID ?? UUID().uuidString,
            title: title,
            startDate: startDate,
            endDate: endDate,
            location: location,
            notes: notes
        )
        await CalendarLocalStore.shared.saveEvent(localEvent)
        
        let capturedID = createdEventID
        let undoAction: @Sendable () async throws -> Void = {
            if let id = capturedID {
                _ = try? await CalendarService.shared.deleteEvent(identifier: id)
                await CalendarLocalStore.shared.removeEvent(id: id)
            }
        }
        
        // Register with UndoJournal
        await UndoJournal.shared.register(toolName: "create_calendar_event", undoAction: undoAction)
        
        let df = DateFormatter()
        df.dateStyle = .medium
        df.timeStyle = .short
        let timeDesc = "\(df.string(from: startDate)) – \(df.string(from: endDate))"
        var locDesc = ""
        if let loc = location, !loc.isEmpty {
            locDesc = " at \(loc)"
        }
        
        return ToolResult(
            success: true,
            message: "Created event '\(title)' in \(destination) for \(timeDesc)\(locDesc).",
            undoAction: undoAction
        )
    }
}

// MARK: - Tool 4: delete_calendar_event (Tier T2 Irreversible / Dangerous)

public final class DeleteCalendarEventTool: PearlTool {
    public let name = "delete_calendar_event"
    public let description = "Cancel or delete a calendar event by ID or title (requires explicit confirmation)"
    public let tier = ToolTier.t2ReadPersonal
    public let requiredTCC: [TCCService] = [.calendar]
    public let isReversible = false
    
    public var argumentDescriptors: [ToolArgumentDescriptor] {
        return [
            ToolArgumentDescriptor(
                name: "id",
                type: "string",
                description: "Unique identifier of the calendar event to delete",
                isRequired: false
            ),
            ToolArgumentDescriptor(
                name: "title",
                type: "string",
                description: "Title of the calendar event to delete",
                isRequired: false
            ),
            ToolArgumentDescriptor(
                name: "confirm",
                type: "string",
                description: "Explicit confirmation flag ('true') to proceed with deletion",
                isRequired: false
            )
        ]
    }
    
    public init() {}
    
    public func execute(args: [String: String], context: ToolExecutionContext) async throws -> ToolResult {
        let eventID = args["id"] ?? args["event_id"]
        let titleQuery = args["title"] ?? args["name"]
        
        guard (eventID != nil && !eventID!.isEmpty) || (titleQuery != nil && !titleQuery!.isEmpty) else {
            return ToolResult(success: false, message: "Missing 'id' or 'title' of the event to delete.")
        }
        
        let targetDesc = eventID ?? titleQuery!
        
        // User confirmation verification
        let isConfirmed = context.userConfirmed
        guard isConfirmed else {
            return ToolResult(
                success: false,
                message: "Confirmation required: Deleting calendar event '\(targetDesc)' is irreversible. User confirmation required via HUD prompt or --confirm."
            )
        }
        
        var deletedAny = false
        var deletedTitle: String? = nil
        
        if let id = eventID, !id.isEmpty {
            if let success = try? await CalendarService.shared.deleteEvent(identifier: id), success {
                deletedAny = true
                deletedTitle = id
            }
            await CalendarLocalStore.shared.removeEvent(id: id)
            deletedAny = true
        } else if let title = titleQuery, !title.isEmpty {
            if let res = try? await CalendarService.shared.deleteEvent(matchingTitle: title), res.deleted {
                deletedAny = true
                deletedTitle = res.title ?? title
                if let id = res.id {
                    await CalendarLocalStore.shared.removeEvent(id: id)
                }
            } else {
                // Check local store
                let localEvents = await CalendarLocalStore.shared.loadEvents()
                if let match = localEvents.first(where: { $0.title.localizedCaseInsensitiveContains(title) }) {
                    await CalendarLocalStore.shared.removeEvent(id: match.id)
                    deletedAny = true
                    deletedTitle = match.title
                }
            }
        }
        
        if deletedAny {
            let name = deletedTitle ?? targetDesc
            return ToolResult(success: true, message: "Deleted calendar event '\(name)'.")
        } else {
            return ToolResult(success: false, message: "Could not find calendar event '\(targetDesc)' to delete.")
        }
    }
}

// MARK: - Unified CalendarTool Router

public final class CalendarTool: PearlTool {
    public let name = "calendar"
    public let description = "Comprehensive macOS calendar management (list events, check availability, create and delete events)"
    public let tier = ToolTier.t1Reversible
    public let requiredTCC: [TCCService] = [.calendar]
    public let isReversible = true
    
    private let listTool = ListCalendarEventsTool()
    private let checkTool = CheckCalendarAvailabilityTool()
    private let createTool = CreateCalendarEventTool()
    private let deleteTool = DeleteCalendarEventTool()
    
    public init() {}
    
    public func execute(args: [String: String], context: ToolExecutionContext) async throws -> ToolResult {
        let action = args["action"]?.lowercased() ?? "list"
        switch action {
        case "list", "get", "query":
            return try await listTool.execute(args: args, context: context)
        case "check", "availability", "conflict":
            return try await checkTool.execute(args: args, context: context)
        case "create", "add", "new":
            return try await createTool.execute(args: args, context: context)
        case "delete", "remove", "cancel":
            return try await deleteTool.execute(args: args, context: context)
        default:
            if args["title"] != nil && args["start_date"] != nil {
                return try await createTool.execute(args: args, context: context)
            }
            return try await listTool.execute(args: args, context: context)
        }
    }
}
