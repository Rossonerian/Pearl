import XCTest
@testable import PearlCore

final class MLXProviderTests: XCTestCase {
    
    func testInitialIdleState() {
        let provider = MLXProvider(runner: { _, prompt, _ in
            return "mock response"
        })
        XCTAssertFalse(provider.isLoaded)
        XCTAssertEqual(provider.estimatedModelFootprintMB, 0.0)
        XCTAssertFalse(provider.isUnderMemoryPressure)
    }
    
    func testLoadingViaMockRunnerFlipsState() async throws {
        let provider = MLXProvider(runner: { _, prompt, _ in
            return "Hello from MLX: \(prompt)"
        })
        
        XCTAssertFalse(provider.isLoaded)
        
        let response = try await provider.generate(prompt: "Test prompt")
        XCTAssertTrue(provider.isLoaded)
        XCTAssertEqual(provider.estimatedModelFootprintMB, 850.0)
        XCTAssertEqual(response.content, "Hello from MLX: Test prompt")
        XCTAssertEqual(response.providerName, "MLX-Local")
        XCTAssertTrue(response.isLocal)
        XCTAssertEqual(response.badge.label, "local mlx")
    }
    
    func testMemoryPressureRefusal() async {
        let provider = MLXProvider(runner: { _, prompt, _ in
            return "response"
        })
        
        provider.setMemoryPressure(active: true)
        XCTAssertTrue(provider.isUnderMemoryPressure)
        
        do {
            _ = try await provider.generate(prompt: "test")
            XCTFail("Expected memoryPressureRefused error")
        } catch let error as MLXProviderError {
            XCTAssertEqual(error, .memoryPressureRefused)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
        
        XCTAssertFalse(provider.isLoaded)
        XCTAssertEqual(provider.estimatedModelFootprintMB, 0.0)
    }
    
    func testManualUnload() async throws {
        let provider = MLXProvider(runner: { _, prompt, _ in
            return "response"
        })
        
        _ = try await provider.generate(prompt: "test")
        XCTAssertTrue(provider.isLoaded)
        
        provider.unload()
        XCTAssertFalse(provider.isLoaded)
        XCTAssertEqual(provider.estimatedModelFootprintMB, 0.0)
    }
    
    func testIdleTimerAutoUnload() async throws {
        let provider = MLXProvider(idleUnloadSeconds: 0.1, runner: { _, prompt, _ in
            return "response"
        })
        
        _ = try await provider.generate(prompt: "test")
        XCTAssertTrue(provider.isLoaded)
        
        // Wait for idle timer to fire
        try await Task.sleep(nanoseconds: 250_000_000) // 0.25 seconds
        
        XCTAssertFalse(provider.isLoaded)
        XCTAssertEqual(provider.estimatedModelFootprintMB, 0.0)
    }
    
    func testPearlConfigDecodesLegacyJSONMissingV31Keys() throws {
        let legacyJSON = """
        {
            "version": "2.0.0",
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
            "pccEnabled": false
        }
        """.data(using: .utf8)!
        
        let config = try JSONDecoder().decode(PearlConfig.self, from: legacyJSON)
        XCTAssertEqual(config.version, "2.0.0")
        XCTAssertFalse(config.mlxEnabled)
        XCTAssertEqual(config.mlxModelID, "mlx-community/Qwen2.5-1.5B-Instruct-4bit")
        XCTAssertEqual(config.mlxIdleUnloadSeconds, 30)
        XCTAssertEqual(config.allowedFolders, ["~/Documents", "~/Downloads", "~/Desktop", "~/Projects"])
        XCTAssertEqual(config.quietHoursStart, 22)
        XCTAssertEqual(config.quietHoursEnd, 8)
        XCTAssertEqual(config.autoLeaveSeconds, 4.0)
    }
    
    func testFallbackChainRoutesThroughMLXProviderWhenEnabled() async {
        let mlx = MLXProvider(runner: { _, _, _ in
            return "MLX successful response"
        })
        
        // appleFM will fail if simulated unavailable, or we can use forceEscalation = false but make appleFM fail
        let appleFM = AppleFMProvider()
        appleFM.isSimulatedUnavailable = true
        
        let chain = FallbackChain(appleFM: appleFM, mlxProvider: mlx, pccEnabled: false, mlxEnabled: true)
        let context = ModelExecutionContext(forceEscalation: false)
        
        let response = await chain.process(utterance: "hello", context: context)
        XCTAssertEqual(response.content, "MLX successful response")
        XCTAssertEqual(response.providerName, "MLX-Local")
        XCTAssertTrue(response.isLocal)
    }
    
    func testFallbackChainLogsCleanFailureWhenMLXDisabled() async {
        let mlx = MLXProvider(runner: { _, _, _ in
            return "should not be called"
        })
        
        let appleFM = AppleFMProvider()
        appleFM.isSimulatedUnavailable = true
        
        let chain = FallbackChain(appleFM: appleFM, mlxProvider: mlx, pccEnabled: false, mlxEnabled: false)
        let context = ModelExecutionContext(forceEscalation: true) // bypasses appleFM
        
        let response = await chain.process(utterance: "hello", context: context)
        // Should fall through to offline fallback since AppleFM bypassed, MLX disabled, PCC false, Frontier offline
        XCTAssertEqual(response.providerName, "Offline Fallback")
        XCTAssertTrue(response.content.contains("On-device Small MLX: Disabled in settings"))
    }
}
