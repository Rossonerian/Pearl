import AppKit
import SwiftUI
import Foundation
import Speech
import AVFoundation
import PearlCore
import PearlTools
import PearlVoice
import PearlMemory

public final class AppDelegate: NSObject, NSApplicationDelegate {
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
    
    public func applicationDidFinishLaunching(_ notification: Notification) {
        NSApplication.shared.setActivationPolicy(.accessory)
        
        let config = PearlConfig.load()
        
        // 1. Initialize pre-created floating HUD pill
        hudPanel = HUDPanel()
        
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
        
        // 4. Register Native Typed Tools & Memory Provider
        registerNativeTools()
        AssistantPipeline.shared.memoryProvider = PearlMemoryProvider.shared
        
        // 5. Setup Live Voice Pipeline & 60 Hz Metering
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
                } else {
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
        
        // 6. Setup Unix Domain Socket Server for CLI
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
        
        // 6. Memory Pressure Warning Source
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
        
        // 7. V3.1 Skill Engine & Global KillSwitch Wiring
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
        
        NSLog("[Pearl] Initialized successfully. Resident memory footprint ready.")
    }
    
    public func applicationWillTerminate(_ notification: Notification) {
        CarbonHotkeyManager.shared.unregisterHotkey()
        socketServer?.stop()
        memoryPressureSource?.cancel()
    }
    
