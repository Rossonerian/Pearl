import AppKit
import Carbon

public final class CarbonHotkeyManager {
    public static let shared = CarbonHotkeyManager()
    
    private var hotKeyRef: EventHotKeyRef?
    private var eventHandlerRef: EventHandlerRef?
    public var onHotKeyTriggered: (() -> Void)?
    
    private init() {}
    
    public func registerDefaultHotkey() {
        // Ctrl + Option + Space
        // kVK_Space = 0x31 (49)
        // controlKey = (1 << 12) = 4096
        // optionKey = (1 << 11) = 2048
        registerHotkey(keyCode: UInt32(kVK_Space), modifiers: UInt32(controlKey | optionKey))
    }
    
    public func registerHotkey(keyCode: UInt32, modifiers: UInt32) {
        unregisterHotkey()
        
        var hotKeyID = EventHotKeyID()
        hotKeyID.signature = OSType(0x50524C31) // 'PRL1'
        hotKeyID.id = 1
        
        let hotKeyStatus = RegisterEventHotKey(
            keyCode,
            modifiers,
            hotKeyID,
            GetApplicationEventTarget(),
            0,
            &hotKeyRef
        )
        
        if hotKeyStatus != noErr {
            NSLog("[CarbonHotkeyManager] Failed to register Carbon hotkey, status: %d", hotKeyStatus)
            return
        }
        
        var eventType = EventTypeSpec()
        eventType.eventClass = OSType(kEventClassKeyboard)
        eventType.eventKind = OSType(kEventHotKeyPressed)
        
        let handlerUPP: EventHandlerUPP = { (_, inEvent, _) -> OSStatus in
            CarbonHotkeyManager.shared.onHotKeyTriggered?()
            return noErr
        }
        
        let handlerStatus = InstallEventHandler(
            GetApplicationEventTarget(),
            handlerUPP,
            1,
            &eventType,
            nil,
            &eventHandlerRef
        )
        
        if handlerStatus != noErr {
            NSLog("[CarbonHotkeyManager] Failed to install event handler, status: %d", handlerStatus)
        }
    }
    
    public func unregisterHotkey() {
        if let ref = hotKeyRef {
            UnregisterEventHotKey(ref)
            hotKeyRef = nil
        }
        if let ref = eventHandlerRef {
            RemoveEventHandler(ref)
            eventHandlerRef = nil
        }
    }
    
    deinit {
        unregisterHotkey()
    }
}
