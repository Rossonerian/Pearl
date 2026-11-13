# Contributing to Pearl

Thank you for your interest in contributing to Pearl! Pearl is an ultra-low-latency, native voice assistant for Apple Silicon macOS. We value code quality, test coverage, empirical benchmarking, and an uncompromising commitment to user privacy and security.

---

## 1. Code of Conduct & Philosophy

- **Zero Telemetry**: We will never accept PRs that introduce third-party analytics, user tracking, advertising SDKs, or background telemetric beacons.
- **No Companion Persona**: Pearl is engineered as a capable, warm, concise macOS assistant. We do not accept PRs adding simulated emotional attachments or companion roleplay.
- **Performance First**: Pearl actions should execute in sub-millisecond time. In-process AppKit/CoreAudio/IOKit Swift APIs are preferred over spawning subshells or `osascript`.
- **Honest Claims**: All performance numbers must be empirically verifiable using `./Bench/scripts/run_all.sh`.

---

## 2. Development Setup

### Prerequisites
- macOS 15.0+ running on Apple Silicon (A-Series / M-Series).
- Xcode Command Line Tools (`xcode-select --install`).
- Python 3.9+ (for benchmark aggregation scripts).

### Building Pearl
```bash
git clone https://github.com/rossonerian/Pearl.git
cd Pearl

# Build debug configuration
DEVELOPER_DIR=/Library/Developer/CommandLineTools swift build

# Build release configuration
DEVELOPER_DIR=/Library/Developer/CommandLineTools swift build -c release
```

### Running Tests and Diagnostics
```bash
# Verify system integrity and sandbox rules
swift run pearl-cli doctor --security

# Run all empirical benchmarks
./Bench/scripts/run_all.sh
```

---

## 3. Architecture Guidelines

Pearl is structured as modular Swift packages:
- `Sources/PearlCore`: Policy engine, router, sandboxing, taint tracking, context management.
- `Sources/PearlTools`: Native Swift tool implementations (Volume, Battery, Apps, Screenshots, Git, Reminders).
- `Sources/PearlVoice`: Audio capture, Silero VAD, sentence chunking, barge-in controller, speech synthesis.
- `Sources/PearlMemory`: Plaintext Markdown memory store, SQLite FTS5 index, learning gate, memory viewer.
- `Sources/PearlMCP`: JSON-RPC 2.0 Model Context Protocol server exposing native tools over stdio.
- `App/`: AppKit floating notch HUD, menu bar status item, global Carbon hotkey, SwiftUI Onboarding and Settings.

### Coding Standards
1. **Swift Concurrency**: Use `async`/`await` and actors where appropriate. Ensure thread safety across background audio threads and the main AppKit runloop.
2. **NeverTier Boundary**: Any tool executing system side effects must be registered with a strict `ToolTier` and evaluated through `PolicyEngine.shared`.
3. **No Shell Invocations**: Avoid `/bin/sh -c` and `rm` commands in Swift sources. Use `FileManager` or direct APIs.

---

## 4. Submitting a Pull Request

1. **Create a Topic Branch**:
   ```bash
   git checkout -b feature/your-feature-name
   ```
2. **Commit Guidelines**: Use Conventional Commits (`feat:`, `fix:`, `perf:`, `docs:`, `test:`, `chore:`).
3. **Run Benchmarks**: If modifying performance-critical paths, run `./Bench/scripts/run_all.sh` and ensure no regressions.
4. **Audit**: Verify `DEVELOPER_DIR=/Library/Developer/CommandLineTools swift build` succeeds cleanly with 0 warnings.
5. **Open a PR**: Describe your changes, motivation, and include benchmark diffs if applicable.
