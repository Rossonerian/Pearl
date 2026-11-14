import Foundation

public enum MLXProviderError: Error, LocalizedError, Sendable, Equatable {
    case disabled
    case memoryPressureRefused
    case runtimeUnavailable(String)
    case executionFailed(String)
    
    public var errorDescription: String? {
        switch self {
        case .disabled:
            return "MLX Provider is disabled."
        case .memoryPressureRefused:
            return "MLX Provider refused execution due to active system memory pressure."
        case .runtimeUnavailable(let reason):
            return "MLX runtime unavailable: \(reason)"
        case .executionFailed(let reason):
            return "MLX execution failed: \(reason)"
        }
    }
}

public final class MLXProvider: ModelProvider, @unchecked Sendable {
    public let name = "MLX-Local"
    public let modelID: String
    public let isLocal = true
    public let maxAllowedTier = ToolTier.t2ReadPersonal
    
    public let idleUnloadSeconds: TimeInterval
    
    private let lock = NSLock()
    private var _isLoaded: Bool = false
    private var _isUnderMemoryPressure: Bool = false
    private var idleTimer: DispatchSourceTimer?
    
    public typealias InferenceRunner = @Sendable (_ modelID: String, _ prompt: String, _ context: ModelExecutionContext) async throws -> String
    private let customRunner: InferenceRunner?
    
    public var isLoaded: Bool {
        lock.withLock { _isLoaded }
    }
    
    public var estimatedModelFootprintMB: Double {
        return isLoaded ? 850.0 : 0.0
    }
    
    public var isUnderMemoryPressure: Bool {
        lock.withLock { _isUnderMemoryPressure }
    }
    
    public init(
        modelID: String = PearlConfig.load().mlxModelID,
        idleUnloadSeconds: TimeInterval = TimeInterval(PearlConfig.load().mlxIdleUnloadSeconds),
        runner: InferenceRunner? = nil
    ) {
        self.modelID = modelID
        self.idleUnloadSeconds = idleUnloadSeconds
        self.customRunner = runner
    }
    
    public func setMemoryPressure(active: Bool) {
        lock.withLock {
            _isUnderMemoryPressure = active
            if active && _isLoaded {
                _isLoaded = false
                cancelIdleTimerLocked()
            }
        }
    }
    
    public func unload() {
        lock.withLock {
            _isLoaded = false
            cancelIdleTimerLocked()
        }
    }
    
    private func cancelIdleTimerLocked() {
        idleTimer?.cancel()
        idleTimer = nil
    }
    
    private func resetIdleTimer() {
        lock.withLock {
            cancelIdleTimerLocked()
            
            guard idleUnloadSeconds > 0 else { return }
            
            let timer = DispatchSource.makeTimerSource(queue: DispatchQueue.global(qos: .utility))
            timer.schedule(deadline: .now() + idleUnloadSeconds)
            timer.setEventHandler { [weak self] in
                self?.unload()
            }
            idleTimer = timer
            timer.resume()
        }
    }
    
    public func loadIfNeeded() throws {
        try lock.withLock {
            if _isUnderMemoryPressure {
                _isLoaded = false
                cancelIdleTimerLocked()
                throw MLXProviderError.memoryPressureRefused
            }
            
            if !_isLoaded {
                if customRunner == nil {
                    let process = Process()
                    process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
                    process.arguments = ["which", "mlx_lm.generate"]
                    let pipe = Pipe()
                    process.standardOutput = pipe
                    process.standardError = pipe
                    try process.run()
                    process.waitUntilExit()
                    if process.terminationStatus != 0 {
                        let pyProcess = Process()
                        pyProcess.executableURL = URL(fileURLWithPath: "/usr/bin/env")
                        pyProcess.arguments = ["python3", "-c", "import mlx_lm"]
                        pyProcess.standardOutput = Pipe()
                        pyProcess.standardError = Pipe()
                        try pyProcess.run()
                        pyProcess.waitUntilExit()
                        if pyProcess.terminationStatus != 0 {
                            throw MLXProviderError.runtimeUnavailable("mlx_lm python package or mlx_lm.generate executable not found in PATH.")
                        }
                    }
                }
                _isLoaded = true
            }
        }
    }
    
    public func generate(prompt: String, context: ModelExecutionContext = ModelExecutionContext()) async throws -> ModelResponse {
        try lock.withLock {
            if _isUnderMemoryPressure {
                _isLoaded = false
                cancelIdleTimerLocked()
                throw MLXProviderError.memoryPressureRefused
            }
        }
        
        try loadIfNeeded()
        
        let content: String
        do {
            if let runner = customRunner {
                content = try await runner(modelID, prompt, context)
            } else {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
                var args = ["python3", "-m", "mlx_lm.generate", "--model", modelID, "--prompt", prompt]
                if let maxTokens = context.maxTokens {
                    args.append(contentsOf: ["--max-tokens", String(maxTokens)])
                }
                process.arguments = args
                let pipe = Pipe()
                process.standardOutput = pipe
                let errorPipe = Pipe()
                process.standardError = errorPipe
                
                try process.run()
                process.waitUntilExit()
                
                if process.terminationStatus != 0 {
                    let errData = errorPipe.fileHandleForReading.readDataToEndOfFile()
                    let errStr = String(data: errData, encoding: .utf8) ?? "Unknown error"
                    throw MLXProviderError.executionFailed(errStr)
                }
                
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                content = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            }
        } catch let mlxErr as MLXProviderError {
            throw mlxErr
        } catch {
            throw MLXProviderError.executionFailed(error.localizedDescription)
        }
        
        resetIdleTimer()
        
        let detailsText = "on-demand 4-bit (~850 MB model, auto-unload \(Int(idleUnloadSeconds))s)"
        let badge = HUDTurnBadge(
            label: "local mlx",
            provider: name,
            modelID: modelID,
            isLocal: true,
            details: detailsText
        )
        
        return ModelResponse(
            content: content,
            toolCalls: [],
            usage: nil,
            providerName: name,
            modelID: modelID,
            isLocal: true,
            badge: badge
        )
    }
    
    public func stream(prompt: String, context: ModelExecutionContext = ModelExecutionContext()) -> AsyncThrowingStream<String, Error> {
        return AsyncThrowingStream { continuation in
            Task {
                do {
                    let response = try await generate(prompt: prompt, context: context)
                    continuation.yield(response.content)
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }
    }
}
