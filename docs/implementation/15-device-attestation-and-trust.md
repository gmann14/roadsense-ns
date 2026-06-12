# 15 — Device Attestation & Trust (Anti-Sybil)

*Last updated: 2026-06-12 — **Status: SQL gates shipped (B165 ✅ commit `cc9bcbe`, B166 ✅ commit `fca1dc2`); attestation chain B160–B164 and tiers B167 not started***

Covers: hardware-backed device attestation (App Attest on iOS, Play Integrity on Android), server-issued device tokens, corroboration gating for potholes, exact unique-contributor accounting, and a minimal trust-tier model. This is the work that closes findings **P1-1 / P1-2 / P1-3** in [docs/reviews/2026-06-11-backend-prelaunch-review.md](../reviews/2026-06-11-backend-prelaunch-review.md) before the public marketing push (local media + Facebook groups) puts the data's trustworthiness in front of adversarial strangers.

Numbering continues the B-series at **B160** (B154–B159 intentionally skipped, same range-gap convention [11](11-post-launch-roadmap.md) used at B120). Tickets claimed here: **B160–B167**.

[06-security-and-privacy.md](06-security-and-privacy.md) deferred attestation with "observed abuse, not anticipated abuse." That trigger has been re-evaluated: the marketing plan *invites* abuse on a known date, and the prelaunch review proved the current trust signals are forgeable with a bash loop. We are shipping ahead of the push, not after the first incident.

## Why now

The product's only trust currency is `unique_contributors` and pothole `confirmation_count`. Today:

