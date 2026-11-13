# Pearl Safety Guardrail Specification (`pearl-guard`)

The security architecture of Pearl enforces a strict **three-tier boundary** to guarantee that Pearl can operate freely inside user development space (`~/Projects`, `~/Downloads`, `~/Desktop`) without risking system integrity, user privacy, or data loss.

---

## 1. Safety Tiers

### Tier 0: Permanently Prohibited (Hard Block)
Any command matching Tier 0 rules is aborted immediately before invocation:
- **Privilege Escalation**: `sudo`, `su`, `doas`
- **Catastrophic Deletions**: `rm -rf /`, `rm -rf ~`, `rm -rf $HOME`, `/System`, `/Library`, `/Applications`
- **Destructive Disk Wipes**: `diskutil eraseDisk/partitionDisk/deleteVolume`, `dd if=... of=/dev/`, `mkfs`
- **Credential Theft**: Access to `~/.ssh`, `~/.gnupg`, macOS Keychains, API tokens
- **System Tampering**: SIP (`csrutil`), NVRAM, kernel extensions, proxy alterations
- **Synthetic Keystrokes**: AppleScript `keystroke` or `key code` injection

### Tier 1: Seamless Fast-Path (Permitted)
Operations that execute without prompting:
- Launching and quitting applications (`open -a`, `osascript quit`)
- Reading and writing files in `~/Projects`, `~/Downloads`, `~/Desktop`, `~/Documents`, `/tmp`
- Git operations (`status`, `diff`, `log`, `branch`, `commit`, `checkout`, `push`)
- Hardware telemetry (battery, memory, CPU, thermal state)
- Volume and media playback adjustment
- Spotlight file search via `mdfind`
- Safe screenshot capture & deletion (moving to macOS Trash)

### Tier 2: Scoped / Guarded Operations
- High-impact git commands (`git reset --hard`, `git clean -fdx`)
- Modifying system defaults via `defaults write` (restricted to safe app domains)

---

## 2. Implementation: Dual-Layer Defense

1. **Native C Mach-O Validator (`~/.local/bin/pearl-guard`)**:
   - Compiled with `clang -O3`
   - Execution latency: **< 0.8ms**
2. **In-Process Shell Fast-Path (`pearl_guard_validate`)**:
   - Built into `~/.local/bin/pearl`
   - Execution latency: **< 0.05ms** (15 microseconds, zero fork overhead)
