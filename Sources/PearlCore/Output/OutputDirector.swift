import Foundation

/// Defines how the assistant's response should be delivered across voice and HUD modalities.
public enum OutputDeliveryMode: String, Sendable, Codable, Equatable {
    case speakFull
    case speakSummaryAndHUD
    case hudOnly
    case silentNotification
}

/// Structured decision from OutputDirector describing modality delivery, spoken content, and auto-dismiss timing.
public struct OutputDecision: Sendable, Codable, Equatable {
    public let mode: OutputDeliveryMode
    public let hudText: String
    public let spokenText: String?
    public let autoLeaveSeconds: TimeInterval
    public let dismissOnAppSwitch: Bool
    
    public init(
        mode: OutputDeliveryMode,
        hudText: String,
        spokenText: String? = nil,
        autoLeaveSeconds: TimeInterval = 4.0,
        dismissOnAppSwitch: Bool = true
    ) {
        self.mode = mode
        self.hudText = hudText
        self.spokenText = spokenText
        self.autoLeaveSeconds = autoLeaveSeconds
        self.dismissOnAppSwitch = dismissOnAppSwitch
    }
}

/// Adaptive OutputDirector ("Talk Back & Leave") for Pearl.
///
/// Decides delivery modality, spoken summary generation, and HUD auto-leave lifecycle
/// based on request provenance, user presence, confirmation requirements, and response payload structure.
public final class OutputDirector: Sendable {
    public static let shared = OutputDirector()
    
    public init() {}
    
    /// Decides delivery mode, spoken text, and HUD auto-dismiss timing for a given response.
    public func decide(
        responseText: String,
        speechText: String? = nil,
        origin: RequestOrigin,
        isError: Bool = false,
        requiresConfirmation: Bool = false,
        userPresent: Bool = true,
        defaultLeaveSeconds: TimeInterval = 4.0
    ) -> OutputDecision {
        // Case 1: requiresConfirmation == true
        if requiresConfirmation {
            return OutputDecision(
                mode: .speakSummaryAndHUD,
                hudText: responseText,
                spokenText: "Confirmation required. Check the HUD to confirm or cancel.",
                autoLeaveSeconds: 0,
                dismissOnAppSwitch: false
            )
        }
        
        // Case 2: userPresent == false
        if !userPresent {
            return OutputDecision(
                mode: .silentNotification,
                hudText: responseText,
                spokenText: nil,
                autoLeaveSeconds: 2.0,
                dismissOnAppSwitch: true
            )
        }
        
        // Case 3: heavy/structured content
        // contains ```, OR > 3 bullet/numbered lines, OR responseText.count > 220
        let isHeavy = responseText.contains("```") ||
                      countBulletOrNumberedLines(responseText) > 3 ||
                      responseText.count > 220
        
        if isHeavy {
            let mode: OutputDeliveryMode = (origin == .voice) ? .speakSummaryAndHUD : .hudOnly
            let spoken: String? = (origin == .voice) ? summarizeForSpeech(responseText) : nil
            return OutputDecision(
                mode: mode,
                hudText: responseText,
                spokenText: spoken,
                autoLeaveSeconds: 7.0,
                dismissOnAppSwitch: true
            )
        }
        
        // Case 4: short conversational / direct action reply
        let mode: OutputDeliveryMode = (origin == .voice) ? .speakFull : .hudOnly
        let spoken: String? = (origin == .voice) ? stripMarkdownForSpeech(speechText ?? responseText) : nil
        return OutputDecision(
            mode: mode,
            hudText: responseText,
            spokenText: spoken,
            autoLeaveSeconds: defaultLeaveSeconds,
            dismissOnAppSwitch: true
        )
    }
    
    /// Summarizes heavy or structured text for speech:
    /// strips code blocks/markdown, takes first sentence capped at 140 chars,
    /// and appends " Full details are shown in the HUD." if truncated or code blocks existed.
    public func summarizeForSpeech(_ text: String) -> String {
        let hadCodeBlocks = text.contains("```")
        let stripped = stripMarkdownForSpeech(text)
        
        let (sentence, isTruncatedBySentence) = extractFirstSentence(from: stripped)
        let isTruncated = isTruncatedBySentence || (text.count > stripped.count && stripped.count > sentence.count)
        
        if sentence.isEmpty {
            return "Full details are shown in the HUD."
        }
        
        if isTruncated || hadCodeBlocks {
            return sentence + " Full details are shown in the HUD."
        }
        
        return sentence
    }
    