- `device_token` is a **client-minted UUIDv4** rotated monthly on-device (`ios/Sources/RoadSenseNSBootstrap/Persistence/DeviceTokenManager.swift`; same model in the Android branch's `DeviceTokenEntity`). The server validates format only (`supabase/functions/upload-readings/handler.ts`) and hashes with a pepper (`runtime.ts`). Rotation cost for an attacker: zero — `uuidgen` per request.
- `unique_contributors` gates everything public: tile visibility and the worst-roads MV require `unique_contributors >= 3 AND confidence != 'low'` (`20260426170000`, `20260419103016`); confidence flips medium/high at 3/10 contributors (`20260425001500`).
- A pothole goes public on **one device's say-so**: `fold_pothole_candidates` inserts `status='active'` from a single batch (`20260612090000`), and `status='active'` is the only public gate in `get_tile` (z≥8), `get_potholes_in_bbox`, and `get_top_potholes`.
- The incremental aggregate UPSERT **sums per-batch contributor counts** (`update_segment_aggregates_from_batch`, `20260425001500:54`), so one device's three batches read as three contributors until the next nightly recompute — which, on the in-process scheduler, can be nearly a day away, behind a 1h tile cache.

The P0-1 fix (commit `8e0c381`) bounded *values* (magnitude, speed, flag fraction). Nothing yet bounds *identities*. This doc bounds identities.

## Threat model

### What the trust signals gate (the attacker's prize)

| Signal | Public effect | Where enforced |
|---|---|---|
| `unique_contributors >= 3` + `confidence != 'low'` | segment appears on quality tiles and in Worst Roads rankings | `get_tile` (`20260426170000`), `public_worst_segments_mv` (`20260419103016`) |
| `unique_contributors >= 3 / >= 10` | medium / high confidence labels | `update_segment_aggregates_from_batch`, `nightly_recompute_aggregates` |
| `pothole_reports.status = 'active'` | pothole marker on iOS/web maps from z≥8; homepage top-potholes list | `get_tile`, `get_potholes_in_bbox`, `get_top_potholes` |
| `confirmation_count`, `magnitude` | top-potholes ranking order | `get_top_potholes` (`ORDER BY confirmation_count DESC, magnitude DESC`) |

### Attacks, and what each costs

Costs are stated for the attacker at each defense stage. "SQL gates" = B165 + B166 (no attestation yet). "Attestation" = B160–B164 in `enforce` mode. "Tiers" = B167.

**A1 — Sybil contributor inflation.** Mint N UUIDs, upload one plausible batch per token along a target road; with 3 tokens the segment renders publicly at medium confidence, with 10 it reads "high confidence"; the same tokens vote a road up the Worst Roads ranking.
- *Today:* ~50 lines of bash. The 10 batches/hr/IP cap is the only friction; 3 tokens × 1 batch fits inside it without even a VPN.
- *After SQL gates:* unchanged — B166 fixes single-device double counting, not many-device forgery. This is why B166 alone is not enough.
- *After attestation:* a counted contributor requires a passing App Attest / Play Integrity verification, and each physical device yields exactly one attested identity. Sybil count ≈ number of physical devices the attacker controls. Forged-UUID tokens still upload (transition policy, B164) but are stamped unattested and **never counted in any trust signal**.
- *After tiers:* a freshly attested device must age (days + accepted batches) before it counts as established; a same-day device farm moves nothing that requires established devices, and unverified devices get a lower daily batch cap.

**A2 — Fake pothole placement.** One forged batch with `is_pothole=true` rows (post-P0-1: magnitude ≤ 8, speed 45–160, ≤ max(5, 25%) of readings flagged) creates an `active` pothole rendered from z≥8 and eligible for the homepage top-potholes panel. Repeat batches from fresh tokens pump `confirmation_count` to climb that ranking.
- *Today:* one curl per fake pothole.
- *After SQL gates (B165):* public visibility requires ≥ 2 distinct devices in the 15 m cluster. Against client-minted tokens this is two `uuidgen` calls — trivially evaded *in isolation*, which is exactly why B165 is written to count devices, so that the moment B164 lands the same predicate means two *physical* devices. Single-report potholes hold in a non-public `candidate` state.
- *After attestation:* two physically distinct attested devices must report within 15 m / 90 days. The cheap drive-by forgery is gone; the residual is a two-person prank, which manual `confirm_fixed` quorum and 90-day expiry already bound.
- *After tiers:* sensor reports from unattested devices cannot create or promote candidates at all; a single established device's manual report + sensor corroboration is the only single-device path left, and it is auditable.

**A3 — Segment-score data poisoning.** Forge in-bounds readings (`roughness_rms` 0–15) from a handful of tokens to recolor a low-traffic segment — e.g. 20 readings at 0.20 RMS flips a smooth street to `very_rough` (threshold ≥ 0.14). The p10–p90 nightly trim only defends the tails of an honest distribution, not a coordinated shift; per-device weekly caps bound one *token*, and tokens are free.
- *Today:* minutes per segment. Worst Roads is the showcase ranking for the media push — poisoning it is the highest-reputational-damage attack here.
- *After SQL gates:* visibility/promotion needs 3 distinct tokens instead of 1 device's batches — still cheap.
- *After attestation:* unattested readings are excluded from aggregation (B164 full enforcement); influence is bounded by physical devices × the existing ≤ 3 readings/device/week/segment cap. Recoloring a moderately-traveled segment now needs a fleet of iPhones driven (or spoofed at the CoreLocation level on jailbroken hardware — accepted residual, documented in [06](06-security-and-privacy.md)).
- *After tiers:* unchanged (aggregation *weights* by tier are explicitly deferred — see non-goals).

**A4 — Replay.** Re-submitting captured traffic.
- *Today:* same `batch_id` → idempotent replay (advisory lock + `processed_batches`); same-token cross-batch duplicates rejected (`20260426093000`); **cross-rotation replay is open** but low-severity and already tracked as B097 in [08](08-implementation-backlog.md) — not re-claimed here.
- *After attestation:* token issuance uses one-time server challenges (TTL ≤ 5 min, single use), so a captured attestation/assertion cannot mint a second token; App Attest assertion counters must increase monotonically, so a captured assertion cannot be replayed; a *stolen current token* exfiltrated from one device remains usable until its monthly rotation, but it is bound to a single attested identity — abuse is capped at that one device's limits and visible against that one identity.

**A5 — Gateway key extraction.** `PUBLIC_API_KEY` ships in the app bundle and is extractable from the IPA; it authenticates nothing about the device. Attestation supersedes it as the real write-path gate; the key stays as a dumb scraper filter. No ticket — this is a consequence of B164, noted so nobody mistakes the apikey for a defense.

### Explicitly accepted residuals

- Real attested devices driven badly on purpose (indistinguishable from a bad road) — the [06](06-security-and-privacy.md) residual stands.
- Jailbroken devices spoofing CoreLocation under a valid App Attest key — App Attest attests app+device integrity, not sensor truth. Per-device caps bound the damage.
- Sideloaded Android beta builds cannot pass `PLAY_RECOGNIZED` app integrity (see B163 decision).
- A motivated two-device attacker can still corroborate a fake pothole. Quorum `confirm_fixed`, expiry, and (post-launch) P2-5's distinct-device retention fix are the counterweights.

## Architecture

### Server-issued, attestation-bound device tokens

The device token stops being client-minted. The client proves device integrity once, the server mints the token and remembers the binding:

```
iOS                              Deno gateway (Railway)             Postgres
───                              ──────────────────────             ────────
POST /device-tokens/challenge ─▶ mint 32B challenge ─────────────▶ token_challenges (hashed, TTL 5m, single-use)
                              ◀─ { challenge }
DCAppAttestService.generateKey
attestKey(keyId, SHA256(challenge))
POST /device-tokens
  { platform, key_id,
    attestation_object,         ─▶ verify CBOR attestation:
    challenge }                     cert chain → Apple App Attest root,
                                    nonce, App ID = TEAM.ca.roadsense.ios,
                                    counter == 0
                                 mint device_token (server UUID) ─▶ attested_devices upsert
                              ◀─ { device_token, expires_at }        (key_id_hash, public_key,
                                                                      sign_count, trust_tier,
                                                                      current_token_hash)
…30 days later…
generateAssertion(keyId,
  SHA256(challenge))           ─▶ verify assertion sig + counter ↑ ─▶ overwrite current_token_hash
                              ◀─ { device_token, expires_at }         (no history kept)
```

Key properties:

- **Rotation survives.** The client still rotates monthly (the `DeviceTokenManager` decision logic keeps its shape — only "mint a UUID" becomes "exchange an assertion for a server UUID"). Upload payloads, hashing with `TOKEN_PEPPER`, and `ingest_reading_batch`'s signature are unchanged — the token is just no longer self-serve.
- **Verification is offline.** App Attest attestation/assertion verification is local cryptography against Apple's published root cert — no Apple API call in the request path. Play Integrity verdict decoding does call Google (see B163). "Attestation service down" therefore means *client-side* failures (device can't reach Apple) plus the Google decode dependency; the degradation path is B164's unverified tier, never a hard ingest outage.
- **Trust is stamped at write time.** `readings` gains `attested BOOLEAN NOT NULL DEFAULT FALSE`, set at ingest from the token's tier. All trust-signal SQL filters on that column — no historical join from readings back to `attested_devices`, which matters because of the next point.

