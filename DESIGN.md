# Pearl UI Design System & Engineering Specification (`DESIGN.md`)

**Version:** 3.2.0 ("Precision Hardware Instrument")  
**Target Platform:** macOS 26.0+ / macOS 27 "Golden Gate"  
**Hardware Reference:** MacBook Neo (Apple Silicon A18 Pro, 8 GB Unified Memory, 60 Hz Fixed Display, Notchless)  
**Standard:** UI Engineering Protocol (Senior Product Designer, Creative Director & Frontend Engineer)

---

## 1. Product Vision & Visual Philosophy

Pearl is an ultra-lightweight, local-first personal AI assistant engineered exclusively for macOS. Designed like a precision aerospace/audio instrument rather than a noisy chatbot widget, Pearl surfaces only when summoned, communicates state through calibrated motion and restrained contrast, and gets out of the way the moment a task completes.

### Core Principles
1. **Physical Authenticity**: UI surfaces are 100% native AppKit (`NSPanel`, `NSVisualEffectView`, `NSWindow`) and SwiftUI grouped forms. Zero WebKit, zero Electron, zero synthetic CSS blur layers.
2. **Invisible When Idle, Quiet When Local**: Pearl stays completely hidden until invoked (`⌃⌥Space` or `pearl`). Local execution is the silent baseline—**zero redundant `"on device"` or `"T1 Local"` pill badges** cluttering the HUD or stealing horizontal space from answers. Only explicit external cloud escalations or emergency abort/confirmation gates surface compact semantic indicators.
3. **Precision Instrument Palette**: Carbon Obsidian (`#0D0E11` / `.hudWindow` vibrancy), Crisp White (`#FFFFFF`) primary ink, Cool Silver (`#A1A6B0`) secondary copy, Warm Champagne Amber (`#F5B84D` / `NSColor.systemOrange`) for thinking cadence and confirmation gates, Emerald (`#10B981` / `NSColor.systemGreen`) strictly for positive confirmation/security grant actions, and Crimson (`#EF4444` / `NSColor.systemRed`) for abort/destructive states.
4. **Functional Motion at 60 Hz**: Calibrated to MacBook Neo's 60 Hz display (`16.6 ms` frame interval). Motion communicates active hardware states (audio RMS amplitude metering, warm-amber sinusoidal thinking harmonic) and strictly honors `accessibilityDisplayShouldReduceMotion`.
5. **Anti-Slop Compliance**:
   - **Zero purple/violet/indigo "AI" gradients or wave fills** (strictly forbidden across waveform meters, onboarding icons, and highlights).
   - **Zero neon `"on device"` text badges** inside floating capsules or turn cards.
   - **Zero emoji UI icons** (strictly calibrated Apple SF Symbols).
   - **Zero visual clutter**: Single focused focal plane per surface with tabular monospace readouts (`HH:mm:ss`, latency `ms`, spend `$0.0000`).

---

## 2. Design Tokens & Visual Language

### 2.1 Surfaces & Materials
| Surface | Base Material | Blending Mode | Corner Radius | Border / Stroke |
| :--- | :--- | :--- | :--- | :--- |
| **Floating HUD Pill** | `NSVisualEffectView` (`.hudWindow`) | `.behindWindow` | 24.0 pt (`capsuleHeight / 2`) | 1.0 pt `NSColor.white.withAlphaComponent(0.18)` |
| **Turn History Sheet** | `NSVisualEffectView` (`.sidebar`) | `.behindWindow` | 14.0 pt | 1.0 pt `NSColor.white.withAlphaComponent(0.14)` |
| **Turn Card** | Surface fill `white @ 5%` | In-layer | 10.0 pt | 1.0 pt `NSColor.white.withAlphaComponent(0.09)` |
| **Settings / Onboarding** | Native macOS Window Material | Standard Window | 12.0 pt | System Standard Window Border |
| **Action Buttons** | Borderless Layer Button / SwiftUI `.bordered` | In-layer | 7.0 pt | 1.0 pt Semantic Stroke |

### 2.2 Typography
Pearl uses San Francisco (`SF Pro` + `SF Mono`) with `monospacedDigit` / `monospacedSystemFont` for all metrics, latency, and timestamps:

| Token | Family / Weight | Size | Usage |
| :--- | :--- | :--- | :--- |
| `font-hud-status` | SF Pro, Medium | 13.5 pt | Floating pill status, live transcription, and response text |
| `font-hud-cloud` | SF Mono, Medium | 10.0 pt | Cloud escalation indicator (shown **only** when `!isLocal`) |
| `font-card-prompt` | SF Pro, Regular | 11.5 pt | History card user prompt (`› query`) |
| `font-card-reply` | SF Pro, Medium | 12.5 pt | History card assistant response (up to 2 wrapped lines) |
| `font-code-tabular` | SF Mono, Regular | 10.0 pt (Tabular) | Timestamps (`HH:mm:ss`), latency (`ms`), token counts, spend USD |
| `font-window-title` | SF Pro, Semibold | 16.0 pt | Window headers and onboarding stage titles |
| `font-section-head` | SF Pro, Semibold | 12.0 pt | Grouped form section headers |

