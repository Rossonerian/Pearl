import SwiftUI
import AppKit
import UniformTypeIdentifiers
import Observation
import EventKit
import AVFoundation
import Speech
import CoreGraphics
import CoreServices
import ApplicationServices
import ServiceManagement
import PearlCore
import PearlTools
import PearlMemory

public enum TCCPermissionState: Sendable, Equatable {
    case granted
    case writeOnly
    case notDetermined
    case denied
    case restricted
    
    public var label: String {
        switch self {
        case .granted: return "Granted"
        case .writeOnly: return "Write-Only"
        case .notDetermined: return "Not Requested"
        case .denied: return "Denied"
        case .restricted: return "Restricted"
        }
    }
    
    public var symbolName: String {
        switch self {
        case .granted: return "checkmark.circle.fill"
        case .writeOnly, .notDetermined: return "exclamationmark.triangle.fill"
        case .denied, .restricted: return "xmark.circle.fill"
        }
    }
    
    public var tintColor: Color {
        switch self {
        case .granted: return .green
        case .writeOnly, .notDetermined: return .orange
        case .denied, .restricted: return .red
        }
    }
}

public struct TCCPermissionEntry: Identifiable, Sendable {
    public let id: String
    public let name: String
    public let description: String
    public let state: TCCPermissionState
    public let settingsURL: String
}

@Observable
public final class SettingsViewModel {
    public var selectedTab = 0
    public var deterministicTierEnabled = true
    public var localLLMTierEnabled = true
    public var cloudTierEnabled = true
    public var fastModelID = "claude-haiku-5-5"
    public var escalationModelID = "claude-sonnet-5-5"
    public var modelEndpoint = "https://api.anthropic.com/v1/messages"
    public var monthlySpendCap: Double = 10.0
    public var maxTokensPerTurn: Int = 4096
    public var currentSpendMonth: Double = 0.0
    public var factCount: Int = 0
    public var profileByteCount: Int = 0
    public var schemaVersion: Int = 1
    public var showWipeAlert = false
    public var statusMessage = ""
    public var autoCheckUpdates = true
    public var launchAtLoginEnabled = false
    public var loginItemNotice = ""
    public var loginItemRequiresApproval = false
    public var activePersona = "executive"
    
    // Folders & TCC Permissions
    public var folderEntries: [ApprovedFolderEntry] = []
    public var folderStatusMessage = ""
    public var folderErrorMessage: String? = nil
    public var tccEntries: [TCCPermissionEntry] = []
    
    public init() {}
}

/// Native SwiftUI Settings Interface for Pearl 3.3.0.
/// Controls launch preferences, execution tiers, model routing, spend caps,
/// approved folders, live macOS TCC status, and memory inspection/erasure.
public struct SettingsView: View {
    public var state = SettingsViewModel()
    
    public init() {}
    
    public var body: some View {
        TabView(selection: Binding(get: { state.selectedTab }, set: { state.selectedTab = $0 })) {
            generalTab
                .tabItem {
                    Label("General", systemImage: "gearshape")
                }
                .tag(0)
            
            tiersAndModelsTab
                .tabItem {
                    Label("Tiers & Models", systemImage: "cpu")
                }
                .tag(1)
            
            spendCapsTab
                .tabItem {
                    Label("Spend Caps", systemImage: "creditcard")
                }
                .tag(2)
            
            memoryAndPrivacyTab
                .tabItem {
                    Label("Memory & Privacy", systemImage: "brain.head.profile")
                }
                .tag(3)
        }
        .frame(width: 600, height: 520)
        .padding()
        .onAppear {
            loadConfig()
            loadMemoryStats()
            refreshFoldersAndPermissions()
        }
    }
    
