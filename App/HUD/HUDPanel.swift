import AppKit

public final class HUDPanel: NSPanel {
    public let hudView: HUDView
    
    public init() {
        let screenRect = NSScreen.main?.frame ?? NSRect(x: 0, y: 0, width: 1470, height: 956)
        let pillWidth: CGFloat = 360
        let pillHeight: CGFloat = 46
        let pillX = (screenRect.width - pillWidth) / 2.0
        let pillY = screenRect.maxY - pillHeight - 6.0
        
        let rect = NSRect(x: pillX, y: pillY, width: pillWidth, height: pillHeight)
        
        self.hudView = HUDView(frame: NSRect(x: 0, y: 0, width: pillWidth, height: pillHeight))
        
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
        
        hudView.onDismissRequested = { [weak self] in
            self?.hidePill()
        }
    }
    
    public func showPill(text: String = "Pearl standing by", thinking: Bool = false) {
        hudView.setStatusText(text)
        if thinking {
            hudView.startThinkingAnimation()
        }
        orderFront(nil)
        CATransaction.flush()
    }
    
    public func hidePill() {
        hudView.stopAnimation()
        orderOut(nil)
        CATransaction.flush()
    }
    
    public var isPillVisible: Bool {
        return isVisible
    }
}
