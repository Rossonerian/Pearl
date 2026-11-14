import AppKit

/// Waveform audio bar view for Pearl HUD.
///
/// Implements 60 Hz display refresh cadence adhering to MacBook Neo specifications.
public final class WaveformBarView: NSView {
    public var barCount: Int = 7
    public var levels: [CGFloat] = Array(repeating: 0.15, count: 7)
    public var isThinking: Bool = false
    public var phase: CGFloat = 0.0
    
    public override var isFlipped: Bool { true }
    
    public override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        self.wantsLayer = true
    }
    
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
    
    public func updateThinking(step: CGFloat = 0.10) {
        isThinking = true
        if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            levels = Array(repeating: 0.5, count: barCount)
            needsDisplay = true
            return
        }
        phase += step
        for i in 0..<barCount {
            let offset = CGFloat(i) * 0.65
            let sinVal = sin(phase + offset)
            levels[i] = CGFloat(0.20 + 0.70 * ((sinVal + 1.0) / 2.0))
        }
        needsDisplay = true
    }
    
    public func updateLevels(normalized: CGFloat) {
        isThinking = false
        let clamped = max(0.08, min(1.0, normalized))
        for i in 0..<barCount {
            let distFromCenter = abs(CGFloat(i) - CGFloat(barCount - 1) / 2.0)
            let factor = max(0.2, 1.0 - (distFromCenter * 0.22))
            levels[i] = clamped * factor
        }
        needsDisplay = true
    }
    
    public override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        
        let totalWidth = bounds.width
        let totalHeight = bounds.height
        let barSpacing: CGFloat = 4.0
        let barWidth: CGFloat = max(2.0, (totalWidth - (CGFloat(barCount - 1) * barSpacing)) / CGFloat(barCount))
        let minHeight: CGFloat = 4.0
        
        let isHighContrast = NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast
        
        for i in 0..<barCount {
            let barX = CGFloat(i) * (barWidth + barSpacing)
            let barH = max(minHeight, totalHeight * levels[i])
            let barY = (totalHeight - barH) / 2.0
            
            let barRect = CGRect(x: barX, y: barY, width: barWidth, height: barH)
            let path = CGPath(roundedRect: barRect, cornerWidth: barWidth / 2.0, cornerHeight: barWidth / 2.0, transform: nil)
            
            if isThinking {
                let alpha = isHighContrast ? 0.95 : (0.50 + 0.50 * levels[i])
                context.setFillColor(CGColor(red: 0.60, green: 0.40, blue: 0.95, alpha: alpha))
            } else {
                let alpha = isHighContrast ? 1.0 : (0.60 + 0.40 * levels[i])
                context.setFillColor(CGColor(red: 0.95, green: 0.95, blue: 0.98, alpha: alpha))
            }
            
            context.addPath(path)
            context.fillPath()
        }
    }
}
