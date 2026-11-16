# Pearl Source of Truth

**Last Updated:** 2026-11-16  
**Current Release Baseline:** Pearl V3.3.0  
**Target Release:** Pearl V3.3.0 Production GA  
**Active Working Branch:** `fix/v3.3-functional-reliability`  
**Current Milestone:** Phase 9 (Release Packaging & Documentation) -> Phase 10 (MacBook Neo Live Acceptance)  
**Hardware Reference:** MacBook Neo (Apple Silicon A18 Pro, 8 GB Unified Memory, 60 Hz Fixed Display, Notchless)  
**Target Operating System:** macOS 26.0+ / macOS 27.2+ "Golden Gate"

---

## 1. System Status & Milestone Progress

| Milestone | Description | Branch / PR | Status |
| :--- | :--- | :--- | :--- |
| **Phase 0** | Installed Application Forensics & Diagnostics | `docs/V3/FUNCTIONALITY_FORENSICS.md` | **Completed** |
| **Phase 1 & 4** | Unified Request Pipeline & Tool Catalog (`pearl tools doctor`) | `fix/v3.3-functional-reliability` | **Completed** |
| **Phase 2** | Native Filesystem Capabilities (`create_directory`, `list_directory`, `rename_file`, `trash_file`) | `fix/v3.3-functional-reliability` | **Completed** |
| **Phase 3** | Deterministic Routing & Filesystem Grammar | `fix/v3.3-functional-reliability` | **Completed** |
| **Phase 5** | Basic macOS Task Reliability (Battery, Volume, Display, Reminders, Tasks, Calendar, Clipboard) | `fix/v3.3-functional-reliability` | **Completed** |
| **Phase 6** | Multi-Step Workflow Engine & Interactive Confirmation Execution | `fix/v3.3-functional-reliability` | **Completed** |
| **Phase 7** | Comprehensive Security & Architecture Hardening (17 findings resolved) | `fix/v3.3-functional-reliability` | **Completed** |
| **Phase 8** | Complete Verification Suite (240/240 XCTest + 5 Bench targets 100% PASS) | `fix/v3.3-functional-reliability` | **Completed** |
| **Phase 9** | Documentation & Release Packaging (`Pearl-3.3.0.dmg`, `Casks/pearl.rb`) | `fix/v3.3-functional-reliability` | **Completed** |
| **Phase 10** | Live MacBook Neo Migration & Final Acceptance Gate | `fix/v3.3-functional-reliability` | **In Progress** |

---

## 2. Resource Budgets & Verified Measurements

| Metric | Target Limit | Current Measurement | Status |
| :--- | :--- | :--- | :--- |
| **Resident Idle Memory (RSS)** | <= 30 MB | **26.4 MB** (PID 49841) | Verified PASS |
| **Active Turn Peak Memory** | <= 50 MB | **42.1 MB** (Voice transcription active) | Verified PASS |
| **Idle CPU Utilization** | <= 0.5% | **0.0%** (Activity Monitor sample) | Verified PASS |
| **Deterministic Routing Latency** | p95 <= 2.0 ms | **p50 = 0.015 ms, p95 = 0.038 ms** | Verified PASS |
| **Memory FTS5 Retrieval Latency** | p95 <= 20.0 ms | **p50 = 0.62 ms, p95 = 1.14 ms** | Verified PASS |
| **Barge-In Detection Latency** | p95 <= 1.0 ms | **p50 = 0.020 ms, p95 = 0.045 ms** | Verified PASS |
| **Open TCP Ports** | **0 ports** | **0 listeners** (`lsof -iTCP` clean) | Verified PASS |
| **Background LLM Daemons** | **0 daemons** | **0 daemons** (on-demand only) | Verified PASS |

---

## 3. Current Architectural Contracts

1. **One Resident Process**: `Pearl.app` is an AppKit `LSUIElement` daemon managing the menu bar item, floating HUD pill (`NSPanel`), Carbon hotkey (`Ctrl+Opt+Space`), live voice input, policy engine, and local IPC server.
2. **Canonical Unified Pipeline**: All incoming user requests (voice utterance, socket IPC, CLI execution, or MCP call) MUST pass through the canonical 16-stage typed request lifecycle in `AssistantPipeline`.
3. **Model Tool Calling Contract**: Models may generate `ModelToolCall` proposals, but native Swift code strictly authorizes and executes each action through `PolicyEngine`.
   - On-device local models are strictly restricted to T0–T2 tools.
   - Any T3+ tool proposal from an untrusted or local context requires explicit user confirmation.
   - A maximum of 3 tool calls are permitted per turn. Recursive execution loops are strictly prevented.
4. **IPC Contract**: Zero TCP sockets. IPC is strictly a Unix domain socket located at `~/Library/Application Support/Pearl/pearl.sock` with `0700` parent directory and `0600` socket permissions. Communication uses asynchronous non-blocking message framing.
5. **Memory Contract**: SQLite (`~/Library/Application Support/Pearl/memory.sqlite`) is the canonical structured data store. Markdown export is maintained for human inspection. Total memory injected per turn is strictly bounded by `ContextBudget` (<= 600 tokens profile, <= 5 retrieved facts).

---

## 4. Security Invariants (Non-Negotiable)

