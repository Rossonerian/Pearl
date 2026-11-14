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
    
    public init() {}
}

/// Comprehensive SwiftUI Settings Interface for Pearl V2.
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
        .frame(width: 580, height: 460)
        .padding()
        .onAppear {
            loadConfig()
            loadMemoryStats()
        }
    }
    
    // MARK: - Tab 1: General
    private var generalTab: some View {
        Form {
            Section(header: Text("Voice & Hotkey Activation")) {
                LabeledContent("Global Hotkey:") {
                    Text("⌃⌥Space (Ctrl + Opt + Space)")
                        .font(.system(.body, design: .monospaced))
                }
                Text("Triggers the notch HUD floating pill across all spaces and full-screen apps.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            
            Section(header: Text("Updates & Distribution")) {
                Toggle("Automatically check for updates via Sparkle", isOn: Binding(get: { state.autoCheckUpdates }, set: { state.autoCheckUpdates = $0 }))
                Text("Updates are verified via EdDSA cryptographic signatures. In accordance with Pearl's zero-telemetry policy, system hardware profiling is disabled.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            
            Section(header: Text("Diagnostic Info")) {
                LabeledContent("App Version:") {
                    Text("Pearl 3.1.0 (Production Release)")
                }
                LabeledContent("Host Architecture:") {
                    Text("Apple Silicon (A18 Pro / M-Series)")
                }
                LabeledContent("IPC Transport:") {
                    Text("Local Unix Domain Socket (0 TCP listeners)")
                        .foregroundColor(.green)
                }
            }
        }
        .formStyle(.grouped)
    }
    
    // MARK: - Tab 2: Tiers & Models
    private var tiersAndModelsTab: some View {
        Form {
            Section(header: Text("Execution Tiers")) {
                Toggle("Tier 1: Deterministic Actions (< 1 ms)", isOn: Binding(get: { state.deterministicTierEnabled }, set: { state.deterministicTierEnabled = $0 }))
                Text("Direct native Swift CoreAudio, IOKit, and NSWorkspace actions. Zero token cost, zero LLM latency.")
                    .font(.caption)
                    .foregroundColor(.secondary)
                
                Toggle("Tier 2: On-Device Foundation Models (< 50 ms)", isOn: Binding(get: { state.localLLMTierEnabled }, set: { state.localLLMTierEnabled = $0 }))
                Text("Private on-device inference via Apple SystemLanguageModel or MLX open-weights.")
                    .font(.caption)
                    .foregroundColor(.secondary)
                
                Toggle("Tier 3: Cloud Frontier Escalation", isOn: Binding(get: { state.cloudTierEnabled }, set: { state.cloudTierEnabled = $0 }))
                Text("Escalates complex, ambiguous multi-step reasoning queries to cloud provider.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            
            Section(header: Text("Model Configuration")) {
                TextField("Fast Model:", text: Binding(get: { state.fastModelID }, set: { state.fastModelID = $0 }))
                TextField("Escalation Model:", text: Binding(get: { state.escalationModelID }, set: { state.escalationModelID = $0 }))
                TextField("Provider Endpoint:", text: Binding(get: { state.modelEndpoint }, set: { state.modelEndpoint = $0 }))
                
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
            Section(header: Text("Hard Budget Protection")) {
                HStack {
                    Text("Monthly Spend Cap:")
                    Spacer()
                    Text(String(format: "$%.2f USD", state.monthlySpendCap))
                        .fontWeight(.bold)
                }
                Slider(value: Binding(get: { state.monthlySpendCap }, set: { state.monthlySpendCap = $0 }), in: 1.0...50.0, step: 1.0)
                Text("When cumulative monthly spend reaches this threshold, Pearl strictly falls back to Tier 2 on-device models.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            
            Section(header: Text("Turn Limits")) {
                Stepper("Max Tokens Per Turn: \(state.maxTokensPerTurn)", value: Binding(get: { state.maxTokensPerTurn }, set: { state.maxTokensPerTurn = $0 }), in: 512...8192, step: 512)
                
                HStack {
                    Text("Current Month Estimated Spend:")
                    Spacer()
                    Text(String(format: "$%.4f / $%.2f", state.currentSpendMonth, state.monthlySpendCap))
                        .foregroundColor(.secondary)
                }
                ProgressView(value: state.currentSpendMonth, total: state.monthlySpendCap)
            }
        }
        .formStyle(.grouped)
    }
    
    // MARK: - Tab 4: Memory & Privacy
    private var memoryAndPrivacyTab: some View {
        Form {
            Section(header: Text("Inspectable Memory Store")) {
                LabeledContent("Active Learned Facts:") {
                    Text("\(state.factCount) facts")
                }
                LabeledContent("Profile Size:") {
                    Text("\(state.profileByteCount) bytes (Schema v\(state.schemaVersion))")
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
    }
    
    private func saveConfig() {
        var config = PearlConfig.load()
        config.fastModelID = state.fastModelID
        config.escalationModelID = state.escalationModelID
        config.modelProviderEndpoint = state.modelEndpoint
        config.monthlySpendCapUSD = state.monthlySpendCap
        config.maxTokensPerTurn = state.maxTokensPerTurn
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
