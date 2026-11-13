import AppKit

public final class StatusItemController: NSObject {
    private var statusItem: NSStatusItem?
    public var onToggleHUD: (() -> Void)?
    public var onQuitRequested: (() -> Void)?
    
    public func setup() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        guard let button = statusItem?.button else { return }
        
        let config = NSImage.SymbolConfiguration(pointSize: 13, weight: .medium)
        if let image = NSImage(systemSymbolName: "waveform.circle.fill", accessibilityDescription: "Pearl")?.withSymbolConfiguration(config) {
            button.image = image
        } else {
            button.title = "●"
        }
        
        let menu = NSMenu()
        
        let titleItem = NSMenuItem(title: "Pearl (v2.0)", action: nil, keyEquivalent: "")
        titleItem.isEnabled = false
        menu.addItem(titleItem)
        
        menu.addItem(NSMenuItem.separator())
        
        let toggleItem = NSMenuItem(title: "Toggle HUD (⌃⌥Space)", action: #selector(toggleHUDClicked), keyEquivalent: "")
        toggleItem.target = self
        menu.addItem(toggleItem)
        
        menu.addItem(NSMenuItem.separator())
        
        let quitItem = NSMenuItem(title: "Quit Pearl", action: #selector(quitClicked), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)
        
        statusItem?.menu = menu
    }
    
    @objc private func toggleHUDClicked() {
        onToggleHUD?()
    }
    
    @objc private func quitClicked() {
        onQuitRequested?()
    }
}
