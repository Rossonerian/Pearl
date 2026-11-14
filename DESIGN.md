# Pearl UI Design System & Engineering Specification (`DESIGN.md`)

**Target Platform:** macOS 26.0+ / macOS 27 "Golden Gate"  
**Hardware Reference:** MacBook Neo (Apple Silicon A18 Pro, 8 GB Unified Memory, 60 Hz Fixed Display, Notchless)  
**Standard:** UI Engineering Protocol (Senior Product Designer, Creative Director & Frontend Engineer)

---

## 1. Product Vision & Visual Philosophy

Pearl is an ultra-lightweight, local-first personal AI assistant built exclusively for macOS. Unlike generic AI products that clutter the desktop with bloated Electron containers, artificial chat widgets, and rainbow gradients, Pearl adheres to strict macOS native engineering and restrained visual design.

### Core Principles
1. **Physical Authenticity**: UI surfaces are native AppKit (`NSPanel`, `NSVisualEffectView`, `NSWindow`) and SwiftUI views. Zero web rendering layers (no WebKit, no Electron).
2. **Invisible When Idle**: Zero persistent screen clutter. Pearl stays completely hidden until summoned via global hotkey (`Ctrl+Opt+Space`) or CLI.
3. **Restrained Color & High Contrast**: Monochrome dark palette with system semantic accents (`systemGreen` for trusted/verified, `systemRed` for destructive/denied, `systemOrange` for confirmation required).
4. **Functional Motion at Display Cadence**: 60 Hz animation cadence tailored to the MacBook Neo display (16.6ms intervals). Motion communicates active hardware state (listening, thinking, speaking) and strictly respects macOS Reduced Motion accessibility preferences.
5. **Anti-Slop Compliance**:
   - No generic purple/blue "AI" gradients or neon borders.
   - No emoji substitutions for interface iconography (strictly use Apple SF Symbols).
   - No unnecessary card grids, nested containers, or floating decorative particles.
   - No marketing filler text or fabricated latency statistics.

---

## 2. Design Tokens & Visual Language

### 2.1 Surfaces & Materials
| Surface | Base Material | Blending Mode | Corner Radius | Border / Stroke |
| :--- | :--- | :--- | :--- | :--- |
| **Floating HUD Pill** | `NSVisualEffectView` (`.hudWindow`) | `.behindWindow` | 23.0 pt (Pill) | 1.0 pt `NSColor.white.withAlphaComponent(0.18)` |
| **Settings / Onboarding** | Native macOS Window Background | Standard Window | 12.0 pt | System Standard Window Border |
| **Conversation Panel** | `NSVisualEffectView` (`.sidebar` / `.contentBackground`) | `.behindWindow` | 14.0 pt | 1.0 pt `NSColor.separatorColor` |
| **Interactive Buttons** | `NSButton` / SwiftUI `.bordered` | In-layer | 6.0 pt | System focus ring & active tint |

### 2.2 Typography
Pearl uses the San Francisco system font family with tabular figures for real-time measurements:

| Token | Family / Weight | Size | Usage |
| :--- | :--- | :--- | :--- |
| `font-hud-status` | SF Pro, Medium | 13 pt | Floating pill status and live transcription |
| `font-hud-badge` | SF Mono, Regular | 10 pt | Execution tier badge (T0, On-Device, Claude) |
| `font-window-title` | SF Pro, Semibold | 15 pt | Window headers and sheet titles |
| `font-section-head` | SF Pro, Semibold | 12 pt | Grouped form section titles |
| `font-body` | SF Pro, Regular | 13 pt | Standard labels and descriptive copy |
| `font-code-tabular` | SF Mono, Regular | 11 pt (Tabular) | Timers, token counts, memory bytes, latency ms |
| `font-caption` | SF Pro, Regular | 11 pt | Secondary helper instructions and audit notes |

### 2.3 Color Tokens & Semantic Roles
```swift
// Dark Vibrant Theme (Default for HUD)
let hudBackground = NSColor.windowBackgroundColor.withAlphaComponent(0.75)
let hudBorder     = NSColor.white.withAlphaComponent(0.18)
let textPrimary   = NSColor.white
let textSecondary = NSColor.white.withAlphaComponent(0.65)
let textMuted     = NSColor.white.withAlphaComponent(0.40)

// Semantic Action Feedback
let statusTrusted      = NSColor.systemGreen    // T0-T2 verified local execution
let statusEscalated    = NSColor.systemBlue     // Frontier cloud model
let statusConfirmation = NSColor.systemOrange   // T3-T5 confirmation needed
let statusDenied       = NSColor.systemRed      // Never-Tier or policy block
let waveformActive     = NSColor.white.withAlphaComponent(0.90)
let waveformIdle       = NSColor.white.withAlphaComponent(0.35)
```

