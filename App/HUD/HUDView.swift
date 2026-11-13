import AppKit

public final class HUDView: NSView {
    public let waveformView = WaveformBarView(frame: NSRect(x: 16, y: 12, width: 64, height: 24))
    public let statusLabel = NSTextField(labelWithString: "Pearl standing by")
    private var animationTimer: Timer?
    public var onDismissRequested: (() -> Void)?
    
    public override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setupViews()
    }
    
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
    
    private func setupViews() {
        wantsLayer = true
        
        let visualEffect = NSVisualEffectView(frame: bounds)
        visualEffect.autoresizingMask = [.width, .height]
        visualEffect.material = .hudWindow
        visualEffect.blendingMode = .behindWindow
        visualEffect.state = .active
        visualEffect.wantsLayer = true
        visualEffect.layer?.cornerRadius = bounds.height / 2.0
        visualEffect.layer?.masksToBounds = true
        visualEffect.layer?.borderWidth = 1.0
        visualEffect.layer?.borderColor = NSColor.white.withAlphaComponent(0.18).cgColor
        addSubview(visualEffect)
        
        waveformView.frame = NSRect(x: 18, y: (bounds.height - 24) / 2.0, width: 64, height: 24)
        addSubview(waveformView)
        
        statusLabel.frame = NSRect(x: 90, y: (bounds.height - 20) / 2.0, width: bounds.width - 106, height: 20)
        statusLabel.font = NSFont.systemFont(ofSize: 13, weight: .medium)
        statusLabel.textColor = .white
        statusLabel.lineBreakMode = .byTruncatingTail
        addSubview(statusLabel)
    }
    
    public func setStatusText(_ text: String) {
        statusLabel.stringValue = text
    }
    
    public func startThinkingAnimation() {
        waveformView.isThinking = true
        stopAnimation()
        
        guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else {
            waveformView.updateThinking(step: 0)
            return
        }
        
        // 60 Hz display refresh cadence (1/60s ≈ 16.6ms)
        animationTimer = Timer.scheduledTimer(withTimeInterval: 0.0166, repeats: true) { [weak self] _ in
            self?.waveformView.updateThinking(step: 0.10)
        }
    }
    
    public func updateAudioLevel(_ level: CGFloat) {
        waveformView.isThinking = false
        stopAnimation()
        waveformView.updateLevels(normalized: level)
    }
    
    public func stopAnimation() {
        animationTimer?.invalidate()
        animationTimer = nil
    }
    
    public override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { // ESC key
            onDismissRequested?()
        } else {
            super.keyDown(with: event)
        }
    }
}
