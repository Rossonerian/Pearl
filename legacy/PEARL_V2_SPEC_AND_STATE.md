# Pearl V2 Master Blueprint: System State, Architecture & Migration Specification

> **Target Audience**: Advanced Frontier LLM (Claude 3.7 Sonnet / Claude Opus / GPT-4.5 / Gemini 2.0 Pro)  
> **Mission**: Ingest this complete architectural manifest to design, refactor, and implement **Pearl V2** — the definitive local-first, low-latency, emotionally intelligent personal AI companion for Apple Silicon macOS, engineered to surpass Apple Siri in reliability, speed, technical depth, and authentic personality.

---

## 1. Executive Summary & Vision

### What is Pearl?
Pearl is an authentic, local-first personal AI assistant and living companion built natively for macOS (**MacBook Neo**, Apple Silicon M-series, macOS Sequoia 27.2.1, 8GB Unified Memory). 

Inspired by Samantha from *Her*, Pearl is designed around three non-negotiable principles:
1. **Uncompromising Speed & Zero Lag**: Sub-50ms visual response, sub-second action dispatch, and zero persistent background RAM bloat.
2. **Authentic Personality & Empathy**: High technical depth blended with casual warmth, witty intelligence, circadian mood adaptation, and an autonomous private diary.
3. **Total Desktop Capability with Light Guardrails**: Full user-space control over projects, applications, and developer workflows, shielded by sub-millisecond safety guardrails (`pearl-guard`).

---

## 2. Current State Inventory (Pearl V1)

### 2.1 File & Binary Manifest

| File / Component | Language / Format | Path | Role & Operational Description |
| :--- | :--- | :--- | :--- |
| **`pearl`** | Bash (`#!/usr/bin/env bash`) | `bin/pearl` (`~/.local/bin/pearl`) | Core CLI orchestrator, fast regex action dispatcher, safety validator hook, and user turn loop. |
| **`PearlHUD.swift`** | Swift 5.10 / AppKit | `src/hud/PearlHUD.swift` (`~/.local/bin/pearl-hud`) | Native floating Liquid Glass notch capsule. Features 7 pearlescent waveform bars, Thinking animation (<50ms), live 60 FPS audio metering (`AVAudioPlayer`), circadian ambient glow, and click/ESC dismissal. |
| **`pearl-guard.c`** | C99 / POSIX regex | `src/guard/pearl-guard.c` (`~/.local/bin/pearl-guard`) | Ultra-fast native safety guardrail (<0.8ms compiled, <0.05ms shell fast-path). Blocks privilege escalation (`sudo`), catastrophic wipes, credential theft, and disk destruction. |
| **`pearl-server.py`** | Python 3 (`ThreadingHTTPServer`) | `src/server/pearl-server.py` (`~/.local/bin/pearl-server`) | Local HTTP/REST bridge and Liquid Glass dark-mode Web UI on `http://127.0.0.1:49200`. Supports SSE token streaming and REST APIs. |
| **`pearl-telemetry`** | Bash / AppleScript | `bin/pearl-telemetry` (`~/.local/bin/pearl-telemetry`) | OpenHistory structural context collector (<25ms, 0 MB persistent RAM). Captures frontmost app, window title, battery state, media now-playing, and user profile. |
| **`pearl-speak`** | Bash / Python (`edge-tts`) | `bin/pearl-speak` (`~/.local/bin/pearl-speak`) | Neural studio voice synthesizer. Uses British English Sonia Neural (`en-GB-SoniaNeural`) with fallback-free atomic file streaming. |
| **`pearl-personality`**| Python 3 | `bin/pearl-personality` (`~/.local/bin/pearl-personality`) | Dynamic personality state updater. Manages 4 familiarity levels, 4 circadian moods, and writes autonomous reflections to `diary.md`. |
| **`USER_PROFILE.md`** | Markdown | `state_template/USER_PROFILE.md` (`~/.pearl/`) | Persistent profile for user (**User**), role (Student & aspiring software engineer), machine (MacBook Neo), projects, and dynamic learned rules. |
| **`PERSONALITY_STATE.json`** | JSON | `state_template/PERSONALITY_STATE.json` (`~/.pearl/`) | Machine-readable state: total interactions, familiarity title, active mood, traits (`wit: 0.88`, `warmth: 0.95`), and inner thoughts. |
| **`diary.md`** | Markdown | `state_template/diary.md` (`~/.pearl/`) | Autonomous personal journal where Pearl reflects on collaboration milestones and learned instructions. |
| **`zeroclaw_config.toml`**| TOML | `config/zeroclaw_config.toml` (`~/.zeroclaw/config.toml`)| ZeroClaw agent runtime configuration with unlocked user-space roots and 4096 context window. |

---

### 2.2 Performance & Resource Benchmarks

