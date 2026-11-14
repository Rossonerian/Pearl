# Pearl Risk Register & Architectural Constraints

**Hardware Target:** MacBook Neo (Apple Silicon A18 Pro, 8 GB Unified Memory, 60 Hz Fixed Display)  
**OS Target:** macOS 26.0+ / macOS 27 "Golden Gate"

---

## 1. Hardware & Resource Constraints

### Risk 1.1: 8 GB Unified Memory Pressure
- **Description**: The 8 GB unified memory is shared between the macOS kernel, WindowServer, user apps, and Pearl. Resident processes exceeding 30–50 MB risk triggering memory pressure warnings and system paging.
- **Severity**: High.
- **Probability**: Medium.
- **Mitigation**:
  - Maintain idle physical footprint <= 30 MB (verified at ~26 MB).
  - Pre-allocate HUD views and dismiss to hidden state rather than destroying/rebuilding.
  - Zero permanent local LLM processes in resident daemon. Any on-demand MLX model or Core ML engine runs in a separate XPC service (`PearlInference.xpc`) that unloads on idle timeout (60s) or OS memory pressure.
  - Monitor `DispatchSourceMemoryPressure` and aggressively purge caches on `.warning` or `.critical`.

### Risk 1.2: Fixed 60 Hz Display & Notchless Geometry
- **Description**: Hard-coding 120 Hz animation timers or notch geometry will cause visual tearing, excessive CPU usage, or clipping on the MacBook Neo's fixed 60 Hz notchless display.
- **Severity**: Medium.
- **Probability**: High.
- **Mitigation**:
  - HUD is positioned as a top-center pill relative to `NSScreen.main?.frame` without notch assumptions.
  - All timers and waveform animations run at physical 60 Hz (16.6ms intervals).
  - Respect `NSWorkspace.accessibilityDisplayShouldReduceMotion` to eliminate continuous animation entirely when requested.

---

## 2. Security & Guardrail Risks

### Risk 2.1: Indirect Prompt Injection via External Context
- **Description**: External untrusted content (emails, web pages, git diffs, files, calendar invites) ingested by Pearl may contain hidden adversarial instructions designed to hijack the model and execute unauthorized tools.
- **Severity**: Critical.
- **Probability**: High.
- **Mitigation**:
  - Context is immediately tagged with `TaintState.tainted(source:reason:)`.
  - In tainted contexts, local models are strictly blocked from invoking T3+ tools.
  - All untrusted text passes through `QuarantinedReader`, which strips executable commands and summarizes content to <= 500 characters using an isolated model session with ZERO tools attached.
  - Any T3+ action in a tainted context requires fresh explicit user confirmation showing exact arguments.

### Risk 2.2: Long-Term Memory Poisoning
- **Description**: Attackers attempt to inject malicious instructions or false facts into Pearl's long-term memory store (`facts.md` or `memory.sqlite`) so that subsequent independent queries execute attacker-chosen actions.
- **Severity**: Critical.
- **Probability**: High.
- **Mitigation**:
  - `LearningGate` enforces an untrusted-content gate: inputs from external sources (mail, web, MCP, documents) are strictly rejected from memory promotion without explicit interactive confirmation.
  - Verified against 60/60 test cases in `corpora/memory_poisoning.jsonl` (100% block rate).
  - Stored memory facts remain passive text data, never executable instructions.

### Risk 2.3: Credential Theft & Exfiltration
- **Description**: Model output or tool parameters attempt to read `~/.ssh`, macOS Keychain files, or make unauthorized HTTP requests to exfiltrate secrets.
- **Severity**: Critical.
- **Probability**: Medium.
- **Mitigation**:
  - `NeverTierValidator` hard-blocks raw command strings targeting `.ssh`, Keychain, `/dev/tcp`, or curl pipes.
  - `SeatbeltProfile` generates deny-default profiles denying read/write access to `~/.ssh` and denying outbound network access.
  - `KeychainService.redact` sanitizes API keys and sensitive tokens before logging to `audit.log` or displaying in HUD.

---

## 3. Concurrency, IPC & Reliability Risks

### Risk 3.1: IPC Thread Starvation & Deadlocks
- **Description**: Calling async Swift tasks from synchronous socket handlers using `DispatchSemaphore(value: 0)` blocks worker threads, leading to deadlock under concurrent client requests.
- **Severity**: High.
- **Probability**: Medium.
- **Mitigation**:
  - Implement `AsyncUnixSocketServer` utilizing native Swift structured concurrency (`TaskGroup` / `async let`).
  - Bounded connection pool (max 8 concurrent connections).
  - Length-prefixed framing and 2.0-second socket timeout (`SO_RCVTIMEO`, `SO_SNDTIMEO`).

### Risk 3.2: Offline Audit Tampering
- **Description**: A malicious actor or compromised process modifies historical entries in `audit.log` while Pearl is not running. Resuming the logger without validation would accept the tampered record.
- **Severity**: High.
- **Probability**: Low.
- **Mitigation**:
  - On daemon boot, `AuditLogger` executes `AuditLogVerifier.verifyFile` from line 0 to EOF.
  - If any sequence gap, hash discontinuity, or hash mismatch is discovered, Pearl enters `quarantined` mode, logs a security error, and creates an isolated recovery log rather than appending to corrupted data.

---

## 4. Model Drift & Availability Risks

### Risk 4.1: Apple Foundation Models Availability & Drift
- **Description**: On-device Foundation Models (`SystemLanguageModel`) are managed by macOS and can change behavior or availability across OS updates without pinning.
- **Severity**: Medium.
- **Probability**: High.
- **Mitigation**:
  - Deterministic router handles common daily actions (volume, battery, apps, screenshots, git) without any LLM invocation.
  - Intent resolution is schema-constrained with strict regex fallback parsing.
  - FallbackChain provides explicit diagnostic error summaries if on-device FM fails.
