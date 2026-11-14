import XCTest
@testable import PearlCore

final class CacheAndTelemetryTests: XCTestCase {
    
    override func setUp() {
        super.setUp()
        CacheManager.shared.clearAll()
        PerformanceMonitor.shared.reset()
    }
    
    // MARK: - 1. TTL Expiration
    func testTTLExpiration() {
        let cache = TTLCache<String, String>(maxSize: 10, ttlSeconds: 0.05)
        cache.set("ephemeralKey", value: "hello")
        
        XCTAssertEqual(cache.get("ephemeralKey"), "hello")
        
        // Wait past TTL
        Thread.sleep(forTimeInterval: 0.08)
        
        XCTAssertNil(cache.get("ephemeralKey"))
        let stats = cache.stats(namespace: "test")
        XCTAssertEqual(stats.entries, 0)
        XCTAssertEqual(stats.hits, 1)
        XCTAssertEqual(stats.misses, 1)
    }
    
    // MARK: - 2. Per-Entry TTL Override
    func testTTLPerEntryOverride() {
        let cache = TTLCache<String, String>(maxSize: 10, ttlSeconds: 300)
        cache.set("shortKey", value: "quick", ttl: 0.04)
        cache.set("longKey", value: "persistent", ttl: 60.0)
        
        XCTAssertEqual(cache.get("shortKey"), "quick")
        XCTAssertEqual(cache.get("longKey"), "persistent")
        
        Thread.sleep(forTimeInterval: 0.07)
        
        XCTAssertNil(cache.get("shortKey"))
        XCTAssertEqual(cache.get("longKey"), "persistent")
        
        let stats = cache.stats(namespace: "test")
        XCTAssertEqual(stats.entries, 1)
    }
    
    // MARK: - 3. LRU Eviction
    func testLRUEvictionWhenExceedingMaxSize() {
        let cache = TTLCache<String, String>(maxSize: 3, ttlSeconds: 300)
        cache.set("k1", value: "v1")
        cache.set("k2", value: "v2")
        cache.set("k3", value: "v3")
        
        // Access k1 to make k2 the least recently used
        XCTAssertEqual(cache.get("k1"), "v1")
        
        // Insert k4, exceeding maxSize (3). k2 should be evicted
        cache.set("k4", value: "v4")
        
        XCTAssertNil(cache.get("k2"), "k2 should have been evicted as LRU")
        XCTAssertEqual(cache.get("k1"), "v1")
        XCTAssertEqual(cache.get("k3"), "v3")
        XCTAssertEqual(cache.get("k4"), "v4")
        
        let stats = cache.stats(namespace: "lru")
        XCTAssertEqual(stats.entries, 3)
    }
    
    // MARK: - 4. Hit/Miss Counters & Hit Rate
    func testHitMissCountersAndHitRate() {
        let cache = TTLCache<String, Int>(maxSize: 10, ttlSeconds: 300)
        
        let initialStats = cache.stats(namespace: "test")
        XCTAssertEqual(initialStats.hits, 0)
        XCTAssertEqual(initialStats.misses, 0)
        XCTAssertEqual(initialStats.hitRate, 0.0)
        
        cache.set("a", value: 100)
        _ = cache.get("a") // Hit 1
        _ = cache.get("a") // Hit 2
        _ = cache.get("b") // Miss 1
        _ = cache.get("c") // Miss 2
        
        let statsAfter = cache.stats(namespace: "test")
        XCTAssertEqual(statsAfter.hits, 2)
        XCTAssertEqual(statsAfter.misses, 2)
        XCTAssertEqual(statsAfter.hitRate, 0.5)
        
        _ = cache.get("a") // Hit 3
        let finalStats = cache.stats(namespace: "test")
        XCTAssertEqual(finalStats.hits, 3)
        XCTAssertEqual(finalStats.misses, 2)
        XCTAssertEqual(finalStats.hitRate, 0.6)
    }
    
    // MARK: - 5. CacheManager Invalidate Namespace
    func testCacheManagerInvalidateNamespace() {
        let manager = CacheManager.shared
        
        manager.setString(namespace: "skills", key: "skill1", value: "voice-assistant")
        manager.setString(namespace: "skills", key: "skill2", value: "code-analysis")
        manager.setString(namespace: "recipes", key: "recipe1", value: "build-pipeline")
        
        XCTAssertEqual(manager.getString(namespace: "skills", key: "skill1"), "voice-assistant")
        XCTAssertEqual(manager.getString(namespace: "recipes", key: "recipe1"), "build-pipeline")
        
        manager.invalidate(namespace: "skills")
        
        XCTAssertNil(manager.getString(namespace: "skills", key: "skill1"))
        XCTAssertNil(manager.getString(namespace: "skills", key: "skill2"))
        XCTAssertEqual(manager.getString(namespace: "recipes", key: "recipe1"), "build-pipeline")
    }
    
