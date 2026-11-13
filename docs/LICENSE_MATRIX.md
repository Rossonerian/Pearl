# Pearl V2 License Matrix & Dependency Audit

This document records the license, copyright, and distribution compliance status of all internal components, system APIs, models, and third-party dependencies evaluated for Pearl V2.

## 1. Core Principles
1. **Repository License**: Apache-2.0 (Permissive with patent grant).
2. **GPL Proscription**: Strict avoidance of GPL-3.0 / AGPL-3.0 copyleft dependencies (e.g. Piper TTS, boring.notch) to protect permissive distribution and enterprise usage.
3. **Model Weight Compatibility**: Commercial-friendly, open weights only.
4. **Clean Linking**: Avoid GPL shared libraries in G2P/phonemizers.

---

## 2. Dependency Audit Matrix

| Component | Role | License | Status | Compliance Notes & Risk Mitigation |
|---|---|---|---|---|
| **Pearl (Core/App/CLI)** | Resident Menu-Bar Shell, Action Engine, IPC | Apache-2.0 | APPROVED | Authored by project owner. |
| **Apple SpeechAnalyzer** | Primary STT (macOS 27) | Apple SDK / Proprietary | APPROVED | Native system framework; no external distribution required; zero GPL risk. |
| **Apple Foundation Models** | Primary Local LLM (`LanguageModelSession`) | Apple SDK / Proprietary | APPROVED | Native on-device system model; Neural Engine accelerated; no binary redistribution. |
| **AVSpeechSynthesizer** | System TTS Fallback | Apple SDK / Proprietary | APPROVED | Native macOS framework (`en-GB` premium voices). |
| **KeyboardShortcuts** | Global Carbon Hotkey (Ctrl+Opt+Space) | MIT | APPROVED | Permissive; authored by Sindre Sorhus; no TCC Input Monitoring required. |
| **SQLite (FTS5)** | Bounded Context & Memory Index | Public Domain | APPROVED | Bundled in macOS Darwin libc / libsqlite3. |
| **Silero VAD (v6)** | Local Voice Activity Detection | MIT | APPROVED | Verified: Silero VAD official license is MIT. Weights are permissively licensed. |
| **Kokoro-82M (Core ML)** | Primary Local Neural TTS | Apache-2.0 | APPROVED | Open weights by hexgrad; Core ML conversion by community/FluidAudio. |
| **G2P / Phonemizer for Kokoro** | Text to Phonemes | MIT / Apache-2.0 | APPROVED (RESTRICTED) | **CRITICAL AUDIT**: Native Kokoro Python relies on `espeak-ng` (GPL-3.0). Pearl Swift pipeline uses Misaki / pure-Swift phoneme lookup table (MIT), completely eliminating `libespeak-ng` GPL linking. |
| **FluidAudio** | Core ML Audio Runtime (Swift) | Apache-2.0 | APPROVED | Native Swift Core ML pipeline for streaming audio on Apple Silicon. |
| **Parakeet-TDT (Core ML)** | STT Fallback | CC-BY-4.0 / Apache-2.0 | APPROVED | NVIDIA FastConformer / Parakeet weights. Permissive with attribution. |
| **Qwen 2.5 / 3.5 2B (MLX)** | Local LLM Fallback (On-Demand) | Apache-2.0 | APPROVED | Run on-demand only via MLX Swift; unloads on idle/memory warning. |
| **Anthropic sandbox-runtime (`srt`)**| Seatbelt Sandbox Isolation | Apache-2.0 | APPROVED | Subprocess containment for T3–T5 tools. |

---

## 3. High-Risk Dependency Verdicts

### Verdict on Piper TTS
- **License**: GPL-3.0.
- **Risk**: Any distribution or static bundling of Piper or its voice models triggers copyleft obligations across the entire binary distribution.
- **Decision**: **REJECTED & DROPPED**. Pearl strictly uses Kokoro-82M Core ML (Apache-2.0) and system `AVSpeechSynthesizer`.

### Verdict on `espeak-ng`
- **License**: GPL-3.0.
- **Risk**: Python Kokoro often wraps `libespeak-ng`.
- **Decision**: **REJECTED FOR LINKING**. Pearl's Swift voice pipeline uses a direct token-to-phoneme dictionary and Core ML acoustic model without linking `libespeak-ng`.

### Verdict on Silero VAD
- **Audit**: Badge text in older README revisions previously pointed to vague dual-licensing; repository `LICENSE` file explicitly specifies MIT.
- **Decision**: **APPROVED**.

*Last Updated: 2026-11-13 (macOS 27.2.1 Golden Gate)*