    private func registerNativeTools() {
        PearlToolsRegistry.registerAll(into: ToolRegistry.shared, catalog: CentralToolCatalog.shared)
        let reg = ToolRegistry.shared
        reg.register(ListTasksTool())
        reg.register(CreateTaskTool())
        reg.register(CompleteTaskTool())
        reg.register(DeleteTaskTool())
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
    
    private func handleVoiceUtterance(_ utterance: String) {
        guard !utterance.isEmpty else { return }
        
        hudPanel.showPill(text: "Thinking...", thinking: true)
        
        Task { [weak self] in
            guard let self = self else { return }
            let request = AssistantRequest(utterance: utterance, origin: .voice)
            let response = await AssistantPipeline.shared.process(request: request)
            
            await MainActor.run {
                self.hudPanel.recordTurn(
                    userUtterance: utterance,
                    assistantResponse: response.responseText,
                    badgeLabel: response.badge.label,
                    isLocal: response.badge.isLocal,
                    latencyMs: response.latencyMs
                )
                
                let isConfirmation = response.responseText.localizedCaseInsensitiveContains("confirmation required") ||
                                     response.responseText.localizedCaseInsensitiveContains("user confirmation required")
                
                let decision = response.outputDecision ?? OutputDirector.shared.decide(
                    responseText: response.responseText,
                    speechText: response.speechText,
                    origin: .voice,
                    requiresConfirmation: isConfirmation
                )
                
                if isConfirmation || decision.autoLeaveSeconds == 0 {
                    let toolName = response.badge.modelID.isEmpty ? "Action" : response.badge.modelID
                    self.hudPanel.showConfirmation(
                        toolName: toolName,
                        prompt: response.responseText,
                        tier: "T2",
                        onConfirm: { [weak self] in
                            Task { [weak self] in
                                let confirmedReq = AssistantRequest(
                                    utterance: utterance,
                                    origin: .voice,
                                    userConfirmed: true
                                )
                                let confirmedResp = await AssistantPipeline.shared.process(request: confirmedReq)
                                await MainActor.run {
                                    guard let self = self else { return }
                                    self.hudPanel.recordTurn(
                                        userUtterance: "Confirmed: \(utterance)",
                                        assistantResponse: confirmedResp.responseText,
                                        badgeLabel: confirmedResp.badge.label,
                                        isLocal: confirmedResp.badge.isLocal,
                                        latencyMs: confirmedResp.latencyMs
                                    )
                                    let confirmedDecision = confirmedResp.outputDecision ?? OutputDirector.shared.decide(
                                        responseText: confirmedResp.responseText,
                                        speechText: confirmedResp.speechText,
                                        origin: .voice
                                    )
                                    self.hudPanel.showPill(
                                        text: confirmedDecision.hudText,
                                        thinking: false,
                                        tierBadge: confirmedResp.badge.label,
                                        isLocal: confirmedResp.badge.isLocal
                                    )
                                    if (confirmedDecision.mode == .speakFull || confirmedDecision.mode == .speakSummaryAndHUD),
                                       let spoken = confirmedDecision.spokenText, !spoken.isEmpty {
                                        self.pendingAutoLeave = PendingAutoLeave(
                                            seconds: confirmedDecision.autoLeaveSeconds,
                                            dismissOnAppSwitch: confirmedDecision.dismissOnAppSwitch
                                        )
                                        SpeechSynthesizerService.shared.speak(text: spoken)
                                    } else {
                                        self.hudPanel.scheduleAutoLeave(
                                            after: confirmedDecision.autoLeaveSeconds,
                                            dismissOnAppSwitch: confirmedDecision.dismissOnAppSwitch
                                        )
                                    }
                                }
                            }
                        },
                        onCancel: { [weak self] in
                            guard let self = self else { return }
                            self.hudPanel.showPill(text: "Action cancelled", thinking: false)
                            self.hudPanel.scheduleAutoLeave(after: 2.0, dismissOnAppSwitch: true)
                        }
                    )
                    
                    if (decision.mode == .speakFull || decision.mode == .speakSummaryAndHUD),
                       let spoken = decision.spokenText, !spoken.isEmpty {
                        self.pendingAutoLeave = PendingAutoLeave(
                            seconds: decision.autoLeaveSeconds,
                            dismissOnAppSwitch: decision.dismissOnAppSwitch
                        )
                        SpeechSynthesizerService.shared.speak(text: spoken)
                    }
                } else {
                    self.hudPanel.showPill(
                        text: decision.hudText,
                        thinking: false,
                        tierBadge: response.badge.label,
                        isLocal: response.badge.isLocal
                    )
                    
                    if (decision.mode == .speakFull || decision.mode == .speakSummaryAndHUD),
                       let spoken = decision.spokenText, !spoken.isEmpty {
                        self.pendingAutoLeave = PendingAutoLeave(
                            seconds: decision.autoLeaveSeconds,
                            dismissOnAppSwitch: decision.dismissOnAppSwitch
                        )
                        SpeechSynthesizerService.shared.speak(text: spoken)
                    } else {
                        self.hudPanel.scheduleAutoLeave(
                            after: decision.autoLeaveSeconds,
                            dismissOnAppSwitch: decision.dismissOnAppSwitch
                        )
                    }
                }
            }
        }
    }
    
    private func handleMemoryPressure() {
        MLXProvider.shared.setMemoryPressure(active: true)
        hudPanel?.hidePill()
        AudioPipelineService.shared.enterStandby()
    }
    
    private func openSettings() {
        if settingsWindow == nil {
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 600, height: 480),
                styleMask: [.titled, .closable, .miniaturizable],
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
            responseData["version"] = "3.1.0"
            
        case "status":
            let isVisible = await MainActor.run { hudPanel.isPillVisible }
            let frontmostApp = NSWorkspace.shared.frontmostApplication?.localizedName ?? "Unknown"
            responseMessage = "Pearl Daemon Status"
            responseData["hud_visible"] = "\(isVisible)"
            responseData["frontmost_app"] = frontmostApp
            responseData["pid"] = "\(getpid())"
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
            
        case "execute":
            let query = req.arguments?["query"] ?? ""
            let assistantReq = AssistantRequest(utterance: query, origin: .socket)
            let assistantResp = await AssistantPipeline.shared.process(request: assistantReq)
            responseMessage = assistantResp.responseText
            isSuccess = assistantResp.success
            await MainActor.run {
                self.hudPanel.recordTurn(
                    userUtterance: query,
                    assistantResponse: assistantResp.responseText,
                    badgeLabel: assistantResp.badge.label,
                    isLocal: assistantResp.badge.isLocal,
                    latencyMs: assistantResp.latencyMs
                )
                self.hudPanel.showPill(
                    text: assistantResp.responseText,
                    thinking: false,
                    tierBadge: assistantResp.badge.label,
                    isLocal: assistantResp.badge.isLocal
                )
                if let decision = assistantResp.outputDecision {
                    self.hudPanel.scheduleAutoLeave(
                        after: decision.autoLeaveSeconds,
                        dismissOnAppSwitch: decision.dismissOnAppSwitch
                    )
                }
            }
            
        case "toggle_history":
            await MainActor.run {
                self.hudPanel.toggleHistory()
            }
            responseMessage = "Conversation history toggled"
            
        case "confirm_tool":
            let toolName = req.arguments?["tool"] ?? "TestTool"
            let promptText = req.arguments?["prompt"] ?? "Execute sensitive tool action?"
            await MainActor.run {
                self.hudPanel.showConfirmation(
                    toolName: toolName,
                    prompt: promptText,
                    tier: "T2",
                    onConfirm: { [weak self] in
                        self?.hudPanel.showPill(text: "Action confirmed", thinking: false)
                    },
                    onCancel: { [weak self] in
                        self?.hudPanel.showPill(text: "Action cancelled", thinking: false)
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
}
