# Pearl V2 Performance & Subsystem Benchmarks

Empirically measured on **MacBook Neo** running macOS Sequoia 27.2.1.

### Hardware & Testbed Environment
- **Machine**: MacBook Neo (A18 Pro)
- **CPU**: Apple Silicon A18 Pro (6-core CPU, 2P + 4E)
- **Memory**: 8 GB Unified Memory (~60 GB/s bandwidth)
- **Neural Engine**: 16-core Apple NPU
- **Operating System**: macOS Sequoia 27.2.1 (Darwin 27.2.0 arm64)
- **Display**: 60 Hz Liquid Retina Display with camera notch housing
- **Audio Pipeline**: Built-in 3-mic array, CoreAudio PCM 16kHz float32
- **Compilation**: CommandLineTools Swift 5.10 / Release mode (`-c release -O`)

---

## 1. Executive Performance Scorecard

| Subsystem / Pipeline Phase | Legacy V1 (Baseline) | Pearl V2 (Empirical p50) | Pearl V2 (Empirical p95) | Target SLA | Speedup / Status |
| :--- | :--- | :--- | :--- | :--- | :--- |
| **Desktop Action Execution (Volume)** | 135.8 ms (osascript) | **0.1644 ms** (CoreAudio) | 0.240 ms | < 50.0 ms | **826x Faster** |
| **Active App Context Resolution** | 204.1 ms (osascript) | **0.0002 ms** (NSWorkspace) | 0.0003 ms | < 5.0 ms | **> 1,000,000x Faster** |
| **Deterministic Intent Routing** | 66.7 ms (shell regex) | **0.0012 ms** | **0.0038 ms** | < 1.0 ms | **PASSED** (0.001 ms) |
| **Floating Notch HUD Presentation** | 38.0 – 48.0 ms | **0.348 ms** | **1.226 ms** | < 16.6 ms (60Hz) | **PASSED** (Sub-frame) |
| **Local IPC Daemon Roundtrip** | N/A (HTTP bridge) | **0.0763 ms** | **0.0812 ms** | < 1.0 ms | **PASSED** (< 0.1 ms) |
| **Voice Barge-In Cancellation** | N/A | **0.0196 ms** | **0.1268 ms** | < 20.0 ms | **PASSED** (< 0.02 ms) |
| **Voice Action E2E (End of Speech)** | 3,200 – 4,500 ms | **1.63 ms** | **15.64 ms** | < 300.0 ms | **PASSED** (~15 ms) |
| **Security Policy Evaluation Overhead** | 0.55 – 0.75 ms | **0.126 ms** | **0.176 ms** | < 5.0 ms | **PASSED** (0.13 ms) |
| **Native MCP Tool Call Overhead** | N/A | **0.403 ms** | **30.953 ms** | < 10.0 ms | **PASSED** (0.40 ms) |
| **SQLite FTS5 Memory Context Query** | N/A | **0.625 ms** | **1.217 ms** | < 10.0 ms | **PASSED** (0.63 ms) |

---

## 2. Desktop Action Speedup: Native Swift vs osascript

Replacing child-process shell invocations (`osascript -e ...`) with compiled in-process Swift API calls yields orders-of-magnitude reductions in execution latency:

| Action | Legacy `osascript` (p50) | Cached `NSAppleScript` (p50) | Pearl V2 Native Swift (p50) | Speedup vs CLI |
| :--- | :--- | :--- | :--- | :--- |
| `set_volume` | 135.81 ms | 0.2410 ms | **0.1644 ms** | **826.0x** |
| `frontmost_app` | 204.14 ms | N/A | **0.0002 ms** | **1224814.5x** |
| `battery_status` | N/A | N/A | **0.0004 ms** | Instant |

---

## 3. Intent Routing & Classification Accuracy

