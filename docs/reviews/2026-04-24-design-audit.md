# Design Audit — RoadSense NS (iOS)

**Reviewer:** Claude (Opus 4.7)
**Date:** 2026-04-24
**Branch:** `gmann14/design-audit`
**Scope:** Brand identity, onboarding, driving UX, photo flow, stats, settings, privacy zones, tone/copy. Paired with an opinionated mockup at `ios/RoadSenseNS/Features/Map/MapScreenRedesignPreview.swift`.

---

## TL;DR — three moves

1. **Commit harder to a distinctive aesthetic.** The teal + cream + amber palette is a strong bone structure, but the iOS build still uses stock `SF Pro Rounded` and SF Symbols — the exact look of a thousand civic-tech apps. Load the Fraunces + Plex Mono families you already planned in `design-tokens.md`, ship a real app mark, and treat every pro-social moment (km mapped, pothole marked, drive completed) as a celebration beat. The single biggest move to stop feeling generic is loading two custom fonts.
2. **Make the driving screen a single hero action.** The current bottom card crams ≥5 competing actions (status header, legend, 3-stat row, *Mark pothole*, *Add photo*, *View stats*, sometimes privacy nag). Replace with a permanent Waze-style floating pothole button + ambient progress ring, a minimal top status chip, and move everything else off the driving surface. This is the feature users will tell their friends about.
3. **Rewrite copy from "engineer" to "community."** The app treats users as sensors ("Accepted readings passed device-side quality filters"). Reframe as contributors ("2 drives stayed on your phone — exactly as intended. 4.2 km added to Nova Scotia's map this week."). Pro-social pride motivates frustrated drivers; engineering transparency is for the FAQ.

Brand name is not locked and the domain is available — §1.1 has three concrete alternatives, ranked.

Everything below follows the same severity structure as the April 23 review: **High** = visible UX/brand problem, **Medium** = meaningful polish, **Low** = taste nits. Every High and Medium finding has a red/green TDD plan in §7.

---

## 0. Aesthetic direction: "Field Atlas"

Pick *one* aesthetic point of view and execute it with precision. The direction I'd commit to, given your constraints (frustrated NS driver, set-and-forget, pro-social):

> **Field Atlas.** Nova Scotia's honest civic cartography app — a paper atlas that updates in real time. Tactile, cartographic, Canadian. Color: harbour teal + chart-paper cream + hazard amber + the ramp green→red. Typography: Fraunces (display) for personality, Manrope (UI) for calm, IBM Plex Mono for numerals. Motion: quiet in ambient states, springy and celebratory at contribution moments. Signature visual: a **road ribbon** that paints behind you as you drive, color-coded by roughness in real time — this is the thing someone screenshots and shares.

Why not something bolder (road-warrior black + hazard yellow)? Because every NS driver is the audience, not the angry subset. Civic pride scales further than rage.

Why not softer (pastel / neutral)? Because road data *is* harsh — potholes and cracks — and the ramp colors (green/amber/orange/red) already carry visual voltage. The design should frame that signal, not blur it.

The current token set already quietly supports this direction. What's missing is **commitment**: custom fonts, a real mark, tactile atmosphere (subtle paper grain, map contour flourishes), and celebration motion.

---

## 1. Brand identity

### 1.1 Name — High

The product-spec calls the current name "RoadSense NS (or PaveScore, BumpMap, RoadPulse — TBD)". RoadSense NS doesn't scale: it suffixes a province into the name, narrowing a product that could serve any region, and "sense" is generic. PaveScore / BumpMap / RoadPulse each trip on one of: descriptor-only (no memorability), cutesy (undermines civic trust), or cliché.

**Three alternatives ranked:**

1. **Patch** — `patch.ca` / `patch.app`. Double meaning: patch = pothole fill + patch = fabric / quilt of roads. Short, verb/noun, memorable, Canadian-feeling (quilted, civic). App voice: "Patched 4.2 km today." Logo is trivial — a stitched chevron.
2. **Rumble** — `rumble.ca` etc. Names the sensation the app measures. Owns a word users already use ("this road rumbles"). Risk: `rumble.com` exists as a video platform — trademark check required.
3. **Plot** — cartographer's verb. "You've plotted 12 km of Halifax." Quiet and confident. Risk: generic search term.

Keep NS out of the name. The *coverage area* is Nova Scotia for launch; the *brand* should expand. Domain note: since you said the (unnamed) domain is available, I'd run a 30-minute trademark + App Store search on the top two before committing.

**Recommendation:** Patch. Everything downstream in this review assumes you'll pick a name before ship; I'll use `RoadSense NS` as placeholder.

### 1.2 Typography — High

`design-tokens.md` specifies Fraunces + Manrope + IBM Plex Mono for web. iOS currently uses `.system(..., design: .rounded)` everywhere — SF Pro Rounded — which is literally what Apple ships as default.

The design system *documents* a distinctive voice and *implements* the default. Close the gap:

- **Fraunces** (display) — bundle as a resource, register in `Info.plist` via `UIAppFonts`. Use for the word mark, the stats `numberLg`, segment hero road names, onboarding titles, celebration beats. Fraunces is editorial, slightly soft, handles civic + warm.
- **IBM Plex Mono** (numerals) — bundle for km values, coordinates, stats readouts. Mono numerals on a drive screen *read as measurement* and fit the cartographic direction.
- **Manrope** or **SF Pro** (UI body) — either works. Keeping SF Pro for body avoids 200KB more binary; Manrope reinforces cross-platform consistency. I'd bundle Manrope too; it's 120KB.

Total cost: ~400KB app size, one afternoon of work. Impact: the app stops looking like every other iOS app.

### 1.3 App mark — High

There is no dedicated brand mark. The onboarding "brandMark" is a 28×28 teal circle with `SF Symbols` `road.lanes` inside — functional placeholder, not a mark. Similarly the stats medallion uses `road.lanes`.

A mark for a driving-sensor app wants to evoke motion + measurement + place. Three directions, pick one:

- **Chevron stitch** — an upward chevron made of three short strokes (like a road quality dash), in amber on deep teal. Stitched, cartographic, Canadian-quilt energy. Pairs with the "Patch" name.
- **Contour road** — a single horizontal road outline with a subtle contour-line bend, amber highlight at one point. Topographic.
- **Pulse dot** — a fat dot with a radiating ring (like the recording indicator in the current bottom card). Simple, Waze-adjacent.

Recommendation: commission a designer for one hour on the chosen direction. Until then, replace the SF Symbol with a custom `Canvas { }` primitive (I include one in the mockup file, §6) so at least the mark is *drawn* rather than borrowed.

### 1.4 Brand tone — High

Current copy is honest but engineering-y. Scan of in-app strings:

| Where | Current | Problem |
|---|---|---|
| `MapScreen` header | `"Drive in progress · capturing road readings."` | Sensor framing. |
| `MapScreen` idle | `"Start driving to track road quality."` | Imperative + data-speak. |
| `StatsView` explainer | `"Accepted readings passed device-side quality filters..."` | Dev-facing. |
| `StatsView` explainer | `"Privacy-filtered readings never leave the device..."` | Dev-facing. |
| `MapScreen` undo banner | `"It will send automatically after 5 seconds unless you undo it."` | Correct but robotic. |
| `OnboardingFlowView` | `"Motion is the core signal for scoring road roughness."` | Jargon. |
| `MapScreen` illustration | `"Drive to start mapping."` | Uninspired. |
| `SettingsView` about | `"RoadSense NS passively measures road roughness while you drive..."` | Spec-paraphrase. |

Target voice: **confident Canadian civic, quietly proud, occasionally warm.** Not ra-ra, not corporate.

Proposed rewrites (sample; full pass in §7.T1):

| Where | Proposed |
|---|---|
| Header idle | `"On the record when you drive."` |
| Header active | `"On the record · 4.2 km so far."` |
| Stats explainer | `"Everything you see here came from real drives. Nothing shows up until it's good enough to trust."` |
| Privacy explainer | `"2 drives stayed on your phone this month — exactly the way you set it up."` |
| Onboarding motion | `"Motion access is how we tell driving from walking. It stays on your phone."` |
| Illustration | `"Drive normally. Your first road ribbon shows up after the next sync."` |
| Undo banner | `"Marked. Uploading in 5 seconds — tap to undo."` |

Ship a `Strings.swift` constant file or `Localizable.strings` with these as a single PR. Makes future tone passes one file instead of a hunt.

---

## 2. Onboarding

**Files:** `OnboardingFlowView.swift`, `CollectionReadiness.swift`

### O1. Progressive permission pattern conflicts with "set-and-forget" — High

The current flow stops at "Ready" after When-In-Use Location + Motion. Always Location is deferred until after the first drive, per the product-spec's App-Store-friendly progressive pattern (§Permission Strategy in `product-spec.md`).

Your stated goal: *"everything should be set up so that it can background collect even if they never touch it again."* That's genuinely in tension with the two-stage pattern. But the fix isn't to demand Always on Day 1 (denial rates jump from ~40% to ~70% — well-documented in iOS comm-apps). The fix is to **make the post-first-drive upgrade actually happen**, and to tell the user it's coming so the pattern feels intentional.

Three changes:

1. **Tell users the contract during onboarding.** Add a one-liner under the "Ready to collect" state:
   > *"After your first drive, we'll ask for one more permission — that's when it runs on its own, even when you close the app."*
   Currently onboarding hides this.
2. **Auto-present the upgrade on the first foreground after a drive completes.** Today the user has to open the app, see a yellow banner in the bottom card, and tap *Allow in background*. Instead, when `readiness.backgroundCollection == .upgradeRequired` AND `userStatsSummary.acceptedReadingCount > 0` AND no prior upgrade prompt seen, surface a full-screen modal on next foreground. Fire and forget; don't nag after dismiss.
3. **Rename the state.** `primaryActionTitle == "Allow in background"` is accurate but clinical. Try `"Finish set-up"` or `"Set it and forget it"` — the exact framing you used in the brief.

### O2. Privacy-zones CTA adds cold-start friction — Medium

Step 2 offers "Optional: manage privacy zones". Given that the default 60-second / 300m endpoint trimming covers the exact case most users care about (home/work), presenting privacy zones in onboarding implies they're *expected* and adds decision weight. Drop it from onboarding; keep the Settings → Privacy Zones path. Add a single-sentence reassurance in Ready state: *"Your home and work are already shielded by default. You can add more zones later in Settings."* — which is stronger copy than the current 2-sentence hedge.

### O3. Permission copy buries the "why" — Medium

Current Motion tip: *"Motion is the core signal for scoring road roughness."* That's a sensor-led sentence, not a user-led one. Rewrite each tip with a **Why you care** + **What happens next** + **What stays on-device** pattern:

| Current | Proposed |
|---|---|
| "Tap **Allow While Using App**. Allow Once resets every launch..." | "**Allow While Using App.** We use location to know which roads you drove — nothing else. Allow Once resets every launch and won't work." |
| "**OK**. Motion is the core signal..." | "**OK on Motion.** This is how we tell driving from walking or cycling. It stays on your phone." |

### O4. No mission hook — Medium

The onboarding opens with "We need two permissions before your first drive." Compliant, cold. The product is civic: missing a line about what the user is joining. Add one line above the step-card:

> *"A shared map of every pothole and rough stretch in Nova Scotia, built by the people who drive them."*

One sentence. Once. Don't repeat.

### O5. Step-count inconsistency — Low

The eyebrow says `"Step 1 of 2 · Permissions"` / `"Step 2 of 2 · Ready"`, but `.permissionHelp` (iOS Settings bounce) also maps to Step 1 — visually the trail never shows Step 1 as "in trouble." Either show 3 steps (Permissions, Help, Ready) or drop the step counter from the help state entirely.

---

## 3. Driving screen (the big one)

**File:** `MapScreen.swift`. Replace with the redesign in §6 + `MapScreenRedesignPreview.swift`.

### D1. No single hero action — High

The bottom card currently exposes, in one surface:

- Recording status dot + title + subtitle
- Chevron expand/collapse
- 4 legend chips (Smooth / Fair / Rough / Very rough)
- 3 meta cells (Mapped / Segments / Last drive)
- Map load error banner (conditional)
- `Mark pothole` gradient button (your intended hero)
- `Add photo` button
- `View stats` / `Turn collection back on` / `Allow in background` primary button
- `Manage privacy zones` link (conditional)

Plus top bar (title, stats icon, settings icon), plus the segment sheet trigger hit target, plus banners for feedback / follow-up prompts. That's 14+ tap targets on one screen.

Your Waze reference is exactly right: during an actual drive, the only thing that matters in that split-second is the one action you came here for. Everything else is ambient or banished to secondary screens.

**Redesign (detailed in §6 mockup):**

