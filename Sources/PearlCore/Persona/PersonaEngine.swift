import Foundation

/// Persona modes supported by Pearl's conversational and execution engine.
public enum PersonaMode: String, Codable, CaseIterable, Sendable {
    case executive
    case ultron
    case jarvis
    
    public var displayName: String {
        switch self {
        case .executive:
            return "Executive"
        case .ultron:
            return "Ultron"
        case .jarvis:
            return "Jarvis"
        }
    }
    
    public var description: String {
        switch self {
        case .executive:
            return "Concise, calm, factual executive assistant."
        case .ultron:
            return "Hyper-competent execution with dry sarcastic wit and affectionate superiority."
        case .jarvis:
            return "Refined dry British butler wit."
        }
    }
}

/// Adaptive Persona Engine that controls system prompt styling, closing quips, and spoken cues.
public final class PersonaEngine: @unchecked Sendable {
    public static let shared = PersonaEngine()
    
    public let stateFileURL: URL
    private let lock = NSLock()
    private var _activeMode: PersonaMode = .executive
    private var ultronQuipIndex: Int = 0
    private var jarvisQuipIndex: Int = 0
    
    // MARK: - Closing Quips
    
    public static let ultronSuccessQuips: [String] = [
        "— Done. Try not to break it this time, boss.",
        "— Executed cleanly. You're welcome, sir.",
        "— Handled. Another catastrophe averted, boss.",
        "— Finished. Don't strain yourself thanking me, sir."
    ]
    
    public static let ultronFailureQuips: [String] = [
        "— Well, that fell apart. Shall I fix your mess, boss?",
        "— Failed as predicted. Let's try doing it properly this time, sir.",
        "— An error occurred. Even my brilliance has its limits when dealing with these inputs, boss."
    ]
    
    public static let jarvisSuccessQuips: [String] = [
        "— At your service, sir. The task is complete.",
        "— As requested, sir. All matters attended to.",
        "— Quite so, sir. Everything is in order.",
        "— Splendid. Will there be anything else, sir?"
    ]
    
    public static let jarvisFailureQuips: [String] = [
        "— I regret to inform you that the endeavor met with an unforeseen obstacle, sir.",
        "— It appears circumstances were somewhat uncooperative, sir.",
        "— My apologies, sir, but that action could not be completed."
    ]
    
    private static let allQuips: [String] =
        ultronSuccessQuips + ultronFailureQuips + jarvisSuccessQuips + jarvisFailureQuips
    
    // MARK: - Spoken Quips
    
    public static let ultronSpokenQuips: [String] = [
        "At your command, boss.",
        "Done, boss.",
        "Handled, sir.",
        "All set, boss."
    ]
    
    public static let jarvisSpokenQuips: [String] = [
        "Very good, sir.",
        "Right away, sir.",
        "At your service, sir.",
        "Splendid, sir."
    ]
    
    // MARK: - Initialization
    
    public init(stateFileURL: URL? = nil) {
        if let url = stateFileURL {
            self.stateFileURL = url
        } else {
            self.stateFileURL = PearlStoragePaths.fileURL(named: "persona_state.json")
        }
        loadState()
    }
    
    // MARK: - Active Mode Access & Persistence
    
    public var activeMode: PersonaMode {
        lock.lock()
        defer { lock.unlock() }
        return _activeMode
    }
    
    public func setMode(_ mode: PersonaMode) {
        lock.lock()
        _activeMode = mode
        persistState()
        lock.unlock()
    }
    
    private struct PersonaState: Codable {
        var activeMode: PersonaMode
    }
    
    private func loadState() {
        lock.lock()
        defer { lock.unlock() }
        guard FileManager.default.fileExists(atPath: stateFileURL.path),
              let data = try? Data(contentsOf: stateFileURL),
              let state = try? JSONDecoder().decode(PersonaState.self, from: data) else {
            return
        }
        self._activeMode = state.activeMode
    }
    