### 2.3 Color Tokens & Semantic Roles
```swift
// Carbon Obsidian HUD Surface & Typography
let hudMaterial       = NSVisualEffectView.Material.hudWindow
let hudBorder         = NSColor.white.withAlphaComponent(0.18) // 0.45 in High Contrast
let hudDivider        = NSColor.white.withAlphaComponent(0.10)
let textPrimary       = NSColor.white.withAlphaComponent(0.95)
let textSecondary     = NSColor.white.withAlphaComponent(0.60)
let textMuted         = NSColor.white.withAlphaComponent(0.42)

// Waveform & Semantic Action Feedback (Zero Purple/Violet AI Slop)
let waveformListening = CGColor(red: 1.00, green: 1.00, blue: 1.00, alpha: 0.92) // Crisp white RMS
let waveformThinking  = CGColor(red: 0.96, green: 0.72, blue: 0.30, alpha: 0.92) // Champagne Amber
let statusConfirmation = NSColor.systemOrange  // Confirmation gate
let actionConfirm      = NSColor.systemGreen   // Confirm action & security verification
let statusEscalated    = NSColor.systemTeal    // Cloud escalation indicator (!isLocal only)
let statusDenied       = NSColor.systemRed     // Kill switch / destructive erase
```

---

## 3. Surface Specifications

### 3.1 Top-Center Floating HUD Capsule
- **Standard Geometry**: `400 pt × 48 pt`, positioned top-center at `x = (screenWidth - 400) / 2.0`, `y = screenMaxY - 48 - 6.0`.
- **Confirmation Geometry**: `460 pt × 56 pt`, expanding smoothly (`180 ms easeInEaseOut`) when a `T2+` tool confirmation is requested.
- **No `"on device"` Clutter**: Local responses render directly across the full `~266 pt` status track (`x: 82` to `currentWidth - 46`), separated from the history chevron (`chevron.down` / `chevron.up`) by a subtle `1 pt` vertical hairline divider (`x = currentWidth - 38`). Only non-local cloud responses surface a subtle compact badge.
- **Waveform Meter**:
  - 5 vertical capsule bars (`width: 3 pt`, `spacing: 4 pt`, `minHeight: 4 pt`, `maxHeight: 24 pt`).
  - Listening mode: White harmonic bars driven by 60 Hz RMS speech levels.
  - Thinking mode: Warm champagne-amber (`#F5B84D`) traveling sinusoidal phase at 60 Hz (`16.6 ms`).
  - Reduced Motion mode: Static balanced 3-bar amber/white display with instantaneous swaps.
- **Expandable Turn History Sheet**:
  - Dimensions: `420 pt × 310 pt` directly below the capsule (`+6 pt` gap).
  - Cards (`76 pt` height, `10 pt` radius): Top row shows `HH:mm:ss` timestamp left and tabular `ms` latency right (no `"on device"` / `"T1 Local"` label); middle row shows `› <user prompt>`; bottom 2 lines wrap the assistant response with tail truncation if longer.

### 3.2 Menu Bar Status Item (`StatusItemController`)
- SF Symbol icon (`waveform.circle.fill`, `13 pt` medium).
- Version header: `Pearl 3.2.0`.
- Actions: `Toggle HUD (⌃⌥Space)`, inline **Persona** submenu (`Executive`, `Ultron`, `Jarvis` with active checkmark), `Settings... (⌘,)`, `Setup Guide...`, and `Quit Pearl (⌘Q)`.

### 3.3 Settings Panel & Onboarding Walkthrough
- **Settings (`580 × 480 pt`)**: Native `.grouped` Form tabs (*General*, *Brains & Models*, *Spend Caps*, *Memory & Privacy*) with SF Symbol section headers, monospaced tabular numeric readouts, and clear configuration controls without repetitive `"on-device"` marketing copy.
- **Onboarding (`600 × 500 pt`)**: 4-step walkthrough (*Philosophy & Primary Brain*, *Hotkey & Voice*, *macOS Permissions*, *Ready to Deploy*) highlighting V3.2's switchable personas (`Executive`, `Ultron`, `Jarvis`), deterministic local harness, and privacy guarantees.

---

## 4. Accessibility & Verification Checklist

- [x] Zero `"on device"` or `"T1 Local"` pill/card clutter in floating HUD or history drawer.
- [x] Zero purple/violet/indigo AI gradient or wave slop across all views.
- [x] Zero emoji icons; strict SF Symbols and tabular SF Mono measurements.
- [x] Full Reduced Motion (`accessibilityDisplayShouldReduceMotion`) and High Contrast (`accessibilityDisplayShouldIncreaseContrast`) support.
- [x] VoiceOver announcements on status transitions + full keyboard navigation (`Tab`, `Enter`, `Esc`).
- [x] Live application screenshot visual inspection completed after build.
