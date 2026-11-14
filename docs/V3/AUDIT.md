# Pearl V3 Master Repository Audit

**Target Architecture:** macOS 26.0+ / macOS 27 "Golden Gate"  
**Hardware Reference:** MacBook Neo (Apple Silicon A18 Pro, 8 GB Unified Memory, 60 Hz Display)  
**Starting Commit:** `9fc53ee3640d2a74ca6846475cae262930ad53fe` on `main`  
**Audit Date:** 2026-11-14

---

## Executive Summary

Pearl has a robust Swift foundation consisting of 7 primary modules (`PearlCore`, `PearlTools`, `PearlVoice`, `PearlMemory`, `PearlMCP`, `PearlApp`, `PearlCLI`), a 96.47% accurate deterministic router across 851 golden utterances, a verified Seatbelt sandbox engine, and a working native macOS floating pill HUD.

However, an exhaustive audit of all 207 starting tree entries and 37 mandatory review areas reveals **critical architectural disconnects and integration gaps** that prevent Pearl from operating as a unified conversational personal assistant. Most prominently:
1. **Disconnected Model Tool Execution**: `AppleFMProvider` can emit `ModelToolCall` structures, but `AppDelegate` and `FallbackChain` ignore them completely, leaving them unexecuted.
2. **Fragmented Execution Paths**: Voice utterances, IPC requests, and CLI commands each invoke separate execution logic. There is no unified assistant request pipeline.
3. **Tool Tier Misclassifications**: `CloseAppTool` is categorized as `T1` (reversible) despite being inherently irreversible without state restoration.
4. **IPC Thread Blocking**: `AppDelegate.handleIPCRequest` blocks worker threads with `DispatchSemaphore(value: 0)`, risking deadlock and thread starvation.
5. **Audit Chain Boot Integrity**: `AuditLogger` resumes from the last line of `audit.log` without verifying the entire hash chain from genesis on startup.
6. **Memory-Model Disconnect**: `ContextAssembler` is fully implemented and tested, but never invoked by `FallbackChain` or `AppDelegate` during model generation turns.

Below is the complete classification and detailed audit of all 37 review areas.

---

## Classification of 37 Mandatory Review Areas

