import AppKit
import Foundation
import PearlCore
import PearlTools

public final class AppDelegate: NSObject, NSApplicationDelegate {
    private var hudPanel: HUDPanel!
    private var statusController: StatusItemController!
    private var socketServer: UnixSocketServer!
    private var memoryPressureSource: DispatchSourceMemoryPressure?
    private let launchDate = Date()
    
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
        
        // 4. Register Native Typed Tools
        registerNativeTools()
        
        // 5. Setup Unix Domain Socket Server for CLI
        socketServer = UnixSocketServer(socketPath: config.socketPath)
        socketServer.onCommandHandler = { [weak self] request in
            return self?.handleIPCRequest(request) ?? IPCResponse(id: request.id, success: false, message: "Server shutting down")
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
        
        NSLog("[Pearl] Initialized successfully. Resident memory footprint ready.")
    }
    
    public func applicationWillTerminate(_ notification: Notification) {
        CarbonHotkeyManager.shared.unregisterHotkey()
        socketServer?.stop()
        memoryPressureSource?.cancel()
    }
    
    private func registerNativeTools() {
        let reg = ToolRegistry.shared
        reg.register(BatteryTool())
        reg.register(VolumeTool())
        reg.register(AppTool())
        reg.register(CloseAppTool())
        reg.register(ScreenshotTool())
        reg.register(TrashScreenshotsTool())
        reg.register(GitTool())
        reg.register(UndoTool())
        reg.register(ReminderTool())
    }
    
    private func toggleHUD() {
        if hudPanel.isPillVisible {
            hudPanel.hidePill()
        } else {
            hudPanel.showPill(text: "Pearl standing by", thinking: false)
        }
    }
    
    private func handleMemoryPressure() {
        hudPanel?.hidePill()
    }
    
    private func handleIPCRequest(_ req: IPCRequest) -> IPCResponse {
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
            responseData["version"] = "2.0.0"
            
        case "status":
            let isVisible = DispatchQueue.main.sync { hudPanel.isPillVisible }
            let frontmostApp = NSWorkspace.shared.frontmostApplication?.localizedName ?? "Unknown"
            responseMessage = "Pearl Daemon Status"
            responseData["hud_visible"] = "\(isVisible)"
            responseData["frontmost_app"] = frontmostApp
            responseData["pid"] = "\(getpid())"
            responseData["hotkey"] = "Ctrl+Opt+Space"
            
        case "show":
            DispatchQueue.main.sync {
                hudPanel.showPill(text: req.arguments?["text"] ?? "Pearl standing by", thinking: false)
            }
            responseMessage = "HUD panel shown"
            
        case "hide":
            DispatchQueue.main.sync {
                hudPanel.hidePill()
            }
            responseMessage = "HUD panel hidden"
            
        case "execute":
            let query = req.arguments?["query"] ?? ""
            if let intent = DeterministicRouter.shared.resolve(utterance: query) {
                if let tool = ToolRegistry.shared.tool(named: intent.toolName) {
                    let sema = DispatchSemaphore(value: 0)
                    var toolRes: ToolResult?
                    Task {
                        let ctx = ToolExecutionContext(trustState: .trusted, userConfirmed: false)
                        toolRes = try? await PolicyEngine.shared.execute(tool: tool, args: intent.arguments, context: ctx)
                        sema.signal()
                    }
                    sema.wait()
                    if let r = toolRes {
                        responseMessage = r.message
                        isSuccess = r.success
                        DispatchQueue.main.async {
                            self.hudPanel.showPill(text: r.message, thinking: false)
                        }
                    } else {
                        responseMessage = "Execution failed."
                        isSuccess = false
                    }
                } else {
                    responseMessage = "Tool '\(intent.toolName)' not registered."
                    isSuccess = false
                }
            } else {
                responseMessage = "Unmatched query (ready for local LLM tier): \(query)"
                isSuccess = true
            }
            
        case "quit":
            responseMessage = "Pearl daemon terminating"
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                NSApplication.shared.terminate(nil)
            }
            
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