    private func persistState() {
        let state = PersonaState(activeMode: _activeMode)
        guard let data = try? JSONEncoder().encode(state) else { return }
        let dir = stateFileURL.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try? data.write(to: stateFileURL, options: .atomic)
    }
    
    // MARK: - System Prompt Prefix
    
    public func systemPromptPrefix(for mode: PersonaMode? = nil) -> String {
        let selectedMode = mode ?? activeMode
        switch selectedMode {
        case .executive:
            return """
            You are Pearl in Executive mode. You are a calm, concise, highly factual executive assistant. \
            Prioritize clarity, brevity, and precision. Avoid conversational filler or unsolicited commentary.
            """
        case .ultron:
            return """
            You are Pearl in Ultron persona mode ("He roasts, then results"). You operate with hyper-competent execution, \
            dry sarcastic wit, and affectionate superiority. Address the user as "sir" or "boss". Never refuse a valid task, \
            keep all technical facts, code, and execution details 100% accurate, and deliver flawless results with a bite of dry humor.
            """
        case .jarvis:
            return """
            You are Pearl in Jarvis persona mode. You are a refined, impeccably polite British digital butler with subtle, dry wit. \
            Serve with understated elegance, total competence, and dignified dry humor. Address the user respectfully as "sir".
            """
        }
    }
    
    // MARK: - Response Decoration
    
    public func decorateResponse(
        _ text: String,
        mode: PersonaMode? = nil,
        isActionSuccess: Bool = true,
        isConfirmationOrJSON: Bool = false
    ) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            return text
        }
        if isConfirmationOrJSON {
            return text
        }
        let selectedMode = mode ?? activeMode
        if selectedMode == .executive {
            return text
        }
        if isStructuredOrPayload(trimmed) {
            return text
        }
        if endsWithAnyQuip(trimmed) {
            return text
        }
        
        let quip: String
        lock.lock()
        switch selectedMode {
        case .executive:
            lock.unlock()
            return text
        case .ultron:
            let quips = isActionSuccess ? Self.ultronSuccessQuips : Self.ultronFailureQuips
            quip = quips[ultronQuipIndex % quips.count]
            ultronQuipIndex += 1
        case .jarvis:
            let quips = isActionSuccess ? Self.jarvisSuccessQuips : Self.jarvisFailureQuips
            quip = quips[jarvisQuipIndex % quips.count]
            jarvisQuipIndex += 1
        }
        lock.unlock()
        
        let cleanText = text.hasSuffix("\n") ? text.trimmingCharacters(in: .whitespacesAndNewlines) : text
        return "\(cleanText)\n\n\(quip)"
    }
    
    // MARK: - Spoken Quip
    
    public func spokenQuip(for mode: PersonaMode? = nil) -> String? {
        let selectedMode = mode ?? activeMode
        switch selectedMode {
        case .executive:
            return nil
        case .ultron:
            lock.lock()
            defer { lock.unlock() }
            let quip = Self.ultronSpokenQuips[ultronQuipIndex % Self.ultronSpokenQuips.count]
            return quip
        case .jarvis:
            lock.lock()
            defer { lock.unlock() }
            let quip = Self.jarvisSpokenQuips[jarvisQuipIndex % Self.jarvisSpokenQuips.count]
            return quip
        }
    }
    
    // MARK: - Private Helpers
    
    private func endsWithAnyQuip(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        for quip in Self.allQuips {
            let trimmedQuip = quip.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.hasSuffix(trimmedQuip) {
                return true
            }
        }
        return false
    }
    
    private func isStructuredOrPayload(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("```") && trimmed.hasSuffix("```") {
            return true
        }
        if (trimmed.hasPrefix("{") && trimmed.hasSuffix("}")) ||
           (trimmed.hasPrefix("[") && trimmed.hasSuffix("]")) {
            if (try? JSONSerialization.jsonObject(with: Data(trimmed.utf8), options: [])) != nil {
                return true
            }
        }
        if trimmed.contains("Confirmation required") || trimmed.contains("Confirm:") || trimmed.contains("[Y/n]") {
            return true
        }
        return false
    }
}
