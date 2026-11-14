import Foundation

public final class KillSwitch: @unchecked Sendable {
    public static let shared = KillSwitch()
    
    private let lock = NSLock()
    private var _isAborted: Bool = false
    private var _triggerCount: Int = 0
    private var _lastReason: String? = nil
    private var _triggeredAt: Date? = nil
    private var handlers: [UUID: @Sendable (String) -> Void] = [:]
    
    public var isAborted: Bool {
        lock.lock()
        defer { lock.unlock() }
        return _isAborted
    }
    
    public var triggerCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return _triggerCount
    }
    
    public var lastReason: String? {
        lock.lock()
        defer { lock.unlock() }
        return _lastReason
    }
    
    public var triggeredAt: Date? {
        lock.lock()
        defer { lock.unlock() }
        return _triggeredAt
    }
    
    public init() {}
    
    public func trigger(reason: String = "Kill switch activated") {
        let callbacks: [@Sendable (String) -> Void]
        lock.lock()
        _isAborted = true
        _triggerCount += 1
        _lastReason = reason
        _triggeredAt = Date()
        callbacks = Array(handlers.values)
        lock.unlock()
        
        Task {
            await AuditLogger.shared.log(
                tool: "KillSwitch",
                args: ["reason": reason],
                tier: .t5RawShell,
                trustState: .trusted,
                success: true
            )
        }
        
        for handler in callbacks {
            handler(reason)
        }
    }
    
    public func reset() {
        lock.lock()
        defer { lock.unlock() }
        _isAborted = false
        _lastReason = nil
        _triggeredAt = nil
    }
    
    @discardableResult
    public func onTrigger(_ handler: @escaping @Sendable (String) -> Void) -> UUID {
        lock.lock()
        defer { lock.unlock() }
        let id = UUID()
        handlers[id] = handler
        return id
    }
    
    public func removeHandler(_ id: UUID) {
        lock.lock()
        defer { lock.unlock() }
        handlers.removeValue(forKey: id)
    }
}
