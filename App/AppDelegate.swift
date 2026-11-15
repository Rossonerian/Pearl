import AppKit
import SwiftUI
import Foundation
import Speech
import AVFoundation
import ServiceManagement
import PearlCore
import PearlTools
import PearlVoice
import PearlMemory

public final class AppDelegate: NSObject, NSApplicationDelegate {
    public static weak var shared: AppDelegate?
    
    private var hudPanel: HUDPanel!
    private var statusController: StatusItemController!
    private var socketServer: UnixSocketServer!
    private var memoryPressureSource: DispatchSourceMemoryPressure?
    private var settingsWindow: NSWindow?
    private var onboardingWindow: NSWindow?
    private let launchDate = Date()
    
    private struct PendingAutoLeave {
        let seconds: TimeInterval
        let dismissOnAppSwitch: Bool
    }
    private var pendingAutoLeave: PendingAutoLeave?
    
    // MARK: - Structured IPC JSON Payloads for `tools`
    
    private struct ToolSummaryPayload: Codable {
        let name: String
        let description: String
        let tier: Int
        let tierLabel: String
        let isReversible: Bool
        let requiresConfirmation: Bool
        let supportsUndo: Bool
        let requiredTCC: [String]
        let nativeAssistantExposed: Bool
        let cliExposed: Bool
        let mcpExposed: Bool
        let registeredInCatalog: Bool
        let registeredInRegistry: Bool
    }
    
    private struct ToolsListPayload: Codable {
        let catalogCount: Int
        let registryCount: Int
        let totalCount: Int
        let tools: [ToolSummaryPayload]
    }
    
    private struct ToolInspectPayload: Codable {
        let name: String
        let description: String
        let tier: Int
        let tierLabel: String
        let registeredInCatalog: Bool
        let registeredInRegistry: Bool
        let hasMetadata: Bool
        let isReversible: Bool
        let requiresConfirmation: Bool
        let supportsUndo: Bool
        let timeoutSeconds: Double
        let requiredTCC: [String]
        let nativeAssistantExposed: Bool
        let cliExposed: Bool
        let mcpExposed: Bool
        let arguments: [ToolArgumentDescriptor]
    }
    
    private struct ToolsDoctorPayload: Codable {
        let isHealthy: Bool
        let catalogCount: Int
        let registryCount: Int
        let missingFromToolRegistry: [String]
        let missingFromCatalog: [String]
        let metadataWithoutImplementation: [String]
        let tierMismatches: [String]
        let descriptorMismatches: [String]
        let mcpViolations: [String]
    }
    
    public func applicationDidFinishLaunching(_ notification: Notification) {
        AppDelegate.shared = self
        NSApplication.shared.setActivationPolicy(.accessory)
        
        let config = PearlConfig.load()
        
        // 1. Initialize pre-created floating HUD pill
        hudPanel = HUDPanel()
        hudPanel.onTextInputOpened = {
            LiveSpeechRecognizer.shared.stopListening()
            SpeechSynthesizerService.shared.stopPlayback()
            AudioPipelineService.shared.enterStandby()
        }
        hudPanel.hudView.onSubmitTextQuery = { [weak self] text in
            self?.submitHUDTextQuery(text)
        }
        
        // 2. Setup Menu Bar Status Item
        statusController = StatusItemController()
        statusController.onToggleHUD = { [weak self] in
            self?.toggleHUD()
        }
        statusController.onSettingsRequested = { [weak self] in
            self?.openSettings()
        }
        statusController.onOnboardingRequested = { [weak self] in
            self?.openOnboarding()
        }
        statusController.onQuitRequested = {
            NSApplication.shared.terminate(nil)
        }
        statusController.setup()
        
        // 3. Register Global Carbon Hotkey (Ctrl+Opt+Space)
        CarbonHotkeyManager.shared.onHotKeyTriggered = { [weak self] in
            DispatchQueue.main.async {
                self?.toggleHUD()
            }
        }
        CarbonHotkeyManager.shared.registerDefaultHotkey()
        
        // 4. Register Native Typed Tools, Revalidate Folder Bookmarks & Bind Memory Provider
        registerNativeTools()
        AssistantPipeline.shared.memoryProvider = PearlMemoryProvider.shared
        
        // 5. Sync Login Item preference safely when running from a bundled .app
        if config.launchAtLoginEnabled && Bundle.main.bundleURL.pathExtension == "app" {
            let result = AppDelegate.setLaunchAtLogin(true)
            if case .failure(let error) = result {
                NSLog("[Pearl] Login item registration notice: %@", error.localizedDescription)
            }
        }
        
        // 6. Setup Live Voice Pipeline & 60 Hz Metering
        let speech = LiveSpeechRecognizer.shared
        speech.onAudioLevelUpdated = { [weak self] level in
            self?.hudPanel.hudView.updateAudioLevel(CGFloat(level))
        }
        speech.onPartialTranscript = { [weak self] text in
            self?.hudPanel.hudView.setStatusText(text)
        }
        speech.onFinalTranscript = { [weak self] transcript in
            self?.handleVoiceUtterance(transcript)
        }
        speech.onError = { error in
            NSLog("[Pearl] Live speech recognizer notice: %@", error.localizedDescription)
        }
        
        SpeechSynthesizerService.shared.onPlaybackFinished = { [weak self] in
            DispatchQueue.main.async {
                guard let self = self else { return }
                if let pending = self.pendingAutoLeave {
                    self.pendingAutoLeave = nil
                    if pending.seconds > 0 {
                        self.hudPanel.scheduleAutoLeave(after: pending.seconds, dismissOnAppSwitch: pending.dismissOnAppSwitch)
                    }
                } else if !self.hudPanel.hudView.isConfirmationActive && !self.hudPanel.hudView.isTextInputExpanded {
                    self.hudPanel.scheduleAutoLeave(after: 4.0, dismissOnAppSwitch: true)
                }
            }
        }
        
        BargeInController.shared.onBargeInTriggered = { [weak self] in
            self?.hudPanel.showPill(text: "Listening...", thinking: false)
        }
        
        // Request speech & audio permissions asynchronously if needed
        SFSpeechRecognizer.requestAuthorization { status in
            NSLog("[Pearl] Speech recognition authorization status: %ld", status.rawValue)
        }
        AVCaptureDevice.requestAccess(for: .audio) { granted in
            NSLog("[Pearl] Audio capture granted: %d", granted)
        }
        
        // 7. Setup Unix Domain Socket Server for CLI
        socketServer = UnixSocketServer(socketPath: config.socketPath)
        socketServer.onCommandHandler = { [weak self] request in
            guard let self = self else {
                return IPCResponse(id: request.id, success: false, message: "Server shutting down")
            }
            return await self.handleIPCRequest(request)
        }
        
        do {
            try socketServer.start()
            NSLog("[Pearl] IPC socket server listening on %@", config.socketPath)
        } catch {
            NSLog("[Pearl] Failed to start IPC socket server: %@", error.localizedDescription)
        }
        
        // 8. Memory Pressure Warning Source
        let memSource = DispatchSource.makeMemoryPressureSource(eventMask: [.warning, .critical], queue: .main)
        memSource.setEventHandler { [weak self] in
            let mask = memSource.mask
            NSLog("[Pearl] Memory pressure event received: %@", String(describing: mask))
            if mask.contains(.warning) || mask.contains(.critical) {
                self?.handleMemoryPressure()
            }
        }
        memSource.resume()
        memoryPressureSource = memSource
        
        // 9. V3.3 Skill, Recipe, Persona & Global KillSwitch Wiring
        if let savedMode = PersonaMode(rawValue: config.activePersona.lowercased()) {
            PersonaEngine.shared.setMode(savedMode)
        }
        RecipeEngine.shared.ensureSeeded()
        Task {
            try? await SkillEngine.shared.seedDefaultSkillsIfEmpty()
        }
        _ = KillSwitch.shared.onTrigger { [weak self] _ in
            DispatchQueue.main.async {
                LiveSpeechRecognizer.shared.stopListening()
                SpeechSynthesizerService.shared.stopPlayback()
                AudioPipelineService.shared.enterStandby()
                self?.hudPanel?.showPill(text: "Aborted", thinking: false, tierBadge: "kill switch", isLocal: true)
                self?.hudPanel?.scheduleAutoLeave(after: 2.0, dismissOnAppSwitch: true)
            }
        }
        
        NSLog("[Pearl] v%@ initialized successfully. Resident memory footprint ready.", PearlConfig.currentVersion)
    }
    
