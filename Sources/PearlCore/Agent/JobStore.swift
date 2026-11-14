import Foundation
import SQLite3

public enum PlanJobStatus: String, Codable, Sendable {
    case pending
    case running
    case pausedForApproval
    case pausedForMemory
    case completed
    case failed
    case aborted
    case rolledBack
}

public enum PlanStepStatus: String, Codable, Sendable {
    case pending
    case completed
    case failed
    case pausedForApproval
    case skipped
    case rolledBack
}

public struct PlanStep: Codable, Sendable, Equatable {
    public let index: Int
    public let description: String
    public let toolName: String
    public let arguments: [String: String]
    public var status: PlanStepStatus
    public var resultMessage: String?
    public var reversible: Bool
    
    public init(
        index: Int,
        description: String,
        toolName: String,
        arguments: [String: String] = [:],
        status: PlanStepStatus = .pending,
        resultMessage: String? = nil,
        reversible: Bool = false
    ) {
        self.index = index
        self.description = description
        self.toolName = toolName
        self.arguments = arguments
        self.status = status
        self.resultMessage = resultMessage
        self.reversible = reversible
    }
}

public struct PlanJob: Codable, Sendable, Identifiable, Equatable {
    public let id: String
    public let goal: String
    public var steps: [PlanStep]
    public var currentStepIndex: Int
    public var status: PlanJobStatus
    public var errorMessage: String?
    public let createdAt: Date
    public var updatedAt: Date
    
