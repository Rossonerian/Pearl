import AppKit
import PearlCore

public final class StatusItemController: NSObject, NSMenuDelegate {
    private var statusItem: NSStatusItem?
    private var personaMenuItems: [PersonaMode: NSMenuItem] = [:]
    public var onToggleHUD: (() -> Void)?
    public var onSettingsRequested: (() -> Void)?
    public var onOnboardingRequested: (() -> Void)?
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
        menu.delegate = self
        
        let titleItem = NSMenuItem(title: "Pearl 3.3.0", action: nil, keyEquivalent: "")
        titleItem.isEnabled = false
        titleItem.image = NSImage(systemSymbolName: "waveform", accessibilityDescription: nil)
        menu.addItem(titleItem)
        
        menu.addItem(NSMenuItem.separator())
        
        let toggleItem = NSMenuItem(title: "Toggle HUD (⌃⌥Space)", action: #selector(toggleHUDClicked), keyEquivalent: "")
        toggleItem.image = NSImage(systemSymbolName: "macwindow", accessibilityDescription: nil)
        toggleItem.target = self
        menu.addItem(toggleItem)
        
        // Persona Quick Switcher Submenu
        let personaParent = NSMenuItem(title: "Persona", action: nil, keyEquivalent: "")
        personaParent.image = NSImage(systemSymbolName: "person.wave.2", accessibilityDescription: nil)
        let personaSubmenu = NSMenu()
        personaMenuItems.removeAll()
        for mode in PersonaMode.allCases {
            let item = NSMenuItem(title: mode.displayName, action: #selector(personaSelected(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = mode.rawValue
            item.toolTip = mode.description
            item.state = (PersonaEngine.shared.activeMode == mode) ? .on : .off
            personaSubmenu.addItem(item)
            personaMenuItems[mode] = item
        }
        personaParent.submenu = personaSubmenu
        menu.addItem(personaParent)
        
        menu.addItem(NSMenuItem.separator())
        
        let settingsItem = NSMenuItem(title: "Settings...", action: #selector(settingsClicked), keyEquivalent: ",")
        settingsItem.image = NSImage(systemSymbolName: "gearshape", accessibilityDescription: nil)
        settingsItem.target = self
        menu.addItem(settingsItem)
        
        let onboardingItem = NSMenuItem(title: "Setup Guide...", action: #selector(onboardingClicked), keyEquivalent: "")
        onboardingItem.image = NSImage(systemSymbolName: "checklist", accessibilityDescription: nil)
        onboardingItem.target = self
        menu.addItem(onboardingItem)
        
        menu.addItem(NSMenuItem.separator())
        
        let quitItem = NSMenuItem(title: "Quit Pearl", action: #selector(quitClicked), keyEquivalent: "q")
        quitItem.image = NSImage(systemSymbolName: "power", accessibilityDescription: nil)
        quitItem.target = self
        menu.addItem(quitItem)
        
        statusItem?.menu = menu
    }
    
    public func menuWillOpen(_ menu: NSMenu) {
        let active = PersonaEngine.shared.activeMode
        for (mode, item) in personaMenuItems {
            item.state = (mode == active) ? .on : .off
        }
    }
    
    @objc private func personaSelected(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String,
              let mode = PersonaMode(rawValue: raw) else { return }
        PersonaEngine.shared.setMode(mode)
        var config = PearlConfig.load()
        config.activePersona = mode.rawValue
        config.save()
        for (itemMode, item) in personaMenuItems {
            item.state = (itemMode == mode) ? .on : .off
        }
    }
    
    @objc private func toggleHUDClicked() {
        onToggleHUD?()
    }
    
    @objc private func settingsClicked() {
        onSettingsRequested?()
    }
    
    @objc private func onboardingClicked() {
        onOnboardingRequested?()
    }
    
    @objc private func quitClicked() {
        onQuitRequested?()
    }
}
