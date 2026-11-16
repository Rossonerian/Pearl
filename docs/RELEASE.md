# Pearl Release & Publishing Guide

This document describes the end-to-end release, signing, notarization, and distribution process for Pearl V3.3 on macOS.

---

## 1. Sparkle 2 Setup & Cryptographic Signing (EdDSA)

Pearl uses [Sparkle 2](https://sparkle-project.org/) for secure, zero-telemetry in-app updates. All update archives are cryptographically signed using EdDSA (Ed25519).

### 1.1 Generating Sparkle EdDSA Keys (Offline)

Before cutting the first production release, generate an EdDSA private/public keypair on an offline or hardware-secured machine:

```bash
# Using Sparkle's generate_keys tool:
./bin/generate_keys
```

- **Private Key**: Back this up in an offline hardware vault or macOS Keychain. **NEVER commit the private key to git.**
- **Public Key**: Add the base64-encoded public key to `App/SparkleConfig.swift` and `Pearl.app/Contents/Info.plist`:
  ```xml
  <key>SUPublicEDKey</key>
  <string>YOUR_BASE64_ED25519_PUBLIC_KEY</string>
  <key>SUFeedURL</key>
  <string>https://raw.githubusercontent.com/rossonerian/Pearl/main/appcast.xml</string>
  <key>SUEnableSystemProfiling</key>
  <false/>
  ```

> [!IMPORTANT]
> `SUEnableSystemProfiling` must ALWAYS be set to `<false/>`. Pearl enforces zero telemetry; no anonymous hardware specs or system profiling data will ever be sent during update checks.

### 1.2 Generating Appcast & Deltas

When creating a new release archive (e.g. `Pearl-2.0.0.dmg` or `Pearl-2.0.0.zip`):

```bash
# Generate the appcast item and sign the archive
./bin/generate_appcast archives/
```

Commit the updated `appcast.xml` to `main` so clients can discover and verify the release.

---

## 2. Release Packaging & Signing Harness

Pearl includes an automated packaging and code signing script: `scripts/build_release.sh`.

### 2.1 Prerequisites

- Apple Developer Program membership.
- Developer ID Application certificate installed in your Keychain:
  - Name format: `Developer ID Application: Your Name (TEAM_ID)`
- App Store Connect API Key or Keychain credentials for `xcrun notarytool`:
  ```bash
  xcrun notarytool store-credentials "PEARL_NOTARY_PROFILE" \
    --apple-id "developer@example.com" \
    --team-id "TEAM_ID" \
    --password "app-specific-password"
  ```

### 2.2 Running `build_release.sh`

```bash
# Build, sign with Developer ID, notarize, staple, and create DMG
export CODE_SIGN_IDENTITY="Developer ID Application: Your Team Name (TEAM_ID)"
export NOTARY_PROFILE="PEARL_NOTARY_PROFILE"

./scripts/build_release.sh --dmg
```

For local testing without a Developer ID certificate:
```bash
# Uses ad-hoc signing (-) and skips notarytool
./scripts/build_release.sh --adhoc --zip
```

### 2.3 Signing Architecture (Inside-Out)

Pearl performs hardened runtime signing inside-out:
1. `Pearl.app/Contents/Helpers/pearl-cli` is signed with `com.apple.security.inherit` or standalone hardened runtime.
2. Embedded frameworks, dylibs, and XPC services are signed.
3. The main executable `Pearl.app/Contents/MacOS/Pearl` is signed with:
   - `--options runtime` (Hardened Runtime enabled)
   - `--timestamp` (Apple Secure Timestamp)
   - `--entitlements App/Pearl.entitlements`:
     - `com.apple.security.automation.apple-events` (for controlling apps like Safari, Music, Mail)
     - `com.apple.security.device.audio-input` (for live microphone streaming)
     - `com.apple.security.files.user-selected.read-write` (for user workspace interaction)
4. The outer bundle `Pearl.app` is signed.
5. The DMG/ZIP container is created and notarized via `xcrun notarytool submit --wait`.
6. The notarization ticket is stapled via `xcrun stapler staple Pearl.dmg`.
7. Gatekeeper validation is verified via `spctl -a -vv Pearl.app`.

---

## 3. Homebrew Distribution

Pearl is distributed via Homebrew Cask.

### 3.1 Custom Tap

Users can install Pearl directly from your tap:
```bash
brew tap rossonerian/tap
brew install --cask pearl
```

Formula path: `Casks/pearl.rb`.

### 3.2 Upstream `homebrew/cask` Submission

Once Pearl meets upstream notability criteria (stars, downloads, stable tagged releases):
1. Compute the SHA256 of the notarized DMG:
   ```bash
   shasum -a 256 Pearl-2.0.0.dmg
   ```
2. Update `url` and `sha256` in `Casks/pearl.rb`.
3. Submit a pull request to `Homebrew/homebrew-cask`.

---

## 4. Release Checklist

1. [ ] Run `Bench/scripts/run_all.sh` on clean MacBook Neo hardware.
2. [ ] Run `Bench/scripts/generate_report.py` to refresh `docs/BENCHMARKS.md`.
3. [ ] Verify `swift test` and `DEVELOPER_DIR=/Library/Developer/CommandLineTools swift build` pass cleanly.
4. [ ] Run `pearl doctor --security` to verify 0 misconfigurations.
5. [ ] Run `scripts/build_release.sh` with valid Developer ID credentials.
6. [ ] Verify Gatekeeper: `spctl -a -vv dist/Pearl.app` reports `accepted`.
7. [ ] Sign update archive with Sparkle `generate_appcast` and update `appcast.xml`.
8. [ ] Test install on a fresh macOS user account.
9. [ ] Create GitHub Release with `Pearl-2.0.0.dmg` and release notes.
