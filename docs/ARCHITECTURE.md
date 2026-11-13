# Pearl V2 Architecture Specification

Status: Active Architectural Blueprint  
Target Platform: macOS 27.2.1 "Golden Gate", Apple Silicon A18 Pro, 8 GB Unified Memory  
Revision: 2.0.0

---

## 1. System Topology & Process Model

Pearl V2 replaces the legacy multi-language shell runtime with a native, highly decomposed Swift architecture engineered specifically for 8 GB Apple Silicon Macs.

```
                      ┌────────────────────────────────────────┐
                      │              User Interface            │
                      │  - Status Item (NSStatusBar)           │
                      │  - Floating Pill HUD (NSPanel, 60 Hz)  │
                      │  - Carbon Hotkey (Ctrl+Opt+Space)      │
                      └──────────────────┬─────────────────────┘
                                         │
                                         ▼
┌────────────────────────────────────────────────────────────────────────────────────────┐
│                        Resident Process: Pearl.app (LSUIElement)                      │
│                                                                                        │
│   ┌────────────────────┐   ┌───────────────────────────┐   ┌───────────────────────┐   │
│   │   Audio Pipeline   │   │     Action & Policy       │   │    Storage & State    │   │
│   │ - Audio Capture    │   │ - Grammar/Slot Router     │   │ - Markdown Memory     │   │
│   │ - Silero VAD v6    │   │ - T0-T5 Policy Engine     │   │ - SQLite FTS5 Index   │   │
│   │ - SpeechAnalyzer   │   │ - Typed Tool Registry     │   │ - Undo Journal        │   │
│   │ - Push-To-Talk Mgr │   │ - Context Taint Tracker   │   │ - Hash-Chained Audit  │   │
│   └────────────────────┘   └───────────────────────────┘   └───────────────────────┘   │
│                                                                                        │
│   ┌────────────────────────────────────────────────────────────────────────────────┐   │
│   │                           Unix Domain Socket Server                            │   │
│   │              Path: ~/Library/Application Support/Pearl/pearl.sock              │   │
│   │              Permissions: 0700 (Owner-only access, zero TCP)                   │   │
│   └────────────────────────────────────────────────────────────────────────────────┘   │
└────────────────────────────┬───────────────────────────────────────────┬───────────────┘
                             │ Mach Messages (XPC)                       │ Unix Domain Socket
                             ▼                                           ▼
┌─────────────────────────────────────────────────────────┐  ┌───────────────────────────┐
│        On-Demand Helper: PearlInference.xpc             │  │        pearl-cli          │
│ - Sandboxed XPC service                                 │  │ - Terminal client         │
│ - Kokoro-82M Core ML TTS Engine                         │  │ - Stdio pipe to socket    │
│ - Optional Qwen 3.5 2B MLX LLM                          │  │ - Sub-15ms invocation     │
│ - Idle timeout: exits after 60s of inactivity           │  └───────────────────────────┘
│ - Memory Pressure Handler: unloads on .warning          │
└─────────────────────────────────────────────────────────┘
```

---

## 2. Memory & Footprint Allocations

On an 8 GB unified memory Mac running a browser and code editor, available memory for background services is strictly bounded.

| Subsystem | State | Target Footprint | Measured Hard Cap | Reclaim Strategy |
|---|---|---|---|---|
| **Pearl.app (Resident)** | Idle | <= 25 MB | 40 MB | AppKit lightweight views, zero WebKit |
| **Audio Capture + VAD** | Listening | ~5 MB | 10 MB | Silero v6 Core ML, single audio buffer |
| **SpeechAnalyzer STT** | Active Speech | ~40 MB | 100 MB | Streaming buffers freed on finalization |
| **PearlInference (TTS)**| Synthesizing | ~350 MB | 500 MB | Evicted after 60s idle timeout |
| **Apple Foundation Model**| Active Turn | ~500 MB | 1000 MB | Managed by OS Neural Engine subsystem |
| **Total Resident Footprint**| **Idle** | **<= 25 MB** | **40 MB** | **Process cleanly returns pages to OS** |

