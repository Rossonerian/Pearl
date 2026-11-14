import AppKit

/// Flipped NSView container so history scroll content stacks cleanly from top to bottom.
public final class FlippedView: NSView {
    public override var isFlipped: Bool { true }
}

/// Model representing a single user/assistant conversation turn.
public struct HUDTurnRecord: Identifiable, Sendable {
    public let id: UUID
    public let timestamp: Date
    public let userText: String
    public let assistantText: String
    public let badgeLabel: String?
    public let isLocal: Bool
    public let latencyMs: Double?
    
    public init(
        id: UUID = UUID(),
        timestamp: Date = Date(),
        userText: String,
        assistantText: String,
        badgeLabel: String? = nil,
        isLocal: Bool = true,
        latencyMs: Double? = nil
    ) {
        self.id = id
        self.timestamp = timestamp
        self.userText = userText
        self.assistantText = assistantText
        self.badgeLabel = badgeLabel
        self.isLocal = isLocal
        self.latencyMs = latencyMs
    }
}

/// Floating HUD View for Pearl.
///
/// Implements:
/// 1. Top floating capsule with 60 Hz listening waveform meter and status transcription.
/// 2. Interactive tool confirmation banner: When a tool proposal requires confirmation,
///    presents an interactive prompt with `[Confirm (Enter)]` and `[Cancel (Esc)]` buttons.
/// 3. Expandable conversation history panel with SF Mono timestamps and execution tier badges.
/// 4. Strict adherence to `DESIGN.md` (no gradients, 60 Hz cadence, high contrast, reduced motion).
public final class HUDView: NSView {
    
    public override var isFlipped: Bool { true }
    
    // MARK: - Subviews: Top Capsule
    public let capsuleVisualEffect = NSVisualEffectView()
    public let listeningIndicator = ListeningIndicatorView(frame: NSRect(x: 16, y: 12, width: 52, height: 24))
    public let statusLabel = NSTextField(labelWithString: "Pearl standing by")
    public let badgeLabel = NSTextField(labelWithString: "")
    public let capsuleDivider = NSView()
    public let historyToggleButton = NSButton()
    
    // MARK: - Subviews: Interactive Tool Confirmation Banner
    public let confirmationContainer = NSView()
    public let confirmationIcon = NSImageView()
    public let confirmationPromptLabel = NSTextField(labelWithString: "")
    public let confirmationBadge = NSTextField(labelWithString: "T2 CONFIRM")
    public let confirmButton = NSButton()
    public let cancelButton = NSButton()
    
    // MARK: - Subviews: Expandable Conversation History Panel
    public let historyVisualEffect = NSVisualEffectView()
    public let historyHeaderLabel = NSTextField(labelWithString: "Recent Turns")
    public let historyCountBadge = NSTextField(labelWithString: "0 turns")
    public let historyCollapseButton = NSButton()
    public let historyScrollView = NSScrollView()
    public let historyDocumentView = FlippedView()
    
    // MARK: - State
    public private(set) var isHistoryExpanded: Bool = false
    public private(set) var isConfirmationActive: Bool = false
    public private(set) var turnRecords: [HUDTurnRecord] = []
    
    private var pendingConfirmAction: (() -> Void)?
    private var pendingCancelAction: (() -> Void)?
    
    // Callbacks
    public var onDismissRequested: (() -> Void)?
    public var onToggleHistoryRequested: (() -> Void)?
    public var onConfirmationResolved: (() -> Void)?
    
    // Date formatter for SF Mono timestamps
    private let timestampFormatter: DateFormatter = {
        let df = DateFormatter()
        df.dateFormat = "HH:mm:ss"
        return df
    }()
    
