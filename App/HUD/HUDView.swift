import AppKit

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
    public let listeningIndicator = ListeningIndicatorView(frame: NSRect(x: 16, y: 11, width: 56, height: 24))
    public let statusLabel = NSTextField(labelWithString: "Pearl standing by")
    public let badgeLabel = NSTextField(labelWithString: "")
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
    public let historyDocumentView = NSView()
    
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
        capsuleVisualEffect.material = .hudWindow
        capsuleVisualEffect.blendingMode = .behindWindow
        capsuleVisualEffect.state = .active
        capsuleVisualEffect.wantsLayer = true
        capsuleVisualEffect.layer?.cornerRadius = 23.0
        capsuleVisualEffect.layer?.masksToBounds = true
        capsuleVisualEffect.layer?.borderWidth = 1.0
        capsuleVisualEffect.layer?.borderColor = NSColor.white.withAlphaComponent(0.18).cgColor
        addSubview(capsuleVisualEffect)
        
        // Waveform indicator
        capsuleVisualEffect.addSubview(listeningIndicator)
        
        // Status text
        statusLabel.font = NSFont.systemFont(ofSize: 13, weight: .medium)
        statusLabel.textColor = .white
        statusLabel.lineBreakMode = .byTruncatingTail
        statusLabel.drawsBackground = false
        statusLabel.isBezeled = false
        statusLabel.isEditable = false
        capsuleVisualEffect.addSubview(statusLabel)
        
        // Tier badge
        badgeLabel.font = NSFont.monospacedSystemFont(ofSize: 10, weight: .regular)
        badgeLabel.textColor = NSColor.systemGreen
        badgeLabel.drawsBackground = false
        badgeLabel.isBezeled = false
        badgeLabel.isEditable = false
        badgeLabel.alignment = .right
        capsuleVisualEffect.addSubview(badgeLabel)
        
        // History toggle button
        historyToggleButton.bezelStyle = .regularSquare
        historyToggleButton.isBordered = false
        historyToggleButton.image = NSImage(systemSymbolName: "chevron.down", accessibilityDescription: "Toggle History")
        historyToggleButton.contentTintColor = NSColor.white.withAlphaComponent(0.70)
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
        confirmButton.layer?.cornerRadius = 6.0
        confirmButton.layer?.backgroundColor = NSColor.systemGreen.withAlphaComponent(0.25).cgColor
        confirmButton.layer?.borderWidth = 1.0
        confirmButton.layer?.borderColor = NSColor.systemGreen.withAlphaComponent(0.70).cgColor
        confirmButton.contentTintColor = NSColor.systemGreen
        confirmButton.target = self
        confirmButton.action = #selector(handleConfirmClicked)
        confirmationContainer.addSubview(confirmButton)
        
        // Cancel Button
        cancelButton.title = "Cancel (Esc)"
        cancelButton.font = NSFont.systemFont(ofSize: 11, weight: .regular)
        cancelButton.wantsLayer = true
        cancelButton.isBordered = false
        cancelButton.layer?.cornerRadius = 6.0
        cancelButton.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.10).cgColor
        cancelButton.layer?.borderWidth = 1.0
        cancelButton.layer?.borderColor = NSColor.white.withAlphaComponent(0.20).cgColor
        cancelButton.contentTintColor = NSColor.white.withAlphaComponent(0.75)
        cancelButton.target = self
        cancelButton.action = #selector(handleCancelClicked)
        confirmationContainer.addSubview(cancelButton)
    }
    
    // MARK: - Setup History Panel
    
    private func setupHistoryPanel() {
        historyVisualEffect.material = .sidebar
        historyVisualEffect.blendingMode = .behindWindow
        historyVisualEffect.state = .active
        historyVisualEffect.wantsLayer = true
        historyVisualEffect.layer?.cornerRadius = 14.0
        historyVisualEffect.layer?.masksToBounds = true
        historyVisualEffect.layer?.borderWidth = 1.0
        historyVisualEffect.layer?.borderColor = NSColor.separatorColor.cgColor
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
        let capsuleHeight: CGFloat = isConfirmationActive ? 50.0 : 46.0
        let currentWidth = bounds.width
        
        // 1. Top Capsule
        capsuleVisualEffect.frame = NSRect(x: 0, y: 0, width: currentWidth, height: capsuleHeight)
        capsuleVisualEffect.layer?.cornerRadius = capsuleHeight / 2.0
        
        if isConfirmationActive {
            // Confirmation layout
            listeningIndicator.isHidden = true
            statusLabel.isHidden = true
            badgeLabel.isHidden = true
            historyToggleButton.isHidden = true
            
            confirmationContainer.isHidden = false
            confirmationContainer.frame = NSRect(x: 12, y: 0, width: currentWidth - 24, height: capsuleHeight)
            
            confirmationIcon.frame = NSRect(x: 4, y: (capsuleHeight - 18) / 2.0, width: 20, height: 18)
            confirmationBadge.frame = NSRect(x: 28, y: (capsuleHeight - 16) / 2.0, width: 84, height: 16)
            
            let btnWidth: CGFloat = 100.0
            let btnSpacing: CGFloat = 6.0
            let buttonsTotalWidth = (btnWidth * 2.0) + btnSpacing
            let promptWidth = max(60, currentWidth - 24 - 116 - buttonsTotalWidth - 12)
            
            confirmationPromptLabel.frame = NSRect(x: 114, y: (capsuleHeight - 18) / 2.0, width: promptWidth, height: 18)
            
            let cancelX = currentWidth - 24 - (btnWidth * 2.0) - btnSpacing
            let confirmX = currentWidth - 24 - btnWidth
            
            cancelButton.frame = NSRect(x: cancelX, y: (capsuleHeight - 26) / 2.0, width: btnWidth, height: 26)
            confirmButton.frame = NSRect(x: confirmX, y: (capsuleHeight - 26) / 2.0, width: btnWidth, height: 26)
        } else {
            // Standard layout
            listeningIndicator.isHidden = false
            statusLabel.isHidden = false
            badgeLabel.isHidden = false
            historyToggleButton.isHidden = false
            confirmationContainer.isHidden = true
            
            listeningIndicator.frame = NSRect(x: 16, y: (capsuleHeight - 24) / 2.0, width: 56, height: 24)
            
            let rightOffset: CGFloat = 34.0
            let badgeWidth: CGFloat = badgeLabel.stringValue.isEmpty ? 0 : 80.0
            let statusWidth = max(50, currentWidth - 84 - badgeWidth - rightOffset - 8)
            
            statusLabel.frame = NSRect(x: 82, y: (capsuleHeight - 20) / 2.0, width: statusWidth, height: 20)
            badgeLabel.frame = NSRect(x: 82 + statusWidth + 4, y: (capsuleHeight - 16) / 2.0, width: badgeWidth, height: 16)
            historyToggleButton.frame = NSRect(x: currentWidth - 28, y: (capsuleHeight - 20) / 2.0, width: 20, height: 20)
        }
        
        // 2. Expandable History Panel
        if isHistoryExpanded {
            historyVisualEffect.isHidden = false
            let historyY = capsuleHeight + 6.0
            let historyHeight = max(60, bounds.height - historyY)
            historyVisualEffect.frame = NSRect(x: 0, y: historyY, width: currentWidth, height: historyHeight)
            
            historyHeaderLabel.frame = NSRect(x: 14, y: 8, width: 120, height: 18)
            historyCountBadge.frame = NSRect(x: 138, y: 9, width: 80, height: 16)
            historyCollapseButton.frame = NSRect(x: currentWidth - 28, y: 8, width: 18, height: 18)
            
            let scrollY: CGFloat = 32.0
            historyScrollView.frame = NSRect(x: 10, y: scrollY, width: currentWidth - 20, height: max(20, historyHeight - scrollY - 10))
            renderHistoryCards()
        } else {
            historyVisualEffect.isHidden = true
        }
    }
    
    // MARK: - Public State Controls
    
    public func setStatusText(_ text: String) {
        statusLabel.stringValue = text
    }
    
    public func setTierBadge(_ badgeText: String, isLocal: Bool = true) {
        badgeLabel.stringValue = badgeText
        badgeLabel.textColor = isLocal ? NSColor.systemGreen : NSColor.systemBlue
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
        
        let contentWidth = historyScrollView.contentView.bounds.width
        var currentY: CGFloat = 4.0
        let cardSpacing: CGFloat = 8.0
        
        if turnRecords.isEmpty {
            let emptyLabel = NSTextField(labelWithString: "No recent conversation turns")
            emptyLabel.font = NSFont.systemFont(ofSize: 12, weight: .regular)
            emptyLabel.textColor = NSColor.white.withAlphaComponent(0.40)
            emptyLabel.alignment = .center
            emptyLabel.frame = NSRect(x: 0, y: 40, width: contentWidth, height: 20)
            historyDocumentView.addSubview(emptyLabel)
            historyDocumentView.frame = NSRect(x: 0, y: 0, width: contentWidth, height: 100)
            return
        }
        
        for record in turnRecords.reversed() {
            let cardView = NSView()
            cardView.wantsLayer = true
            cardView.layer?.cornerRadius = 8.0
            cardView.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.04).cgColor
            cardView.layer?.borderWidth = 1.0
            cardView.layer?.borderColor = NSColor.white.withAlphaComponent(0.08).cgColor
            
            let timeStr = timestampFormatter.string(from: record.timestamp)
            let timeLabel = NSTextField(labelWithString: timeStr)
            timeLabel.font = NSFont.monospacedSystemFont(ofSize: 10, weight: .regular)
            timeLabel.textColor = NSColor.white.withAlphaComponent(0.45)
            timeLabel.frame = NSRect(x: 8, y: 6, width: 60, height: 14)
            cardView.addSubview(timeLabel)
            
            let badgeText = record.badgeLabel ?? (record.isLocal ? "T1 Local" : "Cloud")
            let badgeView = NSTextField(labelWithString: badgeText)
            badgeView.font = NSFont.monospacedSystemFont(ofSize: 9, weight: .medium)
            badgeView.textColor = record.isLocal ? NSColor.systemGreen : NSColor.systemBlue
            badgeView.frame = NSRect(x: 72, y: 6, width: 100, height: 14)
            cardView.addSubview(badgeView)
            
            if let lat = record.latencyMs {
                let latLabel = NSTextField(labelWithString: String(format: "%.0f ms", lat))
                latLabel.font = NSFont.monospacedSystemFont(ofSize: 9, weight: .regular)
                latLabel.textColor = NSColor.white.withAlphaComponent(0.35)
                latLabel.alignment = .right
                latLabel.frame = NSRect(x: contentWidth - 80, y: 6, width: 70, height: 14)
                cardView.addSubview(latLabel)
            }
            
            let userLabel = NSTextField(labelWithString: "You: \(record.userText)")
            userLabel.font = NSFont.systemFont(ofSize: 11, weight: .regular)
            userLabel.textColor = NSColor.white.withAlphaComponent(0.70)
            userLabel.lineBreakMode = .byTruncatingTail
            userLabel.frame = NSRect(x: 8, y: 22, width: contentWidth - 16, height: 16)
            cardView.addSubview(userLabel)
            
            let assistantLabel = NSTextField(labelWithString: "Pearl: \(record.assistantText)")
            assistantLabel.font = NSFont.systemFont(ofSize: 12, weight: .medium)
            assistantLabel.textColor = .white
            assistantLabel.lineBreakMode = .byTruncatingTail
            assistantLabel.frame = NSRect(x: 8, y: 40, width: contentWidth - 16, height: 16)
            cardView.addSubview(assistantLabel)
            
            let cardHeight: CGFloat = 62.0
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