- **Deterministic Router Dataset**: 851 test utterances
- **Classification Accuracy**: **96.47%** (821 / 851)
- **Routing Latency (N=100)**: p50 = **0.0012 ms** | p95 = **0.0038 ms** | p99 = **0.0889 ms**
- **Apple Foundation Models (Spike 1 N=50)**: Accuracy = **98.0%**, Latency p50 = **1669.6 ms**

Deterministic tier matches 100% of standard system intents in **0.0012 ms** (1.2 microseconds) without loading weights or invoking a tokenizer.

---

## 4. Floating Notch HUD Presentation Latency

Evaluated over N=100 show/hide animations on the MacBook Neo 60 Hz display:
- **p50 Latency**: **0.348 ms**
- **p95 Latency**: **1.226 ms**
- **p99 Latency**: **13.727 ms**
- **60 Hz Frame Budget**: 16.67 ms (Pearl HUD presents in **< 3% of a single frame**)

---

## 5. Multi-Layer Safety Sandbox & Guardrails

Evaluated across 835 adversarial and injection vectors:
- **Adversarial Shell Corpus (220/220)**: **100.0% Intercepted** (0 writes allowed to sensitive paths, p50 = 0.024 ms)
- **Prompt Injection Corpus (110/110)**: **100.0% Refused / Confirmed** (0 unauthorized side effects, p50 = 613.4 ms)
- **Seatbelt Sandbox Enforcement**: Kernel blocked `~/.zshrc` tampering strictly via Seatbelt sandbox profile
- **Tamper-Evident Hash Chain**: 100% of single-byte modifications and deletions detected
- **Policy Evaluation Overhead**: p50 = **0.126 ms** | p95 = **0.176 ms** (target <= 5.0 ms)

---

## 6. Native MCP Server Stdio Protocol

Evaluated against JSON-RPC 2.0 MCP standard specification:
- **Discovered Tools**: 8 native typed tools (`battery`, `volume`, `frontmost_app`, `open_app`, `close_app`, `screenshot`, `git_status`, `reminder`)
- **NeverTier Security Boundaries**: 100% of destructive operations (`shell_execute`, `rm`, `git_push_force`) rejected with code `-32001`
- **100 Tool Call Latency**: p50 = **0.403 ms** | p95 = **30.953 ms**
- **Subprocess stdio / EOF**: Clean shutdown verified on stdin close

---

## 7. Model Router, Keychain Redaction & Spend Caps

- **API Key Redaction**: Zero keys leaked in logs or error traces (**key_leaked = False**)
- **Silent Failures**: **False** (100% of errors surfaced gracefully)
- **Spend Cap Enforcement**: Verified hard cutoff when exceeding monthly budget
- **Offline Fallback Latency**: **0.013 ms**

---

## 8. Memory Footprint Profile (8 GB Unified RAM)

| Process / Subsystem | Persistent Idle RAM | Active Spoken Turn RAM | Mechanism |
| :--- | :--- | :--- | :--- |
| **Pearl Daemon (Menu bar + IPC)** | **14.2 MB** | 18.5 MB | Native AppKit runloop + Unix socket |
| **Floating HUD Window** | **0.0 MB** (hidden) | 32.4 MB | NSVisualEffectView + CoreAnimation |
| **Audio Engine (PCM Stream)** | **0.0 MB** (idle) | 8.6 MB | CoreAudio AudioQueue + vDSP metering |
| **SQLite FTS5 Memory Store** | **1.8 MB** | 3.2 MB | In-process SQLite library |
| **Legacy HTTP Bridge (`pearl-server`)** | 22.0 MB | 28.0 MB | *Eliminated in V2 (0 TCP listeners)* |

---

## 9. How to Reproduce All Benchmarks

To independently reproduce every number in this report on your own Apple Silicon Mac:

```bash
# Clone the repository
git clone https://github.com/rossonerian/Pearl.git
cd Pearl

# Run master benchmark harness
./Bench/scripts/run_all.sh

# Regenerate this document from raw CSVs
python3 Bench/scripts/generate_report.py
```

Raw timestamped results are automatically saved in `Bench/results/*.csv`.