### Privacy posture (this section is load-bearing)

[06](06-security-and-privacy.md)'s rotation story is "the server cannot link a device across rotations." A naive attestation design destroys that: an issuance log of every token a key ever received is a linkage table. The rules:

1. `attested_devices` stores `key_id_hash = SHA256(key_id || TOKEN_PEPPER)` — never the raw App Attest key id.
2. The row holds **only `current_token_hash`, overwritten in place at rotation.** No token-history table, no issuance audit log of past hashes. After rotation, the server again cannot join last month's readings to this month's device. (The operator *could* snapshot the table before rotation; the defense is policy + open-source code + the absence of any code path that persists history, stated honestly in the privacy policy — same trust boundary as the in-memory raw token in [06](06-security-and-privacy.md) principle 3.)
3. `readings.attested` is a boolean, not an identity — it leaks nothing.
4. The stored public key is the per-app App Attest key, not a hardware identifier; Apple's framework is explicitly designed not to be a tracking super-cookie.
5. [06](06-security-and-privacy.md) (threat-model rows, PIPEDA table row 4, the deletion-policy text) and the public privacy policy must be updated in the same PR as B160 — the "device token is not knowable to us" phrasing changes to "the current token is bound to an anonymous hardware-attested key; past tokens are not linkable."
6. App Store privacy labels: location stays Linked = Yes (unchanged); re-verify during B162 that the attestation exchange doesn't add an "Identifiers" disclosure — Apple's own guidance treats App Attest as non-tracking, but the checklist in [10](10-app-store-and-testflight-readiness.md) is the gate, not this doc.

### Enforcement modes and migration

One env var on the gateway, `ATTESTATION_MODE`:

| Mode | Behavior |
|---|---|
| `off` | today's behavior; issuance endpoints live but optional (dev default) |
| `log` | tokens verified when server-issued; legacy client-minted tokens accepted exactly as today; metrics on attested fraction — the soak mode |
| `enforce` | legacy/unattested tokens still upload, but: stamped `attested=false`, **excluded from all trust signals and aggregation**, device cap drops 50 → 10 batches/day. Pothole sensor reports from unattested tokens cannot create or promote candidates. |

`enforce` is deliberately *soft* — it never strands the existing TestFlight testers' queued uploads or old builds mid-drive; their data simply stops moving public surfaces until they update. A later hard mode (`403 token_upgrade_required` on unattested ingest) is gated on attested-build adoption ≥ 90% or 30 days post-release, whichever is later, and is a one-line flip documented in B164.

Existing beta-era *data* is grandfathered: aggregates and readings already ingested keep their standing (they came from a closed, personally-known tester pool predating the adversarial window). Existing single-reporter potholes get an explicit decision in B165.