    public init(
        id: String = UUID().uuidString,
        goal: String,
        steps: [PlanStep] = [],
        currentStepIndex: Int = 0,
        status: PlanJobStatus = .pending,
        errorMessage: String? = nil,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.goal = goal
        self.steps = steps
        self.currentStepIndex = currentStepIndex
        self.status = status
        self.errorMessage = errorMessage
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

public enum JobStoreError: Error, LocalizedError, Sendable {
    case databaseOpenFailed(String)
    case executionFailed(String)
    case jobNotFound(String)
    case invalidData(String)
    
    public var errorDescription: String? {
        switch self {
        case .databaseOpenFailed(let msg): return "JobStore DB open failed: \(msg)"
        case .executionFailed(let msg): return "JobStore SQL error: \(msg)"
        case .jobNotFound(let id): return "Job not found with ID: \(id)"
        case .invalidData(let msg): return "Invalid job data: \(msg)"
        }
    }
}

public actor JobStore {
    public static let defaultDatabaseURL: URL = {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let pearlDir = appSupport.appendingPathComponent("Pearl", isDirectory: true)
        try? FileManager.default.createDirectory(at: pearlDir, withIntermediateDirectories: true, attributes: [
            .posixPermissions: 0o700
        ])
        return pearlDir.appendingPathComponent("jobs.sqlite")
    }()
    
    public static let shared: JobStore = {
        do {
            return try JobStore()
        } catch {
            fatalError("Failed to initialize default JobStore: \(error)")
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
            throw JobStoreError.databaseOpenFailed("Failed to open SQLite database at \(url.path): \(errMsg)")
        }
        
        // WAL mode, high-performance concurrency pragmas
        sqlite3_exec(db, "PRAGMA journal_mode = WAL;", nil, nil, nil)
        sqlite3_exec(db, "PRAGMA synchronous = NORMAL;", nil, nil, nil)
        sqlite3_exec(db, "PRAGMA busy_timeout = 5000;", nil, nil, nil)
        sqlite3_exec(db, "PRAGMA foreign_keys = ON;", nil, nil, nil)
        
        let createTableSQL = """
        CREATE TABLE IF NOT EXISTS jobs (
            id TEXT PRIMARY KEY NOT NULL,
            goal TEXT NOT NULL,
            steps_json TEXT NOT NULL,
            current_step_index INTEGER NOT NULL,
            status TEXT NOT NULL,
            error_message TEXT,
            created_at TEXT NOT NULL,
            updated_at TEXT NOT NULL
        );
        CREATE INDEX IF NOT EXISTS idx_jobs_status ON jobs(status);
        CREATE INDEX IF NOT EXISTS idx_jobs_created_at ON jobs(created_at);
        """
        
        var errMsg: UnsafeMutablePointer<CChar>?
        if sqlite3_exec(db, createTableSQL, nil, nil, &errMsg) != SQLITE_OK {
            let msg = errMsg != nil ? String(cString: errMsg!) : "Unknown"
            sqlite3_free(errMsg)
            sqlite3_close_v2(db)
            throw JobStoreError.executionFailed("Failed to initialize jobs schema: \(msg)")
        }
        
        self.db = db
    }
    
    deinit {
        if let db = db {
            sqlite3_close_v2(db)
        }
    }
    
    // MARK: - CRUD Operations
    
    @discardableResult
    public func createJob(goal: String, steps: [PlanStep]) throws -> PlanJob {
        guard let db = db else {
            throw JobStoreError.executionFailed("Database not open")
        }
        
        let now = Date()
        let job = PlanJob(
            id: UUID().uuidString,
            goal: goal,
            steps: steps,
            currentStepIndex: 0,
            status: .pending,
            errorMessage: nil,
            createdAt: now,
            updatedAt: now
        )
        
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let stepsData = try? encoder.encode(job.steps),
              let stepsJSON = String(data: stepsData, encoding: .utf8) else {
            throw JobStoreError.invalidData("Failed to encode steps JSON")
        }
        
        let isoFormatter = ISO8601DateFormatter()
        let createdStr = isoFormatter.string(from: job.createdAt)
        let updatedStr = isoFormatter.string(from: job.updatedAt)
        
        let sql = """
        INSERT INTO jobs (id, goal, steps_json, current_step_index, status, error_message, created_at, updated_at)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?);
        """
        
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            let msg = String(cString: sqlite3_errmsg(db))
            throw JobStoreError.executionFailed("Prepare insert job failed: \(msg)")
        }
        defer { sqlite3_finalize(stmt) }
        
        sqlite3_bind_text(stmt, 1, job.id, -1, SQLITE_TRANSIENT)
        sqlite3_bind_text(stmt, 2, job.goal, -1, SQLITE_TRANSIENT)
        sqlite3_bind_text(stmt, 3, stepsJSON, -1, SQLITE_TRANSIENT)
        sqlite3_bind_int(stmt, 4, Int32(job.currentStepIndex))
        sqlite3_bind_text(stmt, 5, job.status.rawValue, -1, SQLITE_TRANSIENT)
        sqlite3_bind_null(stmt, 6)
        sqlite3_bind_text(stmt, 7, createdStr, -1, SQLITE_TRANSIENT)
        sqlite3_bind_text(stmt, 8, updatedStr, -1, SQLITE_TRANSIENT)
        
        guard sqlite3_step(stmt) == SQLITE_DONE else {
            let msg = String(cString: sqlite3_errmsg(db))
            throw JobStoreError.executionFailed("Insert job failed: \(msg)")
        }
        
        return job
    }
    
    public func updateJob(_ job: PlanJob) throws {
        guard let db = db else {
            throw JobStoreError.executionFailed("Database not open")
        }
        
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let stepsData = try? encoder.encode(job.steps),
              let stepsJSON = String(data: stepsData, encoding: .utf8) else {
            throw JobStoreError.invalidData("Failed to encode steps JSON")
        }
        
        let isoFormatter = ISO8601DateFormatter()
        let updatedStr = isoFormatter.string(from: job.updatedAt)
        
        let sql = """
        UPDATE jobs SET
            goal = ?,
            steps_json = ?,
            current_step_index = ?,
            status = ?,
            error_message = ?,
            updated_at = ?
        WHERE id = ?;
        """
        
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            let msg = String(cString: sqlite3_errmsg(db))
            throw JobStoreError.executionFailed("Prepare update job failed: \(msg)")
        }
        defer { sqlite3_finalize(stmt) }
        
        sqlite3_bind_text(stmt, 1, job.goal, -1, SQLITE_TRANSIENT)
        sqlite3_bind_text(stmt, 2, stepsJSON, -1, SQLITE_TRANSIENT)
        sqlite3_bind_int(stmt, 3, Int32(job.currentStepIndex))
        sqlite3_bind_text(stmt, 4, job.status.rawValue, -1, SQLITE_TRANSIENT)
        if let err = job.errorMessage {
            sqlite3_bind_text(stmt, 5, err, -1, SQLITE_TRANSIENT)
        } else {
            sqlite3_bind_null(stmt, 5)
        }
        sqlite3_bind_text(stmt, 6, updatedStr, -1, SQLITE_TRANSIENT)
        sqlite3_bind_text(stmt, 7, job.id, -1, SQLITE_TRANSIENT)
        
        guard sqlite3_step(stmt) == SQLITE_DONE else {
            let msg = String(cString: sqlite3_errmsg(db))
            throw JobStoreError.executionFailed("Update job failed: \(msg)")
        }
    }
    
