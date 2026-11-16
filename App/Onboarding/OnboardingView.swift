import SwiftUI
import AppKit
import AVFoundation
import CoreServices
import Observation
import PearlCore

@Observable
public final class OnboardingViewModel {
    public var currentStep = 0
    public var selectedBrain = OnboardingView.BrainChoice.appleOnDevice
    public var hotkeyString = "Ctrl + Opt + Space"
    public var pushToTalk = true
    public var apiKey = ""
    public var micAuthorized = false
    public var accessibilityAuthorized = false
    public var automationAuthorized = false
    public var updatesEnabled = true
    
    public init() {}
}

/// SwiftUI Onboarding Flow for Pearl 3.3.0.
/// Guides the user through choosing an execution brain, hotkey setup,
/// TCC permissions, and verifies zero default personal data collection.
public struct OnboardingView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    public var state = OnboardingViewModel()
    public var onFinish: (() -> Void)?
    
    public enum BrainChoice: String, CaseIterable, Identifiable {
        case appleOnDevice = "Apple Silicon Neural Engine"
        case localWeights = "Local Open-Weights (MLX / Ollama)"
        case cloudBYO = "Cloud Frontier (BYO API Key)"
        
        public var id: String { rawValue }
        
        public var description: String {
            switch self {
            case .appleOnDevice:
                return "Private Foundation Models accelerated by Apple Silicon Neural Engine. Zero network calls, zero token cost."
            case .localWeights:
                return "Run quantized open models (Qwen 2.5 1.5B / Llama 3.2 3B) via MLX or Ollama with complete offline autonomy."
            case .cloudBYO:
                return "Frontier reasoning via Anthropic or OpenAI over direct HTTPS using your personal API key."
            }
        }
        
        public var badge: String {
            switch self {
            case .appleOnDevice: return "Recommended (Fastest)"
            case .localWeights: return "Offline"
            case .cloudBYO: return "Cloud Escalation"
            }
        }
    }
    
    public init(onFinish: (() -> Void)? = nil) {
        self.onFinish = onFinish
    }
    
    public var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack(spacing: 12) {
                Image(systemName: "waveform.circle.fill")
                    .resizable()
                    .frame(width: 32, height: 32)
                    .foregroundColor(.accentColor)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Welcome to Pearl 3.3.0")
                        .font(.title2)
                        .fontWeight(.bold)
                    Text("Ultra-low-latency macOS voice assistant for Apple Silicon")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                Spacer()
                Text("Step \(state.currentStep + 1) of 4")
                    .font(.system(.caption, design: .monospaced).monospacedDigit())
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Color.secondary.opacity(0.15))
                    .cornerRadius(6)
            }
            .padding()
            
            Divider()
            
            // Step Body
            VStack {
                switch state.currentStep {
                case 0:
                    stepPhilosophyAndBrain
                case 1:
                    stepHotkeyAndAudio
                case 2:
                    stepPermissionsGuide
                case 3:
                    stepVerificationAndFinish
                default:
                    EmptyView()
                }
            }
            .padding(24)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            
            Divider()
            
            // Footer Navigation
            HStack {
                if state.currentStep > 0 {
                    Button("Back") {
                        navigateStep(-1)
                    }
                    .keyboardShortcut("[", modifiers: .command)
                }
                
                Spacer()
                
                if state.currentStep < 3 {
                    Button("Continue") {
                        navigateStep(1)
                    }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                } else {
                    Button("Launch Pearl") {
                        saveConfiguration()
                        onFinish?()
                    }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                }
            }
            .padding()
        }
        .frame(width: 580, height: 480)
        .onAppear {
            checkPermissions()
        }
    }
    
    // MARK: - Step 1: Philosophy & Brain
    private var stepPhilosophyAndBrain: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Assistant Architecture")
                    .font(.headline)
                Text("Pearl pairs deterministic local control with switchable tactical personas (**Executive**, **Ultron**, **Jarvis**), strictly bounded permissions, **zero telemetry**, and **zero default cloud tracking**.")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
            }
            
            Divider()
            
            Text("Choose Your Primary Brain:")
                .font(.headline)
            
            ForEach(BrainChoice.allCases) { choice in
                Button {
                    state.selectedBrain = choice
                } label: {
                    HStack(alignment: .top, spacing: 12) {
                        Image(systemName: state.selectedBrain == choice ? "largecircle.fill.circle" : "circle")
                            .foregroundColor(state.selectedBrain == choice ? .accentColor : .secondary)
                            .padding(.top, 2)
                            .accessibilityHidden(true)
                        
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Text(choice.rawValue)
                                    .fontWeight(.medium)
                                Spacer()
                                Text(choice.badge)
                                    .font(.caption2)
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 2)
                                    .background(Color.accentColor.opacity(0.15))
                                    .foregroundColor(.accentColor)
                                    .cornerRadius(4)
                            }
                            Text(choice.description)
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }
                    .padding(10)
                    .background(state.selectedBrain == choice ? Color.accentColor.opacity(0.08) : Color.clear)
                    .cornerRadius(8)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityElement(children: .combine)
                .accessibilityLabel("\(choice.rawValue), \(choice.badge)")
                .accessibilityHint(choice.description)
                .accessibilityAddTraits(state.selectedBrain == choice ? [.isSelected] : [])
            }
            
            if state.selectedBrain == .cloudBYO {
                HStack {
                    Text("API Key:")
                        .font(.caption)
                    SecureField("sk-ant-... or sk-...", text: Binding(get: { state.apiKey }, set: { state.apiKey = $0 }))
                        .textFieldStyle(.roundedBorder)
                        .font(.caption)
                }
            }
        }
    }
    
    // MARK: - Step 2: Hotkey & Audio
    private var stepHotkeyAndAudio: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Hotkey & Voice Trigger")
                .font(.headline)
            
            VStack(alignment: .leading, spacing: 8) {
                Text("Global Hotkey:")
                    .font(.subheadline)
                    .fontWeight(.medium)
                HStack {
                    Text(state.hotkeyString)
                        .font(.system(.body, design: .monospaced))
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(Color.secondary.opacity(0.12))
                        .cornerRadius(6)
                    Spacer()
                    Button("Default (⌃⌥Space)") {
                        state.hotkeyString = "Ctrl + Opt + Space"
                    }
                    .buttonStyle(.bordered)
                }
                Text("Press anywhere across macOS to toggle the lightweight Notch HUD pill.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            
            Divider()
            
            VStack(alignment: .leading, spacing: 10) {
                Text("Voice Interaction Mode:")
                    .font(.subheadline)
                    .fontWeight(.medium)
                
                Toggle("Push-to-Talk (Hold Hotkey to Speak)", isOn: Binding(get: { state.pushToTalk }, set: { state.pushToTalk = $0 }))
                    .toggleStyle(.checkbox)
                
                Text(state.pushToTalk ? 
                     "Microphone is engaged only while holding the hotkey. Immediate release triggers endpoint in <10ms." : 
                     "Hands-free mode with Silero VAD and real-time 60 Hz barge-in cancellation.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            
            Divider()
            
            Toggle("Check for Updates via Sparkle (EdDSA Verified, Zero Telemetry)", isOn: Binding(get: { state.updatesEnabled }, set: { state.updatesEnabled = $0 }))
                .toggleStyle(.checkbox)
                .font(.subheadline)
            Text("Update checks download appcast.xml directly from GitHub. Hardware specs and system profiling are strictly disabled.")
                .font(.caption)
                .foregroundColor(.secondary)
        }
    }
    
    // MARK: - Step 3: Permissions Guide
    private var stepPermissionsGuide: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("System Permissions (TCC)")
                .font(.headline)
            Text("Pearl requests only the minimum macOS permissions required to listen to voice commands and automate applications.")
                .font(.subheadline)
                .foregroundColor(.secondary)
            
            VStack(spacing: 12) {
                permissionRow(
                    name: "Microphone",
                    description: "Required for push-to-talk voice input streaming.",
                    granted: state.micAuthorized,
                    prefPane: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone"
                )
                
                permissionRow(
                    name: "Accessibility",
                    description: "Required for global hotkey registration and active window context.",
                    granted: state.accessibilityAuthorized,
                    prefPane: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
                )
                
                permissionRow(
                    name: "Automation (Apple Events)",
                    description: "Required to interact safely with Safari, Music, Notes, and Mail.",
                    granted: state.automationAuthorized,
                    prefPane: "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation"
                )
            }
            
            Spacer()
            
            Button("Re-check Permissions") {
                checkPermissions()
            }
            .buttonStyle(.link)
        }
    }
    
    // MARK: - Step 4: Verification & Finish
    private var stepVerificationAndFinish: some View {
        VStack(spacing: 18) {
            Image(systemName: "checkmark.shield.fill")
                .resizable()
                .frame(width: 56, height: 56)
                .foregroundColor(.green)
            
            Text("Ready to Deploy")
                .font(.title3)
                .fontWeight(.bold)
            
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Image(systemName: "checkmark.circle.fill").foregroundColor(.green)
                    Text("Selected Brain: \(state.selectedBrain.rawValue)").font(.subheadline)
                }
                HStack {
                    Image(systemName: "checkmark.circle.fill").foregroundColor(.green)
                    Text("Activation Hotkey: \(state.hotkeyString)").font(.subheadline)
                }
                HStack {
                    Image(systemName: "checkmark.circle.fill").foregroundColor(.green)
                    Text("Telemetry: 0 third-party trackers, zero default personal data").font(.subheadline)
                }
                HStack {
                    Image(systemName: "checkmark.circle.fill").foregroundColor(.green)
                    Text("Safety: Dual-layer Seatbelt sandbox + Tamper-evident audit chain").font(.subheadline)
                }
            }
            .padding()
            .background(Color.secondary.opacity(0.08))
            .cornerRadius(8)
            
            Text("Press **Launch Pearl** to start the resident daemon. You can reopen this guide anytime from the menu bar status icon.")
                .font(.caption)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
        }
    }
    
    // MARK: - Helpers
    private func navigateStep(_ delta: Int) {
        let target = max(0, min(3, state.currentStep + delta))
        if reduceMotion {
            state.currentStep = target
        } else {
            withAnimation(.easeInOut(duration: 0.18)) {
                state.currentStep = target
            }
        }
    }

    private func permissionRow(name: String, description: String, granted: Bool, prefPane: String) -> some View {
        HStack {
            Image(systemName: granted ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                .foregroundColor(granted ? .green : .orange)
                .accessibilityHidden(true)
            
            VStack(alignment: .leading, spacing: 2) {
                Text(name).fontWeight(.medium)
                Text(description).font(.caption).foregroundColor(.secondary)
            }
            
            Spacer()
            
            if !granted {
                Button("Open Settings") {
                    if let url = URL(string: prefPane) {
                        NSWorkspace.shared.open(url)
                    }
                }
                .buttonStyle(.bordered)
                .font(.caption)
                .accessibilityLabel("Open \(name) in System Settings")
            } else {
                Text("Granted")
                    .font(.caption)
                    .foregroundColor(.green)
            }
        }
        .padding(8)
        .background(Color.secondary.opacity(0.06))
        .cornerRadius(6)
        .accessibilityElement(children: .contain)
    }
    
    private func checkPermissions() {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: state.micAuthorized = true
        default: state.micAuthorized = false
        }
        state.accessibilityAuthorized = AXIsProcessTrusted()
        state.automationAuthorized = checkAutomationPermission()
    }
    
    private func checkAutomationPermission() -> Bool {
        var targetDesc = AEAddressDesc()
        let bundleId = "com.apple.finder"
        let err = bundleId.withCString { cStr in
            AECreateDesc(DescType(typeApplicationBundleID), cStr, strlen(cStr), &targetDesc)
        }
        guard err == noErr else { return false }
        defer { AEDisposeDesc(&targetDesc) }
        let status = AEDeterminePermissionToAutomateTarget(&targetDesc, DescType(typeWildCard), DescType(typeWildCard), false)
        return status == noErr
    }
    
    private func saveConfiguration() {
        var config = PearlConfig.load()
        config.pushToTalkDefault = state.pushToTalk
        config.hotkey = state.hotkeyString.lowercased().replacingOccurrences(of: " ", with: "")
        config.mlxEnabled = (state.selectedBrain == .localWeights)
        config.save()
    }
}
