import Foundation
import SQLite3

public enum TaskStoreError: Error, LocalizedError, Sendable {
    case databaseOpenFailed(String)
    case executionFailed(String)
    case taskNotFound(UUID)
    case invalidParameter(String)
    
    public var errorDescription: String? {
        switch self {
        case .databaseOpenFailed(let msg): return "TaskStore DB open failed: \(msg)"
        case .executionFailed(let msg): return "TaskStore SQL error: \(msg)"
        case .taskNotFound(let id): return "Task not found with ID: \(id.uuidString)"
        case .invalidParameter(let msg): return "Invalid parameter: \(msg)"
        }
    }
}

/// Structured, lightweight SQLite task storage engine.
/// Zero external dependencies beyond SQLite3.
/// Default location: ~/Library/Application Support/Pearl/tasks.sqlite
public actor TaskStore {
    public static let defaultDatabaseURL: URL = {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let pearlDir = appSupport.appendingPathComponent("Pearl", isDirectory: true)
        try? FileManager.default.createDirectory(at: pearlDir, withIntermediateDirectories: true, attributes: [
            .posixPermissions: 0o700
        ])
        return pearlDir.appendingPathComponent("tasks.sqlite")
    }()
    
    public static let shared: TaskStore = {
        do {
            return try TaskStore()
        } catch {
            fatalError("Failed to initialize default TaskStore: \(error)")
        }
    }()
    
    public nonisolated let databaseURL: URL
    private var db: OpaquePointer?
    
    private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
    
    public init(databaseURL: URL? = nil) throws {
        let url = databaseURL ?? Self.defaultDatabaseURL
        self.databaseURL = url
        
        let dir = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [
            .posixPermissions: 0o700
        ])
        
        var dbPointer: OpaquePointer?
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
        let rc = sqlite3_open_v2(url.path, &dbPointer, flags, nil)
        guard rc == SQLITE_OK, let db = dbPointer else {
            let errMsg = dbPointer != nil ? String(cString: sqlite3_errmsg(dbPointer)) : "Unknown"
            if let dbPointer = dbPointer { sqlite3_close_v2(dbPointer) }
            throw TaskStoreError.databaseOpenFailed("Failed to open SQLite database at \(url.path): \(errMsg)")
        }
        
        // WAL mode, high-performance concurrency pragmas
        sqlite3_exec(db, "PRAGMA journal_mode = WAL;", nil, nil, nil)
        sqlite3_exec(db, "PRAGMA synchronous = NORMAL;", nil, nil, nil)
        sqlite3_exec(db, "PRAGMA busy_timeout = 5000;", nil, nil, nil)
        sqlite3_exec(db, "PRAGMA foreign_keys = ON;", nil, nil, nil)
        
        let createTableSQL = """
        CREATE TABLE IF NOT EXISTS tasks (
            id TEXT PRIMARY KEY NOT NULL,
            title TEXT NOT NULL,
            notes TEXT,
            priority TEXT NOT NULL,
            status TEXT NOT NULL,
            due_date TEXT,
            created_at TEXT NOT NULL,
            updated_at TEXT NOT NULL,
            completed_at TEXT
        );
        CREATE INDEX IF NOT EXISTS idx_tasks_status ON tasks(status);
        CREATE INDEX IF NOT EXISTS idx_tasks_priority ON tasks(priority);
        CREATE INDEX IF NOT EXISTS idx_tasks_due_date ON tasks(due_date);
        """
        
        var errMsg: UnsafeMutablePointer<CChar>?
        if sqlite3_exec(db, createTableSQL, nil, nil, &errMsg) != SQLITE_OK {
            let msg = errMsg != nil ? String(cString: errMsg!) : "Unknown"
            sqlite3_free(errMsg)
            sqlite3_close_v2(db)
            throw TaskStoreError.executionFailed("Failed to initialize tasks schema: \(msg)")
        }
        
        self.db = db
    }
    
    deinit {
        if let db = db {
            sqlite3_close_v2(db)
        }
    }
    
    // MARK: - Core CRUD Operations
    
    /// Create a new task item and persist to SQLite.
    @discardableResult
    public func createTask(
        title: String,
        notes: String? = nil,
        priority: TaskPriority = .medium,
        dueDate: Date? = nil,
        id: UUID = UUID()
    ) throws -> TaskItem {
        guard let db = db else {
            throw TaskStoreError.executionFailed("Database not open")
        }
        
        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedTitle.isEmpty else {
            throw TaskStoreError.invalidParameter("Task title cannot be empty")
        }
        
        let now = Date()
        let task = TaskItem(
            id: id,
            title: trimmedTitle,
            notes: notes?.trimmingCharacters(in: .whitespacesAndNewlines),
            priority: priority,
            status: .pending,
            dueDate: dueDate,
            createdAt: now,
            updatedAt: now,
            completedAt: nil
        )
        
        let sql = """
        INSERT INTO tasks (id, title, notes, priority, status, due_date, created_at, updated_at, completed_at)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?);
        """
        
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            let msg = String(cString: sqlite3_errmsg(db))
            throw TaskStoreError.executionFailed("Prepare insert failed: \(msg)")
        }
        defer { sqlite3_finalize(stmt) }
        
        bindTaskParameters(task, to: stmt)
        
        guard sqlite3_step(stmt) == SQLITE_DONE else {
            let msg = String(cString: sqlite3_errmsg(db))
            throw TaskStoreError.executionFailed("Insert failed: \(msg)")
        }
        
        return task
    }
    
    /// List tasks matching the optional status and priority criteria.
    public func listTasks(status: TaskStatus? = nil, priority: TaskPriority? = nil) throws -> [TaskItem] {
        guard let db = db else {
            throw TaskStoreError.executionFailed("Database not open")
        }
        
        var sql = "SELECT id, title, notes, priority, status, due_date, created_at, updated_at, completed_at FROM tasks"
        var conditions: [String] = []
        if status != nil {
            conditions.append("status = ?")
        }
        if priority != nil {
            conditions.append("priority = ?")
        }
        
        if !conditions.isEmpty {
            sql += " WHERE " + conditions.joined(separator: " AND ")
        }
        
        // Order by priority (urgent > high > medium > low), then upcoming due dates, then created date
        sql += """
         ORDER BY 
            CASE priority 
                WHEN 'urgent' THEN 1 
                WHEN 'high' THEN 2 
                WHEN 'medium' THEN 3 
                WHEN 'low' THEN 4 
                ELSE 5 
            END ASC,
            CASE WHEN due_date IS NULL THEN 1 ELSE 0 END ASC,
            due_date ASC,
            created_at DESC;
        """
        
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            let msg = String(cString: sqlite3_errmsg(db))
            throw TaskStoreError.executionFailed("Prepare select failed: \(msg)")
        }
        defer { sqlite3_finalize(stmt) }
        
        var bindIndex: Int32 = 1
        if let s = status {
            sqlite3_bind_text(stmt, bindIndex, s.rawValue, -1, SQLITE_TRANSIENT)
            bindIndex += 1
        }
        if let p = priority {
            sqlite3_bind_text(stmt, bindIndex, p.rawValue, -1, SQLITE_TRANSIENT)
            bindIndex += 1
        }
        
        var results: [TaskItem] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            if let item = parseTaskRow(from: stmt) {
                results.append(item)
            }
        }
        
        return results
    }
    
    /// Mark a task as completed. Sets status = completed, completed_at = now, updated_at = now.
    @discardableResult
    public func completeTask(id: UUID) throws -> TaskItem? {
        guard let db = db else {
            throw TaskStoreError.executionFailed("Database not open")
        }
        
        guard let _ = try getTask(id: id) else {
            return nil
        }
        
        let now = Date()
        let nowISO = TaskDateFormatter.isoString(from: now)
        let sql = "UPDATE tasks SET status = ?, completed_at = ?, updated_at = ? WHERE id = ?;"
        
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            let msg = String(cString: sqlite3_errmsg(db))
            throw TaskStoreError.executionFailed("Prepare complete failed: \(msg)")
        }
        defer { sqlite3_finalize(stmt) }
        
        sqlite3_bind_text(stmt, 1, TaskStatus.completed.rawValue, -1, SQLITE_TRANSIENT)
        sqlite3_bind_text(stmt, 2, nowISO, -1, SQLITE_TRANSIENT)
        sqlite3_bind_text(stmt, 3, nowISO, -1, SQLITE_TRANSIENT)
        sqlite3_bind_text(stmt, 4, id.uuidString, -1, SQLITE_TRANSIENT)
        
        guard sqlite3_step(stmt) == SQLITE_DONE else {
            let msg = String(cString: sqlite3_errmsg(db))
            throw TaskStoreError.executionFailed("Complete update failed: \(msg)")
        }
        
        return try getTask(id: id)
    }
    
    /// Reverts a completed task back to pending (used for undo).
    @discardableResult
    public func uncompleteTask(id: UUID) throws -> TaskItem? {
        guard let db = db else {
            throw TaskStoreError.executionFailed("Database not open")
        }
        
        guard let _ = try getTask(id: id) else {
            return nil
        }
        
        let nowISO = TaskDateFormatter.isoString(from: Date())
        let sql = "UPDATE tasks SET status = ?, completed_at = NULL, updated_at = ? WHERE id = ?;"
        
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            let msg = String(cString: sqlite3_errmsg(db))
            throw TaskStoreError.executionFailed("Prepare uncomplete failed: \(msg)")
        }
        defer { sqlite3_finalize(stmt) }
        
        sqlite3_bind_text(stmt, 1, TaskStatus.pending.rawValue, -1, SQLITE_TRANSIENT)
        sqlite3_bind_text(stmt, 2, nowISO, -1, SQLITE_TRANSIENT)
        sqlite3_bind_text(stmt, 3, id.uuidString, -1, SQLITE_TRANSIENT)
        
        guard sqlite3_step(stmt) == SQLITE_DONE else {
            let msg = String(cString: sqlite3_errmsg(db))
            throw TaskStoreError.executionFailed("Uncomplete update failed: \(msg)")
        }
        
        return try getTask(id: id)
    }
    
    /// Delete a task permanently by UUID. Returns the deleted task if found.
    @discardableResult
    public func deleteTask(id: UUID) throws -> TaskItem? {
        guard let db = db else {
            throw TaskStoreError.executionFailed("Database not open")
        }
        
        guard let existing = try getTask(id: id) else {
            return nil
        }
        
        let sql = "DELETE FROM tasks WHERE id = ?;"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            let msg = String(cString: sqlite3_errmsg(db))
            throw TaskStoreError.executionFailed("Prepare delete failed: \(msg)")
        }
        defer { sqlite3_finalize(stmt) }
        
        sqlite3_bind_text(stmt, 1, id.uuidString, -1, SQLITE_TRANSIENT)
        
        guard sqlite3_step(stmt) == SQLITE_DONE else {
            let msg = String(cString: sqlite3_errmsg(db))
            throw TaskStoreError.executionFailed("Delete failed: \(msg)")
        }
        
        return existing
    }
    
    /// Returns all pending tasks with due dates strictly prior to reference date.
    public func getOverdueTasks(asOf referenceDate: Date = Date()) throws -> [TaskItem] {
        guard let db = db else {
            throw TaskStoreError.executionFailed("Database not open")
        }
        
        let refISO = TaskDateFormatter.isoString(from: referenceDate)
        let sql = """
        SELECT id, title, notes, priority, status, due_date, created_at, updated_at, completed_at
        FROM tasks
        WHERE status = 'pending' AND due_date IS NOT NULL AND due_date < ?
        ORDER BY due_date ASC;
        """
        
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            let msg = String(cString: sqlite3_errmsg(db))
            throw TaskStoreError.executionFailed("Prepare overdue query failed: \(msg)")
        }
        defer { sqlite3_finalize(stmt) }
        
        sqlite3_bind_text(stmt, 1, refISO, -1, SQLITE_TRANSIENT)
        
        var results: [TaskItem] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            if let item = parseTaskRow(from: stmt) {
                results.append(item)
            }
        }
        
        return results
    }
    
    /// Retrieve single task by UUID.
    public func getTask(id: UUID) throws -> TaskItem? {
        guard let db = db else {
            throw TaskStoreError.executionFailed("Database not open")
        }
        
        let sql = """
        SELECT id, title, notes, priority, status, due_date, created_at, updated_at, completed_at
        FROM tasks
        WHERE id = ? LIMIT 1;
        """
        
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            let msg = String(cString: sqlite3_errmsg(db))
            throw TaskStoreError.executionFailed("Prepare getTask failed: \(msg)")
        }
        defer { sqlite3_finalize(stmt) }
        
        sqlite3_bind_text(stmt, 1, id.uuidString, -1, SQLITE_TRANSIENT)
        
        if sqlite3_step(stmt) == SQLITE_ROW {
            return parseTaskRow(from: stmt)
        }
        return nil
    }
    
    /// Flexible lookup: resolves by full UUID, 8-character prefix, or exact/fuzzy title match.
    public func findTask(byIdentifier identifier: String) throws -> TaskItem? {
        let trimmed = identifier.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        
        // 1. Try exact UUID parse
        if let uuid = UUID(uuidString: trimmed) {
            return try getTask(id: uuid)
        }
        
        guard let db = db else {
            throw TaskStoreError.executionFailed("Database not open")
        }
        
        // 2. Try prefix match on id (e.g. 8-char short hex)
        let prefixSQL = """
        SELECT id, title, notes, priority, status, due_date, created_at, updated_at, completed_at
        FROM tasks
        WHERE id LIKE ? LIMIT 1;
        """
        var prefixStmt: OpaquePointer?
        if sqlite3_prepare_v2(db, prefixSQL, -1, &prefixStmt, nil) == SQLITE_OK {
            sqlite3_bind_text(prefixStmt, 1, "\(trimmed)%", -1, SQLITE_TRANSIENT)
            if sqlite3_step(prefixStmt) == SQLITE_ROW {
                let task = parseTaskRow(from: prefixStmt)
                sqlite3_finalize(prefixStmt)
                return task
            }
        }
        sqlite3_finalize(prefixStmt)
        
        // 3. Try matching title (case-insensitive, prefer pending)
        let titleSQL = """
        SELECT id, title, notes, priority, status, due_date, created_at, updated_at, completed_at
        FROM tasks
        WHERE title LIKE ?
        ORDER BY CASE status WHEN 'pending' THEN 0 ELSE 1 END ASC, created_at DESC
        LIMIT 1;
        """
        var titleStmt: OpaquePointer?
        if sqlite3_prepare_v2(db, titleSQL, -1, &titleStmt, nil) == SQLITE_OK {
            sqlite3_bind_text(titleStmt, 1, "%\(trimmed)%", -1, SQLITE_TRANSIENT)
            if sqlite3_step(titleStmt) == SQLITE_ROW {
                let task = parseTaskRow(from: titleStmt)
                sqlite3_finalize(titleStmt)
                return task
            }
        }
        sqlite3_finalize(titleStmt)
        
        return nil
    }
    
    /// Restore or upsert an entire task record (useful for undo actions or sync).
    @discardableResult
    public func restoreTask(_ task: TaskItem) throws -> TaskItem {
        guard let db = db else {
            throw TaskStoreError.executionFailed("Database not open")
        }
        
        let sql = """
        INSERT OR REPLACE INTO tasks (id, title, notes, priority, status, due_date, created_at, updated_at, completed_at)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?);
        """
        
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            let msg = String(cString: sqlite3_errmsg(db))
            throw TaskStoreError.executionFailed("Prepare restore failed: \(msg)")
        }
        defer { sqlite3_finalize(stmt) }
        
        bindTaskParameters(task, to: stmt)
        
        guard sqlite3_step(stmt) == SQLITE_DONE else {
            let msg = String(cString: sqlite3_errmsg(db))
            throw TaskStoreError.executionFailed("Restore failed: \(msg)")
        }
        
        return task
    }
    
    /// Total count of tasks optionally filtered by status.
    public func countTasks(status: TaskStatus? = nil) throws -> Int {
        guard let db = db else {
            throw TaskStoreError.executionFailed("Database not open")
        }
        
        var sql = "SELECT COUNT(*) FROM tasks"
        if status != nil {
            sql += " WHERE status = ?"
        }
        
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            let msg = String(cString: sqlite3_errmsg(db))
            throw TaskStoreError.executionFailed("Prepare count failed: \(msg)")
        }
        defer { sqlite3_finalize(stmt) }
        
        if let s = status {
            sqlite3_bind_text(stmt, 1, s.rawValue, -1, SQLITE_TRANSIENT)
        }
        
        if sqlite3_step(stmt) == SQLITE_ROW {
            return Int(sqlite3_column_int(stmt, 0))
        }
        return 0
    }
    
    /// Wipes all tasks from database (testing / reset only).
    public func clearAllTasks() throws {
        guard let db = db else {
            throw TaskStoreError.executionFailed("Database not open")
        }
        var errMsg: UnsafeMutablePointer<CChar>?
        if sqlite3_exec(db, "DELETE FROM tasks;", nil, nil, &errMsg) != SQLITE_OK {
            let msg = errMsg != nil ? String(cString: errMsg!) : "Unknown"
            sqlite3_free(errMsg)
            throw TaskStoreError.executionFailed("Clear all tasks failed: \(msg)")
        }
    }
    
    // MARK: - Internal Parsing & Binding Helpers
    
    private func bindTaskParameters(_ task: TaskItem, to stmt: OpaquePointer?) {
        sqlite3_bind_text(stmt, 1, task.id.uuidString, -1, SQLITE_TRANSIENT)
        sqlite3_bind_text(stmt, 2, task.title, -1, SQLITE_TRANSIENT)
        
        if let notes = task.notes {
            sqlite3_bind_text(stmt, 3, notes, -1, SQLITE_TRANSIENT)
        } else {
            sqlite3_bind_null(stmt, 3)
        }
        
        sqlite3_bind_text(stmt, 4, task.priority.rawValue, -1, SQLITE_TRANSIENT)
        sqlite3_bind_text(stmt, 5, task.status.rawValue, -1, SQLITE_TRANSIENT)
        
        if let dueStr = task.dueDateISO8601 {
            sqlite3_bind_text(stmt, 6, dueStr, -1, SQLITE_TRANSIENT)
        } else {
            sqlite3_bind_null(stmt, 6)
        }
        
        sqlite3_bind_text(stmt, 7, task.createdAtISO8601, -1, SQLITE_TRANSIENT)
        sqlite3_bind_text(stmt, 8, task.updatedAtISO8601, -1, SQLITE_TRANSIENT)
        
        if let compStr = task.completedAtISO8601 {
            sqlite3_bind_text(stmt, 9, compStr, -1, SQLITE_TRANSIENT)
        } else {
            sqlite3_bind_null(stmt, 9)
        }
    }
    
    private func parseTaskRow(from stmt: OpaquePointer?) -> TaskItem? {
        guard let stmt = stmt else { return nil }
        
        guard let idCStr = sqlite3_column_text(stmt, 0),
              let idUUID = UUID(uuidString: String(cString: idCStr)),
              let titleCStr = sqlite3_column_text(stmt, 1) else {
            return nil
        }
        
        let title = String(cString: titleCStr)
        
        let notes: String? = sqlite3_column_text(stmt, 2).map { String(cString: $0) }
        
        let priorityStr = sqlite3_column_text(stmt, 3).map { String(cString: $0) }
        let priority = TaskPriority(rawValue: priorityStr ?? "") ?? .medium
        
        let statusStr = sqlite3_column_text(stmt, 4).map { String(cString: $0) }
        let status = TaskStatus(rawValue: statusStr ?? "") ?? .pending
        
        let dueStr = sqlite3_column_text(stmt, 5).map { String(cString: $0) }
        let dueDate = TaskDateFormatter.parseDate(dueStr)
        
        let createdStr = sqlite3_column_text(stmt, 6).map { String(cString: $0) }
        let createdAt = TaskDateFormatter.parseDate(createdStr) ?? Date()
        
        let updatedStr = sqlite3_column_text(stmt, 7).map { String(cString: $0) }
        let updatedAt = TaskDateFormatter.parseDate(updatedStr) ?? Date()
        
        let completedStr = sqlite3_column_text(stmt, 8).map { String(cString: $0) }
        let completedAt = TaskDateFormatter.parseDate(completedStr)
        
        return TaskItem(
            id: idUUID,
            title: title,
            notes: notes,
            priority: priority,
            status: status,
            dueDate: dueDate,
            createdAt: createdAt,
            updatedAt: updatedAt,
            completedAt: completedAt
        )
    }
}
