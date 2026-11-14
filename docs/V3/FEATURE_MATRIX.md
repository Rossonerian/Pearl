# Pearl Feature Matrix: V2 Baseline vs V3 Target

**Baseline Release:** Pearl V2.0.0 (`9fc53ee3640d2a74ca6846475cae262930ad53fe`)  
**Target Release:** Pearl V3  
**Hardware Reference:** MacBook Neo (Apple Silicon A18 Pro, 8 GB Unified Memory, 60 Hz Display)

---

## 1. System Architecture & Resource Footprint

| Capability | Pearl V2 Baseline | Pearl V3 Target | Status |
| :--- | :--- | :--- | :--- |
| **App Bundle Format** | Native AppKit `LSUIElement` menu bar app | Native AppKit `LSUIElement` menu bar app | Maintained |
| **Resident Footprint** | Measured ~26 MB idle | Target <= 30 MB idle (stretch <= 25 MB) | Validated |
| **Active Interaction Memory** | ~42 MB during voice recognition | Target <= 50 MB during active turns | Target |
| **Idle CPU Utilization** | 0.0% measured idle | Average <= 0.5% | Maintained |
| **Background Daemons** | Zero Python/Ollama daemons | Zero persistent background LLM servers | Hard Invariant |
| **IPC Transport** | Local Unix Domain Socket in `0700` dir | Non-blocking async Unix socket with message framing | In Progress (M1) |
| **TCP Network Listeners** | 0 open TCP ports | 0 open TCP ports (100% local IPC) | Hard Invariant |
| **Display Cadence** | Fixed 60 Hz animation timer (16.6ms) | Fixed 60 Hz animation timer with CADisplayLink | Maintained |
| **Resource Governor** | Memory pressure notifications dismiss HUD | Proactive cache trimming, context eviction, audio release | Target (V3) |

---

## 2. Request Routing & Model Intelligence

| Capability | Pearl V2 Baseline | Pearl V3 Target | Status |
| :--- | :--- | :--- | :--- |
| **Unified Request Pipeline** | Separate logic in AppDelegate, CLI, and Voice | Single canonical `AssistantPipeline` (16 typed stages) | Gap -> M1 |
| **L0: Deterministic Router** | Regex & slot matcher (p50: 0.015 ms, 96.47% accuracy) | High-speed grammar matcher + negation resolution | Maintained |
| **L1: Lightweight Intent** | Implicit inside Apple FM parser | Dedicated lightweight schema-constrained intent resolver | Target (V3) |
| **L2: On-Device Apple FM** | SystemLanguageModel (T0-T2 tools, on-device) | Bounded tool calling with prompt feedback loops | Gap -> M1 |
| **L3: Cloud Frontier (Claude)** | Anthropic Messages API, SpendCapTracker | Multi-turn streaming with structured tool execution | Maintained |
| **Model Tool Execution** | Model produces toolCalls, but callers ignore them | Central `ModelToolExecutor` with tier & loop limits | Gap -> M1 |
| **Multi-Turn Conversation** | Single-turn request/response only | Bounded multi-turn context with session IDs & references | Target (V3) |
| **Clarifying Questions** | Not supported | Assistant can pause and ask user for clarification | Target (V3) |

---

## 3. Security, Sandboxing & Audit Integrity

| Capability | Pearl V2 Baseline | Pearl V3 Target | Status |
| :--- | :--- | :--- | :--- |
| **NeverTier Policy** | 13 hard-blocked threat classes | 13 threat classes + sensitive path invariants | Maintained |
| **Taint Tracking** | Global singleton `TaintTracker` | Session-scoped taint state + exact-arg confirmation | Gap -> M1 |
| **Seatbelt Sandbox** | Apple Seatbelt `.sb` deny-default Scheme profile | Process isolation for child git/tool executions | Maintained |
| **Quarantined Reader** | Summarizes untrusted text to <= 500 chars (0 tools) | Strict quarantine boundaries for web/email text | Maintained |
| **Undo Journal** | In-memory LIFO stack of 20 undo closures | Actor-isolated journal with persistent undo tokens | Maintained |
| **Audit Logger** | SHA-256 hash chaining | Full hash-chain verification on boot; fail-safe quarantine | Gap -> M1 |
| **Credential Protection** | Keychain service with `[REDACTED]` arg sanitization | Zero credential leakage to prompts or logs | Maintained |
| **Central Tool Catalog** | Distributed across individual tool structs | Centralized catalog with schemas, tiers, and exposure rules | Gap -> M1 |

---

## 4. Memory & Context Architecture