    // MARK: - 6. CacheManager Invalidate Prefix
    func testCacheManagerInvalidatePrefix() {
        let manager = CacheManager()
        
        manager.setString(namespace: "vault", key: "notes/work/meeting.md", value: "Notes 1")
        manager.setString(namespace: "vault", key: "notes/personal/diary.md", value: "Notes 2")
        manager.setString(namespace: "vault", key: "config/settings.json", value: "Settings")
        
        manager.invalidatePrefix(namespace: "vault", prefix: "notes/work/")
        
        XCTAssertNil(manager.getString(namespace: "vault", key: "notes/work/meeting.md"))
        XCTAssertEqual(manager.getString(namespace: "vault", key: "notes/personal/diary.md"), "Notes 2")
        XCTAssertEqual(manager.getString(namespace: "vault", key: "config/settings.json"), "Settings")
    }
    
    // MARK: - 7. CacheManager ClearAll & Formatted Summary
    func testCacheManagerClearAllAndFormattedSummary() {
        let manager = CacheManager()
        
        manager.setString(namespace: "skills", key: "s", value: "val1")
        manager.setString(namespace: "recipes", key: "r", value: "val2")
        manager.setString(namespace: "memory", key: "m", value: "val3")
        manager.setString(namespace: "vault", key: "v", value: "val4")
        manager.setString(namespace: "config", key: "c", value: "val5")
        
        let statsBefore = manager.allStats()
        XCTAssertEqual(statsBefore.count, 5)
        for stat in statsBefore {
            XCTAssertEqual(stat.entries, 1)
        }
        
        let summary = manager.formattedSummary()
        XCTAssertTrue(summary.contains("Cache Summary"))
        XCTAssertTrue(summary.contains("skills"))
        XCTAssertTrue(summary.contains("recipes"))
        XCTAssertTrue(summary.contains("config"))
        
        manager.clearAll()
        
        XCTAssertNil(manager.getString(namespace: "skills", key: "s"))
        XCTAssertNil(manager.getString(namespace: "config", key: "c"))
        
        let statsAfter = manager.allStats()
        for stat in statsAfter {
            XCTAssertEqual(stat.entries, 0)
        }
    }
    
    // MARK: - 8. PerformanceMonitor Record & Percentiles
    func testPerformanceMonitorRecordAndPercentiles() {
        let monitor = PerformanceMonitor()
        
        // Record 100 samples from 1.0 to 100.0
        for i in 1...100 {
            monitor.record(operation: "db_query", durationMs: Double(i))
        }
        
        guard let p = monitor.percentiles(for: "db_query") else {
            XCTFail("Percentiles should exist for recorded operation")
            return
        }
        
        XCTAssertEqual(p.operation, "db_query")
        XCTAssertEqual(p.count, 100)
        XCTAssertEqual(p.meanMs, 50.5, accuracy: 0.001)
        XCTAssertEqual(p.p50Ms, 50.5, accuracy: 0.1)
        XCTAssertEqual(p.p95Ms, 95.05, accuracy: 0.1)
        XCTAssertEqual(p.p99Ms, 99.01, accuracy: 0.1)
        
        let summary = monitor.formattedSummary()
        XCTAssertTrue(summary.contains("Performance Metrics"))
        XCTAssertTrue(summary.contains("db_query"))
        
        monitor.reset()
        XCTAssertNil(monitor.percentiles(for: "db_query"))
        XCTAssertTrue(monitor.allMetrics().isEmpty)
    }
    
    // MARK: - 9. PerformanceMonitor Measure Sync and Async
    func testPerformanceMonitorMeasureSyncAndAsync() async throws {
        let monitor = PerformanceMonitor()
        
        let syncVal = monitor.measure(operation: "sync_op") { () -> Int in
            Thread.sleep(forTimeInterval: 0.01)
            return 123
        }
        XCTAssertEqual(syncVal, 123)
        
        let syncMetrics = monitor.percentiles(for: "sync_op")
        XCTAssertNotNil(syncMetrics)
        XCTAssertEqual(syncMetrics?.count, 1)
        XCTAssertGreaterThan(syncMetrics?.meanMs ?? 0.0, 5.0)
        
        let asyncVal = try await monitor.measureAsync(operation: "async_op") { () -> String in
            try await Task.sleep(nanoseconds: 10_000_000)
            return "async_result"
        }
        XCTAssertEqual(asyncVal, "async_result")
        
        let asyncMetrics = monitor.percentiles(for: "async_op")
        XCTAssertNotNil(asyncMetrics)
        XCTAssertEqual(asyncMetrics?.count, 1)
        XCTAssertGreaterThan(asyncMetrics?.meanMs ?? 0.0, 5.0)
    }
    
