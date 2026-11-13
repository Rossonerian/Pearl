# Pearl Architecture & Data Flow

This document details the internal architecture, components, and communication protocols of Pearl on Apple Silicon macOS.

```mermaid
flowchart TD
    subgraph TriggerLayer ["1. Trigger & Activation Layer"]
        CLI["CLI: pearl '<query>'"]
        HOTKEY["Global Shortcut: Ctrl+Opt+Space"]
        HTTP["HTTP / SSE API: 127.0.0.1:49200"]
    end

    subgraph Orchestration ["2. Orchestration & State Core"]
        DISPATCH["pearl (Bash Dispatcher)"]
        GUARD["pearl-guard (<0.05ms Security Filter)"]
        TELEM["pearl-telemetry (<25ms OpenHistory Context)"]
        STATE["~/.pearl State (Personality, Profile, Diary)"]
    end

    subgraph Presentation ["3. Presentation & Audio Engine"]
        HUD["PearlHUD (Native Swift AppKit Notch Capsule)"]
        TTS["pearl-speak (Studio Sonia Neural Voice)"]
        SOUND["macOS Audio Subsystem (AVAudioPlayer)"]
    end

    subgraph Intelligence ["4. Intelligence & Execution Engine"]
        ACTION["macOS Desktop Action Handlers (open, git, volume, mdfind)"]
        LLM["ZeroClaw / Ollama (pearl-1.5b:latest)"]
    end

    CLI --> DISPATCH
    HOTKEY --> DISPATCH
    HTTP --> DISPATCH
    DISPATCH --> GUARD
    GUARD --> TELEM
    TELEM --> STATE
    DISPATCH --> HUD
    DISPATCH --> ACTION
    DISPATCH --> LLM
    LLM --> TTS
    TTS --> HUD
    HUD --> SOUND
```

## Key Invariants
- **Zero Daemon Overhead**: When not in active conversation, Pearl components exit. 0.0 MB idle RAM.
- **Immediate Visual Confirmation**: HUD launches in under 50ms in Thinking state before LLM generation finishes.
- **Fail-Safe Single Voice**: If network voice synthesis fails, Pearl smoothly falls back to silent terminal text without switching voices or speaking mismatched answers.