    public override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setupTopCapsule()
        setupConfirmationBanner()
        setupHistoryPanel()
        updateLayoutFrames()
    }
    
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
    
    // MARK: - Setup Top Capsule
    
    private func setupTopCapsule() {
        let isHighContrast = NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast
        capsuleVisualEffect.material = .hudWindow
        capsuleVisualEffect.blendingMode = .behindWindow
        capsuleVisualEffect.state = .active
        capsuleVisualEffect.wantsLayer = true
        capsuleVisualEffect.layer?.cornerRadius = 24.0
        capsuleVisualEffect.layer?.masksToBounds = true
        capsuleVisualEffect.layer?.borderWidth = 1.0
        capsuleVisualEffect.layer?.borderColor = NSColor.white.withAlphaComponent(isHighContrast ? 0.45 : 0.18).cgColor
        addSubview(capsuleVisualEffect)
        
        // Waveform indicator
        capsuleVisualEffect.addSubview(listeningIndicator)
        
        // Status text
        statusLabel.font = NSFont.systemFont(ofSize: 13.5, weight: .medium)
        statusLabel.textColor = isHighContrast ? .white : NSColor.white.withAlphaComponent(0.95)
        statusLabel.lineBreakMode = .byTruncatingTail
        statusLabel.drawsBackground = false
        statusLabel.isBezeled = false
        statusLabel.isEditable = false
        capsuleVisualEffect.addSubview(statusLabel)
        
        // Cloud escalation indicator (never shown for local turns)
        badgeLabel.font = NSFont.monospacedSystemFont(ofSize: 10, weight: .medium)
        badgeLabel.textColor = NSColor.systemTeal
        badgeLabel.drawsBackground = false
        badgeLabel.isBezeled = false
        badgeLabel.isEditable = false
        badgeLabel.alignment = .right
        badgeLabel.isHidden = true
        capsuleVisualEffect.addSubview(badgeLabel)
        
        // Subtle vertical divider before history toggle
        capsuleDivider.wantsLayer = true
        capsuleDivider.layer?.backgroundColor = NSColor.white.withAlphaComponent(isHighContrast ? 0.25 : 0.10).cgColor
        capsuleVisualEffect.addSubview(capsuleDivider)
        
        // History toggle button
        historyToggleButton.bezelStyle = .regularSquare
        historyToggleButton.isBordered = false
        historyToggleButton.image = NSImage(systemSymbolName: "chevron.down", accessibilityDescription: "Toggle History")
        historyToggleButton.contentTintColor = NSColor.white.withAlphaComponent(0.68)
        historyToggleButton.target = self
        historyToggleButton.action = #selector(handleHistoryToggleClicked)
        historyToggleButton.toolTip = "Toggle Conversation History (Tab)"
        capsuleVisualEffect.addSubview(historyToggleButton)
    }
    
    // MARK: - Setup Confirmation Banner
    
    private func setupConfirmationBanner() {
        confirmationContainer.wantsLayer = true
        confirmationContainer.isHidden = true
        capsuleVisualEffect.addSubview(confirmationContainer)
        
        // Warning Icon
        confirmationIcon.image = NSImage(systemSymbolName: "exclamationmark.triangle.fill", accessibilityDescription: "Confirmation Required")
        confirmationIcon.contentTintColor = NSColor.systemOrange
        confirmationContainer.addSubview(confirmationIcon)
        
        // Tier badge
        confirmationBadge.font = NSFont.monospacedSystemFont(ofSize: 10, weight: .semibold)
        confirmationBadge.textColor = NSColor.systemOrange
        confirmationBadge.drawsBackground = false
        confirmationBadge.isBezeled = false
        confirmationBadge.isEditable = false
        confirmationContainer.addSubview(confirmationBadge)
        
        // Prompt label
        confirmationPromptLabel.font = NSFont.systemFont(ofSize: 12, weight: .medium)
        confirmationPromptLabel.textColor = .white
        confirmationPromptLabel.lineBreakMode = .byTruncatingTail
        confirmationPromptLabel.drawsBackground = false
        confirmationPromptLabel.isBezeled = false
        confirmationPromptLabel.isEditable = false
        confirmationContainer.addSubview(confirmationPromptLabel)
        
        // Confirm Button
        confirmButton.title = "Confirm (Enter)"
        confirmButton.font = NSFont.systemFont(ofSize: 11, weight: .semibold)
        confirmButton.wantsLayer = true
        confirmButton.isBordered = false
        confirmButton.layer?.cornerRadius = 7.0
        confirmButton.layer?.backgroundColor = NSColor.systemGreen.withAlphaComponent(0.22).cgColor
        confirmButton.layer?.borderWidth = 1.0
        confirmButton.layer?.borderColor = NSColor.systemGreen.withAlphaComponent(0.65).cgColor
        confirmButton.contentTintColor = NSColor.systemGreen
        confirmButton.target = self
        confirmButton.action = #selector(handleConfirmClicked)
        confirmationContainer.addSubview(confirmButton)
        
        // Cancel Button
        cancelButton.title = "Cancel (Esc)"
        cancelButton.font = NSFont.systemFont(ofSize: 11, weight: .regular)
        cancelButton.wantsLayer = true
        cancelButton.isBordered = false
        cancelButton.layer?.cornerRadius = 7.0
        cancelButton.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.08).cgColor
        cancelButton.layer?.borderWidth = 1.0
        cancelButton.layer?.borderColor = NSColor.white.withAlphaComponent(0.18).cgColor
        cancelButton.contentTintColor = NSColor.white.withAlphaComponent(0.78)
        cancelButton.target = self
        cancelButton.action = #selector(handleCancelClicked)
        confirmationContainer.addSubview(cancelButton)
    }
    
    // MARK: - Setup History Panel
    
    private func setupHistoryPanel() {
        let isHighContrast = NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast
        historyVisualEffect.material = .sidebar
        historyVisualEffect.blendingMode = .behindWindow
        historyVisualEffect.state = .active
        historyVisualEffect.wantsLayer = true
        historyVisualEffect.layer?.cornerRadius = 14.0
        historyVisualEffect.layer?.masksToBounds = true
        historyVisualEffect.layer?.borderWidth = 1.0
        historyVisualEffect.layer?.borderColor = NSColor.white.withAlphaComponent(isHighContrast ? 0.35 : 0.14).cgColor
        historyVisualEffect.isHidden = true
        addSubview(historyVisualEffect)
        
        // Header
        historyHeaderLabel.font = NSFont.systemFont(ofSize: 12, weight: .semibold)
        historyHeaderLabel.textColor = NSColor.white.withAlphaComponent(0.85)
        historyHeaderLabel.drawsBackground = false
        historyHeaderLabel.isBezeled = false
        historyHeaderLabel.isEditable = false
        historyVisualEffect.addSubview(historyHeaderLabel)
        
        historyCountBadge.font = NSFont.monospacedSystemFont(ofSize: 10, weight: .regular)
        historyCountBadge.textColor = NSColor.white.withAlphaComponent(0.40)
        historyCountBadge.drawsBackground = false
        historyCountBadge.isBezeled = false
        historyCountBadge.isEditable = false
        historyVisualEffect.addSubview(historyCountBadge)
        
        historyCollapseButton.bezelStyle = .regularSquare
        historyCollapseButton.isBordered = false
        historyCollapseButton.image = NSImage(systemSymbolName: "chevron.up", accessibilityDescription: "Collapse History")
        historyCollapseButton.contentTintColor = NSColor.white.withAlphaComponent(0.50)
        historyCollapseButton.target = self
        historyCollapseButton.action = #selector(handleHistoryToggleClicked)
        historyVisualEffect.addSubview(historyCollapseButton)
        
        // Scroll view
        historyScrollView.drawsBackground = false
        historyScrollView.hasVerticalScroller = true
        historyScrollView.hasHorizontalScroller = false
        historyScrollView.autohidesScrollers = true
        historyScrollView.borderType = .noBorder
        historyScrollView.documentView = historyDocumentView
        historyVisualEffect.addSubview(historyScrollView)
    }
    
    // MARK: - Layout Updates
    
    public override func layout() {
        super.layout()
        updateLayoutFrames()
    }
    
    private func updateLayoutFrames() {
        let capsuleHeight: CGFloat = isConfirmationActive ? 56.0 : 48.0
        let currentWidth = bounds.width
        
        // 1. Top Capsule
        capsuleVisualEffect.frame = NSRect(x: 0, y: 0, width: currentWidth, height: capsuleHeight)
        capsuleVisualEffect.layer?.cornerRadius = capsuleHeight / 2.0
        
        if isConfirmationActive {
            // Confirmation layout
            listeningIndicator.isHidden = true
            statusLabel.isHidden = true
            badgeLabel.isHidden = true
            capsuleDivider.isHidden = true
            historyToggleButton.isHidden = true
            
            confirmationContainer.isHidden = false
            confirmationContainer.frame = NSRect(x: 12, y: 0, width: currentWidth - 24, height: capsuleHeight)
            
            confirmationIcon.frame = NSRect(x: 4, y: (capsuleHeight - 18) / 2.0, width: 20, height: 18)
            confirmationBadge.frame = NSRect(x: 28, y: (capsuleHeight - 16) / 2.0, width: 82, height: 16)
            
            let btnWidth: CGFloat = 96.0
            let btnSpacing: CGFloat = 8.0
            let buttonsTotalWidth = (btnWidth * 2.0) + btnSpacing
            let promptWidth = max(60, currentWidth - 24 - 114 - buttonsTotalWidth - 10)
            
            confirmationPromptLabel.frame = NSRect(x: 112, y: (capsuleHeight - 18) / 2.0, width: promptWidth, height: 18)
            
            let cancelX = currentWidth - 24 - (btnWidth * 2.0) - btnSpacing
            let confirmX = currentWidth - 24 - btnWidth
            
            cancelButton.frame = NSRect(x: cancelX, y: (capsuleHeight - 28) / 2.0, width: btnWidth, height: 28)
            confirmButton.frame = NSRect(x: confirmX, y: (capsuleHeight - 28) / 2.0, width: btnWidth, height: 28)
        } else {
            // Standard layout
            let showCloudBadge = !badgeLabel.stringValue.isEmpty
            listeningIndicator.isHidden = false
            statusLabel.isHidden = false
            badgeLabel.isHidden = !showCloudBadge
            capsuleDivider.isHidden = false
            historyToggleButton.isHidden = false
            confirmationContainer.isHidden = true
            
            listeningIndicator.frame = NSRect(x: 16, y: (capsuleHeight - 24) / 2.0, width: 42, height: 24)
            
            let rightAreaWidth: CGFloat = 44.0
            let badgeWidth: CGFloat = showCloudBadge ? 96.0 : 0.0
            let badgeGap: CGFloat = showCloudBadge ? 8.0 : 0.0
            let statusWidth = max(60, currentWidth - 68 - rightAreaWidth - badgeWidth - badgeGap - 8)
            
            statusLabel.frame = NSRect(x: 68, y: (capsuleHeight - 20) / 2.0, width: statusWidth, height: 20)
            badgeLabel.frame = NSRect(x: 68 + statusWidth + 6, y: (capsuleHeight - 16) / 2.0, width: badgeWidth, height: 16)
            capsuleDivider.frame = NSRect(x: currentWidth - 38, y: (capsuleHeight - 20) / 2.0, width: 1.0, height: 20.0)
            historyToggleButton.frame = NSRect(x: currentWidth - 30, y: (capsuleHeight - 20) / 2.0, width: 20, height: 20)
        }
        
        // 2. Expandable History Panel
        if isHistoryExpanded {
            historyVisualEffect.isHidden = false
            let historyY = capsuleHeight + 6.0
            let historyHeight = max(60, bounds.height - historyY)
            historyVisualEffect.frame = NSRect(x: 0, y: historyY, width: currentWidth, height: historyHeight)
            
            // NSVisualEffectView uses bottom-left origin (isFlipped == false), so anchor header at top
            let headerY = max(8.0, historyHeight - 28.0)
            historyHeaderLabel.frame = NSRect(x: 14, y: headerY, width: 120, height: 18)
            historyCountBadge.alignment = .right
            historyCountBadge.frame = NSRect(x: currentWidth - 124, y: headerY + 1, width: 86, height: 16)
            historyCollapseButton.frame = NSRect(x: currentWidth - 30, y: headerY, width: 18, height: 18)
            
            historyScrollView.frame = NSRect(x: 10, y: 10, width: currentWidth - 20, height: max(20, headerY - 16))
            renderHistoryCards()
        } else {
            historyVisualEffect.isHidden = true
        }
    }
    
    // MARK: - Public State Controls
    
    public func setStatusText(_ text: String) {
        statusLabel.stringValue = text
        statusLabel.toolTip = text
    }
    
    public func setTierBadge(_ badgeText: String, isLocal: Bool = true) {
        let lower = badgeText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let isLocalOrSuppressed = isLocal || lower.isEmpty || lower == "on device" || lower == "ready" || lower == "t1 local"
        if isLocalOrSuppressed {
            badgeLabel.stringValue = ""
            badgeLabel.isHidden = true
        } else {
            badgeLabel.stringValue = badgeText
            badgeLabel.textColor = NSColor.systemTeal
            badgeLabel.isHidden = false
        }
        updateLayoutFrames()
    }
    
    public func startThinkingAnimation() {
        listeningIndicator.startThinkingAnimation()
    }
    
    public func updateAudioLevel(_ level: CGFloat) {
        listeningIndicator.updateAudioLevel(level)
    }
    
    public func stopAnimation() {
        listeningIndicator.stopAnimation()
    }
    
    // MARK: - Interactive Tool Confirmation Banner
    
    /// Presents an interactive prompt inside the HUD capsule for tool proposals requiring confirmation.
    public func presentToolConfirmation(
        toolName: String,
        prompt: String,
        tier: String = "T2",
        onConfirm: @escaping () -> Void,
        onCancel: @escaping () -> Void
    ) {
        isConfirmationActive = true
        pendingConfirmAction = onConfirm
        pendingCancelAction = onCancel
        
        confirmationBadge.stringValue = "\(tier) CONFIRM"
        confirmationPromptLabel.stringValue = "\(toolName): \(prompt)"
        
        updateLayoutFrames()
    }
    
    public func dismissToolConfirmation() {
        isConfirmationActive = false
        pendingConfirmAction = nil
        pendingCancelAction = nil
        updateLayoutFrames()
    }
    
    @objc private func handleConfirmClicked() {
        let action = pendingConfirmAction
        dismissToolConfirmation()
        action?()
        onConfirmationResolved?()
    }
    
    @objc private func handleCancelClicked() {
        let action = pendingCancelAction
        dismissToolConfirmation()
        action?()
        onConfirmationResolved?()
    }
    
    // MARK: - Conversation History Management
    
    public func setHistoryExpanded(_ expanded: Bool) {
        isHistoryExpanded = expanded
        historyToggleButton.image = NSImage(
            systemSymbolName: expanded ? "chevron.up" : "chevron.down",
            accessibilityDescription: expanded ? "Collapse History" : "Expand History"
        )
        updateLayoutFrames()
    }
    
    public func toggleHistory() {
        setHistoryExpanded(!isHistoryExpanded)
        onToggleHistoryRequested?()
    }
    
    @objc private func handleHistoryToggleClicked() {
        toggleHistory()
    }
    
    public func addTurnRecord(_ record: HUDTurnRecord) {
        turnRecords.append(record)
        // Maintain last 25 turns to bound memory
        if turnRecords.count > 25 {
            turnRecords.removeFirst(turnRecords.count - 25)
        }
        historyCountBadge.stringValue = "\(turnRecords.count) turn\(turnRecords.count == 1 ? "" : "s")"
        if isHistoryExpanded {
            renderHistoryCards()
        }
    }
    
    private func renderHistoryCards() {
        historyDocumentView.subviews.forEach { $0.removeFromSuperview() }
        
        let contentWidth = max(historyScrollView.contentView.bounds.width, bounds.width - 20)
        var currentY: CGFloat = 4.0
        let cardSpacing: CGFloat = 8.0
        
        if turnRecords.isEmpty {
            let emptyLabel = NSTextField(labelWithString: "No recent conversation turns")
            emptyLabel.font = NSFont.systemFont(ofSize: 12, weight: .regular)
            emptyLabel.textColor = NSColor.white.withAlphaComponent(0.42)
            emptyLabel.alignment = .center
            emptyLabel.frame = NSRect(x: 0, y: 48, width: contentWidth, height: 20)
            historyDocumentView.addSubview(emptyLabel)
            historyDocumentView.frame = NSRect(x: 0, y: 0, width: contentWidth, height: 120)
            return
        }
        
        for record in turnRecords.reversed() {
            let cardView = FlippedView()
            cardView.wantsLayer = true
            cardView.layer?.cornerRadius = 10.0
            cardView.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.05).cgColor
            cardView.layer?.borderWidth = 1.0
            cardView.layer?.borderColor = NSColor.white.withAlphaComponent(0.09).cgColor
            
            // Top metadata row: Timestamp left, optional Cloud tag + tabular Latency right
            let timeStr = timestampFormatter.string(from: record.timestamp)
            let timeLabel = NSTextField(labelWithString: timeStr)
            timeLabel.font = NSFont.monospacedSystemFont(ofSize: 10, weight: .regular)
            timeLabel.textColor = NSColor.white.withAlphaComponent(0.42)
            timeLabel.frame = NSRect(x: 10, y: 7, width: 64, height: 14)
            cardView.addSubview(timeLabel)
            
            if !record.isLocal, let badgeText = record.badgeLabel, !badgeText.isEmpty {
                let badgeView = NSTextField(labelWithString: badgeText)
                badgeView.font = NSFont.monospacedSystemFont(ofSize: 9.5, weight: .medium)
                badgeView.textColor = NSColor.systemTeal
                badgeView.frame = NSRect(x: 78, y: 7, width: 160, height: 14)
                cardView.addSubview(badgeView)
            }
            
            if let lat = record.latencyMs {
                let latLabel = NSTextField(labelWithString: String(format: "%.0f ms", lat))
                latLabel.font = NSFont.monospacedSystemFont(ofSize: 10, weight: .regular)
                latLabel.textColor = NSColor.white.withAlphaComponent(0.40)
                latLabel.alignment = .right
                latLabel.frame = NSRect(x: contentWidth - 82, y: 7, width: 72, height: 14)
                cardView.addSubview(latLabel)
            }
            
            // User prompt row
            let userLabel = NSTextField(labelWithString: "› \(record.userText)")
            userLabel.font = NSFont.systemFont(ofSize: 11.5, weight: .regular)
            userLabel.textColor = NSColor.white.withAlphaComponent(0.58)
            userLabel.lineBreakMode = .byTruncatingTail
            userLabel.frame = NSRect(x: 10, y: 24, width: contentWidth - 20, height: 16)
            cardView.addSubview(userLabel)
            
            // Assistant response (up to 2 lines)
            let assistantLabel = NSTextField(wrappingLabelWithString: record.assistantText)
            assistantLabel.font = NSFont.systemFont(ofSize: 12.5, weight: .medium)
            assistantLabel.textColor = NSColor.white.withAlphaComponent(0.94)
            assistantLabel.maximumNumberOfLines = 2
            assistantLabel.lineBreakMode = .byTruncatingTail
            assistantLabel.cell?.truncatesLastVisibleLine = true
            assistantLabel.frame = NSRect(x: 10, y: 42, width: contentWidth - 20, height: 30)
            cardView.addSubview(assistantLabel)
            
            let cardHeight: CGFloat = 76.0
            cardView.frame = NSRect(x: 0, y: currentY, width: contentWidth, height: cardHeight)
            historyDocumentView.addSubview(cardView)
            
            currentY += cardHeight + cardSpacing
        }
        
        historyDocumentView.frame = NSRect(x: 0, y: 0, width: contentWidth, height: currentY)
    }
    
    // MARK: - Keyboard Event Handling
    
    public override func keyDown(with event: NSEvent) {
        if isConfirmationActive {
            if event.keyCode == 36 || event.keyCode == 76 { // Return / Enter
                handleConfirmClicked()
                return
            } else if event.keyCode == 53 { // ESC
                handleCancelClicked()
                return
            }
        }
        
        switch event.keyCode {
        case 53: // ESC key
            if isHistoryExpanded {
                toggleHistory()
            } else {
                onDismissRequested?()
            }
        case 48, 125: // Tab or Down Arrow
            toggleHistory()
        default:
            super.keyDown(with: event)
        }
    }
}
