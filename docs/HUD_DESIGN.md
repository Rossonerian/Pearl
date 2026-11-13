# Pearl Liquid Glass HUD Design Specification

The Pearl HUD (`PearlHUD.swift`) is a native macOS AppKit floating notch capsule engineered to blend seamlessly into modern Apple Silicon MacBooks (M1/M2/M3/M4 notch displays).

---

## 1. Visual Geometry & Materials

- **Dimensions**: 170pt width × 40pt height with 20pt corner radius (pill capsule).
- **Notch Placement**: Positioned horizontally centered on the main screen, 34pt below the top edge directly beneath the physical notch.
- **Vibrancy Layer**: `NSVisualEffectView` with `.hudWindow` material and `.behindWindow` blending mode.
- **Liquid Bezel**: Multi-stop refractive gradient border (`1.2pt` width) with specular crystal highlight on top and soft ambient bounce on bottom.

---

## 2. Waveform Dynamics & States

- **Bar Architecture**: 7 vertical bars (3.5pt width, 5.0pt spacing) rendered using `CALayer` with pearlescent luminescence.
- **Thinking State**: Renders a harmonic, multi-frequency traveling sine wave with an organic breathing envelope:
  $$h(t, i) = h_{min} + \left(\frac{\sin(\omega t + \phi_i) + 1}{2}\right) \cdot \text{breathing}(t) \cdot (h_{max} - h_{min})$$
- **Speaking State (60 FPS Audio Metering)**: Driven by `AVAudioPlayer.updateMeters()` sampling channel 0 average power every 35ms:
  $$\text{normalized} = \max\left(0.05, \min\left(1.0, \frac{\text{avgPower} + 45.0}{45.0}\right)\right)$$
- **Fluid Morphing**: Transitions from Thinking wave to audio-metered bars with zero stutter or flicker.

---

## 3. Circadian Ambient Glow

The ambient drop shadow (`18pt` radius, `0.45 – 0.55` opacity) dynamically reflects Pearl's mood:
- **Late Night Introspective**: Nocturnal Moonlit Cyan (`#0ea5e9`)
- **Morning Clarity**: Golden Sunrise Amber (`#f59e0b`)
- **Focused Builder**: Cyber Electric Cobalt (`#3b82f6`)
- **Twilight Wind-Down**: Amethyst Lavender (`#a855f7`)

---

## 4. Interactive Controls

- **Click to Dismiss**: `mouseDown` on the capsule immediately cancels audio playback and initiates spring exit.
- **Key Dismissal**: Pressing `Escape` or `Space` instantly dismisses the HUD.