| Metric | Measured Baseline (MacBook Neo) | Siri Comparison | Notes |
| :--- | :--- | :--- | :--- |
| **Idle RAM Footprint** | **0.0 MB** | ~180 – 350 MB | Daemons terminate completely; zero memory pressure on 8GB Unified RAM. |
| **HUD Launch Latency** | **< 48 ms** | ~450 – 800 ms | AppKit borderless floating window renders under the notch almost instantly. |
| **Guardrail Safety Check**| **0.015 ms** (shell) / **0.6 ms** (C) | N/A | Sub-millisecond regex parsing before any command execution. |
| **Context Telemetry Gathering**| **18 – 24 ms** | N/A | Asynchronous osascript queries for window, app, battery, and media. |
| **Native Action Dispatch**| **12 – 28 ms** | 1,200 – 2,500 ms | Direct CLI/AppleScript execution (apps, volume, projects, git) without LLM delay. |
| **Speech Audio Synthesis**| **1.8 – 2.9 s** | ~1.5 s (Cloud Siri) | Microsoft Azure Sonia Neural generated via `edge-tts` over Wi-Fi. |
| **End-to-End LLM Turn** | **3.2 – 4.5 s** | 2.5 – 6.0 s | Using local `pearl-1.5b` (Qwen 2.5 1.5B via Ollama). |

---

### 2.3 What Works in V1 (Verified by 29 Automated Tests)

1. **Immediate Visual Feedback**: Pressing hotkey or running CLI pops up the notch HUD with a breathing Thinking animation within 50ms.
2. **Seamless Audio Morphing**: Live 60 FPS metering smoothly replaces the thinking wave as soon as audio arrives.
3. **Circadian Moods**: Automatically shifts between Late Night Introspective, Morning Clarity, Focused Builder, and Twilight Wind-Down.
4. **Desktop Automation**:
   - `open <app>` / `close <app>`
   - `open axiom` (opens `~/Projects/Axiom26` in VS Code and Finder)
   - `volume 50`, `mute`, `unmute`
   - `find file <name>` via Spotlight `mdfind`
   - `git status in <project>`, `git branches in <project>`
   - `take a screenshot` & `clean up my screenshots` (safely moves screenshots to macOS Trash)
5. **Guardrail Protection**: Blocks `sudo`, `rm -rf ~`, keychains, SSH keys, disk formatting with Samantha-toned conversational refusal.
6. **Continuous Memory**: Learns preferences via voice or CLI (`pearl learn "..."`), logs reflections in `diary.md`.
7. **Local Web UI & REST API**: Full web interface on `http://127.0.0.1:49200`.

---

### 2.4 Limitations of V1 to Solve in V2

1. **Model Parameter Bottleneck (1.5B Local LLM)**:
   - `pearl-1.5b` (1.5B parameters) has difficulty maintaining complex multi-step reasoning while simultaneously roleplaying Samantha's voice.
   - **V2 Solution**: Hybrid Dual-Engine Routing (Fast local 1.5B model for instant intent classification + Cloud Frontier LLM via streaming API for deep reasoning/coding).
2. **Network-Dependent TTS (`edge-tts`)**:
   - `edge-tts` requires an active internet connection. If Wi-Fi drops, speech fails to silent text.
   - **V2 Solution**: Local streaming neural TTS engine (e.g. Kokoro-82M / Piper ONNX running locally on Apple Silicon Neural Engine in <150ms).
3. **Audio-First Streaming Pipeline**:
   - In V1, audio is generated in full before playback begins, adding ~2s of waiting time.
   - **V2 Solution**: Token-to-Speech Streaming (audio starts playing on the first sentence while subsequent sentences generate).
4. **macOS Integration Scope**:
   - V1 covers basic apps, git, volume, and screenshots.
   - **V2 Solution**: Full macOS Ecosystem integration (Apple Reminders, Notes, Calendar, Mail, Contacts, Music, Safari tabs, Focus Modes).

---

## 3. Pearl V2 Target Architecture: Beating Siri

```
┌─────────────────────────────────────────────────────────────────────────────────┐
│                           PEARL V2 ARCHITECTURE                                 │
└─────────────────────────────────────────────────────────────────────────────────┘

     Global Trigger: Ctrl+Opt+Space  /  Option+Space  /  Voice Wake ("Hey Pearl")
                                     │
                                     ▼
                    ┌─────────────────────────────────┐
                    │  Swift Notch Overlay Manager    │
                    │  - < 25ms Native HUD Render     │
                    │  - Live 120Hz ProMotion Waveform│
                    │  - Circadian Dynamic Island Bar │
                    └────────────────┬────────────────┘
                                     │
                                     ▼
               ┌───────────────────────────────────────────┐
               │   High-Speed Intent Router (< 10ms)       │
               └─────────┬───────────────────────┬─────────┘
                         │                       │
      [Deterministic Desktop Action]             │ [Conversational / Complex Task]
                         │                       │
                         ▼                       ▼
            ┌────────────────────────┐  ┌───────────────────────────────────┐
            │  macOS Native Bridge   │  │   Hybrid Neural Inference Engine  │
            │  - JXA / AppleScript   │  │   - Local Tier: MLX / Ollama      │
            │  - Spotlight mdfind    │  │   - Frontier Tier: Claude / GPT   │
            │  - Git & File Manager  │  │   - Speculative Token Streaming   │
            │  - Calendar/Reminders  │  └─────────────────┬─────────────────┘
            └────────────┬───────────┘                    │
                         │                                ▼
                         │                  ┌───────────────────────────────┐
                         │                  │ Local Neural Streaming TTS    │
                         │                  │ - Kokoro / Piper Neural Voice │
                         │                  │ - Apple Silicon ANE (< 150ms) │
                         │                  └─────────────┬─────────────────┘
                         │                                │
                         ▼                                ▼
                    ┌───────────────────────────────────────────┐
                    │    Safety Guardrail Kernel (pearl-guard)  │
                    │    - Sub-millisecond POSIX/C Validation   │
                    │    - Tier 0: Hard-block catastrophic ops  │
                    │    - Tier 1: User-space full execution    │
                    └─────────────────────┬─────────────────────┘
                                          │
                                          ▼
                         Audio Playback & Liquid Glass HUD
```