    public func applicationWillTerminate(_ notification: Notification) {
        CarbonHotkeyManager.shared.unregisterHotkey()
        socketServer?.stop()
        memoryPressureSource?.cancel()
    }
    
    // MARK: - Login Item Management (SMAppService)
    
    public static func setLaunchAtLogin(_ enabled: Bool) -> Result<SMAppService.Status, Error> {
        let service = SMAppService.mainApp
        do {
            if enabled {
                if service.status != .enabled {
                    try service.register()
                }
            } else {
                if service.status == .enabled || service.status == .requiresApproval {
                    try service.unregister()
                }
            }
            return .success(service.status)
        } catch {
            NSLog("[Pearl] SMAppService launch-at-login update failed: %@", error.localizedDescription)
            return .failure(error)
        }
    }
    
    public static var currentLaunchAtLoginStatus: SMAppService.Status {
        return SMAppService.mainApp.status
    }
    
    // MARK: - Startup Tool & Bookmark Registration
    
    private func registerNativeTools() {
        PearlToolsRegistry.registerAll(into: ToolRegistry.shared, catalog: CentralToolCatalog.shared)
        CentralToolCatalog.shared.registerDefaultCoreTools()
        let folderEntries = FilesystemPermissionManager.shared.revalidateBookmarks()
        NSLog("[Pearl] Registered %d tool(s); revalidated %d approved folder bookmark(s).",
              CentralToolCatalog.shared.allTools().count,
              folderEntries.count)
    }
    
    private func toggleHUD() {
        if hudPanel.isPillVisible {
            LiveSpeechRecognizer.shared.stopListening()
            SpeechSynthesizerService.shared.stopPlayback()
            AudioPipelineService.shared.enterStandby()
            hudPanel.hidePill()
        } else {
            hudPanel.showPill(text: "Listening...", thinking: false)
            hudPanel.hudView.updateAudioLevel(0.05)
            do {
                try LiveSpeechRecognizer.shared.startListening()
            } catch {
                NSLog("[Pearl] Failed to start live speech: %@", error.localizedDescription)
                hudPanel.showPill(text: "Microphone unavailable", thinking: false)
            }
        }
    }
    
    // MARK: - Unified Voice & HUD Text Command Execution
    
    public func submitHUDTextQuery(_ text: String, confirmed: Bool = false) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        
        LiveSpeechRecognizer.shared.stopListening()
        SpeechSynthesizerService.shared.stopPlayback()
        AudioPipelineService.shared.enterStandby()
        