    /// Strips markdown syntax (backticks, **, ##, headers, links, bullets) for clean text-to-speech output.
    public func stripMarkdownForSpeech(_ text: String) -> String {
        var result = text
        
        // 1. Remove code blocks
        while let startRange = result.range(of: "```") {
            let afterStart = result[startRange.upperBound...]
            if let endRange = afterStart.range(of: "```") {
                result.removeSubrange(startRange.lowerBound..<endRange.upperBound)
            } else {
                result.removeSubrange(startRange.lowerBound..<result.endIndex)
                break
            }
        }
        
        // 2. Remove inline code backticks `code` -> code
        result = result.replacingOccurrences(of: "`", with: "")
        
        // 3. Remove markdown images ![alt](url)
        let imgRegex = try? NSRegularExpression(pattern: #"(!\[.*?\]\(.*?\))"#, options: [])
        if let imgRegex = imgRegex {
            result = imgRegex.stringByReplacingMatches(
                in: result,
                options: [],
                range: NSRange(location: 0, length: result.utf16.count),
                withTemplate: ""
            )
        }
        
        // 4. Convert markdown links [title](url) -> title
        let linkRegex = try? NSRegularExpression(pattern: #"\[(.*?)\]\(.*?\)"#, options: [])
        if let linkRegex = linkRegex {
            result = linkRegex.stringByReplacingMatches(
                in: result,
                options: [],
                range: NSRange(location: 0, length: result.utf16.count),
                withTemplate: "$1"
            )
        }
        
        // 5. Remove bold / italics / strikethrough markers: **, __, ~~
        result = result.replacingOccurrences(of: "**", with: "")
        result = result.replacingOccurrences(of: "__", with: "")
        result = result.replacingOccurrences(of: "~~", with: "")
        
        // 6. Clean line-by-line elements: headers (## ), bullets (- , * , + ), blockquotes (> )
        let lines = result.components(separatedBy: .newlines)
        var cleanedLines: [String] = []
        for line in lines {
            var trimmedLine = line.trimmingCharacters(in: .whitespaces)
            
            // Remove markdown headers: #, ##, ###, etc.
            while trimmedLine.hasPrefix("#") {
                trimmedLine.removeFirst()
            }
            trimmedLine = trimmedLine.trimmingCharacters(in: .whitespaces)
            
            // Remove blockquote marker >
            if trimmedLine.hasPrefix(">") {
                trimmedLine.removeFirst()
                trimmedLine = trimmedLine.trimmingCharacters(in: .whitespaces)
            }
            
            // Remove bullet markers: - , * , +
            if trimmedLine.hasPrefix("- ") || trimmedLine.hasPrefix("* ") || trimmedLine.hasPrefix("+ ") {
                trimmedLine.removeSubrange(trimmedLine.startIndex..<trimmedLine.index(trimmedLine.startIndex, offsetBy: 2))
                trimmedLine = trimmedLine.trimmingCharacters(in: .whitespaces)
            } else if let dotIndex = trimmedLine.firstIndex(of: ".") {
                let prefix = trimmedLine[..<dotIndex]
                if !prefix.isEmpty && prefix.allSatisfy({ $0.isNumber }) {
                    let remainder = trimmedLine[trimmedLine.index(after: dotIndex)...]
                    if remainder.hasPrefix(" ") {
                        trimmedLine = remainder.trimmingCharacters(in: .whitespaces)
                    }
                }
            }
            
            // Remove remaining lone * markers inside line
            trimmedLine = trimmedLine.replacingOccurrences(of: "*", with: "")
            
            if !trimmedLine.isEmpty {
                cleanedLines.append(trimmedLine)
            }
        }
        
        result = cleanedLines.joined(separator: "\n")
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    
    // MARK: - Private Helpers
    
    private func countBulletOrNumberedLines(_ text: String) -> Int {
        let lines = text.components(separatedBy: .newlines)
        var count = 0
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("- ") || trimmed.hasPrefix("* ") || trimmed.hasPrefix("+ ") {
                count += 1
            } else if isNumberedLine(trimmed) {
                count += 1
            }
        }
        return count
    }
    
    private func isNumberedLine(_ line: String) -> Bool {
        guard let dotIndex = line.firstIndex(of: ".") else { return false }
        let prefix = line[..<dotIndex]
        guard !prefix.isEmpty, prefix.allSatisfy({ $0.isNumber }) else { return false }
        let remainder = line[line.index(after: dotIndex)...]
        return remainder.hasPrefix(" ")
    }
    
    private func extractFirstSentence(from text: String) -> (sentence: String, isTruncated: Bool) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return ("", false) }
        
        var terminatorIndex: String.Index? = nil
        var currentIndex = trimmed.startIndex
        
        while currentIndex < trimmed.endIndex {
            let ch = trimmed[currentIndex]
            let nextIndex = trimmed.index(after: currentIndex)
            
            if ch == "\n" {
                terminatorIndex = currentIndex
                break
            } else if ch == "." || ch == "!" || ch == "?" {
                var checkIndex = nextIndex
                while checkIndex < trimmed.endIndex && (trimmed[checkIndex] == "\"" || trimmed[checkIndex] == "'" || trimmed[checkIndex] == ")" || trimmed[checkIndex] == "”") {
                    checkIndex = trimmed.index(after: checkIndex)
                }
                if checkIndex == trimmed.endIndex || trimmed[checkIndex].isWhitespace {
                    terminatorIndex = checkIndex
                    break
                }
            }
            currentIndex = nextIndex
        }
        
        let sentence: String
        let isTruncatedBySentence: Bool
        
        if let termIndex = terminatorIndex {
            sentence = String(trimmed[..<termIndex]).trimmingCharacters(in: .whitespacesAndNewlines)
            let remainder = trimmed[termIndex...].trimmingCharacters(in: .whitespacesAndNewlines)
            isTruncatedBySentence = !remainder.isEmpty
        } else {
            sentence = trimmed
            isTruncatedBySentence = false
        }
        
        if sentence.count > 140 {
            let capped = String(sentence.prefix(140)).trimmingCharacters(in: .whitespacesAndNewlines)
            return (capped, true)
        } else {
            return (sentence, isTruncatedBySentence)
        }
    }
}
