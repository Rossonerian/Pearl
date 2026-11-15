import AppKit

/// Flipped NSView container so history scroll content and stacked bars align cleanly from top to bottom.
public final class FlippedView: NSView {
    public override var isFlipped: Bool { true }
}

/// Custom borderless AppKit button with accessible exterior keyboard focus ring support.
public final class InstrumentButton: NSButton {
    public override var acceptsFirstResponder: Bool { true }

    public override func awakeFromNib() {
        super.awakeFromNib()
        focusRingType = .exterior
    }

    public override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        focusRingType = .exterior
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        focusRingType = .exterior
    }

    public override var focusRingMaskBounds: NSRect {
        return bounds
    }

    public override func drawFocusRingMask() {
        let radius = layer?.cornerRadius ?? 6.0
        let path = NSBezierPath(roundedRect: bounds, xRadius: radius, yRadius: radius)
        path.fill()
    }
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
/// 1. Top floating capsule (`400x48` standard) with 60 Hz listening waveform meter, status transcription,
///    keyboard command toggle (`⌘T` or `/`), and history toggle (`Tab`).
/// 2. Interactive tool confirmation banner (`460x56`): Displays pending tool, tier, and exact
///    target/destination with `[Confirm (Enter)]` and `[Cancel (Esc)]` controls.
/// 3. Compact text command input bar (`420x40`) directly beneath the capsule for typed queries.
/// 4. Expandable conversation history panel with SF Mono timestamps and tabular latency metrics.
/// 5. Strict adherence to `DESIGN.md` (zero gradients, zero emoji icons, full High Contrast, Reduced Motion, and VoiceOver support).
public final class HUDView: NSView, NSTextFieldDelegate {
    
    public override var isFlipped: Bool { true }
    
    // MARK: - Subviews: Top Capsule
    public let capsuleVisualEffect = NSVisualEffectView()
    public let listeningIndicator = ListeningIndicatorView(frame: NSRect(x: 16, y: 12, width: 52, height: 24))
    public let statusLabel = NSTextField(labelWithString: "Pearl standing by")
    public let badgeLabel = NSTextField(labelWithString: "")
    public let capsuleDivider = NSView()
    public let textInputToggleButton = InstrumentButton()
    public let historyToggleButton = InstrumentButton()
    
    // MARK: - Subviews: Interactive Tool Confirmation Banner
    public let confirmationContainer = NSView()
    public let confirmationIcon = NSImageView()
    public let confirmationBadge = NSTextField(labelWithString: "T2 CONFIRM")
    public let confirmationToolLabel = NSTextField(labelWithString: "")
    public let confirmationPromptLabel = NSTextField(labelWithString: "")
    public let confirmButton = InstrumentButton()
    public let cancelButton = InstrumentButton()
    
    // MARK: - Subviews: Compact Text Command Bar (420x40)
    public let inputVisualEffect = NSVisualEffectView()
    public let inputContentView = FlippedView()
    public let inputPromptIcon = NSImageView()
    public let commandTextField = NSTextField()
    public let commandSubmitButton = InstrumentButton()
    
    // MARK: - Subviews: Expandable Conversation History Panel
    public let historyVisualEffect = NSVisualEffectView()
    public let historyHeaderLabel = NSTextField(labelWithString: "Recent Turns")
    public let historyCountBadge = NSTextField(labelWithString: "0 turns")
    public let historyCollapseButton = InstrumentButton()
    public let historyScrollView = NSScrollView()
    public let historyDocumentView = FlippedView()
    
    // MARK: - State
    public private(set) var isHistoryExpanded: Bool = false
    public private(set) var isTextInputExpanded: Bool = false
    public private(set) var isConfirmationActive: Bool = false
    public private(set) var turnRecords: [HUDTurnRecord] = []
    
    private var isInputFocused: Bool = false
    private var pendingConfirmAction: (() -> Void)?
    private var pendingCancelAction: (() -> Void)?
    private var accessibilityObserver: NSObjectProtocol?
    
