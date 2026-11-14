import SwiftUI
import AppKit
import UniformTypeIdentifiers
import Observation
import PearlCore
import PearlMemory

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
    public var currentSpendMonth: Double = 0.42
    public var factCount: Int = 0
    public var profileByteCount: Int = 0
    public var schemaVersion: Int = 1
    public var showWipeAlert = false
    public var statusMessage = ""
    public var autoCheckUpdates = true
    public var activePersona = "executive"
    
    public init() {}
}

/// Native SwiftUI Settings Interface for Pearl 3.2.0.
/// Controls execution tiers, model routing, spend caps, memory export/erasure,
/// and security policy inspection.
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
        .frame(width: 600, height: 480)
        .padding()
        .onAppear {
            loadConfig()
            loadMemoryStats()
        }
    }
    
    // MARK: - Tab 1: General
    private var generalTab: some View {
        Form {
            Section(header: Label("Voice & Hotkey Activation", systemImage: "keyboard")) {
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
                Toggle("Automatically check for updates via Sparkle", isOn: Binding(get: { state.autoCheckUpdates }, set: { state.autoCheckUpdates = $0 }))
                Text("Updates are verified via EdDSA cryptographic signatures. Hardware profiling and telemetry are permanently disabled.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            
            Section(header: Label("Diagnostic Info", systemImage: "gauge.with.needle")) {
                LabeledContent("App Version") {
                    Text("Pearl 3.2.0 (Ultron Workflow)")
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
                Toggle("Tier 1: Deterministic Actions (< 1 ms)", isOn: Binding(get: { state.deterministicTierEnabled }, set: { state.deterministicTierEnabled = $0 }))
                Text("Direct native Swift CoreAudio, IOKit, and NSWorkspace actions. Zero token cost and sub-millisecond latency.")
                    .font(.caption)
                    .foregroundColor(.secondary)
                
                Toggle("Tier 2: Local Foundation Models (< 50 ms)", isOn: Binding(get: { state.localLLMTierEnabled }, set: { state.localLLMTierEnabled = $0 }))
                Text("Private local inference via Apple Neural Engine or quantized MLX open-weights.")
                    .font(.caption)
                    .foregroundColor(.secondary)
                
                Toggle("Tier 3: Cloud Frontier Escalation", isOn: Binding(get: { state.cloudTierEnabled }, set: { state.cloudTierEnabled = $0 }))
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
                Slider(value: Binding(get: { state.monthlySpendCap }, set: { state.monthlySpendCap = $0 }), in: 1.0...50.0, step: 1.0)
                Text("When cumulative monthly cloud spend reaches this threshold, Pearl strictly locks execution to local Tier 1–2 engines.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            
            Section(header: Label("Turn Limits", systemImage: "gauge.medium")) {
                Stepper("Max Tokens Per Turn: \(state.maxTokensPerTurn)", value: Binding(get: { state.maxTokensPerTurn }, set: { state.maxTokensPerTurn = $0 }), in: 512...8192, step: 512)
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
    
    // MARK: - Tab 4: Memory & Privacy
    private var memoryAndPrivacyTab: some View {
        Form {
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
            
            Section(header: Text("Memory Data Actions")) {
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
            
            Section(header: Text("Privacy Commitment")) {
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
    
    // MARK: - Helpers
    private func loadConfig() {
        let config = PearlConfig.load()
        state.fastModelID = config.fastModelID
        state.escalationModelID = config.escalationModelID
        state.modelEndpoint = config.modelProviderEndpoint
        state.monthlySpendCap = config.monthlySpendCapUSD
        state.maxTokensPerTurn = config.maxTokensPerTurn
        state.activePersona = PersonaEngine.shared.activeMode.rawValue
    }
    
    private func saveConfig() {
        var config = PearlConfig.load()
        config.fastModelID = state.fastModelID
        config.escalationModelID = state.escalationModelID
        config.modelProviderEndpoint = state.modelEndpoint
        config.monthlySpendCapUSD = state.monthlySpendCap
        config.maxTokensPerTurn = state.maxTokensPerTurn
        config.activePersona = state.activePersona
        config.save()
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
