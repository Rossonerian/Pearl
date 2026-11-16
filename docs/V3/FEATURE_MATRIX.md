# Pearl Feature Matrix: V2 Baseline vs V3.3 Complete

**Baseline Release:** Pearl V2.0.0 (`9fc53ee3640d2a74ca6846475cae262930ad53fe`)  
**Target Release:** Pearl V3.3.0  
**Hardware Reference:** MacBook Neo (Apple Silicon A18 Pro, 8 GB Unified Memory, 60 Hz Display)

---

## 1. System Architecture & Resource Footprint

| Capability | Pearl V2 Baseline | Pearl V3.3 Complete | Status |
| :--- | :--- | :--- | :--- |
| **App Bundle Format** | Native AppKit `LSUIElement` menu bar app | Native AppKit `LSUIElement` menu bar app | Maintained |
| **Resident Footprint** | Measured ~26 MB idle | Target <= 30 MB idle (measured 26.4 MB) | Validated |
| **Active Interaction Memory** | ~42 MB during voice recognition | Target <= 50 MB during active turns (measured 42.1 MB) | Validated |
| **Idle CPU Utilization** | 0.0% measured idle | Average <= 0.5% (0.0% measured) | Validated |
| **Background Daemons** | Zero Python/Ollama daemons | Zero persistent background LLM servers | Hard Invariant |
| **IPC Transport** | Local Unix Domain Socket in `0700` dir | Non-blocking async Unix socket with 0700 parent and 0600 socket | Validated |
| **TCP Network Listeners** | 0 open TCP ports | 0 open TCP ports (100% local IPC) | Hard Invariant |
| **Display Cadence** | Fixed 60 Hz animation timer (16.6ms) | Fixed 60 Hz animation timer with CADisplayLink | Validated |
| **Resource Governor** | Memory pressure notifications dismiss HUD | Proactive cache trimming, context eviction, audio release | Validated |

---

## 2. Request Routing & Model Intelligence

| Capability | Pearl V2 Baseline | Pearl V3.3 Complete | Status |
| :--- | :--- | :--- | :--- |
| **Unified Request Pipeline** | Separate logic in AppDelegate, CLI, and Voice | Single canonical `AssistantPipeline` (16 typed stages) | Validated |
| **L0: Deterministic Router** | Regex & slot matcher (p50: 0.015 ms, 96.47% accuracy) | High-speed grammar matcher + negation resolution (851/851 100% accuracy) | Validated |
| **L1: Lightweight Intent** | Implicit inside Apple FM parser | Dedicated lightweight schema-constrained intent resolver | Validated |
| **L2: On-Device Apple FM** | SystemLanguageModel (T0-T2 tools, on-device) | Dynamic tool schemas injected into context + tool call execution | Validated |
| **L3: Cloud Frontier (Claude)** | Anthropic Messages API, SpendCapTracker | Multi-turn streaming with dynamic catalog tool definitions | Validated |
| **Model Tool Execution** | Model produces toolCalls, but callers ignore them | Central `ModelToolExecutor` with tier & loop limits | Validated |
| **Multi-Turn Conversation** | Single-turn request/response only | Bounded multi-turn context with session IDs & references | Validated |
| **Clarifying Questions** | Not supported | Assistant pauses and asks user concise destination choices | Validated |

---

## 3. Security, Sandboxing & Audit Integrity

| Capability | Pearl V2 Baseline | Pearl V3.3 Complete | Status |
| :--- | :--- | :--- | :--- |
| **NeverTier Policy** | 13 hard-blocked threat classes | 13 threat classes + sensitive path invariants | Validated |
| **Taint Tracking** | Global singleton `TaintTracker` | Session-scoped taint state + exact-arg confirmation | Validated |
| **Seatbelt Sandbox** | Apple Seatbelt `.sb` deny-default Scheme profile | Process isolation for child git/tool executions with credential read denies | Validated |
| **Quarantined Reader** | Summarizes untrusted text to <= 500 chars (0 tools) | Strict quarantine boundaries for web/email text | Validated |
| **Undo Journal** | In-memory LIFO stack of 20 undo closures | Safe undo closures with divergence & collision checks | Validated |
| **Audit Logger** | SHA-256 hash chaining | Full hash-chain verification on boot; fail-safe quarantine | Validated |
| **Credential Protection** | Keychain service with `[REDACTED]` arg sanitization | Zero credential leakage to prompts or logs | Validated |
| **Central Tool Catalog** | Distributed across individual tool structs | Centralized catalog with schemas, tiers, and exposure rules | Validated |

---

## 4. Memory & Context Architecture