        executeUtteranceOnHUD(
            trimmed,
            origin: .cli,
            userConfirmed: confirmed,
            freshConfirmationArgs: nil
        )
    }
    
    private func handleVoiceUtterance(_ utterance: String) {
        let trimmed = utterance.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        
        executeUtteranceOnHUD(
            trimmed,
            origin: .voice,
            userConfirmed: false,
            freshConfirmationArgs: nil
        )
    }
    
    private func executeUtteranceOnHUD(
        _ utterance: String,
        origin: RequestOrigin,
        sessionID: String = "default",
        userConfirmed: Bool = false,
        freshConfirmationArgs: [String: String]? = nil
    ) {
        DispatchQueue.main.async { [weak self] in
            self?.hudPanel.showPill(text: "Thinking...", thinking: true)
        }
        
        Task { [weak self] in
            guard let self = self else { return }
            let request = AssistantRequest(
                utterance: utterance,
                origin: origin,
                sessionID: sessionID,
                userConfirmed: userConfirmed,
                freshConfirmationArgs: freshConfirmationArgs
            )
            let response = await AssistantPipeline.shared.process(request: request)
            
            await MainActor.run {
                self.presentResponseOnHUD(
                    utterance: utterance,
                    response: response,
                    origin: origin,
                    sessionID: sessionID,
                    wasConfirmedRetry: userConfirmed
                )
            }
        }
    }
    
    @MainActor
    private func presentResponseOnHUD(
        utterance: String,
        response: AssistantResponse,
        origin: RequestOrigin,
        sessionID: String = "default",
        wasConfirmedRetry: Bool = false
    ) {
        let historyLabel = wasConfirmedRetry ? "Confirmed: \(utterance)" : utterance
        hudPanel.recordTurn(
            userUtterance: historyLabel,
            assistantResponse: response.responseText,
            badgeLabel: response.badge.label,
            isLocal: response.badge.isLocal,
            latencyMs: response.latencyMs
        )
        
        let isConfirmation = response.requiresConfirmation ||
            response.responseText.localizedCaseInsensitiveContains("confirmation required") ||
            response.responseText.localizedCaseInsensitiveContains("user confirmation required")
        
        let decision = response.outputDecision ?? OutputDirector.shared.decide(
            responseText: response.responseText,
            speechText: response.speechText,
            origin: origin,
            requiresConfirmation: isConfirmation
        )
        
        if isConfirmation || decision.autoLeaveSeconds == 0 {
            let toolName = response.confirmationToolName ?? (response.badge.modelID.isEmpty ? "Action" : response.badge.modelID)
            let tierLabel = resolvedTierLabel(forToolNamed: toolName)
            let confirmationPrompt = formatConfirmationPrompt(response: response, toolName: toolName)
            let pendingArgs = response.confirmationArguments
            
            hudPanel.showConfirmation(
                toolName: toolName,
                prompt: confirmationPrompt,
                tier: tierLabel,
                onConfirm: { [weak self] in
                    self?.executeUtteranceOnHUD(
                        utterance,
                        origin: origin,
                        sessionID: sessionID,
                        userConfirmed: true,
                        freshConfirmationArgs: pendingArgs
                    )
                },
                onCancel: { [weak self] in
                    guard let self = self else { return }
                    self.hudPanel.showPill(text: "Action cancelled", thinking: false)
                    self.hudPanel.scheduleAutoLeave(after: 2.0, dismissOnAppSwitch: true)
                }
            )
            
            if (decision.mode == .speakFull || decision.mode == .speakSummaryAndHUD),
               let spoken = decision.spokenText, !spoken.isEmpty {
                pendingAutoLeave = PendingAutoLeave(
                    seconds: 0,
                    dismissOnAppSwitch: false
                )
                SpeechSynthesizerService.shared.speak(text: spoken)
            }
        } else {
            hudPanel.showPill(
                text: decision.hudText,
                thinking: false,
                tierBadge: response.badge.label,
                isLocal: response.badge.isLocal
            )
            
            let effectiveLeaveSeconds: TimeInterval = response.needsClarification
                ? max(decision.autoLeaveSeconds, 10.0)
                : decision.autoLeaveSeconds
            
            if (decision.mode == .speakFull || decision.mode == .speakSummaryAndHUD),
               let spoken = decision.spokenText, !spoken.isEmpty {
                pendingAutoLeave = PendingAutoLeave(
                    seconds: effectiveLeaveSeconds,
                    dismissOnAppSwitch: decision.dismissOnAppSwitch
                )
                SpeechSynthesizerService.shared.speak(text: spoken)
            } else {
                hudPanel.scheduleAutoLeave(
                    after: effectiveLeaveSeconds,
                    dismissOnAppSwitch: decision.dismissOnAppSwitch
                )
            }
        }
    }
    
    private func resolvedTierLabel(forToolNamed toolName: String) -> String {
        if let meta = CentralToolCatalog.shared.metadata(for: toolName) {
            return "T\(meta.tier.rawValue)"
        }
        if let tool = CentralToolCatalog.shared.tool(named: toolName) ?? ToolRegistry.shared.tool(named: toolName) {
            return "T\(tool.tier.rawValue)"
        }
        return "T2"
    }
    
    private func formatConfirmationPrompt(response: AssistantResponse, toolName: String) -> String {
        let args = response.confirmationArguments ?? [:]
        var targetSummary: String? = nil
        
        if let src = args["source"], let dst = args["destination"], !src.isEmpty, !dst.isEmpty {
            targetSummary = "\(src) → \(dst)"
        } else if let path = args["path"], !path.isEmpty {
            targetSummary = path
        } else if let filename = args["filename"], !filename.isEmpty {
            targetSummary = filename
        } else if let to = args["to"], !to.isEmpty {
            if let subject = args["subject"], !subject.isEmpty {
                targetSummary = "To: \(to) — \(subject)"
            } else {
                targetSummary = "To: \(to)"
            }
        } else if let url = args["url"], !url.isEmpty {
            targetSummary = url
        } else if let name = args["name"], !name.isEmpty {
            targetSummary = name
        } else if let title = args["title"], !title.isEmpty {
            targetSummary = title
        } else if let id = args["id"], !id.isEmpty {
            targetSummary = id
        }
        
        let rawReason = (response.confirmationReason ?? response.responseText)
            .replacingOccurrences(of: "Confirmation required: ", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        
        if let target = targetSummary {
            if rawReason.localizedCaseInsensitiveContains(target) {
                return rawReason
            }
            return rawReason.isEmpty ? target : "\(target) — \(rawReason)"
        }
        return rawReason.isEmpty ? "Confirm \(toolName)" : rawReason
    }
    
    private func handleMemoryPressure() {
        MLXProvider.shared.setMemoryPressure(active: true)
        hudPanel?.hidePill()
        AudioPipelineService.shared.enterStandby()
    }
    
    private func openSettings() {
        if settingsWindow == nil {
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 600, height: 520),
                styleMask: [.titled, .closable, .miniaturizable, .resizable],
                backing: .buffered,
                defer: false
            )
            window.center()
            window.title = "Pearl Settings"
            window.contentView = NSHostingView(rootView: SettingsView())
            window.isReleasedWhenClosed = false
            settingsWindow = window
        }
        settingsWindow?.makeKeyAndOrderFront(nil)
        NSApplication.shared.activate(ignoringOtherApps: true)
    }
    
    private func openOnboarding() {
        if onboardingWindow == nil {
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 580, height: 480),
                styleMask: [.titled, .closable],
                backing: .buffered,
                defer: false
            )
            window.center()
            window.title = "Welcome to Pearl"
            let view = OnboardingView(onFinish: { [weak self] in
                self?.onboardingWindow?.close()
            })
            window.contentView = NSHostingView(rootView: view)
            window.isReleasedWhenClosed = false
            onboardingWindow = window
        }
        onboardingWindow?.makeKeyAndOrderFront(nil)
        NSApplication.shared.activate(ignoringOtherApps: true)
    }
    
    // MARK: - Unix Socket IPC Handler
    
    private func handleIPCRequest(_ req: IPCRequest) async -> IPCResponse {
        var timebaseInfo = mach_timebase_info()
        mach_timebase_info(&timebaseInfo)
        let start = mach_continuous_time()
        
        let cmd = req.command.lowercased()
        var responseMessage = ""
        var responseData: [String: String] = [:]
        var isSuccess = true
        
        switch cmd {
        case "ping":
            responseMessage = "PONG"
            let uptime = Int(Date().timeIntervalSince(launchDate))
            responseData["uptime_seconds"] = "\(uptime)"
            responseData["pid"] = "\(getpid())"
            responseData["version"] = PearlConfig.currentVersion
            responseData["persona"] = PersonaEngine.shared.activeMode.rawValue
            
        case "status":
            let isVisible = await MainActor.run { hudPanel.isPillVisible }
            let frontmostApp = NSWorkspace.shared.frontmostApplication?.localizedName ?? "Unknown"
            responseMessage = "Pearl Daemon Status"
            responseData["hud_visible"] = "\(isVisible)"
            responseData["frontmost_app"] = frontmostApp
            responseData["pid"] = "\(getpid())"
            responseData["version"] = PearlConfig.currentVersion
            responseData["hotkey"] = "Ctrl+Opt+Space"
            
        case "show":
            let text = req.arguments?["text"] ?? "Pearl standing by"
            await MainActor.run {
                hudPanel.showPill(text: text, thinking: false)
            }
            responseMessage = "HUD panel shown"
            
        case "hide":
            await MainActor.run {
                hudPanel.hidePill()
            }
            responseMessage = "HUD panel hidden"
            
        case "ask", "execute":
            let query = req.arguments?["query"] ?? req.arguments?["utterance"] ?? ""
            let sessionID = req.arguments?["sessionID"] ?? req.arguments?["session_id"] ?? "default"
            let userConfirmed = (
                req.arguments?["userConfirmed"]?.lowercased() == "true" ||
                req.arguments?["confirm"]?.lowercased() == "true"
            )
            var freshArgs: [String: String]? = nil
            if let rawArgsJSON = req.arguments?["freshConfirmationArgsJSON"] ?? req.arguments?["confirmationArgumentsJSON"],
               let jsonData = rawArgsJSON.data(using: .utf8),
               let decoded = try? JSONDecoder().decode([String: String].self, from: jsonData) {
                freshArgs = decoded
            }
            
            let assistantReq = AssistantRequest(
                utterance: query,
                origin: .cli,
                sessionID: sessionID,
                userConfirmed: userConfirmed,
                freshConfirmationArgs: freshArgs
            )
            let assistantResp = await AssistantPipeline.shared.process(request: assistantReq)
            responseMessage = assistantResp.responseText
            isSuccess = assistantResp.success
            
            responseData["requiresConfirmation"] = assistantResp.requiresConfirmation ? "true" : "false"
            responseData["needsClarification"] = assistantResp.needsClarification ? "true" : "false"
            if let toolName = assistantResp.confirmationToolName, !toolName.isEmpty {
                responseData["confirmationToolName"] = toolName
            }
            if let reason = assistantResp.confirmationReason, !reason.isEmpty {
                responseData["confirmationReason"] = reason
            }
            if let confirmArgs = assistantResp.confirmationArguments,
               let encoded = try? JSONEncoder().encode(confirmArgs),
               let jsonStr = String(data: encoded, encoding: .utf8) {
                responseData["confirmationArgumentsJSON"] = jsonStr
            }
            
            await MainActor.run {
                self.presentResponseOnHUD(
                    utterance: query,
                    response: assistantResp,
                    origin: .cli,
                    sessionID: sessionID,
                    wasConfirmedRetry: userConfirmed
                )
            }
            
        case "tools":
            let result = handleToolsIPC(arguments: req.arguments)
            isSuccess = result.success
            responseMessage = result.message
            for (k, v) in result.data {
                responseData[k] = v
            }
            
        case "toggle_history":
            await MainActor.run {
                self.hudPanel.toggleHistory()
            }
            responseMessage = "Conversation history toggled"
            
        case "confirm_tool":
            let toolName = req.arguments?["tool"] ?? "TestTool"
            let promptText = req.arguments?["prompt"] ?? "Execute sensitive tool action?"
            let utterance = req.arguments?["utterance"] ?? req.arguments?["query"]
            let sessionID = req.arguments?["sessionID"] ?? req.arguments?["session_id"] ?? "default"
            var pendingArgs: [String: String]? = nil
            if let rawJSON = req.arguments?["arguments"] ?? req.arguments?["confirmationArgumentsJSON"],
               let jsonData = rawJSON.data(using: .utf8),
               let decoded = try? JSONDecoder().decode([String: String].self, from: jsonData) {
                pendingArgs = decoded
            }
            let tierLabel = resolvedTierLabel(forToolNamed: toolName)
            
            await MainActor.run {
                self.hudPanel.showConfirmation(
                    toolName: toolName,
                    prompt: promptText,
                    tier: tierLabel,
                    onConfirm: { [weak self] in
                        guard let self = self else { return }
                        if let utterance = utterance, !utterance.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                            self.executeUtteranceOnHUD(
                                utterance,
                                origin: .cli,
                                sessionID: sessionID,
                                userConfirmed: true,
                                freshConfirmationArgs: pendingArgs
                            )
                        } else if let tool = CentralToolCatalog.shared.tool(named: toolName) ?? ToolRegistry.shared.tool(named: toolName) {
                            let args = pendingArgs ?? [:]
                            self.hudPanel.showPill(text: "Executing \(toolName)...", thinking: true)
                            Task { [weak self] in
                                let ctx = ToolExecutionContext(
                                    trustState: .trusted,
                                    userConfirmed: true,
                                    providerIsLocal: true,
                                    freshConfirmationArgs: args
                                )
                                let resultMessage: String
                                do {
                                    let res = try await PolicyEngine.shared.execute(tool: tool, args: args, context: ctx)
                                    resultMessage = res.message
                                } catch {
                                    resultMessage = "Execution failed: \(error.localizedDescription)"
                                }
                                await MainActor.run {
                                    guard let self = self else { return }
                                    self.hudPanel.recordTurn(
                                        userUtterance: "Confirmed \(toolName)",
                                        assistantResponse: resultMessage,
                                        isLocal: true
                                    )
                                    self.hudPanel.showPill(text: resultMessage, thinking: false)
                                    self.hudPanel.scheduleAutoLeave(after: 4.0, dismissOnAppSwitch: true)
                                }
                            }
                        } else {
                            self.hudPanel.showPill(text: "Action confirmed", thinking: false)
                            self.hudPanel.scheduleAutoLeave(after: 2.5, dismissOnAppSwitch: true)
                        }
                    },
                    onCancel: { [weak self] in
                        self?.hudPanel.showPill(text: "Action cancelled", thinking: false)
                        self?.hudPanel.scheduleAutoLeave(after: 2.0, dismissOnAppSwitch: true)
                    }
                )
            }
            responseMessage = "Tool confirmation presented"
            
        case "quit":
            responseMessage = "Pearl daemon terminating"
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                NSApplication.shared.terminate(nil)
            }
            
        case "brief", "briefing":
            do {
                let briefing = try await BriefingEngine.shared.generateMorningBriefing()
                responseMessage = briefing
            } catch {
                responseMessage = "Failed to generate briefing: \(error.localizedDescription)"
                isSuccess = false
            }
            
        case "remember":
            let factText = req.arguments?["fact"] ?? ""
            if !factText.isEmpty {
                do {
                    let store = try MemoryStore()
                    let gate = try LearningGate(store: store)
                    let (factId, _) = try await gate.explicitRemember(fact: factText, source: "user", trust: .trusted)
                    responseMessage = "Remembered: '\(factText)' (id: \(factId))"
                    responseData["id"] = factId
                } catch {
                    responseMessage = "Failed to remember: \(error.localizedDescription)"
                    isSuccess = false
                }
            } else {
                responseMessage = "Missing 'fact' argument"
                isSuccess = false
            }
            
        case "forget":
            let factId = req.arguments?["id"] ?? ""
            if !factId.isEmpty {
                do {
                    let store = try MemoryStore()
                    let gate = try LearningGate(store: store)
                    let removed = try await gate.forget(factId: factId)
                    if removed {
                        responseMessage = "Forgot fact \(factId)"
                    } else {
                        responseMessage = "Fact \(factId) not found"
                        isSuccess = false
                    }
                } catch {
                    responseMessage = "Failed to forget: \(error.localizedDescription)"
                    isSuccess = false
                }
            } else {
                responseMessage = "Missing 'id' argument"
                isSuccess = false
            }
            
        case "memory":
            let sub = req.arguments?["subcommand"] ?? "stats"
            do {
                let store = try MemoryStore()
                let gate = try LearningGate(store: store)
                let viewer = MemoryViewer(store: store, gate: gate)
                if sub == "export" {
                    let json = try await viewer.exportJSON()
                    responseMessage = json
                } else {
                    let stats = try await viewer.getStats()
                    responseMessage = "Memory Stats: \(stats.factCount) facts, \(stats.profileByteCount) profile bytes (\(stats.profileEstimatedTokens) tokens), \(stats.pendingProposalsCount) pending proposals (Schema v\(stats.schemaVersion))"
                    responseData["fact_count"] = "\(stats.factCount)"
                    responseData["profile_bytes"] = "\(stats.profileByteCount)"
                    responseData["schema_version"] = "\(stats.schemaVersion)"
                }
            } catch {
                responseMessage = "Memory operation failed: \(error.localizedDescription)"
                isSuccess = false
            }
            
        case "jobs":
            let sub = req.arguments?["subcommand"] ?? "list"
            let jobId = req.arguments?["id"] ?? ""
            do {
                if sub == "resume", !jobId.isEmpty {
                    let job = try await PlanExecutor.shared.resumeJob(id: jobId)
                    responseMessage = "Resumed job \(String(job.id.prefix(8))): status = \(job.status.rawValue) (\(job.currentStepIndex)/\(job.steps.count) steps)"
                } else if sub == "rollback", !jobId.isEmpty {
                    let count = try await PlanExecutor.shared.rollbackJob(id: jobId)
                    responseMessage = "Rolled back job \(String(jobId.prefix(8))): reverted \(count) step(s)."
                } else {
                    let jobs = try await JobStore.shared.listJobs()
                    if jobs.isEmpty {
                        responseMessage = "No plan jobs recorded."
                    } else {
                        let lines = jobs.prefix(15).map { j in
                            "• [\(j.status.rawValue)] \(j.goal) (\(j.currentStepIndex)/\(j.steps.count)) [ID: \(String(j.id.prefix(8)))]"
                        }
                        responseMessage = "Plan Jobs (\(jobs.count)):\n" + lines.joined(separator: "\n")
                    }
                }
            } catch {
                responseMessage = "Jobs operation failed: \(error.localizedDescription)"
                isSuccess = false
            }
            
        case "approvals":
            let sub = req.arguments?["subcommand"] ?? "list"
            let itemId = req.arguments?["id"] ?? ""
            do {
                if sub == "approve", !itemId.isEmpty {
                    let res = try await ApprovalQueue.shared.approve(id: itemId)
                    responseMessage = "Approved & executed \(itemId): \(res.message)"
                    isSuccess = res.success
                } else if sub == "deny", !itemId.isEmpty {
                    let item = try await ApprovalQueue.shared.deny(id: itemId)
                    responseMessage = "Denied approval '\(item.toolName)' [\(item.id)]"
                } else {
                    let pending = await ApprovalQueue.shared.listPending()
                    if pending.isEmpty {
                        responseMessage = "No pending approvals."
                    } else {
                        let lines = pending.map { p in
                            "• [\(p.tier)] \(p.toolName) (\(p.reason)) [ID: \(p.id)]"
                        }
                        responseMessage = "Pending Approvals (\(pending.count)):\n" + lines.joined(separator: "\n")
                    }
                }
            } catch {
                responseMessage = "Approvals operation failed: \(error.localizedDescription)"
                isSuccess = false
            }
            
        case "review":
            let sub = req.arguments?["subcommand"] ?? "list"
            let propId = req.arguments?["id"] ?? ""
            do {
                switch sub {
                case "show":
                    if let p = ProposalStore.shared.getProposal(id: propId) {
                        responseMessage = "Proposal \(p.id) [\(p.status.rawValue)] — \(p.title) (\(p.targetKind.rawValue): \(p.targetName).md)\nExplanation: \(p.explanation)\n\n```diff\n\(p.unifiedDiff())\n```"
                    } else {
                        responseMessage = "Proposal '\(propId)' not found."
                        isSuccess = false
                    }
                case "approve":
                    let approved = try ProposalStore.shared.approveProposal(id: propId)
                    SkillEngine.shared.invalidateIndex()
                    responseMessage = "Approved proposal '\(approved.id)' -> wrote \(approved.targetKind.rawValue)/\(approved.targetName).md"
                case "reject":
                    let rejected = try ProposalStore.shared.rejectProposal(id: propId)
                    responseMessage = "Rejected proposal '\(rejected.id)' (\(rejected.targetName))."
                default:
                    let pending = ProposalStore.shared.listPending()
                    if pending.isEmpty {
                        responseMessage = "No pending skill/recipe proposals."
                    } else {
                        let lines = pending.map { "• [\($0.changeType.rawValue)] \($0.targetKind.rawValue)/\($0.targetName).md — \($0.title) [ID: \($0.id)]" }
                        responseMessage = "Pending Proposals (\(pending.count)):\n" + lines.joined(separator: "\n")
                    }
                }
            } catch {
                responseMessage = "Review operation failed: \(error.localizedDescription)"
                isSuccess = false
            }
            
        case "recipes":
            RecipeEngine.shared.ensureSeeded()
            let sub = req.arguments?["subcommand"] ?? "list"
            let name = req.arguments?["name"] ?? ""
            do {
                switch sub {
                case "show":
                    if let r = RecipeEngine.shared.readRecipe(name: name) {
                        let inputsText = r.inputs.isEmpty ? "none" : r.inputs.joined(separator: ", ")
                        responseMessage = "Recipe '\(r.name)' — \(r.description)\nTriggers: \(r.triggers.joined(separator: ", "))\nInputs: \(inputsText)\n\n\(r.body)"
                    } else {
                        responseMessage = "Recipe '\(name)' not found."
                        isSuccess = false
                    }
                case "run":
                    var argsMap: [String: String] = [:]
                    if let rawJSON = req.arguments?["arguments"], let data = rawJSON.data(using: .utf8),
                       let decoded = try? JSONDecoder().decode([String: String].self, from: data) {
                        argsMap = decoded
                    }
                    let rendered = try RecipeEngine.shared.renderRecipe(name: name, arguments: argsMap)
                    responseMessage = "Rendered recipe '\(name)':\n\n\(rendered)"
                case "delete":
                    try RecipeEngine.shared.deleteRecipe(name: name)
                    responseMessage = "Deleted recipe '\(name)'."
                default:
                    let all = RecipeEngine.shared.loadRecipes()
                    if all.isEmpty {
                        responseMessage = "No recipes installed."
                    } else {
                        let lines = all.map { "• \($0.name) — \($0.description) [inputs: \($0.inputs.isEmpty ? "none" : $0.inputs.joined(separator: ", "))]" }
                        responseMessage = "Recipes (\(all.count)):\n" + lines.joined(separator: "\n")
                    }
                }
            } catch {
                responseMessage = "Recipe operation failed: \(error.localizedDescription)"
                isSuccess = false
            }
            
        case "persona":
            let modeArg = (req.arguments?["mode"] ?? "show").lowercased()
            if modeArg == "show" || modeArg.isEmpty {
                let active = PersonaEngine.shared.activeMode
                responseMessage = "Active persona: \(active.displayName) (\(active.rawValue)) — \(active.description)"
                responseData["persona"] = active.rawValue
            } else if let mode = PersonaMode(rawValue: modeArg) {
                PersonaEngine.shared.setMode(mode)
                var cfg = PearlConfig.load()
                cfg.activePersona = mode.rawValue
                cfg.save()
                responseMessage = "Persona switched to \(mode.displayName) — \(mode.description)"
                responseData["persona"] = mode.rawValue
            } else {
                responseMessage = "Unknown persona '\(modeArg)'. Valid options: executive, ultron, jarvis"
                isSuccess = false
            }
            
        case "vault":
            let sub = req.arguments?["subcommand"] ?? "list"
            let name = req.arguments?["name"] ?? ""
            do {
                switch sub {
                case "read":
                    if let text = VaultManager.shared.readNote(name: name) {
                        responseMessage = text
                    } else {
                        responseMessage = "Vault note '\(name)' not found."
                        isSuccess = false
                    }
                case "write":
                    let content = req.arguments?["content"] ?? ""
                    try VaultManager.shared.writeNote(name: name, content: content)
                    responseMessage = "Wrote note '\(name)' to PearlVault."
                case "search":
                    let query = req.arguments?["query"] ?? name
                    let hits = VaultManager.shared.searchNotes(query: query)
                    if hits.isEmpty {
                        responseMessage = "No vault notes matched '\(query)'."
                    } else {
                        let lines = hits.prefix(15).map { "• \($0.file): \($0.snippet)" }
                        responseMessage = "Vault matches (\(hits.count)):\n" + lines.joined(separator: "\n")
                    }
                default:
                    let notes = VaultManager.shared.listNotes()
                    if notes.isEmpty {
                        responseMessage = "PearlVault is empty (\(PearlConfig.load().vaultPath))."
                    } else {
                        responseMessage = "PearlVault Notes (\(notes.count)):\n" + notes.map { "• \($0)" }.joined(separator: "\n")
                    }
                }
            } catch {
                responseMessage = "Vault operation failed: \(error.localizedDescription)"
                isSuccess = false
            }
            
        case "dream":
            do {
                let store = try? MemoryStore()
                let engine = DreamEngine(vaultManager: .shared, memoryStore: store)
                let dream = try await engine.synthesizeDream()
                responseMessage = "Dream Synthesis complete: \(dream.title)\nSaved to: \(dream.savedNotePath)\nThemes: \(dream.sharedThemes.joined(separator: ", "))\n\n\(dream.bridgeNarrative)"
            } catch {
                responseMessage = "Dream synthesis skipped: \(error.localizedDescription)"
                isSuccess = false
            }
            
        case "subbots":
            let botStr = (req.arguments?["bot_type"] ?? "search").lowercased()
            let target = req.arguments?["target"] ?? ""
            if let botType = SubBotType(rawValue: botStr), !target.isEmpty {
                let task = SubBotTask(
                    botType: botType,
                    targets: botType == .search ? [] : [target],
                    query: botType == .search ? target : nil
                )
                let results = await SubBotManager.shared.runBatch([task])
                if let first = results.first {
                    isSuccess = first.success
                    responseMessage = first.success ? first.markdownContent : (first.error ?? "SubBot failed.")
                } else {
                    isSuccess = false
                    responseMessage = "SubBot produced no output."
                }
            } else {
                isSuccess = false
                responseMessage = "Usage: subbots <search|scrape|crawl|map|monitor> <target>"
            }
            
        case "cache":
            let sub = req.arguments?["subcommand"] ?? "stats"
            if sub == "clear" {
                CacheManager.shared.clearAll()
                responseMessage = "All Pearl caches cleared."
            } else {
                responseMessage = CacheManager.shared.formattedSummary()
            }
            
        case "metrics":
            responseMessage = PerformanceMonitor.shared.formattedSummary()
            
        case "abort":
            KillSwitch.shared.trigger(reason: "Aborted via CLI IPC")
            responseMessage = "KillSwitch triggered: active agent execution halted."
            
        default:
            responseMessage = "Unhandled command: \(cmd)"
            isSuccess = false
        }
        
        let end = mach_continuous_time()
        let latencyMs = Double(end - start) * Double(timebaseInfo.numer) / Double(timebaseInfo.denom) / 1_000_000.0
        
        return IPCResponse(
            id: req.id,
            success: isSuccess,
            message: responseMessage,
            data: responseData,
            latencyMs: latencyMs
        )
    }
    
    // MARK: - Live Runtime `tools` IPC Subcommand Handler
    
    private func handleToolsIPC(arguments: [String: String]?) -> (success: Bool, message: String, data: [String: String]) {
        let sub = (arguments?["subcommand"] ?? "list").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        
        let catalog = CentralToolCatalog.shared
        let registry = ToolRegistry.shared
        
        switch sub.isEmpty ? "list" : sub {
        case "list":
            let catalogTools = Dictionary(uniqueKeysWithValues: catalog.allTools().map { ($0.name.lowercased(), $0) })
            let registryTools = Dictionary(uniqueKeysWithValues: registry.allTools().map { ($0.name.lowercased(), $0) })
            let allKeys = Set(catalogTools.keys).union(registryTools.keys).sorted()
            
            let summaries: [ToolSummaryPayload] = allKeys.compactMap { key in
                guard let tool = catalogTools[key] ?? registryTools[key] else { return nil }
                let meta = catalog.metadata(for: key)
                let tier = meta?.tier ?? tool.tier
                let tcc = (meta?.requiredTCC ?? tool.requiredTCC).map(\.rawValue)
                let reqConfirm = meta?.requiresConfirmation ?? (tier >= .t3WorkspaceChanges)
                let supportsUndo = meta?.supportsUndo ?? tool.isReversible
                return ToolSummaryPayload(
                    name: tool.name,
                    description: meta?.description ?? tool.description,
                    tier: tier.rawValue,
                    tierLabel: "T\(tier.rawValue)",
                    isReversible: meta?.isReversible ?? tool.isReversible,
                    requiresConfirmation: reqConfirm,
                    supportsUndo: supportsUndo,
                    requiredTCC: tcc,
                    nativeAssistantExposed: meta?.nativeAssistantExposed ?? true,
                    cliExposed: meta?.cliExposed ?? true,
                    mcpExposed: meta?.mcpExposed ?? (tier <= .t2ReadPersonal),
                    registeredInCatalog: catalogTools[key] != nil,
                    registeredInRegistry: registryTools[key] != nil
                )
            }
            
            let payload = ToolsListPayload(
                catalogCount: catalogTools.count,
                registryCount: registryTools.count,
                totalCount: summaries.count,
                tools: summaries
            )
            
            var data: [String: String] = ["count": "\(summaries.count)"]
            if let encoded = try? encoder.encode(payload), let json = String(data: encoded, encoding: .utf8) {
                data["json"] = json
            }
            
            let lines = summaries.map { item in
                let tccStr = item.requiredTCC.isEmpty ? "none" : item.requiredTCC.joined(separator: ",")
                let flags = [
                    item.requiresConfirmation ? "confirm" : "auto",
                    item.isReversible ? "undo" : "no-undo",
                    item.mcpExposed ? "mcp" : "local-only"
                ].joined(separator: ", ")
                return "• [\(item.tierLabel)] \(item.name) — \(item.description) (TCC: \(tccStr); \(flags))"
            }
            let message = "Live Runtime Tools (\(summaries.count) total; catalog: \(catalogTools.count), registry: \(registryTools.count)):\n" + lines.joined(separator: "\n")
            return (true, message, data)
            
        case "inspect":
            let rawName = (arguments?["name"] ?? arguments?["tool"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !rawName.isEmpty else {
                return (false, "Missing 'name' argument for 'tools inspect'.", [:])
            }
            let catalogTool = catalog.tool(named: rawName)
            let registryTool = registry.tool(named: rawName)
            let meta = catalog.metadata(for: rawName)
            
            guard let liveTool = catalogTool ?? registryTool else {
                if let meta = meta {
                    let payload = ToolInspectPayload(
                        name: meta.name,
                        description: meta.description,
                        tier: meta.tier.rawValue,
                        tierLabel: "T\(meta.tier.rawValue)",
                        registeredInCatalog: false,
                        registeredInRegistry: false,
                        hasMetadata: true,
                        isReversible: meta.isReversible,
                        requiresConfirmation: meta.requiresConfirmation,
                        supportsUndo: meta.supportsUndo,
                        timeoutSeconds: meta.timeoutSeconds,
                        requiredTCC: meta.requiredTCC.map(\.rawValue),
                        nativeAssistantExposed: meta.nativeAssistantExposed,
                        cliExposed: meta.cliExposed,
                        mcpExposed: meta.mcpExposed,
                        arguments: meta.arguments
                    )
                    var data: [String: String] = [:]
                    if let encoded = try? encoder.encode(payload), let json = String(data: encoded, encoding: .utf8) {
                        data["json"] = json
                    }
                    let msg = "Tool '\(meta.name)' [T\(meta.tier.rawValue)] has catalog metadata but is NOT registered in runtime ToolRegistry."
                    return (false, msg, data)
                }
                return (false, "Tool '\(rawName)' is not registered in runtime catalog or registry.", [:])
            }
            
            let tier = meta?.tier ?? liveTool.tier
            let tcc = (meta?.requiredTCC ?? liveTool.requiredTCC).map(\.rawValue)
            let args = (meta?.arguments.isEmpty == false ? meta?.arguments : nil) ?? liveTool.argumentDescriptors
            let payload = ToolInspectPayload(
                name: liveTool.name,
                description: meta?.description ?? liveTool.description,
                tier: tier.rawValue,
                tierLabel: "T\(tier.rawValue)",
                registeredInCatalog: catalogTool != nil,
                registeredInRegistry: registryTool != nil,
                hasMetadata: meta != nil,
                isReversible: meta?.isReversible ?? liveTool.isReversible,
                requiresConfirmation: meta?.requiresConfirmation ?? (tier >= .t3WorkspaceChanges),
                supportsUndo: meta?.supportsUndo ?? liveTool.isReversible,
                timeoutSeconds: meta?.timeoutSeconds ?? 15.0,
                requiredTCC: tcc,
                nativeAssistantExposed: meta?.nativeAssistantExposed ?? true,
                cliExposed: meta?.cliExposed ?? true,
                mcpExposed: meta?.mcpExposed ?? (tier <= .t2ReadPersonal),
                arguments: args
            )
            
            var data: [String: String] = ["name": payload.name]
            if let encoded = try? encoder.encode(payload), let json = String(data: encoded, encoding: .utf8) {
                data["json"] = json
            }
            
            var lines: [String] = [
                "Tool: \(payload.name) [\(payload.tierLabel)]",
                "Description: \(payload.description)",
                "Runtime Registration: catalog=\(payload.registeredInCatalog ? "yes" : "no"), registry=\(payload.registeredInRegistry ? "yes" : "no"), metadata=\(payload.hasMetadata ? "yes" : "no")",
                "Policy: requiresConfirmation=\(payload.requiresConfirmation), reversible=\(payload.isReversible), supportsUndo=\(payload.supportsUndo), timeout=\(String(format: "%.1fs", payload.timeoutSeconds))",
                "Required TCC: \(payload.requiredTCC.isEmpty ? "none" : payload.requiredTCC.joined(separator: ", "))",
                "Exposure: assistant=\(payload.nativeAssistantExposed), cli=\(payload.cliExposed), mcp=\(payload.mcpExposed)"
            ]
            if payload.arguments.isEmpty {
                lines.append("Arguments: none")
            } else {
                lines.append("Arguments:")
                for arg in payload.arguments {
                    let reqTag = arg.isRequired ? "required" : "optional"
                    let allowed = arg.allowedValues.map { " [allowed: \($0.joined(separator: "|"))]" } ?? ""
                    lines.append("  • \(arg.name) (\(arg.type), \(reqTag)) — \(arg.description)\(allowed)")
                }
            }
            return (true, lines.joined(separator: "\n"), data)
            
        case "doctor":
            let report = catalog.auditConsistency(against: registry)
            let payload = ToolsDoctorPayload(
                isHealthy: report.isHealthy,
                catalogCount: report.catalogCount,
                registryCount: report.registryCount,
                missingFromToolRegistry: report.missingFromToolRegistry,
                missingFromCatalog: report.missingFromCatalog,
                metadataWithoutImplementation: report.metadataWithoutImplementation,
                tierMismatches: report.tierMismatches,
                descriptorMismatches: report.descriptorMismatches,
                mcpViolations: report.mcpViolations
            )
            var data: [String: String] = [
                "healthy": report.isHealthy ? "true" : "false",
                "catalogCount": "\(report.catalogCount)",
                "registryCount": "\(report.registryCount)"
            ]
            if let encoded = try? encoder.encode(payload), let json = String(data: encoded, encoding: .utf8) {
                data["json"] = json
            }
            
            var lines: [String] = [
                "Live Tool Consistency Audit: \(report.isHealthy ? "HEALTHY" : "ISSUES DETECTED")",
                "Runtime Counts: catalog=\(report.catalogCount), ToolRegistry=\(report.registryCount)"
            ]
            if !report.missingFromToolRegistry.isEmpty {
                lines.append("• Missing from ToolRegistry: \(report.missingFromToolRegistry.joined(separator: ", "))")
            }
            if !report.missingFromCatalog.isEmpty {
                lines.append("• Missing from CentralToolCatalog: \(report.missingFromCatalog.joined(separator: ", "))")
            }
            if !report.metadataWithoutImplementation.isEmpty {
                lines.append("• Metadata without runtime implementation: \(report.metadataWithoutImplementation.joined(separator: ", "))")
            }
            if !report.tierMismatches.isEmpty {
                lines.append("• Tier mismatches: \(report.tierMismatches.joined(separator: "; "))")
            }
            if !report.descriptorMismatches.isEmpty {
                lines.append("• Descriptor mismatches: \(report.descriptorMismatches.joined(separator: "; "))")
            }
            if !report.mcpViolations.isEmpty {
                lines.append("• MCP boundary violations: \(report.mcpViolations.joined(separator: "; "))")
            }
            if report.isHealthy {
                lines.append("All runtime tool registrations, schemas, tiers, and MCP boundaries verified.")
            }
            return (report.isHealthy, lines.joined(separator: "\n"), data)
            
        default:
            return (false, "Unknown tools subcommand '\(sub)'. Valid options: list, inspect, doctor", [:])
        }
    }
}