    public func getJob(id: String) throws -> PlanJob? {
        guard let db = db else {
            throw JobStoreError.executionFailed("Database not open")
        }
        
        let sql = """
        SELECT id, goal, steps_json, current_step_index, status, error_message, created_at, updated_at
        FROM jobs WHERE id = ? LIMIT 1;
        """
        
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            let msg = String(cString: sqlite3_errmsg(db))
            throw JobStoreError.executionFailed("Prepare getJob failed: \(msg)")
        }
        defer { sqlite3_finalize(stmt) }
        
        sqlite3_bind_text(stmt, 1, id, -1, SQLITE_TRANSIENT)
        
        if sqlite3_step(stmt) == SQLITE_ROW {
            return parseJobRow(from: stmt)
        }
        return nil
    }
    
    public func listJobs(status: PlanJobStatus? = nil) throws -> [PlanJob] {
        guard let db = db else {
            throw JobStoreError.executionFailed("Database not open")
        }
        
        var sql = "SELECT id, goal, steps_json, current_step_index, status, error_message, created_at, updated_at FROM jobs"
        if status != nil {
            sql += " WHERE status = ?"
        }
        sql += " ORDER BY created_at DESC;"
        
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            let msg = String(cString: sqlite3_errmsg(db))
            throw JobStoreError.executionFailed("Prepare listJobs failed: \(msg)")
        }
        defer { sqlite3_finalize(stmt) }
        
        if let s = status {
            sqlite3_bind_text(stmt, 1, s.rawValue, -1, SQLITE_TRANSIENT)
        }
        
        var jobs: [PlanJob] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            if let job = parseJobRow(from: stmt) {
                jobs.append(job)
            }
        }
        return jobs
    }
    
    public func deleteJob(id: String) throws {
        guard let db = db else {
            throw JobStoreError.executionFailed("Database not open")
        }
        
        let sql = "DELETE FROM jobs WHERE id = ?;"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            let msg = String(cString: sqlite3_errmsg(db))
            throw JobStoreError.executionFailed("Prepare deleteJob failed: \(msg)")
        }
        defer { sqlite3_finalize(stmt) }
        
        sqlite3_bind_text(stmt, 1, id, -1, SQLITE_TRANSIENT)
        
        guard sqlite3_step(stmt) == SQLITE_DONE else {
            let msg = String(cString: sqlite3_errmsg(db))
            throw JobStoreError.executionFailed("Delete job failed: \(msg)")
        }
    }
    
    public func clearAllJobs() throws {
        guard let db = db else {
            throw JobStoreError.executionFailed("Database not open")
        }
        var errMsg: UnsafeMutablePointer<CChar>?
        if sqlite3_exec(db, "DELETE FROM jobs;", nil, nil, &errMsg) != SQLITE_OK {
            let msg = errMsg != nil ? String(cString: errMsg!) : "Unknown"
            sqlite3_free(errMsg)
            throw JobStoreError.executionFailed("Clear all jobs failed: \(msg)")
        }
    }
    
    // MARK: - Private Helpers
    
    private func parseJobRow(from stmt: OpaquePointer?) -> PlanJob? {
        guard let stmt = stmt else { return nil }
        guard let idC = sqlite3_column_text(stmt, 0),
              let goalC = sqlite3_column_text(stmt, 1),
              let stepsJSONC = sqlite3_column_text(stmt, 2),
              let statusC = sqlite3_column_text(stmt, 4),
              let createdC = sqlite3_column_text(stmt, 6),
              let updatedC = sqlite3_column_text(stmt, 7) else {
            return nil
        }
        
        let id = String(cString: idC)
        let goal = String(cString: goalC)
        let stepsJSON = String(cString: stepsJSONC)
        let currentStepIndex = Int(sqlite3_column_int(stmt, 3))
        let statusStr = String(cString: statusC)
        let status = PlanJobStatus(rawValue: statusStr) ?? .pending
        let errorMessage: String? = sqlite3_column_text(stmt, 5).map { String(cString: $0) }
        
        let isoFormatter = ISO8601DateFormatter()
        let createdAt = isoFormatter.date(from: String(cString: createdC)) ?? Date()
        let updatedAt = isoFormatter.date(from: String(cString: updatedC)) ?? Date()
        
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let steps = (try? decoder.decode([PlanStep].self, from: Data(stepsJSON.utf8))) ?? []
        
        return PlanJob(
            id: id,
            goal: goal,
            steps: steps,
            currentStepIndex: currentStepIndex,
            status: status,
            errorMessage: errorMessage,
            createdAt: createdAt,
            updatedAt: updatedAt
        )
    }
}