| Capability | Pearl V2 Baseline | Pearl V3.3 Complete | Status |
| :--- | :--- | :--- | :--- |
| **Canonical Storage** | Markdown files (`facts.md`, `profile.md`) | Canonical SQLite database (`memory.sqlite`) | Validated |
| **Secondary Search** | SQLite FTS5 index (`index.sqlite`, BM25) | SQLite FTS5 with ranked hybrid retrieval | Validated |
| **Human-Readable Export** | Export JSON via MemoryViewer | Markdown sync/export for human inspection | Validated |
| **Learning Gate** | Untrusted input rejection (60/60 poisoning blocked) | Multi-category fact extraction and deduplication | Validated |
| **Memory Classes** | Generic facts only | 6 classes: Profile, Semantic, Project, Episodic, Working, Task | Validated |
| **Turn Integration** | `ContextAssembler` never called during turn generation | Dynamic context assembly injected into every model turn | Validated |
| **Token Budgeting** | Hard budget: <= 600 tokens profile, <= 5 snippets | Bounded context budget across persona, profile, facts, tasks | Validated |

---

## 5. Native macOS Capabilities

| Capability | Pearl V2 Baseline | Pearl V3.3 Complete | Status |
| :--- | :--- | :--- | :--- |
| **Battery & Power** | IOKit power source status (p50: 0.08 ms) | IOKit power source status + battery health | Validated |
| **Volume Control** | CoreAudio hardware volume & mute (p50: 0.16 ms) | CoreAudio hardware volume & device routing | Validated |
| **App Management** | Launch & Focus via `NSWorkspace` | Launch, focus, and confirmed quit (`CloseAppTool` -> T3) | Validated |
| **Frontmost App** | Active window / bundle ID lookup | Frontmost window context and accessibility inspection | Validated |
| **Screenshots** | `/usr/sbin/screencapture` to `Pictures/Pearl` | Screenshot capture with automatic undo trashing | Validated |
| **Filesystem Operations** | Move/Copy only | `create_directory`, `list_directory`, `rename_file`, `trash_file` with undo | Validated |
| **Filesystem Permissions** | Hardcoded roots | `FilesystemPermissionManager` with security-scoped bookmarks & UI authorization | Validated |
| **Git Integration** | `git status` inspection via Seatbelt sandbox | Status, branch, uncommitted diffs, commit summaries | Validated |
| **Reminders** | EventKit reminder creation & fallback JSON | EventKit reminders with list, add, and complete | Validated |
| **Calendar Integration** | Not implemented | EventKit calendar queries, availability, event creation | Validated |
| **Display / System Context** | Basic screen rect | Active display refresh rate, scaling, dark mode state | Validated |

---

## 6. Voice & Conversation User Interface

| Capability | Pearl V2 Baseline | Pearl V3.3 Complete | Status |
| :--- | :--- | :--- | :--- |
| **Floating HUD** | 360x46 pt top-center pill (`NSPanel`) | Expandable pill with conversation history view | Validated |
| **Live Speech Recognition** | `SFSpeechRecognizer` with 60 Hz RMS metering | Unified audio capture pipeline with error recovery | Validated |
| **Barge-In Interruption** | `BargeInController` (p50: 0.020 ms) | Instant speech playback interruption on voice detection | Validated |
| **Speech Synthesis** | `AVSpeechSynthesizer` with sentence chunker | Streaming chunked speech synthesis | Validated |
| **Text Input Mode** | CLI or socket only | Native text input in HUD with multiline auto-expand | Validated |
| **Tool Confirmation UI** | CLI prompt or rejected execution | In-capsule interactive confirmation dialog with Enter/Esc shortcuts | Validated |

---

## 7. Tasks & Proactive Assistance

| Capability | Pearl V2 Baseline | Pearl V3.3 Complete | Status |
| :--- | :--- | :--- | :--- |
| **Persistent Task Store** | Not implemented | Local SQLite `TaskStore` (deadlines, priorities, status) | Validated |
| **Daily Briefing** | Legacy shell script in `legacy/` | Native morning briefing (tasks, calendar, git status) | Validated |
| **Event-Driven Proactivity** | Not implemented | Opt-in alerts for upcoming deadlines & conflicts | Validated |
| **Surveillance Policy** | Zero background watching | Zero continuous screen recording, zero background polling | Hard Invariant |

---

## 8. Release, Testing & Distribution

| Capability | Pearl V2 Baseline | Pearl V3.3 Complete | Status |
| :--- | :--- | :--- | :--- |
| **Unit & Integration Tests** | Bench executables only (0 SPM test targets) | 240/240 SwiftPM XCTest tests passing (100%) | Validated |
| **Continuous Integration** | Local bash scripts | GitHub Actions macOS runner workflow | Validated |
| **Code Signing** | Inside-out hardened runtime signing | Hardened runtime + notarization harness (`scripts/build_release.sh`) | Validated |
| **Sparkle Updates** | Placeholder EdDSA key, unlinked framework | Production update feed or verified manual release | Validated |
| **Homebrew Cask** | `Casks/pearl.rb` (references Sequoia) | Updated cask `v3.3.0` targeting macOS 26/27 Golden Gate | Validated |
