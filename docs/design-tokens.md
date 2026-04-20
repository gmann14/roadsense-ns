# RoadSense NS — Design Tokens

*Source of truth · updated 2026-04-20 · referenced by [product-spec.md](product-spec.md)*

This file is the canonical token map. iOS (`ios/RoadSenseNS/Features/DesignSystem/DesignTokens.swift`) and web (`apps/web/app/tokens.css`) both implement it. **Never hardcode a color, radius, or duration elsewhere.**

---

## Color

### Surface & ink (adaptive)

| Token | Light | Dark | Usage |
|---|---|---|---|
| `canvas` | `#F6F1E8` | `#0B1419` | App background |
| `canvas-sunken` | `#ECE5D5` | `#060D11` | Grouped backgrounds, list rows |
| `surface` | `#FFFCF5` | `#132129` | Cards |
| `surface-elevated` | `#FFFFFF` | `#1B2B34` | Sheets, modals |
| `ink` | `#0F1E26` | `#EEF2F4` | Body text |
| `ink-muted` | `#55707D` | `#90A4AE` | Secondary text |
| `ink-faint` | `#8FA3AB` | `#617680` | Tertiary / placeholder |
| `border` | `rgba(15,30,38,0.10)` | `rgba(238,242,244,0.10)` | Hairline dividers |
| `border-strong` | `rgba(15,30,38,0.18)` | `rgba(238,242,244,0.18)` | Stronger outlines |

### Brand

| Token | Value | Usage |
|---|---|---|
| `deep` | `#0E3B4A` | Primary brand, hero blocks, primary buttons |
| `deep-ink` | `#07222C` | Pressed state of `deep` |
| `signal` | `#E9A23B` | **Your-contribution moments only** (km, milestones, sync-success pulse) |
| `signal-soft` | `#F7DFB1` | Tint fill for `signal` |

### Roughness ramp (unified iOS + web)

| Category | Value | Hover / 12% tint |
|---|---|---|
| `ramp-smooth` | `#2F8F6D` | `rgba(47,143,109,0.12)` |
| `ramp-fair` | `#E2B341` | `rgba(226,179,65,0.14)` |
| `ramp-rough` | `#D97636` | `rgba(217,118,54,0.14)` |
| `ramp-very-rough` | `#C04242` | `rgba(192,66,66,0.14)` |
| `ramp-unpaved` | `#8A9AA2` | `rgba(138,154,162,0.14)` |

Contrast-verified against `canvas` (≥ 4.5:1 for text on 12% tint).

### Semantic

| Token | Value | Usage |
|---|---|---|
| `success` | `#2F8F6D` | Sync success, affirmation |
| `warning` | `#D97636` | Non-blocking alert |
| `danger` | `#C04242` | Destructive, errors |

---

## Typography

### Families

- Web: **Fraunces** (display), **Manrope** (UI), **IBM Plex Mono** (numerals).
- iOS: **SF Pro Rounded** (display numerals), **SF Pro** (UI), **SF Mono** (tabular data).

### Scale

| Token | Size / line-height | Tracking | Weight | Family |
|---|---|---|---|---|
| `display` | 40 / 44 | -0.02em | 700 | display |
| `title` | 28 / 32 | -0.015em | 700 | display |
| `headline` | 20 / 26 | -0.01em | 600 | ui |
| `body` | 16 / 24 | 0 | 400 | ui |
| `callout` | 15 / 20 | 0 | 500 | ui |
| `caption` | 13 / 16 | 0 | 500 | ui |
| `eyebrow` | 11 / 14 | +0.12em uppercase | 700 | ui |
| `number-lg` | 48 / 52 | -0.03em | 700 | mono |
| `number-md` | 22 / 26 | -0.01em | 600 | mono |

---

## Space

Use these values only: **`4 · 8 · 12 · 16 · 20 · 24 · 32 · 48 · 64`**.

## Radius

| Token | Value | Usage |
|---|---|---|
| `radius-xs` | 8 | Chips, tags |
| `radius-sm` | 14 | Inputs |
| `radius-md` | 20 | Cards |
| `radius-lg` | 28 | Feature panels, sheets |
| `radius-pill` | 999 | Pills, FABs |

## Elevation

| Token | Value |
|---|---|
| `shadow-soft` | `0 8px 24px -8px rgba(14, 59, 74, 0.18)` |
| `shadow-hard` | `0 20px 60px -16px rgba(14, 59, 74, 0.24)` |

---

## Motion

| Token | Duration | Easing | Usage |
|---|---|---|---|
| `motion-standard` | 220 ms | `cubic-bezier(0.2, 0, 0, 1)` | UI state changes |
| `motion-enter` | 360 ms | `cubic-bezier(0.16, 1, 0.3, 1)` | Sheets, drawers |
| `motion-map` | 600 ms | `linear` | Map data settle |
| `motion-celebrate` | 900 ms | spring (0.55 damping) | Contribution pulse (Signal accent) |

All reduce to a ≤ 200 ms fade when `prefers-reduced-motion: reduce`.

---

## Icon vocabulary (16 names)

`route · pothole · signal-weak · signal-medium · signal-strong · shield · home · work · driving · paused · syncing · synced · trend-up · trend-down · trend-flat · info`

Canvas 24×24, 1.5px stroke, rounded line caps, `currentColor`.