    // MARK: - 10. PerformanceMonitor Bounded Ring Buffer
    func testPerformanceMonitorBoundedRingBuffer() {
        let monitor = PerformanceMonitor()
        
        // Add 600 samples; capacity is 512
        for i in 1...600 {
            monitor.record(operation: "stress_op", durationMs: Double(i))
        }
        
        let metrics = monitor.percentiles(for: "stress_op")
        XCTAssertNotNil(metrics)
        XCTAssertEqual(metrics?.count, 512)
        
        // The first 88 items (1..88) should have been overwritten, leaving 89..600
        // Mean of 89..600 is (89 + 600) / 2 = 344.5
        XCTAssertEqual(metrics?.meanMs ?? 0.0, 344.5, accuracy: 0.1)
    }
    
    // MARK: - 11. PearlConfig Legacy JSON Backward Compatibility
    func testPearlConfigLegacyJSONBackwardCompatibility() throws {
        let legacyJSON = """
        {
            "version": "3.1.0",
            "hotkey": "ctrl+opt+space",
            "socketPath": "/tmp/pearl.sock",
            "fastModelID": "haiku",
            "escalationModelID": "sonnet",
            "modelProviderEndpoint": "https://api.anthropic.com",
            "voiceLocale": "en-US",
            "preferredVoice": "Alex",
            "bargeInEnabled": true,
            "pushToTalkDefault": true,
            "maxContextTokens": 2048,
            "memoryDirectory": "/tmp/memory",
            "monthlySpendCapUSD": 5.0,
            "maxTokensPerTurn": 1024,
            "pccEnabled": false,
            "mlxEnabled": true,
            "mlxModelID": "mlx-community/Qwen2.5-1.5B-Instruct-4bit",
            "mlxIdleUnloadSeconds": 45,
            "allowedFolders": ["~/Projects"],
            "quietHoursStart": 23,
            "quietHoursEnd": 7,
            "autoLeaveSeconds": 5.0
        }
        """.data(using: .utf8)!
        
        let config = try JSONDecoder().decode(PearlConfig.self, from: legacyJSON)
        
        // Legacy keys decoded
        XCTAssertEqual(config.version, "3.1.0")
        XCTAssertEqual(config.hotkey, "ctrl+opt+space")
        XCTAssertTrue(config.mlxEnabled)
        XCTAssertEqual(config.mlxIdleUnloadSeconds, 45)
        
        // V3.2 keys default gracefully
        XCTAssertEqual(config.activePersona, "executive")
        XCTAssertEqual(config.vaultPath, ("~/Documents/PearlVault" as NSString).expandingTildeInPath)
        XCTAssertEqual(config.outputDirectoryPath, ("~/Documents/PearlOutput" as NSString).expandingTildeInPath)
        XCTAssertEqual(config.subBotMaxConcurrency, 4)
        XCTAssertNil(config.firecrawlApiKey)
    }
    
    // MARK: - 12. PearlConfig V3.2 Round-Trip Encoding
    func testPearlConfigV32RoundTripEncoding() throws {
        var original = PearlConfig()
        XCTAssertEqual(original.version, "3.2.0")
        XCTAssertEqual(original.activePersona, "executive")
        XCTAssertEqual(original.subBotMaxConcurrency, 4)
        XCTAssertNil(original.firecrawlApiKey)
        
        original.activePersona = "researcher"
        original.vaultPath = "/custom/vault/path"
        original.outputDirectoryPath = "/custom/output/path"
        original.subBotMaxConcurrency = 8
        original.firecrawlApiKey = "fc-test-key-12345"
        
        let encoder = JSONEncoder()
        encoder.outputFormatting = .prettyPrinted
        let encodedData = try encoder.encode(original)
        
        let decoded = try JSONDecoder().decode(PearlConfig.self, from: encodedData)
        
        XCTAssertEqual(decoded.version, "3.2.0")
        XCTAssertEqual(decoded.activePersona, "researcher")
        XCTAssertEqual(decoded.vaultPath, "/custom/vault/path")
        XCTAssertEqual(decoded.outputDirectoryPath, "/custom/output/path")
        XCTAssertEqual(decoded.subBotMaxConcurrency, 8)
        XCTAssertEqual(decoded.firecrawlApiKey, "fc-test-key-12345")
        XCTAssertEqual(decoded.hotkey, original.hotkey)
        XCTAssertEqual(decoded.maxTokensPerTurn, original.maxTokensPerTurn)
    }
}