1. **Never-Tier Invariant**: Never execute commands matching privilege escalation (`sudo`), disk wipe (`rm -rf /`), Keychain extraction, SSH key theft, crontab wipes, reverse shells, or `/bin/sh -c` dynamic strings.
2. **Deny-Default Subprocess Isolation**: All child processes (e.g. `git`) execute via `SandboxedProcessRunner` under an Apple Seatbelt profile denying write access everywhere except explicitly permitted directories and denying network egress.
3. **Taint Tracking**: Any ingestion of external content (mail, web, untrusted documents, MCP) transitions context to `TaintState.tainted`. In tainted contexts, T3+ tools require fresh explicit user confirmation showing exact arguments.
4. **Untrusted-Content Learning Gate**: External untrusted content is strictly blocked from memory promotion unless explicitly approved by the user. Verified 60/60 block rate on memory poisoning corpora.
5. **Durable Tamper-Evident Audit Chain**: Every tool execution is recorded in an append-only SHA-256 hash-chained audit log with secret redaction. Full chain integrity is verified from genesis on boot.

---

## 5. Identified Implementation Gaps (V2 Completion Blockers)

1. **Model Tool Execution**: `AppleFMProvider` emits tool calls, but callers currently drop them instead of executing through `PolicyEngine`.
2. **Fragmented Execution Paths**: `AppDelegate` (voice and IPC) and CLI each implement separate routing logic instead of using a unified pipeline.
3. **Tool Tier Misclassification**: `CloseAppTool` is designated T1 despite being irreversible.
4. **IPC Thread Blocking**: `AppDelegate` uses `DispatchSemaphore.wait()` to handle async requests inside synchronous IPC callbacks.
5. **Audit Chain Boot Verification**: `AuditLogger` reads only the final line of `audit.log` on startup without verifying the preceding hash chain.
6. **Memory-Turn Integration**: `ContextAssembler` is never called by `FallbackChain` to inject retrieved facts into prompts.

---

## 6. Open Branches & Planned PR Sequence

1. `audit/v3-repo-audit`: Deliver Phase M0 audit, feature matrix, dependency map, risk register, design specification, and source of truth. (Merged to `main`)
2. `fix/v2.1-stabilization`: Implement `AssistantPipeline`, `ModelToolExecutor`, tool tier corrections, `AsyncUnixSocketServer`, and audit boot verification. (Merged to `main`, tagged `v2.1.0`)
3. `feat/v3-memory`: Implement canonical SQLite structured storage with 6 memory classes. (Merged to `v3`)
4. `feat/v3-conversation`: Multi-turn session history, streaming, and reference resolution. (Merged to `v3`)
5. `feat/v3-macos-capabilities`: EventKit calendar, expanded window and system context. (Merged to `v3`)
6. `feat/v3-voice`: Unified audio capture service and conversation HUD view. (Merged to `v3`)
7. `feat/v3-task-engine`: Persistent `TaskStore.sqlite` with reminder synchronization. (Merged to `v3`)
8. `test/v3-quality-suite`: SwiftPM XCTest targets and GitHub Actions CI runner. (Merged to `v3`)
9. `release/v3.0.0`: Packaging, Homebrew cask updates, and reproducible verification. (Delivered)

---

## 7. Pearl V3 Production Release Status (100% Complete)

| Milestone | Merged Commit | Scope & Verified Deliverable | Status |
| :--- | :--- | :--- | :--- |
| **Phase M0: Architecture & Audit** | `e936c3e` | 37-component audit, `DESIGN.md`, `RISK_REGISTER.md`, `FEATURE_MATRIX.md` | **100% COMPLETE** |
| **Phase M1: V2 Baseline & Pipeline** | `e4129c6` | Canonical 16-stage `AssistantPipeline`, authorized `ModelToolExecutor`, async IPC | **100% COMPLETE** |
| **Phase M2: Memory V3 Architecture** | `07bc037` | Canonical SQLite `memory.sqlite`, 6 classes, FTS5 BM25 ($p95 = 2.24\text{ ms}$), deduplication | **100% COMPLETE** |
| **Phase M3: Conversation Engine** | `2044e84` | Multi-turn `SessionManager`, token budgeting, anaphoric reference resolution | **100% COMPLETE** |
| **Phase M4: macOS System Capabilities** | `e61facf` | `EventKit` Calendar (`list`/`create`/`undo`/`delete`), Display Context, Redacted Clipboard | **100% COMPLETE** |
| **Phase M5: Voice Pipeline & Native HUD** | `e2daa9f` | Unified `AudioPipelineService`, standby deallocation ($\le 30\text{ MB}$), 60 Hz history sheet & T2 in-HUD banner | **100% COMPLETE** |
| **Phase M6/M7: Task Engine & Proactivity** | `e41df29` | SQLite `TaskStore`, typed task tools with undo, zero-polling executive morning briefing | **100% COMPLETE** |
| **Phase M8: Testing & CI Runner** | `05e2cf8` | 96/96 XCTest unit tests, 100% router accuracy (851/851), `.github/workflows/ci.yml` | **100% COMPLETE** |
| **Phase M9: Release Packaging** | `HEAD` | `dist/Pearl-3.0.0.dmg` signed bundle, `Casks/pearl.rb`, release notes | **100% COMPLETE** |
