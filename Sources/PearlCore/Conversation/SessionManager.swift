import Foundation

/// Pending clarification state when a user request is missing a required detail (e.g. destination folder).
public struct PendingClarification: Sendable, Codable, Equatable {
    public let kind: String
    public let prompt: String
    public let targets: [String]
    public let newName: String?
    public let sourcePath: String?
    public let createdAt: Date
    
    public init(
        kind: String,
        prompt: String,
        targets: [String],
        newName: String? = nil,
        sourcePath: String? = nil,
        createdAt: Date = Date()
    ) {
        self.kind = kind
        self.prompt = prompt
        self.targets = targets
        self.newName = newName
        self.sourcePath = sourcePath
        self.createdAt = createdAt
    }
}

/// Session performance and activity metrics for Pearl conversation sessions.
public struct SessionMetrics: Sendable, Codable, Equatable {
    public let sessionID: String
    public let totalTurns: Int
    public let activeTurnsInWindow: Int
    public let startedAt: Date
    public let lastActiveAt: Date
    public let estimatedTokensInWindow: Int
    
    public init(
        sessionID: String,
        totalTurns: Int,
        activeTurnsInWindow: Int,
        startedAt: Date,
        lastActiveAt: Date,
        estimatedTokensInWindow: Int
    ) {
        self.sessionID = sessionID
        self.totalTurns = totalTurns
        self.activeTurnsInWindow = activeTurnsInWindow
        self.startedAt = startedAt
        self.lastActiveAt = lastActiveAt
        self.estimatedTokensInWindow = estimatedTokensInWindow
    }
}

/// Actor managing active multi-turn conversation sessions in Pearl.
///
/// Responsibilities:
/// - Maintains sliding window of turns (default: last 10 turns, hard-bounded by token budget e.g. 1,500 tokens).
/// - Enforces token budgets to prevent LLM context exhaustion and spend runaway.
/// - Provides session metrics (total turns, startedAt, lastActiveAt).
public actor SessionManager {
    public static let shared = SessionManager()
    
    public struct Configuration: Sendable {
        public let defaultMaxTurns: Int
        public let defaultTokenBudget: Int
        public let maxSessionTurnsRetained: Int
        
        public init(
            defaultMaxTurns: Int = 10,
            defaultTokenBudget: Int = 1500,
            maxSessionTurnsRetained: Int = 200
        ) {
            self.defaultMaxTurns = defaultMaxTurns
            self.defaultTokenBudget = defaultTokenBudget
            self.maxSessionTurnsRetained = maxSessionTurnsRetained
        }
    }
    
    private struct SessionState {
        var turns: [ConversationTurn] = []
        var totalTurnsRecorded: Int = 0
        let startedAt: Date
        var lastActiveAt: Date
        
        init(now: Date = Date()) {
            self.startedAt = now
            self.lastActiveAt = now
        }
    }
    
    private var sessions: [String: SessionState] = [:]
    private var pendingClarifications: [String: PendingClarification] = [:]
    private let config: Configuration
    
    public init(config: Configuration = Configuration()) {
        self.config = config
    }
    
    /// Records a new turn into the designated session.
    public func recordTurn(_ turn: ConversationTurn, sessionID: String = "default") {
        var state = sessions[sessionID] ?? SessionState(now: turn.timestamp)
        state.totalTurnsRecorded += 1
        state.lastActiveAt = turn.timestamp
        state.turns.append(turn)
        
        // Retention pruning if history grows too large
        if state.turns.count > config.maxSessionTurnsRetained {
            let overflow = state.turns.count - config.maxSessionTurnsRetained
            state.turns.removeFirst(overflow)
        }
        
        sessions[sessionID] = state
    }
    
    /// Retrieves recent turns constrained by the default sliding window and token budget.
    public func getRecentTurns(sessionID: String = "default") -> [ConversationTurn] {
        return getBoundedHistory(
            sessionID: sessionID,
            maxTurns: config.defaultMaxTurns,
            tokenBudget: config.defaultTokenBudget
        )
    }
    
    /// Retrieves bounded conversation history for model context assembly.
    ///
    /// Takes up to `maxTurns` freshest turns, and ensures the total estimated token
    /// count does not exceed `tokenBudget`. Returns turns in chronological order.
    public func getBoundedHistory(
        sessionID: String = "default",
        maxTurns: Int? = nil,
        tokenBudget: Int? = nil
    ) -> [ConversationTurn] {
        guard let state = sessions[sessionID], !state.turns.isEmpty else {
            return []
        }
        
        let turnLimit = maxTurns ?? config.defaultMaxTurns
        let budgetLimit = tokenBudget ?? config.defaultTokenBudget
        
        // Slice the most recent turns up to turnLimit
        let candidateTurns = state.turns.suffix(turnLimit)
        
        // Walk backwards from newest to oldest, accumulating tokens
        var boundedReversed: [ConversationTurn] = []
        var accumulatedTokens = 0
        
        for turn in candidateTurns.reversed() {
            let tokens = turn.estimatedTokens
            if !boundedReversed.isEmpty && accumulatedTokens + tokens > budgetLimit {
                break
            }
            boundedReversed.append(turn)
            accumulatedTokens += tokens
        }
        
        return boundedReversed.reversed()
    }
    
    /// Returns session metrics including total turns, window size, timestamps, and active tokens.
    public func getMetrics(sessionID: String = "default") -> SessionMetrics {
        let now = Date()
        guard let state = sessions[sessionID] else {
            return SessionMetrics(
                sessionID: sessionID,
                totalTurns: 0,
                activeTurnsInWindow: 0,
                startedAt: now,
                lastActiveAt: now,
                estimatedTokensInWindow: 0
            )
        }
        
        let bounded = getRecentTurns(sessionID: sessionID)
        let tokenCount = bounded.reduce(0) { $0 + $1.estimatedTokens }
        
        return SessionMetrics(
            sessionID: sessionID,
            totalTurns: state.totalTurnsRecorded,
            activeTurnsInWindow: bounded.count,
            startedAt: state.startedAt,
            lastActiveAt: state.lastActiveAt,
            estimatedTokensInWindow: tokenCount
        )
    }
    
    /// Sets a pending clarification for a session.
    public func setPendingClarification(_ clarification: PendingClarification, sessionID: String = "default") {
        pendingClarifications[sessionID] = clarification
    }
    
    /// Returns and optionally clears the active pending clarification for a session (expires after 5 minutes).
    public func getPendingClarification(sessionID: String = "default") -> PendingClarification? {
        guard let item = pendingClarifications[sessionID] else { return nil }
        if Date().timeIntervalSince(item.createdAt) > 300 {
            pendingClarifications.removeValue(forKey: sessionID)
            return nil
        }
        return item
    }
    
    /// Clears any pending clarification for a session.
    public func clearPendingClarification(sessionID: String = "default") {
        pendingClarifications.removeValue(forKey: sessionID)
    }
    
    /// Clears turns for a specific session.
    public func clearSession(sessionID: String = "default") {
        sessions.removeValue(forKey: sessionID)
        pendingClarifications.removeValue(forKey: sessionID)
    }
    
    /// Returns all tracked session IDs.
    public func allSessionIDs() -> [String] {
        return Array(sessions.keys)
    }
    
    /// Resets all sessions.
    public func resetAll() {
        sessions.removeAll()
        pendingClarifications.removeAll()
    }
}
