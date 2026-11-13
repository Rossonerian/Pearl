# Pearl — Liquid Glass Native Personal AI Companion for macOS

Pearl is an authentic, local-first personal AI assistant and companion built natively for Apple Silicon macOS (**MacBook Neo**). 

Inspired by Samantha from *Her*, Pearl pairs casual conversational warmth and wit with high technical depth, instant native desktop automation, and an ultra-low latency Liquid Glass Waveform HUD designed to live seamlessly beneath the MacBook notch.

---

## Key Capabilities

1. **Liquid Glass Waveform HUD (`pearl-hud`)**:
   - Native AppKit floating notch capsule with 7 pearlescent waveform bars.
   - **Thinking Animation**: Immediate (< 50ms) visual breathing wave while the model processes queries.
   - **60 FPS Audio Metering**: Seamlessly morphs into live audio-metered speech via `AVAudioPlayer`.
   - **Circadian Ambient Glow**: Changes hue dynamically with Pearl's circadian mood (Moonlit Cyan at night, Sunrise Amber in morning, Cyber Cobalt in focus sprints).
   - **Interactive Dismissal**: Click capsule or press `Esc` / `Space` to dismiss.

2. **Ultra-Fast Desktop Action Engine & Safety Guardrail (`pearl-guard`)**:
   - Direct execution of system tasks: launching/quitting applications, opening projects in VS Code and Finder, adjusting volume, Spotlight search, safe screenshot capture and cleanup to macOS Trash.
   - **Sub-0.05ms Guardrail**: Permanently blocks privilege escalation (`sudo`), catastrophic deletions (`rm -rf ~`), disk wiping, credential exfiltration (`~/.ssh`, Keychains), and synthetic UI keystroke injection with warm, conversational explanations.

3. **Continuous Learning & OpenHistory Structural Telemetry**:
   - Collects frontmost application, active window title, battery power, media playback, and user profile context in **< 25ms with 0 MB persistent background RAM**.
   - Dynamically learns user preferences via voice (*"Pearl, remember that..."*) or CLI (`pearl learn "<preference>"`), updating `USER_PROFILE.md`.

4. **Adaptive Personality & Private Diary (`~/.pearl/diary.md`)**:
   - 4-level Familiarity Progression (from *New Co-pilot* to *Unshakable Ally*).
   - Dynamic Circadian Mood Shifter adapting tone across late-night, morning, focus, and wind-down phases.
   - Autonomous introspective journal (`pearl diary`) where Pearl writes reflections on your collaboration.

5. **Local HTTP Bridge & Liquid Glass Web UI (`pearl-server`)**:
   - Lightweight local web server running on `http://127.0.0.1:49200`.
   - Native macOS Liquid Glass dark-mode Web UI.
   - REST and Server-Sent Events (SSE) streaming APIs for desktop and local clients.

---

## Repository Structure

```
├── bin/                               # Core executable CLI tools
│   ├── pearl                          # Main Pearl orchestrator & action dispatcher
│   ├── pearl-server                   # Local HTTP server & Liquid Glass Web UI bridge
│   ├── pearl-telemetry                # OpenHistory macOS structural telemetry collector
│   ├── pearl-speak                    # Studio Neural voice synthesis runner
│   ├── pearl-personality              # Personality evolution, circadian mood & diary engine
│   ├── pearl-brief                    # Instant hardware/system status generator
│   ├── pearl-battery                  # Quick battery status script
│   └── pearl-note                     # Quick note capture utility
├── src/                               # Native compiled source code
│   ├── hud/
│   │   └── PearlHUD.swift             # Native AppKit Liquid Glass Waveform HUD
│   ├── guard/
│   │   └── pearl-guard.c              # Native C sub-millisecond safety guardrail
│   └── server/
│       └── pearl-server.py            # HTTP & SSE streaming bridge with Liquid Glass Web UI
├── config/                            # Platform & engine configurations
│   ├── zeroclaw_config.toml           # ZeroClaw multi-root config with unlocked user-space
│   ├── Modelfile                      # Ollama pearl-1.5b Modelfile with Samantha persona
│   └── com.rossonerian.pearl-server.plist # macOS LaunchAgent definition
├── state_template/                    # Schema templates for dynamic memory & state
│   ├── USER_PROFILE.md                # User profile, role, ambition, and dynamic learned rules
│   ├── PERSONALITY_STATE.json         # Personality traits, familiarity bond, and circadian mood
│   ├── diary.md                       # Autonomous introspective journal template
│   ├── scratchpad.md                  # Quick scratchpad notes template
│   └── timeline.md                    # OpenHistory interaction audit log
├── Makefile                           # One-command build & install
├── install.sh                         # Bootstrap & deployment script
└── PEARL_V2_SPEC_AND_STATE.md         # Master blueprint & hand-off specification for Strong LLM
```

---

## Quick Start

```zsh
# 1. Build and install
make install

# 2. Talk to Pearl
pearl "Pearl, what is your mood right now?"

# 3. Desktop automation
pearl "open axiom"
pearl "git status in Axiom26"
pearl "volume 50"

# 4. View Pearl's diary
pearl diary
```
