import Foundation
import SQLite3
import PearlCore

public actor FTSIndex {
    public static let currentSchemaVersion: Int = 2
    
    private let databaseURL: URL
    private var db: OpaquePointer?
    
    public init(databaseURL: URL, initialFacts: [MemoryFact] = [], initialProfile: String? = nil) throws {
        self.databaseURL = databaseURL
        let db = try Self.openAndInitializeDatabase(at: databaseURL)
        self.db = db
        
        // If index is fresh, populate with initial profile & facts if provided
        var total = 0
        var stmt: OpaquePointer?
        if sqlite3_prepare_v2(db, "SELECT count(*) FROM memory_fts;", -1, &stmt, nil) == SQLITE_OK {
            if sqlite3_step(stmt) == SQLITE_ROW {
                total = Int(sqlite3_column_int(stmt, 0))
            }
        }
        sqlite3_finalize(stmt)
        
        if total == 0 {
            if let p = initialProfile?.trimmingCharacters(in: .whitespacesAndNewlines), !p.isEmpty {
                try Self.insertStatic(
                    id: "profile_main",
                    sourceType: "profile",
                    filePath: "profile.md",
                    date: MemoryFact.currentDateString(),
                    content: p,
                    into: db
                )
            }
            for fact in initialFacts {
                try Self.insertStatic(
                    id: fact.id,
                    sourceType: "fact",
                    filePath: "facts.md",
                    date: fact.date,
                    content: fact.content,
                    into: db
                )
            }
        }
    }
    
    deinit {
        if let db = db {
            sqlite3_close_v2(db)
        }
    }
    
    private static func openAndInitializeDatabase(at url: URL) throws -> OpaquePointer {
        let dir = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        
        var dbPointer: OpaquePointer?
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
        let rc = sqlite3_open_v2(url.path, &dbPointer, flags, nil)
        guard rc == SQLITE_OK, let db = dbPointer else {
            let errMsg = dbPointer != nil ? String(cString: sqlite3_errmsg(dbPointer)) : "Unknown"
            if let dbPointer = dbPointer { sqlite3_close_v2(dbPointer) }
            throw MemoryError.databaseError("Failed to open SQLite database at \(url.path): \(errMsg)")
        }
        
        // Performance & concurrency pragmas
        sqlite3_exec(db, "PRAGMA journal_mode = WAL;", nil, nil, nil)
        sqlite3_exec(db, "PRAGMA synchronous = NORMAL;", nil, nil, nil)
        
        // 1. Schema version table
        let schemaTableSQL = """
        CREATE TABLE IF NOT EXISTS schema_version (
            version INTEGER PRIMARY KEY
        );
        """
        try executeStaticSQL(schemaTableSQL, on: db)
        
        // 2. FTS5 Virtual Table
        let ftsTableSQL = """
        CREATE VIRTUAL TABLE IF NOT EXISTS memory_fts USING fts5(
            id UNINDEXED,
            source_type,
            file_path UNINDEXED,
            date,
            content,
            tokenize = 'porter unicode61'
        );
        """
        try executeStaticSQL(ftsTableSQL, on: db)
        
        // 3. Check and apply migration if needed
        var versionStmt: OpaquePointer?
        var existingVersion: Int?
        if sqlite3_prepare_v2(db, "SELECT version FROM schema_version LIMIT 1;", -1, &versionStmt, nil) == SQLITE_OK {
            if sqlite3_step(versionStmt) == SQLITE_ROW {
                existingVersion = Int(sqlite3_column_int(versionStmt, 0))
            }
        }
        sqlite3_finalize(versionStmt)
        
        if let v = existingVersion {
            if v < currentSchemaVersion {
                // Perform migration: upgrade from v1 to v2
                try executeStaticSQL("UPDATE schema_version SET version = \(currentSchemaVersion);", on: db)
            }
        } else {
            // Fresh database
            try executeStaticSQL("INSERT INTO schema_version (version) VALUES (\(currentSchemaVersion));", on: db)
        }
        
        return db
    }
    
    private static func executeStaticSQL(_ sql: String, on db: OpaquePointer) throws {
        var errMsg: UnsafeMutablePointer<CChar>?
        let rc = sqlite3_exec(db, sql, nil, nil, &errMsg)
        if rc != SQLITE_OK {
            let error = errMsg.map { String(cString: $0) } ?? "Unknown error"
            sqlite3_free(errMsg)
            throw MemoryError.databaseError("Failed SQL execution '\(sql)': \(error)")
        }
    }
    
    private func executeSQL(_ sql: String) throws {
        guard let db = db else {
            throw MemoryError.databaseError("Database not open")
        }
        try Self.executeStaticSQL(sql, on: db)
    }
    
    public func getSchemaVersion() -> Int {
        guard let db = db else { return 0 }
        var stmt: OpaquePointer?
        var version = 0
        if sqlite3_prepare_v2(db, "SELECT version FROM schema_version LIMIT 1;", -1, &stmt, nil) == SQLITE_OK {
            if sqlite3_step(stmt) == SQLITE_ROW {
                version = Int(sqlite3_column_int(stmt, 0))
            }
        }
        sqlite3_finalize(stmt)
        return version
    }
    
    public func insert(snippet: MemorySnippet) throws {
        try insert(
            id: snippet.id,
            sourceType: snippet.sourceType,
            filePath: snippet.filePath,
            date: snippet.date,
            content: snippet.content
        )
    }
    
    public func insert(
        id: String,
        sourceType: String,
        filePath: String,
        date: String,
        content: String
    ) throws {
        // Ensure db connection is active (e.g. if rebuilt after deletion)
        if db == nil || !FileManager.default.fileExists(atPath: databaseURL.path) {
            self.db = try Self.openAndInitializeDatabase(at: databaseURL)
        }
        guard let db = db else {
            throw MemoryError.databaseError("Database not open")
        }
        
        try Self.insertStatic(
            id: id,
            sourceType: sourceType,
            filePath: filePath,
            date: date,
            content: content,
            into: db
        )
    }
    
    private static func insertStatic(
        id: String,
        sourceType: String,
        filePath: String,
        date: String,
        content: String,
        into db: OpaquePointer
    ) throws {
        // Delete prior entry with same id if any
        var delStmt: OpaquePointer?
        if sqlite3_prepare_v2(db, "DELETE FROM memory_fts WHERE id = ?;", -1, &delStmt, nil) == SQLITE_OK {
            sqlite3_bind_text(delStmt, 1, (id as NSString).utf8String, -1, nil)
            _ = sqlite3_step(delStmt)
        }
        sqlite3_finalize(delStmt)
        
        let sql = "INSERT INTO memory_fts (id, source_type, file_path, date, content) VALUES (?, ?, ?, ?, ?);"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            let errMsg = String(cString: sqlite3_errmsg(db))
            throw MemoryError.databaseError("Prepare failed for insert: \(errMsg)")
        }
        defer { sqlite3_finalize(stmt) }
        
        sqlite3_bind_text(stmt, 1, (id as NSString).utf8String, -1, nil)
        sqlite3_bind_text(stmt, 2, (sourceType as NSString).utf8String, -1, nil)
        sqlite3_bind_text(stmt, 3, (filePath as NSString).utf8String, -1, nil)
        sqlite3_bind_text(stmt, 4, (date as NSString).utf8String, -1, nil)
        sqlite3_bind_text(stmt, 5, (content as NSString).utf8String, -1, nil)
        
        guard sqlite3_step(stmt) == SQLITE_DONE else {
            let errMsg = String(cString: sqlite3_errmsg(db))
            throw MemoryError.databaseError("Insert failed: \(errMsg)")
        }
    }
    
    public func delete(id: String) throws {
        if db == nil { return }
        guard let db = db else { return }
        
        let sql = "DELETE FROM memory_fts WHERE id = ?;"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            let errMsg = String(cString: sqlite3_errmsg(db))
            throw MemoryError.databaseError("Prepare failed for delete: \(errMsg)")
        }
        defer { sqlite3_finalize(stmt) }
        
        sqlite3_bind_text(stmt, 1, (id as NSString).utf8String, -1, nil)
        _ = sqlite3_step(stmt)
    }
    
    public func search(query: String, topK: Int = 5) -> [MemorySnippet] {
        guard let db = db else { return [] }
        
        // Sanitize query to avoid FTS syntax errors
        let sanitized = sanitizeFTSQuery(query)
        guard !sanitized.isEmpty else { return [] }
        
        let effectiveLimit = max(1, min(topK, ContextBudget.maxRetrievedSnippets))
        let sql = """
        SELECT id, source_type, file_path, date, content, bm25(memory_fts) as rank
        FROM memory_fts
        WHERE memory_fts MATCH ?
        ORDER BY rank ASC, id ASC
        LIMIT ?;
        """
        
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            return []
        }
        defer { sqlite3_finalize(stmt) }
        
        sqlite3_bind_text(stmt, 1, (sanitized as NSString).utf8String, -1, nil)
        sqlite3_bind_int(stmt, 2, Int32(effectiveLimit))
        
        var results: [MemorySnippet] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            let id = sqlite3_column_text(stmt, 0).map { String(cString: $0) } ?? ""
            let sourceType = sqlite3_column_text(stmt, 1).map { String(cString: $0) } ?? ""
            let filePath = sqlite3_column_text(stmt, 2).map { String(cString: $0) } ?? ""
            let date = sqlite3_column_text(stmt, 3).map { String(cString: $0) } ?? ""
            let content = sqlite3_column_text(stmt, 4).map { String(cString: $0) } ?? ""
            let rank = sqlite3_column_double(stmt, 5)
            
            results.append(
                MemorySnippet(
                    id: id,
                    sourceType: sourceType,
                    filePath: filePath,
                    date: date,
                    content: content,
                    bm25Score: rank
                )
            )
        }
        
        return results
    }
    
    public func count() -> Int {
        guard let db = db else { return 0 }
        var stmt: OpaquePointer?
        var total = 0
        if sqlite3_prepare_v2(db, "SELECT count(*) FROM memory_fts;", -1, &stmt, nil) == SQLITE_OK {
            if sqlite3_step(stmt) == SQLITE_ROW {
                total = Int(sqlite3_column_int(stmt, 0))
            }
        }
        sqlite3_finalize(stmt)
        return total
    }
    
    /// Completely rebuilds `index.sqlite` from markdown files.
    /// Re-opening or creating db if file was deleted, clearing table,
    /// inserting facts and profile. Guarantees 100% deterministic results.
    public func rebuild(facts: [MemoryFact], profile: String) throws {
        if db != nil {
            sqlite3_close_v2(db)
            db = nil
        }
        
        // Re-open and re-initialize schema
        self.db = try Self.openAndInitializeDatabase(at: databaseURL)
        
        guard let db = db else {
            throw MemoryError.databaseError("Failed to re-open database during rebuild")
        }
        
        try executeSQL("DELETE FROM memory_fts;")
        
        // Insert profile if present
        let trimmedProfile = profile.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedProfile.isEmpty {
            try insert(
                id: "profile_main",
                sourceType: "profile",
                filePath: "profile.md",
                date: MemoryFact.currentDateString(),
                content: trimmedProfile
            )
        }
        
        // Insert all facts in deterministic order
        for fact in facts {
            try insert(
                id: fact.id,
                sourceType: "fact",
                filePath: "facts.md",
                date: fact.date,
                content: fact.content
            )
        }
        
        // Optimize FTS b-tree index
        _ = sqlite3_exec(db, "INSERT INTO memory_fts(memory_fts) VALUES('optimize');", nil, nil, nil)
    }
    
    public func close() {
        if let db = db {
            sqlite3_close_v2(db)
            self.db = nil
        }
    }
    
    private func sanitizeFTSQuery(_ query: String) -> String {
        let tokens = query.components(separatedBy: CharacterSet.alphanumerics.inverted)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard !tokens.isEmpty else { return "" }
        return tokens.map { "\"\($0)\"*" }.joined(separator: " OR ")
    }
}
