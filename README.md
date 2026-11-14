# Pearl (v3.1.0)

> Capable, private, lightweight native macOS personal AI assistant built in compiled Swift for Apple Silicon.

[![Platform](https://img.shields.io/badge/platform-macOS%2015.0%2B-blue.svg)](https://apple.com/macos)
[![Architecture](https://img.shields.io/badge/arch-Apple%20Silicon%20(A18%20Pro%20%2F%20M--Series)-orange.svg)](https://apple.com)
[![License](https://img.shields.io/badge/license-MIT%20%2F%20Apache--2.0-green.svg)](LICENSE)
[![Zero Telemetry](https://img.shields.io/badge/telemetry-0%20call%20home-brightgreen.svg)](PRIVACY.md)
[![MCP Compliant](https://img.shields.io/badge/MCP-2024--11--05-purple.svg)](docs/MCP.md)
[![Tests](https://img.shields.io/badge/tests-156%2F156%20passed%20(100%25)-brightgreen.svg)](Tests/)

---

## Overview

Pearl V3 is a local-first, native macOS personal AI assistant engineered specifically for Apple Silicon (optimized for MacBook Neo, A18 Pro, and M-Series Macs with 8 GB unified memory). Built in compiled Swift, Pearl replaces heavyweight Electron shells and Python daemons with direct in-process AppKit, CoreAudio, EventKit, SQLite, and IOKit system calls.

It presents an ultra-responsive floating pill HUD beneath the display notch, supports push-to-talk voice commands, multi-turn conversational reasoning with anaphoric reference resolution ("open Safari" $\rightarrow$ "now close it"), inspectable 6-class personal memory, typed task management, event-driven proactivity, and Model Context Protocol (MCP) tool exposure—all operating with **zero telemetry**, **zero background LLM daemons**, and **zero TCP network listeners**.

---

## What's New in Pearl V3

1. **Structured 6-Class Memory Architecture (`memory.sqlite`)**:
   - Structured SQLite canonical store (`~/Library/Application Support/Pearl/memory.sqlite`) supporting 6 distinct memory classes: Profile, Semantic, Project, Episodic, Working, and Task.
   - Ranked BM25 search via SQLite FTS5 with Porter tokenization ($p95 = 2.24\text{ ms}$ across 5,000 facts).
   - Automatic fact deduplication and entity-level fact correction.
   - Bidirectional human-readable Markdown synchronization (`facts.md`, `profile.md`).

2. **Multi-Turn Conversation & Contextual Intelligence**:
   - `SessionManager` maintaining bounded turn history under strict token budgets.
   - `ContextReferenceResolver` resolving anaphoric pronoun references ("close it", "check that branch", "do it again") across consecutive turns.
   - `StreamingResponseChunker` streaming typing cadence for live HUD response rendering.

3. **Native macOS System Capabilities (`Sources/PearlTools/`)**:
   - **Calendar (`EventKit`)**: Query events (`list_calendar_events`), check schedule availability (`check_calendar_availability`), create events with instant `UndoJournal` rollback (`create_calendar_event`), and delete events with user confirmation (`delete_calendar_event`).
   - **Display Context**: Inspect active display resolution, Retina backing scale, color appearance, and nominal 60 Hz refresh rate.
   - **Clipboard & Secret Redaction**: Read and write clipboard content with automatic redaction of API keys/tokens and undo restoration.
   - **System Notifications**: Post native desktop notifications with zero third-party dependencies.

4. **Consolidated Audio & Native 60 Hz HUD UI**:
   - Unified `AudioPipelineService` owning a single `AVAudioEngine` tap for 60 Hz RMS metering, barge-in detection, and real-time speech recognition.
   - Standby resource deallocation tearing down audio graphs on idle to guarantee physical memory footprint $\le 30\text{ MB}$.
   - Expandable HUD conversation history sheet with SF Mono tabular timestamps.
   - Interactive Tier 2 tool confirmation banner (`[Confirm (Enter)]` / `[Cancel (Esc)]`) embedded directly inside the floating notch capsule.

5. **Local Task Engine & Proactive Briefing**:
   - Structured `TaskStore.sqlite` with priority sorting, status tracking, and deadline filtering.
   - Typed task management tools with undo support (`list_tasks`, `create_task`, `complete_task`, `delete_task`).
   - Executive morning daily briefing and zero-polling event-driven deadline notifications.

6. **Hardened Safety & Formal Quality Suite**:
   - 100.00% deterministic routing accuracy on 851 golden utterances (0 wrong actions, 0 false triggers on negations).
   - 100% malicious shell command interception (220/220) and prompt injection rejection (110/110).
   - 156 / 156 unit tests passing across `PearlCoreTests`, `PearlMemoryTests`, and `PearlToolsTests`.
   - Comprehensive GitHub Actions CI runner (`.github/workflows/ci.yml`).

7. **V3.1 Agent Harness, Adaptive Output & Expanded macOS Access**:
   - **Adaptive OutputDirector ("Talk Back & Leave")**: Chooses `.speakFull`, `.speakSummaryAndHUD` (concise voice summary for long/code/list responses), `.hudOnly`, or `.silentNotification`, and auto-dismisses the HUD on timeout or frontmost app switch (event-driven, zero polling).
   - **Bounded Agent Harness**: `PlanExecutor` (8-step cap, memory guard, LIFO `UndoJournal` rollback), SQLite `JobStore` checkpoints, `ApprovalQueue` for away/high-tier actions, and global `KillSwitch` (`pearl abort`).
   - **On-Demand Local MLX Brain**: Optional lazy-loaded `MLXProvider` (~1.5B 4-bit) with memory-pressure refusal and 30s idle auto-unload (`0 MB` idle footprint).
   - **Expanded Tiered Tools & Screen OCR**: Allowlisted `FileTools`, `WindowTool`, `ShortcutsTool`, `BrowserTool`, `CommunicationDraftTool` (Mail drafts without auto-send; `send_mail` strictly T4 confirmed), and in-memory `ScreenCaptureKit` + Vision OCR (`read_screen_text`).
   - **Declarative Markdown Skills & Smart Nudges**: Inspectable skills in `~/Library/Application Support/Pearl/skills/*.md` (`start-workday`, `meeting-prep`), proactive nudges with quiet hours, and user-approved preference learning.

---

## Architecture Overview

```
                               ┌─────────────────────────────────────────┐
                               │         MacBook Notch Floating HUD      │
                               │        (AppKit / CoreAnimation / 60Hz)  │
                               └────────────────────▲────────────────────┘
                                                    │
┌────────────────────────┐              ┌───────────┴───────────┐              ┌────────────────────────┐
│   Global Hotkey        │─────────────▶│      Pearl Daemon     │◀─────────────│   External MCP Host    │
│  (Ctrl + Opt + Space)  │              │  (AppKit / Unix Socket│              │ (Claude Desktop/Cursor)│
└────────────────────────┘              └───────────┬───────────┘              └────────────────────────┘
                                                    │
                ┌───────────────────────────────────┼───────────────────────────────────┐
                ▼                                   ▼                                   ▼
   ┌─────────────────────────┐         ┌─────────────────────────┐         ┌─────────────────────────┐
   │  Deterministic Router   │         │     Voice Pipeline      │         │   Multi-Tier Models     │
   │   (0.001 ms, N=851)     │         │ (Silero VAD / 60Hz PCM) │         │ (Apple FM / Cloud BYO)  │
   └────────────┬────────────┘         └────────────┬────────────┘         └────────────┬────────────┘
                │                                   │                                   │
                ▼                                   ▼                                   ▼
   ┌─────────────────────────┐         ┌─────────────────────────┐         ┌─────────────────────────┐
   │    Native Swift Tools   │         │   Inspectable Memory    │         │  Seatbelt Sandboxing    │
   │ (CoreAudio, IOKit, Apps)│         │  (Markdown + FTS5 Index)│         │ (TaintTracker / Audit)  │
   └─────────────────────────┘         └─────────────────────────┘         └─────────────────────────┘
```

Pearl operates across four distinct execution tiers:
1. **Tier 1 (Deterministic Engine - < 1 ms)**: Exact and pattern matching for system controls (Volume, Battery, Window Context, App Switching). Zero token cost, zero LLM invocation.
2. **Tier 2 (On-Device Foundation Models - < 50 ms)**: Private neural inference on Apple Silicon (16-core NPU) for parameter extraction and schema-constrained extraction without network egress.
3. **Tier 3 (Cloud Frontier Escalation)**: User-designated API key (Anthropic Claude / OpenAI) for complex, multi-turn reasoning, protected by monthly hard budget spend caps.
4. **NeverTier (Strictly Denied)**: Destructive filesystem deletion (`rm -rf ~`), privilege escalation (`sudo`), and credential access (`~/.ssh`, Keychains) are permanently blocked by policy.

---

## Empirical Benchmarks (MacBook Neo)

All numbers empirically measured on a **MacBook Neo** (Apple A18 Pro, 8 GB Unified RAM, macOS 27.2.1, 60 Hz display). See [docs/BENCHMARKS.md](docs/BENCHMARKS.md) for raw datasets.

| Subsystem / Benchmark | Legacy V1 (Baseline) | Pearl V2 (Empirical p50) | Target SLA | Improvement |
| :--- | :--- | :--- | :--- | :--- |
| **Desktop Action (Volume Control)** | 135.8 ms (`osascript`) | **0.164 ms** (CoreAudio) | < 50.0 ms | **826x faster** |
| **Active App Context Resolution** | 204.1 ms (`osascript`) | **0.0002 ms** (NSWorkspace) | < 5.0 ms | **> 1,000,000x faster** |
| **Deterministic Intent Routing** | 66.7 ms (shell regex) | **0.0012 ms** (Swift router) | < 1.0 ms | **55,000x faster** |
| **Floating HUD Notch Presentation** | 38.0 – 48.0 ms | **0.348 ms** (AppKit panel) | < 16.6 ms (60Hz) | **Sub-frame presentation** |
| **Voice Barge-In Interruption** | N/A | **0.019 ms** (AudioEngine) | < 20.0 ms | **Instant audio cutoff** |
| **End-to-End Voice Turn (Action)** | 3,200 – 4,500 ms | **15.6 ms** (deterministic) | < 300.0 ms | **200x faster** |
| **Local Daemon IPC Roundtrip** | N/A (HTTP bridge) | **0.076 ms** (Unix socket) | < 1.0 ms | **Near-zero overhead** |
| **Memory Search (SQLite FTS5)** | N/A | **0.615 ms** (Indexed query) | < 10.0 ms | **Sub-millisecond context** |
| **Security Policy Evaluation** | 0.55 – 0.75 ms | **0.126 ms** (In-process check) | < 5.0 ms | **Sub-0.2ms validation** |
| **MCP Tool Call Dispatch** | N/A | **0.403 ms** (JSON-RPC stdio) | < 10.0 ms | **Sub-millisecond MCP** |

### Memory & Network Footprint Profile

- **Idle RAM**: **14.2 MB** (Resident set size in menu bar)
- **Active Floating HUD**: **32.4 MB** (Peak during 60 Hz waveform animation)
- **Persistent Daemons**: **1** (`Pearl.app` resident daemon)
- **TCP Listeners**: **0** (Verified via `lsof -a -iTCP -sTCP:LISTEN -p <pid>`)
- **Third-Party Telemetry Calls**: **0** (No analytics, no crash beacons, no phoning home)

---

## Installation & Quickstart

### Option A: Homebrew Cask (Recommended)

```bash
# Add the Pearl tap and install
brew tap rossonerian/tap
brew install --cask pearl
```

### Option B: Download Notarized App

Download `Pearl-2.0.0.dmg` from the latest [GitHub Release](https://github.com/rossonerian/Pearl/releases). Drag `Pearl.app` into `/Applications`.

### Option C: Build From Source

```bash
git clone https://github.com/rossonerian/Pearl.git
cd Pearl

# Compile release binaries
DEVELOPER_DIR=/Library/Developer/CommandLineTools swift build -c release

# Or package signed .app and .dmg bundle
./scripts/build_release.sh --adhoc --dmg
```

---

## Usage

### 1. Hotkey & Voice

- **Activate HUD**: Press `Ctrl + Opt + Space` (`⌃⌥Space`) anywhere in macOS.
- **Push-to-Talk**: Hold `⌃⌥Space` and speak. Releasing the hotkey triggers the endpoint in **< 10 ms**.
- **Example Commands**:
  - *"Set volume to 40"*
  - *"Check battery"*
  - *"Take a screenshot"*
  - *"What app is frontmost?"*
  - *"Remember that my favorite project is Pearl"*

### 2. Command-Line Interface (`pearl-cli` / `pearl`)

Pearl ships with a compiled Mach-O CLI tool communicating with the daemon over a fast local Unix domain socket:

```bash
# Verify daemon connectivity
pearl ping

# Query daemon status and frontmost application
pearl status

# Execute an action query
pearl exec "set volume to 65"

# Control the floating notch HUD
pearl show "Building Pearl v2.0..."
pearl hide

# Manage inspectable memory
pearl remember "Prefers concise terminal responses"
pearl memory stats
pearl memory export > ~/pearl_memory_backup.json
pearl forget <fact_id>

# Run security and sandbox diagnostics
pearl doctor --security

# Run native Model Context Protocol (MCP) server
pearl mcp
```

### 3. Model Context Protocol (MCP) Integration

Pearl exposes its native typed tools to MCP clients (Claude Desktop, Cursor, Zed) via stdio.

Add Pearl to `~/Library/Application Support/Claude/claude_desktop_config.json`:

```json
{
  "mcpServers": {
    "pearl": {
      "command": "/Applications/Pearl.app/Contents/Helpers/pearl-cli",
      "args": ["mcp"]
    }
  }
}
```

Exposed MCP Tools:
- `volume`: Get and set system audio volume (0-100%).
- `battery`: Inspect battery charge percentage, state, and power source.
- `frontmost_app`: Identify the active focused macOS application.
- `open_app`: Launch or switch to any installed application.
- `close_app`: Safely terminate a running application.
- `screenshot`: Capture fullscreen or window screenshots.
- `reminder`: Create and list reminders in Apple Reminders.
- `git_status`: Query repository branch and working tree status.

---

## Security & Privacy

Pearl is designed from the ground up to protect your privacy and system integrity:

- **[PRIVACY.md](PRIVACY.md)**: Zero tracking, zero telemetry, zero system profiling. The only network calls are to your BYO LLM provider and opt-in Sparkle update manifests.
- **[SECURITY.md](SECURITY.md)**: Vulnerability disclosure policy and threat model.
- **[docs/THREAT_MODEL.md](docs/THREAT_MODEL.md)**: Detailed analysis of prompt injection defenses, seatbelt sandbox profiles, and taint tracking.

---

## Reproducing Benchmarks

Every benchmark figure in this documentation can be reproduced on your hardware in one command:

```bash
./Bench/scripts/run_all.sh
```

This compiles the test suites, runs all 11 benchmark targets, and automatically regenerates `docs/BENCHMARKS.md`.

---

## Contributing

We welcome contributions! Please review [CONTRIBUTING.md](CONTRIBUTING.md) before submitting pull requests.

---

## License

Pearl is licensed under the Apache 2.0 and MIT Licenses. See [LICENSE](LICENSE) and [docs/LICENSE_MATRIX.md](docs/LICENSE_MATRIX.md) for details.