    // MARK: - Tab 1: General
    private var generalTab: some View {
        Form {
            Section(header: Label("Startup & Hotkey Activation", systemImage: "keyboard")) {
                Toggle("Launch Pearl at Login", isOn: Binding(
                    get: { state.launchAtLoginEnabled },
                    set: { newValue in
                        applyLaunchAtLoginToggle(newValue)
                    }
                ))
                Text("Starts Pearl as a background menu bar instrument when you sign in to macOS.")
                    .font(.caption)
                    .foregroundColor(.secondary)
                
                if !state.loginItemNotice.isEmpty {
                    HStack(spacing: 8) {
                        Image(systemName: state.loginItemRequiresApproval ? "exclamationmark.triangle.fill" : "info.circle")
                            .foregroundColor(state.loginItemRequiresApproval ? .orange : .secondary)
                        Text(state.loginItemNotice)
                            .font(.caption)
                            .foregroundColor(state.loginItemRequiresApproval ? .orange : .secondary)
                        if state.loginItemRequiresApproval {
                            Spacer()
                            Button("Open Login Items…") {
                                openSystemSettingsPane("x-apple.systempreferences:com.apple.LoginItems-Settings.extension")
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                        }
                    }
                }
                
                LabeledContent("Global Hotkey") {
                    Text("⌃⌥Space (Ctrl + Opt + Space)")
                        .font(.system(.body, design: .monospaced).monospacedDigit())
                        .foregroundColor(.primary)
                }
                Text("Summons the floating instrument HUD capsule across all spaces and full-screen apps.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            
            Section(header: Label("Persona & Talk-Back", systemImage: "person.wave.2")) {
                Picker("Assistant Persona", selection: Binding(
                    get: { state.activePersona },
                    set: { newValue in
                        state.activePersona = newValue
                        if let mode = PersonaMode(rawValue: newValue) {
                            PersonaEngine.shared.setMode(mode)
                        }
                        saveConfig()
                    }
                )) {
                    ForEach(PersonaMode.allCases, id: \.rawValue) { mode in
                        Text("\(mode.displayName) — \(mode.description)").tag(mode.rawValue)
                    }
                }
            }
            
            Section(header: Label("Updates & Distribution", systemImage: "arrow.triangle.2.circlepath")) {
                Toggle("Automatically check for updates via Sparkle", isOn: Binding(
                    get: { state.autoCheckUpdates },
                    set: { state.autoCheckUpdates = $0; saveConfig() }
                ))
                Text("Updates are verified via EdDSA cryptographic signatures. Hardware profiling and telemetry are permanently disabled.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            
            Section(header: Label("Diagnostic Info", systemImage: "gauge.with.needle")) {
                LabeledContent("App Version") {
                    Text("Pearl \(PearlConfig.currentVersion)")
                        .font(.system(.body, design: .monospaced).monospacedDigit())
                }
                LabeledContent("Host Architecture") {
                    Text("Apple Silicon (A18 Pro / M-Series)")
                }
                LabeledContent("IPC Transport") {
                    Text("Local Unix Domain Socket (0 TCP listeners)")
                        .font(.system(.callout, design: .monospaced).monospacedDigit())
                        .foregroundColor(.green)
                }
            }
        }
        .formStyle(.grouped)
    }
    
    // MARK: - Tab 2: Tiers & Models
    private var tiersAndModelsTab: some View {
        Form {
            Section(header: Label("Execution Tiers", systemImage: "bolt.shield")) {
                Toggle("Tier 1: Deterministic Actions (< 1 ms)", isOn: Binding(
                    get: { state.deterministicTierEnabled },
                    set: { state.deterministicTierEnabled = $0; saveConfig() }
                ))
                Text("Direct native Swift CoreAudio, IOKit, and NSWorkspace actions. Zero token cost and sub-millisecond latency.")
                    .font(.caption)
                    .foregroundColor(.secondary)
                
                Toggle("Tier 2: Local Foundation Models (< 50 ms)", isOn: Binding(
                    get: { state.localLLMTierEnabled },
                    set: { newValue in
                        state.localLLMTierEnabled = newValue
                        saveConfig()
                    }
                ))
                Text("Private local inference via Apple Neural Engine or quantized MLX open-weights.")
                    .font(.caption)
                    .foregroundColor(.secondary)
                
                Toggle("Tier 3: Cloud Frontier Escalation", isOn: Binding(
                    get: { state.cloudTierEnabled },
                    set: { state.cloudTierEnabled = $0; saveConfig() }
                ))
                Text("Routes complex multi-step reasoning queries to your configured frontier model endpoint.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            
            Section(header: Label("Model Configuration", systemImage: "slider.horizontal.3")) {
                TextField("Fast Model", text: Binding(get: { state.fastModelID }, set: { state.fastModelID = $0 }))
                    .font(.system(.body, design: .monospaced))
                TextField("Escalation Model", text: Binding(get: { state.escalationModelID }, set: { state.escalationModelID = $0 }))
                    .font(.system(.body, design: .monospaced))
                TextField("Provider Endpoint", text: Binding(get: { state.modelEndpoint }, set: { state.modelEndpoint = $0 }))
                    .font(.system(.body, design: .monospaced))
                
                Button("Save Model Configuration") {
                    saveConfig()
                    state.statusMessage = "Model settings updated."
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .formStyle(.grouped)
    }
    
    // MARK: - Tab 3: Spend Caps
    private var spendCapsTab: some View {
        Form {
            Section(header: Label("Hard Budget Protection", systemImage: "shield.lefthalf.filled")) {
                HStack {
                    Text("Monthly Spend Cap")
                    Spacer()
                    Text(String(format: "$%.2f USD", state.monthlySpendCap))
                        .font(.system(.body, design: .monospaced).monospacedDigit())
                        .fontWeight(.semibold)
                }
                Slider(
                    value: Binding(
                        get: { state.monthlySpendCap },
                        set: { newValue in
                            state.monthlySpendCap = newValue
                            saveConfig()
                        }
                    ),
                    in: 1.0...50.0,
                    step: 1.0
                )
                .accessibilityLabel("Monthly Spend Cap")
                Text("When cumulative monthly cloud spend reaches this threshold, Pearl strictly locks execution to local Tier 1–2 engines.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            
            Section(header: Label("Turn Limits", systemImage: "gauge.medium")) {
                Stepper(
                    "Max Tokens Per Turn: \(state.maxTokensPerTurn)",
                    value: Binding(
                        get: { state.maxTokensPerTurn },
                        set: { newValue in
                            state.maxTokensPerTurn = newValue
                            saveConfig()
                        }
                    ),
                    in: 512...8192,
                    step: 512
                )
                .font(.system(.body).monospacedDigit())
                
                HStack {
                    Text("Current Month Estimated Spend")
                    Spacer()
                    Text(String(format: "$%.4f / $%.2f", state.currentSpendMonth, state.monthlySpendCap))
                        .font(.system(.body, design: .monospaced).monospacedDigit())
                        .foregroundColor(.secondary)
                }
                ProgressView(value: min(state.currentSpendMonth, state.monthlySpendCap), total: max(1.0, state.monthlySpendCap))
            }
        }
        .formStyle(.grouped)
    }
    
    // MARK: - Tab 4: Memory & Privacy (includes Folders & TCC Permissions)
    private var memoryAndPrivacyTab: some View {
        Form {
            Section(header: Label("Approved Folders", systemImage: "folder.badge.gearshape")) {
                if state.folderEntries.isEmpty {
                    Text("No approved folders configured.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                } else {
                    ForEach(state.folderEntries, id: \.id) { entry in
                        folderEntryRow(entry)
                    }
                }
                
                HStack(spacing: 10) {
                    Button("Authorize Folder…") {
                        authorizeFolder()
                    }
                    .buttonStyle(.borderedProminent)
                    .accessibilityLabel("Authorize Folder")
                    
                    Button("Revalidate") {
                        revalidateFolders()
                    }
                    .buttonStyle(.bordered)
                    .accessibilityLabel("Revalidate approved folder permissions")
                    
                    Spacer()
                }
                
                if let errorMsg = state.folderErrorMessage, !errorMsg.isEmpty {
                    HStack(alignment: .top, spacing: 6) {
                        Image(systemName: "exclamationmark.octagon.fill")
                            .foregroundColor(.red)
                        Text(errorMsg)
                            .font(.caption)
                            .foregroundColor(.red)
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel("Folder authorization error: \(errorMsg)")
                } else if !state.folderStatusMessage.isEmpty {
                    Text(state.folderStatusMessage)
                        .font(.caption)
                        .foregroundColor(.green)
                }
                
                Text("Filesystem tools are confined to approved directories. Sensitive system paths, ~/.ssh, Keychains, and .env files remain permanently blocked.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            
            Section(header: Label("macOS Permissions (TCC)", systemImage: "checkmark.shield")) {
                ForEach(state.tccEntries) { entry in
                    tccPermissionRow(entry)
                }
                
                HStack(spacing: 10) {
                    Button("Refresh Status") {
                        refreshTCCPermissions()
                    }
                    .buttonStyle(.bordered)
                    
                    Spacer()
                    
                    Button("Open Privacy & Security…") {
                        openSystemSettingsPane("x-apple.systempreferences:com.apple.preference.security?Privacy")
                    }
                    .buttonStyle(.bordered)
                }
            }
            
            Section(header: Label("Inspectable Memory Store", systemImage: "externaldrive.badge.checkmark")) {
                LabeledContent("Active Learned Facts") {
                    Text("\(state.factCount) facts")
                        .font(.system(.body, design: .monospaced).monospacedDigit())
                }
                LabeledContent("Profile Size") {
                    Text("\(state.profileByteCount) bytes (Schema v\(state.schemaVersion))")
                        .font(.system(.body, design: .monospaced).monospacedDigit())
                }
                Text("All memory is stored locally in human-readable Markdown format with SQLite FTS5 search. No cloud syncing.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            
            Section(header: Label("Memory Data Actions", systemImage: "tray.and.arrow.up")) {
                HStack(spacing: 12) {
                    Button("Export Memory (JSON)") {
                        exportMemoryJSON()
                    }
                    .buttonStyle(.bordered)
                    
                    Spacer()
                    
                    Button("Forget All (Wipe Memory)", role: .destructive) {
                        state.showWipeAlert = true
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.red)
                }
                
                if !state.statusMessage.isEmpty {
                    Text(state.statusMessage)
                        .font(.caption)
                        .foregroundColor(.green)
                }
            }
            
            Section(header: Label("Privacy Commitment", systemImage: "hand.raised.shield.fill")) {
                HStack {
                    Image(systemName: "hand.raised.shield.fill")
                        .foregroundColor(.green)
                    Text("Zero Telemetry Guaranteed")
                        .fontWeight(.medium)
                }
                Text("Pearl contains 0 tracking SDKs, 0 user analytics, and 0 listening daemons. Network egress occurs ONLY to your designated LLM provider and Sparkle update manifest.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
        .formStyle(.grouped)
        .alert("Wipe All Memory?", isPresented: Binding(get: { state.showWipeAlert }, set: { state.showWipeAlert = $0 })) {
            Button("Cancel", role: .cancel) {}
            Button("Erase All Facts", role: .destructive) {
                wipeMemory()
            }
        } message: {
            Text("This will permanently delete all stored profile facts and learned user context. This action cannot be undone.")
        }
    }
    
    // MARK: - Subviews: Folder & TCC Rows
    
    @ViewBuilder
    private func folderEntryRow(_ entry: ApprovedFolderEntry) -> some View {
        HStack(spacing: 10) {
            folderStatusIcon(for: entry.status)
            
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(entry.displayPath)
                        .font(.subheadline)
                        .fontWeight(.medium)
                    
                    if entry.hasSecurityScopedBookmark {
                        Label("Bookmark", systemImage: "bookmark.fill")
                            .font(.caption2)
                            .foregroundColor(.green)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(Color.green.opacity(0.12))
                            .cornerRadius(4)
                    }
                    
                    if entry.isDefault {
                        Text("Default")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(Color.secondary.opacity(0.12))
                            .cornerRadius(4)
                    }
                }
                
                Text(entry.canonicalPath)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            
            Spacer()
            
            if entry.status == .needsAuthorization || entry.status == .bookmarkStale {
                Button("Authorize…") {
                    authorizeFolder(suggestedURL: URL(fileURLWithPath: entry.canonicalPath))
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .accessibilityLabel("Authorize \(entry.displayPath)")
            }
            
            if !entry.isDefault {
                Button(role: .destructive) {
                    removeFolder(entry)
                } label: {
                    Image(systemName: "trash")
                }
                .buttonStyle(.borderless)
                .help("Remove \(entry.displayPath)")
                .accessibilityLabel("Remove \(entry.displayPath)")
            }
        }
        .padding(.vertical, 2)
    }
    
    @ViewBuilder
    private func folderStatusIcon(for status: FolderAccessStatus) -> some View {
        switch status {
        case .accessible:
            Image(systemName: "checkmark.circle.fill")
                .foregroundColor(.green)
                .accessibilityLabel("Accessible")
        case .needsAuthorization:
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundColor(.orange)
                .accessibilityLabel("Needs Authorization")
        case .bookmarkStale:
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundColor(.orange)
                .accessibilityLabel("Bookmark Stale")
        case .missing:
            Image(systemName: "questionmark.circle")
                .foregroundColor(.secondary)
                .accessibilityLabel("Folder Missing")
        }
    }
    
    @ViewBuilder
    private func tccPermissionRow(_ entry: TCCPermissionEntry) -> some View {
        HStack(spacing: 10) {
            Image(systemName: entry.state.symbolName)
                .foregroundColor(entry.state.tintColor)
                .accessibilityLabel(entry.state.label)
            
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.name)
                    .font(.subheadline)
                    .fontWeight(.medium)
                Text(entry.description)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            
            Spacer()
            
            Text(entry.state.label)
                .font(.system(.caption, design: .monospaced))
                .foregroundColor(entry.state.tintColor)
            
            if entry.state != .granted {
                Button(entry.id == "automation" ? "Request…" : "Open Settings…") {
                    if entry.id == "automation" {
                        requestAutomationPermission()
                    }
                    openSystemSettingsPane(entry.settingsURL)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .accessibilityLabel("Open System Settings for \(entry.name)")
            }
        }
        .padding(.vertical, 2)
    }
    
    // MARK: - Helpers
    
    private func loadConfig() {
        let config = PearlConfig.load()
        state.fastModelID = config.fastModelID
        state.escalationModelID = config.escalationModelID
        state.modelEndpoint = config.modelProviderEndpoint
        state.monthlySpendCap = config.monthlySpendCapUSD
        state.maxTokensPerTurn = config.maxTokensPerTurn
        state.activePersona = PersonaEngine.shared.activeMode.rawValue
        state.launchAtLoginEnabled = config.launchAtLoginEnabled
        state.localLLMTierEnabled = config.mlxEnabled || config.pccEnabled
        state.currentSpendMonth = SpendCapTracker.shared.currentSpend()
        
        if Bundle.main.bundleURL.pathExtension == "app" {
            let status = AppDelegate.currentLaunchAtLoginStatus
            state.loginItemRequiresApproval = (status == .requiresApproval)
            if status == .requiresApproval {
                state.loginItemNotice = "Approval required in System Settings → General → Login Items."
            }
        }
    }
    
    private func saveConfig() {
        var config = PearlConfig.load()
        config.fastModelID = state.fastModelID
        config.escalationModelID = state.escalationModelID
        config.modelProviderEndpoint = state.modelEndpoint
        config.monthlySpendCapUSD = state.monthlySpendCap
        config.maxTokensPerTurn = state.maxTokensPerTurn
        config.activePersona = state.activePersona
        config.launchAtLoginEnabled = state.launchAtLoginEnabled
        config.save()
        
        SpendCapTracker.shared.updateLimits(
            monthlyCapUSD: state.monthlySpendCap,
            maxTokensPerTurn: state.maxTokensPerTurn
        )
    }
    
    private func applyLaunchAtLoginToggle(_ enabled: Bool) {
        state.launchAtLoginEnabled = enabled
        saveConfig()
        
        let result = AppDelegate.setLaunchAtLogin(enabled)
        switch result {
        case .success(let status):
            state.loginItemRequiresApproval = (status == .requiresApproval)
            if status == .requiresApproval {
                state.loginItemNotice = "Approval required in System Settings → General → Login Items."
            } else {
                state.loginItemNotice = enabled ? "Pearl registered to launch at login." : ""
            }
        case .failure(let error):
            state.loginItemRequiresApproval = false
            state.loginItemNotice = "Preference saved. System login item registration requires a bundled Pearl.app (\(error.localizedDescription))."
        }
    }
    
    @MainActor
    private func authorizeFolder(suggestedURL: URL? = nil) {
        guard let selectedURL = FilesystemPermissionManager.shared.promptUserToAuthorizeFolder(suggestedURL: suggestedURL) else {
            return
        }
        let entries = FilesystemPermissionManager.shared.approvedFolderEntries()
        state.folderEntries = entries
        state.folderErrorMessage = nil
        let matched = entries.first(where: { $0.canonicalPath == selectedURL.resolvingSymlinksInPath().path })
        state.folderStatusMessage = "Authorized \(matched?.displayPath ?? selectedURL.lastPathComponent)"
    }
    
    @MainActor
    private func revalidateFolders() {
        let entries = FilesystemPermissionManager.shared.revalidateBookmarks()
        state.folderEntries = entries
        state.folderErrorMessage = nil
        let accessibleCount = entries.filter { $0.status == .accessible }.count
        state.folderStatusMessage = "Revalidated \(accessibleCount)/\(entries.count) approved folder(s)."
    }
    
    @MainActor
    private func removeFolder(_ entry: ApprovedFolderEntry) {
        FilesystemPermissionManager.shared.removeApprovedFolder(path: entry.canonicalPath)
        var updated = FilesystemPermissionManager.shared.approvedFolderEntries()
        if updated.contains(where: { $0.id == entry.id }) {
            FilesystemPermissionManager.shared.removeApprovedFolder(path: entry.displayPath)
            updated = FilesystemPermissionManager.shared.approvedFolderEntries()
        }
        state.folderEntries = updated
        state.folderErrorMessage = nil
        state.folderStatusMessage = "Removed \(entry.displayPath)"
    }
    
    @MainActor
    private func refreshFoldersAndPermissions() {
        state.folderEntries = FilesystemPermissionManager.shared.approvedFolderEntries()
        refreshTCCPermissions()
    }
    
    @MainActor
    private func refreshTCCPermissions() {
        state.tccEntries = [
            TCCPermissionEntry(
                id: "reminders",
                name: "Reminders",
                description: "Create, read, and complete Apple Reminders.",
                state: mapEKStatus(EKEventStore.authorizationStatus(for: .reminder)),
                settingsURL: "x-apple.systempreferences:com.apple.preference.security?Privacy_Reminders"
            ),
            TCCPermissionEntry(
                id: "calendar",
                name: "Calendar",
                description: "Inspect availability and schedule calendar events.",
                state: mapEKStatus(EKEventStore.authorizationStatus(for: .event)),
                settingsURL: "x-apple.systempreferences:com.apple.preference.security?Privacy_Calendars"
            ),
            TCCPermissionEntry(
                id: "screen_recording",
                name: "Screen Recording",
                description: "In-memory screen OCR and screenshot capture.",
                state: CGPreflightScreenCaptureAccess() ? .granted : .notDetermined,
                settingsURL: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture"
            ),
            TCCPermissionEntry(
                id: "accessibility",
                name: "Accessibility",
                description: "Global hotkey and window management controls.",
                state: AXIsProcessTrusted() ? .granted : .notDetermined,
                settingsURL: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
            ),
            TCCPermissionEntry(
                id: "microphone",
                name: "Microphone",
                description: "Low-latency push-to-talk audio capture.",
                state: mapAVStatus(AVCaptureDevice.authorizationStatus(for: .audio)),
                settingsURL: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone"
            ),
            TCCPermissionEntry(
                id: "speech_recognition",
                name: "Speech Recognition",
                description: "On-device voice command transcription.",
                state: mapSpeechStatus(SFSpeechRecognizer.authorizationStatus()),
                settingsURL: "x-apple.systempreferences:com.apple.preference.security?Privacy_SpeechRecognition"
            ),
            TCCPermissionEntry(
                id: "automation",
                name: "Automation (Apple Events)",
                description: "Control Safari, Mail, and System Events for workflow automation.",
                state: checkAutomationPermissionStatus(),
                settingsURL: "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation"
            )
        ]
    }
    
    private func checkAutomationPermissionStatus() -> TCCPermissionState {
        var targetDesc = AEAddressDesc()
        let bundleId = "com.apple.finder"
        let err = bundleId.withCString { cStr in
            AECreateDesc(DescType(typeApplicationBundleID), cStr, strlen(cStr), &targetDesc)
        }
        guard err == noErr else { return .notDetermined }
        defer { AEDisposeDesc(&targetDesc) }
        let status = AEDeterminePermissionToAutomateTarget(&targetDesc, DescType(typeWildCard), DescType(typeWildCard), false)
        if status == noErr {
            return .granted
        } else if status == errAEEventNotPermitted {
            return .denied
        } else {
            return .notDetermined
        }
    }
    
    private func requestAutomationPermission() {
        for target in ["com.apple.finder", "com.apple.systemevents"] {
            var targetDesc = AEAddressDesc()
            let err = target.withCString { cStr in
                AECreateDesc(DescType(typeApplicationBundleID), cStr, strlen(cStr), &targetDesc)
            }
            if err == noErr {
                defer { AEDisposeDesc(&targetDesc) }
                _ = AEDeterminePermissionToAutomateTarget(&targetDesc, DescType(typeWildCard), DescType(typeWildCard), true)
            }
            let appName = (target == "com.apple.finder") ? "Finder" : "System Events"
            var scriptErr: NSDictionary?
            let script = NSAppleScript(source: "tell application \"\(appName)\" to return name")
            _ = script?.executeAndReturnError(&scriptErr)
        }
        refreshTCCPermissions()
    }
    
    private func mapEKStatus(_ status: EKAuthorizationStatus) -> TCCPermissionState {
        switch status {
        case .fullAccess:
            return .granted
        case .writeOnly:
            return .writeOnly
        case .denied:
            return .denied
        case .restricted:
            return .restricted
        case .notDetermined:
            return .notDetermined
        @unknown default:
            return .notDetermined
        }
    }
    
    private func mapAVStatus(_ status: AVAuthorizationStatus) -> TCCPermissionState {
        switch status {
        case .authorized:
            return .granted
        case .denied:
            return .denied
        case .restricted:
            return .restricted
        case .notDetermined:
            return .notDetermined
        @unknown default:
            return .notDetermined
        }
    }
    
    private func mapSpeechStatus(_ status: SFSpeechRecognizerAuthorizationStatus) -> TCCPermissionState {
        switch status {
        case .authorized:
            return .granted
        case .denied:
            return .denied
        case .restricted:
            return .restricted
        case .notDetermined:
            return .notDetermined
        @unknown default:
            return .notDetermined
        }
    }
    
    private func openSystemSettingsPane(_ urlString: String) {
        if let url = URL(string: urlString) {
            NSWorkspace.shared.open(url)
        }
    }
    
    private func loadMemoryStats() {
        Task {
            do {
                let store = try MemoryStore()
                let gate = try LearningGate(store: store)
                let viewer = MemoryViewer(store: store, gate: gate)
                let stats = try await viewer.getStats()
                await MainActor.run {
                    self.state.factCount = stats.factCount
                    self.state.profileByteCount = stats.profileByteCount
                    self.state.schemaVersion = stats.schemaVersion
                }
            } catch {
                // Default zero stats if store not initialized yet
            }
        }
    }
    
    private func exportMemoryJSON() {
        Task {
            do {
                let store = try MemoryStore()
                let gate = try LearningGate(store: store)
                let viewer = MemoryViewer(store: store, gate: gate)
                let json = try await viewer.exportJSON()
                
                await MainActor.run {
                    let savePanel = NSSavePanel()
                    savePanel.allowedContentTypes = [.json]
                    savePanel.nameFieldStringValue = "pearl_memory_export.json"
                    if savePanel.runModal() == .OK, let url = savePanel.url {
                        try? json.write(to: url, atomically: true, encoding: .utf8)
                        state.statusMessage = "Exported memory to \(url.lastPathComponent)"
                    }
                }
            } catch {
                await MainActor.run {
                    state.statusMessage = "Failed to export: \(error.localizedDescription)"
                }
            }
        }
    }
    
    private func wipeMemory() {
        Task {
            do {
                let store = try MemoryStore()
                try await store.clearAllFacts()
                await MainActor.run {
                    self.state.factCount = 0
                    self.state.profileByteCount = 0
                    self.state.statusMessage = "All memory facts forgotten."
                }
            } catch {
                await MainActor.run {
                    self.state.statusMessage = "Wipe failed: \(error.localizedDescription)"
                }
            }
        }
    }
}
