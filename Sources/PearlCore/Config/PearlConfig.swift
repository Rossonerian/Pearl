import Foundation

public struct PearlConfig: Codable, Sendable {
    public var version: String
    public var hotkey: String
    public var socketPath: String
    public var fastModelID: String
    public var escalationModelID: String
    public var modelProviderEndpoint: String
    public var voiceLocale: String
    public var preferredVoice: String
    public var bargeInEnabled: Bool
    public var pushToTalkDefault: Bool
    public var maxContextTokens: Int
    public var memoryDirectory: String
    public var monthlySpendCapUSD: Double
    public var maxTokensPerTurn: Int
    public var pccEnabled: Bool
    
    public init(
        version: String = "2.0.0",
        hotkey: String = "ctrl+opt+space",
        socketPath: String = ("~/Library/Application Support/Pearl/pearl.sock" as NSString).expandingTildeInPath,
        fastModelID: String = "claude-haiku-5-5",
        escalationModelID: String = "claude-sonnet-5-5",
        modelProviderEndpoint: String = "https://api.anthropic.com/v1/messages",
        voiceLocale: String = "en-GB",
        preferredVoice: String = "Daniel",
        bargeInEnabled: Bool = true,
        pushToTalkDefault: Bool = true,
        maxContextTokens: Int = 4096,
        memoryDirectory: String = ("~/.pearl/memory" as NSString).expandingTildeInPath,
        monthlySpendCapUSD: Double = 10.0,
        maxTokensPerTurn: Int = 4096,
        pccEnabled: Bool = false
    ) {
        self.version = version
        self.hotkey = hotkey
        self.socketPath = socketPath
        self.fastModelID = fastModelID
        self.escalationModelID = escalationModelID
        self.modelProviderEndpoint = modelProviderEndpoint
        self.voiceLocale = voiceLocale
        self.preferredVoice = preferredVoice
        self.bargeInEnabled = bargeInEnabled
        self.pushToTalkDefault = pushToTalkDefault
        self.maxContextTokens = maxContextTokens
        self.memoryDirectory = memoryDirectory
        self.monthlySpendCapUSD = monthlySpendCapUSD
        self.maxTokensPerTurn = maxTokensPerTurn
        self.pccEnabled = pccEnabled
    }
    
    public static var defaultConfigurationDirectory: URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return appSupport.appendingPathComponent("Pearl", isDirectory: true)
    }
    
    public static var defaultConfigFileURL: URL {
        return defaultConfigurationDirectory.appendingPathComponent("config.json")
    }
    
    public static func load() -> PearlConfig {
        let fileURL = defaultConfigFileURL
        guard let data = try? Data(contentsOf: fileURL),
              let config = try? JSONDecoder().decode(PearlConfig.self, from: data) else {
            let defaultConfig = PearlConfig()
            defaultConfig.save()
            return defaultConfig
        }
        return config
    }
    
    public func save() {
        let dir = PearlConfig.defaultConfigurationDirectory
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [
            .posixPermissions: 0o700
        ])
        let fileURL = PearlConfig.defaultConfigFileURL
        if let data = try? JSONEncoder().encode(self) {
            try? data.write(to: fileURL, options: .atomic)
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
        }
    }
}
