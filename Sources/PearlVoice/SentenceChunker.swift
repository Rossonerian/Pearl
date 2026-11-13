import Foundation

public final class SentenceChunker: @unchecked Sendable {
    private var buffer: String = ""
    private let minChunkLength: Int = 18
    private let clausePunctuation: CharacterSet = CharacterSet(charactersIn: ".!?;,:\n")
    
    public init() {}
    
    public func append(token: String) -> [String] {
        buffer.append(token)
        var readyChunks: [String] = []
        
        while true {
            guard let breakIndex = findNaturalBreakIndex(in: buffer) else {
                break
            }
            
            let chunk = String(buffer[..<breakIndex]).trimmingCharacters(in: .whitespacesAndNewlines)
            buffer = String(buffer[breakIndex...]).trimmingCharacters(in: .whitespaces)
            
            if !chunk.isEmpty {
                readyChunks.append(chunk)
            }
        }
        
        return readyChunks
    }
    
    public func finish() -> [String] {
        let remaining = buffer.trimmingCharacters(in: .whitespacesAndNewlines)
        buffer = ""
        return remaining.isEmpty ? [] : [remaining]
    }
    
    public func reset() {
        buffer = ""
    }
    
    private func findNaturalBreakIndex(in text: String) -> String.Index? {
        guard text.count >= minChunkLength else { return nil }
        
        var currentIndex = text.startIndex
        var lastValidBreak: String.Index? = nil
        
        while currentIndex < text.endIndex {
            let char = text[currentIndex]
            let scalar = char.unicodeScalars.first!
            
            if clausePunctuation.contains(scalar) {
                let nextIdx = text.index(after: currentIndex)
                if text.distance(from: text.startIndex, to: nextIdx) >= minChunkLength {
                    lastValidBreak = nextIdx
                    break
                }
            }
            currentIndex = text.index(after: currentIndex)
        }
        
        return lastValidBreak
    }
}