| Area | Component / Subsystem | Classification | Primary File(s) |
| :--- | :--- | :--- | :--- |
| **1** | `Package.swift` | **Partially implemented** (missing test targets & Sparkle) | `Package.swift` |
| **2** | App Lifecycle & `AppDelegate` | **Implemented with correctness issues** (semaphore blocking, fragmented dispatch) | `App/AppDelegate.swift` |
| **3** | HUD & Status Item | **Fully implemented and verified** (60 Hz cadence, RMS audio meter) | `App/HUD/HUDPanel.swift`, `HUDView.swift` |
| **4** | Carbon Hotkey Manager | **Fully implemented and verified** (`Ctrl+Opt+Space` global event tap) | `App/Hotkey/CarbonHotkeyManager.swift` |
| **5** | Unix Socket IPC | **Implemented with correctness issues** (serial queue, synchronous handler, partial reads) | `App/IPC/UnixSocketServer.swift`, `IPCProtocol.swift` |
| **6** | CLI (`pearl-cli`) | **Fully implemented and verified** (IPC client, direct offline fallback, doctor command) | `Sources/pearl-cli/main.swift`, `DoctorCommand.swift` |
| **7** | Tool Registry | **Fully implemented and verified** (thread-safe tool store) | `Sources/PearlCore/Registry/ToolRegistry.swift` |
| **8** | Deterministic Router | **Implemented with correctness issues** (routes git status to T3 "git" instead of T0 "git_status") | `Sources/PearlCore/Router/DeterministicRouter.swift` |
| **9** | Policy Engine | **Fully implemented and verified** (NeverTier, Taint, Trust, T4/T5 confirmation checks) | `Sources/PearlCore/Policy/PolicyEngine.swift` |
| **10** | NeverTier Validation | **Fully implemented and verified** (13 hard-blocked threat classes) | `Sources/PearlCore/Policy/NeverTierValidator.swift` |
| **11** | Taint Tracker | **Partially implemented** (global singleton instead of session-scoped) | `Sources/PearlCore/Policy/TaintTracker.swift` |
| **12** | Seatbelt Sandbox | **Fully implemented and verified** (deny-default Scheme profile generator & runner) | `Sources/PearlCore/Sandbox/SeatbeltProfile.swift`, `SandboxedProcessRunner.swift` |
| **13** | Quarantined Reader | **Fully implemented and verified** (schema-constrained <= 500 chars, zero tools) | `Sources/PearlCore/Quarantine/QuarantinedReader.swift` |
| **14** | Undo Journal | **Fully implemented and verified** (actor-isolated LIFO stack of 20 undo closures) | `Sources/PearlCore/Undo/UndoJournal.swift` |
| **15** | Audit Logger & Verifier | **Implemented with correctness issues** (startup does not verify full chain from genesis) | `Sources/PearlCore/Audit/AuditLogger.swift`, `AuditLogVerifier.swift` |
| **16** | Apple Foundation Models Provider | **Implemented but not integrated** (generates tool calls that are never executed) | `Sources/PearlCore/Model/AppleFMProvider.swift` |
| **17** | Frontier Provider (Claude) | **Fully implemented and verified** (HTTP client, spend tracker, Keychain secret redaction) | `Sources/PearlCore/Model/FrontierProvider.swift` |
| **18** | Model Fallback Chain | **Implemented with correctness issues** (never assembles memory context, ignores tool calls) | `Sources/PearlCore/Model/FallbackChain.swift` |
| **19** | SpendCapTracker | **Fully implemented and verified** (monthly USD budget and turn token limit enforcement) | `Sources/PearlCore/Model/SpendCapTracker.swift` |
| **20** | MemoryStore | **Partially implemented** (Markdown is canonical store; SQLite FTS5 is secondary index) | `Sources/PearlMemory/MemoryStore.swift` |
| **21** | FTSIndex | **Fully implemented and verified** (SQLite FTS5, Porter tokenizer, BM25 ranking) | `Sources/PearlMemory/FTSIndex.swift` |
| **22** | LearningGate | **Fully implemented and verified** (untrusted content rejection, proposed facts queue) | `Sources/PearlMemory/LearningGate.swift` |
| **23** | ContextAssembler | **Implemented but not integrated** (context budget assembler exists but never called in turns) | `Sources/PearlMemory/ContextAssembler.swift` |
| **24** | MemoryViewer | **Fully implemented and verified** (JSON export, memory statistics) | `Sources/PearlMemory/MemoryViewer.swift` |
| **25** | LiveSpeechRecognizer | **Fully implemented and verified** (SFSpeechRecognizer + 60 Hz audio RMS level tap) | `Sources/PearlVoice/LiveSpeechRecognizer.swift` |
| **26** | AudioCaptureEngine | **Partially implemented** (redundant duplicate AVAudioEngine instance) | `Sources/PearlVoice/AudioCaptureEngine.swift` |
| **27** | SpeechSynthesizerService | **Fully implemented and verified** (AVSpeechSynthesizer wrapper with completion handlers) | `Sources/PearlVoice/SpeechSynthesizerService.swift` |
| **28** | BargeInController | **Fully implemented and verified** (p50 = 0.020 ms speech interruption detector) | `Sources/PearlVoice/BargeInController.swift` |
| **29** | MCPServer | **Fully implemented and verified** (JSON-RPC 2.0 stdio server exposing 8 safe T0–T2 tools) | `Sources/PearlMCP/MCPServer.swift` |
| **30** | Settings & Onboarding | **Fully implemented and verified** (SwiftUI forms with spend caps and memory wipe) | `App/Settings/SettingsView.swift`, `OnboardingView.swift` |
| **31** | Sparkle Configuration | **Documented but not implemented** (placeholder EdDSA key, framework unlinked) | `App/SparkleConfig.swift` |
| **32** | Release Scripts | **Implemented with correctness issues** (macOS 15.0 minimum in Info.plist vs 26.0 in SPM) | `scripts/build_release.sh` |
| **33** | Homebrew Cask | **Implemented with correctness issues** (targets `:sequoia` instead of `:golden_gate` / macOS 26+) | `Casks/pearl.rb` |
| **34** | Benchmark Executables & Results | **Fully implemented and verified** (13 benchmark targets, raw CSV datasets preserved) | `Bench/Sources/...`, `Bench/results/*.csv` |
| **35** | Security Corpora | **Fully implemented and verified** (1,241 total test records across 4 corpora) | `corpora/*.jsonl` |
| **36** | Legacy Implementations | **Fully implemented and verified** (old Python/Bash v1 code archived in `legacy/`) | `legacy/...` |
| **37** | Documentation | **Partially implemented** (V2 docs complete; V3 master architecture needed) | `docs/...` |