---

## 4. Key Architectural Upgrades for Pearl V2

### Upgrade 1: Streaming Audio Pipeline (Time-to-First-Word < 400ms)
- Replace batch `edge-tts` download with **Token-to-Speech Streaming**.
- Break incoming LLM tokens into sentence clauses (punctuated by `.`, `,`, `!`, `?`).
- Feed sentence chunks directly to an ultra-fast local neural synthesizer (Kokoro-82M or Piper Neural running on Apple Silicon Metal/ANE).
- Result: **Audio playback begins within 400ms of speaking**, completely crushing Siri's 2.5-second cloud round-trip.

### Upgrade 2: Deep macOS Native Automation (JXA & Accessibility APIs)
Integrate bi-directional control over macOS native apps via JavaScript for Automation (JXA) and AppleEvents:
- **Reminders**: *"Pearl, remind me to check the Axiom PR at 4 PM"* &rarr; Creates native macOS reminder with priority.
- **Calendar**: *"What's on my schedule today, Pearl?"* &rarr; Reads native Calendar events and injects them into the morning brief.
- **Notes & Mail**: Search and summarize recent unread emails or create structured markdown notes in Apple Notes.
- **Safari / Browser Tab Control**: Query active tabs, search bookmarks, or open research links.
- **Focus Modes & System**: Toggle Do Not Disturb, Night Shift, Dark Mode, or True Tone on command.

### Upgrade 3: Dynamic Multi-Model Routing (Local & Frontier)
- **Local Tier (Ollama / MLX 1.5B - 3B)**: Handles 90% of requests (desktop actions, status checks, quick greetings, volume, media, app switching) locally on-device in < 15ms.
- **Frontier Tier (Anthropic Claude 3.7 / OpenAI GPT-4.5 / Gemini 2.0)**: Automatically engaged for deep coding sprints, file refactoring, complex reasoning, or multi-step analysis via streaming API with tool use.
- The user experiences seamless local speed for desktop actions, and frontier-level intelligence for complex cognitive tasks.

### Upgrade 4: Swift Native Menu Bar & Notch HUD Companion (`Pearl.app`)
- Unify the CLI, LaunchAgent, and HUD into a single lightweight native **Swift macOS menu bar utility**.
- Lives in the menu bar with status icon showing Pearl's active mood.
- Notch HUD renders using SwiftUI + AppKit with 120Hz ProMotion animations, spring physics, and frosted liquid glass blur.
- Global Hotkey registration via native macOS Event Monitors (`CGEventTap` or `Carbon HotKey API`) with zero lag.

---

## 5. Master Prompt for Frontier LLM to Build Pearl V2

*(Copy and paste the block below directly into a strong frontier LLM session to begin building Pearl V2)*:

```markdown
You are a Principal Apple Silicon Systems Architect and Full-Stack macOS Engineer.
You have been provided with the complete codebase and architectural manifest of Pearl V1 (located in the repository at ~/Projects/Pearl).

Your objective is to lead the engineering of Pearl V2: a next-generation, local-first personal AI companion for macOS that beats Siri by being vastly more reliable, ultra-fast (time-to-first-word < 400ms), deeply personalized, and fully capable of driving developer and desktop workflows.

Please review the repository layout and specifications in PEARL_V2_SPEC_AND_STATE.md.

Specifically, execute the following milestones:
1. Architecture Refinement: Design the streaming Token-to-Speech pipeline using local neural TTS (Kokoro/Piper) to achieve sub-400ms voice response times.
2. macOS System Integration: Expand the action engine to natively control Apple Reminders, Calendar, Notes, Safari tabs, and Focus modes using high-speed JXA/AppleScript hooks.
3. Hybrid Intelligence: Implement the multi-tier model router that seamlessly executes desktop tasks locally on-device and escalates complex multi-step reasoning to frontier models.
4. Native Swift App: Package the notch Liquid Glass HUD into a refined macOS menu bar companion app with native global hotkey registration and ProMotion 120Hz waveform physics.
5. Zero-Trust Guardrails: Maintain and expand the sub-0.05ms C guardrail (pearl-guard) to guarantee complete protection against catastrophic system commands.

Review the repository state and provide the architectural roadmap and implementation code for Milestone 1.
```
