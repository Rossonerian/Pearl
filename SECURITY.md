# Pearl Security Policy

The Pearl project takes the security of our users and their computing environments with the utmost seriousness. Because Pearl operates as a resident desktop assistant capable of executing system tasks, our architecture enforces strict defense-in-depth boundaries.

---

## 1. Threat Model & Security Architecture

Pearl's formal security architecture and threat analysis are documented in detail:
- **[docs/THREAT_MODEL.md](docs/THREAT_MODEL.md)**: Threat vectors, trust states, prompt injection defenses, Seatbelt sandbox profiles, and policy rules.
- **[docs/GUARDRAILS.md](docs/GUARDRAILS.md)**: Destructive command interception and policy tiers.

### Defense-in-Depth Layers:
1. **NeverTier Execution Denials**: Irreversible system commands (`rm -rf /`, `sudo`, modifying `~/.zshrc`, reading `~/.ssh` or Keychains) are rejected unconditionally at the policy layer before any execution.
2. **Seatbelt Sandbox Profiles**: Child processes run under OS-level Seatbelt sandbox containment (`sandbox_init` / `sandbox_exec`), denying writes to sensitive user directories even if an internal parser is bypassed.
3. **In-Process Taint Tracking (`TaintTracker`)**: Any content originating from untrusted external sources (emails, downloaded files, web content, MCP payloads) is flagged as tainted. Tainted contexts strictly require explicit, out-of-band user confirmation before triggering external side effects.
4. **Isolated Quarantined Reader**: Untrusted content is summarized by an isolated on-device model with **zero tools attached**, schema-constrained to <= 500 characters of factual extraction, stripping all potential prompt injection directives.
5. **Tamper-Evident Hash Chain**: All security-sensitive actions and policy decisions are committed to an append-only, SHA-256 chained audit log (`~/.pearl/audit.jsonl`). Any deletion, reordering, or byte modification is detected by `pearl doctor --security`.

---

## 2. Reporting a Vulnerability

If you discover a potential security vulnerability in Pearl (including prompt injection bypasses, sandbox escapes, unauthorized network egress, or policy circumvention), please report it responsibly.

### Disclosure Contact
- **Email**: `security@pearl.ai` (or via GitHub Private Vulnerability Reporting on the repository)
- Please include:
  1. A description of the vulnerability and its potential impact.
  2. Detailed reproduction steps or Proof of Concept (PoC) commands/utterances.
  3. Operating system version, hardware model, and Pearl build version.

### Response Timelines
- **Initial Acknowledgment**: Within 48 hours.
- **Vulnerability Assessment & Triage**: Within 5 business days.
- **Remediation & Patch Release**: Critical vulnerabilities are patched with high priority and distributed via an emergency Sparkle update.

---

## 3. Supported Versions

| Version | Supported | Security Updates |
| :--- | :--- | :--- |
| **2.0.x** | **Yes** | Active security patches and vulnerability updates |
| 1.x (Legacy) | No | End of Life; users are strongly encouraged to upgrade to V2 |