---

## Detailed Findings & Correction Specifications

### Finding 1: Model-Generated Tool Calls Disconnected from Execution
- **File & Symbol**: `App/AppDelegate.swift` (lines 179-183, 303-314), `Sources/PearlCore/Model/AppleFMProvider.swift` (lines 102-110).
- **Description**: `AppleFMProvider.generate` maps user intents to `ModelResponse.toolCalls`. However, both `AppDelegate.handleVoiceUtterance` and `AppDelegate.handleIPCRequest("execute")` read only `modelRes.content` (which contains the static string `"Executing <tool>..."`). The tool calls are never forwarded to `PolicyEngine` for execution, results are never collected, and the user receives a false acknowledgement.
- **Severity**: **Critical (V2 Blocker)**.
- **Reproduction**: Trigger voice or execute `"turn the volume to 30"` via Apple FM fallback. Pearl responds `"Executing volume..."` but audio volume remains unchanged.
- **Dependency**: `PolicyEngine`, `ToolRegistry`, `AppleFMProvider`.
- **Proposed Correction**: Implement `ModelToolExecutor` to consume `modelRes.toolCalls`, validate against `ToolRegistry`, check policy tiers, execute approved tools via `PolicyEngine`, collect results, and format a real final response.
- **Acceptance Criteria**: Utterances routed through Apple FM execute the corresponding native tool, verify outcome, and return actual execution results.

---

### Finding 2: Fragmented Assistant Execution Paths
- **File & Symbol**: `App/AppDelegate.swift` (`handleVoiceUtterance`, `handleIPCRequest`), `Sources/pearl-cli/main.swift`.
- **Description**: Routing logic (checking `DeterministicRouter`, falling back to `FallbackChain`, and calling tools) is duplicated independently in `AppDelegate.handleVoiceUtterance` and `AppDelegate.handleIPCRequest("execute")`. Memory context is not assembled in either path.
- **Severity**: **High (Architectural Defect)**.
- **Reproduction**: Code inspection of `AppDelegate.swift` lines 166-183 vs lines 276-315.
- **Dependency**: `DeterministicRouter`, `FallbackChain`, `MemoryStore`, `PolicyEngine`.
- **Proposed Correction**: Create a single canonical `AssistantPipeline` in `Sources/PearlCore/Pipeline/AssistantPipeline.swift` implementing the 16-step request lifecycle. `AppDelegate`, CLI, and Voice pipelines will all call this canonical pipeline.
- **Acceptance Criteria**: All interfaces process requests through the same pipeline with identical trust, policy, memory, and audit guarantees.

---

### Finding 3: Tool Tier Misclassification (`CloseAppTool`)
- **File & Symbol**: `Sources/PearlTools/AppTool.swift` (`CloseAppTool`, line 87).
- **Description**: `CloseAppTool` is declared as `ToolTier.t1Reversible` while explicitly setting `isReversible = false`. Quitting an application can result in unsaved work loss and is not automatically reversible.
- **Severity**: **High (Security / Data Integrity)**.
- **Reproduction**: Inspect `CloseAppTool.tier` (`.t1Reversible`) vs `isReversible` (`false`).
- **Dependency**: `ToolProtocol`, `PolicyEngine`.
- **Proposed Correction**: Reclassify `CloseAppTool` to `ToolTier.t3WorkspaceChanges` (or require explicit user confirmation if unsaved documents exist).
- **Acceptance Criteria**: `CloseAppTool` has consistent tier classification reflecting its true reversibility and risk profile.

