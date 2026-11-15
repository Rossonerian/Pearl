import EventKit
import Foundation
import PearlCore

/// Persistent local reminder record used for offline/test isolation and EventKit synchronization.
public struct LocalReminderItem: Codable, Sendable, Equatable {
    public let id: String
    public var title: String
    public var isCompleted: Bool
    public let createdAt: Date
    public var completedAt: Date?
    public var eventKitIdentifier: String?

    public init(
        id: String = UUID().uuidString,
        title: String,
        isCompleted: Bool = false,
        createdAt: Date = Date(),
        completedAt: Date? = nil,
        eventKitIdentifier: String? = nil
    ) {
        self.id = id
        self.title = title
        self.isCompleted = isCompleted
        self.createdAt = createdAt
        self.completedAt = completedAt
        self.eventKitIdentifier = eventKitIdentifier
    }
}

public final class ReminderTool: PearlTool {
    public let name = "reminder"
    public let description = "Create, list, or complete reminders in Apple Reminders with instant undo support"
    public let tier = ToolTier.t1Reversible
    public let requiredTCC: [TCCService] = [.reminders]
    public let isReversible = true

    public var argumentDescriptors: [ToolArgumentDescriptor] {
        return [
            ToolArgumentDescriptor(
                name: "action",
                type: "string",
                description: "Action: create, list, or complete (default create)",
                isRequired: false,
                allowedValues: ["create", "list", "complete"]
            ),
            ToolArgumentDescriptor(
                name: "title",
                type: "string",
                description: "Reminder title (required for create/complete)",
                isRequired: false
            ),
            ToolArgumentDescriptor(
                name: "id",
                type: "string",
                description: "Reminder ID prefix or UUID (for complete)",
                isRequired: false
            )
        ]
    }

    private let customStoreURL: URL?
    private let storeLock = NSLock()

    public init(localStoreURL: URL? = nil) {
        self.customStoreURL = localStoreURL
    }

    private var localStoreURL: URL {
        return customStoreURL ?? PearlStoragePaths.fileURL(named: "reminders.json")
    }

