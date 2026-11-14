import Foundation

/// Pacing configuration for streaming response chunks to HUD and UI.
public struct CadenceConfig: Sendable, Equatable {
    public let baseDelayMs: UInt64
    public let commaPauseMs: UInt64
    public let sentencePauseMs: UInt64
    public let enableDelay: Bool
    
    public init(
        baseDelayMs: UInt64 = 25,
        commaPauseMs: UInt64 = 90,
        sentencePauseMs: UInt64 = 180,
        enableDelay: Bool = true
    ) {
        self.baseDelayMs = baseDelayMs
        self.commaPauseMs = commaPauseMs
        self.sentencePauseMs = sentencePauseMs
        self.enableDelay = enableDelay
    }
    
    /// Natural speaking / reading cadence (~250-300 wpm).
    public static let natural = CadenceConfig(baseDelayMs: 25, commaPauseMs: 90, sentencePauseMs: 180, enableDelay: true)
    
    /// Fast typing cadence (~500 wpm).
    public static let fast = CadenceConfig(baseDelayMs: 12, commaPauseMs: 45, sentencePauseMs: 90, enableDelay: true)
    
    /// Instant execution without sleep delays, suitable for unit tests and benchmarks.
    public static let instant = CadenceConfig(baseDelayMs: 0, commaPauseMs: 0, sentencePauseMs: 0, enableDelay: false)
}

/// Streaming helper that yields tokens and word chunks with realistic cadence for live HUD typing feedback.
public final class StreamingResponseChunker: Sendable {
    public init() {}
    
    /// Splits text into word/punctuation chunks with natural trailing boundaries.
    ///
    /// For example:
    /// `"Pearl is ready, sir."` -> `["Pearl ", "is ", "ready, ", "sir."]`
    public static func tokenize(text: String) -> [String] {
        guard !text.isEmpty else { return [] }
        
        var chunks: [String] = []
        var currentChunk = ""
        let chars = Array(text)
        var i = 0
        
        while i < chars.count {
            let char = chars[i]
            currentChunk.append(char)
            
            // Check if we reached a word boundary (whitespace or newline)
            if char.isWhitespace || char.isNewline {
                // Consume consecutive whitespaces into the same chunk
                while i + 1 < chars.count && (chars[i + 1].isWhitespace || chars[i + 1].isNewline) {
                    i += 1
                    currentChunk.append(chars[i])
                }
                chunks.append(currentChunk)
                currentChunk = ""
            }
            i += 1
        }
        
        if !currentChunk.isEmpty {
            chunks.append(currentChunk)
        }
        
        return chunks
    }
    
    /// Streams pre-synthesized text as an `AsyncStream<String>` yielding chunks with realistic typing cadence.
    public static func stream(
        text: String,
        cadence: CadenceConfig = .natural
    ) -> AsyncStream<String> {
        let tokens = tokenize(text: text)
        return AsyncStream { continuation in
            let task = Task {
                for token in tokens {
                    if Task.isCancelled { break }
                    
                    continuation.yield(token)
                    
                    if cadence.enableDelay {
                        let delayMs = delayForToken(token, cadence: cadence)
                        if delayMs > 0 {
                            try? await Task.sleep(nanoseconds: delayMs * 1_000_000)
                        }
                    }
                }
                continuation.finish()
            }
            
            continuation.onTermination = { @Sendable _ in
                task.cancel()
            }
        }
    }
    
    /// Smooths an incoming `AsyncThrowingStream` from LLM providers, breaking larger blocks
    /// into natural word tokens and pacing delivery to the HUD.
    public static func smoothStream(
        upstream: AsyncThrowingStream<String, Error>,
        cadence: CadenceConfig = .natural
    ) -> AsyncThrowingStream<String, Error> {
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    for try await chunk in upstream {
                        if Task.isCancelled { break }
                        let tokens = tokenize(text: chunk)
                        for token in tokens {
                            if Task.isCancelled { break }
                            continuation.yield(token)
                            if cadence.enableDelay {
                                let delayMs = delayForToken(token, cadence: cadence)
                                if delayMs > 0 {
                                    try? await Task.sleep(nanoseconds: delayMs * 1_000_000)
                                }
                            }
                        }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            
            continuation.onTermination = { @Sendable _ in
                task.cancel()
            }
        }
    }
    
    // MARK: - Cadence Calculation
    
    private static func delayForToken(_ token: String, cadence: CadenceConfig) -> UInt64 {
        let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasSuffix(".") || trimmed.hasSuffix("!") || trimmed.hasSuffix("?") {
            return cadence.sentencePauseMs
        } else if trimmed.hasSuffix(",") || trimmed.hasSuffix(";") || trimmed.hasSuffix(":") {
            return cadence.commaPauseMs
        } else if token.contains("\n") {
            return cadence.sentencePauseMs
        } else {
            return cadence.baseDelayMs
        }
    }
}