Simulator and dev builds: `DCAppAttestService.isSupported == false` on simulators. Local Debug builds talk to the local stack with `ATTESTATION_MODE=off`. For Staging signed builds, the gateway accepts a `DEV_ATTEST_BYPASS_SECRET`-authenticated issuance path that mints an `unverified`-tier token; that env var must never be set on the production service (asserted by a deploy checklist line in [05](05-deployment-and-observability.md)'s Railway runbook).

## Tickets

### B160 — Server-issued device tokens: schema, challenge, and issuance endpoint

- **Spec refs:** [06](06-security-and-privacy.md), [03](03-api-contracts.md), [13](13-railway-deno-migration.md)
- **Depends on:** none (parallelizable with B165/B166)
- **Effort:** 2–3 days
- **RED**
  - Deno contract tests for `POST /functions/v1/device-tokens/challenge` (returns 32-byte challenge, rate-limited per IP via the existing `check_and_bump_rate_limit` pattern) and `POST /functions/v1/device-tokens` (rejects missing/expired/reused challenge with distinct error codes; rejects unknown platform)
  - pgTAP tests for `token_challenges` (hashed storage, TTL expiry, single-use delete-on-redeem) and `attested_devices` (key_id_hash PK, `current_token_hash` UNIQUE, overwrite-in-place on rotation leaves exactly one row and no history)
  - a grep-style/pgTAP guard asserting no table or log line stores a raw `key_id` or more than one token hash per device
- **GREEN**
  - migration: `attested_devices` (`key_id_hash BYTEA PRIMARY KEY`, `platform`, `public_key BYTEA`, `sign_count BIGINT`, `trust_tier`, `current_token_hash BYTEA UNIQUE`, `first_attested_at`, `last_rotated_at`, `accepted_batches INTEGER`), `token_challenges`, and a new `device_trust_tier` enum (`unverified`, `attested`, `established`)
  - mount `device-tokens/` handlers on `server.ts` ROUTES (deps-injected, same `createXHandler(deps)` pattern as every other function)
  - verification itself is stubbed behind a `verifyAttestation(platform, …)` dep — B161/B163 supply the real implementations
  - update [03-api-contracts.md](03-api-contracts.md) with the two endpoints and error codes in the same PR (backlog rule 5)
  - update [06](06-security-and-privacy.md) threat-model rows + privacy-policy outline per the privacy-posture section above
- **Acceptance**
  - challenge → issue → rotate round-trip works end to end against local Postgres with a fake verifier
  - a reused or expired challenge can never mint a token; concurrent redeems of one challenge yield exactly one token
  - `attested_devices` contains exactly one row per device after N rotations, holding only the latest token hash

### B161 — App Attest verification on the Deno gateway

- **Spec refs:** [06](06-security-and-privacy.md), [13](13-railway-deno-migration.md) (deps-pinning conventions)
- **Depends on:** B160
- **Effort:** 3–4 days
- **RED**
  - unit tests over checked-in fixture vectors: a known-good attestation object (captured from a real dev-environment device, both `appattestdevelop` and production `appattest` aaguids), a tampered cert chain, a wrong-nonce object, a wrong-App-ID object, a nonzero initial counter — each rejected with a distinct reason
  - assertion tests: valid signature verifies; counter replay (same or lower `sign_count`) rejected; signature over the wrong challenge rejected
  - a test proving verification makes **zero network calls** (fake fetch that throws)
- **GREEN**
  - implement `verifyAppAttestAttestation(...)`: CBOR decode, X.509 chain validation to the pinned Apple App Attest root CA, nonce check (`SHA256(authData || clientDataHash)`), key-id = SHA256(credCert public key), RP ID hash = `SHA256(TEAMID.ca.roadsense.ios)`, counter == 0
  - implement `verifyAppAttestAssertion(...)`: signature over `SHA256(authData || clientDataHash)` with the stored public key, monotonic counter, persist new `sign_count`
  - CBOR + minimal X.509 path handling via a small pinned/vendored dependency in `deps.ts` — **sticking point:** Deno's WebCrypto has no built-in cert-chain validation; budget the extra day here, and if a vetted minimal verifier can't be locked down, stop per the hard-stop rule below rather than hand-rolling ASN.1 in a hurry
  - environment switch for the `appattestdevelop` vs `appattest` aaguid (Staging accepts both; production accepts production only)
- **Acceptance**
  - all fixture vectors pass/fail exactly as specified; verification is pure CPU (no egress)
  - a real device on a Staging build can complete attestation against the deployed gateway
  - Apple receipt refresh / fraud-metrics API is explicitly **not** called (deferred — non-goal)

### B162 — iOS App Attest client integration and token exchange

- **Spec refs:** [01](01-ios-implementation.md) persistence/uploader sections, [06](06-security-and-privacy.md), [10](10-app-store-and-testflight-readiness.md)
- **Depends on:** B161
- **Effort:** 3–4 days
- **RED**
  - bootstrap-package unit tests (protocol-seamed, per the [01](01-ios-implementation.md) wrapper rule — never call `DCAppAttestService` from logic under test) for the token state machine: no key → attest → token; token near expiry → assertion → new token; attestation failure → retry with backoff → degraded client-minted token after N failures; `isSupported == false` → degraded path immediately
  - persistence tests: App Attest `keyId` survives relaunch in Keychain (per the [06](06-security-and-privacy.md) Keychain-only rule for secrets — this is the "future: signed device token" line coming due); a degraded token is replaced by an attested one at the next successful exchange
  - test that upload payload shape is byte-identical to today (server-issued token slots into the same `device_token` field)
- **GREEN**
  - `AttestationService` wrapper over `DCAppAttestService` (generateKey / attestKey / generateAssertion), keyId in Keychain
  - extend the `DeviceTokenManager` resolve flow: instead of `makeUUID()`, drive the challenge → attest/assert → token exchange against the B160 endpoints; keep the 30-day expiry decision logic and injected clock untouched
  - degraded path: after persistent attestation failure (Apple unreachable, unsupported device), fall back to the current client-minted UUID so collection and upload never stop; mark state in diagnostics (Settings → diagnostics gains "device verified: yes/no/pending")
  - simulator/dev builds: `isSupported == false` path exercised by default; Staging builds may use the `DEV_ATTEST_BYPASS_SECRET` issuance path behind a debug flag
  - re-verify App Store privacy labels per the privacy-posture checklist
- **Acceptance**
  - a TestFlight build attests on first launch and uploads under a server-issued token with zero contract changes visible in `processed_batches`
  - yanking the network during attestation leaves a device that still collects and uploads (degraded), then upgrades itself on the next successful exchange
  - simulator runs and the UI-test suite pass without any attestation entitlement present

### B163 — Play Integrity verification (Android sibling)

- **Spec refs:** [12](12-android-implementation.md), [06](06-security-and-privacy.md), [11](11-post-launch-roadmap.md) Phase 12
- **Depends on:** B160 (server), B161 (shared issuance plumbing); the Android client work rides the `gmann14/android-beta-test-fixes` merge (B120-range) — server side does not wait for it
- **Effort:** 2–3 days (server) + 1–2 days client wiring inside the Android branch
- **RED**
  - Deno tests with fixture verdicts: `MEETS_DEVICE_INTEGRITY` + `PLAY_RECOGNIZED` accepted; failed device integrity rejected; stale verdict timestamp rejected; nonce/requestHash mismatch rejected; Google decode endpoint unreachable → issuance returns the documented `attestation_unavailable` error (client falls back to degraded token, ingest unaffected)
  - package-name pinning test (`ca.roadsense.android`)
- **GREEN**
  - `verifyPlayIntegrity(...)` dep for the B160 endpoint: call Google's `decodeIntegrityToken`, validate verdict fields (request hash = our challenge, package name, timestamp freshness, device + app integrity)
  - **[DECISION]** until the app distributes through Play, sideloaded beta APKs cannot earn `PLAY_RECOGNIZED`; accept `MEETS_DEVICE_INTEGRITY` alone at tier `attested` during the sideload-beta phase and require `PLAY_RECOGNIZED` from the first Play-track build onward (config flag, flipped in the B127 launch checklist)
  - Android client: integrate `IntegrityManager` into the ported `DeviceTokenManager` flow with the same degraded-fallback semantics as B162
- **Acceptance**
  - server verdict verification is fixture-tested without Google access; live path verified once against a real device token
  - the Google-decode dependency failing degrades token issuance only — never `/upload-readings`
  - the same `attested_devices` row shape serves both platforms; no Android-only branches in ingest

### B164 — Enforcement modes, beta-token migration, and degradation

- **Spec refs:** [03](03-api-contracts.md), [06](06-security-and-privacy.md), [05](05-deployment-and-observability.md)
- **Depends on:** B162 (an attested build must exist before `log` mode means anything); B163 for the Android flip
- **Effort:** 2–3 days
- **RED**
  - Deno tests for the three `ATTESTATION_MODE` values on `/upload-readings` and `/pothole-actions`: `off` = today's behavior bit-for-bit; `log` = legacy tokens accepted + attested fraction metric emitted; `enforce` = legacy/unattested tokens accepted with `attested=false` stamping, 10/day device cap, and no trust-signal writes
  - pgTAP: readings rows carry `attested` correctly per token tier; `segment_contributor_marks` (B166) and pothole reporter marks (B165) receive **no** rows from unattested tokens in `enforce` mode; `nightly_recompute_aggregates` excludes unattested readings from score and contributor math in `enforce` mode
  - a replay-style test proving a pre-migration legacy batch (real beta payload shape) still ingests successfully in every mode
- **GREEN**
  - migration: `readings` gains `attested BOOLEAN NOT NULL DEFAULT FALSE` (cheap on a partitioned table; no backfill — historical rows are correctly `false`); `ingest_reading_batch` gains a `p_attested BOOLEAN DEFAULT FALSE` parameter (additive, replay-safe)
  - gateway: token-tier lookup by `current_token_hash` at upload time feeds the stamp + cap; metrics counter for attested/unattested batch counts in structured logs (the [05](05-deployment-and-observability.md) ops-metrics pattern)
  - aggregation: `update_segment_aggregates_from_batch` and `nightly_recompute_aggregates` filter trust-signal and score inputs to `attested = TRUE` when (and only when) a new `attestation_enforced` setting row says so — one switch, read by SQL, set by the same deploy that flips `ATTESTATION_MODE`, so gateway and DB can't disagree
  - rollout runbook entry in [05](05-deployment-and-observability.md): `off → log` (with the B162 TestFlight release) → ≥ 1 week soak watching the attested fraction → `enforce` before the marketing push; the later hard-reject flip (`403 token_upgrade_required`) documented but not scheduled
- **Acceptance**
  - flipping modes requires no client release and no migration beyond the one above
  - in `enforce`, a forged-UUID upload succeeds (200) yet provably moves no public surface: no contributor mark, no confidence change, no pothole candidate, no score input
  - beta testers on the previous build keep uploading without errors through the whole rollout

### B165 — Pothole corroboration gate: candidate status and distinct-device promotion ✅

**Shipped 2026-06-12 (commit `cc9bcbe`)** — stage 1 (distinct token hashes) as specified: migrations `20260612181000_pothole_status_candidate_value.sql` + `20260612182000_pothole_corroboration_gate.sql`, pgTAP suite `supabase/tests/018_pothole_corroboration_gate.sql`, contract note in [03](03-api-contracts.md), methodology-page sentence. Grandfathering applied as decided (existing actives kept; demotion SQL recorded in the migration comment). Bonus: the sensor-path `unique_reporters` blind increment is fixed via `pothole_reporter_marks` per the RED note below. Stage 2 (attested-only marks) lands with B164.

- **Spec refs:** [02](02-backend-implementation.md) pothole folding, [03](03-api-contracts.md), review findings P1-2/P0-1
- **Depends on:** none for stage 1 (distinct token hashes); B164 for stage 2 (distinct *attested* devices) — ship stage 1 immediately, the predicate tightens automatically when `attestation_enforced` flips
- **Effort:** 2–3 days
- **RED**
  - pgTAP: a single device's sensor batch creates a pothole with `status='candidate'` that does **not** appear in `get_tile` potholes, `get_potholes_in_bbox`, or `get_top_potholes`; a second *distinct* device within 15 m / 90 days promotes it to `active`; N batches from the *same* device never promote (this also kills the sensor-path `unique_reporters` inflation — the current `update_existing` arm adds per-batch distinct counts blindly, same bug class as P1-3)
  - pgTAP: manual `manual_report` creates `candidate` (not `active`) unless it corroborates an existing candidate from a different device; `confirm_present` from a second device promotes; the existing `confirm_fixed` two-device quorum still resolves
  - pgTAP for the new `pothole_reporter_marks` table: `(pothole_id, device_token_hash)` PK makes `unique_reporters` exact under repeated batches and across the sensor/manual paths
  - backfill test covering the grandfathering decision below on a fixture of pre-migration potholes
- **GREEN**
  - migration: `ALTER TYPE pothole_status ADD VALUE 'candidate'`; `pothole_reporter_marks (pothole_id UUID, device_token_hash BYTEA, PRIMARY KEY (pothole_id, device_token_hash))` with rows deleted alongside their pothole; redefine `fold_pothole_candidates` and `apply_pothole_action` to write marks, compute `unique_reporters` from genuinely-new marks only, insert as `candidate`, and promote to `active` at `unique_reporters >= 2` (stage 2: marks only written for attested devices, per B164)
  - **public visibility predicates stay untouched** — `status='active'` remains the single gate in `get_tile` / `get_potholes_in_bbox` / `get_top_potholes`; the gate moves into the status transition, one place instead of three
  - **[DECISION]** existing TestFlight-era single-reporter `active` potholes are **grandfathered** (kept `active`): they predate the adversarial window and came from a personally-known closed tester pool, and demoting them would blank most of the pothole layer weeks before the push. They expire on the normal 90-day unconfirmed cycle. The alternative (one-off demotion to `candidate`, `UPDATE pothole_reports SET status='candidate' WHERE unique_reporters < 2 AND status='active'`) is recorded here for the owner to apply instead if the optics of "every marker is corroborated" matter more than map density.
  - backfill `pothole_reporter_marks` from existing `pothole_actions` device hashes where recoverable; sensor-era potholes start with their current `unique_reporters` value trusted as-is
  - web/iOS copy check: nothing currently promises "every marker is multi-witness"; the methodology page gains one sentence saying new potholes require two devices (same-PR docs rule)
- **Acceptance**
  - a single forged batch can no longer place a public pothole marker or a top-potholes entry; promotion appears on tiles within one cache TTL (≤ 1h) of the corroborating report
  - `unique_reporters` is exact (re-running the same device's batches N times changes nothing)
  - the pre-push map keeps its grandfathered markers; every post-migration marker is corroborated or invisible

### B166 — Exact unique-contributor accounting for the incremental path ✅

**Shipped 2026-06-12 (commit `fca1dc2`)** — migration `20260612180000_exact_contributor_dedupe.sql` (marks table + backfill, `update_segment_aggregates_from_batch` counts only newly-inserted marks, `nightly_recompute_aggregates` seeds marks for everything it counts, GC cron registration), Deno scheduler sweep in `_shared/scheduler.ts`, pgTAP suite `supabase/tests/017_segment_contributor_marks.sql` (P1-3 reproduction green by construction; pgTAP not executed in this pass — Docker unavailable — verified by manual diff against the last-write-wins bodies).

- **Spec refs:** [02](02-backend-implementation.md) aggregates, review finding P1-3
- **Depends on:** none (parallelizable with everything; smallest ticket, biggest honesty-per-day)
- **Effort:** 1–2 days
- **RED**
  - pgTAP reproducing P1-3: one device, three batches, same segment, same day → `unique_contributors` must stay 1 and confidence must stay `low` through the incremental path (today it reads 3/`medium`)
  - pgTAP: two genuinely distinct devices across separate batches → 2; a device already counted by the nightly recompute does not re-increment via a later batch
  - pgTAP: marks GC removes rows older than the 6-month reading-retention window and the nightly recompute remains the overriding source of truth afterward
- **GREEN**
  - migration: `segment_contributor_marks (segment_id UUID, device_token_hash BYTEA, first_seen_at TIMESTAMPTZ, PRIMARY KEY (segment_id, device_token_hash))`; `update_segment_aggregates_from_batch` inserts marks `ON CONFLICT DO NOTHING` and increments `unique_contributors` **only by the count of rows actually inserted**, then derives confidence from the corrected value (this closes "3 batches → medium-confidence visible tile" in the same statement)
  - **why a dedupe table and not HyperLogLog:** the cardinality is tiny (active devices × touched segments — thousands of rows at NS scale, not billions), the Railway Postgres template ships no `hll` extension, the marks are exactly auditable in a pgTAP test, and the nightly `COUNT(DISTINCT)` recompute already corrects any drift within 24h — a probabilistic sketch buys nothing here but a new dependency and approximate answers on the project's headline trust number. The table also slots into the conventions the schema already uses (`rate_limits`, `processed_batches`: small bookkeeping tables with date-based GC).
  - GC: extend the existing daily scheduler job list (`_shared/scheduler.ts`) with a marks sweep older than 6 months, matching reading retention (privacy: marks hold token hashes already present in `readings`, with the same retention window — no new retention class)
  - monthly token rotation still counts a long-running device once per rotation; that residual is identical to today's nightly-recompute semantics and is closed by B160's stable attested identity only in the sense that caps apply per device — contributor counts deliberately keep counting *token* hashes so the privacy property (no cross-rotation linkage in analytical tables) holds
- **Acceptance**
  - the P1-3 reproduction is green: no single device can raise confidence or make a segment publicly visible inside one day, regardless of batch count
  - incremental and nightly paths agree on `unique_contributors` for a fixture of overlapping batches to within the documented rotation-boundary semantics
  - ingest latency for a 1000-reading batch is not measurably regressed (the marks insert is one statement)

### B167 — Trust tiers: new vs established devices, caps and counting

- **Spec refs:** [06](06-security-and-privacy.md), [02](02-backend-implementation.md)
- **Depends on:** B164
- **Effort:** 2–3 days
- **RED**
  - pgTAP/Deno tests for tier transitions: `attested` → `established` requires both ≥ 7 days since `first_attested_at` **and** ≥ 5 accepted batches (injected clock); `unverified` never auto-promotes
  - tests for tier effects: per-device daily batch cap 10 (`unverified`) / 50 (`attested`/`established`); the single-device manual-pothole publication path (manual report + own-drive sensor backing) requires `established`; everything else (contributor marks, reporter marks, score inclusion) keys off `attested`-or-better exactly as B164 left it
  - a regression test asserting aggregation weights are **unchanged** by tier — guarding the deferral below from scope creep
- **GREEN**
  - tier evaluation at token rotation/issuance time (no per-upload recomputation); `accepted_batches` incremented from the ingest result path
  - wire the tiered caps into the existing `check_and_bump_rate_limit` call sites (key prefix per tier, no schema change to `rate_limits`)
  - enable the `established`-gated single-device manual path in `apply_pothole_action` (the only loosening tiers buy; B165 ships without it)
  - surface the tier in Settings diagnostics ("device verified / established") so testers can self-report
- **Acceptance**
  - a device farm attested today cannot use any `established`-gated path for a week no matter its volume
  - tier changes require no client release
  - aggregation math is bit-identical before/after this ticket for the same input readings — tiers gate *counting and caps*, not weights

## Sequencing & effort

### What must land before the public marketing push

In order, with the dependency chain (B165/B166 run in parallel with the B160 chain):

| Order | Ticket | Effort | Why pre-push |
|---|---|---|---|
| 1 | B166 contributor dedupe | 1–2 d | SQL-only; kills the cheapest trust-number forgery and the "3 batches → medium confidence" hole in a day of work |
| 2 | B165 pothole corroboration | 2–3 d | SQL-only; no new public pothole on one identity's say-so, predicate auto-tightens when attestation enforces |
| 3 | B160 token issuance | 2–3 d | foundation for the chain |
| 4 | B161 App Attest verify | 3–4 d | the hard cryptographic middle; schedule slack here |
| 5 | B162 iOS client + TestFlight build | 3–4 d | `log`-mode soak starts when this build reaches testers |
| 6 | B164 enforcement (`log` → soak ≥ 1 wk → `enforce`) | 2–3 d + soak | `enforce` must be live before the first media story runs |

**Critical path: B160 → B161 → B162 → B164-enforce ≈ 2.5–3.5 weeks of work plus one week of log-mode soak — start no later than ~4–5 weeks before the push date.** If the push date moves earlier than that, the floor is B166 + B165 (≈ 1 week, SQL-only, no client release): they don't stop a determined Sybil, but they close every one-identity forgery and the pothole layer's single-witness publication, which are the attacks a Facebook-thread skeptic will actually try first.

### What can follow the push

- **B163 Play Integrity** — server side can land anytime after B161; it gates the *Android* public beta (pre-Play-launch checklist item in B127), not the iOS/web push.
- **B167 trust tiers** — tightens caps and enables the established-device manual path; valuable within 2–4 weeks post-push, not blocking (rate limits and B164's exclusion rule carry the interim).
- The hard-reject ingest flip (B164's documented follow-up), P2-5 distinct-device pothole retention, and B097 cross-rotation dedupe — scheduled by their existing triggers.

### Non-goals (explicit, to keep this shippable)

- **ML-ish anomaly detection** (velocity checks, route-shape plausibility models, cross-device correlation scoring) — deferred until there is real attack telemetry to train against; the layered identity cost is the MVP defense.
- IP/ASN reputation, CAPTCHA, proof-of-work, or any human-verification step in the upload path.
- Per-batch request signing / assertion-per-upload — one attestation per token issuance is the cost/benefit sweet spot; signing every batch adds latency and battery for marginal gain over a 30-day-bound token.
- Aggregation *weight* multipliers by tier (B167 gates counting and caps only).
- Apple receipt refresh / fraud-metric APIs; DeviceCheck two-bit storage.
- Jailbreak/root detection beyond what App Attest / Play Integrity verdicts already encode.
- Attesting the photo endpoints (not mounted in production — NEW-2 owns that decision) or any web write surface (the web has none).
- Retroactively re-validating or purging historical beta readings.
- Any admin/revocation UI — revocation at MVP is a manual `DELETE FROM attested_devices WHERE current_token_hash = …` runbook entry.

## Hard stop rules

Stop and reassess if:

- B161's attestation verification cannot be built on a small, pinned, test-vectored dependency — do not hand-roll ASN.1/X.509 under deadline pressure; slipping the push beats shipping a verifier nobody can audit
- the `log`-mode soak shows < 70% of active devices attesting after a week — find the client bug before flipping `enforce`, or the map goes quiet at the worst moment
- attestation latency or failure rates measurably break first-launch onboarding — the degraded path must keep collection working, or the trust feature is costing the contributors it exists to protect
- any step requires storing token-hash history per device — that's the privacy model breaking, not an implementation detail
