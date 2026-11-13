# Pearl Privacy Policy & Commitment

Pearl is engineered around a simple, inviolable principle: **your computer is your private domain, and your assistant should never phone home.**

---

## 1. Absolute Zero Telemetry

- **No Analytics**: Pearl contains zero analytics SDKs (no Google Analytics, Mixpanel, Amplitude, Segment, PostHog, or Firebase).
- **No Crash Beacons**: Crash logs remain locally on your machine in standard macOS DiagnosticReports (`~/Library/Logs/DiagnosticReports`). No telemetry is automatically dispatched.
- **No Heartbeats or Phone-Home Beacons**: Pearl does not send startup pings, daily active user (DAU) counters, or feature usage statistics.

---

## 2. Network Egress Guarantee

Pearl makes outbound network requests **only** under the following two explicit conditions:

1. **User's Designated LLM Provider**:
   - If you configure a cloud model (such as Anthropic Claude or OpenAI), HTTPS requests are made directly from your computer to that provider's official API endpoint.
   - Credentials are stored securely in macOS Keychain. They are never sent to any intermediary server or proxy operated by Pearl.
   - If you choose **Apple On-Device Intelligence** or local open-weights (MLX / Ollama), outbound LLM network traffic is **zero**.

2. **Opt-in Software Updates (Sparkle 2)**:
   - If update checks are enabled in Settings, Pearl fetches `appcast.xml` from GitHub over HTTPS to verify release versions.
   - In strict compliance with our privacy policy, **System Profiling is disabled** (`SUEnableSystemProfiling = false`). No hardware identifiers, serial numbers, OS specifications, or machine configurations are ever transmitted.
   - You can completely disable update checks at any time in **Settings → General → Updates**.

---

## 3. Local-First Memory & Storage

- **Plaintext Inspectable Memory**: All learned context and profile data is stored locally in `~/.pearl/memory/` as standard Markdown and JSON files.
- **No Cloud Synchronization**: Pearl does not sync your memory, notes, profile, or preferences to any cloud backend or third-party database.
- **Right to Forget**: You can inspect every stored fact, export your entire memory store as JSON, or permanently wipe all facts via the UI or CLI (`pearl memory stats|export` / `pearl forget <id>`).

---

## 4. Zero Default Personal Data

Pearl starts with zero knowledge about you. It does not scrape your Address Book, Mail history, browser history, or Documents folder upon installation. Pearl learns about you only when you explicitly instruct it to (e.g. *"Remember that..."* or `pearl remember "<fact>"`).

---

## 5. Independent Verification

You can independently audit Pearl's network activity using standard macOS monitoring tools:

```bash
# Verify 0 open TCP listening sockets for the Pearl daemon:
lsof -a -iTCP -sTCP:LISTEN -p $(pgrep Pearl)

# Monitor outbound connections during active usage:
sudo nettop -m tcp -p $(pgrep Pearl)
```

If you observe any outbound network traffic from Pearl to any destination other than your designated model provider endpoint and the Sparkle GitHub appcast, please file a critical security report immediately.
