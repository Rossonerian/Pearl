import AppKit

/// 60 Hz audio-reactive and thinking waveform meter conforming to `DESIGN.md`.
///
/// Tailored for the Apple Silicon MacBook Neo display rate (60 Hz / 16.6ms cadence).
/// Renders 5 vertical rounded bars with center-weighted dynamic scaling,
/// smooth sinusoidal phase oscillation during thinking, and instantaneous
/// static fallback when macOS Reduced Motion is enabled.
public final class ListeningIndicatorView: NSView {
    public var barCount: Int = 5
    public var levels: [CGFloat] = Array(repeating: 0.15, count: 5)
    public var isThinking: Bool = false
    public var phase: CGFloat = 0.0
    
    private var animationTimer: Timer?
    
    public override var isFlipped: Bool { true }
    
    public override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        self.wantsLayer = true
    }
    
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
    
    deinit {
        stopAnimation()
    }
    
    // MARK: - 60 Hz Animation Driving
    
    public func startThinkingAnimation() {
        isThinking = true
        stopAnimation()
        
        // Strictly respect macOS Reduced Motion
        if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            // Static 3-bar balanced display
            levels = [0.4, 0.7, 0.4, 0.0, 0.0]
            needsDisplay = true
            return
        }
        
        // 60 Hz display refresh cadence (1/60s ≈ 16.6ms)
        animationTimer = Timer.scheduledTimer(withTimeInterval: 0.0166, repeats: true) { [weak self] _ in
            self?.stepThinkingWave()
        }
    }
    
    public func updateAudioLevel(_ normalized: CGFloat) {
        isThinking = false
        stopAnimation()
        
        let clamped = max(0.08, min(1.0, normalized))
        for i in 0..<barCount {
            let distFromCenter = abs(CGFloat(i) - CGFloat(barCount - 1) / 2.0)
            let factor = max(0.25, 1.0 - (distFromCenter * 0.28))
            levels[i] = clamped * factor
        }
        needsDisplay = true
    }
    
    public func stopAnimation() {
        animationTimer?.invalidate()
        animationTimer = nil
    }
    
    private func stepThinkingWave() {
        phase += 0.10
        for i in 0..<barCount {
            // Traveling wave with harmonic offset
            let offset = CGFloat(i) * 0.65
            let sinVal = sin(phase + offset)
            levels[i] = CGFloat(0.20 + 0.70 * ((sinVal + 1.0) / 2.0))
        }
        needsDisplay = true
    }
    
    // MARK: - Drawing & Rendering
    
    public override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        
        let totalWidth = bounds.width
        let totalHeight = bounds.height
        let barSpacing: CGFloat = 4.0
        let barWidth: CGFloat = max(2.5, (totalWidth - (CGFloat(barCount - 1) * barSpacing)) / CGFloat(barCount))
        let minHeight: CGFloat = 4.0
        
        let isHighContrast = NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast
        
        for i in 0..<barCount {
            let barX = CGFloat(i) * (barWidth + barSpacing)
            let barH = max(minHeight, totalHeight * levels[i])
            let barY = (totalHeight - barH) / 2.0
            
            let barRect = CGRect(x: barX, y: barY, width: barWidth, height: barH)
            let path = CGPath(
                roundedRect: barRect,
                cornerWidth: barWidth / 2.0,
                cornerHeight: barWidth / 2.0,
                transform: nil
            )
            
            if isThinking {
                // Violet-luminescence thinking wave
                let alpha: CGFloat = isHighContrast ? 0.95 : (0.55 + 0.45 * levels[i])
                context.setFillColor(CGColor(red: 0.65, green: 0.45, blue: 0.95, alpha: alpha))
            } else {
                // Crisp white active waveform
                let alpha: CGFloat = isHighContrast ? 1.0 : (0.45 + 0.55 * levels[i])
                context.setFillColor(CGColor(red: 1.0, green: 1.0, blue: 1.0, alpha: alpha))
            }
            
            context.addPath(path)
            context.fillPath()
        }
    }
}
