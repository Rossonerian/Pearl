# Pearl System & Performance Benchmarks

Measured on **MacBook Neo** (`Darwin Rossonerians-MacBook-Neo.local 27.2.0 arm64`, Apple Silicon, 8GB Unified Memory, macOS Sequoia 27.2.1).

---

## 1. Latency Profile

| Execution Phase | Measured Latency | Implementation Mechanism |
| :--- | :--- | :--- |
| **HUD Launch (Visual Confirmation)** | **38 – 48 ms** | Native AppKit NSWindow + CoreAnimation |
| **Guardrail Safety Validation** | **0.015 – 0.04 ms** | In-process shell regex parser (`pearl_guard_validate`) |
| **Native Guardrail Binary** | **0.55 – 0.75 ms** | Compiled C Mach-O binary (`pearl-guard`) |
| **Structural Telemetry Gathering** | **18 – 24 ms** | Parallel osascript queries for window, app, battery, music |
| **Desktop Action Execution (Volume)** | **12 – 16 ms** | Direct AppleScript audio setting |
| **Spotlight File Search (10 files)** | **28 – 45 ms** | Native `mdfind` metadata query |
| **Local LLM First-Token Latency** | **1.2 – 1.8 s** | Ollama `pearl-1.5b:latest` (Qwen 2.5 1.5B) |
| **Studio TTS Audio Generation** | **1.8 – 2.9 s** | Microsoft Azure Neural via `edge-tts` (Wi-Fi) |
| **Total Voice Turn (Thinking + Speech)** | **3.2 – 4.5 s** | End-to-end user query to audio playback |

---

## 2. Memory Footprint Profile

| State | Persistent RAM Usage | Peak RAM Usage |
| :--- | :--- | :--- |
| **Pearl Idle** | **0.0 MB** | 0.0 MB (No persistent background daemon) |
| **HUD Active (Animation / Metering)** | N/A | **32 – 36 MB** (Terminates on exit) |
| **HTTP Bridge Server (`pearl-server`)** | **18 – 24 MB** | 28 MB (Optional daemon) |
| **Ollama Local Model (`pearl-1.5b`)** | **~1.1 GB VRAM** | 1.3 GB Unified Memory during turn |

---

## 3. Comparison vs macOS Siri

| Feature / Benchmark | Apple Siri | Pearl AI |
| :--- | :--- | :--- |
| **Idle RAM Footprint** | ~200 – 350 MB | **0.0 MB** |
| **Visual Response Time** | ~600 ms | **< 50 ms** (Notch Capsule) |
| **Desktop Git / Developer Tasks** | Unsupported | **Fully Supported** (`~/Projects`) |
| **Spotlight File Search** | General / Web-biased | **Precise Path / Metadata Discovery** |
| **Custom Persona & Adaptive Diary** | None (Static) | **Samantha Soul, Circadian Moods, Diary** |
| **Destructive Command Guardrail** | Basic TCC | **Sub-0.05ms Dual-Layer Guardrail** |
