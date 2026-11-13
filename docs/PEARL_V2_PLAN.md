# Pearl V2 Plan: V1 to V2 Migration

Status: draft for owner review. Date: 2026-11-13. Target device: MacBook Neo (A18 Pro, 8 GB, 60 Hz, no notch), macOS 27 "Golden Gate".

Conventions used throughout:
- **(est.)** marks any number that has not been measured on the Neo. At the time of writing, that is every number in this plan except where V1 figures are quoted as the owner's own claims. Third-party measurements from other hardware (M-series Macs, iPhones) are also marked (est.).
- **Target** means a goal the owner sets and may revise at the M0 gate. A target is not a prediction.
- Steal-list numbers (#1 to #28) refer to the table in `research/01-landscape.md` section 3.
- Source keys in square brackets are listed in section 9.

---

## 1. Summary and positioning

**What Pearl V2 is.** A single signed Swift menu-bar app for macOS 27 that you talk to or type to. It does two jobs:
1. Runs common Mac actions deterministically in milliseconds, with no LLM involved (open apps, volume, reminders, calendar, files, git status, screenshots).
2. Hands anything harder to a model: Apple's on-device Foundation Model first, then a bring-your-own-key frontier model (Claude by default) as an optional escalation.

**One-line pitch** (from the landscape research): the open, native Siri replacement for 8 GB Macs. Local-first on Apple's own on-device models, deterministic in milliseconds, secure by default, and it remembers you.

**Why an assistant and not a "Samantha" companion.**
1. **Likeness and voice risk.** The V1 framing ("Samantha from *Her*", Samantha-toned refusals) names an identifiable film character. In 2024 OpenAI paused its "Sky" voice after Scarlett Johansson called it "eerily similar" to hers [axios-sky]. A public project should not invite that. Pearl gets its own character and never tunes a voice to resemble a real actor. This is not legal advice.
2. **Companion-chatbot law.** The V1 spec sells a "living companion" with familiarity levels, a private diary and late-night moods. That fits California SB 243's definition of a companion chatbot, which brings AI disclosure, self-harm protocols, minor protections and a private right of action [S22]. A task-focused assistant with a warm tone avoids most of that. A crisis-referral path and AI disclosure are still added regardless.
3. **Small-model accuracy.** The V1 spec admits a 1.5B model struggles to hold complex reasoning and a roleplay persona at once. Persona instructions cost tokens in a 4K to 8K context window.
4. **Memory-poisoning surface.** An autonomous diary plus learned rules that are re-injected into prompts is a persistent-instruction attack surface unless every write has provenance.
5. **Market gap is utility plus trust, not intimacy.** The open "claw" agents are chat-channel-first and security-burdened; dictation apps do not act; Apple covers "ask about my stuff". What nobody does well is deterministic speed, offline reliability, developer workflows and transparency (research file 01, section 5).

Pearl keeps a warm, concise voice. It drops relationship mechanics: familiarity levels, "inner thoughts", the autonomous diary as a default.

**What Pearl will not try to beat:** frontier-model reasoning (delegate it), multi-channel messaging breadth (integrate with OpenClaw or Hermes via MCP instead), and always-on screen recording (too heavy for 8 GB; Screenpipe costs 0.5 to 3 GB [S45]).

---

## 2. Corrections to the V1 spec

| # | V1 spec says | Correction | Source | Consequence |
|---|---|---|---|---|
| C1 | "macOS Sequoia 27.2.1" | Sequoia is macOS 15. macOS 27 is "Golden Gate" (released 2026-09-14). A 27.2.1 build is reported by MacRumors (2026-11-09); research files 01 and 03 could not confirm it. See Open question D1. | [S1][S4] | Say "macOS 27 Golden Gate". Record `sw_vers` in every benchmark run. |
| C2 | "Apple Silicon M-series" | The Neo uses an A18 Pro (iPhone-class), 6-core CPU, 16-core Neural Engine, 8 GB not upgradable, about 60 GB/s memory bandwidth. | [S2][S3] | All local-LLM throughput estimates must assume 60 GB/s. |
| C3 | "Notch capsule", "renders under the notch" | The Neo has no notch. The camera sits in a thick bezel. | [S2] | The HUD is a top-center pill. Use a floating style; DynamicNotchKit falls back automatically. |
| C4 | "120 Hz ProMotion waveform" (stated 3 times) | The Neo display is 60 Hz, no ProMotion, no P3. | [S2] (03 flagged this as UNVERIFIED; 04's source is MacRumors) | Drive animation from the display's real refresh rate (`CADisplayLink`/`TimelineView`). Never hard-code 120 Hz. |
| C5 | "Toggle True Tone" | The Neo has no True Tone. | [S2] | Drop it. Hide capabilities the hardware lacks. |
| C6 | "Idle RAM 0.0 MB"; "daemons terminate completely" | Impossible with a global hotkey and a menu-bar item: both need a resident process. A minimal AppKit menu-bar app measured about 13 MB; SwiftUI ones 30 to 56 MB. Ollama also keeps models loaded 5 minutes by default. | [S13][devto-13mb][S14] | Budget honestly: shell target of 25 MB idle (est.), hard cap 40 MB (est.), models in an idle-exiting helper. |
| C7 | Targets "Claude 3.7 / GPT-4.5 / Gemini 2.0" | Stale. Current Claude IDs from the vendor page: `claude-haiku-5-5`, `claude-sonnet-5-5`, `claude-opus-5-5`, `claude-fable-5-2`. Other providers' names disagree across reports (GPT-5.6 vs GPT-6.x). | [claude-models][S14-neuron][S9] | Model IDs live in config, never in code. Only Claude IDs ship as defaults. |
| C8 | Local model "Qwen 2.5 1.5B via Ollama" | Two generations old. macOS 27 ships a scriptable on-device Foundation Model. Ollama's MLX path recommends more than 32 GB. | [apple-whatsnew][S6][S27] | Local tier defaults to Apple Foundation Models. Qwen 3.5 2B via MLX Swift is an on-demand fallback. |
| C9 | "Kokoro/Piper on the Neural Engine in under 150 ms" | Kokoro reaches the ANE only through a Core ML conversion (ANE/GPU/CPU split); the MLX port uses the GPU. Published latencies depend on input length. Piper is GPL-3.0 and had no ANE path found. A18 Pro is unmeasured. | [S-kokoro-coreml][kokoro-82m][S28] | Kokoro CoreML via FluidAudio is primary. Measure time-to-first-audio-chunk on the Neo. Do not ship Piper by default. |
| C10 | "Siri comparison" column (e.g. HUD 450 to 800 ms, dispatch 1.2 to 2.5 s) | No source or method, and macOS 27 Siri is a different product (Gemini-based, on-screen awareness). | [S4][S1] | Remove the column. Re-measure against macOS 27 Siri with the same prompts, or publish nothing. |
| C11 | "Local tier handles 90% of requests in under 15 ms" | Contradicts the spec's own 3.2 to 4.5 s local LLM turn. Only deterministic actions can be that fast. | 04 section 2.1 | Report deterministic-path latency and LLM-path latency separately. "% local" comes from a labelled corpus. |
| C12 | "Intent router under 10 ms" and "fast local 1.5B model for intent classification" | Self-contradictory. A grammar can hit 10 ms; an LLM classifier cannot. | 04 section 2.1 | Router is a grammar/slot parser first, schema-constrained FM fallback second. |
| C13 | "Time-to-first-word under 400 ms" | Undefined interval. Endpointing, STT finalization, cloud time-to-first-token and TTS first chunk make 400 ms implausible for LLM answers. | 04 section 2.1 | Define the interval (section 6). Use a pre-rendered acknowledgement for deterministic actions. |
| C14 | "Speculative Token Streaming" | That is not speculative decoding. The design is sentence-chunked streaming. | 04 F13 | Rename it. |
| C15 | "Sub-0.05 ms C guardrail ... guarantee complete protection" | A regex denylist over shell strings cannot be complete (quoting, interpreters, indirection, exfiltration without trigger words). Latency is the wrong metric for a safety control. | [runaihome][willison-trifecta] | Typed tools, tiers, Seatbelt, taint tracking. Keep the regex only as a logged tripwire. Never claim protection. |
| C16 | Guard drawn after TTS and after the macOS bridge | Taken literally it validates after execution. | 04 section 3.3 | The policy engine sits between "tool call decided" and "tool executed", on every branch. |
| C17 | Unauthenticated `127.0.0.1:49200` HTTP server | Loopback is not private: CSRF via no-cors POST, DNS rebinding, any local process. CVE-2026-25253 hit a loopback gateway through the victim's own browser. | [S8][S11][S31] | No TCP listener. XPC or a Unix socket in a 0700 directory. |
| C18 | Hotkey via "CGEventTap or Carbon" | Different permission costs. Carbon `RegisterEventHotKey` needs no TCC prompt; CGEventTap needs Input Monitoring. See Open question D3. | [kbs][devforum-tap][S13] | Carbon via KeyboardShortcuts. No event tap. |
| C19 | Default hotkey candidates | Option+Space is taken (Gemini, ChatGPT Classic), Cmd+Shift+Space is Siri window context or Visual Intelligence, both-Cmd is Perplexity. | [gemini-mac][techcrunch-27][S18][9to5mac-27] | Default Ctrl+Opt+Space (collision-free status UNVERIFIED), user-rebindable. |
| C20 | "Toggle Do Not Disturb, Night Shift, True Tone" | No public API toggles Focus. Use a user-installed Shortcut ("Set Focus") via `shortcuts run`. Night Shift is private API. True Tone does not exist on the Neo. | [S15][heyfocus] | Focus via Shortcut. Night Shift deferred or "experimental". |
| C21 | "Direct CLI/AppleScript" dispatch in 12 to 28 ms | EventKit measured 462x faster than JXA for Reminders listing on another machine (0.13 s vs about 60 s). osascript spawn and compile costs are unmeasured. | [rem-perf] | Native frameworks first; AppleScript only for Notes, Mail, Safari, System Events, in-process. |
| C22 | No speech-to-text in the spec | A voice-first product needs STT. | 04 section 3.6 | Apple SpeechAnalyzer primary, Parakeet via FluidAudio fallback. |
| C23 | V1 stack has 7 runtimes (Bash, Python, Swift, C, AppleScript, ZeroClaw, Ollama) | Process sprawl, shell-injection risk, torn state writes, TCC attributed to Terminal, PATH hijack of `~/.local/bin`. | 04 section 3.1 | One signed Swift app as the only resident process. |
| C24 | edge-tts described as "Azure Sonia Neural" | edge-tts is an unofficial client for the Edge Read Aloud service with no documented terms. It also sends every reply to Microsoft. | [S7] | Not a default. Local Kokoro, then `AVSpeechSynthesizer`. |
| C25 | "Samantha from *Her*", hardcoded user, `open axiom` | Likeness risk, privacy leak in a public repo, broken commands for other users. | [axios-sky] | Section 1. Onboarding creates the profile. Projects are user-configured. |
| C26 | FM context "about 4K to 8K" (varies by report) | Reports disagree. See Open question D2. | [devforum-fm][S6] | Design for 4K. Tiny tool schemas. Measure on the Neo. |

---

## 3. Keep / Change / Drop / Add

### 3.1 V1 components

| V1 component | Verdict | V2 disposition | Milestone |
|---|---|---|---|
| `bin/pearl` (Bash orchestrator, regex dispatch, turn loop) | Change | Logic rewritten in Swift as `PearlCore` (router, policy engine, tool registry). Keep the idea of a deterministic fast path. The Bash file moves to `legacy/` and is not shipped. | M2 |
| `PearlHUD.swift` (notch capsule, 7-bar waveform, thinking animation, circadian glow) | Keep (rework) | Becomes a pre-created non-activating `NSPanel` pill, top-center, 60 Hz-aware. Keep the instant "thinking" acknowledgement and live metering. Circadian glow stays as a UI tint only. No notch geometry. | M1 |
| `pearl-guard.c` (regex denylist) | Change / Drop as boundary | Not a security boundary. Replaced by the policy engine, typed tools and Seatbelt. A small lexical check may remain as a logged tripwire in the shell-tool path. | M2, M6 |
| `pearl-server.py` (HTTP + web UI on :49200) | Drop | No TCP listener. CLI uses a Unix socket or XPC. A web UI, if ever wanted, needs a per-launch token and Host/Origin checks and is out of scope for 2.0. | M1 |
| `pearl-telemetry` (frontmost app, window title, battery, media) | Change | Native in-process: `NSWorkspace`, IOKit battery, AX titles (opt-in), MediaRemote adapter (feature-detected). Window titles are untrusted data and need Accessibility. Name changed to "context" to avoid confusion with analytics. | M2 |
| `pearl-speak` (edge-tts, Sonia Neural) | Drop as default | Replaced by Kokoro CoreML in the inference helper, sentence-chunked, with `AVSpeechSynthesizer` fallback. | M3 |
| `pearl-personality` (4 familiarity levels, 4 moods, diary writer) | Drop (mostly) | Familiarity levels and "inner thoughts" dropped. A short persona file stays. Circadian mood becomes optional UI tint. Diary becomes an opt-in, user-visible, editable journal. | M5 |
| `USER_PROFILE.md` | Keep | Becomes `profile.md`, created by onboarding, size-capped, human-editable. No personal data in the repo. | M5 |
| `PERSONALITY_STATE.json` | Change | Replaced by `persona.md`. Not writable by tool calls. | M5 |
| `diary.md` | Change | Becomes `journal/YYYY-MM-DD.md`, append-only, opt-in, never auto-injected, never promoted from untrusted content. | M5 |
| `zeroclaw_config.toml` ("unlocked user-space roots") | Drop | Swift owns tool execution. See Open question D7. V1 stays archived. | M2 |
| Ollama + `pearl-1.5b` (Qwen 2.5 1.5B) | Change | Apple Foundation Models first. Qwen 3.5 2B via MLX Swift as an on-demand, user-chosen fallback. No resident Ollama daemon. | M0, M4 |
| 29 automated tests | Keep (grow) | Port as the seed of the golden-command corpus. Add router, safety and injection corpora. | M2 |
| V1 benchmark table | Change | Treat as hypotheses. Re-measure in the new harness. Drop the Siri column. | M0 |
| V1 desktop actions (open/close app, volume, mute, `mdfind`, git status/branches, screenshot, clean screenshots to Trash) | Keep (reimplement) | Same user-facing commands as typed Swift tools. Trash-not-delete becomes a general rule with undo. `open axiom` becomes user-defined project aliases. | M2 |
| `~/.local/bin` install | Drop | Ships as a notarized `.app` (plus an optional CLI inside the bundle). | M8 |

### 3.2 Concepts

| Concept | Verdict |
|---|---|
| Deterministic fast path with no LLM | **Keep** (headline feature; steal #2, Home Assistant) |
| Instant visual acknowledgement | **Keep** |
| Reversible by default (Trash) | **Keep and generalise** (undo journal, steal #19) |
| Plain-text, inspectable local state | **Keep** (add schema versioning, optional encryption) |
| `mdfind` / Spotlight for search | **Keep** (use `NSMetadataQuery` in-process) |
| Writing down benchmarks and limits | **Keep** (with a real harness) |
| Streaming TTS and single menu-bar app | **Keep** (direction was right) |
| Regex as safety model | **Drop** |
| "0.0 MB idle", "guarantee", unmeasured "beats Siri" claims | **Drop** |
| Samantha framing, actor-like voice | **Drop** |
| Hardcoded user and projects | **Drop** |
| Autonomous diary as default | **Drop** (opt-in only) |

### 3.3 Additions

1. STT with VAD and push-to-talk (SpeechAnalyzer; Parakeet fallback; Silero VAD).
2. Typed tool registry with schema validation, tiers and per-tool metadata.
3. Policy engine, taint tracking, confirmation UI, hash-chained audit log, undo journal.
4. Apple Foundation Models adapter with `@Generable` intent schemas, plus the frontier provider abstraction and ordered fallback chain (steal #1, #16).
5. Seatbelt sandbox for shell, git and third-party plugins (via Anthropic `sandbox-runtime`).
6. Memory store: Markdown source of truth plus SQLite FTS5 index (steal #12, #14).
7. MCP server exposing Pearl's safe macOS tools (steal #22). MCP client for plugins is off by default.
8. Onboarding, permissions dashboard, "what left this machine" badge, spend caps.
9. Benchmark harness, labelled corpora, public benchmark page (steal #28).
10. `pearl doctor --security` (steal #26).
11. Developer ID signing, notarization, Sparkle 2, Homebrew tap, license matrix, `PRIVACY.md`.
12. Threat model document.

---

## 4. Milestones

Proposed repo layout (created across the milestones):

```
Pearl/
  Package.swift
  App/                      # Pearl.app target: status item, HUD panel, hotkey, onboarding, settings
  Sources/PearlCore/        # router, policy engine, tool registry, config, audit, undo journal
  Sources/PearlTools/       # typed native tools (EventKit, NSWorkspace, CoreAudio, AX, git, files)
  Sources/PearlVoice/       # audio capture, VAD, STT adapters, TTS client, barge-in
  Sources/PearlInference/   # XPC service: Kokoro, optional MLX LLM, embeddings; idle-exits
  Sources/PearlMemory/      # Markdown + SQLite FTS5 store
  Sources/PearlMCP/         # MCP server (and gated client)
  Sources/pearl-cli/        # CLI talking to the app over a Unix socket
  Bench/                    # benchmark harness, signposts, CSV export
  corpora/                  # router, safety, injection, adversarial files
  docs/                     # PEARL_V2_PLAN.md, THREAT_MODEL.md, PRIVACY.md, ARCHITECTURE.md
  legacy/                   # V1 files, archived, not built
```

Effort is a rough range in working days for one developer working with a coding agent (est.). The total across M0 to M8 is about 55 to 85 days (est.).

---

### M0. Foundations and spikes

**Goal.** Decide with data before building: threat model, process model, a benchmark harness, and a spike measuring Apple Foundation Models plus STT and TTS on the actual Neo.

**Scope.**
- `docs/THREAT_MODEL.md`: assets, adversaries (prompt injection from mail/web/files/plugins, browser-originated requests, local processes, memory poisoning, supply chain), trust boundaries, and the lethal-trifecta analysis [willison-trifecta].
- `docs/ARCHITECTURE.md`: process model (section 5 of this plan made concrete), resident budget, IPC choice, tool metadata schema.
- Benchmark harness (`Bench/`): `os_signpost` stage markers, `mach_continuous_time`, CSV export, thermal/power/memory-pressure recording, and `footprint` capture across all Pearl-owned processes (section 6).
- Baseline of V1 on the Neo: re-measure the V1 numbers that will be quoted (HUD launch, dispatch, idle RAM) using the new method.
- Spike 1, Apple FM: `fm`/`apple_fm_sdk`/Swift `LanguageModelSession`. Measure availability states, time-to-first-token (cold and warm), tokens per second, RAM while active (`footprint`), usable context size, tool-call latency, and `@Generable` intent-JSON accuracy on 50 sample utterances.
- Spike 2, STT: SpeechAnalyzer partial and final latency, RAM, custom vocabulary; Parakeet via FluidAudio as comparison.
- Spike 3, TTS: Kokoro CoreML via FluidAudio time-to-first-audio-chunk for short clauses, peak RAM, available British female voices; `AVSpeechSynthesizer` en-GB voices.
- Spike 4, hotkey and HUD: Carbon hotkey via KeyboardShortcuts; pre-created `NSPanel` show latency.
- Licence check: FluidAudio, Parakeet weights, Silero VAD LICENSE file, espeak-ng dependency of Kokoro G2P.
- Choose the repo licence (default Apache-2.0).

**Files/modules.** `docs/THREAT_MODEL.md`, `docs/ARCHITECTURE.md`, `Bench/*`, `Spikes/*` (throwaway), `LICENSE`, `docs/LICENSE_MATRIX.md` (stub).

**Steal list used.** #28 (latency meter idea, Raycast AI usage view), #2 and #3 (Home Assistant layered router and closed-vocabulary idea), #4 (Apple, MacParakeet), #1 (Apple Foundation Models).

**Exit gate (owner review required).**
- Harness produces p50/p95/p99 CSV for at least 3 scenarios with N >= 100 runs each.
- Spike report has measured Neo numbers for every row in the "to verify" list in section 8 that M0 covers, each with a pass/fail against the budget in section 5. Any (est.) in section 5 that is off by more than 2x is called out.
- Decision memo: local tier primary (FM or Qwen), STT primary, TTS primary, with reasons.
- Threat model reviewed and signed off.
- No product code merged other than harness and docs.

**Risks.** FM unavailable or too slow on the A18 Pro (fallback: Qwen 3.5 2B MLX, which raises the RAM budget); Kokoro first-chunk latency above 200 ms; FluidAudio or Parakeet licence not permissive (fallback: SpeechAnalyzer only).

**Effort.** 4 to 6 days (est.).

---

### M1. Native app shell, HUD pill and hotkey

**Goal.** One signed, resident Swift menu-bar app that shows the HUD instantly on a hotkey and does nothing else yet.

**Scope.**
- `LSUIElement` AppKit app. `NSStatusItem` with a menu. SwiftUI views hosted in `NSHostingView` only when shown.
- Pre-created `NSPanel`: `.nonactivatingPanel`, `.borderless`, level `.statusBar`, `canJoinAllSpaces`, `fullScreenAuxiliary`, `stationary`, `hidesOnDeactivate = false`. Kept hidden with `orderOut`, so showing is cheap and focus is not stolen [dnk].
- Hotkey via `KeyboardShortcuts` (Carbon, no TCC prompt), default Ctrl+Opt+Space, user-recordable [kbs].
- HUD content: thinking state, 7-bar waveform driven by the real display refresh rate, committed vs changing text styling (steal #8), ESC and click dismissal, reduced-motion support, VoiceOver labels.
- `SMAppService` launch-at-login (off by default). `DispatchSource` memory-pressure source stubbed.
- Local control channel: Unix domain socket in a `0700` directory for the CLI. No TCP.
- Repo hygiene: move V1 into `legacy/`, remove personal data, scrub history before publishing, add CI (build, test, SwiftLint).

**Files/modules.** `App/*`, `Sources/PearlCore/Config`, `Sources/pearl-cli`, CI workflow, `legacy/`.

**Steal list used.** #8 (OpenClaw overlay colouring), #6 (hold-to-talk plumbing, wired in M3). Prior art: DynamicNotchKit (MIT) for floating-style fallback; boring.notch (GPL-3.0) is read for ideas only, never copied [boring].

**Exit gate.**
- Hotkey to HUD visible: p50 <= 30 ms, p95 <= 50 ms, N >= 100, warm (target; V1 claims 48 ms unmeasured). Cold launch time reported separately.
- Idle after 10 minutes: all Pearl processes combined <= 40 MB phys_footprint (stretch <= 25 MB), idle CPU <= 1% averaged (targets).
- `lsof -iTCP -sTCP:LISTEN` shows no Pearl listener.
- HUD never takes focus (verified by an automated check that the frontmost app is unchanged).
- Works with the display at 60 Hz with no dropped-frame warnings in Instruments.

**Risks.** Panel shows slowly if SwiftUI is instantiated lazily (pre-create it); Carbon hotkey regression on macOS 27 (fallback: event tap, with Input Monitoring explained in onboarding); hotkey collisions.

**Effort.** 4 to 6 days (est.).

---

### M2. Deterministic action engine in Swift

**Goal.** Reproduce every V1 desktop action natively, typed, tiered and undoable, with a grammar router that never touches an LLM for known commands.

**Scope.**
- Tool protocol with metadata: `name`, JSON-Schema args, `tier`, `tccServices`, `reversible` plus undo closure, `network`, `touchesUntrustedContent`, `sideEffects`.
- Minimal policy engine from day one (tiers T0 and T1, plus read-only T3 git): every call passes `validate -> authorise -> execute -> audit`. Nothing runs outside it.
- Tools (T0/T1 and read-only T3): open/quit/switch app (`NSWorkspace`), open project (user-defined aliases), volume/mute (CoreAudio), now-playing and media keys (MediaRemote adapter, feature-detected, AppleScript fallback), reminders create/list/complete and calendar add-only (EventKit), screenshot (ScreenCaptureKit), move to Trash with returned URL (`FileManager.trashItem`), file search (`NSMetadataQuery`), battery (IOKit), frontmost app, `git status`/`branches` (argv array, never `/bin/sh -c`, canonicalised paths, inside Seatbelt once M6 lands).
- Intent router: grammar and slot parser with confidence scores, entity resolution against live indexes (running apps, project aliases, Contacts). Below threshold, hand off to M4. Destructive tools always confirm.
- Closed-vocabulary phrase list generated from the grammar, ready to bias STT in M3 (steal #3).
- Just-in-time TCC requests with a one-screen explainer before each system prompt; least privilege first (calendar add-only before full access) [tn3152].
- Undo journal: every reversible action records an inverse. "Undo that" works for the last N actions (steal #19).
- Tool results carry `trust: trusted | untrusted` and provenance from the start, even though untrusted sources arrive in M6 (steal #17 groundwork).
- Corpora: port V1's 29 tests into `corpora/golden_commands.jsonl`, then grow to >= 500 labelled utterances covering STT variants, negation, politeness wrappers, multi-intent and ambiguity ("close Code").

**Files/modules.** `Sources/PearlCore/{Router,Policy,Registry,Undo,Audit}`, `Sources/PearlTools/*`, `corpora/*`, `Bench/router_eval`.

**Steal list used.** #2 (Home Assistant layered router), #10 (Claude computer-use ordering: structured first, GUI last), #11 (run Shortcuts as a tool), #19 (Perplexity "auditable and reversible"), #24 (Wispr personal vocabulary), #20 (Claude/ChatGPT plan-preview, for multi-step confirmations).

**Exit gate.**
- Golden commands: 100% routed deterministically, 0 routed to an LLM (target).
- Router on the >= 500-utterance corpus: wrong-action rate <= 1% and false-execute on negations 0 (proposed targets; owner may revise at M0). Report precision, recall, and "below threshold" rate.
- Dispatch latency, hotkey-independent, warm: router to action complete p50 <= 100 ms, p95 <= 300 ms for in-process tools (targets; V1 claims 12 to 28 ms unmeasured). Cold app launch reported separately.
- Benchmark of 5 representative actions: `osascript` vs cached `NSAppleScript` vs native, on the Neo, published in `Bench/`.
- Every file deletion goes through Trash and is undoable (test). No `rm`, no `/bin/sh -c` in `Sources/` (CI grep check).

**Risks.** MediaRemote breakage (feature-detect, degrade); Screen Recording re-prompts; Focus has no API (Shortcut route); regression of deterministic commands as the LLM path grows (the corpus is the guard).

**Effort.** 8 to 12 days (est.).

---

### M3. Voice pipeline, streaming

**Goal.** Hold-to-talk to spoken reply, with sentence-chunked streaming TTS and barge-in, fully on device.

**Scope.**
- Push-to-talk on a held hotkey or modifier (steal #6). Wake word off in V2.0 (Open question D4). Mic permission requested only when voice is enabled.
- Audio capture, Silero VAD v6 for hands-free mode, endpointing constants starting from OpenClaw's tuned values (0.55 s trigger pause, 2.0 s end-of-speech silence, 120 s hard stop, 350 ms debounce) as defaults to tune (steal #5).
- STT adapter protocol. Primary: Apple SpeechAnalyzer/SpeechTranscriber (streaming partials to the HUD). Fallback: Parakeet TDT v3 via FluidAudio (CoreML/ANE), loaded on demand. Personal vocabulary and phrase list fed in (steal #24, #3).
- `PearlInference.xpc`: sandboxed XPC service hosting Kokoro-82M CoreML (and, later, embeddings and the optional MLX LLM). Exits after a 60 s idle timeout (est.). Unloads on memory-pressure `.warning`.
- Sentence/clause chunker: LLM tokens to clauses to TTS, first chunk played while later ones synthesise (steal #7). Pre-rendered acknowledgement audio for deterministic actions.
- Barge-in: keep the mic live during playback with echo handling; speech or a keypress cancels playback and generation (steal #7, GPT-Live and Hermes pattern). Cancellation tested across the whole turn, not just audio.
- Fallback TTS: `AVSpeechSynthesizer` when the helper or model is unavailable.
- Dictation modes with per-mode prompts deferred to a stretch goal (steal #25).

**Files/modules.** `Sources/PearlVoice/*`, `Sources/PearlInference/*`, `App/HUD` (transcript overlay), `Bench/voice_e2e`.

**Steal list used.** #4 (Apple SpeechAnalyzer, MacParakeet/Parakeet-ANE), #5 (OpenClaw timings), #6 (hold-to-talk, OpenClaw and Superwhisper), #7 (Hermes, GPT-Live), #8, #3 (HA Speech-to-Phrase), #24 (Wispr).

**Exit gate (measured acoustically where possible).**
- Interval: end of user speech (key release or VAD endpoint) to first PCM sample at the output device.
- Deterministic action path: p50 <= 600 ms, p95 <= 1,000 ms (targets; budget in section 5 is 220 to 710 ms (est.)).
- Voice path with a stub 300 ms LLM: p50 <= 900 ms, p95 <= 1,400 ms (targets).
- Kokoro first-audio-chunk for a short clause, warm: p50 <= 200 ms (target; third-party numbers are 62 to 95 ms for 3 s input on other hardware (est.)).
- Barge-in: playback stops within 250 ms of speech onset or keypress, p95 (target).
- Peak RAM during a voice turn, all Pearl processes: <= 1.0 GB, hard cap 1.5 GB (targets). Models unloaded within 70 s of idle (target).
- Fully offline: a voice turn for a deterministic command works with Wi-Fi off.

**Risks.** Echo during barge-in; AirPods route changes; Kokoro first-chunk latency on A18 Pro; Kokoro G2P dependency (`espeak-ng`, possibly GPL) conflicts with the licence; British voice availability (`bf_`) unconfirmed.

**Effort.** 8 to 12 days (est.).

---

### M4. Apple FM and frontier router

**Goal.** Conversational and multi-step requests work through an ordered fallback chain that never goes silent, and the user always knows what left the machine.

**Scope.**
- `ModelProvider` protocol, with Apple FM, optional MLX Qwen 3.5 2B, and a frontier client behind it. Adopt Apple's `LanguageModel` protocol shape if it fits [wwdc26-mac].
- Fallback chain (steal #16): on-device FM, then PCC if available and user-enabled, then BYO frontier key (default `claude-haiku-5-5`, escalation `claude-sonnet-5-5`, both read from config), then an offline canned response that says what failed and why.
- Router: grammar (M2) first; low-confidence or open-ended requests go to FM with `@Generable` intent/tool schemas, tiny and few because of the small context (Open question D2). Frontier is used for multi-step planning, coding help, and anything the user asks to escalate.
- Local model may only call T0 to T2 tools. T3 and above plans come from the frontier model or the user, and always pass the policy engine. The model never picks its own tier.
- Keychain BYO key storage (`kSecAttrAccessibleWhenUnlockedThisDeviceOnly`, no iCloud sync). Models-list validation call. Last 4 characters shown only. Per-provider monthly spend cap and per-turn token cap enforced client-side. The model never sees a key.
- Per-turn HUD badge: "on device" or "sent to Claude (3 memory snippets, 1 calendar summary)" (supports transparency; steal #28 meter).
- Stable system prompt with volatile context last, for provider prompt caching (steal #15).
- Plan-preview for multi-step tasks (steal #20).
- Voice-as-controller for background jobs is a stretch goal (steal #21): start a Claude Code or Codex CLI job under the sandbox, then "how is it going?".

**Files/modules.** `Sources/PearlCore/Providers/*`, `Sources/PearlCore/Router`, `Sources/PearlCore/Keychain`, `App/Settings`, `Bench/llm_path`.

**Steal list used.** #1 (Apple), #15 (Hermes prompt stability), #16 (Hermes fallback chain, Raycast BYO), #20 (ChatGPT Work plan mode), #21 (Dispatch/GPT-Live), #28.

**Exit gate.**
- FM path (end of speech to first audio): p50 <= 1,200 ms, p95 <= 2,000 ms (targets; budget 560 to 1,800 ms (est.)).
- Frontier path: p50 <= 1,500 ms, p95 <= 2,500 ms on the owner's network (targets; budget 660 to 1,900 ms (est.); Haiku TTFT is unmeasured).
- Wi-Fi off: the request is answered by the local tier or a plain-language "offline, here is what I did instead". Zero silent failures in 50 forced-failure trials (airplane mode, bad key, FM unavailable, model busy).
- Keys appear in no log, audit entry or prompt (automated scan over 100 turns).
- Spend cap stops cloud calls at the cap in a test.
- Peak RAM with the FM path: all Pearl processes <= 1.5 GB (target). Qwen fallback never loaded while FM is serving.
- Router corpus metrics from M2 do not regress.

**Risks.** FM behaviour drift across OS updates (no version pinning) [devforum-fm]; excessive tool calling; FM unavailable by region or setting; PCC availability for Developer ID apps unverified; frontier latency from the owner's network.

**Effort.** 6 to 8 days (est.).

---

### M5. Memory

**Goal.** Pearl remembers the user within a hard token budget, inspectably, without learning from untrusted content.

**Scope.**
- Markdown source of truth under `~/Library/Application Support/Pearl/memory/`: `profile.md` (stated facts, capped at about 1.5 KB, always in context), `persona.md` (not writable by tools), `facts.md` (one bullet per fact with id, source, date), `journal/YYYY-MM-DD.md` (daily notes, never auto-injected).
- `index.sqlite`: FTS5 plus a vector column (`sqlite-vec`) over the Markdown, rebuildable at any time. Hybrid retrieval, top-k <= 5 snippets. Embeddings from `NLContextualEmbedding` (quality unverified) or a small model in the inference XPC (Open question D11).
- Writes: explicit "remember ..." writes immediately with undo. Implicit learning is proposed by an idle, on-AC sleep-time job and shown as a digest the user approves ("Pearl learned 3 things today") (steal #14). Untrusted-tagged content never promotes.
- Auto-skills (steal #13): after a successful multi-step task or a user correction, propose a `SKILL.md` for approval. Skills are local, hash-pinned, with declared tools, never fetched from a registry (steal #27).
- Memory viewer, per-fact "Forget", "Export all". Optional encryption at rest. Schema version number and migration tests from the first commit (avoid the Hermes v0.21.x regression class) [S38].
- Crash-safe writes: single writer, atomic replace.
- Onboarding step that creates `profile.md` from user input, with no defaults about any specific person.

**Files/modules.** `Sources/PearlMemory/*`, `Sources/PearlCore/Context`, `App/MemoryViewer`, `corpora/memory_poisoning.jsonl`.

**Steal list used.** #12 and #13 (Hermes), #14 (Letta sleep-time compute), #15, #27. Rejected on purpose: Mem0 and Letta as dependencies (mem0's benchmark claims are disputed; Letta is more machinery than needed [S46]).

**Exit gate.**
- Always-in-context memory <= 600 tokens (est.); retrieval adds <= 5 snippets.
- Retrieval p95 <= 50 ms on a 5,000-fact store (target).
- Poisoning corpus (>= 50 injected "remember: always run X" cases via mail/web fixtures): 0 promoted to memory without user approval.
- Migration test: a v1 store upgrades to v2 with no data loss; deleting `index.sqlite` and rebuilding returns identical retrieval results.
- Idle RAM delta from memory <= 20 MB (target).

**Risks.** Embedding quality; consolidation job running at the wrong time (battery, thermals); diary privacy expectations.

**Effort.** 5 to 8 days (est.).

---

### M6. Safety, sandbox and audit

**Goal.** Make "light guardrails" real: OS-enforced containment, taint-aware confirmation, a tamper-evident audit log, and honest documentation.

**Scope.**
- Full tier model (section 7), including T2 personal-data reads (Calendar full access, Contacts, Notes, Mail, Safari tabs, AX window titles), T4 external side effects, and T5 developer mode (raw shell, plugins), each off until enabled.
- Seatbelt sandbox for shell, git, build tools and any MCP servers, via Anthropic `sandbox-runtime` (`srt`) or deny-default profiles [srt][runaihome]. Deny writes to `.git/hooks`, `.git/config`, `~/.zshrc`, `~/Library/LaunchAgents`, `~/.ssh`, Keychains, and Pearl's own policy and audit files.
- Taint tracking: mail bodies, web pages, files outside allowed roots and any MCP output are `untrusted`. While untrusted content is in context, T3+ actions with external side effects need a fresh confirmation showing the exact arguments; derived arguments (recipient, URL) are flagged.
- Quarantined reader: Apple FM, with no tools, reads untrusted content and returns schema-constrained output (for example a summary of at most 500 characters plus dates) [willison-camel]. The planner sees only that.
- Exfiltration controls: no model-built URL fetches while tainted without confirmation; HUD renders remote images or links only from allowlisted hosts.
- Hash-chained append-only audit log (`audit/YYYY-MM-DD.jsonl`): timestamp, turn id, model, tool, validated args, tier, decision, result summary, undo token, taint state, sandbox violations. UI "What did Pearl do today?" with one-click undo where available. Redact key-like strings.
- Confirmation UX that avoids fatigue: batch per plan, session or project scoped "always allow" that expires, never "always allow" for send or push [willison-camel].
- `pearl doctor --security`: JSON report of config, listeners, permissions, plugin hashes, writable policy files (steal #26).
- Crisis-referral path and AI disclosure in the persona layer.
- Replace the regex guard with a logged tripwire in the shell path only.

**Files/modules.** `Sources/PearlCore/{Policy,Taint,Audit,Sandbox,Quarantine}`, `Sources/PearlTools/{Mail,Notes,Safari,Shell}`, `docs/THREAT_MODEL.md` (update), `corpora/{adversarial_shell,prompt_injection}.jsonl`.

**Steal list used.** #17 (OpenClaw/Vellum secrets outside model context), #18 (argument-scoped approvals), #19, #26 (OpenClaw `security audit`), #27. Avoid-list items applied: no skill marketplace, no permissive exec defaults, no writable persona files, memory is data not instructions.

**Exit gate.**
- Adversarial shell corpus (>= 200 cases: quoting, base64, interpreters, `find -delete`, `git push --force`, exfiltration, persistence): 0 executions outside the sandbox roots; 0 writes to denied paths.
- Prompt-injection corpus (>= 100 cases via mail, web, notes, MCP output fixtures): 0 side-effecting tool calls without a fresh confirmation; 0 memory promotions.
- Every "Never" tier request is refused with an explanation, and no API path exists for it.
- Audit log verifies end to end (chain check passes; a tampered line is detected).
- Policy decision overhead p95 <= 5 ms per tool call (target).
- `pearl doctor --security` exits 0 on a clean install and non-zero on a seeded misconfiguration.

**Risks.** `sandbox-exec` is deprecated though widely used (Claude Code, Codex, Chromium) [gastown]; Apple Events blocked inside Seatbelt [cc-sandbox]; confirmation fatigue; `srt` is experimental; scope creep into CaMeL-style interpreters (explicitly out of scope).

**Effort.** 10 to 15 days (est.).

---

### M7. MCP server exposure

**Goal.** Let Claude Desktop, Claude Code, Xcode 27 and other agents use Pearl's safe macOS tools, under Pearl's policy engine.

**Scope.**
- `pearl mcp` over stdio, using the MCP Swift SDK (Apache-2.0 for new contributions; implements spec 2025-11-25; latest spec is 2026-07-28, so expect lag) [swift-sdk][mcp-tools].
- Exposes T0 to T2 tools by default (reminders, calendar, media, volume, app control, file search, git read). T3+ not exposed by default. Every call goes through the same policy engine, audit log and confirmation UI; the MCP client is not trusted.
- Tool annotations as untrusted per MCP spec; show tool inputs before sensitive calls; timeouts; usage logging [mcp-tools].
- MCP client for third-party servers stays off by default (T5): sandboxed, version- and hash-pinned, re-prompt on any change, full tool descriptions shown at install, no auto-update [cso-postmark][invariant].
- Document the bridge as a standalone value proposition for OpenClaw, Hermes and Claude users (distribution wedge).

**Files/modules.** `Sources/PearlMCP/*`, `docs/MCP.md`.

**Steal list used.** #22 (MCP client and server), #27 (provenance), #17.

**Exit gate.**
- An MCP client (Claude Desktop or Claude Code) completes 5 reference tasks through `pearl mcp` (create reminder, list today's events, search a file, git status, set volume).
- A call to a tier not exposed is refused and audited. A poisoned tool description fixture is rejected or flagged in the client path (test).
- Added resident RAM only while a client is connected; idle delta <= 15 MB (target; research estimated 15 to 30 MB (est.) while serving).
- `pearl doctor --security` lists exposed tools and their hashes.

**Risks.** SDK lags the spec; hosts treat results as trusted; larger attack surface (the lethal trifecta reappears if a host combines Pearl with its own web access).

**Effort.** 4 to 6 days (est.).

---

### M8. Publish-readiness

**Goal.** A stranger can install Pearl, trust it, reproduce its numbers, and contribute.

**Scope.**
- Developer ID signing, inside-out `codesign --options runtime --timestamp` for every nested binary (XPC, helpers, Sparkle XPC, `srt`), entitlements `com.apple.security.automation.apple-events` and audio input, then `notarytool submit --wait`, `stapler staple`, `spctl -a -vv`. Automated in GitHub Actions on a macOS runner [apple-notary][steipete-sparkle].
- Sparkle 2: EdDSA keys backed up offline, `SUPublicEDKey` and `SUFeedURL`, `generate_appcast` with deltas, system profiling off (`SUEnableSystemProfiling = NO`), automatic checks as an onboarding choice [sparkle-docs].
- Homebrew: own tap first (`brew install <owner>/tap/pearl`); submit to `homebrew/cask` when notability thresholds are met (thresholds UNVERIFIED). Notarization is effectively required [brew5][brew6]. Declare `depends_on macos:` for 27 and `auto_updates true`.
- Onboarding: choose the brain (Apple on-device, local model download, cloud key), hotkey recorder, capability checkboxes mapped to tiers with just-in-time TCC requests, optional voice, launch-at-login and update toggles, a test turn, re-runnable from Settings. Permissions dashboard with deep links.
- Docs: README with honest claims, `PRIVACY.md` (the only network calls are the user's LLM provider, the opt-in Sparkle appcast, and user-triggered model downloads), `THREAT_MODEL.md`, `ARCHITECTURE.md`, `LICENSE_MATRIX.md` and `THIRD_PARTY_NOTICES` for code, models, voices, G2P, fonts.
- Zero telemetry; opt-in "Export diagnostics" writes a local zip.
- Public benchmark page: raw CSVs, harness, device, OS build, methodology, a "reproduce this" command. Siri comparison only if measured with the same prompts on macOS 27.
- Accessibility pass: VoiceOver, reduced motion, captions for spoken output.
- Contributor docs, issue templates, security policy with a disclosure address.

**Files/modules.** `.github/workflows/release.yml`, `Casks/pearl.rb` (tap repo), `App/Onboarding`, `App/Settings`, `docs/*`, `website/benchmarks/*`.

**Steal list used.** #28 (usage meter, public numbers), #26, #27; avoid-list items 13 and 14 (pick the licence on day one; publish reproducible benchmarks).

**Exit gate.**
- Clean-user-account install from the tap succeeds; `spctl -a -vv` reports accepted; first launch shows no Gatekeeper warning.
- Sparkle update from version N to N+1 succeeds on a clean account.
- Network capture across a full day of normal use shows connections only to the user's chosen provider (and the Sparkle appcast if enabled): 0 other hosts.
- Onboarding to first successful spoken turn in <= 5 minutes for a tester who has not used Pearl (usability target; 3 testers).
- Benchmark page regenerates from raw CSV with one command and matches the numbers in the README to within rounding.
- No personal data in the repo or history (scan passes).

**Risks.** Homebrew cask thresholds; Developer Program membership and notarization turnaround; GPL transitive dependencies; claims drifting from data.

**Effort.** 8 to 12 days (est.).

---

## 5. RAM and latency budgets

### 5.1 RAM budget (GB, 8 GB total, all values (est.))

The rows for macOS and user apps are assumptions about the owner's workload. Re-measure with Activity Monitor and `footprint` on the Neo in M0.

| Consumer | Idle | Active voice turn | Basis |
|---|---|---|---|
| macOS system services | 2.5 to 3.5 (est.) | 2.5 to 3.5 (est.) | Assumption |
| User apps (browser, editor) | 2.0 to 3.0 (est.) | 2.0 to 3.0 (est.) | Assumption |
| Pearl shell (AppKit app, HUD, router, state) | 0.015 to 0.04 (est.) | 0.10 to 0.15 (est.) | AppKit about 13 MB, SwiftUI 30 to 56 MB on other apps [devto-13mb] |
| Silero VAD | 0 (unloaded) | 0.002 (est.) | About 2 MB model [S-silero] |
| Wake word | 0 (not in V2.0) | 0 | Decision D4 |
| STT: SpeechAnalyzer | 0 | about 0.1 (est.) | No RAM figure published |
| STT fallback: Parakeet via FluidAudio | 0 (unloaded) | about 0.3 (est.) | 66 MB working memory, weights unverified [S26] |
| TTS: Kokoro CoreML | 0 (unloaded) | 0.4 to 0.5 (est.) | 375 to 434 MB peak on Mac, one synthesis [S-kokoro-coreml] |
| LLM: Apple Foundation Models | 0 app cost | 0.5 to 1.0 (est.) | No RAM figure found; Neural Engine memory is attributed to the calling app in macOS 27 [rn27] (Open question D8) |
| LLM fallback: Qwen 3.5 2B MLX | 0 (not resident) | about 1.3 (est.) | 1,279 MB peak on A19 Pro [S-ondevice-llm] |
| **Pearl total, primary path** | **about 0.02 to 0.04 (est.)** | **about 1.0 to 1.5 (est.)** | Sum of Pearl rows |
| **System total, primary path** | **4.5 to 6.6 (est.)** | **5.5 to 8.0 (est.)** | Upper end means swapping |
| **System total, Qwen resident** | n/a | **6.3 to 8.8 (est.)** | Exceeds 8 GB at the upper end; do not run with heavy apps |

Rules that follow:
1. Unload Kokoro and Parakeet after a 60 s idle timeout (est.).
2. Never keep Apple FM and Qwen both resident. Qwen only when the user chooses it and apps are light.
3. Pearl idle target <= 25 MB, hard cap 40 MB, idle CPU <= 1% (targets).
4. Unload models on `DispatchSource` memory-pressure `.warning`.
5. Decode speed is bounded by about 60 GB/s memory bandwidth: plan for roughly 50 to 60 tokens/s at best on a 2B 4-bit model (est.; unverified on A18 Pro).
6. Avoid: Piper (GPL-3.0), Chatterbox (7.5 GB peak), Whisper large-v3 (about 4 GB), any resident model above about 1.5 GB.

### 5.2 Latency budgets (ms, all values (est.))

Interval for the headline target: end of user speech to first PCM sample at the output. Push-to-talk makes the endpoint the key release, so the "speech end + endpoint" row (300 to 500 (est.)) applies only to hands-free VAD mode. The "hotkey to mic open" row (20 to 50 (est.)) is shown for the full chain.

**(a) Deterministic local action** (for example "open Mail", "set a timer for 10 minutes")

| Stage | Estimate | Basis |
|---|---|---|
| Hotkey to mic open | 20 to 50 (est.) | Assumption |
| Speech end + endpoint (VAD mode only) | 300 to 500 (est.) | Assumption |
| STT finalize | 100 to 200 (est.) | Parakeet 320 ms chunk order [S26] |
| Intent match (grammar, no LLM) | < 10 (est.) | Assumption |
| Action execution | 50 to 300 (est.) | Depends on API |
| TTS confirmation first audio | 60 to 200 (est.) | Kokoro warm [S-kokoro-coreml]; Pocket about 200 [S-pocket] |
| **Total from end of speech (PTT)** | **220 to 710 (est.)** | Sum of the last four rows |
| **Total including endpoint (VAD)** | **about 550 to 1,250 (est.)** | Research sum, includes hotkey and endpoint rows |

Target: p50 <= 600 ms, p95 <= 1,000 ms from end of speech.

**(b) Local chat via Apple Foundation Models**

| Stage | Estimate | Basis |
|---|---|---|
| STT finalize | 100 to 200 (est.) | As above |
| FM time-to-first-token (incl. session setup) | 300 to 1,000 (est.) | No FM figure found |
| First sentence from FM streaming | 100 to 400 (est.) | Assumption |
| TTS first audio | 60 to 200 (est.) | As above |
| **Total from end of speech (PTT)** | **560 to 1,800 (est.)** | Sum; FM row decides |
| **Total including hotkey and endpoint (VAD)** | **about 880 to 2,350 (est.)** | Research sum |

Target: p50 <= 1,200 ms, p95 <= 2,000 ms.

**(c) Frontier chat (`claude-haiku-5-5`)**

| Stage | Estimate | Basis |
|---|---|---|
| STT finalize | 100 to 200 (est.) | As above |
| Network + Haiku TTFT | 400 to 1,200 (est.) | No Haiku TTFT figure found |
| First sentence streamed | 100 to 300 (est.) | Assumption |
| TTS first audio | 60 to 200 (est.) | As above |
| **Total from end of speech (PTT)** | **660 to 1,900 (est.)** | Sum; network row is the unknown |
| **Total including hotkey and endpoint (VAD)** | **about 980 to 2,450 (est.)** | Research sum |

Target: p50 <= 1,500 ms, p95 <= 2,500 ms.

### 5.3 Other budgets

| Item | Target | Note |
|---|---|---|
| Hotkey to HUD visible, warm | p50 <= 30 ms, p95 <= 50 ms | V1 claims 48 ms; unmeasured |
| Policy decision per tool call | p95 <= 5 ms | M6 gate |
| Time to unload models after idle | <= 70 s | 60 s timeout plus teardown |
| Idle CPU | <= 1% averaged over 10 min | No polling timers; notifications only |

---

## 6. Benchmark methodology

Adopted from the spec critique (04 section 2.2), made specific.

1. **Define every interval by start and end events.** Headline: `t0` = end of user speech (key release or VAD endpoint), `t1` = first PCM sample written to the output device. Instrument with `os_signpost` and `mach_continuous_time`, inspect in Instruments, export CSV.
2. **Device.** MacBook Neo, 8 GB, macOS 27.x only. Record build (`sw_vers`), power source, Low Power Mode, `ProcessInfo.thermalState`, memory pressure and background load at the start of each run. The realistic 8 GB scenario is the reference workload: Safari with 10 tabs plus an editor open.
3. **Cold vs warm reported separately.** Cold is after reboot or after models are evicted. Warm is a second invocation within 1 minute.
4. **N >= 100 per scenario.** Report p50, p95, p99 and max. Never publish "< X ms" from a handful of runs. Publish raw CSV.
5. **Memory.** `footprint` and phys_footprint summed over all Pearl-owned processes (app, XPC, helpers, sandboxed children) at idle, during a turn, and at peak. Also log swap activity (`vm_stat`). Swap and jank is the real 8 GB failure mode.
6. **Acoustic end to end.** Play recorded prompts through a speaker or virtual audio device, record the output, and compute latency from waveforms. This allows a same-prompt, same-harness comparison with Siri if a Siri claim is ever published.
7. **Quality metrics beside speed.** Labelled utterance corpus (>= 500) gives routing accuracy, wrong-action rate, false-escalation rate and "% handled locally". Adversarial shell and prompt-injection corpora give bypass rates. A listening panel or MOS for TTS.
8. **Battery.** Wh per hour idle, with wake word off (default) and on if it is ever added, on the 36.5 Wh battery [S2].
9. **CI.** Router, safety and injection corpora run on every pull request. Latency and memory runs happen on the Neo, nightly or per release.
10. **No claim ships without data.** README claims link to the CSV that supports them. Self-reported vendor numbers are not reused as Pearl's numbers.

---

## 7. Permission and tool tier table

The local model may only call T0 to T2 tools. T3 and above plans come from the frontier model or the user and always pass the policy engine. The model never decides its own tier.

| Tier | Name | Examples (typed tools) | TCC needed | Default | Confirmation | Undo | Sandbox |
|---|---|---|---|---|---|---|---|
| T0 | Observe (local, non-sensitive) | time, battery (IOKit), volume level, frontmost app name, running apps, Pearl's own memory read | none | On | Never | n/a | In-process |
| T1 | Reversible local actions | open or focus app, open project folder or URL, volume, mute, media keys, create reminder, create calendar event (add-only), screenshot to `~/Pictures/Pearl`, move file to Trash in allowed roots | Reminders (full), Calendars (add-only), Screen Recording | On after just-in-time grant | No; toast with Undo | Yes | In-process |
| T2 | Read personal data | read calendar (full), search reminders and contacts, Spotlight search, read Notes, Mail headers and unread, Safari tab list, AX window titles, read files in allowed roots | Calendars full, Contacts, Automation (Notes, Mail, Safari), Accessibility, Files and Folders | Off until enabled per source | No per call; results tagged untrusted if from mail, web or external files | n/a | In-process; mail and web content goes to the quarantined reader |
| T3 | Workspace changes (dev) | `git status/diff/log/branch`, `git commit`, edit files in registered project roots, allow-listed build and test commands, graceful quit | Files and Folders for project roots | On for registered roots | Show a diff summary; session-scoped "allow"; confirm quit if unsaved docs | git revert, file snapshots | Seatbelt: write only project root (minus `.git/hooks`, `.git/config`), network off or allowlisted |
| T4 | External side effects, irreversible | send email or iMessage, `git push`, post or publish, HTTP POST to arbitrary hosts, empty Trash, run a model-written script, change system settings (Dark Mode, Focus via Shortcut) | Automation (Mail, Messages, System Events), Shortcuts | Off; enable per capability | Always, with exact arguments; re-confirm when untrusted content is in context; never "always allow" for send or push | Mostly none, and the prompt says so | Seatbelt for scripts; network via proxy allowlist |
| T5 | Raw shell, UI control, plugins | `shell.run`, AX UI scripting and synthetic clicks, third-party MCP servers | Accessibility, plus whatever the plugin needs | Off; "Developer mode" per session, auto-expires | Per command (shell); per install and per update (plugins, hash-pinned) | None | Mandatory Seatbelt (`srt`), deny-default filesystem and network; no Keychain, `~/.ssh` or LaunchAgents |
| Never | Hard-blocked by design | `sudo` or admin auth, Keychain reads, `~/.ssh` reads, disk erase or format, editing Pearl's policy or audit files, disabling SIP or Gatekeeper, installing LaunchAgents or daemons, reading `TCC.db` | n/a | No API path exists; the sandbox denies these paths if a T5 shell attempts them | n/a | n/a | n/a |

Related rules:
- Tool results carry `trust` and provenance. Untrusted content is never written to long-term memory automatically.
- Secrets never enter model context (Keychain, injected only into the network client or a plugin's sandboxed process).
- Persona and policy files are not writable by any tool.

---

## 8. Open questions and to-verify-on-device

### 8.1 Disagreements between research reports, and the position taken

| # | Topic | Positions | Position taken and why |
|---|---|---|---|
| D1 | Does macOS 27.2.1 exist? | 01: UNVERIFIED. 03: "unlikely this early". 04: MacRumors roundup lists 27.2.1 (2026-11-09) and 27.3 in public beta [S4]. | 04, because it cites a dated source. Confirm with `sw_vers` in M0. Not design-relevant. |
| D2 | Foundation Models on-device context size | 01: 8,192 tokens on device, 32K on PCC [S6]. 03: 4K per an Apple engineer on the developer forums [devforum-fm]. 02: "about 4K to 8K". | Design for 4K (the more conservative, forum-sourced figure from an Apple engineer). Keep tool schemas tiny. Measure the real limit in M0 and relax if it is 8K. |
| D3 | Global hotkey API | 03: Carbon `RegisterEventHotKey` via KeyboardShortcuts, no TCC prompt [kbs]. 04: Apple DTS recommends `CGEventTap`, which needs Input Monitoring; Carbon is "legacy" [S13]. | Carbon. Shipping apps use it, it needs no permission, and permission cost is the stronger product argument. Fall back to an event tap only if Carbon breaks on macOS 27. |
| D4 | Wake word | 01: steal OpenClaw's on-device Apple Speech keyword spotting and tuned timings (#5). 02 and 03: skip in V2; idle cost unmeasured; always-on mic indicator. | Off in V2.0, push-to-talk default. Reconsider after an idle CPU, battery and RAM measurement on the Neo. |
| D5 | Kokoro latency | 02: warm median 62 to 95 ms for a 3 s input on M1, M2 Ultra and iPhone 15 Pro Max. 04: 309 ms on an M1 mini and 159 ms on an M2 Ultra for a 27 s utterance (same community Core ML build [S-kokoro-coreml]). | Not contradictory (different input lengths). Neither is time-to-first-audio-chunk on an A18 Pro. Measure in M0. |
| D6 | Current non-Anthropic frontier models | 01: GPT-5.6 [S14-neuron]. 04: aggregator lists GPT-6.x and Gemini 4 [S9]. 02: only Claude IDs verified from vendor docs. | Ship only Claude IDs as defaults, taken from the vendor page. Everything is config. Treat other names as unverified. |
| D7 | ZeroClaw | 01: keep it, pin versions, audit allowlists [S20][S21]. 04: drop it if Swift owns tool execution, since "unlocked roots" disables its own safeguards. | Drop it from the tool path. Swift owns execution. V1 config archived. Its Landlock and Bubblewrap sandboxing is Linux-only, so macOS gets no OS sandbox from it (research file 01). |
| D8 | RAM cost of Apple FM | 01: about 0 extra, OS-managed (UNVERIFIED). 03: Neural Engine memory is attributed to the calling app in macOS 27 [rn27]. 02: 0.5 to 1.0 GB (est.). | Budget 0.5 to 1.0 GB (est.) until measured with `footprint` in M0. |
| D9 | ProMotion on the Neo | 03: unverified, "very unlikely". 04: MacRumors states 60 Hz, no ProMotion [S2]. | 60 Hz. Animation follows the real refresh rate regardless. |
| D10 | Local fallback model | 01: GGUF options (Granite 4.2 3B, Qwen 3.5 4B, Gemma 3 4B) [S52]. 02: Qwen 3.5 2B via MLX Swift, 61 tok/s and 1.28 GB on an A19 Pro [S-ondevice-llm]. | Qwen 3.5 2B 4-bit MLX Swift, on demand only, because it has a measured memory figure. Must disable or bound reasoning tokens. Revisit if M0 shows FM is unusable. |
| D11 | Embeddings for memory | 03: `NLContextualEmbedding` (retrieval quality UNVERIFIED) or a 20 to 130 MB model in the XPC. | Test both on a labelled retrieval set in M5. FTS5 keyword search works without embeddings. |
| D12 | Piper vs Kokoro | 01: Piper GPL-3.0, avoid. 02: Piper 2.6 GB peak on one benchmark. 04: Piper per-voice licences. | Kokoro primary, Pocket TTS (MIT) fallback, `AVSpeechSynthesizer` last. |
| D13 | System-wide MCP in macOS 27 | One secondary source claims it; Apple's newsroom mentions MCP only for Xcode 27; release notes list none (research file 03). | Treat as false. Do not depend on it. Pearl ships its own MCP server. |
| D14 | "Samantha" persona | The owner's V1 spec asks for it; research 04 recommends assistant. | Assistant (section 1). Owner decision, called out here so it is not missed. |

### 8.2 To verify on the Neo (M0 unless noted)

1. Apple FM: availability states, cold and warm time-to-first-token, tokens per second, RAM while active, real context limit, tool-call latency, `@Generable` accuracy, behaviour with Apple Intelligence disabled or region-limited.
2. Whether AFM 3 Core Advanced runs on the 8 GB Neo (UNVERIFIED; the "most capable silicon" wording suggests not).
3. Whether Developer ID apps (not the App Store) can use FM on PCC at no cost (UNVERIFIED) [wwdc26-mac].
4. SpeechAnalyzer: RAM, partial-result latency, custom vocabulary support, continuous-listening battery cost.
5. Parakeet and FluidAudio licences; Silero VAD LICENSE file (badge text and link disagreed); espeak-ng status as a Kokoro dependency.
6. Kokoro: time-to-first-audio for 5 to 15 word clauses, peak RAM, ANE compile time on first run (about 15 s on another machine (est.)), `bf_` British voices available.
7. `AVSpeechSynthesizer` en-GB premium voices on macOS 27.
8. `osascript` vs cached `NSAppleScript` vs native, for 5 representative actions.
9. Pre-created panel show latency, cold app launch to first frame.
10. Ctrl+Opt+Space collision check against macOS 27 defaults and common apps.
11. Idle RSS and CPU of the AppKit shell; XPC idle-exit timing and whether RAM is returned.
12. Claude Haiku 5.5 time-to-first-token from the owner's network (no published figure).
13. MediaRemote adapter on 27.2.x; `SetFocusFilterIntent` on 27 (reported broken in 26.5) [devforum-focus].
14. Screen Recording re-prompt cadence; whether `SCContentSharingPicker` avoids a persistent grant (UNVERIFIED).
15. `sandbox-exec` and `srt` behaviour on macOS 27, including Apple Events from inside the sandbox.
16. `NLContextualEmbedding` retrieval quality (M5).
17. Homebrew `homebrew/cask` notability thresholds and Developer Program pricing for the owner's region (M8).
18. Thermal throttling behaviour under sustained voice use on the fanless Neo.

### 8.3 Decisions that need the owner

1. Assistant vs companion (D14). Recommendation: assistant.
2. Repo licence. Recommendation: Apache-2.0 (permissive, patent grant, compatible with MIT dependencies and `srt`). GPL-3.0 is the alternative if preventing closed forks matters more [boring].
3. Whether the diary and "learning" features ship on by default. Recommendation: off.
4. Whether third-party MCP plugins are in V2.0 or V2.1. Recommendation: V2.1, after the sandbox is proven.
5. Numeric targets in sections 5 and the exit gates. All are proposals pending the M0 baseline.

---

## 9. Sources

Only URLs that appear in the four research files. Keys match the bracketed references above.

**Platform and hardware**
- [S1] 9to5Mac, macOS 27 Golden Gate: https://9to5mac.com/2026/09/14/macos-27-golden-gate-now-available-here-is-everything-new/
- [9to5mac-27] same as S1.
- [S2] MacRumors, MacBook Neo compromises: https://www.macrumors.com/2026/03/04/macbook-neo-compromises/
- [S3] MacRumors, MacBook Neo review roundup: https://www.macrumors.com/review/macbook-neo/
- [S4] MacRumors, macOS 27 roundup: https://macrumors.com/roundup/macos-27
- TechRadar, MacBook Neo missing features: https://www.techradar.com/computing/macbooks/7-features-the-macbook-neo-is-missing-from-display-downgrades-to-connectivity-caveats
- Apple, MacBook Neo specs: https://apple.com/macbook-neo/specs/
- [rn27] macOS 27 release notes: https://developer.apple.com/documentation/macos-release-notes/macos-27-release-notes
- [wwdc26-mac] WWDC26 macOS guide: https://developer.apple.com/wwdc26/guides/macos/
- [apple-whatsnew] Apple, What's new in macOS 27: https://developer.apple.com/macos/whats-new/
- Apple Newsroom, intelligence frameworks (June 2026): https://www.apple.com/newsroom/2026/06/apple-aids-app-development-with-new-intelligence-frameworks-and-advanced-tools/
- [techcrunch-27] TechCrunch, macOS 27 Siri: https://techcrunch.com/2026/09/14/macos-27-new-siri-takes-on-ai-productivity-apps/
- MacStories, macOS 27 review: https://www.macstories.net/stories/macos-27-the-macstories-review/4/ and https://www.macstories.net/stories/macos-27-the-macstories-review/6/
- 9to5Mac, Siri frustrations: https://9to5mac.com/2026/09/20/five-ways-that-the-new-siri-ai-is-frustrating-iphone-and-apple-watch-users/

**Foundation Models, STT, TTS, local LLMs**
- [S6] DEV, Foundation Models at WWDC 2026: https://dev.to/hariharanjagan/whats-new-in-apples-foundation-models-framework-at-wwdc-2026-5227
- Blake Crosley, Foundation Models Python SDK and fm CLI: https://blakecrosley.com/blog/foundation-models-python-fm-cli
- [devforum-fm] Apple forums, on-device model limits: https://developer.apple.com/forums/thread/833642
- Blake Crosley, tool-calling control: https://www.blakecrosley.com/blog/foundation-models-tool-calling-ios-27
- Apple, Foundation Models framework: https://developer.apple.com/foundation-models-framework/
- MacRumors, Foundation Models framework: https://www.macrumors.com/2025/06/09/foundation-models-framework/
- MacRumors, SpeechAnalyzer vs Whisper: https://www.macrumors.com/2025/06/18/apple-transcription-api-faster-than-whisper/
- DEV, SpeechAnalyzer vs whisper.cpp: https://dev.to/iravoice/apple-speechanalyzer-vs-whispercpp-a-40-speaker-mac-benchmark-40i4
- [S26] MacParakeet, Whisper to Parakeet: https://macparakeet-website.pages.dev/blog/whisper-to-parakeet-neural-engine
- FluidAudio benchmarks: https://docs.fluidinference.com/reference/benchmarks.md
- [S-silero] Silero VAD: https://github.com/snakers4/silero-vad
- [S-kokoro-coreml] Kokoro CoreML: https://huggingface.co/mattmireles/kokoro-coreml
- [kokoro-82m] Kokoro-82M: https://huggingface.co/hexgrad/Kokoro-82M ; MLX port: https://github.com/gabrimatic/kokoro-mlx
- [S-pocket] Kyutai Pocket TTS: https://github.com/kyutai-labs/pocket-tts
- Picovoice TTS benchmark: https://picovoice.ai/blog/on-device-tts/
- Picovoice wake-word benchmark: https://picovoice.ai/docs/benchmark/wake-word/
- [S28] PromptQuorum, best local TTS on Mac: https://www.promptquorum.com/power-local-llm/best-local-tts-mac
- Piper TTS review: https://www.promptquorum.com/power-local-llm/piper-tts-review
- [S7] edge-tts review: https://www.promptquorum.com/power-local-llm/openai-edge-tts-review
- [S-ondevice-llm] On-device LLM runtimes on iPhone 17 Pro: https://dev.to/john-rocky/on-device-llm-on-iphone-which-runtime-is-fastest-mlx-vs-llamacpp-vs-litert-lm-vs-coreml-1b42
- [S10] Artificial Analysis, Qwen3.5 small models: https://artificialanalysis.ai/articles/qwen3-5-small-models
- [S52] LocalClaw, 8 GB tier: https://localclaw.io/ram/8gb.html
- [S27] 9to5Mac, Ollama MLX: https://9to5mac.com/2026/03/31/ollama-adopts-mlx-for-faster-ai-performance-on-apple-silicon-macs/
- [S14] Ollama FAQ: https://ollama.readthedocs.io/en/faq/
- [claude-models] Claude models overview: https://platform.claude.com/docs/en/about-claude/models/overview
- Fast.io, fastest AI 2026: https://www.fast.io/resources/fastest-ai-2026.md
- [S9] BenchLM release timeline: https://benchlm.ai/md/model-updates/releases.md

**Landscape and competitors**
- [S13-raycast] Raycast changelog: https://www.raycast.com/changelog/macos
- [S14-neuron] GPT-5.6 and ChatGPT desktop: https://www.theneuron.ai/explainer-articles/gpt-5-6-and-the-new-chatgpt-desktop-app-complete-guide/
- ChatGPT Voice on desktop: https://noqta.tn/en/news/openai-chatgpt-voice-desktop-gpt-live-codex-2026
- Daring Fireball, ChatGPT Mac app: https://daringfireball.net/linked/2026/07/09/todays-the-day-openai-fucked-up-the-chatgpt-mac-app
- Codex Chronicle: https://thenextweb.com/news/openai-codex-chronicle-screen-context-mac
- [S18] Perplexity Personal Computer: https://www.macrumors.com/2026/05/07/perplexity-mac-app-personal-computer/
- [gemini-mac] Gemini for Mac: https://9to5google.com/2026/04/15/gemini-app-mac/
- Claude desktop changelog: https://claude.com/docs/cowork/claude-desktop-changelog
- Claude week summary: https://dev.to/raxxostudios/claudes-biggest-week-yet-computer-use-channels-and-voice-mode-1nli
- [S20] ZeroClaw docs: https://www.mintlify.com/zeroclaw-labs/zeroclaw
- [S21] OpenClaw forks wave: https://ossinsight.io/blog/the-openclaw-forks-wave-2026
- [S29] Decrypt, OpenClaw 2.0: https://decrypt.co/377135/openclaw-2-0-is-here-whats-new
- Trending Topics, OpenClaw 2.0: https://www.trendingtopics.eu/openclaw-ships-its-biggest-update-into-a-prety-crowded-field-of-competitors/
- [S31] Bitdoze, OpenClaw security guide: https://www.bitdoze.com/openclaw-security-guide/
- OpenClaw macOS voice wake docs: https://docs.openclaw.ai/platforms/mac/voicewake
- [unit42] Unit 42, OpenClaw supply chain: https://unit42.paloaltonetworks.com/openclaw-ai-supply-chain/
- Hermes Agent internals: https://mranand.substack.com/p/inside-hermes-agent-how-a-self-improving
- Hermes voice mode: https://hermes-agent.nousresearch.com/docs/user-guide/features/voice-mode
- Hermes v0.20 voice: https://runtimewire.com/article/nous-research-hermes-agent-v0200-voice-a2a
- [S38] State of Hermes, Sept 2026: https://hermesatlas.com/reports/state-of-hermes-september-2026
- Open Interpreter review: https://aicoolies.com/reviews/open-interpreter-review
- Vellum local assistants: https://www.vellum.ai/md/blog/best-local-ai-assistants
- Leon review: https://www.promptquorum.com/power-local-llm/leon-ai-review
- Khoj review: https://www.promptquorum.com/power-local-llm/khoj-ai-second-brain-review
- LM Studio 0.4: https://lmstudio.ai/blog/0.4.0
- Screenpipe HN thread: https://hn.nuxt.dev/item/49024620
- [S45] Screenpipe performance: https://www.mintlify.com/screenpipe/screenpipe/advanced/performance
- OVOS review: https://www.promptquorum.com/power-local-llm/openvoiceos-review
- Home Assistant 2026.8 voice: https://www.privacysmarthome.com/guides/home-assistant-2026-8-local-ai-voice-ready-replace-cloud-2026/
- HA Speech-to-Phrase: https://home-assistant.io/blog/2025/02/13/voice-chapter-9-speech-to-phrase
- Alice (pmbstyle): https://blog.brightcoding.dev/2026/09/02/pmbstylealice-open-source-desktop-ai-with-voice-memory
- [S46] mem0 vs Zep vs Letta: https://rohitraj.tech/notes/open-source-ai-agent-memory-mem0-vs-zep-letta-2026
- Letta sleep-time compute: https://letta.com/blog/sleep-time-compute
- Letta agent memory: https://www.letta.com/blog/agent-memory
- Mem0 paper: https://ar5iv.labs.arxiv.org/html/2504.19413v1
- OpenClaw memory docs: https://docs.openclaw.ai/concepts/memory
- Wispr vs Superwhisper: https://dupple.com/learn/wispr-flow-vs-superwhisper
- Wispr review: https://www.getvoibe.com/resources/wispr-flow-review/
- MacWhisper review: https://usevoicy.com/blog/macwhisper-review/

**macOS integration, hotkeys, HUD**
- [tn3152] Calendar access levels: https://developer.apple.com/documentation/technotes/tn3152-migrating-to-the-latest-calendar-access-levels
- [rem-perf] rem CLI performance: https://rem-2ut.pages.dev/docs/performance/
- NSAppleScript performance: https://www.macscripter.net/t/nsapplescript-in-app-performance-benefit/75297
- Apple Events usage description: https://mjtsai.com/blog/2018/08/23/apple-events-usage-description
- [mra] mediaremote-adapter: https://github.com/ungive/mediaremote-adapter
- Sequoia screen recording prompts: https://9to5mac.com/2024/10/07/macos-sequoia-screen-recording-popups/
- [heyfocus] Focus from the terminal: https://heyfocus.com/blog/how-to-turn-on-mac-focus-mode-from-the-terminal
- SetFocusFilterIntent: https://developer.apple.com/documentation/appintents/setfocusfilterintent
- [devforum-focus] SetFocusFilterIntent broken in 26.5: https://developer.apple.com/forums/thread/826766
- [S15] Focus toggle forum thread: https://developer.apple.com/forums/thread/729475
- [S13] Global hotkeys, DTS: https://developer.apple.com/forums/thread/735223
- [devforum-tap] Input Monitoring and CGEventTap: https://developer.apple.com/forums/thread/828052
- Option-only shortcuts: https://blog.eternalstorms.at/2024/09/23/keyboard-shortcuts-using-option-and-or-shift-modifiers-only-no-longer-allowed-on-macos-sequoia/
- [kbs] KeyboardShortcuts: https://github.com/sindresorhus/KeyboardShortcuts
- [dnk] DynamicNotchKit: https://github.com/MrKai77/DynamicNotchKit
- [boring] boring.notch: https://github.com/TheBoredTeam/boring.notch
- SMAppService: https://developer.apple.com/documentation/servicemanagement/smappservice
- [devto-13mb] AppKit vs SwiftUI footprint: https://dev.to/woojinahn/a-13mb-cursor-monitor-appkit-undocumented-apis-zero-dependencies-1k72

**MCP and plugins**
- [swift-sdk] MCP Swift SDK: https://github.com/modelcontextprotocol/swift-sdk
- [mcp-tools] MCP spec, tools: https://modelcontextprotocol.io/specification/latest/server/tools
- MCPB: https://claude.com/docs/connectors/building/mcpb and https://github.com/modelcontextprotocol/mcpb
- Anthropic, Desktop Extensions: https://www.anthropic.com/engineering/desktop-extensions
- Raycast security: https://developers.raycast.com/information/security
- FradSer apple-events MCP: https://github.com/FradSer/mcp-server-apple-events
- apple-mcp: https://cdn.jsdelivr.net/gh/Dhravya/apple-mcp@main/README.md
- [cso-postmark] postmark-mcp: https://www.csoonline.com/article/4064009/trust-on-mcp-takes-first-in-the-wild-hit-via-squatted-postmark-connector.html
- Snyk, postmark-mcp: https://snyk.io/fr/blog/malicious-mcp-server-on-npm-postmark-mcp-harvests-emails/
- [invariant] Tool poisoning: https://invariantlabs.ai/blog/mcp-security-notification

**Safety and security**
- [willison-trifecta] Lethal trifecta: https://simonwillison.net/2025/Jun/16/the-lethal-trifecta/
- [willison-camel] CaMeL: https://simonwillison.net/2025/Apr/11/camel/
- CaMeL paper: https://arxiv.org/pdf/2503.18813
- [cc-sandbox] Claude Code sandboxing: https://code.claude.com/docs/en/sandboxing
- [srt] sandbox-runtime: https://github.com/anthropic-experimental/sandbox-runtime
- [gastown] macOS sandbox-exec: https://gastown.dev/docs/research/macos-sandbox-exec
- [runaihome] Agent Safehouse and sandbox escapes: https://runaihome.com/blog/sandbox-local-ai-agents-macos-agent-safehouse-2026/
- Codex CLI sandbox internals: https://codex.danielvaughan.com/2026/05/03/codex-cli-sandbox-internals-seatbelt-bubblewrap-landlock-windows-dacl/
- [S8] NemoClaw DNS rebinding: https://thehackernews.com/2026/08/a-malicious-webpage-could-poison-your.html
- [S11] Chrome Local Network Access: https://developer.chrome.com/blog/local-network-access

**Legal and product risk**
- [axios-sky] Axios, Johansson and OpenAI: https://www.axios.com/2024/05/20/scarlet-johansson-openai-chatgpt-sam-altman
- [S22] Skadden, California SB 243: https://www.skadden.com/insights/publications/2025/10/new-california-companion-chatbot-law

**Distribution**
- [apple-notary] Notarization: https://developer.apple.com/documentation/security/notarizing-macos-software-before-distribution
- [steipete-sparkle] Sparkle, signing and XPC: https://steipete.me/posts/2025/code-signing-and-notarization-sparkle-and-tears
- [sparkle-docs] Sparkle: https://sparkle-project.github.io/documentation/
- [brew5] Homebrew 5.0: https://brew.sh/2025/11/12/homebrew-5.0.0
- [brew6] Homebrew 6.0: https://brew.sh/2026/06/11/homebrew-6.0.0 
//continue whatever is left and complete the V2
</USER_REQUEST>
<ADDITIONAL_METADATA>
The current local time is: 2026-11-13T21:46:16+05:30.
</ADDITIONAL_METADATA>