---

## 3. Surface Specifications

### 3.1 Top-Center Floating HUD Pill
- **Geometry**: Width 360 pt, Height 46 pt. Positioned at top-center of `NSScreen.main`:
  `x = (screenWidth - 360) / 2.0`, `y = screenMaxY - 46 - 6.0`.
- **Window Class**: `NSPanel` with style mask `[.nonactivatingPanel, .fullSizeContentView, .borderless]`.
- **Window Level**: `.statusBar` (`NSScreenSaverWindowLevel - 1`), collection behavior `[.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]`.
- **Waveform Meter**:
  - 5 vertical rounded bars (width 3 pt, spacing 4 pt, base height 4 pt, max height 20 pt).
  - Normal listening: Bar heights driven directly by 60 Hz RMS audio levels from `LiveSpeechRecognizer`.
  - Thinking state: Waveform oscillates in a smooth sinusoidal phase (`sin(step + offset)`) at 60 Hz (16.6ms).
  - Reduced Motion mode: Static 3-bar indicator without oscillation when `NSWorkspace.shared.accessibilityDisplayShouldReduceMotion` is enabled.
- **Status Text**: Single-line text field with tail truncation. Displays state transitions:
  - `"Listening..."`
  - Streaming partial transcription text
  - `"Thinking..."`
  - Response message (persists 3.0s after speech synthesis completes or until dismissed).
- **Dismissal**: Pressing `ESC`, clicking outside, or re-pressing `Ctrl+Opt+Space` dismisses the pill immediately.

### 3.2 Settings Panel
- **Size**: Fixed 580 x 460 pt, centered on active screen.
- **Tabs**:
  1. *General*: Hotkey shortcut, daemon status, system architecture, Sparkle update toggle.
  2. *Tiers & Models*: T1 Deterministic, T2 On-Device, T3 Cloud toggle, Model IDs, Provider endpoints.
  3. *Spend Caps*: Monthly hard limit slider ($1 - $50), turn token limit, progress bar with current spend.
  4. *Memory & Privacy*: Stored facts count, profile byte count, Export JSON button, destructive Wipe Memory button with two-step confirmation.
- **Form Style**: Native macOS `.grouped` style with native section headers and standard SF Symbols.

### 3.3 Onboarding Walkthrough
- **Size**: 580 x 480 pt, modal presentation for first run.
- **Layout**: Clean 3-step walkthrough:
  1. *Welcome & Mission*: Lightweight native assistant, zero telemetry commitment.
  2. *Permissions*: Microphone access and Speech Recognition permission requests with inline status badges.
  3. *Activation & Shortcuts*: Instruction on `Ctrl+Opt+Space`, menu bar item location, and CLI command usage (`pearl`).

---

## 4. Accessibility & Responsiveness

1. **VoiceOver Support**:
   - HUD status text updates post `NSAccessibility.post(element: self, notification: .announcementRequested)` with transcription and responses.
   - Settings and Onboarding controls have full keyboard navigation (Tab/Shift-Tab) and explicit accessibility labels.
2. **Reduced Motion**:
   - Respects `NSWorkspace.shared.accessibilityDisplayShouldReduceMotion`.
   - Thinking waveform animations and sliding transitions are replaced with instantaneous opacity swaps.
3. **High Contrast**:
   - When High Contrast mode is active, HUD border opacity increases to `0.45` and text maintains minimum 7:1 contrast ratio against the HUD material.

---

## 5. Verification Checklist

- [x] Zero generic AI landing-page visuals or gradient slop.
- [x] Zero Electron, WebKit, or HTML rendering layers in resident assistant.
- [x] HUD renders cleanly across standard, Retina, and external displays.
- [x] 60 Hz animation cadence verified on MacBook Neo hardware.
- [x] Instant response to `ESC` and hotkey toggle.
- [x] Settings and Onboarding adhere to macOS Human Interface Guidelines.