| Capability | Pearl V2 Baseline | Pearl V3 Target | Status |
| :--- | :--- | :--- | :--- |
| **Canonical Storage** | Markdown files (`facts.md`, `profile.md`) | Canonical SQLite database (`memory.sqlite`) | Gap -> M2 |
| **Secondary Search** | SQLite FTS5 index (`index.sqlite`, BM25) | SQLite FTS5 with ranked hybrid retrieval | Maintained |
| **Human-Readable Export** | Export JSON via MemoryViewer | Markdown sync/export for human inspection | Target (M2) |
| **Learning Gate** | Untrusted input rejection (60/60 poisoning blocked) | Multi-category fact extraction and deduplication | Maintained |
| **Memory Classes** | Generic facts only | 6 classes: Profile, Semantic, Project, Episodic, Working, Task | Target (M2) |
| **Turn Integration** | `ContextAssembler` never called during turn generation | Dynamic context assembly injected into every model turn | Gap -> M1/M2 |
| **Token Budgeting** | Hard budget: <= 600 tokens profile, <= 5 snippets | Bounded context budget across persona, profile, facts, tasks | Maintained |

---

## 5. Native macOS Capabilities

| Capability | Pearl V2 Baseline | Pearl V3 Target | Status |
| :--- | :--- | :--- | :--- |
| **Battery & Power** | IOKit power source status (p50: 0.08 ms) | IOKit power source status + battery health | Maintained |
| **Volume Control** | CoreAudio hardware volume & mute (p50: 0.16 ms) | CoreAudio hardware volume & device routing | Maintained |
| **App Management** | Launch & Focus via `NSWorkspace` | Launch, focus, and confirmed quit (`CloseAppTool` -> T3) | Fixed (M1) |
| **Frontmost App** | Active window / bundle ID lookup | Frontmost window context and accessibility inspection | Maintained |
| **Screenshots** | `/usr/sbin/screencapture` to `Pictures/Pearl` | Screenshot capture with automatic undo trashing | Maintained |
| **Trash Operations** | `TrashScreenshotsTool` (`FileManager.trashItem`) | Safe file trashing with undo in approved locations | Maintained |
| **Git Integration** | `git status` inspection via Seatbelt sandbox | Status, branch, uncommitted diffs, commit summaries | Maintained |
| **Reminders** | EventKit reminder creation & fallback JSON | EventKit reminders with list, add, and complete | Maintained |
| **Calendar Integration** | Not implemented | EventKit calendar queries, availability, event creation | Target (M4) |
| **Display / System Context** | Basic screen rect | Active display refresh rate, scaling, dark mode state | Target (M4) |

---

## 6. Voice & Conversation User Interface

| Capability | Pearl V2 Baseline | Pearl V3 Target | Status |
| :--- | :--- | :--- | :--- |
| **Floating HUD** | 360x46 pt top-center pill (`NSPanel`) | Expandable pill with conversation history view | Target (M5) |
| **Live Speech Recognition** | `SFSpeechRecognizer` with 60 Hz RMS metering | Unified audio capture pipeline with error recovery | Maintained |
| **Barge-In Interruption** | `BargeInController` (p50: 0.020 ms) | Instant speech playback interruption on voice detection | Maintained |
| **Speech Synthesis** | `AVSpeechSynthesizer` with sentence chunker | Streaming chunked speech synthesis | Maintained |
| **Text Input Mode** | CLI or socket only | Text input field inside HUD for quiet environments | Target (M5) |
| **Tool Confirmation UI** | CLI prompt or rejected execution | Interactive confirmation dialog with exact args in HUD | Target (M5) |

---

## 7. Tasks & Proactive Assistance

| Capability | Pearl V2 Baseline | Pearl V3 Target | Status |
| :--- | :--- | :--- | :--- |
| **Persistent Task Store** | Not implemented | Local SQLite `TaskStore` (deadlines, priorities, status) | Target (M6) |
| **Daily Briefing** | Legacy shell script in `legacy/` | Native morning briefing (tasks, calendar, git status) | Target (M6) |
| **Event-Driven Proactivity** | Not implemented | Opt-in alerts for upcoming deadlines & conflicts | Target (M7) |
| **Surveillance Policy** | Zero background watching | Zero continuous screen recording, zero background polling | Hard Invariant |

---

## 8. Release, Testing & Distribution

| Capability | Pearl V2 Baseline | Pearl V3 Target | Status |
| :--- | :--- | :--- | :--- |
| **Unit & Integration Tests** | Bench executables only (0 SPM test targets) | Native SwiftPM XCTest targets (`swift test`) | Gap -> M1 |
| **Continuous Integration** | Local bash scripts | GitHub Actions macOS runner workflow | Target (M8) |
| **Code Signing** | Inside-out hardened runtime signing | Hardened runtime + notarization harness | Maintained |
| **Sparkle Updates** | Placeholder EdDSA key, unlinked framework | Production update feed or verified manual release | Gap -> M9 |
| **Homebrew Cask** | `Casks/pearl.rb` (references Sequoia) | Updated cask targeting macOS 26/27 Golden Gate | Gap -> M1 |
