# Pearl (v2.0)

> Ultra-low-latency, voice-first macOS assistant built natively in Swift for Apple Silicon.

[![Platform](https://img.shields.io/badge/platform-macOS%2015.0%2B-blue.svg)](https://apple.com/macos)
[![Architecture](https://img.shields.io/badge/arch-Apple%20Silicon%20(A18%20Pro%20%2F%20M--Series)-orange.svg)](https://apple.com)
[![License](https://img.shields.io/badge/license-MIT%20%2F%20Apache--2.0-green.svg)](LICENSE)
[![Zero Telemetry](https://img.shields.io/badge/telemetry-0%20call%20home-brightgreen.svg)](PRIVACY.md)
[![MCP Compliant](https://img.shields.io/badge/MCP-2024--11--05-purple.svg)](docs/MCP.md)

---

## Overview

Pearl is a local-first, native macOS assistant designed for Apple Silicon. Built in compiled Swift, Pearl replaces fragile shell scripts and sluggish AppleScript processes with direct in-process AppKit, CoreAudio, and IOKit system calls. It presents a lightweight floating pill beneath the MacBook notch, supports instant push-to-talk voice commands, exposes its capabilities over Model Context Protocol (MCP), and operates with **zero telemetry** and **zero TCP network listeners**.

### Assistant Philosophy

- **Zero Companion Persona**: Pearl is warm, concise, and focused strictly on task execution. It does not roleplay, simulate emotional dependency, or waste your time with conversational fluff.
- **Local-First & Private**: Direct on-device intelligence via Apple Foundation Models or local open-weights (MLX/Ollama). When using cloud providers, queries flow directly to your BYO endpoint using encrypted Keychain credentials.
- **Hardened Safety Boundaries**: Dual-layer Seatbelt sandbox, in-process taint tracking, and a tamper-evident audit hash chain prevent unauthorized side effects.
- **Radical Transparency**: All memory is stored locally in human-readable Markdown files. You can inspect, export, or permanently wipe your data with one click.

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
