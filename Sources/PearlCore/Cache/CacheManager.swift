import Foundation
import Dispatch

public struct CacheNamespaceStats: Codable, Sendable, Equatable {
    public let namespace: String
    public let entries: Int
    public let hits: Int
    public let misses: Int
    public var hitRate: Double
    
    public init(
        namespace: String,
        entries: Int,
        hits: Int,
        misses: Int,
        hitRate: Double? = nil
    ) {
        self.namespace = namespace
        self.entries = entries
        self.hits = hits
        self.misses = misses
        let total = hits + misses
        self.hitRate = hitRate ?? (total > 0 ? Double(hits) / Double(total) : 0.0)
    }
}

public final class TTLCache<Key: Hashable & Sendable, Value: Sendable>: @unchecked Sendable {
    private struct Entry: @unchecked Sendable {
        var value: Value
        var expiresAt: Date
        var lastAccessed: Date
        var accessSequence: UInt64
    }
    
    private let lock = NSLock()
    private var storage: [Key: Entry] = [:]
    private var sequenceCounter: UInt64 = 0
    public let maxSize: Int
    public let ttlSeconds: TimeInterval
    private var hits: Int = 0
    private var misses: Int = 0
    
    public init(maxSize: Int = 128, ttlSeconds: TimeInterval = 300) {
        self.maxSize = maxSize
        self.ttlSeconds = ttlSeconds
    }
    
    public func get(_ key: Key) -> Value? {
        lock.lock()
        defer { lock.unlock() }
        
        let now = Date()
        guard let entry = storage[key] else {
            misses += 1
            return nil
        }
        
        if entry.expiresAt <= now {
            storage.removeValue(forKey: key)
            misses += 1
            return nil
        }
        
        sequenceCounter += 1
        var updated = entry
        updated.lastAccessed = now
        updated.accessSequence = sequenceCounter
        storage[key] = updated
        hits += 1
        return updated.value
    }
    
    public func set(_ key: Key, value: Value, ttl: TimeInterval? = nil) {
        lock.lock()
        defer { lock.unlock() }
        
        let now = Date()
        let effectiveTTL = ttl ?? ttlSeconds
        let expiresAt = now.addingTimeInterval(effectiveTTL)
        sequenceCounter += 1
        
        if storage[key] != nil {
            storage[key] = Entry(value: value, expiresAt: expiresAt, lastAccessed: now, accessSequence: sequenceCounter)
            return
        }
        
        if storage.count >= maxSize {
            // Evict expired entries first
            let expiredKeys = storage.compactMap { (k, v) -> Key? in
                v.expiresAt <= now ? k : nil
            }
            for k in expiredKeys {
                storage.removeValue(forKey: k)
            }
            
            // If still at capacity, evict the least recently accessed (LRU) entry deterministically
            if storage.count >= maxSize {
                if let lruKey = storage.min(by: { $0.value.accessSequence < $1.value.accessSequence })?.key {
                    storage.removeValue(forKey: lruKey)
                }
            }
        }
        
        storage[key] = Entry(value: value, expiresAt: expiresAt, lastAccessed: now, accessSequence: sequenceCounter)
    }
    
    public func remove(_ key: Key) {
        lock.lock()
        defer { lock.unlock() }
        storage.removeValue(forKey: key)
    }
    
    public func removeWhere(_ predicate: (Key) -> Bool) {
        lock.lock()
        defer { lock.unlock() }
        let matchingKeys = storage.keys.filter(predicate)
        for k in matchingKeys {
            storage.removeValue(forKey: k)
        }
    }
    
    public func clear() {
        lock.lock()
        defer { lock.unlock() }
        storage.removeAll()
    }
    
    public func resetStats() {
        lock.lock()
        defer { lock.unlock() }
        hits = 0
        misses = 0
    }
    
    public func stats(namespace: String) -> CacheNamespaceStats {
        lock.lock()
        defer { lock.unlock() }
        let now = Date()
        let activeCount = storage.values.filter { $0.expiresAt > now }.count
        return CacheNamespaceStats(
            namespace: namespace,
            entries: activeCount,
            hits: hits,
            misses: misses
        )
    }
}

public final class CacheManager: @unchecked Sendable {
    public static let shared = CacheManager()
    
    public static let standardNamespaces: [String] = [
        "skills",
        "recipes",
        "memory",
        "vault",
        "config"
    ]
    
    private let lock = NSLock()
    private var caches: [String: TTLCache<String, String>] = [:]
    
    public init() {
        for ns in Self.standardNamespaces {
            caches[ns] = TTLCache<String, String>()
        }
    }
    
    private func getCache(for namespace: String) -> TTLCache<String, String> {
        lock.lock()
        defer { lock.unlock() }
        if let existing = caches[namespace] {
            return existing
        }
        let created = TTLCache<String, String>()
        caches[namespace] = created
        return created
    }
    
    public func getString(namespace: String, key: String) -> String? {
        return getCache(for: namespace).get(key)
    }
    
    public func setString(namespace: String, key: String, value: String, ttl: TimeInterval? = nil) {
        getCache(for: namespace).set(key, value: value, ttl: ttl)
    }
    
    public func invalidate(namespace: String) {
        getCache(for: namespace).clear()
    }
    
    public func invalidatePrefix(namespace: String, prefix: String) {
        getCache(for: namespace).removeWhere { $0.hasPrefix(prefix) }
    }
    
    public func clearAll() {
        lock.lock()
        let allCaches = Array(caches.values)
        lock.unlock()
        for cache in allCaches {
            cache.clear()
        }
    }
    
    public func reset() {
        lock.lock()
        let allCaches = Array(caches.values)
        lock.unlock()
        for cache in allCaches {
            cache.clear()
            cache.resetStats()
        }
    }
    