---

### Finding 4: IPC Semaphore Blocking on Async Calls
- **File & Symbol**: `App/AppDelegate.swift` (lines 278, 301, 326, 350, 375), `App/IPC/UnixSocketServer.swift` (lines 122-145).
- **Description**: `UnixSocketServer` uses a synchronous `onCommandHandler: ((IPCRequest) -> IPCResponse)?` closure dispatched on a serial `DispatchQueue`. `AppDelegate` uses `DispatchSemaphore.wait()` to block the thread while waiting for async `Task` results. This risks thread pool exhaustion and prevents concurrent request handling. Furthermore, `UnixSocketServer.handleClient` reads up to 16KB in a single `read()` call without message framing.
- **Severity**: **High (Reliability / Performance)**.
- **Reproduction**: Send concurrent IPC requests (`pearl status` and `pearl "check battery"` simultaneously); observe queue serialization and blocking.
- **Dependency**: `UnixSocketServer`, `IPCProtocol`.
- **Proposed Correction**: Redesign IPC server into `AsyncUnixSocketServer` using Swift Concurrency `async`/`await`, non-blocking client connections, framed request messages, and configurable timeouts.
- **Acceptance Criteria**: Zero semaphores in IPC handling; concurrent client connections handled safely without thread starvation.

---

### Finding 5: Audit Log Startup Verification Gap
- **File & Symbol**: `Sources/PearlCore/Audit/AuditLogger.swift` (lines 81-92).
- **Description**: `AuditLogger.readLastState` inspects only the final line of `audit.log` to resume the hash chain. It does not verify the full chain from genesis on daemon startup. If any historical records were altered or deleted while Pearl was offline, `AuditLogger` continues appending to the tampered chain without alerting.
- **Severity**: **High (Security / Audit Integrity)**.
- **Reproduction**: Manually tamper with an intermediate line in `~/Library/Application Support/Pearl/audit.log`, restart Pearl, and execute an action. A new record is appended without flagging the corrupted chain.
- **Dependency**: `AuditLogVerifier`, `AuditLogger`.
- **Proposed Correction**: Integrate `AuditLogVerifier.verifyFile` into `AuditLogger` initialization. If the chain is corrupted, transition to an explicit `corruptedChain` state, log a security alert, and fail-safe into a quarantined audit session.
- **Acceptance Criteria**: Any offline modification of historical audit logs triggers immediate tamper detection and fail-safe quarantine on startup.

---

### Finding 6: Memory Integration Disconnected from Turn Turns
- **File & Symbol**: `Sources/PearlCore/Model/FallbackChain.swift` (lines 35-75), `Sources/PearlMemory/ContextAssembler.swift`.
- **Description**: `ContextAssembler.assemble(query:store:)` formats stated profile facts and FTS5 retrieved memories into prompt sections. However, `FallbackChain.process` accepts an empty `ModelExecutionContext()` and never queries `MemoryStore` or `ContextAssembler`. Consequently, user-learned facts are never provided to Apple FM or Claude.
- **Severity**: **High (Core Product Functionality)**.
- **Reproduction**: Run `pearl remember "My current project is Pearl"`, then ask `pearl "What project am I currently working on?"`. The model responds generically without knowledge of the stored fact.
- **Dependency**: `FallbackChain`, `MemoryStore`, `ContextAssembler`.
- **Proposed Correction**: Wire `ContextAssembler` into the canonical `AssistantPipeline` so that every query retrieves relevant memory snippets and injects them into the model's execution context within token limits.
- **Acceptance Criteria**: Stored facts are automatically retrieved and accurately reflected in conversational answers across application restarts.