### Memory Pressure Compliance
Both `Pearl.app` and `PearlInference.xpc` register a `DispatchSourceMemoryPressure` event listener:
```swift
let memoryPressureSource = DispatchSource.makeMemoryPressureSource(
    eventMask: [.warning, .critical], 
    queue: .main
)
memoryPressureSource.setEventHandler {
    let event = memoryPressureSource.mask
    if event.contains(.warning) || event.contains(.critical) {
        InferenceCoordinator.shared.evictAllModelsImmediately()
    }
}
memoryPressureSource.resume()
```

---

## 3. Inter-Process Communication (IPC)

Pearl V2 completely deprecates the V1 HTTP server (`127.0.0.1:49200`). Local communication is implemented via:

1. **Unix Domain Socket**:
   - Location: `~/Library/Application Support/Pearl/pearl.sock`
   - Permissions: Directory `0700`, Socket `0600` owned by running user.
   - Protocol: Line-delimited JSON-RPC 2.0 over stream socket.
   - Message Format:
     ```json
     {"jsonrpc": "2.0", "id": 1, "method": "executeCommand", "params": {"query": "mute volume"}}
     ```
2. **Mach XPC Services**:
   - High-throughput Core ML inference runs inside `PearlInference.xpc`.
   - Uses `NSXPCConnection` with typed protocol interfaces and bidirectional progress streaming.

---

## 4. Typed Tool Registry Schema

Tools in Pearl V2 are strictly typed Swift structures adhering to the `PearlTool` protocol:

```swift
public enum ToolTier: Int, Codable, Comparable {
    case t0Observe = 0
    case t1Reversible = 1
    case t2ReadPersonal = 2
    case t3WorkspaceChanges = 3
    case t4ExternalSideEffects = 4
    case t5RawShell = 5
}

public protocol PearlTool: Sendable {
    var name: String { get }
    var description: String { get }
    var tier: ToolTier { get }
    var requiredTCC: [TCCPermission] { get }
    var isReversible: Bool { get }
    
    func validateArguments(_ rawJSON: [String: Any]) throws -> ValidatedArguments
    func execute(args: ValidatedArguments, context: ToolExecutionContext) async throws -> ToolResult
}
```

### Tool Execution Pipeline
Every tool call passes through the 5-stage deterministic pipeline:
1. **Schema Validation**: Parse and validate input arguments against strict Swift types.
2. **Policy Evaluation**: Check tool tier against current context trust state (Taint status). If context is tainted and `tier >= .t3WorkspaceChanges`, suspend and prompt user.
3. **Pre-Flight Undo Registration**: If tool is mutating, capture reverse action (e.g. `FileManager.trashItem` returns URL).
4. **Execution**: Run in-process (native framework) or inside sandboxed child (`srt` / Seatbelt).
5. **Audit Logging**: Write hash-chained entry to `audit.log`.

---

## 5. Router Architecture & Intent Resolution

```
User Utterance ("mute volume" / "summarize my morning meetings")
                      │
                      ▼
        ┌───────────────────────────┐
        │   Grammar & Slot Parser   │ ──(Score >= 0.95)──► Deterministic Tool Execution
        │     (Pure Swift, <5ms)    │                      (No LLM, Sub-50ms)
        └─────────────┬─────────────┘
                      │ (Unmatched)
                      ▼
        ┌───────────────────────────┐
        │  Apple Foundation Models  │ ──(Confidence OK)──► @Generable Intent Action
        │   (On-Device System LLM)  │                      (Local Neural Engine)
        └─────────────┬─────────────┘
                      │ (Requires escalation / Off-device)
                      ▼
        ┌───────────────────────────┐
        │   Frontier Model Router   │ ──► claude-haiku-5-5 (Fast)
        │      (TLS to Cloud)       │     claude-sonnet-5-5 (Complex Escalation)
        └───────────────────────────┘
```

This ensures 100% of common Mac commands execute instantly with zero token consumption and zero latency jitter.