    public func allStats() -> [CacheNamespaceStats] {
        lock.lock()
        let allNamespaces = Set(Self.standardNamespaces).union(caches.keys).sorted()
        lock.unlock()
        return allNamespaces.map { ns in
            getCache(for: ns).stats(namespace: ns)
        }
    }
    
    public func formattedSummary() -> String {
        let stats = allStats()
        var lines: [String] = ["Cache Summary (\(stats.count) namespaces):"]
        for s in stats {
            let pct = String(format: "%.1f%%", s.hitRate * 100.0)
            lines.append("- \(s.namespace): \(s.entries) entries, \(s.hits) hits, \(s.misses) misses (hit rate: \(pct))")
        }
        return lines.joined(separator: "\n")
    }
}

public struct OperationPercentiles: Codable, Sendable, Equatable {
    public let operation: String
    public let count: Int
    public let p50Ms: Double
    public let p95Ms: Double
    public let p99Ms: Double
    public let meanMs: Double
    
    public init(
        operation: String,
        count: Int,
        p50Ms: Double,
        p95Ms: Double,
        p99Ms: Double,
        meanMs: Double
    ) {
        self.operation = operation
        self.count = count
        self.p50Ms = p50Ms
        self.p95Ms = p95Ms
        self.p99Ms = p99Ms
        self.meanMs = meanMs
    }
}

public final class PerformanceMonitor: @unchecked Sendable {
    public static let shared = PerformanceMonitor()
    
    private struct RingBuffer {
        let capacity: Int
        private var buffer: [Double]
        private var writeIndex: Int = 0
        private var count: Int = 0
        
        init(capacity: Int = 512) {
            self.capacity = capacity
            self.buffer = [Double](repeating: 0.0, count: capacity)
        }
        
        mutating func append(_ value: Double) {
            buffer[writeIndex] = value
            writeIndex = (writeIndex + 1) % capacity
            if count < capacity {
                count += 1
            }
        }
        
        var values: [Double] {
            if count < capacity {
                return Array(buffer.prefix(count))
            } else {
                return buffer
            }
        }
        
        var currentCount: Int {
            count
        }
    }
    
    private let lock = NSLock()
    private var buffers: [String: RingBuffer] = [:]
    
    public init() {}
    
    public func record(operation: String, durationMs: Double) {
        lock.lock()
        defer { lock.unlock() }
        if buffers[operation] == nil {
            buffers[operation] = RingBuffer(capacity: 512)
        }
        buffers[operation]?.append(durationMs)
    }
    
    public func measure<T>(operation: String, _ block: () throws -> T) rethrows -> T {
        let start = DispatchTime.now()
        defer {
            let end = DispatchTime.now()
            let nano = end.uptimeNanoseconds - start.uptimeNanoseconds
            let durationMs = Double(nano) / 1_000_000.0
            record(operation: operation, durationMs: durationMs)
        }
        return try block()
    }
    
    public func measureAsync<T>(operation: String, _ block: () async throws -> T) async rethrows -> T {
        let start = DispatchTime.now()
        defer {
            let end = DispatchTime.now()
            let nano = end.uptimeNanoseconds - start.uptimeNanoseconds
            let durationMs = Double(nano) / 1_000_000.0
            record(operation: operation, durationMs: durationMs)
        }
        return try await block()
    }
    
    private static func calculatePercentile(_ p: Double, sorted: [Double]) -> Double {
        guard !sorted.isEmpty else { return 0.0 }
        if sorted.count == 1 { return sorted[0] }
        let index = (p / 100.0) * Double(sorted.count - 1)
        let lower = Int(floor(index))
        let upper = Int(ceil(index))
        if lower == upper { return sorted[lower] }
        let fraction = index - Double(lower)
        return sorted[lower] + fraction * (sorted[upper] - sorted[lower])
    }
    
    private func _percentilesLocked(for operation: String) -> OperationPercentiles? {
        guard let ring = buffers[operation], ring.currentCount > 0 else {
            return nil
        }
        let vals = ring.values.sorted()
        let count = vals.count
        let sum = vals.reduce(0.0, +)
        let meanMs = sum / Double(count)
        let p50 = Self.calculatePercentile(50.0, sorted: vals)
        let p95 = Self.calculatePercentile(95.0, sorted: vals)
        let p99 = Self.calculatePercentile(99.0, sorted: vals)
        return OperationPercentiles(
            operation: operation,
            count: count,
            p50Ms: p50,
            p95Ms: p95,
            p99Ms: p99,
            meanMs: meanMs
        )
    }
    
    public func percentiles(for operation: String) -> OperationPercentiles? {
        lock.lock()
        defer { lock.unlock() }
        return _percentilesLocked(for: operation)
    }
    
    public func allMetrics() -> [OperationPercentiles] {
        lock.lock()
        defer { lock.unlock() }
        return buffers.keys.sorted().compactMap { _percentilesLocked(for: $0) }
    }
    
    public func reset() {
        lock.lock()
        defer { lock.unlock() }
        buffers.removeAll()
    }
    
    public func formattedSummary() -> String {
        let metrics = allMetrics()
        if metrics.isEmpty {
            return "Performance Metrics: No samples recorded"
        }
        var lines: [String] = ["Performance Metrics (\(metrics.count) operations):"]
        for m in metrics {
            let p50 = String(format: "%.2f", m.p50Ms)
            let p95 = String(format: "%.2f", m.p95Ms)
            let p99 = String(format: "%.2f", m.p99Ms)
            let mean = String(format: "%.2f", m.meanMs)
            lines.append("- \(m.operation): count=\(m.count), p50=\(p50)ms, p95=\(p95)ms, p99=\(p99)ms, mean=\(mean)ms")
        }
        return lines.joined(separator: "\n")
    }
}