    public func execute(args: [String: String], context: ToolExecutionContext) async throws -> ToolResult {
        let rawAction = args["action"]?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let hasTitle = !(args["title"] ?? args["text"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let action: String
        if let rawAction = rawAction, !rawAction.isEmpty {
            action = rawAction
        } else {
            action = hasTitle ? "create" : "list"
        }

        switch action {
        case "list", "show", "get":
            return await listReminders()
        case "create", "add", "new":
            let rawTitle = (args["title"] ?? args["text"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !rawTitle.isEmpty else {
                return ToolResult(
                    success: false,
                    message: "Missing required 'title' argument for creating a reminder.",
                    errorCode: .invalidArguments
                )
            }
            return await createReminder(title: rawTitle)
        case "complete", "done", "finish":
            let idQuery = args["id"]?.trimmingCharacters(in: .whitespacesAndNewlines)
            let titleQuery = (args["title"] ?? args["text"])?.trimmingCharacters(in: .whitespacesAndNewlines)
            return await completeReminder(idQuery: idQuery, titleQuery: titleQuery)
        default:
            return ToolResult(
                success: false,
                message: "Unsupported reminder action '\(action)'. Supported actions: create, list, complete.",
                errorCode: .invalidArguments
            )
        }
    }

    // MARK: - Actions

    private func listReminders() async -> ToolResult {
        var displayEntries: [(id: String, title: String)] = []
        var seenEKIDs = Set<String>()
        var seenLowerTitles = Set<String>()

        if customStoreURL == nil && Self.isEventKitAuthorized() {
            let ekItems = await fetchActiveEventKitReminders()
            for item in ekItems {
                seenEKIDs.insert(item.id)
                seenLowerTitles.insert(item.title.lowercased())
                displayEntries.append((id: String(item.id.prefix(8)), title: item.title))
            }
        }

        let localActive = loadLocalReminders().filter { !$0.isCompleted }
        for item in localActive {
            if let ekID = item.eventKitIdentifier, seenEKIDs.contains(ekID) {
                continue
            }
            if seenLowerTitles.contains(item.title.lowercased()) {
                continue
            }
            seenLowerTitles.insert(item.title.lowercased())
            displayEntries.append((id: String(item.id.prefix(8)), title: item.title))
        }

        if displayEntries.isEmpty {
            return ToolResult(
                success: true,
                message: "No active reminders found.",
                errorCode: .completed
            )
        }

        let formatted = displayEntries.prefix(25).enumerated().map { idx, entry in
            "\(idx + 1). \(entry.title) [ID: \(entry.id)]"
        }.joined(separator: "; ")

        return ToolResult(
            success: true,
            message: "Reminders (\(displayEntries.count)): \(formatted)",
            errorCode: .completed
        )
    }

    private func createReminder(title: String) async -> ToolResult {
        var ekSaved = false
        var reminderID: String? = nil

        if customStoreURL == nil {
            let authorized = await ensureEventKitAccessIfInteractive()
            if authorized {
                let store = EKEventStore()
                if let defaultCal = store.defaultCalendarForNewReminders() {
                    let rem = EKReminder(eventStore: store)
                    rem.title = title
                    rem.calendar = defaultCal
                    if (try? store.save(rem, commit: true)) != nil {
                        ekSaved = true
                        reminderID = rem.calendarItemIdentifier
                    }
                }
            }
        }

        let item = LocalReminderItem(
            title: title,
            isCompleted: false,
            eventKitIdentifier: reminderID
        )
        mutateLocalReminders { list in
            list.append(item)
        }

        let createdLocalID = item.id
        let capturedReminderID = reminderID
        let fileURL = self.localStoreURL
        let lock = self.storeLock

        let undoAction: @Sendable () async throws -> Void = {
            if let rId = capturedReminderID {
                let undoStore = EKEventStore()
                if let ekItem = undoStore.calendarItem(withIdentifier: rId) as? EKReminder {
                    try? undoStore.remove(ekItem, commit: true)
                }
            }
            Self.mutateLocalReminders(at: fileURL, lock: lock) { items in
                items.removeAll { $0.id == createdLocalID }
            }
        }

        let destination = ekSaved ? "Apple Reminders" : "Reminders"
        let shortID = String(item.id.prefix(8))
        return ToolResult(
            success: true,
            message: "Added '\(title)' to \(destination) [ID: \(shortID)].",
            undoAction: undoAction,
            errorCode: .completed
        )
    }

    private func completeReminder(idQuery: String?, titleQuery: String?) async -> ToolResult {
        let cleanID = (idQuery ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanTitle = (titleQuery ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanID.isEmpty || !cleanTitle.isEmpty else {
            return ToolResult(
                success: false,
                message: "Missing 'id' or 'title' of the reminder to complete.",
                errorCode: .invalidArguments
            )
        }

        let queryDesc = !cleanID.isEmpty ? cleanID : cleanTitle
        var completedEKID: String? = nil
        var completedTitle: String? = nil
        var completedLocalID: String? = nil

        // 1. Check EventKit if authorized (and not using an isolated custom store URL)
        if customStoreURL == nil && Self.isEventKitAuthorized() {
            let ekItems = await fetchActiveEventKitReminders()
            if let matched = Self.findBestMatch(
                in: ekItems,
                idOf: { $0.id },
                titleOf: { $0.title },
                idQuery: cleanID,
                titleQuery: cleanTitle
            ) {
                let store = EKEventStore()
                if let ekReminder = store.calendarItem(withIdentifier: matched.id) as? EKReminder {
                    ekReminder.isCompleted = true
                    if (try? store.save(ekReminder, commit: true)) != nil {
                        completedEKID = matched.id
                        completedTitle = matched.title
                    }
                }
            }
        }

        // 2. Check and update local fallback store
        mutateLocalReminders { items in
            let activePairs = items.enumerated().filter { !$0.element.isCompleted }
            if let ekID = completedEKID,
               let idx = activePairs.first(where: { $0.element.eventKitIdentifier == ekID })?.offset {
                items[idx].isCompleted = true
                items[idx].completedAt = Date()
                completedLocalID = items[idx].id
                if completedTitle == nil { completedTitle = items[idx].title }
                return
            }

            if let match = Self.findBestMatch(
                in: activePairs,
                idOf: { $0.element.id },
                titleOf: { $0.element.title },
                idQuery: cleanID,
                titleQuery: cleanTitle
            ) {
                items[match.offset].isCompleted = true
                items[match.offset].completedAt = Date()
                completedLocalID = items[match.offset].id
                if completedTitle == nil { completedTitle = items[match.offset].title }
            }
        }

        guard completedEKID != nil || completedLocalID != nil else {
            return ToolResult(
                success: false,
                message: "No active reminder found matching '\(queryDesc)'.",
                errorCode: .invalidArguments
            )
        }

        let finalTitle = completedTitle ?? queryDesc
        let displayID = String((completedLocalID ?? completedEKID ?? cleanID).prefix(8))
        let capturedEKID = completedEKID
        let capturedLocalID = completedLocalID
        let fileURL = self.localStoreURL
        let lock = self.storeLock

        let undoAction: @Sendable () async throws -> Void = {
            if let ekID = capturedEKID {
                let undoStore = EKEventStore()
                if let ekReminder = undoStore.calendarItem(withIdentifier: ekID) as? EKReminder {
                    ekReminder.isCompleted = false
                    try undoStore.save(ekReminder, commit: true)
                }
            }
            if let localID = capturedLocalID {
                Self.mutateLocalReminders(at: fileURL, lock: lock) { items in
                    if let idx = items.firstIndex(where: { $0.id == localID }) {
                        items[idx].isCompleted = false
                        items[idx].completedAt = nil
                    }
                }
            }
        }

        return ToolResult(
            success: true,
            message: "Completed reminder '\(finalTitle)' [ID: \(displayID)].",
            undoAction: undoAction,
            errorCode: .completed
        )
    }

    // MARK: - EventKit Helpers

    private struct EKReminderSnapshot: Sendable {
        let id: String
        let title: String
    }

    private static func isEventKitAuthorized() -> Bool {
        let status = EKEventStore.authorizationStatus(for: .reminder)
        if #available(macOS 14.0, *) {
            return status == .fullAccess
        } else {
            return status == .authorized
        }
    }

    private func ensureEventKitAccessIfInteractive() async -> Bool {
        if Self.isEventKitAuthorized() {
            return true
        }
        guard !PearlStoragePaths.isRunningTests else {
            return false
        }
        let hasUsageDescription =
            Bundle.main.object(forInfoDictionaryKey: "NSRemindersFullAccessUsageDescription") != nil ||
            Bundle.main.object(forInfoDictionaryKey: "NSRemindersUsageDescription") != nil
        guard hasUsageDescription else {
            return false
        }

        let status = EKEventStore.authorizationStatus(for: .reminder)
        guard status == .notDetermined else {
            return false
        }
        let store = EKEventStore()
        if #available(macOS 14.0, *) {
            return (try? await store.requestFullAccessToReminders()) ?? false
        } else {
            return await withCheckedContinuation { continuation in
                store.requestAccess(to: .reminder) { ok, _ in
                    continuation.resume(returning: ok)
                }
            }
        }
    }

    private func fetchActiveEventKitReminders() async -> [EKReminderSnapshot] {
        let store = EKEventStore()
        let predicate = store.predicateForIncompleteReminders(withDueDateStarting: nil, ending: nil, calendars: nil)
        return await withCheckedContinuation { continuation in
            store.fetchReminders(matching: predicate) { items in
                let snapshots = (items ?? [])
                    .filter { !$0.isCompleted }
                    .map { EKReminderSnapshot(id: $0.calendarItemIdentifier, title: $0.title ?? "Untitled") }
                continuation.resume(returning: snapshots)
            }
        }
    }

    // MARK: - Local Store & Matching Helpers

    private static func findBestMatch<T>(
        in candidates: [T],
        idOf: (T) -> String,
        titleOf: (T) -> String,
        idQuery: String,
        titleQuery: String
    ) -> T? {
        let lowerID = idQuery.lowercased()
        let lowerTitle = titleQuery.lowercased()

        if !lowerID.isEmpty {
            if let exact = candidates.first(where: { idOf($0).lowercased() == lowerID }) {
                return exact
            }
            if let prefix = candidates.first(where: { idOf($0).lowercased().hasPrefix(lowerID) }) {
                return prefix
            }
        }

        if !lowerTitle.isEmpty {
            if let exactTitle = candidates.first(where: { titleOf($0).lowercased() == lowerTitle }) {
                return exactTitle
            }
            if let idPrefix = candidates.first(where: { idOf($0).lowercased().hasPrefix(lowerTitle) }) {
                return idPrefix
            }
            if let partialTitle = candidates.first(where: { titleOf($0).localizedCaseInsensitiveContains(titleQuery) }) {
                return partialTitle
            }
        }

        return nil
    }

    private func loadLocalReminders() -> [LocalReminderItem] {
        storeLock.lock()
        defer { storeLock.unlock() }
        return Self.readLocalReminders(from: localStoreURL)
    }

    private func mutateLocalReminders(_ update: (inout [LocalReminderItem]) -> Void) {
        Self.mutateLocalReminders(at: localStoreURL, lock: storeLock, update: update)
    }

    private static func readLocalReminders(from url: URL) -> [LocalReminderItem] {
        guard let data = try? Data(contentsOf: url) else {
            return []
        }
        if let structured = try? JSONDecoder().decode([LocalReminderItem].self, from: data) {
            return structured
        }
        if let legacyTitles = try? JSONDecoder().decode([String].self, from: data) {
            return legacyTitles.map { LocalReminderItem(title: $0) }
        }
        return []
    }

    private static func mutateLocalReminders(
        at url: URL,
        lock: NSLock,
        update: (inout [LocalReminderItem]) -> Void
    ) {
        lock.lock()
        defer { lock.unlock() }
        var items = readLocalReminders(from: url)
        update(&items)
        let dir = url.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [
            .posixPermissions: 0o700
        ])
        if let data = try? JSONEncoder().encode(items) {
            try? data.write(to: url, options: .atomic)
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        }
    }
}