- **Remove the bottom card entirely.** The map is the surface.
- **Top-left: mark chip** — small capsule with app name + a pulsing dot when recording. Nothing else. Tapping opens the brand/status sheet (the old card's content, on demand).
- **Top-right: 2 circular buttons** — stats, settings. That's it. No privacy nag up here.
- **Bottom-center: the HERO.** A 96×96 amber FAB with `exclamationmark.triangle.fill`, single word label "Pothole" under it. This is your Waze-police button. It obeys physical ergonomics — bottom-right of screen for right-handed thumbs, but centered works too if the intent is "both hands on wheel, glance and stab."
- **Around the FAB: the ambient progress ring.** A thin arc that fills as the current drive accumulates km. Teal when idle/active-normal, amber pulse when a pothole is marked, green when a drive completes successfully.
- **Secondary FAB, smaller (64×64), bottom-right inset:** camera icon. *Only visible when speed < 5 km/h* (stopped) OR the app detects the user is walking (via CMMotionActivityManager — which you already integrate for driving detection).
- **Legend:** move to a one-time tip on first map render, and to the Stats screen.
- **Meta row:** move to Stats. Driving screen shows progress through the ring, not a 3-up readout.
- **First-run empty state:** keep the illustration but make it the *entire* empty state (no competing card), anchored to the center, with one honest sentence: *"Drive normally. Your first road ribbon shows up after the next sync."* Remove the currently-hidden bottom card so the map doesn't fight the illustration.

### D2. Mark pothole tap target lives inside a collapsible card — High

`markPotholeAction` is a child of `bottomCard` gated on `isCardExpanded`. If the user collapses the card (chevron tap, or accidental gesture), the pothole button *disappears* until they re-expand. For a one-shot action that must be reachable mid-drive, this is a footgun. The FAB in §D1 removes this entirely — it's permanent.

### D3. "One tap" / "Optional" pill labels on buttons are noise — Low

`Mark pothole [One tap]` and `Add photo [Optional]` both add a secondary label that restates what the button already implies. A single tap on a button is Apple's default; "optional" for a button the user chose not to press is axiomatic. Drop both pills. The FAB design makes them obviously impossible anyway.

### D4. Status subtitle is over-worked — Medium

`headerSubtitle` computes 8 different strings (loading, upgrade-required, privacy risk, actively collecting × 2 km thresholds, paused, pending uploads, cold start, default). Every branch is correct; together they make the user's eyes flit for something that changes. For a driving surface, subtitle should be:

- **0 km so far:** empty — don't show.
- **Mid-drive:** `"4.2 km and counting"` — that's the only subtitle.
- **Paused / permission issue:** move into a dedicated `NeedsAttentionChip` at the top that's impossible to miss, with a single action.

Everything else is FAQ.

### D5. Primary action = "View stats" when idle — High

When nothing's wrong and the user isn't driving, the primary action becomes *View stats*. That's a noun-button that takes users to *another screen* instead of reinforcing the main loop. It's a signal the designer didn't have a better idle action in mind.

Fix: the idle state IS the primary action. Show a pro-social readout in the center of the screen when the user opens it between drives:

> *"You've mapped 47 km of Nova Scotia so far this month."*
> *"Plus 318 km from 812 other drivers near you."*

No button. Cancer-cell idle screens ("open this next") degrade apps. Let the user close the app with a good feeling. When they drive again, the ring fills again.

### D6. Add Photo is permanent in a space where it shouldn't be — Medium

Per your brief: "adding photo should be an option whenever, but we assume that people will do it when walking or passengers, so it doesn't have to be primary." The current placement makes it visually equal-ish to the pothole CTA. The redesign shows it only when stopped/walking. Detection:

```swift
var isStoppedOrWalking: Bool {
    locationService.smoothedSpeedMps < 1.4 // ~5 km/h
    || motionActivity.currentActivity == .walking
}
```

Exposing the secondary FAB on a fade-in animation when this flips true feels like magic; it disappears when you roll again so the pothole button owns the center.

### D7. No ambient per-drive progress — High

Today, feedback that the app is working mid-drive is text only ("Drive in progress · 4.2 km mapped"). There's no visual heartbeat. Users — especially drivers — need to glance and know *it's working.* The progress ring in §D1 solves this. Additionally, consider:

- **Micro-pulse on the brand chip.** Every N readings accepted, the recording dot pulses briefly. Reassures without distraction.
- **Road ribbon overlay.** As the user drives, paint the just-driven segments of road at reduced opacity on the map, color-coded by local roughness. This is the signature visual. Implementation: local SwiftData coordinates → Mapbox `PointAnnotationGroup` line layer → style by client-side rough score. It's already partially there (`pendingDriveCoordinates`) — lean into it.

### D8. Mark-pothole feedback is a banner tucked at the bottom — Medium

After tapping *Mark pothole*, feedback is a `potholeFeedbackBanner` at screen bottom, above the bottom card. It reads *"Pothole marked — It will send automatically after 5 seconds unless you undo it."*

Two issues:
1. Banner position is tied to `bottomCardHeight + Space.md`. On smaller devices this collides with safe-area. (Already flagged as L2 in the April 23 review — still here.)
2. The feedback *competes* with the action that just fired. Better: **celebrate directly on the FAB itself.** When a pothole is marked, the FAB ring flashes amber, the button label briefly changes to "Marked!", and a tiny countdown ring appears around the button for the 5s undo window — so the undo target is the same button. Tap it to undo. This is tactile and obvious.

Copy: `"Marked!"` → after 5s → revert to `"Pothole"`. If user taps during undo window, show `"Cancelled."` for 800ms then revert.

### D9. Follow-up "Still there? / Looks fixed" surfaces during sheet dismiss — Medium

Already documented in the April 23 review as H3. The redesign implicitly fixes this because segment sheets go away in this model — follow-up prompts become a one-time small sheet fired when the user stops near a pothole they're now near (or on next drive start), not during segment tap flow.

---

## 4. Secondary surfaces

### Segment detail sheet — Medium

**File:** `SegmentDetailSheet.swift`.

Already flagged in April 23 (H3, M2, M3). Plus:

- **Seg1. Hero should carry the road name in display type, not just bold.** Already uses `TypeStyle.title` (28pt, rounded bold) which is good, but ink color is same as chip row. Add a subtle underline or harbor-teal accent line under the road name — cartographic energy.
- **Seg2. Sparkline is lovely but premature.** Until many segments have 30-day data, 90% of sheets will show the empty-state fallback. Hide the trend card entirely when `scoreLast30D == nil`. Saves vertical space.
- **Seg3. "Still there" vs "Looks fixed" — button treatments should be more different.** Both are filled buttons with different tints. Try: `Still there` = amber solid with `checkmark.circle.fill` icon; `Looks fixed` = transparent green with bordered outline + `sparkles` icon. The first is an affirmation; the second is a state-change.
- **Seg4. Remove the in-sheet *Add photo* button entirely.** It was a workaround for the fact that `MapScreen` gates Add Photo on segment selection (flagged as M2 in April 23). Once the FAB in §D1 handles photo globally, this button is duplicative.

### Stats — High

**File:** `StatsView.swift`.

The screen is titled *Stats* and delivers exactly that: accepted readings, pending, privacy-filtered, potholes flagged, km, segments. Zero community framing, zero sense of impact, zero pride. Screen is accurate and boring.

**Rebuild as a contribution card + impact card + community card:**

1. **Hero (keep medallion, supercharge it).** Current: km count, road.lanes icon + segments. Add:
   - *"Top 7% of drivers in Halifax this month"* (tongue-in-cheek — you don't need a true leaderboard yet; compute from local segments on a bell curve).
   - Animated count-up on number changes, using your defined-but-unused `motion-celebrate` spring.
2. **Impact card (new).** "Of the potholes you flagged, 2 have been fixed." For the MVP — since moderation is manual — show the first three rows as "Awaiting moderation" so the user sees the *path*. Closed-loop reassurance even without the loop being fully automated.
3. **Community card.** "Drivers in Nova Scotia contributed 4,712 km last week." Pulls from a cheap server aggregate; updates daily. Makes the individual feel part of something.
4. **Demote the engineering row.** Keep *Accepted / Pending / Privacy-filtered* but behind an expandable "Technical details" disclosure with the current copy verbatim — some users (and App Store reviewers) will love it. Default collapsed.

### Settings — Low/Medium

**File:** `SettingsView.swift`.

- **Set1. Data deletion framing is aggressive.** The destructive red button `Delete local contribution data` with the threatening confirmation is correct behavior but it's the biggest visual element on the screen. On a civic app the calmest framing wins. Move it to the bottom under a neutral "Starting fresh" heading, use a text-only destructive link instead of a bordered red button.
- **Set2. Privacy-zones path is jumpy.** `Settings → Manage privacy zones` calls `dismiss()` then triggers a parent-owned sheet. Users see the sheet dismiss, a gap, the privacy-zones sheet appear. Fix: push to `PrivacyZonesView` with `NavigationStack` within Settings. Already half-wired up — just finish.
- **Set3. Retry buttons can hide.** *Retry failed batches* only renders when `failedPermanentBatchCount > 0`. Good. But the user has no way to *see* what failed without something going wrong. Add a passive row: "Failed batches: 0" / "Failed photos: 0" so the absence of failure is itself visible. Silence is less reassuring than *"nothing broken"*.
- **Set4. The *About* card is spec-paraphrase.** Rewrite in the new brand voice (see §1.4).

### Privacy zones — Low

**File:** `PrivacyZonesView.swift`.

This screen is actually the strongest in the app — tactile map reticle, draft vs saved visual contrast, polygon rendering. It fits the Field Atlas direction naturally. Keep. Two nits:

- **PZ1. Radius slider lacks human reference.** `325 m` is an abstraction to most users. Add a one-liner under the slider: "~1 city block" / "~2-3 blocks" based on the value. Cheap, huge UX lift.
- **PZ2. Default label `"Home"` is thoughtful, but the *next* suggestion after saving is `"Work"` — accurate but assumes a common shape. Also suggest `"Partner"`, `"Family"`, which you already do. Good. Stop here.

### Camera flow — Low

**File:** `PotholeCameraFlowView.swift`.

Functional, focused. Copy *"Slow down or pull over first. Daylight works best."* is great — safety-first without preaching. Two tweaks:

- **Cam1. Review state lacks affirmation.** After capture: "Review photo" is the heading. Add a subtitle: *"This will help moderators confirm the pothole. Yours stays private."* Reinforces pro-social + privacy.
- **Cam2. H6 from April 23 still pending** (re-check camera auth on scenePhase change). Already fixed in this code path — the `onChange(of: scenePhase)` handler exists. Mark H6 resolved.

---

## 5. Global tone + copy pass

Already walked above in §1.4 + individual findings. To make this shippable:

- **One-shot strings file.** Create `ios/RoadSenseNS/App/BrandVoice.swift` with namespaced constants (`BrandVoice.Driving.recordingIdle`, `BrandVoice.Onboarding.motionTip`, etc.). All in-view strings reference these. Makes future tone passes a single-file change and catches drift.
- **Avoid inter-view copy duplication.** Currently `"Drive in progress · capturing road readings."` lives in `MapScreen.swift`; `"Drive to start mapping."` lives there too; `"No drives yet"` lives in `StatsView.swift`. These are the same concept, said three ways. Consolidate.
- **Numerals > words.** "4.2 km" beats "four kilometres". "2 drives stayed on your phone" beats "A small number of drives". The brief is civic honesty: numbers feel honest.

---

## 6. Mockup

See `ios/RoadSenseNS/Features/Map/MapScreenRedesignPreview.swift`.

The file is a **preview-only** SwiftUI proposal. It is not wired to `AppModel`, fixtures, or Mapbox — it uses mock data and pure SwiftUI primitives so it compiles with zero environment. Open `#Preview` in Xcode to see the proposed driving screen. It demonstrates:

- **Top-left brand chip** (pulsing dot when `isRecording`)
- **Top-right** minimal stats + settings chrome
- **Hero FAB** — 96×96 amber, `Pothole` label, ambient teal progress ring
- **Secondary camera FAB** — appears conditionally when "stopped or walking"
- **Road ribbon sketch** — a placeholder-painted path behind the FAB area
- **Idle copy state** ("You've mapped 47 km of Nova Scotia this month")
- **Custom brand mark** — a `Canvas { }`-drawn chevron stitch (§1.3 direction 1)
- **Celebration beat** on *Mark pothole* — FAB rings flash amber, button label flips to "Marked!", undo window renders as a receding arc around the button

You'll see compromises: the real build will animate the road ribbon from live coordinates, not a precomputed path; the stopped-or-walking detection hooks into `CMMotionActivityManager` + `CLLocation`; the progress ring fills from live km. The mockup is for aesthetic + composition calibration, not drop-in.

---

## 7. Prioritized fix list — red / green TDD plans

Follows the same structure as the April 23 review: **red** is the failing test that asserts the fix, **green** is the minimum change to pass. Tests-first, then fix — locks the regression before the change lands.

### 7.B1 — Brand name + domain decision (High)

Non-code. Write a one-page ADR (`docs/adr/0001-brand-name.md`) selecting a name + domain after trademark search. Blocks 7.B2 copy pass and 7.B3 mark design. No tests.

### 7.B2 — Typography: bundle + load Fraunces + IBM Plex Mono (High)

- **Red — UI test** (`ios/RoadSenseNSUITests/TypographySmokeTests.swift`):
  - Launch app. Assert `UIFont.fontNames(forFamilyName: "Fraunces").isEmpty == false` and `UIFont.fontNames(forFamilyName: "IBM Plex Mono").isEmpty == false` via an `accessibilityLabel` embedded diagnostic on launch screen.
  - Assert `StatsView` hero `numberLg` renders with `.fontName.contains("Plex")` (expose font via `accessibilityValue` for the test only in DEBUG).
- **Green:**
  - Add `Resources/Fonts/Fraunces-{Variable,Italic-Variable}.ttf` + `IBMPlexMono-{Regular,SemiBold,Bold}.ttf` to the app target.
  - Update `Info.plist` → `UIAppFonts`.
  - Extend `DesignTokens.TypeFace` with `display(size:weight:) -> Font` returning `Font.custom("Fraunces", fixedSize:)` and `number(size:weight:) -> Font` returning `Font.custom("IBMPlexMono-{weight}", fixedSize:)`.
  - Replace `.system(design: .rounded)` usages in hero/number contexts (Stats `numberLg`, SegmentDetail hero, OnboardingFlow stageCard titles, brand chip).

### 7.B3 — Canvas-drawn brand mark (High)

- **Red — snapshot test** (`ios/RoadSenseNSTests/BrandMarkSnapshotTests.swift`):
  - Render `BrandMark(size: 28)`.
  - Compare to a baseline PNG via `iOSSnapshotTestCase` (or `swift-snapshot-testing` if available).
  - Test currently fails because `BrandMark` does not exist.
- **Green:** Create `ios/RoadSenseNS/Features/DesignSystem/BrandMark.swift` with a `Canvas { }`-drawn chevron stitch. Replace every `Image(systemName: "road.lanes")` used as a mark (onboarding, stats medallion) with `BrandMark(size:)`.

### 7.B4 — Centralized brand voice strings (High)

- **Red — unit test** (`ios/RoadSenseNSTests/BrandVoiceTests.swift`):
  - Assert `BrandVoice.Driving.recordingActive(kmMapped: 4.2) == "On the record · 4.2 km so far."`
  - Assert `BrandVoice.Onboarding.motionTip` is non-empty and free of the word *"signal"* (regression guard against re-drifting to sensor voice).
  - Assert no `MapScreen` string literals remain for voice-scoped phrases (grep the source for `"Drive in progress"` and expect zero — a lint-style assertion).
- **Green:** Create `ios/RoadSenseNS/App/BrandVoice.swift`. Migrate all voice-scoped string literals across `MapScreen`, `StatsView`, `OnboardingFlowView`, `SettingsView`, `SegmentDetailSheet` to reference it.

### 7.O1 — Tell users the Always-Location contract in onboarding (High)

- **Red — SwiftUI snapshot / accessibility test**:
  - Render `OnboardingFlowView` in `.ready` state.
  - Assert a text element matches `/After your first drive, we'll ask for one more permission/` (regex).
  - Fails today — copy isn't there.
- **Green:** Add a third paragraph to `readySubtitle`:
  > *"After your first drive, we'll ask for one more permission — that's when it runs on its own."*

### 7.O2 — Auto-present Always-Location upgrade after first drive (High)

- **Red — `AppModelTests`**:
  - Arrange: `readiness.backgroundCollection == .upgradeRequired`, `userStatsSummary.acceptedReadingCount == 1`, `upgradePromptShown == false`.
  - Act: `model.handleSceneBecameActive()`.
  - Assert `model.shouldPresentAlwaysLocationPrompt == true`.
  - Second act: dismiss → `model.dismissAlwaysLocationPrompt()`.
  - Third act: `handleSceneBecameActive()` again → assert `shouldPresentAlwaysLocationPrompt == false` (one-shot).
- **Green:**
  - Add `@Published var shouldPresentAlwaysLocationPrompt: Bool` + `upgradePromptShown: Bool` (persisted to UserDefaults) to `AppModel`.
  - In `handleSceneBecameActive`, evaluate the three conditions and flip on.
  - Add `fullScreenCover(isPresented: $model.shouldPresentAlwaysLocationPrompt) { AlwaysLocationPromptSheet(onDismiss: { model.dismissAlwaysLocationPrompt() }) }` in `ContentView` (or wherever is topmost).

### 7.O3 — Drop privacy-zones CTA from onboarding Ready state (Medium)

- **Red — snapshot test** of `OnboardingFlowView` in `.ready`: assert no element with accessibility id `"onboarding.manage-privacy-zones"` is present.
- **Green:** Delete the `Button("Optional: manage privacy zones") { ... }` block from `readyState`. Replace `readySubtitle` with the reassurance sentence from §O2.

### 7.O4 — Mission-hook line above onboarding steps (Medium)

- **Red — snapshot test** of `.permissionsRequired`: assert a text element containing `"shared map of every pothole"`.
- **Green:** Add above `header` in `OnboardingFlowView`:
  ```swift
  Text(BrandVoice.Onboarding.missionHook)
      .font(DesignTokens.TypeStyle.callout)
      .foregroundStyle(DesignTokens.Palette.inkMuted)
      .padding(.bottom, DesignTokens.Space.md)
  ```

### 7.D1 — Replace bottom card with FAB + ambient ring (High)

This is the biggest structural change. Ship behind a feature flag (`AppConfig.drivingRedesignEnabled`) so the old screen stays available during QA.

- **Red — UI test** (`AppFlowUITests.swift`):
  - Launch with flag on.
  - On the map screen, assert:
    - No view with id `"map.primary-action"` (the old `View stats` button).
    - A view with id `"map.mark-pothole-fab"` exists, is hittable, and its frame size is ≥ 80×80 pts.
    - A view with id `"map.camera-fab"` is *not* hittable (because fresh launch = no movement, default stopped → actually hittable? Depends on initial state. Assume mid-drive sim for this test.)
  - Separately, assert the old id `"map.mark-pothole-button"` no longer exists (or is hidden under the old flag path).
- **Green:**
  - Introduce `MapScreenRedesignView` (promoted from the mockup file in §6) as the primary `MapScreen` body when the flag is on.
  - Wire FAB to the existing `handleMarkPotholeTap()` logic.
  - Ring: a `GeometryReader` + `Path.addArc` animated by `model.currentDriveKm` / target (say 10 km).
  - Conditional camera FAB visibility: subscribe to `locationService.smoothedSpeedMps` (exists) and `motionActivity.currentActivity`. If < 1.4 m/s OR `.walking`, show; else hide with a 200ms fade.
  - Delete `bottomCard`, `metaRow`, `legendChips`, `primaryAction` from `MapScreen.swift`. Move legend into a one-time `FirstRunLegendTip` overlay shown for 6s on first map load, dismissed on tap.

### 7.D4 — Simplify subtitle to two states (Medium)

- **Red — `AppModelTests`**:
  - `snapshot = { acceptedReadingCount: 0, isActivelyCollecting: false }` → `headerSubtitle == nil` (hidden).
  - `snapshot = { isActivelyCollecting: true, totalKmRecorded: 4.2 }` → `headerSubtitle == "4.2 km and counting"`.
  - `snapshot = { isActivelyCollecting: true, totalKmRecorded: 0.03 }` → `headerSubtitle == "Warming up…"` (or similar — the tiny-km case).
- **Green:** Replace the 8-branch `headerSubtitle` computed property with a 2-branch helper: idle or active. Move all attention-needed states into a separate `needsAttention: NeedsAttention?` typed optional rendered as a distinct top chip.

### 7.D5 — Idle pro-social readout, not "View stats" (High)

- **Red — snapshot test** of `MapScreenRedesignView` with `userStatsSummary = { totalKmRecorded: 47 }` and `nearbyDriversKm: 318`:
  - Assert no button with id `"map.primary-action"`.
  - Assert text containing `"47"` and `"Nova Scotia"` present.
  - Assert text containing `"318"` and `"other drivers"` present.
- **Green:** Add `IdleStatWell` view composited over the map center when `showsFirstRunIllustration == false && !isActivelyCollecting`. Pull `nearbyDriversKm` from a cheap new field on the existing `/stats/nearby` endpoint or mock it to `0` for v1 and hide the second line while it's zero.

### 7.D6 — Camera FAB gated by stopped/walking (Medium)

- **Red — SwiftUI preview-snapshot / UI test**:
  - Simulate `currentSpeedMps = 12` → camera FAB hidden.
  - Simulate `currentSpeedMps = 0.3` → camera FAB visible within 300 ms.
- **Green:** Bind FAB opacity to a derived `isStoppedOrWalking` publisher inside `MapScreenRedesignView`. Animate with `DesignTokens.Motion.standard`.

### 7.D7 — Road ribbon overlay (Medium)

- **Red — integration test** (`RoadQualityMapViewTests`):
  - Inject `pendingDriveCoordinates = [c1, c2, c3]`.
  - Render. Assert the layer-id `"user-drive-ribbon"` exists with ≥ 2 vertices.
- **Green:** Add a new `LineLayer` or `PointAnnotationGroup` to `RoadQualityMapView` sourced from `pendingDriveCoordinates`, styled with the existing ramp colors. Opacity 0.7 so community layer shows through.

### 7.D8 — Celebrate *Mark pothole* on the FAB itself (Medium)

- **Red — `AppModelTests` + UI test**:
  - Assert after `markPothole()` returns `.queued`, the FAB's `accessibilityLabel` becomes `"Marked — undo available"` for 5 s, then reverts to `"Pothole"`.
- **Green:** Add `@State var fabState: FABState = .idle` in `MapScreenRedesignView`. On tap → `.justMarked`, start a 5-second timer, flip back to `.idle`. Render a receding-arc countdown around the FAB via `Path.addArc` animated by `TimelineView(.animation)`. Tapping during `.justMarked` calls `model.undoPotholeReport(id:)` and sets `.cancelled` briefly.

### 7.P1 — Remove duplicate Add Photo from Segment sheet (Medium)

Resolves M2 + M-dup from April 23 review as well.

- **Red — SegmentDetailSheet snapshot test:** Assert no element with id `"segmentDetail.add-photo"`.
- **Green:** Delete the `onAddPhoto` hook and its rendered button. Keep the pothole row still-there/looks-fixed actions.

### 7.S1 — Stats: impact + community cards (High)

- **Red — unit + snapshot**:
  - `UserStatsSummary` grows `approvedPotholeCount: Int` + `pendingPotholeModerationCount: Int` + `nearbyCommunityKmThisWeek: Double` fields.
  - Snapshot of `StatsView` with `approvedPotholeCount = 2, pendingPotholeModerationCount = 1` asserts a row with `"2 have been fixed"` and a row `"1 awaiting moderation"`.
  - Snapshot with `nearbyCommunityKmThisWeek = 318` asserts text `"318 km"` in a card labeled "Community".
- **Green:**
  - Extend `UserStatsSummary` + `UserStatsStore.summary()` to populate the new fields (backend-light: client can compute pothole statuses from its own records; community field reads a cached `/stats/community` response that falls back to `0`).
  - Add `ImpactCard` and `CommunityCard` views.
  - Wrap current Accepted/Pending/Privacy-filtered rows in a `DisclosureGroup("Technical details")`, collapsed by default.

### 7.S2 — Animate medallion count-up (Medium)

- **Red — UI test** with `XCUIElement.value` polled:
  - Arrange a scenario where stats refresh from `12 → 47` segments.
  - Assert intermediate values observed (`accessibilityValue` goes through 20-something) within a 900 ms window.
- **Green:** Wrap the medallion number in an `AnimatedCounter` view backed by a `TimelineView(.animation)` + `withAnimation(DesignTokens.Motion.celebrate)`. Expose the current displayed value as `accessibilityValue` for the test.

### 7.Set1 — Demote destructive data deletion — Medium

- **Red — snapshot test** of `SettingsView`:
  - Assert no element of type `Button` styled `.borderedProminent` with `.tint(DesignTokens.Palette.danger)`.
  - Assert a `Button("Starting fresh…").buttonStyle(.plain)` or text-style exists at the *bottom* of the scroll view.
- **Green:** Replace the bordered-destructive button with a plain text button in a final "Starting fresh" card.

### 7.Set2 — Push PrivacyZonesView from Settings nav, not sheet — Low

- **Red — UI test**: From Settings, tap *Manage privacy zones*. Assert the screen appears via push (navigation back button visible), not a sheet (no drag handle).
- **Green:** Wrap `SettingsView` in a `NavigationStack`; replace `Button("Manage privacy zones") { dismiss(); onManagePrivacyZones() }` with `NavigationLink("Manage privacy zones") { PrivacyZonesView(...) }`.

### 7.PZ1 — Radius slider shows human reference — Low

- **Red — snapshot test**: Render `PrivacyZonesView` with `draftRadiusM = 300`. Assert a text element matches `"~1 city block"`. Render with `800` → `"~2 blocks"`.
- **Green:** Add a `radiusHumanReference(_:)` function mapping radius buckets to 1-liner labels. Render under the slider.

### 7.Cam1 — Camera review state pro-social subtitle — Low

- **Red — snapshot test** of `PotholeCameraFlowView` in review state:
  - Assert text matches `"This will help moderators"`.
- **Green:** Add subtitle below *Review photo* label.

---

## 8. Already-resolved in prior review

Cross-reference with `2026-04-23-pothole-photo-workflow.md`:

| Prior | Status |
|---|---|
| H1 camera `fullScreenCover` vs sheet | Redesign in §D1 removes `SegmentDetailSheet`-driven camera path; re-validate after ship. |
| H2 image processing on main | Independent; still open. |
| H3 follow-up prompt behind sheet | Redesign dissolves the segment-sheet photo CTA (§P1); follow-up prompts become a stopped-proximity banner in §D9. |
| H4 delete-before-save | Independent; still open. |
| H5 discard/upload race | Independent; still open. |
| H6 camera auth re-check | **Resolved** — `onChange(of: scenePhase)` handler present. Close H6. |
| H7 server SHA verification | Independent; still open. |
| M1 segment_id pass-through | Independent; still open. |
| M2 Add-photo gate | Dissolved by §P1 (Add Photo no longer gated on segment-level surface). |
| M3 buttons on resolved potholes | Independent; still open. |

---

## 9. Open questions

- **Name decision** — Patch, Rumble, Plot, stay? Blocks copy + mark work.
- **Bundle size budget** — adding ~400 KB of fonts is worth it IMO, but confirm with your TestFlight beta size targets.
- **Community stats backend** — cheap `/stats/community` aggregate exists yet? If not, is the one-line aggregate query worth adding before this redesign ships? (See §11.)
- **Leaderboard comfort level** — the "Top 7%" line in the Stats redesign is gamification. Is that on-brand for civic or does it cross into Strava-land in a way that undermines the pro-social angle?
- **Always-Location auto-prompt frequency cap** — one shot is the proposed default. If denied, do we ask again at 30 days? Never?
- **Road ribbon retention** — paint forever, or fade after 7 days once it's represented in the community layer? I'd fade.
- **Install → first-drive funnel** — do we want it? (§11.2.) Answering *yes* means shipping one new anonymous ping; *no* means we trade funnel visibility for the cleanest possible privacy story.

---

## 10. Readiness summary

**Not a ship-blocker review — this is a direction review.** The current app is correct; the redesign is about pulling the product's voice and visual density into alignment with the brief ("stupid simple, single hero action, pro-social, set-and-forget").

Recommended sequence if you take all of this:

1. **Week 1** — brand name + domain lock (§7.B1). Typography bundle (§7.B2). BrandVoice strings file (§7.B4).
2. **Week 2** — onboarding copy + Always-Location auto-prompt (§7.O1, O2, O3, O4).
3. **Week 3** — driving screen redesign behind feature flag (§7.D1, D4, D5, D6, D7, D8). This is the big one.
4. **Week 4** — stats rebuild (§7.S1, S2). Settings + privacy tweaks.
5. **Ship** — flip the flag, retire the old bottom card.

Ship in that order and each week produces something shippable on its own, with the driving redesign de-risked by the flag.

Mockup file: `ios/RoadSenseNS/Features/Map/MapScreenRedesignPreview.swift`.

Analytics appendix: §11.

---

## 11. Appendix — Anonymous analytics & portfolio stats

Added after the main review in response to the product question: *we keep user data private, but we'd still like to know aggregate adoption — contributors, devices, coverage — for a public stats page, a portfolio, and eventual advertiser/partner conversations. How do we get that without undermining the privacy posture?*

The answer is a three-layer rule. Everything in layer 1 is free and shippable now. Layer 2 requires a deliberate decision. Layer 3 is a hard "no."

### 11.1 Free today — backend-derived aggregates

Your backend already stores everything needed for a credible stats page. Nothing changes on the client, no new telemetry, no trade-off against the privacy story.

The existing data model knows (via `readings`, `pothole_reports`, `device_tokens`, and the already-partitioned monthly tables):

- Unique contributors ever (`COUNT DISTINCT device_token_hash`).
- Active contributors (last 24 h / 7 d / 30 d).
- Total km mapped · total readings accepted · total potholes flagged · total photos approved.
- % of NS road network with ≥ 1 reading (spatial coverage).
- Geographic distribution — municipality-level contributor counts.
- Drive-session counts derivable from upload batch timestamps clustered per `device_token_hash`.

A single `stats_public` SQL view + a hardened Edge Function (`/stats/public`) covers the portfolio/landing-page need. Refresh nightly via the existing `pg_cron` installation (already used by `20260418165013_nightly_recompute_and_cron.sql`).

**Sketch:**

```sql
-- 20260424_stats_public.sql
CREATE MATERIALIZED VIEW stats_public AS
SELECT
  COUNT(DISTINCT device_token_hash) FILTER (WHERE inserted_at > NOW() - '30 days'::interval) AS contributors_30d,
  COUNT(DISTINCT device_token_hash) FILTER (WHERE inserted_at > NOW() - '7 days'::interval)  AS contributors_7d,
  COUNT(DISTINCT device_token_hash) AS contributors_total,
  COALESCE(SUM(ST_Length(geom::geography)), 0) / 1000.0 AS km_mapped_total,
  COUNT(*) AS readings_accepted_total
FROM readings;

-- Scheduled via pg_cron alongside the existing nightly_recompute job.
SELECT cron.schedule('refresh_stats_public', '10 3 * * *',
  $$ REFRESH MATERIALIZED VIEW CONCURRENTLY stats_public; $$);
```

**k-anonymity floor.** Before exposing any slice narrower than "all of NS" (e.g., per-municipality counts), apply a minimum-cell rule: if `contributors_<slice> < 5`, return `NULL` or roll up into the parent. Cheap, uncontroversial, and heads off inferring presence from small-town slices.

**Copy posture.** Lean into it on the marketing site:

> *"Right now, 1,243 drivers in Nova Scotia have mapped 18,412 km of road. We know that — we don't know who. Here's exactly what we count and why." (→ transparency page)*

### 11.2 Layer 2 — one deliberate decision

There's one thing `stats_public` cannot tell you: **how many people install the app and never drive.** Install-to-first-drive conversion is a real product + portfolio signal and it's invisible to a contributors-only aggregate, because a non-contributor is by definition not in the `readings` table.

If you want it, the pattern is:

- On first launch, generate an **anonymous install UUID** stored in the iOS keychain.
- Ping a new `/stats/install` endpoint exactly once per install with the UUID + app version + `locale`.
- Ping a `/stats/first-drive` endpoint exactly once, the first time the client successfully uploads a batch.
- The UUID is **never linked** to `device_token_hash`, readings, or any other table. It lives in its own `install_pings` table that is purged monthly to rolling aggregates.

That's it. You now have install count, first-drive count, and install → first-drive conversion rate. Two endpoints, one ephemeral table, no behavioral tracking.

**The decision to make:** is that install UUID worth it? My take is yes — conversion rate is the single most important metric for you personally (portfolio) and for anyone considering a municipal or fleet partnership. But it *is* a new stream of "we ping a server on launch" that wasn't there before, and the transparency page has to name it. If you want the absolute cleanest story, skip it and accept that install count is unknowable.

**If you add it, do this one thing right:** store the install UUID *only* client-side in the Keychain with `kSecAttrAccessibleAfterFirstUnlock`, and do **not** include it in crash reports. On the server side, the `install_pings` table gets a hard 35-day TTL — aggregate counters persist, the UUIDs don't.

### 11.3 Layer 3 — hard no, don't drift here

- **No third-party analytics SDKs.** Firebase Analytics, Mixpanel, Amplitude, Segment, PostHog-cloud — all would shred the privacy positioning you're building as a brand. Even in their "privacy-safe" modes they retain more device identity than you want to defend on a transparency page. If you later decide you need richer client-side instrumentation, run PostHog self-hosted on the same infra as Supabase, so the data never leaves your stack.
- **No per-screen / per-tap telemetry.** Resist the temptation. Every event you add is a row on the transparency page and a reason users won't trust the "we don't watch you" promise. Server-side aggregates give you 80% of what you'd ever learn from screen telemetry; the remaining 20% isn't worth the cost.
- **No rotating `device_token` alone.** If you ever decide to rotate `device_token` for privacy (reducing linkability across long time ranges), you *simultaneously* have to introduce a separate short-lived analytics token, or MAU numbers will explode and become meaningless. Not a problem today — note for the file.
- **Sentry stays narrow.** `SentryBootstrapper` is already wired in. Audit its config to confirm:
  - `beforeSend` scrubs location coordinates from any breadcrumb.
  - `sendDefaultPii = false`.
  - No custom `setUser`/`setTag` calls include device token, location, or route data.
  - The transparency page names Sentry explicitly: *"We use Sentry to learn about app crashes. It never sees your location or contribution data."*

### 11.4 Public transparency page (do this first)

Before anything else in §11 ships, write a single-page `/privacy-and-counts` on the marketing site that declares:

- What we count at the aggregate level (from `stats_public`).
- What we *don't* collect (advertising IDs, screen-view analytics, device profiling).
- What Sentry sees (crashes, not content or location).
- Whether the install ping is live (if §11.2 ships).

This page is the brand. It's also the only reason "advertisers" is a defensible future conversation — ad buyers who care will ask, and a clean transparency page is the difference between a ten-minute yes and a month of legal back-and-forth.

### 11.5 Recommended MVP — two weeks of work

In priority order:

1. **`stats_public` migration + materialized view + nightly refresh** (§11.1). Half a day.
2. **`/stats/public` Edge Function**, cached at the edge, returning the view as JSON. Half a day.
3. **Marketing-site `/stats` section** consuming it, plus the transparency page. One day.
4. **Decision point:** install UUID for funnel (§11.2) — yes / no, documented in an ADR.
5. **If yes:** `install_pings` table + `/stats/install` + `/stats/first-drive` endpoints + client keychain UUID + 35-day TTL cron. Two days.
6. **Sentry audit** and transparency page update. Half a day.

That's shippable in a sprint and gives you a real portfolio page plus a defensible narrative.

### 11.6 Red / green TDD plan

Follows the §7 convention.

#### 11.A — `stats_public` materialized view (High)

- **Red — pgTAP test** (`supabase/tests/stats_public_test.sql`):
  - Seed `readings` with 3 known `device_token_hash` values across 10 rows, spaced over 60 days.
  - Refresh the view.
  - Assert `contributors_total == 3`, `contributors_30d` reflects only recent-window rows, `km_mapped_total` matches the sum of `ST_Length(geom)/1000`.
  - Assert the view is owned by `postgres`, selectable by `anon`/`authenticated`, and that no row-level leak reveals per-device data.
- **Green:** The migration in §11.1. Grant `SELECT` to `anon` on `stats_public` only.

#### 11.B — `/stats/public` Edge Function (High)

- **Red — Deno test** (`supabase/functions/stats-public/handler_test.ts`):
  - Given a stubbed `stats_public` row, invoke the handler.
  - Assert response is `200`, JSON-shaped with the 5 public fields, `Cache-Control: public, max-age=3600`, and no row containing any field named `device_token_hash`.
  - Assert the handler rejects any request with a body (it's a pure GET).
- **Green:** A minimal handler that runs a single `SELECT * FROM stats_public` and returns it JSON-encoded. No auth required — this is meant to be public.

#### 11.C — k-anonymity floor for narrower slices (Medium)

- **Red — pgTAP test**: Seed a slice (municipality: "Tiny Village") with 2 distinct `device_token_hash` contributors. Query a `stats_public_by_municipality` view. Assert the "Tiny Village" row either returns `NULL` for contributor counts or is rolled into a "Rest of NS" bucket.
- **Green:** The by-municipality view uses `CASE WHEN COUNT(DISTINCT device_token_hash) < 5 THEN NULL ELSE ... END` for any contributor count.

#### 11.D — Install ping (conditional on §11.2 decision — Medium)

- **Red — Deno test + iOS test**:
  - Deno: handler rejects a second ping with the same install UUID inside 24 h (idempotency).
  - Deno: asserts rows older than 35 days are purged on nightly cron.
  - iOS: `InstallTelemetry.pingOnceIfNeeded()` reads/writes Keychain, pings once, and is a no-op thereafter.
- **Green:**
  - iOS `InstallTelemetry` service, keychain-backed UUID.
  - `install_pings` table with `(install_uuid, app_version, locale, first_seen_at)`.
  - `/stats/install` Edge Function with `ON CONFLICT DO NOTHING`.
  - Nightly cron: `DELETE FROM install_pings WHERE first_seen_at < NOW() - INTERVAL '35 days';` — aggregates live in a separate `install_metrics_daily` table updated by the same cron before delete.

#### 11.E — Sentry scope audit (High)

- **Red — unit test** (`SentryBootstrapperTests`):
  - Given a mocked `Scope`, invoke `SentryBootstrapper.bootstrap(config:)`.
  - Assert `options.sendDefaultPii == false`, `options.beforeSend` drops any event whose breadcrumbs include a `CLLocationCoordinate2D`-shaped payload, and `options.beforeSend` strips any key matching `/token|hash|device_id/i`.
- **Green:** Tighten `SentryBootstrapper.bootstrap(config:)` with the scrubbing closure and the `sendDefaultPii` flag. Add an assertion + compile-time test that no `SentrySDK.setUser(...)` call exists anywhere in the codebase (grep-style lint).

#### 11.F — Transparency page content contract (Low)

- **Red — web test** (when the site exists): fetch `/privacy-and-counts`. Assert the page mentions every telemetry source that ships (Sentry, and install pings if §11.D lands) and links to the counts page.
- **Green:** Write the page. Keep it short — one scrollable panel. Date-stamped.

---

## 12. Hardening review — stress test on the design + plan

Added in response to the product brief: *"be critical and stress test, this thing should be bulletproof and beautiful, with no detail overlooked."* This section assumes the rest of the doc is the proposal and goes looking for what's wrong with it.

Structure: unresolved semantics → ergonomics/safety → accessibility → edge cases → plan realism → copy/brand → missing work → revised priority list.

### 12.0 Summary — what must be resolved before ship

Seven items that are currently either ambiguous, unsafe, or actively wrong. Nothing ships until each of these has a definition (or an explicit "not in v1" decision):

1. **Progress ring semantics are undefined.** §D1 says the ring fills with drive progress. What does 100% mean? What happens past 100%? Is it a goal, a heartbeat, or decorative? This question has three reasonable answers and zero picked. Resolution in §12.1.1.
2. **Camera capture while moving is not safety-gated.** Today the camera FAB opens the live capture view regardless of vehicle speed. At highway speed this is a crash risk and a potential App Store rejection. Resolution in §12.2.1.
3. **Rapid consecutive pothole marks are locked out.** The "Marked!" celebration occupies the hero FAB for the full 5-second undo window. If a second pothole is 3 seconds down the road, the user can't report it. Resolution in §12.2.2.
4. **There is no "attention needed" treatment for the new layout.** The original `MapScreen` branched `headerSubtitle` across 8 states (GPS lost, upgrade needed, paused, etc.). The redesign deletes the whole subtitle and proposes a `needsAttention: NeedsAttention?` chip — but never defines what it looks like or where it lives. Resolution in §12.2.6.
5. **Haptics are absent.** For a one-glance driving action, haptic confirmation is table stakes. Not mentioned in the plan at all. Resolution in §12.3.6.
6. **The `§7.O2` auto-prompt may violate Apple HIG.** Auto-presenting a modal permission pre-prompt on second launch has a history of App Store rejections. The plan treats this as trivial. Resolution in §12.5.5.
7. **Rollback plan for the driving redesign flag doesn't exist.** `§7.D1` says "ship behind a feature flag, then flip it." What happens if real-world usage surfaces a regression after flip? How fast can you roll back? What data was written under the new schema that won't read under the old? Resolution in §12.5.7.

Everything below §12.0 expands these plus finds more.

### 12.1 Unresolved semantics

#### 12.1.1 Progress ring meaning — High

The teal ring around the hero FAB animates with `progress: Double` in the mockup. In production, what drives `progress`?

**Three plausible options:**
- **(a) Drive odometer** — fills from 0 → 1 over N km of the current session. At 100%, either stops filling or loops. Problem: users don't care about arbitrary km targets, and looping is confusing.
- **(b) Heartbeat** — a small segment orbits the ring slowly to signal "recording." No fill-level semantic. Problem: fewer information dimensions visible at a glance.
- **(c) Batch confidence** — fills as the device approaches an upload batch (500 readings → 100% → empty + subtle pulse when uploaded). Problem: ties UI to an implementation detail; upload cadence changes and the ring meaning changes with it.

**Recommend (b) heartbeat** + reserve the ring fill for a single clear state: a thin amber arc during the 5-second undo window (which is what `CountdownRing` already does). The rest of the time, a subtle 60-degree teal arc slowly rotates — alive, no goal, no confusion. This also fixes 12.0 #3 because the undo-window arc doesn't lock out a new pothole mark.

TDD: **Red** — unit test that `ringProgress` is a computed property with exactly two states (`.ambient` slow orbit, `.undoCountdown(deadline: Date)`), no raw `Double`. **Green** — refactor `ProgressRing` into `AmbientRing` + `CountdownRing`, delete the `progress: Double` API.

#### 12.1.2 Road ribbon retention — High

Question raised in §9, still unanswered. Three options:
- Paint forever on device; fade on map after 7 days once community layer has absorbed it.
- Paint for the current drive only; clear on session end.
- Paint for the current day's drives; clear nightly.

Privacy implication: a persistent ribbon shown on the map screen is a map of the user's recent movements visible to anyone who glances at the phone. Someone looking over a shoulder at a café sees a user's commute route. Recommend: **current drive only** on the map screen. Historical coverage appears on the Stats screen's Community card as aggregate, not routes.

#### 12.1.3 Pothole mark quarantine radius — High

Product-spec `§8` describes the canonical-pothole model: multiple reports cluster into one marker within a radius. What's the radius? The spec is silent. Today if a user taps Pothole twice 10 meters apart (same actual pothole, two taps through the GPS jitter), does the system create two reports or merge? Recommend: server-side dedup at ≤ 15 m within the same device in the last 10 minutes. Defined, not left to chance.

#### 12.1.4 Stats FAB flow — Medium

Tapping Stats from the 3-FAB row currently opens the existing full-screen `StatsView`. But mid-drive, a user who glances at Stats wants the answer in 3 seconds, not a modal push. Resolution: Stats FAB opens a partial detent sheet (`.presentationDetents([.medium, .large])`) so the map stays visible at `.medium`. Full `StatsView` is reachable via the sheet's "See all" link or via pull-up to `.large`.

#### 12.1.5 Community-stats window — Low

"Plus 318 km from 812 drivers near you." *When?* This week? Last 30 days? Ever? "Near you" means what — same municipality, or 50 km radius, or same province? Commit to *"this week, in Nova Scotia"* for MVP. Zero ambiguity, matches the `stats_public` view in §11.

#### 12.1.6 Brand chip interactivity — Low

Decorative in the current mockup. Proposal: make it a tap target that opens a small popover with "Currently recording · 4.2 km this drive · last upload 2 min ago" — collects the status-detail info that would otherwise live in Settings. Cost: one more interactive element, but it's a natural affordance already being glanced at.

### 12.2 Ergonomics, safety, and tap-target reality

#### 12.2.1 Camera-while-driving safety gate — High

**Problem:** `PotholeCameraFlowView` opens a live capture view the moment the camera FAB is tapped. No speed check. Driver snaps a photo at 80 km/h. That's dangerous, and Apple has rejected apps for less.

**Fix:**
- In `handleTakePhotoTap()`, read `locationService.smoothedSpeedMps`. If > 2.0 m/s (~7 km/h), do not open the camera. Show a small banner: *"Pull over to take a photo. We'll wait."*
- The camera FAB itself stays visible and tappable always (per the "whenever" brief), but opens the capture view only when safe. Otherwise it surfaces the wait-to-stop banner.
- Add a test: `AppModelTests.testCameraBlocksWhileDriving`.

**TDD:**
- **Red — `AppModelTests`**: Arrange `currentSpeedMps = 12`. Call `handleTakePhotoTap()`. Assert `photoCaptureContext == nil` and `potholeFeedback.title == "Pull over to take a photo"`.
- **Green:** Add speed gate + feedback path.

#### 12.2.2 Consecutive-mark lockout — High

**Problem:** After tapping Pothole, the hero FAB flips to "Marked!" for 5 seconds. During those 5 seconds, a second tap undoes the first mark rather than marking a second pothole. On a genuinely bad stretch of road with two potholes 30 m apart (1 second at 30 km/h), the user mashes the button and gets either a double-tap reading of undo-re-queue chaos or just one mark for two holes.

**Fix:**
- The FAB stays functionally "Mark pothole" during the celebration window. The celebration is a non-blocking visual (brief green flash + subtle pulse + label flip for 800 ms, not 5s).
- Undo lives on a separate mini-chip that pops up for 5 s below the FAB, labeled "Undo last" with an icon. Tap the chip to undo, tap the FAB to mark another.
- Accessibility: the FAB's label stays "Mark pothole" consistently; the chip announces "Undo available, expires in 5 seconds."

This fully deletes the "celebrate on the FAB" idea from §7.D8 and replaces it with a celebrate-briefly-then-step-aside pattern. Update §7.D8 accordingly.

**TDD:**
- **Red — `AppModelTests`**: Arrange state where `markPothole()` returned `.queued` at T. Advance time by 1 s. Call `markPothole()` again. Assert two separate `PotholeActionRecord`s exist (not an undo + re-queue).
- **Green:** Move undo to a separate state + UI element; keep the FAB always marking.

#### 12.2.3 Pothole FAB tap precision in motion — Medium

A 96-pt visible body at arm's length on a bumpy road is generous but not generous enough. Apple HIG says 44pt minimum hit target; industry practice in driving/nav apps is to extend the hit area ~1.2× past the visible body for bumpy-road forgiveness.

**Fix:** Wrap the hero FAB in a `.contentShape(Rectangle().inset(by: -20))` or equivalent, so taps anywhere within ~116pt diameter register. Visual size unchanged; tactile size expanded.

Same principle for the secondary FABs — they're 56pt; add 16pt hit margin.

#### 12.2.4 Settings gear thumb reach on large phones — Low

On iPhone 17 Pro Max (440pt wide), the top-right settings gear is a full thumb-stretch from a right-handed grip. That's fine — Settings isn't frequent. But if the current top-right ever hosts something frequent (the previously-proposed stats icon that we moved to the bottom row), revisit.

**Decision:** leave Settings top-right. Frequency justifies the reach.

#### 12.2.5 Pothole FAB when not driving — Medium

The pothole FAB is always visible — that was deliberate per the brief ("whenever"). But when user opens the app parked in their driveway and taps it, the mark uses their current location — inside their own privacy zone. Today the code handles this: `markPothole()` returns `.insidePrivacyZone` and the feedback says "Inside a privacy zone." Good.

But the *visual* affordance makes no distinction between "this will mark a real pothole" and "this will be rejected." A small hint would be kind:
- When no GPS fix: FAB body slightly desaturated, tap shows "Need a fresh GPS fix" (already handled, but add subtle desat to the FAB).
- When inside privacy zone: FAB body slightly desaturated (same treatment), tap shows the existing rejection copy.
- When outside NS bounds: same.

This is the difference between the FAB feeling like a button that sometimes does nothing versus a button that tells you, in its own appearance, when it's ready.

**TDD:**
- **Red — SwiftUI snapshot test**: Render driving screen with `currentFix = nil` (no GPS). Assert the hero FAB's `accessibilityValue` contains "not ready."
- **Green:** Add a derived `HeroPotholeFAB.readiness: .ready | .needsFix | .inPrivacyZone | .outsideBounds` state that adjusts body opacity (0.7 when not ready) and accessibility value.

#### 12.2.6 "Needs attention" treatment — High

The old `MapScreen.headerSubtitle` branched across 8 states. The redesign deletes the whole subtitle and proposes a `needsAttention: NeedsAttention?` chip that the current mockup never renders.

**Fix (define it):**
- A single pill that replaces or sits beside the brand chip when any of these is true: `.backgroundCollection == .upgradeRequired`, `.locationPermission == .denied`, `.motionPermission == .denied`, `.mapLoadError != nil`, `.isCollectionPausedByUser`, or `.uploadStatusSummary.failedPermanentBatchCount > 0`.
- Pill is tappable and expands into a small modal with the single next action ("Turn Always Location on," "Reconnect," etc.).
- Only one pill at a time — picked by priority order: permission > collection paused > upload failed > map error.

**TDD:**
- **Red — snapshot + unit test**: Various `readiness` + `uploadStatusSummary` combinations → assert the correct pill copy + action.
- **Green:** Implement `NeedsAttentionPill` view + `AppModel.attentionPriority` computed property.

#### 12.2.7 Marked-pothole location drift — Medium

User marks a pothole at T. The undo window is 5 s. At T+2 s they've driven 15 m. If they then undo, we undo correctly. If they don't undo, we upload the location at T. Question: do we upload the location at T or at T+5 (which is 40 m further down the road)? Currently ambiguous in `ManualPotholeLocator`. Must be T — the location is captured at tap, frozen for the undo window, and only then committed.

Verify: `ManualPotholeLocator.swift` freezes coordinates at `markPothole()` time. Add a regression test if not.

### 12.3 Accessibility gaps

#### 12.3.1 VoiceOver navigation order — High

In the 3-FAB row with top chrome, VoiceOver's default order is top-to-bottom, reading order. That means: brand chip → settings → center content → Photo FAB → Pothole FAB → Stats FAB. For a user who opens the app one-handed with VoiceOver, the most important action (Pothole) is the 5th announce. Wrong priority.

**Fix:** Add `.accessibilitySortPriority(...)` so Pothole FAB is announced first, then Photo, then Stats, then brand chip + settings. Test with VoiceOver in the simulator.

**TDD:**
- **Red — UI test** with `app.buttons.firstMatch`: Assert the first hittable accessibility button is `"Mark pothole"`.
- **Green:** Apply `accessibilitySortPriority` on the FABs and top chrome.

#### 12.3.2 Dynamic Type handling — High

Current fixed sizes (FAB label `.font(.system(size: 14, weight: .bold, design: .rounded))`) will not scale with Dynamic Type. A user on AX3 setting gets a tiny "Pothole" label under a 96-pt button. Violates iOS guidelines.

**Fix:** Use `.font(.system(.caption, design: .rounded, weight: .bold))` (dynamic) instead of fixed size for FAB labels. Cap at one-step-up to prevent layout breakage (`.dynamicTypeSize(.large ... .accessibility3)`).

Same pass needed on BrandChip's "RoadSense" label and every other UI text in the mockup.

#### 12.3.3 Reduced Motion support — High

The pulsing dot on the BrandChip, the ring's ambient rotation (proposed in §12.1.1), the CountdownRing animation, and the "Marked!" celebration all violate `UIAccessibility.isReduceMotionEnabled` if run unconditionally.

**Fix:** Wrap all animations in `.animation(nil, value: reduceMotion)` or explicitly check `@Environment(\.accessibilityReduceMotion)` and substitute:
- Pulsing dot → static dot
- Ambient ring rotation → static arc
- CountdownRing → numeric countdown text
- Celebration spring → static color change

**TDD:**
- **Red — snapshot test** with Reduce Motion forced on: assert no `.animation(...)` modifiers on the PulsingDot or ProgressRing.
- **Green:** Wire `@Environment(\.accessibilityReduceMotion)` through relevant views.

#### 12.3.4 Color-only state conveyance — Medium

The hero FAB transitions from amber (idle) → green (just marked). Colorblind users (deuteranopia is ~6% of men) see this as brown → olive. The checkmark icon change carries the information too, which is good — but the ambient ring teal → amber proposal (§12.1.1 undo) is color-only for non-icon state. Add a thin inner ring of dashed stroke during undo countdown as a non-color signal.

#### 12.3.5 Voice Control labels — Low

"Pothole" is a valid Voice Control target word. "Stats" and "Photo" are too. Settings gear's accessibility label is currently just the SF Symbol name. Confirm all labels are spoken correctly: add `accessibilityLabel("Settings")` explicitly.

#### 12.3.6 Haptics catalog — High

No mention of haptics anywhere in the plan. For a driving app where visual confirmation competes with the road, haptic feedback is critical.

**Catalog needed:**
- **Mark pothole tap:** `UIImpactFeedbackGenerator(.medium)` on tap + `UINotificationFeedbackGenerator(.success)` on successful queue.
- **Mark rejected (privacy / GPS / bounds):** `UINotificationFeedbackGenerator(.warning)`.
- **Undo tap:** `UIImpactFeedbackGenerator(.light)`.
- **Camera opened:** `UIImpactFeedbackGenerator(.soft)`.
- **Drive session start / end:** no haptic — too intrusive for background behavior.
- **Always-Location upgrade prompt auto-appear:** no haptic.

Also test with Reduced Motion / Haptics off — iOS respects system-wide haptic preferences automatically, but verify.

**TDD:**
- **Red — test** with a `HapticsServicing` protocol injected into `AppModel`: assert `markPothole()` invokes `.impact(.medium)` then `.notification(.success)` on success.
- **Green:** Extract haptics behind a protocol; swap in a spy for tests.

### 12.4 Edge cases and failure modes

Grid of scenarios the redesign must cover. A checked box means the plan has a definition; an unchecked box means this is work to add to the plan.

| Scenario | Current handling | Gap |
|---|---|---|
| Map tile request fails (quota, offline) | Old `mapLoadError` banner inside bottom card | [ ] Redesign deletes bottom card. Where does the banner go? Answer: into the NeedsAttentionPill (§12.2.6). |
| GPS denied mid-drive | `CLLocationManagerDelegate` stops collection; not visually communicated in the redesign | [ ] NeedsAttentionPill with "GPS turned off — tap to fix." |
| GPS `.reducedAccuracy` (iOS 14+ setting) | Spec mentions but no UI | [ ] Same pill, different copy. |
| Motion permission revoked mid-session | Fall back to GPS-only (spec) | [ ] Pill: "Running without motion — accuracy reduced." |
| App force-quit | iOS won't restart background location; spec uses `significantLocationChange` to wake | [ ] Local notification copy needs design. (§12.7.1) |
| Low Power Mode | Spec adjusts sampling rates | [ ] Subtle brand-chip battery glyph? Or silent? Decide. |
| Thermal `.serious` / `.critical` | Spec pauses collection | [ ] Pill copy + auto-resume on cooldown. |
| Offline (cellular off entirely) | Spec queues uploads | [ ] Visible indicator. Pill copy: "Offline — uploads queued." |
| User pauses collection | Banner in old card; redesign deletes card | [ ] Pill: "Paused — tap to resume." |
| Upload failed permanently | Settings has a retry button | [ ] Surface in NeedsAttentionPill too. |
| Pothole marked 5m inside a privacy zone | Rejected with message | OK |
| Pothole marked 5m **outside** privacy zone boundary | Accepted | [ ] Consider a 50m buffer to reduce leakage near sensitive areas. |
| Two marks within 3 s within 10m | Likely dedup server-side but undefined (§12.1.3) | [ ] Define radius + window. |
| Screen rotates to landscape mid-drive | Not designed | [ ] Lock to portrait for MVP. Add to `Info.plist`. |
| iPad (12.9") | Not designed | [ ] v1: iPhone only. Explicit. |
| Permission revoked via Settings then user returns | `OnboardingFlowView.permissionHelp` state | OK (existing) |
| User attempts to mark pothole without an active drive (engine off) | `markPothole()` succeeds if GPS fix present | [ ] Should succeed (pedestrian scenario) but ensure location is fresh. |
| Camera session already in use (FaceTime, other app) | Currently silent failure | [ ] Detect `AVCaptureSession.RuntimeErrorNotification` and show recovery. |
| App updated mid-session | Unknown | [ ] Investigate. |

### 12.5 Plan realism — where §7 is optimistic or wrong

#### 12.5.1 Week estimates are aggressive — Medium

Summary table from §10 says Week 3 is "Driving screen redesign behind feature flag." Actual scope:
- 3-FAB row + hero FAB with real app data wiring
- AmbientRing + CountdownRing + haptics + NeedsAttentionPill
- Road ribbon Mapbox layer (new) + fade policy (§12.1.2)
- Dynamic Type + Reduced Motion + VoiceOver sort priority
- Tap-forgiveness hit regions
- Speed gate on camera
- Marked-pothole location freeze test
- Consecutive-mark support (rewrite §7.D8)
- Feature flag infra + rollback path (§12.5.7)

Realistic: 2–3 weeks with 1 engineer. Plan-wide adjusted estimate: **6–8 weeks to ship**, not 4.

#### 12.5.2 Test tooling not present — High

Multiple §7 reds reference snapshot tests. `swift-snapshot-testing` is not a dependency in `ios/Package.swift`. Either:
- Add the dependency (Pointfree's `swift-snapshot-testing` works fine) — adds ~150 KB
- Implement snapshot equivalents using `ImageRenderer` + manual byte compare (DIY)
- Drop snapshot reds; rely on `accessibilityLabel`/`accessibilityValue` assertions

Recommendation: add `swift-snapshot-testing`. Cheaper than DIY, well-maintained.

#### 12.5.3 Test accessibility identifiers don't exist yet — Medium

The plan references `"map.mark-pothole-fab"`, `"map.camera-fab"`, `"map.stats-fab"` etc. None of these exist in code. They need to be added as part of the same PR that introduces the redesign — otherwise the red tests can't even compile. Add this to §7.D1's Green list explicitly.

#### 12.5.4 Font licensing not verified — Medium

§7.B2 plans to bundle Fraunces (SIL OFL — fine, free for embedding) and IBM Plex Mono (also SIL OFL — fine). Confirm both license texts are added to the app's Acknowledgements / Settings → About → Licenses screen. Currently not surfaced anywhere in the plan.

**TDD:**
- **Red — UI test**: navigate to Settings → About → Licenses. Assert "Fraunces" and "IBM Plex Mono" entries exist with the SIL OFL preamble.
- **Green:** Add license bundle + UI surface.

#### 12.5.5 Always-Location auto-prompt may fail App Store review — High

§7.O2 proposes auto-presenting a full-screen modal asking for the Always-Location upgrade after the first drive. Apple's HIG language ("Avoid asking people for permissions out of context") and recent rejections of similar pre-prompts suggest this is risky.

**Safer pattern:**
- Don't auto-present a modal. Auto-present an *in-app banner* (non-blocking) at the top of the map screen on the first foreground after a successful drive: *"Always Location → set it once, drive forever. Set up now."*
- Tap the banner → the full-screen modal explains and asks. That's the user-initiated step that satisfies HIG.
- Banner is dismissible. If dismissed, re-show after 7 days. If dismissed twice, never show again — Settings remains the path.

Update §7.O2 plan accordingly.

#### 12.5.6 Stats partition scan cost — Medium

§11.1 sketches `stats_public` aggregating `readings`. Spec says `readings` is partitioned by month. A `COUNT DISTINCT device_token_hash` over all-time scans every partition every refresh. Cost grows linearly with months in operation.

**Fix:**
- Maintain a *cumulative* table updated incrementally rather than recomputed nightly. Each night, the cron computes deltas from the previous run (`WHERE inserted_at > <last_run>`) and increments counters.
- For `COUNT DISTINCT` you need HyperLogLog (`hll` extension on Postgres, or built-in `pg_stat_statements` is unrelated). Add `CREATE EXTENSION hll;` migration.
- Or, keep the simple recompute and accept that at 24 months in, the nightly job is ~10× slower than at month 1. For an MVP, this is fine. Revisit at scale.

Pick the simple path now, add a TODO for HLL once month count > 12.

#### 12.5.7 Rollback plan for the feature flag — High

§7.D1 says "ship behind a feature flag, then flip it." Missing:
- What does flag-off look like? Does the old `MapScreen` stay in the binary? For how long?
- If the new redesign is flagged on for 5% of users and we see crashes, how do we roll back? Is the flag remote (LaunchDarkly, GrowthBook, custom) or compile-time?
- What about state written under the new model (e.g., new pothole records, new analytics events) that the old code might not know how to read?

**Decision required:**
- Flag is *runtime* and remote-controllable (cheaper than ship-a-new-build to roll back).
- Old `MapScreen` stays in binary for 1 release cycle (~6 weeks) after flip, then deleted.
- Schema changes are backward-compatible. New optional fields, no required-renames.

Document this in an ADR before §7.D1 starts.

#### 12.5.8 Sentry scrubbing test specificity — Low

§11.E proposes a "coordinate-shaped payload" detector in `beforeSend`. "Coordinate-shaped" needs a definition. Concrete:

```swift
// In SentryBootstrapper.beforeSend:
if let breadcrumbs = event.breadcrumbs {
    event.breadcrumbs = breadcrumbs.compactMap { breadcrumb in
        var sanitized = breadcrumb
        if let data = sanitized.data {
            sanitized.data = data.filter { key, value in
                let lowerKey = key.lowercased()
                if lowerKey.contains("latitude") || lowerKey.contains("longitude") ||
                   lowerKey.contains("coord") || lowerKey.contains("location") {
                    return false
                }
                if lowerKey.contains("token") || lowerKey.contains("hash") || lowerKey.contains("device_id") {
                    return false
                }
                return true
            }
        }
        return sanitized
    }
}
return event
```

Update §11.E's Green section with this snippet as the canonical implementation.

### 12.6 Copy and brand

#### 12.6.1 No tone workshop with non-engineers — Medium

§1.4 + §7.B4 propose tone rewrites by one author (me). Civic apps live or die on tone. Ship the proposed copy to 3–5 actual NS drivers (a small TestFlight cohort or Discord poll) before locking. Cost: half a day. Risk-mitigated: real users confirm "On the record" doesn't read journalistic, "47 km of Nova Scotia mapped" doesn't read braggy.

#### 12.6.2 FAB labels are inconsistent — Medium

`Photo` (noun) | `Pothole` (noun = object of action) | `Stats` (noun). Reads like three different things, but they're all nouns of different *types*. The Pothole label is the only one where the noun is what you're acting *on*, not a category. Workshop options:
- All actions: `Photo` → `Add photo`, `Pothole` → `Mark pothole`, `Stats` → `Stats` (no good action verb fits).
- All categories: `Photo` (camera category), `Issue` (replaces pothole — broader action), `Stats`.
- Drop labels entirely (icons-only). Risky for first-time users.

Recommend: keep Pothole as the prominent verb-style label ("Pothole" means "tap to mark a pothole"), shorten Photo to single icon if first-run hint covers it, label Stats as a category-noun. This is fine but worth the one-hour copy review.

#### 12.6.3 Brand name still unresolved — High (timeline blocker)

Three options remain (Patch, RoadSense NS, Paved). Decision blocks: domain registration, App Store reservation, brand mark commission, BrandVoice copy lock, marketing site stub. Assign and resolve this **week 1**, not "before ship." If it slips past week 2, every downstream item bumps.

#### 12.6.4 "On the record" connotation risk — Low

Test it. If five real drivers say "this feels journalistic" or "law-enforcementy," replace with "Recording" or "Mapping" verb-state. The phrase is good if it lands; safe if it doesn't.

#### 12.6.5 Copy for failure states is missing — Medium

The plan rewrites positive copy beautifully but ignores failure copy. Currently the app has:
- *"Need a fresh GPS fix"* — fine
- *"Inside a privacy zone"* — fine
- *"Outside coverage area"* — bland
- *"Could not load road details"* — robotic

Add a §7.B4-equivalent pass on failure-state strings. This is also where brand voice is most tested — a friendly app that turns cold under stress feels insincere.

### 12.7 Missing surfaces and deliverables

#### 12.7.1 Notifications design missing — High

Product-spec mentions:
- *"Send a local notification after 48 hours of no data collection: 'RoadSense isn't collecting — tap to resume.'"*
- *"Detect via `ProcessInfo.thermalState`. At `.serious` or `.critical`, pause collection and notify user."*

No notification copy designed. No icon. No deep-link target. Add:
- `BrandVoice.Notifications.idleResume`, `BrandVoice.Notifications.thermalPause`, etc.
- A single `NotificationCoordinator` service + tests.
- A small notification surface in Settings → "Notifications you may receive" so users see the catalog.

#### 12.7.2 Dark mode visual check — Medium

Design tokens declare dark variants (`canvas` light `#F6F1E8` / dark `#0B1419`, etc.). The mockups have only been rendered in (effectively) dark mode — the deep-teal map placeholder reads dark in either system setting. The light-mode treatment of `OnboardingFlowView`, `StatsView`, `SettingsView`, `SegmentDetailSheet` has *not* been visually checked against the redesign palette. Add a light-mode pass:
- Render each redesigned mockup in light mode.
- Verify contrast ratios meet WCAG AA (4.5:1 for body text on canvas).
- Adjust if needed.

The `MockupRenderTests` test in `RoadSenseNSTests/` should produce light + dark variants of every scenario.

#### 12.7.3 Localization stance — High

Nova Scotia is officially bilingual in part (the Acadian regions). The app is English-only currently. Decision needed:
- v1: English only, with explicit "we ship French in v1.1" promise.
- v1: English + French, ~3 weeks added work.

Either is defensible. English-only is the realistic call. Document the decision.

If English-only ships, ensure:
- All strings flow through `Localizable.strings` (currently they don't — direct literals).
- The wrapper `BrandVoice.swift` (§7.B4) reads from `Localizable.strings` so a future French pass is a translation file, not a code change.

#### 12.7.4 iPad layout — Low

Out of scope for v1. Make explicit: `Info.plist` `UIDeviceFamily = [1]` (iPhone only). Rejecting iPad on the App Store is fine. Revisit if a pilot fleet uses iPads.

#### 12.7.5 App icon vs. brand mark — High

§1.3's Canvas-drawn `BrandMark` is for in-app use. The App Store / home-screen icon is a separate asset (1024×1024 PNG, no transparency, specific Apple guidelines). Currently planned: not at all. Need:
- Static rendered version of BrandMark at multiple sizes (40, 60, 80, 120, 180, 1024).
- Apple HIG tweaks (e.g., chevron stitch may need to be heavier at small sizes).
- An `AppIcon.appiconset` in `Assets.xcassets`.

Add to §7.B3 Green list explicitly.

#### 12.7.6 App Store screenshots — Medium

Need at minimum 6.5"-display screenshots for App Store submission. The PNG renderer in `MockupRenderTests` is currently iPhone 17 Pro (393×852). App Store requires iPhone 6.5" (1284×2778). Adjust the test to render both sizes.

Better: render every redesigned scenario at submission resolution and use those *as* the App Store screenshots. Single pipeline, design-aligned marketing, no extra work.

#### 12.7.7 Error state coverage matrix — Medium

For each major surface (Map, Stats, Settings, Privacy Zones, Camera, Onboarding, Segment Detail), enumerate:
- Loading state
- Empty state
- Network-failure state
- Permission-denied state
- Server-error state
- Offline state

Today the plan covers some (Map, Settings); others (Segment Detail, Camera review) are silent. Add a 1-page error-state design pass.

#### 12.7.8 TestFlight beta feedback loop — Low

How do TestFlight users send a "this is broken" report? In-app shake-to-report? `MFMailComposeViewController` button in Settings? TestFlight's built-in feedback?

Add a Settings → "Send feedback" row. Use TestFlight's feedback API for beta builds (`TestFlight: didReceiveScreenshotFeedback`), email mailto for release builds.

#### 12.7.9 Onboarding skipping for returning users — Low

What if a user uninstalls + reinstalls? `Keychain` survives uninstall on iOS by default. The app may treat them as a returning user and skip onboarding, but their `device_token` may have been issued under a different install. Verify the bootstrap path. Add a test.

### 12.8 Revised priority list

Folding §12 findings into §10's recommended sequence. Everything labeled **must** is required for v1; **should** is strongly desired; **defer** is post-MVP.

**Pre-week-1 — name decision (MUST, days 1-3).**
- §12.6.3 brand name + domain + App Store reservation. Until this resolves, every copy task is on hold.

**Week 1 — foundation.**
- MUST §7.B2 typography bundle (with §12.5.4 license surface).
- MUST §7.B4 BrandVoice strings file (with §12.6.5 failure-state copy).
- MUST §12.7.3 localization stance documented.
- MUST §12.5.7 feature-flag rollback ADR written.
- SHOULD §12.6.1 tone workshop with 5 real drivers.
- SHOULD §7.B3 BrandMark + §12.7.5 AppIcon assets.

**Week 2 — onboarding + foundations.**
- MUST §7.O1, O3, O4 onboarding copy + structure changes.
- MUST §7.O2 Always-Location upgrade — using the *banner pattern from §12.5.5*, not the auto-modal.
- MUST §12.3.x accessibility audit (Dynamic Type, Reduced Motion, VoiceOver) on existing screens.
- SHOULD §12.7.1 notifications copy + service.

**Weeks 3-5 — driving screen redesign.**
- MUST §7.D1 (3-FAB row + hero FAB + AmbientRing per §12.1.1).
- MUST §12.2.1 camera safety gate.
- MUST §12.2.2 consecutive-mark support (replaces §7.D8).
- MUST §12.2.6 NeedsAttentionPill.
- MUST §12.3.6 haptics catalog.
- MUST §12.2.3 tap-forgiveness hit regions.
- MUST §12.5.2 swift-snapshot-testing dependency added.
- MUST §12.5.3 accessibility identifiers added before tests can compile.
- MUST §7.D7 road ribbon (with §12.1.2 retention policy).
- SHOULD §12.4 every edge-case row in the grid has a defined behavior.
- DEFER §7.D5 idle pro-social readout (cosmetic, not blocking).

**Week 6 — stats redesign.**
- MUST §7.S1 impact + community cards.
- MUST §11.A-B `stats_public` view + Edge Function.
- SHOULD §11.E Sentry scrub audit (with §12.5.8 specifics).
- DEFER §7.S2 medallion count-up (cosmetic).

**Week 7 — settings + privacy + segment polish.**
- SHOULD §7.Set1, Set2, §7.PZ1, §7.Cam1, §7.P1.
- SHOULD §12.7.7 error-state matrix pass.

**Week 8 — pre-ship hardening.**
- MUST §12.7.6 App Store screenshots from `MockupRenderTests` at iPhone 6.5".
- MUST §11.D install ping ADR (yes/no decision).
- MUST §11.F transparency page on marketing site.
- SHOULD §12.7.8 TestFlight feedback wiring.

**Ship.** Flag flips. Old `MapScreen` retained in binary for 6 weeks per §12.5.7. After 6 weeks, delete.

**Post-MVP / not in v1:**
- DEFER iPad layout.
- DEFER French localization.
- DEFER §11.D install ping if the ADR comes back "no."
- DEFER advanced gamification ("Top 7%" line in Stats — workshop with users first).

Total: ~8 weeks single-engineer. The original §10 said 4 weeks. Real number, including everything in §12, is closer to twice that.

### 12.9 Things this review doesn't cover

So you know what's still unblessed:

- **iPad and CarPlay.** Out of scope but worth flagging as deferred.
- **Apple Watch companion** (Strava-style mark-pothole-from-wrist). Not designed.
- **Server-side anomaly detection** (drivers whose accelerometer signals look like cycling instead of driving). Not designed.
- **Web dashboard** (Phase 2 per spec). Not designed.
- **Municipal partnership flow** (the eventual paying customer). Not designed.
- **Adversarial users** (someone deliberately reporting fake potholes). Not in this review — handled by community confirmation thresholds in spec.
- **Live A/B testing infrastructure.** §12.5.7 implies remote feature flags but doesn't pick a vendor.
- **Crash-rate ship gate** for the feature flag flip. Want < 0.5% crash-free regression before flipping to 100%? Define explicitly.

That's the honest list. Everything in §12 above is in-scope and addressable. Everything in §12.9 is genuine deferred work.

---

## 13. Resolutions — decisions made on the §12 critical findings

This section captures decisions made after the §12 stress test. Where §12 raised a question, §13 records the answer + rationale + plan delta. The mockup at `ios/RoadSenseNS/Features/Map/MapScreenRedesignPreview.swift` reflects these decisions.

### 13.1 Brand name — locked

**Decision:** Ship as **RoadSense NS**.

**Rationale:** The "NS" suffix is a *feature* for launch — it signals local investment to the frustrated-NS-driver target audience. Renaming is non-trivial but possible later if the product expands beyond the province. Alternates considered (Patch, Patchwork, Paved, Rumble, Plot, Shoulder, Pact) all carry their own trade-offs: distinctiveness wins from "Patch" or "Patchwork," but the current name's *local commitment* outweighs the marginal distinctiveness gain at this stage.

**Plan delta:** Close §12.6.3. BrandVoice strings can be written. Domain registration and App Store listing reservation can proceed.

### 13.2 Progress ring — heartbeat orbit, not fill

**Decision:** Replace the fill-based progress ring with an `AmbientRing` — a thin teal arc (~80°) that rotates slowly around the hero FAB at a constant pace whenever recording is active. No fill semantic, no goal, no looping. Hidden when not recording.

**Rationale:** Three options were on the table (drive odometer, heartbeat, batch confidence). All three required answering "what does 100% mean?" — a question that has no satisfying answer for a passive measurement app. Heartbeat sidesteps the question entirely and reads as "still alive" at a glance, which is the actual intent.

**Plan delta:**
- §7.D7 unchanged.
- §12.1.1 Green updated: `AmbientRing` (no parameters) replaces `ProgressRing(progress:)`. `HeroPotholeFAB` takes `isRecording: Bool` instead of `progress: Double`. The `CountdownRing` from §7.D8 moves into the new `UndoChip` component (§13.3).
- Mockup updated: the active-drive PNG now shows the small orbiting arc instead of a 42 % fill.

### 13.3 Consecutive pothole marks — undo chip, FAB always marks

**Decision:** Eliminate the "celebrate on the FAB" pattern entirely. The hero FAB is *always* a "Mark pothole" button — never goes green, never enters a lockout state. After a successful mark, a separate `UndoChip` floats above the FAB row for 5 seconds with a small countdown ring + the label "Undo last mark." Tap the chip → undo. Tap the FAB during the same window → queue another mark.

**Rationale:** The original celebrate-on-FAB pattern blocked consecutive marks for 5 seconds. On a bumpy stretch with two potholes 30 m apart, that's a real failure mode (one tap, two missed reports). The undo chip pattern lets the FAB stay always-on and gives the undo gesture its own clear affordance.

**Plan delta:**
- §7.D8 rewritten: instead of "celebrate on FAB," the celebration is a quick 800 ms haptic + brief opacity pulse on the FAB body, with the `UndoChip` doing the persistent UI work.
- New TDD: assert that `markPothole()` invoked twice within 1 second produces two `PotholeActionRecord` entries (not undo + re-queue).
- Mockup: just-marked-a-pothole PNG now shows the FAB still amber + the undo chip floating above the FAB cluster.

### 13.4 Camera — soft warning, not hard gate

**Decision:** No hard speed-based block on camera capture. A passenger snapping a pic is a real and supported case — the brief explicitly calls this out. Instead:

- Camera FAB stays always tappable (already designed).
- When the camera capture view opens AND the device is moving > ~25 km/h (a threshold that suggests *driving*, not walking or stop-and-go traffic), display a small banner at the top of the capture view: *"Looks like you might be driving. Pull over to be safe — we'll wait."* The banner is dismissable by tapping it; capture remains available.
- Existing "Slow down or pull over first. Daylight works best." subtitle stays as the always-on default safety nudge.
- Onboarding gets a one-line addition: *"You can grab a photo any time, but please not while you're driving."*

**Rationale:** §12.2.1 over-claimed the App Store rejection risk. Apps that *allow* but *don't encourage* photos while moving are routine in the App Store (Strava, Snapchat, Maps). The actual risk surfaces only when the app's design *encourages* unsafe behavior — which we explicitly do not. Soft warning + onboarding language hits the safety bar without disabling the passenger case.

**Plan delta:**
- §12.2.1 Green updated: replace the speed-gate block with the soft-warning banner.
- New TDD: `PotholeCameraFlowViewTests` — at speed > 25 km/h, the warning banner is rendered; at ≤ 25 km/h, it isn't. Capture button remains hittable in both cases.
- Onboarding copy added to §7.B4 BrandVoice catalog.

### 13.5 NeedsAttentionPill — defined

**Decision:** A single pill that replaces or sits adjacent to the brand chip whenever any one of these is true:

1. `readiness.backgroundCollection == .upgradeRequired` (Always-Location not granted)
2. `readiness.locationPermission == .denied` or `.motionPermission == .denied`
3. `mapLoadError != nil`
4. `isCollectionPausedByUser == true`
5. `uploadStatusSummary.failedPermanentBatchCount > 0` or `potholePhotoStatusSummary.failedPermanentCount > 0`
6. `thermalState == .serious` or `.critical`

Only one pill at a time, picked by the priority order above (1 highest). Pill copy + action per state:

| Trigger | Pill copy | Tap action |
|---|---|---|
| Always-Loc upgrade required | "Set it and forget it →" | Auto-prompt modal (see §13.6) |
| Location denied | "Location is off →" | Open Settings deep-link |
| Motion denied | "Motion is off — accuracy reduced →" | Open Settings deep-link |
| Map load error | "Map didn't load — retry" | Re-try Mapbox tile fetch |
| Paused by user | "Paused — tap to resume" | `model.startPassiveMonitoring()` |
| Failed uploads | "Some uploads need help →" | Push to Settings → Uploads |
| Thermal pause | "Phone too hot — paused" | Dismiss-only (auto-resumes) |

**Position:** below the brand chip, above the map. Same height as a chip (~28 pt). Amber background (signal color) when actionable, red (danger) only when something has actually failed.

**Plan delta:** §12.2.6 closed. New view `NeedsAttentionPill.swift` + `AppModel.attentionState: AttentionState?` computed property. Tests cover priority order + tap routing.

### 13.6 Always-Location upgrade — visible banner pattern

**Decision:** Replace the §7.O2 "auto-present full-screen modal" with a more visible non-blocking pattern:

- After the user's first successful drive, on the next foreground, the `NeedsAttentionPill` (§13.5) appears with copy *"Set it and forget it →"* — this is the **most prominent attention pill state**, with a subtle pulse animation (Reduced-Motion-respecting), amber signal color, persistent across navigation.
- The pill itself is the visible nudge. It does not auto-open a modal — that's HIG-incompatible.
- Tapping the pill opens the full-screen Always-Location explainer + system permission prompt. This is the user-initiated step that satisfies HIG.
- If the user dismisses (X button on the pill), it hides for 7 days, then reappears.
- After 3 dismissals total, the pill stops auto-appearing — but the pathway through Settings remains.

**Rationale:** The brief's exact ask was *"obvious so they do it, while staying compliant."* The original §7.O2 went too far toward "obvious" by auto-presenting a modal — a known HIG violation pattern. The pill pattern keeps high visibility (it's the same elevated chrome the user already sees, in its loudest state) without the auto-modal. The pulse + amber color + actionable copy do the "obvious" work.

**Plan delta:**
- §7.O2 rewritten around the pill pattern.
- §12.5.5 closed.
- New TDD: `AppModelTests.testAttentionPillSurfacesAfterFirstDrive` — given `acceptedReadingCount = 1` and `backgroundCollection = .upgradeRequired` and `pillDismissedCount = 0`, assert pill priority resolves to `.alwaysLocationUpgrade`.

### 13.7 Haptics — full catalog adopted

**Decision:** Implement the §12.3.6 catalog as proposed.

| Event | Haptic |
|---|---|
| Mark pothole tap (registered) | `.impact(.medium)` immediately on tap, then `.notification(.success)` ~150 ms later when queued |
| Mark rejected (privacy / GPS / bounds) | `.notification(.warning)` |
| Undo tap | `.impact(.light)` |
| Camera capture button press | `.impact(.soft)` |
| Camera capture taken | `.impact(.medium)` |
| NeedsAttentionPill resolves to actionable state (transition) | none — would be intrusive on background updates |
| App backgrounded mid-collection / drive ends | none |

All haptics route through a `HapticsServicing` protocol (injectable, mock-replaceable) so tests assert the right haptic for the right event. iOS automatically respects system-wide haptic preferences; manual checks add extra `UIAccessibility.isHapticsEnabled` guard.

**Plan delta:** §12.3.6 closed. New file: `App/HapticsService.swift` + protocol + `MockHaptics` for tests.

### 13.8 Feature flag rollback — compile-time, with discipline

**Decision:** For v1, the redesign ships behind a *compile-time* feature flag (`AppConfig.drivingRedesignEnabled: Bool`), defaulted to `true`, defined in `AppConfig.swift`. Rollback path = ship a binary with the flag flipped to `false`. Old `MapScreen` lives in the codebase for one full release cycle (~6 weeks) after the redesign ships, then gets deleted.

Migrate to a runtime remote-config flag (Supabase config table or similar) only if real-world experience proves we need faster rollback than "ship a binary."

**Rationale:** Runtime remote-config flags are the right answer at scale, but for a solo-engineer MVP the operational overhead (auth, caching, fallback when remote is unreachable, A/B logic) outweighs the speed-of-rollback gain. Ship-a-binary takes 24–48 hours through TestFlight + expedited App Store review, which is acceptable risk for an MVP whose users number in the hundreds during the rollback window.

**Schema discipline (regardless of flag mechanism):**
- All schema changes during the redesign are *additive only* (new optional columns, new tables) — never required-field renames or column drops in shipping migrations.
- Both the old and new code paths must read/write the same data shape.
- Any ambiguity in schema → ADR before the schema migration ships.

**Plan delta:** §12.5.7 closed. ADR `docs/adr/0001-driving-redesign-rollback.md` to be written before §7.D1 starts. ADR captures: flag location, default, rollback procedure, deletion timeline, schema-additive rule, escalation criteria for moving to runtime flags.

### 13.9 Systemic gaps — prioritization & decisions

The §12.7 systemic gap list, with concrete in-MVP / deferred / TODO calls.

| Gap | Decision |
|---|---|
| Accessibility (VoiceOver, Dynamic Type, Reduced Motion) | **MVP-blocking.** Can't ship without. §12.3.1–4 land in Week 3 alongside the driving redesign. |
| Edge-case handling (§12.4 grid) | **MVP partial.** All 18 rows must have a defined behavior, but several can be "no UI, log only, fix in v1.1." Define in §13.10. |
| `swift-snapshot-testing` dependency | **Add now.** Pointfree's package, ~150 KB, well-maintained. Blocks §7 reds. |
| Accessibility identifiers on FABs | **Land with §7.D1.** Identifiers added in the same PR as the redesign so reds can compile. |
| Font licensing surface | **MVP.** Settings → About → Licenses screen. Lands with §7.B2. |
| Tone workshop with real drivers | **Pre-ship.** 5-driver TestFlight cohort. Half-day exercise. Slot in Week 7. |
| FAB label inconsistency | **Resolved here:** Photo / Pothole / Stats — all single nouns. "Pothole" is short for "Mark pothole" (the verb is implicit per the brief's "stupid simple"). The mockup labels stand. Re-evaluate after the tone workshop. |
| Failure-state copy | **Land with §7.B4 BrandVoice file.** Add a `BrandVoice.Failure.*` namespace covering all rejection reasons. |
| Notifications design | **MVP.** Local notifications already in spec; copy + delivery service land in Week 7. |
| Dark mode visual check | **Pre-ship.** Render light + dark variants of every mockup; WCAG AA contrast pass. Land with §7.S1 or sooner. |
| Localization stance | **English only for v1.** Strings flow through `Localizable.strings` from day one so a future French pass is a translation file. ADR captures the decision. |
| iPad layout | **Deferred.** `Info.plist` `UIDeviceFamily = [1]` (iPhone only). Explicit rejection in App Store listing. |
| App icon vs. brand mark | **MVP-blocking.** App Store submission needs a 1024×1024 icon. Lands with §7.B3. |
| App Store screenshots | **MVP-blocking.** Use the `MockupRenderTests` pipeline at iPhone 6.5" (1284×2778) — pipeline already exists, just add the device size. |
| Error-state matrix per surface | **Pre-ship.** One-page design pass in Week 7. Output: a section per major surface in the design audit, listing loading / empty / network-failure / permission-denied / offline behaviors. |
| TestFlight feedback wiring | **Add to MVP.** Settings → "Send feedback" row using TestFlight's API for beta builds, `MFMailComposeViewController` (or just a mailto link) for release. |
| Onboarding skip for returning users | **Pre-ship.** Verify Keychain-survives-uninstall behavior; add a regression test. |

### 13.10 Edge-case behaviors — defined

Filling out the §12.4 grid with concrete handling. "v1" = ships in the MVP. "v1.1" = post-launch polish.

| Scenario | Behavior |
|---|---|
| Map tile request fails | NeedsAttentionPill: "Map didn't load — retry." Tap retries. (v1) |
| GPS denied mid-drive | Collection stops. Pill: "GPS turned off — tap to fix." (v1) |
| GPS reduced accuracy | Pill: "Location accuracy is low. Open Settings to enable Precise Location." (v1) |
| Motion permission revoked | Pill: "Running without motion — accuracy reduced." Falls back to GPS-only per spec. (v1) |
| App force-quit | Local notification after 48 h: *"RoadSense isn't collecting — tap to resume."* (v1) |
| Low Power Mode | Reduce sampling per spec. No UI surface (silent). (v1) |
| Thermal `.serious` / `.critical` | Pause collection. Pill: "Phone too hot — paused." Auto-resume on cooldown. (v1) |
| Offline (no cellular, no Wi-Fi) | Pill: "Offline — uploads queued." Hides when first upload succeeds. (v1) |
| User pauses collection | Pill: "Paused — tap to resume." (v1) |
| Upload failed permanently | Pill: "Some uploads need help → Settings." (v1) |
| Pothole marked inside privacy zone | Existing rejection feedback. Hero FAB shows desaturated visual hint (§12.2.5). (v1) |
| Pothole marked outside NS bounds | Existing rejection feedback. (v1) |
| Two marks within 3 s within 10 m | Server-side dedup at ≤ 15 m within 10 minutes per same device. Both client-side records persist; server reconciles. (v1) |
| Screen rotates to landscape | `Info.plist` portrait-only lock. (v1) |
| iPad | `UIDeviceFamily = [1]`, no iPad build. (deferred) |
| Permission revoked via Settings + return | Existing `OnboardingFlowView.permissionHelp` path. (v1) |
| Pedestrian marks pothole (no active drive) | Allowed if GPS fix is fresh (< 30 s). Otherwise shows existing "Need a fresh GPS fix" message. (v1) |
| Camera session in use elsewhere | Detect `AVCaptureSession.runtimeErrorNotification`, show recovery UI: *"Camera in use by another app. Try again."* (v1.1 — best-effort logging in v1.) |
| App updated mid-session | Background modes survive app update on iOS. New flag-on or flag-off path takes effect at next launch. (v1) |

### 13.11 Plan delta summary

§7's recommended sequence → §12.8 revised sequence → §13 confirmed sequence (where decisions land work in specific weeks):

- **Week 0 (days 1–3):** Brand name + domain (closed: RoadSense NS). App Store listing reservation. Done.
- **Week 1:** §7.B2 typography + license surface · §7.B4 BrandVoice (with failure copy) · localization-stance ADR · `swift-snapshot-testing` dep · feature-flag rollback ADR (§13.8) · §7.B3 BrandMark + §12.7.5 AppIcon assets.
- **Week 2:** §7.O1, O3, O4 onboarding · NeedsAttentionPill (§13.5) · Always-Loc pill state (§13.6) · accessibility audit on existing screens (§12.3) · `HapticsService` skeleton (§13.7).
- **Weeks 3–5:** §7.D1 driving redesign · `AmbientRing` + `UndoChip` (§13.2, §13.3) · camera soft warning (§13.4) · §12.2.x ergonomics · accessibility-id work · road ribbon §7.D7 + retention policy (§12.1.2) · edge-case behaviors §13.10.
- **Week 6:** §7.S1 stats redesign · §11.A–B `stats_public` view + Edge Function · Sentry scrub (§11.E + §12.5.8).
- **Week 7:** §7.Set1, Set2, §7.PZ1, §7.Cam1, §7.P1 polish · §12.7.7 error-state matrix · §12.7.1 notifications · tone workshop · light-mode visual pass.
- **Week 8:** App Store screenshots from `MockupRenderTests` at iPhone 6.5" · §11.D install-ping ADR · §11.F transparency page · TestFlight feedback wiring.
- **Ship.** Six weeks of old-`MapScreen`-retention. Then delete.

Total: ~8 calendar weeks, single engineer.

This is the working plan. Everything in §12.0's seven-must-resolve list now has a §13 entry. Mockup file reflects §13.2 and §13.3. Any further changes to the plan should land here as new §13.x entries so the decision log stays in one place.

---

## 14. Implementation status

Live tracking of the §13.11 plan as work lands. Each entry: state · what shipped · where to look · tests.

### 14.1 Phase 1 — Foundations (complete · 2026-04-25)

**ADR 0001 — Driving redesign rollback** · `docs/adr/0001-driving-redesign-rollback.md`. Compile-time `AppConfig.drivingRedesignEnabled` flag, ship-a-binary rollback, schema-additive discipline, 6-week deletion timeline, escalation criteria for moving to runtime flags.

**ADR 0002 — Localization stance** · `docs/adr/0002-localization-stance.md`. v1 ships English-only with all strings flowing through `BrandVoice.swift` so a future French pass is a translation file, not a code change.

**Snapshot-testing dependency** · `ios/Package.swift`. `pointfreeco/swift-snapshot-testing@1.17+` added to `RoadSenseNSBootstrapTests`. The Xcode app target `RoadSenseNSTests` will need the same package added via Xcode UI (`File > Add Package Dependencies`) when the first UI-tier snapshot test lands; documented in the Package.swift comment.

**`BrandVoice.swift`** · `ios/RoadSenseNS/App/BrandVoice.swift`. Centralized strings catalog with namespaced sections: `Onboarding`, `Driving`, `Stats`, `Settings`, `Camera`, `Attention` (NeedsAttentionPill states from §13.5), `Failures`, `Notifications`. Every string uses `NSLocalizedString` with explicit keys and contextual comments. Migration to `Localizable.strings` is mechanical when a translation pass starts. Onboarding is fully migrated (§7.O1, O3, O4); other surfaces will migrate as their redesign work lands.

**`BrandMark.swift`** · `ios/RoadSenseNS/Features/DesignSystem/BrandMark.swift`. Production-ready `Canvas`-drawn brand mark, two style modes (`.solid` / `.onTinted`), accessibility label included. Replaced `Image(systemName: "road.lanes")` in:
- `OnboardingFlowView.brandMark` (28pt header mark).
- `StatsView.medallion` (32pt inside the existing tinted halo).

The same component will drive `AppIcon.appiconset` rendering in Phase 2; preview file already covers four sizes including small (28) and App Store (128 in preview, 1024 at render time).

**`HapticsService.swift`** · `ios/RoadSenseNS/App/HapticsService.swift`. `HapticsServicing` protocol, `UIKitHaptics` real implementation backed by `UIImpactFeedbackGenerator` + `UINotificationFeedbackGenerator`, `NoOpHaptics` for previews and tests. iOS automatically respects system haptic preferences; no manual gate. Wired into:
- `AppContainer.haptics: HapticsServicing` (required field).
- `AppModel.markPothole` — `.notification(.success)` on `.queued`, `.notification(.warning)` on `.unavailableLocation` and `.insidePrivacyZone` and queue errors. Other catalog entries (camera, undo, photo capture) will land alongside the driving-screen redesign UI in Phase 3.

**Onboarding redesign (§7.O1, O3, O4)** · `ios/RoadSenseNS/Features/Onboarding/OnboardingFlowView.swift`.
- `missionHook` — civic-pride one-liner above the header (§7.O4).
- `readySubtitle` — concatenates `readySubtitleDefault` with `alwaysLocationContract` so the Always-Location promise is set during onboarding (§7.O1).
- "Optional: manage privacy zones" CTA + accompanying sheet machinery deleted (§7.O3); privacy zones remain reachable from Settings.
- Permission tip copy, button labels, eyebrow strings, help-state copy all routed through `BrandVoice.Onboarding.*`.

### 14.2 Test status

- **Xcode** `RoadSenseNSTests`: 56 tests pass, 1 skipped (the env-gated mockup renderer), 0 failures.
- **SPM** `RoadSenseNSBootstrapTests`: 85 tests pass.

No regressions introduced by Phase 1. Baseline established before changes; verified after each step.

### 14.3 What hasn't shipped yet (deferred to Phase 2+)

- **Custom fonts (§7.B2).** Fraunces + IBM Plex Mono need actual TTF assets. Infrastructure (`DesignTokens.TypeFace.display(...)` etc.) will be added when the asset bundles arrive.
- **App icon (§7.B3 + §12.7.5).** Render `BrandMark` to `AppIcon.appiconset` at all required sizes via a build-time script. Pending design refinement of the chevron-stitch concept.
- **License surface (§12.5.4).** Settings → About → Licenses screen for SIL OFL acknowledgements. Lands when fonts ship.
- **NeedsAttentionPill (§13.5).** Component + priority logic. Not started; lands as part of the driving redesign in Phase 3.
- **Always-Loc upgrade pill state (§13.6).** Depends on NeedsAttentionPill.
- **Driving-screen redesign (§7.D1).** The multi-week core. Phase 3.
- **Camera soft warning (§13.4).** Lands with the camera flow update in Phase 3.
- **Stats redesign (§7.S1).** Phase 4.
- **Analytics (§11).** `stats_public` view, install-ping decision, transparency page. Phase 5.
- **Notifications (§12.7.1).** Local notifications with `BrandVoice.Notifications.*` copy. Phase 4 polish.
- **Tone workshop (§12.6.1).** Pre-ship, post-Phase-3.
- **App Store screenshots (§12.7.6).** Once Phase 3 mockups become real screens, render at iPhone 6.5".

### 14.4 Foundation contract

Phase 1 shipped without breaking any existing test. Subsequent phases must do the same: any feature behind the redesign flag, any new dependency added to test scaffolding, any string change must keep all baseline tests green. Schema changes follow the additive rule from ADR 0001.

### 14.5 Phase 2 — Visual scaffolding (complete · 2026-04-25)

**`NeedsAttentionPill` + `AttentionState`** · `ios/RoadSenseNS/Features/Map/AttentionState.swift`, `NeedsAttentionPill.swift`. Eight-state enum with priority order, severity ramp, accessibility hints. Pill respects Reduced Motion (no pulse), uses `BrandVoice.Attention.*` strings.

**App icon render pipeline** · `MockupRenderTests.testRenderAppIcon`. Renders `BrandMark` to a 1024×1024 PNG with no transparency, writing directly into `Resources/Assets.xcassets/AppIcon.appiconset/`. iOS 15+/Xcode 15+ accepts a single universal icon — the OS scales for every other slot. Run with `TEST_RUNNER_MOCKUP_RENDER=1`.

**License surface** · `ios/RoadSenseNS/Features/Settings/LicensesView.swift`. Reachable from Settings → About → "Open-source licenses." Currently lists Sentry Cocoa (MIT). Structured to receive Fraunces + IBM Plex Mono entries when the font assets ship.

### 14.6 Phase 3 — Driving redesign (complete · 2026-04-25)

The core of the audit, behind a feature flag.

**Production components** · `ios/RoadSenseNS/Features/Map/DrivingScreenComponents.swift`. Promoted from the preview file:
- `BrandChip` — top-left brand pill with `PulsingDot` (Reduced-Motion-respecting) when recording.
- `ChromeButton` — top-right settings gear, with §12.2.3 tap-forgiveness.
- `HeroPotholeFAB` — center 96-pt FAB with `AmbientRing` (Reduced-Motion-respecting heartbeat orbit, no fill semantic per §13.2). Always reads "Mark pothole" — never enters lockout per §13.3.
- `AmbientRing` — recording heartbeat, ~80° teal arc rotating once every 4s.
- `CountdownRing` — 5-second receding arc inside `UndoChip`.
- `UndoChip` — floating pill that surfaces during the undo window and is tappable independently of the FAB. The hero FAB stays available for consecutive marks per §13.3.
- `SecondaryFAB` — 56-pt buttons used for Photo + Stats.
- `IdleStatWell` — pro-social headline ("47 km of Nova Scotia mapped this month"), driven by `kmThisMonth` + community fields. Hides the community line when both values are 0.
- `FirstRunIllustration` — empty-state cold start.

All components have:
- `accessibilityElement(children: .ignore)` + explicit accessibility labels and hints.
- Tap-forgiveness via `.contentShape(Circle().inset(by: -N))` on every button.
- Dynamic Type capped at `.accessibility1` to balance accessibility with layout safety.

**Driving screen — production view** · `ios/RoadSenseNS/Features/Map/MapScreenRedesign.swift`. Wired to live `AppModel`:
- 3-FAB row (Photo | Pothole | Stats) with `accessibilitySortPriority` that announces Pothole first via VoiceOver (§12.3.1).
- `BrandChip` with `isRecording: model.isActivelyCollecting`.
- `NeedsAttentionPill` with priority computation over: `alwaysLocationUpgrade`, `locationDenied`, `motionDenied`, `mapLoadFailed`, `paused`, `failedUploads`. (Thermal + offline pills are wired in `AttentionState` but not yet computed — easy v1.1 add.)
- Pothole tap → `model.markPothole()` → success/warning haptic via `HapticsService` → UndoChip surfaces for 5 s.
- Undo tap → `model.undoPotholeReport(id:)`.
- Camera tap → opens `PotholeCameraFlowView` with `isLikelyMoving: model.currentSpeedKmh > 25` for the soft safety banner per §13.4.
- Stats tap → presents `StatsView` (existing).
- Settings tap → presents `SettingsView` (existing).
- Map → `RoadQualityMapView` with `pendingDriveCoordinates` and `pendingPotholeCoordinates` — same wiring as legacy `MapScreen`.
- Segment detail → `SegmentDetailSheet` (existing) with deferred follow-up prompt.
- Idle state → `IdleStatWell` (when `userStatsSummary.totalKmRecorded ≥ 0.05`) or `FirstRunIllustration`.

**Feature flag + rollback** · `ios/RoadSenseNS/App/FeatureFlags.swift`. `drivingRedesignEnabled = true`. `ContentView` branches on the flag — flag-on mounts `MapScreenRedesign`, flag-off mounts the legacy `MapScreen`. Per ADR 0001, both code paths ship for ~6 weeks; rollback is a binary release with the flag flipped.

**Camera safety warning** · `PotholeCameraFlowView` gains `isLikelyMoving: Bool` parameter. When true, a dismissable amber banner overlays the live preview with `BrandVoice.Camera.safetyWarningWhileMoving`. Capture stays available — soft nudge per §13.4. Onboarding gains `BrandVoice.Onboarding.cameraSafetyNote` string (catalog entry; placement in onboarding flow can be refined post-tone-workshop).

**App Store screenshot pipeline** · `MockupRenderTests.testRenderMockups` now renders each scenario at two sizes:
- Standard iPhone 17 Pro (393×852 logical → 1179×2556 px @3×).
- iPhone 6.7" App Store size (430×932 logical → 1290×2796 px @3×).

Output: 8 PNGs in `docs/reviews/assets/` (4 `mockup-*.png` + 4 `appstore-*.png`).

### 14.7 Test status (post-Phase-3)

- **Xcode** `RoadSenseNSTests`: 57 tests pass, 2 skipped (env-gated render tests), 0 failures. (+1 vs. Phase 1 baseline — `testRenderAppIcon`.)
- **SPM** `RoadSenseNSBootstrapTests`: 85 tests pass.
- **Build:** Local Debug for iOS Simulator builds clean. No warnings in app code (one unrelated AppIntents.framework warning from Apple's metadata processor).

### 14.8 What's still deferred to Phase 4 / 5

- **Custom fonts** — needs Fraunces + IBM Plex Mono TTF assets. Infrastructure ready; just bundle the files.
- **Stats redesign (§7.S1)** — impact + community cards. Requires the `stats_public` view from §11.A as the data source.
- **Notifications (§12.7.1)** — `BrandVoice.Notifications.*` copy is in catalog; the local-notification service + scheduling is not built.
- **Settings polish (§7.Set1, Set2)** — destructive-action demotion + privacy-zones nav push.
- **Privacy zones polish (§7.PZ1)** — human-reference radius hint.
- **Camera review subtitle (§7.Cam1)** — already in `BrandVoice.Camera.reviewSubtitle`; need to wire it into the review state.
- **Tone workshop (§12.6.1)** — pre-ship copy review with 5 real drivers.
- **Analytics (§11)** — `stats_public` view, install-ping ADR, transparency page.
- **Thermal + offline attention pills** — defined in `AttentionState`; need to wire `model.thermalState` / network reachability into `MapScreenRedesign.attentionState`.
- **Full BrandVoice migration of legacy MapScreen and StatsView/SettingsView** — partial (BrandVoice references in place where wired); MapScreen and the existing StatsView surfaces still have inline literals. Migration is mechanical when the Stats redesign lands.

### 14.9 Visual asset inventory

After Phase 3 the assets directory holds:

```
docs/reviews/assets/
├── appstore-active-drive.png            — App Store 6.7" hero render
├── appstore-first-run.png
├── appstore-idle-between-drives.png
├── appstore-just-marked-a-pothole.png
├── mockup-active-drive.png              — iPhone 17 Pro standard
├── mockup-first-run.png
├── mockup-idle-between-drives.png
└── mockup-just-marked-a-pothole.png
```

Plus the App Icon at `ios/RoadSenseNS/Resources/Assets.xcassets/AppIcon.appiconset/AppIcon-1024.png` (1024×1024, opaque, ready for App Store submission).

### 14.10 Post-Phase-3 corrections (2026-04-25)

Three follow-ups landed after the first device pass. None are in §13.11 — they came from real-device feedback that the redesign's first pass missed.

**Idle stat well dimensions.** The 56pt monospace headline in a 320pt-wide scrim was visually heavy enough to obscure map coverage. Tightened to 38pt / 240pt-wide with `Palette.deep` opacity dropped from 0.66 → 0.42. The well now reads as a subtle headline rather than a near-modal layer.

**Rejection banner ("Need a fresh GPS fix" et al.).** First version was a flat `Color.black.opacity(0.78)` rounded rect with the failure tint as a bare SF Symbol. Restyled to match the rest of the redesign's surface language: tinted icon disc (32pt) with the failure colour at 0.22 fill / 0.5 stroke, ultra-thin material under a `Palette.deep.opacity(0.78)` scrim, `.lg` corner radius. Banner copy is unchanged.

**Manual-mark stat preservation — soft-delete on upload (§ARCH).** `PotholeActionRecord` gained a `uploadedAt: Date?` field; `PotholeActionStore.applyUploadSuccess` now sets `uploadedAt = now` instead of `context.delete(record)`. All "is this work pending" queries (`pendingCount`, `statusSummary.pendingCount`, `pendingManualReportCoordinates`, `prepareNextAction`, `findPendingFollowUpDuplicate`) gain an `uploadedAt == nil` filter so uploaded rows don't show as outstanding work. `statusSummary.lastSuccessfulUploadAt` now derives from `uploadedAt` directly — semantically cleaner than the old "max `lastAttemptAt` of non-failed records" heuristic.

This closes a stat-loss bug discovered post-merge: before commit b2e3913 (2026-04-25 08:59) the `stats.potholesReported += 1` path didn't fire for manual marks at all. Once a mark uploaded successfully, the row was deleted and `reconcileManualReportStats` had nothing left to recover from. The soft-delete keeps the audit trail intact so reconcile remains the safety floor for any future stat-increment regression.

This does not recover historical marks that were already deleted before the fix landed — those are gone from the device. A server-side `/stats/me` endpoint is the only path to recover them and is deferred to Phase 5 analytics.

Schema change is additive per ADR 0001 (new optional field with a default of nil; existing rows migrate cleanly with `uploadedAt = nil`). Tests: `testApplyUploadSuccessSoftDeletesRecordSoReconcilePreservesCount` covers the new behavior end-to-end (queue → promote → upload-success → reset stat → reconcile recovers count from the soft-deleted row). Existing `testStatusSummaryCountsPendingAndFailedPermanentActions` extended with an uploaded record to assert that uploaded rows are excluded from pending/failed counts and feed `lastSuccessfulUploadAt` correctly.
