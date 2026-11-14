import AppKit

/// Floating HUD Panel managing window geometry, animations, and interactive surfaces.
///
/// Anchors directly below the physical notch / top screen edge (`screenMaxY - 6.0`).
/// Manages smooth 60 Hz geometric expansion when presenting interactive tool confirmation
/// banners or the conversation history panel.
public final class HUDPanel: NSPanel {
    public let hudView: HUDView
    
    // Geometry specifications
    private let standardWidth: CGFloat = 360.0
    private let standardHeight: CGFloat = 46.0
    private let confirmationWidth: CGFloat = 480.0
    private let confirmationHeight: CGFloat = 50.0
    private let expandedHistoryHeight: CGFloat = 280.0
    private let expandedHistoryWidth: CGFloat = 420.0
    
    public init() {
        let screenRect = NSScreen.main?.visibleFrame ?? NSScreen.main?.frame ?? NSRect(x: 0, y: 0, width: 1470, height: 956)
        let pillX = (screenRect.width - standardWidth) / 2.0
        let pillY = screenRect.maxY - standardHeight - 6.0
        
        let rect = NSRect(x: pillX, y: pillY, width: standardWidth, height: standardHeight)
        
        self.hudView = HUDView(frame: NSRect(x: 0, y: 0, width: standardWidth, height: standardHeight))
        
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
            self?.syncWindowFrameToState(animated: true)
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
        } else if hudView.isHistoryExpanded {
            targetWidth = expandedHistoryWidth
            targetHeight = expandedHistoryHeight
        }
        
        let targetX = (screenRect.width - targetWidth) / 2.0
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
            }
            hudView.frame = NSRect(x: 0, y: 0, width: targetWidth, height: targetHeight)
            hudView.layout()
        }
    }
    
    // MARK: - Presentation Controls
    
    public func showPill(text: String = "Pearl standing by", thinking: Bool = false, tierBadge: String? = nil, isLocal: Bool = true) {
        hudView.setStatusText(text)
        if let badge = tierBadge {
            hudView.setTierBadge(badge, isLocal: isLocal)
        }
        if thinking {
            hudView.startThinkingAnimation()
        }
        syncWindowFrameToState(animated: false)
        orderFront(nil)
        CATransaction.flush()
    }
    
    public func hidePill() {
        hudView.stopAnimation()
        hudView.setHistoryExpanded(false)
        hudView.dismissToolConfirmation()
        syncWindowFrameToState(animated: false)
        orderOut(nil)
        CATransaction.flush()
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
    }
    
    public func dismissConfirmation() {
        hudView.dismissToolConfirmation()
        syncWindowFrameToState(animated: true)
    }
    
    // MARK: - Conversation History
    
    public func toggleHistory() {
        hudView.toggleHistory()
        syncWindowFrameToState(animated: true)
    }
    
    public func setHistoryExpanded(_ expanded: Bool) {
        hudView.setHistoryExpanded(expanded)
        syncWindowFrameToState(animated: true)
    }
    
    public func recordTurn(
        userUtterance: String,
        assistantResponse: String,
        badgeLabel: String? = nil,
        isLocal: Bool = true,
        latencyMs: Double? = nil
    ) {
        let record = HUDTurnRecord(
            userText: userUtterance,
            assistantText: assistantResponse,
            badgeLabel: badgeLabel,
            isLocal: isLocal,
            latencyMs: latencyMs
        )
        hudView.addTurnRecord(record)
    }
    
    public var isPillVisible: Bool {
        return isVisible
    }
}
