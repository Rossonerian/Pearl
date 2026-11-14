import Foundation
import SQLite3
import PearlCore

// MARK: - Entity Extraction & Fact Normalization

public enum EntityExtractor {
    /// Normalizes content by lowercasing, collapsing whitespace, and stripping non-alphanumeric punctuation.
    public static func normalizeContent(_ text: String) -> String {
        let lower = text.lowercased()
        let cleaned = lower.unicodeScalars.map { scalar -> Character in
            if CharacterSet.alphanumerics.contains(scalar) || CharacterSet.whitespaces.contains(scalar) {
                return Character(scalar)
            }
            return " "
        }
        let joined = String(cleaned)
        return joined.components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }.joined(separator: " ")
    }
    
    /// Extracts an entity key and predicate/value from text.
    /// Returns (entityKey, value) if an entity pattern is detected.
    public static func extractEntity(from text: String, relatedEntityId: String? = nil) -> (key: String, value: String)? {
        if let rel = relatedEntityId?.trimmingCharacters(in: .whitespacesAndNewlines), !rel.isEmpty {
            return (rel.lowercased(), text)
        }
        
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        
        // 1. Key-Value format: "Key: Value" or "Key = Value"
        if let colonIdx = trimmed.firstIndex(of: ":") {
            let keyPart = String(trimmed[..<colonIdx]).trimmingCharacters(in: .whitespacesAndNewlines)
            let valPart = String(trimmed[trimmed.index(after: colonIdx)...]).trimmingCharacters(in: .whitespacesAndNewlines)
            if !keyPart.isEmpty && !valPart.isEmpty && keyPart.split(separator: " ").count <= 5 {
                return (normalizeContent(keyPart), valPart)
            }
        }
        
        // 2. "is" / "are" / "has" pattern: e.g. "User favorite language is Swift" -> key: "user favorite language", value: "Swift"
        let lower = trimmed.lowercased()
        let copulaPatterns = [" is ", " are ", " has "]
        for copula in copulaPatterns {
            if let range = lower.range(of: copula) {
                let subject = String(trimmed[..<range.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
                let predicate = String(trimmed[range.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
                let wordCount = subject.split(separator: " ").count
                if wordCount >= 1 && wordCount <= 6 && !predicate.isEmpty {
                    var normSubject = normalizeContent(subject)
                    if normSubject.hasPrefix("my ") { normSubject = String(normSubject.dropFirst(3)) }
                    if normSubject.hasPrefix("the ") { normSubject = String(normSubject.dropFirst(4)) }
                    return (normSubject, predicate)
                }
            }
        }
        
        // 3. Preference pattern: "prefers X", "likes X"
        let prefPrefixes = ["prefers ", "prefer ", "likes "]
        for prefix in prefPrefixes {
            if lower.hasPrefix(prefix) {
                let remainder = String(trimmed.dropFirst(prefix.count)).trimmingCharacters(in: .whitespacesAndNewlines)
                // If it contains mode/theme/indentation/language keywords
                if remainder.contains("dark") || remainder.contains("light") {
                    return ("pref:appearance", remainder)
                }
                if remainder.contains("tabs") || remainder.contains("spaces") {
                    return ("pref:indentation", remainder)
                }
                return ("pref:\(normalizeContent(remainder.prefix(20).description))", remainder)
            }
        }
        
        // 4. Life attributes: "lives in", "works as", "works at", "allergic to"
        let lifePatterns = [
            ("lives in ", "residence"),
            ("works as ", "occupation"),
            ("works at ", "employer"),
            ("allergic to ", "allergy")
        ]
        for (pat, key) in lifePatterns {
            if lower.contains(pat), let range = lower.range(of: pat) {
                let val = String(trimmed[range.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
                return (key, val)
            }
        }
        
        return nil
    }
}

// MARK: - FTSIndex (Canonical SQLite & FTS5 Store)

public actor FTSIndex {
    public static let currentSchemaVersion: Int = 2
    
    private let databaseURL: URL
    private var db: OpaquePointer?
    
    public init(databaseURL: URL, initialFacts: [MemoryFact] = [], initialProfile: String? = nil) throws {
        self.databaseURL = databaseURL
        let db = try Self.openAndInitializeDatabase(at: databaseURL)
        self.db = db
        
        // If canonical store is fresh, populate with initial profile & facts
        var total = 0
        var stmt: OpaquePointer?
        if sqlite3_prepare_v2(db, "SELECT count(*) FROM memories;", -1, &stmt, nil) == SQLITE_OK {
            if sqlite3_step(stmt) == SQLITE_ROW {
                total = Int(sqlite3_column_int(stmt, 0))
            }
        }
        sqlite3_finalize(stmt)
        
        if total == 0 {
            if let p = initialProfile?.trimmingCharacters(in: .whitespacesAndNewlines), !p.isEmpty {
                let profileItem = MemoryItem(
                    id: "profile_main",
                    category: .profile,
                    content: p,
                    source: "user",
                    provenance: "profile.md",
                    confidence: 1.0,
                    sensitivity: .personal,
                    userApproved: true
                )
                try Self.insertItemStatic(profileItem, into: db)
            }
            for fact in initialFacts {
                try Self.insertItemStatic(fact.asMemoryItem, into: db)
            }
        }
    }
    
    deinit {
        if let db = db {
            sqlite3_close_v2(db)
        }
    }
    
    // MARK: - Database Initialization & Migrations
    
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
        
        // 2. Canonical structured memories table (12 required fields)
        let memoriesTableSQL = """
        CREATE TABLE IF NOT EXISTS memories (
            id TEXT PRIMARY KEY,
            category TEXT NOT NULL,
            content TEXT NOT NULL,
            source TEXT NOT NULL,
            provenance TEXT NOT NULL,
            confidence REAL NOT NULL DEFAULT 1.0,
            sensitivity TEXT NOT NULL DEFAULT 'personal',
            user_approved INTEGER NOT NULL DEFAULT 1,
            created_at TEXT NOT NULL,
            updated_at TEXT NOT NULL,
            valid_until TEXT,
            related_entity_id TEXT
        );
        CREATE INDEX IF NOT EXISTS idx_memories_category ON memories(category);
        CREATE INDEX IF NOT EXISTS idx_memories_related_entity ON memories(related_entity_id);
        CREATE INDEX IF NOT EXISTS idx_memories_updated_at ON memories(updated_at);
        """
        try executeStaticSQL(memoriesTableSQL, on: db)
        
        // 3. FTS5 Virtual Table for ranked BM25 retrieval
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
        
        // 4. Schema version check and upgrade
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
                // If upgrading from v1 or v2 to v3, migrate records from memory_fts into memories
                if v < 3 {
                    try migrateLegacyFTSToMemories(on: db)
                }
                try executeStaticSQL("UPDATE schema_version SET version = \(currentSchemaVersion);", on: db)
            }
        } else {
            // Fresh database
            try executeStaticSQL("INSERT INTO schema_version (version) VALUES (\(currentSchemaVersion));", on: db)
        }
        
        return db
    }
    
    private static func migrateLegacyFTSToMemories(on db: OpaquePointer) throws {
        var stmt: OpaquePointer?
        let sql = "SELECT id, source_type, file_path, date, content FROM memory_fts;"
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(stmt) }
        
        while sqlite3_step(stmt) == SQLITE_ROW {
            let id = sqlite3_column_text(stmt, 0).map { String(cString: $0) } ?? UUID().uuidString
            let sourceType = sqlite3_column_text(stmt, 1).map { String(cString: $0) } ?? "semantic"
            let filePath = sqlite3_column_text(stmt, 2).map { String(cString: $0) } ?? "facts.md"
            let date = sqlite3_column_text(stmt, 3).map { String(cString: $0) } ?? MemoryFact.currentDateString()
            let content = sqlite3_column_text(stmt, 4).map { String(cString: $0) } ?? ""
            
            var category: MemoryCategory = .semantic
            if sourceType == "profile" || filePath.contains("profile") {
                category = .profile
            } else if let parsed = MemoryCategory(rawValue: sourceType) {
                category = parsed
            }
            
            let item = MemoryItem(
                id: id,
                category: category,
                content: content,
                source: "user",
                provenance: filePath,
                confidence: 1.0,
                sensitivity: .personal,
                userApproved: true,
                createdAt: date,
                updatedAt: date
            )
            try? insertItemStatic(item, into: db)
        }
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
    
    private func ensureDatabaseOpen() throws {
        if db == nil || !FileManager.default.fileExists(atPath: databaseURL.path) {
            self.db = try Self.openAndInitializeDatabase(at: databaseURL)
        }
    }
    
    // MARK: - CRUD for MemoryItem (Canonical Store)
    
    @discardableResult
    public func upsert(item: MemoryItem) throws -> MemoryItem {
        try ensureDatabaseOpen()
        guard let db = db else { throw MemoryError.databaseError("Database not open") }
        try Self.insertItemStatic(item, into: db)
        return item
    }
    
    private static func insertItemStatic(_ item: MemoryItem, into db: OpaquePointer) throws {
        let sql = """
        INSERT INTO memories (
            id, category, content, source, provenance, confidence,
            sensitivity, user_approved, created_at, updated_at, valid_until, related_entity_id
        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        ON CONFLICT(id) DO UPDATE SET
            category = excluded.category,
            content = excluded.content,
            source = excluded.source,
            provenance = excluded.provenance,
            confidence = excluded.confidence,
            sensitivity = excluded.sensitivity,
            user_approved = excluded.user_approved,
            updated_at = excluded.updated_at,
            valid_until = excluded.valid_until,
            related_entity_id = excluded.related_entity_id;
        """
        
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            let errMsg = String(cString: sqlite3_errmsg(db))
            throw MemoryError.databaseError("Prepare failed for memories upsert: \(errMsg)")
        }
        defer { sqlite3_finalize(stmt) }
        
        sqlite3_bind_text(stmt, 1, (item.id as NSString).utf8String, -1, nil)
        sqlite3_bind_text(stmt, 2, (item.category.rawValue as NSString).utf8String, -1, nil)
        sqlite3_bind_text(stmt, 3, (item.content as NSString).utf8String, -1, nil)
        sqlite3_bind_text(stmt, 4, (item.source as NSString).utf8String, -1, nil)
        sqlite3_bind_text(stmt, 5, (item.provenance as NSString).utf8String, -1, nil)
        sqlite3_bind_double(stmt, 6, item.confidence)
        sqlite3_bind_text(stmt, 7, (item.sensitivity.rawValue as NSString).utf8String, -1, nil)
        sqlite3_bind_int(stmt, 8, item.userApproved ? 1 : 0)
        sqlite3_bind_text(stmt, 9, (item.createdAt as NSString).utf8String, -1, nil)
        sqlite3_bind_text(stmt, 10, (item.updatedAt as NSString).utf8String, -1, nil)
        
        if let v = item.validUntil {
            sqlite3_bind_text(stmt, 11, (v as NSString).utf8String, -1, nil)
        } else {
            sqlite3_bind_null(stmt, 11)
        }
        
        if let r = item.relatedEntityId {
            sqlite3_bind_text(stmt, 12, (r as NSString).utf8String, -1, nil)
        } else {
            sqlite3_bind_null(stmt, 12)
        }
        
        guard sqlite3_step(stmt) == SQLITE_DONE else {
            let errMsg = String(cString: sqlite3_errmsg(db))
            throw MemoryError.databaseError("Step failed for memories upsert: \(errMsg)")
        }
        
        // Synchronize FTS5 virtual index
        let ftsSourceType = (item.category == .semantic) ? "fact" : (item.category == .profile ? "profile" : item.category.rawValue)
        let ftsFilePath = (item.category == .profile) ? "profile.md" : (item.provenance.isEmpty ? "facts.md" : item.provenance)
        try insertFTSStatic(
            id: item.id,
            sourceType: ftsSourceType,
            filePath: ftsFilePath,
            date: item.dateString,
            content: item.content,
            into: db
        )
    }
    
    private static func insertFTSStatic(
        id: String,
        sourceType: String,
        filePath: String,
        date: String,
        content: String,
        into db: OpaquePointer
    ) throws {
        // Delete prior entry with same id
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
            throw MemoryError.databaseError("Prepare failed for FTS insert: \(errMsg)")
        }
        defer { sqlite3_finalize(stmt) }
        
        sqlite3_bind_text(stmt, 1, (id as NSString).utf8String, -1, nil)
        sqlite3_bind_text(stmt, 2, (sourceType as NSString).utf8String, -1, nil)
        sqlite3_bind_text(stmt, 3, (filePath as NSString).utf8String, -1, nil)
        sqlite3_bind_text(stmt, 4, (date as NSString).utf8String, -1, nil)
        sqlite3_bind_text(stmt, 5, (content as NSString).utf8String, -1, nil)
        
        guard sqlite3_step(stmt) == SQLITE_DONE else {
            let errMsg = String(cString: sqlite3_errmsg(db))
            throw MemoryError.databaseError("Insert failed for FTS: \(errMsg)")
        }
    }
    
    public func getItem(id: String) -> MemoryItem? {
        try? ensureDatabaseOpen()
        guard let db = db else { return nil }
        
        let sql = """
        SELECT id, category, content, source, provenance, confidence,
               sensitivity, user_approved, created_at, updated_at, valid_until, related_entity_id
        FROM memories WHERE id = ? LIMIT 1;
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(stmt) }
        
        sqlite3_bind_text(stmt, 1, (id as NSString).utf8String, -1, nil)
        if sqlite3_step(stmt) == SQLITE_ROW {
            return Self.rowToMemoryItem(stmt: stmt!)
        }
        return nil
    }
    
    public func getAllItems(category: MemoryCategory? = nil) -> [MemoryItem] {
        try? ensureDatabaseOpen()
        guard let db = db else { return [] }
        
        var sql = """
        SELECT id, category, content, source, provenance, confidence,
               sensitivity, user_approved, created_at, updated_at, valid_until, related_entity_id
        FROM memories
        """
        if category != nil {
            sql += " WHERE category = ?"
        }
        sql += " ORDER BY rowid ASC;"
        
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(stmt) }
        
        if let cat = category {
            sqlite3_bind_text(stmt, 1, (cat.rawValue as NSString).utf8String, -1, nil)
        }
        
        var results: [MemoryItem] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            results.append(Self.rowToMemoryItem(stmt: stmt!))
        }
        return results
    }
    
    public func delete(id: String) throws {
        try ensureDatabaseOpen()
        guard let db = db else { return }
        
        var stmt1: OpaquePointer?
        if sqlite3_prepare_v2(db, "DELETE FROM memories WHERE id = ?;", -1, &stmt1, nil) == SQLITE_OK {
            sqlite3_bind_text(stmt1, 1, (id as NSString).utf8String, -1, nil)
            _ = sqlite3_step(stmt1)
        }
        sqlite3_finalize(stmt1)
        
        var stmt2: OpaquePointer?
        if sqlite3_prepare_v2(db, "DELETE FROM memory_fts WHERE id = ?;", -1, &stmt2, nil) == SQLITE_OK {
            sqlite3_bind_text(stmt2, 1, (id as NSString).utf8String, -1, nil)
            _ = sqlite3_step(stmt2)
        }
        sqlite3_finalize(stmt2)
    }
    
    public func count(category: MemoryCategory? = nil) -> Int {
        try? ensureDatabaseOpen()
        guard let db = db else { return 0 }
        
        var sql = "SELECT count(*) FROM memories"
        if category != nil {
            sql += " WHERE category = ?"
        }
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return 0 }
        defer { sqlite3_finalize(stmt) }
        
        if let cat = category {
            sqlite3_bind_text(stmt, 1, (cat.rawValue as NSString).utf8String, -1, nil)
        }
        
        if sqlite3_step(stmt) == SQLITE_ROW {
            return Int(sqlite3_column_int(stmt, 0))
        }
        return 0
    }
    
    public func getCategoryCounts() -> [String: Int] {
        try? ensureDatabaseOpen()
        guard let db = db else { return [:] }
        
        let sql = "SELECT category, count(*) FROM memories GROUP BY category;"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [:] }
        defer { sqlite3_finalize(stmt) }
        
        var counts: [String: Int] = [:]
        while sqlite3_step(stmt) == SQLITE_ROW {
            let cat = sqlite3_column_text(stmt, 0).map { String(cString: $0) } ?? ""
            let count = Int(sqlite3_column_int(stmt, 1))
            counts[cat] = count
        }
        return counts
    }
    
    private static func rowToMemoryItem(stmt: OpaquePointer) -> MemoryItem {
        let id = sqlite3_column_text(stmt, 0).map { String(cString: $0) } ?? ""
        let catStr = sqlite3_column_text(stmt, 1).map { String(cString: $0) } ?? "semantic"
        let category = MemoryCategory(rawValue: catStr) ?? .semantic
        let content = sqlite3_column_text(stmt, 2).map { String(cString: $0) } ?? ""
        let source = sqlite3_column_text(stmt, 3).map { String(cString: $0) } ?? "user"
        let provenance = sqlite3_column_text(stmt, 4).map { String(cString: $0) } ?? "user"
        let confidence = sqlite3_column_double(stmt, 5)
        let sensStr = sqlite3_column_text(stmt, 6).map { String(cString: $0) } ?? "personal"
        let sensitivity = MemorySensitivity(rawValue: sensStr) ?? .personal
        let userApproved = sqlite3_column_int(stmt, 7) != 0
        let createdAt = sqlite3_column_text(stmt, 8).map { String(cString: $0) } ?? ""
        let updatedAt = sqlite3_column_text(stmt, 9).map { String(cString: $0) } ?? ""
        let validUntil = sqlite3_column_text(stmt, 10).map { String(cString: $0) }
        let relatedEntityId = sqlite3_column_text(stmt, 11).map { String(cString: $0) }
        
        return MemoryItem(
            id: id,
            category: category,
            content: content,
            source: source,
            provenance: provenance,
            confidence: confidence,
            sensitivity: sensitivity,
            userApproved: userApproved,
            createdAt: createdAt,
            updatedAt: updatedAt,
            validUntil: validUntil,
            relatedEntityId: relatedEntityId
        )
    }
    
    // MARK: - Deduplication & Fact Correction (Requirement 7)
    
    /// Checks for an existing memory that is an exact/normalized duplicate or represents
    /// the same entity requiring a fact correction.
    /// Returns `(item: MemoryItem, wasCorrected: Bool)`:
    /// - If exact duplicate: returns existing item without inserting duplicate row.
    /// - If fact correction (new value for same entity): updates existing fact in place.
    /// - If novel fact: inserts new fact and returns it.
    @discardableResult
    public func saveOrCorrect(item: MemoryItem) throws -> (item: MemoryItem, wasCorrected: Bool) {
        try ensureDatabaseOpen()
        
        let existingItems = getAllItems(category: item.category)
        let normNewContent = EntityExtractor.normalizeContent(item.content)
        
        // 1. Exact or normalized duplicate check
        for existing in existingItems {
            if existing.id == item.id {
                try upsert(item: item)
                return (item, false)
            }
            if EntityExtractor.normalizeContent(existing.content) == normNewContent {
                // Update timestamp/confidence if new input is fresher
                var updated = existing
                updated.updatedAt = MemoryItem.currentISO8601String()
                if item.confidence > existing.confidence {
                    updated.confidence = item.confidence
                }
                try upsert(item: updated)
                return (updated, false)
            }
        }
        
        // 2. Fact Correction: check for entity match
        let newEntity = EntityExtractor.extractEntity(from: item.content, relatedEntityId: item.relatedEntityId)
        
        if let newEntity = newEntity {
            for existing in existingItems {
                var isMatch = false
                
                // Match via explicit relatedEntityId
                if let newRel = item.relatedEntityId, let existRel = existing.relatedEntityId, !newRel.isEmpty {
                    if newRel.lowercased() == existRel.lowercased() {
                        isMatch = true
                    }
                }
                
                // Match via extracted entity key
                if !isMatch {
                    if let existEntity = EntityExtractor.extractEntity(from: existing.content, relatedEntityId: existing.relatedEntityId) {
                        if existEntity.key == newEntity.key {
                            isMatch = true
                        }
                    }
                }
                
                if isMatch {
                    // Fact correction: update existing fact in place with new value
                    var corrected = existing
                    corrected.content = item.content
                    corrected.updatedAt = MemoryItem.currentISO8601String()
                    corrected.confidence = item.confidence
                    corrected.provenance = item.provenance
                    corrected.source = item.source
                    corrected.userApproved = item.userApproved
                    if item.relatedEntityId != nil {
                        corrected.relatedEntityId = item.relatedEntityId
                    } else if corrected.relatedEntityId == nil {
                        corrected.relatedEntityId = newEntity.key
                    }
                    try upsert(item: corrected)
                    return (corrected, true)
                }
            }
        }
        
        // 3. Novel item: insert fresh
        var finalItem = item
        if finalItem.relatedEntityId == nil, let entityKey = newEntity?.key {
            finalItem.relatedEntityId = entityKey
        }
        try upsert(item: finalItem)
        return (finalItem, false)
    }
    
    // MARK: - Legacy Insert API (Backwards Compatibility)
    
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
        try ensureDatabaseOpen()
        guard let db = db else { throw MemoryError.databaseError("Database not open") }
        
        var category: MemoryCategory = .semantic
        if sourceType == "profile" || filePath.contains("profile") {
            category = .profile
        } else if let parsed = MemoryCategory(rawValue: sourceType) {
            category = parsed
        }
        
        let item = MemoryItem(
            id: id,
            category: category,
            content: content,
            source: "user",
            provenance: filePath,
            confidence: 1.0,
            sensitivity: .personal,
            userApproved: true,
            createdAt: date,
            updatedAt: date
        )
        try Self.insertItemStatic(item, into: db)
    }
    
    // MARK: - Search & BM25 Retrieval (Requirement 8)
    
    public func search(query: String, category: MemoryCategory? = nil, topK: Int = 5) -> [MemorySnippet] {
        guard let db = db else { return [] }
        
        let sanitized = sanitizeFTSQuery(query)
        guard !sanitized.isEmpty else { return [] }
        
        let effectiveLimit = max(1, min(topK, ContextBudget.maxRetrievedSnippets))
        
        var sql: String
        if category != nil {
            sql = """
            SELECT id, source_type, file_path, date, content, bm25(memory_fts) as rank
            FROM memory_fts
            WHERE memory_fts MATCH ? AND source_type = ?
            ORDER BY rank ASC, id ASC
            LIMIT ?;
            """
        } else {
            sql = """
            SELECT id, source_type, file_path, date, content, bm25(memory_fts) as rank
            FROM memory_fts
            WHERE memory_fts MATCH ?
            ORDER BY rank ASC, id ASC
            LIMIT ?;
            """
        }
        
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            return []
        }
        defer { sqlite3_finalize(stmt) }
        
        sqlite3_bind_text(stmt, 1, (sanitized as NSString).utf8String, -1, nil)
        if let cat = category {
            sqlite3_bind_text(stmt, 2, (cat.rawValue as NSString).utf8String, -1, nil)
            sqlite3_bind_int(stmt, 3, Int32(effectiveLimit))
        } else {
            sqlite3_bind_int(stmt, 2, Int32(effectiveLimit))
        }
        
        var results: [MemorySnippet] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            let id = sqlite3_column_text(stmt, 0).map { String(cString: $0) } ?? ""
            let sourceType = sqlite3_column_text(stmt, 1).map { String(cString: $0) } ?? ""
            let filePath = sqlite3_column_text(stmt, 2).map { String(cString: $0) } ?? ""
            let date = sqlite3_column_text(stmt, 3).map { String(cString: $0) } ?? ""
            let content = sqlite3_column_text(stmt, 4).map { String(cString: $0) } ?? ""
            let rank = sqlite3_column_double(stmt, 5)
            
            let parsedCategory = MemoryCategory(rawValue: sourceType) ?? .semantic
            
            results.append(
                MemorySnippet(
                    id: id,
                    category: parsedCategory,
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
    
    // MARK: - Rebuild
    
    /// Completely rebuilds `memory.sqlite` tables and FTS5 virtual table.
    /// Re-opening or creating db if file was deleted, clearing tables,
    /// inserting facts and profile. Guarantees 100% deterministic results.
    public func rebuild(facts: [MemoryFact], profile: String) throws {
        if db != nil {
            sqlite3_close_v2(db)
            db = nil
        }
        
        self.db = try Self.openAndInitializeDatabase(at: databaseURL)
        guard let db = db else {
            throw MemoryError.databaseError("Failed to re-open database during rebuild")
        }
        
        try executeSQL("DELETE FROM memories;")
        try executeSQL("DELETE FROM memory_fts;")
        
        // Insert profile if present
        let trimmedProfile = profile.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedProfile.isEmpty {
            let profileItem = MemoryItem(
                id: "profile_main",
                category: .profile,
                content: trimmedProfile,
                source: "user",
                provenance: "profile.md",
                confidence: 1.0,
                sensitivity: .personal,
                userApproved: true
            )
            try Self.insertItemStatic(profileItem, into: db)
        }
        
        // Insert all facts in deterministic order
        for fact in facts {
            try Self.insertItemStatic(fact.asMemoryItem, into: db)
        }
        
        // Optimize FTS b-tree index
        _ = sqlite3_exec(db, "INSERT INTO memory_fts(memory_fts) VALUES('optimize');", nil, nil, nil)
    }
    
    public func rebuildWithItems(items: [MemoryItem], profile: String) throws {
        if db != nil {
            sqlite3_close_v2(db)
            db = nil
        }
        
        self.db = try Self.openAndInitializeDatabase(at: databaseURL)
        guard let db = db else {
            throw MemoryError.databaseError("Failed to re-open database during rebuild")
        }
        
        try executeSQL("DELETE FROM memories;")
        try executeSQL("DELETE FROM memory_fts;")
        
        let trimmedProfile = profile.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedProfile.isEmpty {
            let profileItem = MemoryItem(
                id: "profile_main",
                category: .profile,
                content: trimmedProfile,
                source: "user",
                provenance: "profile.md",
                confidence: 1.0,
                sensitivity: .personal,
                userApproved: true
            )
            try Self.insertItemStatic(profileItem, into: db)
        }
        
        for item in items {
            try Self.insertItemStatic(item, into: db)
        }
        
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