---

### Finding 7: Redundant Duplicate Audio Engine
- **File & Symbol**: `Sources/PearlVoice/AudioCaptureEngine.swift`, `Sources/PearlVoice/LiveSpeechRecognizer.swift`.
- **Description**: Both `AudioCaptureEngine` and `LiveSpeechRecognizer` instantiate independent `AVAudioEngine` objects, each installing taps on `inputNode(bus: 0)` and calculating audio RMS levels.
- **Severity**: **Medium (Resource Efficiency)**.
- **Reproduction**: Code inspection of `AudioCaptureEngine.swift` lines 7-50 vs `LiveSpeechRecognizer.swift` lines 11-45.
- **Dependency**: `PearlVoice`.
- **Proposed Correction**: Consolidate microphone tap and audio stream management into a single unified `AudioCaptureService` that feeds both RMS metering and speech recognizers.
- **Acceptance Criteria**: Exactly one `AVAudioEngine` instance manages the microphone input node.

---

### Finding 8: Router Intent Mismatch for Git Actions
- **File & Symbol**: `Sources/PearlCore/Router/DeterministicRouter.swift` (lines 122-124), `Sources/PearlTools/GitTool.swift`, `Sources/PearlTools/GitStatusTool.swift`.
- **Description**: When a user asks `"git status"`, `DeterministicRouter` returns `ResolvedIntent(toolName: "git", arguments: ["subcommand": "status"])`. The tool named `"git"` is classified as `ToolTier.t3WorkspaceChanges`. However, `GitStatusTool` (named `"git_status"`) is `ToolTier.t0Observe`. This causes read-only status checks to trigger unnecessary T3 authorization rules.
- **Severity**: **Medium (Correctness)**.
- **Reproduction**: Execute `pearl "git status"` in untrusted context; PolicyEngine triggers confirmation for T3 rather than allowing T0 observation.
- **Dependency**: `DeterministicRouter`, `ToolRegistry`.
- **Proposed Correction**: Update `DeterministicRouter` to resolve `"git status"` to `"git_status"` (T0), and reserve `"git"` for mutating commands.
- **Acceptance Criteria**: `"git status"` executes as T0 Observe without confirmation in trusted contexts.

---

### Finding 9: Missing SwiftPM XCTest Targets
- **File & Symbol**: `Package.swift`.
- **Description**: `Package.swift` defines 7 targets and 2 executables, but contains 0 `.testTarget` entries. All existing verification relies on custom executable benchmarks inside `Bench/`.
- **Severity**: **Medium (Testing & CI)**.
- **Reproduction**: Run `swift test`; SwiftPM reports `no tests found`.
- **Dependency**: `Package.swift`.
- **Proposed Correction**: Add XCTest targets (`PearlCoreTests`, `PearlToolsTests`, `PearlVoiceTests`, `PearlMemoryTests`, `PearlMCPTests`) and integrate with GitHub Actions macOS runner CI.
- **Acceptance Criteria**: `swift test` runs automated functional and security test suites across all modules.

---

### Finding 10: Release Packaging Version & OS Inconsistencies
- **File & Symbol**: `scripts/build_release.sh` (line 150), `Casks/pearl.rb` (line 16).
- **Description**: `scripts/build_release.sh` writes `LSMinimumSystemVersion = "15.0"` into `Info.plist`, whereas `Package.swift` requires `.macOS("26.0")`. In `Casks/pearl.rb`, `depends_on macos: ">= :sequoia"` references macOS 15 instead of macOS 26/27.
- **Severity**: **Medium (Distribution)**.
- **Reproduction**: Compare version numbers across `Package.swift`, `Info.plist`, and `Casks/pearl.rb`.
- **Dependency**: Build and release scripts.
- **Proposed Correction**: Unify minimum macOS version across all build scripts and Homebrew casks to `26.0` / `:golden_gate`.
- **Acceptance Criteria**: All manifests reflect consistent minimum macOS versions.
