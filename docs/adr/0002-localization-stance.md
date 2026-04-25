# ADR 0002 — Localization stance for v1

**Status:** Accepted
**Date:** 2026-04-25
**Driver:** §13.9 of `docs/reviews/2026-04-24-design-audit.md`

## Context

Nova Scotia is officially bilingual in part — Acadian regions speak French as a first language. The product targets every NS driver, which arguably includes French-speaking drivers. Two paths exist for v1:

1. **Ship English-only.** Smaller scope, faster to v1.
2. **Ship English + French (Acadian / Canadian French).** Larger scope, ~2–3 weeks of additional work to translate, review with native speakers, and QA bilingual flows.

A third path — ship English-only but architect for easy translation later — is the realistic middle ground.

## Decision

**Ship English-only for v1.** All user-facing strings flow through `BrandVoice.swift` (which itself reads from `Localizable.strings`), so a future French pass is a translation file, not a code change.

## Consequences

### Positive
- v1 ships ~2–3 weeks earlier.
- We can workshop tone with English-speaking NS drivers (§12.6.1) without splitting effort across languages.
- A "we ship French in v1.1" promise on the marketing page reads as a commitment, not a hedge.

### Negative
- Acadian and other French-speaking NS drivers cannot use the app in their first language at launch. This is a real exclusion.
- Risks the perception of the app as "Halifax-centric" rather than provincial.

### Mitigations
- All strings live in `BrandVoice.swift` from day one (§7.B4) with no inline literals.
- A `Localizable.strings` table in `en.lproj` exists from v1, ready to be paired with `fr.lproj` in v1.1.
- Marketing copy on the launch page commits to French in v1.1 with a target date.
- Beta testers from Acadian regions are explicitly recruited; their feedback shapes the v1.1 French translation priorities.

## v1.1 plan

- Translate all `Localizable.strings` keys to Acadian French.
- Native-speaker review of the full translation pass.
- Locale-aware date/number formatting (already handled by `Formatter.localized` if used consistently).
- App Store listing in French.
- Push notifications respect device locale.

## Implementation checklist

- [ ] Create `ios/RoadSenseNS/App/BrandVoice.swift` with all user-facing strings as `String` constants, each backed by an `NSLocalizedString` lookup.
- [ ] Create `ios/RoadSenseNS/Resources/en.lproj/Localizable.strings` with the canonical English copy.
- [ ] Audit existing UI files to remove inline string literals; route through `BrandVoice`.
- [ ] Add a unit test that ensures every key in `Localizable.strings` is referenced by `BrandVoice` and vice-versa (no orphans, no missing keys).

## Out-of-scope

- Right-to-left language support (Arabic, Hebrew). Not in v1 or v1.1; revisit if user research shows demand.
- Indigenous language support (Mi'kmaq, etc.). A future consideration that requires partnership with Indigenous communities — not something to retrofit unilaterally.
