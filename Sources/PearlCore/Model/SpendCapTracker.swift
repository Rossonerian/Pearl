import Foundation

public enum SpendCapError: LocalizedError, Sendable, Equatable {
    case monthlySpendCapExceeded(current: Double, cap: Double)
    case exceededPerTurnTokenCap(requested: Int, max: Int)
    
    public var errorDescription: String? {
        switch self {
        case .monthlySpendCapExceeded(let current, let cap):
            return String(format: "Frontier monthly spend cap exceeded: current $%.2f exceeds cap of $%.2f. Cloud calls halted.", current, cap)
        case .exceededPerTurnTokenCap(let requested, let max):
            return "Requested tokens (\(requested)) exceeds maximum allowed tokens per turn (\(max))."
        }
    }
}

public final class SpendCapTracker: @unchecked Sendable {
    public static let shared = SpendCapTracker()
    
    private var monthlyCapUSD: Double
    private var maxTokensPerTurn: Int
    private var currentMonthSpendUSD: Double = 0.0
    private var currentMonthKey: String = ""
    private let lock = NSLock()
    
    public init(monthlyCapUSD: Double = 10.0, maxTokensPerTurn: Int = 4096) {
        self.monthlyCapUSD = monthlyCapUSD
        self.maxTokensPerTurn = maxTokensPerTurn
        self.currentMonthKey = SpendCapTracker.currentMonthIdentifier()
        loadPersistedSpend()
    }
    
    public func updateLimits(monthlyCapUSD: Double, maxTokensPerTurn: Int) {
        lock.lock()
        defer { lock.unlock() }
        self.monthlyCapUSD = monthlyCapUSD
        self.maxTokensPerTurn = maxTokensPerTurn
    }
    
    public func checkSpendCap() throws {
        lock.lock()
        defer { lock.unlock() }
        checkAndRotateMonthIfNeeded()
        
        if currentMonthSpendUSD >= monthlyCapUSD {
            throw SpendCapError.monthlySpendCapExceeded(current: currentMonthSpendUSD, cap: monthlyCapUSD)
        }
    }
    
    public func checkTurnTokenLimit(tokens: Int) throws {
        lock.lock()
        defer { lock.unlock() }
        if tokens > maxTokensPerTurn {
            throw SpendCapError.exceededPerTurnTokenCap(requested: tokens, max: maxTokensPerTurn)
        }
    }
    
    @discardableResult
    public func recordUsage(modelID: String, inputTokens: Int, outputTokens: Int) -> Double {
        lock.lock()
        defer { lock.unlock() }
        checkAndRotateMonthIfNeeded()
        
        let cost = calculateCost(modelID: modelID, inputTokens: inputTokens, outputTokens: outputTokens)
        currentMonthSpendUSD += cost
        persistSpend()
        return cost
    }
    
    public func currentSpend() -> Double {
        lock.lock()
        defer { lock.unlock() }
        checkAndRotateMonthIfNeeded()
        return currentMonthSpendUSD
    }
    
    public func resetForTesting(initialSpend: Double = 0.0) {
        lock.lock()
        defer { lock.unlock() }
        self.currentMonthKey = SpendCapTracker.currentMonthIdentifier()
        self.currentMonthSpendUSD = initialSpend
        persistSpend()
    }
    
    private static func currentMonthIdentifier() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM"
        return formatter.string(from: Date())
    }
    
    private func checkAndRotateMonthIfNeeded() {
        let current = SpendCapTracker.currentMonthIdentifier()
        if current != currentMonthKey {
            currentMonthKey = current
            currentMonthSpendUSD = 0.0
            persistSpend()
        }
    }
    
    private func calculateCost(modelID: String, inputTokens: Int, outputTokens: Int) -> Double {
        let lower = modelID.lowercased()
        let inputRate: Double
        let outputRate: Double
        
        if lower.contains("haiku") {
            // Claude Haiku: $0.80 / MTok in, $4.00 / MTok out
            inputRate = 0.80 / 1_000_000.0
            outputRate = 4.00 / 1_000_000.0
        } else if lower.contains("sonnet") {
            // Claude Sonnet: $3.00 / MTok in, $15.00 / MTok out
            inputRate = 3.00 / 1_000_000.0
            outputRate = 15.00 / 1_000_000.0
        } else {
            // Conservative fallback: $1.00 / MTok in, $5.00 / MTok out
            inputRate = 1.00 / 1_000_000.0
            outputRate = 5.00 / 1_000_000.0
        }
        
        return (Double(inputTokens) * inputRate) + (Double(outputTokens) * outputRate)
    }
    
    private var stateFileURL: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("Pearl", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("spend_tracker.json")
    }
    
    private func loadPersistedSpend() {
        guard let data = try? Data(contentsOf: stateFileURL),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let month = json["month"] as? String,
              let spend = json["spend"] as? Double else {
            return
        }
        if month == currentMonthKey {
            currentMonthSpendUSD = spend
        }
    }
    
    private func persistSpend() {
        let payload: [String: Any] = [
            "month": currentMonthKey,
            "spend": currentMonthSpendUSD
        ]
        if let data = try? JSONSerialization.data(withJSONObject: payload) {
            try? data.write(to: stateFileURL, options: .atomic)
        }
    }
}