    // Callbacks
    public var onDismissRequested: (() -> Void)?
    public var onToggleHistoryRequested: (() -> Void)?
    public var onToggleTextInputRequested: (() -> Void)?
    public var onSubmitTextQuery: ((String) -> Void)?
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
        setupTextInputBar()
        setupHistoryPanel()
        configureAccessibilityAndKeyChain()
        applyAccessibilityAppearance()
        updateLayoutFrames()
        
        accessibilityObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.applyAccessibilityAppearance()
            self?.updateLayoutFrames()
        }
    }
    
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
    
    deinit {
        if let observer = accessibilityObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
        }
    }
    
    // MARK: - Setup Top Capsule
    
    private func setupTopCapsule() {
        capsuleVisualEffect.material = .hudWindow
        capsuleVisualEffect.blendingMode = .behindWindow
        capsuleVisualEffect.state = .active
        capsuleVisualEffect.wantsLayer = true
        capsuleVisualEffect.layer?.cornerRadius = 24.0
        capsuleVisualEffect.layer?.masksToBounds = true
        capsuleVisualEffect.layer?.borderWidth = 1.0
        addSubview(capsuleVisualEffect)
        
        // Waveform indicator
        capsuleVisualEffect.addSubview(listeningIndicator)
        
        // Status text
        statusLabel.font = NSFont.systemFont(ofSize: 13.5, weight: .medium)
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
        
        // Subtle vertical divider before utility buttons
        capsuleDivider.wantsLayer = true
        capsuleVisualEffect.addSubview(capsuleDivider)
        
        // Compact keyboard input toggle button
        textInputToggleButton.bezelStyle = .regularSquare
        textInputToggleButton.isBordered = false
        textInputToggleButton.wantsLayer = true
        textInputToggleButton.layer?.cornerRadius = 6.0
        let kbConfig = NSImage.SymbolConfiguration(pointSize: 12, weight: .medium)
        textInputToggleButton.image = NSImage(systemSymbolName: "keyboard", accessibilityDescription: "Type Command")?.withSymbolConfiguration(kbConfig)
        textInputToggleButton.target = self
        textInputToggleButton.action = #selector(handleTextInputToggleClicked)
        textInputToggleButton.toolTip = "Type a command (⌘T or /)"
        capsuleVisualEffect.addSubview(textInputToggleButton)
        
        // History toggle button
        historyToggleButton.bezelStyle = .regularSquare
        historyToggleButton.isBordered = false
        historyToggleButton.wantsLayer = true
        historyToggleButton.layer?.cornerRadius = 6.0
        let chevronConfig = NSImage.SymbolConfiguration(pointSize: 12, weight: .medium)
        historyToggleButton.image = NSImage(systemSymbolName: "chevron.down", accessibilityDescription: "Toggle History")?.withSymbolConfiguration(chevronConfig)
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
        let warnConfig = NSImage.SymbolConfiguration(pointSize: 12, weight: .semibold)
        confirmationIcon.image = NSImage(systemSymbolName: "exclamationmark.triangle.fill", accessibilityDescription: "Confirmation Required")?.withSymbolConfiguration(warnConfig)
        confirmationIcon.contentTintColor = NSColor.systemOrange
        confirmationContainer.addSubview(confirmationIcon)
        
        // Tier badge
        confirmationBadge.font = NSFont.monospacedSystemFont(ofSize: 10, weight: .semibold)
        confirmationBadge.textColor = NSColor.systemOrange
        confirmationBadge.drawsBackground = false
        confirmationBadge.isBezeled = false
        confirmationBadge.isEditable = false
        confirmationContainer.addSubview(confirmationBadge)
        
        // Tool name header
        confirmationToolLabel.font = NSFont.systemFont(ofSize: 11, weight: .semibold)
        confirmationToolLabel.textColor = NSColor.white.withAlphaComponent(0.90)
        confirmationToolLabel.lineBreakMode = .byTruncatingTail
        confirmationToolLabel.drawsBackground = false
        confirmationToolLabel.isBezeled = false
        confirmationToolLabel.isEditable = false
        confirmationContainer.addSubview(confirmationToolLabel)
        
        // Prompt / destination detail label (full second row so target paths & destinations remain readable)
        confirmationPromptLabel.font = NSFont.systemFont(ofSize: 12, weight: .medium)
        confirmationPromptLabel.textColor = .white
        confirmationPromptLabel.lineBreakMode = .byTruncatingMiddle
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
    
    // MARK: - Setup Text Input Bar (420x40)
    
    private func setupTextInputBar() {
        inputVisualEffect.material = .hudWindow
        inputVisualEffect.blendingMode = .behindWindow
        inputVisualEffect.state = .active
        inputVisualEffect.wantsLayer = true
        inputVisualEffect.layer?.cornerRadius = 12.0
        inputVisualEffect.layer?.masksToBounds = true
        inputVisualEffect.layer?.borderWidth = 1.0
        inputVisualEffect.isHidden = true
        addSubview(inputVisualEffect)
        
        inputVisualEffect.addSubview(inputContentView)
        
        let promptConfig = NSImage.SymbolConfiguration(pointSize: 11, weight: .semibold)
        inputPromptIcon.image = NSImage(systemSymbolName: "chevron.right", accessibilityDescription: nil)?.withSymbolConfiguration(promptConfig)
        inputPromptIcon.contentTintColor = NSColor(calibratedRed: 0.96, green: 0.72, blue: 0.30, alpha: 0.90)
        inputContentView.addSubview(inputPromptIcon)
        
        commandTextField.font = NSFont.systemFont(ofSize: 13.0, weight: .regular)
        commandTextField.textColor = NSColor.white.withAlphaComponent(0.95)
        commandTextField.drawsBackground = false
        commandTextField.isBezeled = false
        commandTextField.isBordered = false
        commandTextField.isEditable = true
        commandTextField.isSelectable = true
        commandTextField.focusRingType = .none
        commandTextField.cell?.usesSingleLineMode = true
        commandTextField.cell?.isScrollable = true
        commandTextField.cell?.wraps = false
        commandTextField.placeholderString = "Type a command or ask Pearl…"
        commandTextField.placeholderAttributedString = NSAttributedString(
            string: "Type a command or ask Pearl…",
            attributes: [
                .foregroundColor: NSColor.white.withAlphaComponent(0.42),
                .font: NSFont.systemFont(ofSize: 13.0, weight: .regular)
            ]
        )
        commandTextField.delegate = self
        inputContentView.addSubview(commandTextField)
        
        commandSubmitButton.bezelStyle = .regularSquare
        commandSubmitButton.isBordered = false
        commandSubmitButton.wantsLayer = true
        commandSubmitButton.layer?.cornerRadius = 6.0
        let submitConfig = NSImage.SymbolConfiguration(pointSize: 15, weight: .medium)
        commandSubmitButton.image = NSImage(systemSymbolName: "arrow.up.circle.fill", accessibilityDescription: "Submit Command")?.withSymbolConfiguration(submitConfig)
        commandSubmitButton.contentTintColor = NSColor.white.withAlphaComponent(0.85)
        commandSubmitButton.target = self
        commandSubmitButton.action = #selector(handleSubmitClicked)
        commandSubmitButton.toolTip = "Execute Command (Return)"
        inputContentView.addSubview(commandSubmitButton)
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
        historyCollapseButton.wantsLayer = true
        historyCollapseButton.layer?.cornerRadius = 5.0
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
    
    // MARK: - Accessibility & Key View Chain
    
    private func configureAccessibilityAndKeyChain() {
        listeningIndicator.setAccessibilityElement(true)
        listeningIndicator.setAccessibilityRole(.progressIndicator)
        listeningIndicator.setAccessibilityLabel("Pearl audio and thinking activity meter")
        
        statusLabel.setAccessibilityLabel("Assistant status")
        badgeLabel.setAccessibilityLabel("Model escalation indicator")
        textInputToggleButton.setAccessibilityLabel("Type command")
        historyToggleButton.setAccessibilityLabel("Toggle conversation history")
        
        confirmationBadge.setAccessibilityLabel("Confirmation tier")
        confirmationToolLabel.setAccessibilityLabel("Pending tool")
        confirmationPromptLabel.setAccessibilityLabel("Pending action and destination")
        confirmButton.setAccessibilityLabel("Confirm pending action")
        cancelButton.setAccessibilityLabel("Cancel pending action")
        
        commandTextField.setAccessibilityLabel("Command input")
        commandSubmitButton.setAccessibilityLabel("Submit command")
        historyCollapseButton.setAccessibilityLabel("Collapse conversation history")
        
        commandTextField.nextKeyView = commandSubmitButton
        commandSubmitButton.nextKeyView = textInputToggleButton
        textInputToggleButton.nextKeyView = historyToggleButton
        historyToggleButton.nextKeyView = commandTextField
        
        cancelButton.nextKeyView = confirmButton
        confirmButton.nextKeyView = cancelButton
    }
    
    private func applyAccessibilityAppearance() {
        let isHighContrast = NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast
        
        capsuleVisualEffect.layer?.borderColor = NSColor.white.withAlphaComponent(isHighContrast ? 0.45 : 0.18).cgColor
        historyVisualEffect.layer?.borderColor = NSColor.white.withAlphaComponent(isHighContrast ? 0.35 : 0.14).cgColor
        
        if isInputFocused {
            inputVisualEffect.layer?.borderWidth = 1.5
            inputVisualEffect.layer?.borderColor = NSColor(calibratedRed: 0.96, green: 0.72, blue: 0.30, alpha: isHighContrast ? 0.95 : 0.75).cgColor
        } else {
            inputVisualEffect.layer?.borderWidth = 1.0
            inputVisualEffect.layer?.borderColor = NSColor.white.withAlphaComponent(isHighContrast ? 0.45 : 0.18).cgColor
        }
        
        statusLabel.textColor = isHighContrast ? .white : NSColor.white.withAlphaComponent(0.95)
        commandTextField.textColor = isHighContrast ? .white : NSColor.white.withAlphaComponent(0.95)
        capsuleDivider.layer?.backgroundColor = NSColor.white.withAlphaComponent(isHighContrast ? 0.28 : 0.10).cgColor
        
        if isTextInputExpanded {
            textInputToggleButton.contentTintColor = NSColor(calibratedRed: 0.96, green: 0.72, blue: 0.30, alpha: 0.95)
        } else {
            textInputToggleButton.contentTintColor = NSColor.white.withAlphaComponent(isHighContrast ? 0.88 : 0.65)
        }
        historyToggleButton.contentTintColor = NSColor.white.withAlphaComponent(isHighContrast ? 0.90 : 0.68)
        
        cancelButton.layer?.borderColor = NSColor.white.withAlphaComponent(isHighContrast ? 0.40 : 0.18).cgColor
        confirmButton.layer?.borderColor = NSColor.systemGreen.withAlphaComponent(isHighContrast ? 0.90 : 0.65).cgColor
        
        listeningIndicator.needsDisplay = true
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
            textInputToggleButton.isHidden = true
            historyToggleButton.isHidden = true
            
            confirmationContainer.isHidden = false
            confirmationContainer.frame = NSRect(x: 14, y: 0, width: currentWidth - 28, height: capsuleHeight)
            
            let containerW = confirmationContainer.bounds.width
            let cancelWidth: CGFloat = 86.0
            let confirmWidth: CGFloat = 102.0
            let btnSpacing: CGFloat = 8.0
            let buttonsTotalWidth = cancelWidth + confirmWidth + btnSpacing
            let leftTextWidth = max(90, containerW - buttonsTotalWidth - 12)
            
            confirmationIcon.frame = NSRect(x: 2, y: 9, width: 14, height: 14)
            confirmationBadge.frame = NSRect(x: 20, y: 8, width: 76, height: 15)
            confirmationToolLabel.frame = NSRect(x: 98, y: 8, width: max(40, leftTextWidth - 98), height: 15)
            confirmationPromptLabel.frame = NSRect(x: 2, y: 27, width: leftTextWidth, height: 18)
            
            let cancelX = containerW - buttonsTotalWidth
            let confirmX = containerW - confirmWidth
            
            cancelButton.frame = NSRect(x: cancelX, y: (capsuleHeight - 28) / 2.0, width: cancelWidth, height: 28)
            confirmButton.frame = NSRect(x: confirmX, y: (capsuleHeight - 28) / 2.0, width: confirmWidth, height: 28)
        } else {
            // Standard layout
            let showCloudBadge = !badgeLabel.stringValue.isEmpty
            listeningIndicator.isHidden = false
            statusLabel.isHidden = false
            badgeLabel.isHidden = !showCloudBadge
            capsuleDivider.isHidden = false
            textInputToggleButton.isHidden = false
            historyToggleButton.isHidden = false
            confirmationContainer.isHidden = true
            
            listeningIndicator.frame = NSRect(x: 16, y: (capsuleHeight - 24) / 2.0, width: 42, height: 24)
            
            let rightAreaWidth: CGFloat = 74.0
            let badgeWidth: CGFloat = showCloudBadge ? 92.0 : 0.0
            let badgeGap: CGFloat = showCloudBadge ? 8.0 : 0.0
            let statusWidth = max(60, currentWidth - 68 - rightAreaWidth - badgeWidth - badgeGap - 6)
            
            statusLabel.frame = NSRect(x: 68, y: (capsuleHeight - 20) / 2.0, width: statusWidth, height: 20)
            badgeLabel.frame = NSRect(x: 68 + statusWidth + 6, y: (capsuleHeight - 16) / 2.0, width: badgeWidth, height: 16)
            capsuleDivider.frame = NSRect(x: currentWidth - 68, y: (capsuleHeight - 20) / 2.0, width: 1.0, height: 20.0)
            textInputToggleButton.frame = NSRect(x: currentWidth - 60, y: (capsuleHeight - 24) / 2.0, width: 24, height: 24)
            historyToggleButton.frame = NSRect(x: currentWidth - 32, y: (capsuleHeight - 24) / 2.0, width: 24, height: 24)
        }
        
        // 2. Compact Text Input Bar (420x40 right beneath capsule)
        var nextPanelY = capsuleHeight + 6.0
        if isTextInputExpanded && !isConfirmationActive {
            let inputHeight: CGFloat = 40.0
            let inputWidth = currentWidth
            inputVisualEffect.isHidden = false
            inputVisualEffect.frame = NSRect(x: 0, y: nextPanelY, width: inputWidth, height: inputHeight)
            inputContentView.frame = inputVisualEffect.bounds
            inputPromptIcon.frame = NSRect(x: 12, y: (inputHeight - 14) / 2.0, width: 14, height: 14)
            commandTextField.frame = NSRect(x: 32, y: (inputHeight - 20) / 2.0, width: max(80, inputWidth - 32 - 42), height: 20)
            commandSubmitButton.frame = NSRect(x: inputWidth - 36, y: (inputHeight - 26) / 2.0, width: 26, height: 26)
            nextPanelY += inputHeight + 6.0
        } else {
            inputVisualEffect.isHidden = true
        }
        
        // 3. Expandable History Panel
        if isHistoryExpanded {
            historyVisualEffect.isHidden = false
            let historyHeight = max(60, bounds.height - nextPanelY)
            historyVisualEffect.frame = NSRect(x: 0, y: nextPanelY, width: currentWidth, height: historyHeight)
            
            // NSVisualEffectView uses bottom-left origin (isFlipped == false), so anchor header at top
            let headerY = max(8.0, historyHeight - 28.0)
            historyHeaderLabel.frame = NSRect(x: 14, y: headerY, width: 120, height: 18)
            historyCountBadge.alignment = .right
            historyCountBadge.frame = NSRect(x: currentWidth - 124, y: headerY + 1, width: 86, height: 16)
            historyCollapseButton.frame = NSRect(x: currentWidth - 32, y: headerY - 1, width: 20, height: 20)
            
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
    
    // MARK: - Compact Text Command Bar Controls
    
    public func setTextInputExpanded(_ expanded: Bool) {
        isTextInputExpanded = expanded
        if !expanded {
            isInputFocused = false
        }
        applyAccessibilityAppearance()
        updateLayoutFrames()
    }
    
    public func toggleTextInput() {
        guard !isConfirmationActive else { return }
        setTextInputExpanded(!isTextInputExpanded)
        onToggleTextInputRequested?()
    }
    
    @objc private func handleTextInputToggleClicked() {
        toggleTextInput()
    }
    
    @objc private func handleSubmitClicked() {
        submitCommandField()
    }
    
    private func submitCommandField() {
        let trimmed = commandTextField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        commandTextField.stringValue = ""
        setTextInputExpanded(false)
        onToggleTextInputRequested?()
        onSubmitTextQuery?(trimmed)
    }
    
    // MARK: - NSTextFieldDelegate
    
    public func controlTextDidBeginEditing(_ obj: Notification) {
        isInputFocused = true
        applyAccessibilityAppearance()
    }
    
    public func controlTextDidEndEditing(_ obj: Notification) {
        isInputFocused = false
        applyAccessibilityAppearance()
    }
    
    public func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        if commandSelector == #selector(NSResponder.insertNewline(_:)) {
            submitCommandField()
            return true
        }
        if commandSelector == #selector(NSResponder.cancelOperation(_:)) {
            setTextInputExpanded(false)
            onToggleTextInputRequested?()
            return true
        }
        return false
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
        isTextInputExpanded = false
        isInputFocused = false
        pendingConfirmAction = onConfirm
        pendingCancelAction = onCancel
        
        confirmationBadge.stringValue = "\(tier) CONFIRM"
        confirmationToolLabel.stringValue = toolName
        confirmationPromptLabel.stringValue = prompt
        confirmationPromptLabel.toolTip = "\(toolName): \(prompt)"
        
        applyAccessibilityAppearance()
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
        onConfirmationResolved?()
        action?()
    }
    
    @objc private func handleCancelClicked() {
        let action = pendingCancelAction
        dismissToolConfirmation()
        onConfirmationResolved?()
        action?()
    }
    
    // MARK: - Conversation History Management
    
    public func setHistoryExpanded(_ expanded: Bool) {
        isHistoryExpanded = expanded
        let chevronConfig = NSImage.SymbolConfiguration(pointSize: 12, weight: .medium)
        historyToggleButton.image = NSImage(
            systemSymbolName: expanded ? "chevron.up" : "chevron.down",
            accessibilityDescription: expanded ? "Collapse History" : "Expand History"
        )?.withSymbolConfiguration(chevronConfig)
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
    
    public override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if isConfirmationActive {
            if event.keyCode == 36 || event.keyCode == 76 {
                handleConfirmClicked()
                return true
            } else if event.keyCode == 53 {
                handleCancelClicked()
                return true
            }
        }
        
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if flags == .command, event.charactersIgnoringModifiers?.lowercased() == "t", !isConfirmationActive {
            toggleTextInput()
            return true
        }
        
        return super.performKeyEquivalent(with: event)
    }
    
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
        
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if flags.isEmpty, event.charactersIgnoringModifiers == "/", !isConfirmationActive, !isTextInputExpanded {
            setTextInputExpanded(true)
            onToggleTextInputRequested?()
            return
        }
        
        switch event.keyCode {
        case 53: // ESC key
            if isTextInputExpanded {
                setTextInputExpanded(false)
                onToggleTextInputRequested?()
            } else if isHistoryExpanded {
                toggleHistory()
            } else {
                onDismissRequested?()
            }
        case 48, 125: // Tab or Down Arrow
            if !isTextInputExpanded {
                toggleHistory()
            } else {
                super.keyDown(with: event)
            }
        default:
            super.keyDown(with: event)
        }
    }
}
