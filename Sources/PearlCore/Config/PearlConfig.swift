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
    public var mlxEnabled: Bool
    public var mlxModelID: String
    public var mlxIdleUnloadSeconds: Int
    public var allowedFolders: [String]
    public var quietHoursStart: Int
    public var quietHoursEnd: Int
    public var autoLeaveSeconds: Double
    public var activePersona: String
    public var vaultPath: String
    public var outputDirectoryPath: String
    public var subBotMaxConcurrency: Int
    public var firecrawlApiKey: String?
    public var launchAtLoginEnabled: Bool
    
    enum CodingKeys: String, CodingKey {
        case version, hotkey, socketPath, fastModelID, escalationModelID, modelProviderEndpoint, voiceLocale, preferredVoice, bargeInEnabled, pushToTalkDefault, maxContextTokens, memoryDirectory, monthlySpendCapUSD, maxTokensPerTurn, pccEnabled, mlxEnabled, mlxModelID, mlxIdleUnloadSeconds, allowedFolders, quietHoursStart, quietHoursEnd, autoLeaveSeconds
        case activePersona, vaultPath, outputDirectoryPath, subBotMaxConcurrency, firecrawlApiKey, launchAtLoginEnabled
    }
    
    public static let currentVersion = "3.3.0"
    
    public init(
        version: String = PearlConfig.currentVersion,
        hotkey: String = "ctrl+opt+space",
        socketPath: String = PearlStoragePaths.fileURL(named: "pearl.sock").path,
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
        pccEnabled: Bool = false,
        mlxEnabled: Bool = false,
        mlxModelID: String = "mlx-community/Qwen2.5-1.5B-Instruct-4bit",
        mlxIdleUnloadSeconds: Int = 30,
        allowedFolders: [String] = ["~/Documents", "~/Downloads", "~/Desktop", "~/Projects"],
        quietHoursStart: Int = 22,
        quietHoursEnd: Int = 8,
        autoLeaveSeconds: Double = 4.0,
        activePersona: String = "executive",
        vaultPath: String = ("~/Documents/PearlVault" as NSString).expandingTildeInPath,
        outputDirectoryPath: String = ("~/Documents/PearlOutput" as NSString).expandingTildeInPath,
        subBotMaxConcurrency: Int = 4,
        firecrawlApiKey: String? = nil,
        launchAtLoginEnabled: Bool = false
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
        self.mlxEnabled = mlxEnabled
        self.mlxModelID = mlxModelID
        self.mlxIdleUnloadSeconds = mlxIdleUnloadSeconds
        self.allowedFolders = allowedFolders
        self.quietHoursStart = quietHoursStart
        self.quietHoursEnd = quietHoursEnd
        self.autoLeaveSeconds = autoLeaveSeconds
        self.activePersona = activePersona
        self.vaultPath = vaultPath
        self.outputDirectoryPath = outputDirectoryPath
        self.subBotMaxConcurrency = subBotMaxConcurrency
        self.firecrawlApiKey = firecrawlApiKey
        self.launchAtLoginEnabled = launchAtLoginEnabled
    }
    
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.version = try container.decodeIfPresent(String.self, forKey: .version) ?? PearlConfig.currentVersion
        self.hotkey = try container.decodeIfPresent(String.self, forKey: .hotkey) ?? "ctrl+opt+space"
        self.socketPath = try container.decodeIfPresent(String.self, forKey: .socketPath) ?? PearlStoragePaths.fileURL(named: "pearl.sock").path
        self.fastModelID = try container.decodeIfPresent(String.self, forKey: .fastModelID) ?? "claude-haiku-5-5"
        self.escalationModelID = try container.decodeIfPresent(String.self, forKey: .escalationModelID) ?? "claude-sonnet-5-5"
        self.modelProviderEndpoint = try container.decodeIfPresent(String.self, forKey: .modelProviderEndpoint) ?? "https://api.anthropic.com/v1/messages"
        self.voiceLocale = try container.decodeIfPresent(String.self, forKey: .voiceLocale) ?? "en-GB"
        self.preferredVoice = try container.decodeIfPresent(String.self, forKey: .preferredVoice) ?? "Daniel"
        self.bargeInEnabled = try container.decodeIfPresent(Bool.self, forKey: .bargeInEnabled) ?? true
        self.pushToTalkDefault = try container.decodeIfPresent(Bool.self, forKey: .pushToTalkDefault) ?? true
        self.maxContextTokens = try container.decodeIfPresent(Int.self, forKey: .maxContextTokens) ?? 4096
        self.memoryDirectory = try container.decodeIfPresent(String.self, forKey: .memoryDirectory) ?? ("~/.pearl/memory" as NSString).expandingTildeInPath
        self.monthlySpendCapUSD = try container.decodeIfPresent(Double.self, forKey: .monthlySpendCapUSD) ?? 10.0
        self.maxTokensPerTurn = try container.decodeIfPresent(Int.self, forKey: .maxTokensPerTurn) ?? 4096
        self.pccEnabled = try container.decodeIfPresent(Bool.self, forKey: .pccEnabled) ?? false
        self.mlxEnabled = try container.decodeIfPresent(Bool.self, forKey: .mlxEnabled) ?? false
        self.mlxModelID = try container.decodeIfPresent(String.self, forKey: .mlxModelID) ?? "mlx-community/Qwen2.5-1.5B-Instruct-4bit"
        self.mlxIdleUnloadSeconds = try container.decodeIfPresent(Int.self, forKey: .mlxIdleUnloadSeconds) ?? 30
        self.allowedFolders = try container.decodeIfPresent([String].self, forKey: .allowedFolders) ?? ["~/Documents", "~/Downloads", "~/Desktop", "~/Projects"]
        self.quietHoursStart = try container.decodeIfPresent(Int.self, forKey: .quietHoursStart) ?? 22
        self.quietHoursEnd = try container.decodeIfPresent(Int.self, forKey: .quietHoursEnd) ?? 8
        self.autoLeaveSeconds = try container.decodeIfPresent(Double.self, forKey: .autoLeaveSeconds) ?? 4.0
        self.activePersona = try container.decodeIfPresent(String.self, forKey: .activePersona) ?? "executive"
        self.vaultPath = try container.decodeIfPresent(String.self, forKey: .vaultPath) ?? ("~/Documents/PearlVault" as NSString).expandingTildeInPath
        self.outputDirectoryPath = try container.decodeIfPresent(String.self, forKey: .outputDirectoryPath) ?? ("~/Documents/PearlOutput" as NSString).expandingTildeInPath
        self.subBotMaxConcurrency = try container.decodeIfPresent(Int.self, forKey: .subBotMaxConcurrency) ?? 4
        self.firecrawlApiKey = try container.decodeIfPresent(String.self, forKey: .firecrawlApiKey)
        self.launchAtLoginEnabled = try container.decodeIfPresent(Bool.self, forKey: .launchAtLoginEnabled) ?? false
    }
    
    public static var defaultConfigurationDirectory: URL {
        return PearlStoragePaths.supportDirectory
    }
    
    public static var defaultConfigFileURL: URL {
        return defaultConfigurationDirectory.appendingPathComponent("config.json")
    }
    
    public static func load() -> PearlConfig {
        let fileURL = defaultConfigFileURL
        guard let data = try? Data(contentsOf: fileURL),
              var config = try? JSONDecoder().decode(PearlConfig.self, from: data) else {
            let defaultConfig = PearlConfig()
            defaultConfig.save()
            return defaultConfig
        }
        if config.version.compare(currentVersion, options: .numeric) == .orderedAscending {
            config.version = currentVersion
            config.save()
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
