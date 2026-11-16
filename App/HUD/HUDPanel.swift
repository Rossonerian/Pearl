import AppKit

/// Floating HUD Panel managing window geometry, animations, and interactive surfaces.
///
/// Anchors directly below the physical notch / top screen edge (`screenMaxY - 6.0`).
/// Manages smooth 60 Hz geometric expansion when presenting the compact text command bar,
/// interactive tool confirmation banners, or the conversation history panel.
public final class HUDPanel: NSPanel {
    public let hudView: HUDView
    
    // Geometry specifications (Precision Hardware Instrument V3.3)
    private let standardWidth: CGFloat = 400.0
    private let standardHeight: CGFloat = 48.0
    private let confirmationWidth: CGFloat = 460.0
    private let confirmationHeight: CGFloat = 56.0
    private let textInputWidth: CGFloat = 420.0
    private let textInputHeight: CGFloat = 40.0
    private let expandedHistoryHeight: CGFloat = 310.0
    private let expandedHistoryWidth: CGFloat = 420.0
    
    // Auto-leave lifecycle
    private var autoLeaveWorkItem: DispatchWorkItem?
    private var appSwitchObserver: NSObjectProtocol?
    private var lastAnnouncedText: String = ""
    
    public var onTextInputOpened: (() -> Void)?
    
    public override var canBecomeKey: Bool { true }
    public override var canBecomeMain: Bool { false }
    
    public init() {
        let screenRect = NSScreen.main?.visibleFrame ?? NSScreen.main?.frame ?? NSRect(x: 0, y: 0, width: 1470, height: 956)
        let pillX = screenRect.origin.x + (screenRect.width - standardWidth) / 2.0
        let pillY = screenRect.maxY - standardHeight - 6.0
        
        let rect = NSRect(x: pillX, y: pillY, width: standardWidth, height: standardHeight)
        
        self.hudView = HUDView(frame: NSRect(x: 0, y: 0, width: standardWidth, height: standardHeight))
        self.hudView.autoresizingMask = [.width, .height]
        
        super.init(
            contentRect: rect,
            styleMask: [.nonactivatingPanel, .fullSizeContentView, .borderless],
            backing: .buffered,
            defer: false
        )
        
        self.isOpaque = false
        self.backgroundColor = .clear
        self.level = .statusBar
        self.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
        self.hasShadow = true
        self.hidesOnDeactivate = false
        self.contentView = hudView
        
        setupCallbacks()
    }
    
    private func setupCallbacks() {
        hudView.onDismissRequested = { [weak self] in
            self?.hidePill()
        }
        
        hudView.onToggleHistoryRequested = { [weak self] in
            guard let self = self else { return }
            if self.hudView.isHistoryExpanded {
                self.cancelAutoLeave()
            }
            self.syncWindowFrameToState(animated: true)
        }
        
        hudView.onToggleTextInputRequested = { [weak self] in
            guard let self = self else { return }
            if self.hudView.isTextInputExpanded {
                self.cancelAutoLeave()
                self.onTextInputOpened?()
                self.syncWindowFrameToState(animated: true)
                self.makeKeyAndOrderFront(nil)
                NSApp.activate(ignoringOtherApps: true)
                self.makeFirstResponder(self.hudView.commandTextField)
                self.announceVoiceOver("Command input expanded")
            } else {
                self.syncWindowFrameToState(animated: true)
            }
        }
        
        hudView.onConfirmationResolved = { [weak self] in
            self?.syncWindowFrameToState(animated: true)
        }
    }
    
    // MARK: - Frame Synchronization
    
    public func syncWindowFrameToState(animated: Bool = true) {
        let screenRect = NSScreen.main?.visibleFrame ?? NSScreen.main?.frame ?? NSRect(x: 0, y: 0, width: 1470, height: 956)
        let topY = screenRect.maxY - 6.0
        
        var targetWidth: CGFloat = standardWidth
        var targetHeight: CGFloat = standardHeight
        
        if hudView.isConfirmationActive {
            targetWidth = confirmationWidth
            targetHeight = hudView.isHistoryExpanded ? (expandedHistoryHeight + 10.0) : confirmationHeight
        } else if hudView.isTextInputExpanded && hudView.isHistoryExpanded {
            targetWidth = textInputWidth
            targetHeight = expandedHistoryHeight + textInputHeight + 6.0
        } else if hudView.isTextInputExpanded {
            targetWidth = textInputWidth
            targetHeight = standardHeight + 6.0 + textInputHeight
        } else if hudView.isHistoryExpanded {
            targetWidth = expandedHistoryWidth
            targetHeight = expandedHistoryHeight
        }
        
        let targetX = screenRect.origin.x + (screenRect.width - targetWidth) / 2.0
        let targetY = topY - targetHeight
        let targetRect = NSRect(x: targetX, y: targetY, width: targetWidth, height: targetHeight)
        
        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        if !animated || reduceMotion {
            setFrame(targetRect, display: true, animate: false)
            hudView.frame = NSRect(x: 0, y: 0, width: targetWidth, height: targetHeight)
            hudView.layout()
        } else {
            NSAnimationContext.runAnimationGroup { context in
                // 60 Hz display refresh cadence interpolation (approx 180ms)
                context.duration = 0.18
                context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                self.animator().setFrame(targetRect, display: true)
                self.hudView.animator().frame = NSRect(x: 0, y: 0, width: targetWidth, height: targetHeight)
            } completionHandler: { [weak self] in
                self?.hudView.layout()
            }
        }
    }
    
    // MARK: - Presentation Controls
    
    public func showPill(text: String = "Pearl standing by", thinking: Bool = false, tierBadge: String? = nil, isLocal: Bool = true) {
        if hudView.isConfirmationActive {
            hudView.dismissToolConfirmation()
        }
        hudView.setStatusText(text)
        hudView.setTierBadge(tierBadge ?? "", isLocal: isLocal)
        if thinking {
            hudView.startThinkingAnimation()
        } else {
            hudView.stopAnimation()
        }
        syncWindowFrameToState(animated: false)
        orderFront(nil)
        CATransaction.flush()
        announceVoiceOver(text)
    }
    
    public func hidePill() {
        cancelAutoLeave()
        hudView.stopAnimation()
        hudView.setTextInputExpanded(false)
        hudView.setHistoryExpanded(false)
        hudView.dismissToolConfirmation()
        syncWindowFrameToState(animated: false)
        orderOut(nil)
        CATransaction.flush()
        lastAnnouncedText = ""
    }
    
    public func setTextInputExpanded(_ expanded: Bool) {
        hudView.setTextInputExpanded(expanded)
        if expanded {
            cancelAutoLeave()
            onTextInputOpened?()
        }
        syncWindowFrameToState(animated: true)
        if expanded {
            makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            makeFirstResponder(hudView.commandTextField)
            announceVoiceOver("Command input expanded")
        }
    }
    
    public func toggleTextInput() {
        setTextInputExpanded(!hudView.isTextInputExpanded)
    }
    
    // MARK: - Auto-Leave Lifecycle
    
    /// Schedules automatic departure / dismissal of the HUD capsule after specified duration and/or app switch.
    public func scheduleAutoLeave(after seconds: TimeInterval, dismissOnAppSwitch: Bool) {
        cancelAutoLeave()
        
        if dismissOnAppSwitch {
            appSwitchObserver = NSWorkspace.shared.notificationCenter.addObserver(
                forName: NSWorkspace.didActivateApplicationNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                guard let self = self else { return }
                if !self.hudView.isConfirmationActive && !self.hudView.isTextInputExpanded {
                    self.hidePill()
                }
            }
        }
        
        if seconds > 0 {
            let workItem = DispatchWorkItem { [weak self] in
                guard let self = self else { return }
                if !self.hudView.isConfirmationActive && !self.hudView.isHistoryExpanded && !self.hudView.isTextInputExpanded {
                    self.hidePill()
                }
            }
            self.autoLeaveWorkItem = workItem
            DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: workItem)
        }
    }
    
    /// Cancels any scheduled auto-leave work item and unregisters the application activation observer.
    public func cancelAutoLeave() {
        autoLeaveWorkItem?.cancel()
        autoLeaveWorkItem = nil
        
        if let observer = appSwitchObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
            appSwitchObserver = nil
        }
    }
    
    deinit {
        cancelAutoLeave()
    }
    
    // MARK: - Interactive Tool Confirmation
    
    /// Presents an interactive prompt inside the HUD capsule for tool proposals requiring confirmation.
    public func showConfirmation(
        toolName: String,
        prompt: String,
        tier: String = "T2",
        onConfirm: @escaping () -> Void,
        onCancel: @escaping () -> Void
    ) {
        cancelAutoLeave()
        hudView.presentToolConfirmation(
            toolName: toolName,
            prompt: prompt,
            tier: tier,
            onConfirm: onConfirm,
            onCancel: onCancel
        )
        syncWindowFrameToState(animated: true)
        orderFront(nil)
        makeKey()
        CATransaction.flush()
        announceVoiceOver("Confirmation required for \(toolName): \(prompt)")
    }
    
    public func dismissConfirmation() {
        hudView.dismissToolConfirmation()
        syncWindowFrameToState(animated: true)
    }
    
    // MARK: - Conversation History
    
    public func toggleHistory() {
        hudView.toggleHistory()
        if hudView.isHistoryExpanded {
            cancelAutoLeave()
        }
        syncWindowFrameToState(animated: true)
    }
    
    public func setHistoryExpanded(_ expanded: Bool) {
        hudView.setHistoryExpanded(expanded)
        if expanded {
            cancelAutoLeave()
        }
        syncWindowFrameToState(animated: true)
    }
    
    public func recordTurn(
        userUtterance: String,
        assistantResponse: String,
        badgeLabel: String? = nil,
        isLocal: Bool = true,
        latencyMs: Double? = nil
    ) {
        let lower = (badgeLabel ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let cleanedBadge: String? = (isLocal || lower.isEmpty || lower == "on device" || lower == "ready" || lower == "t1 local") ? nil : badgeLabel
        let record = HUDTurnRecord(
            userText: userUtterance,
            assistantText: assistantResponse,
            badgeLabel: cleanedBadge,
            isLocal: isLocal,
            latencyMs: latencyMs
        )
        hudView.addTurnRecord(record)
    }
    
    public var isPillVisible: Bool {
        return isVisible
    }
    
    // MARK: - VoiceOver Support
    
    private func announceVoiceOver(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != lastAnnouncedText else { return }
        lastAnnouncedText = trimmed
        NSAccessibility.post(
            element: hudView,
            notification: .announcementRequested,
            userInfo: [
                .announcement: trimmed,
                .priority: NSAccessibilityPriorityLevel.high.rawValue
            ]
        )
    }
}
