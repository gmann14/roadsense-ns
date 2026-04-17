# 06 — Security & Privacy

*Last updated: 2026-04-17*

Covers: PIPEDA compliance checklist, threat model, abuse mitigation, App Store privacy labels, and incident response for privacy-impacting issues.

Privacy isn't a feature; it's the foundation. A data leak in a civic-tech app trading on trust would end the project. Everything here is cheap to do correctly up front and expensive or impossible to retrofit.

## Design Principles (non-negotiable)

1. **Collect only what's needed.** No email, no phone, no name. No account system in MVP.
2. **Never see raw tracks server-side.** Client strips privacy-zone readings; server only ingests individual windows with midpoint coordinates.
3. **Never store the raw device token.** The client sends the token UUID over TLS; the Edge Function hashes it with a server-side pepper on receipt and discards the cleartext in the same request. The raw token is never persisted, never logged, never returned. (It *is* in server memory for the duration of the request — that's a necessary trust boundary, not a marketing claim to obscure.) Rotate monthly.
4. **No third-party analytics or ad SDKs.** Sentry for crashes and limited performance diagnostics only, with PII scrubbing, and nothing else.
5. **Anonymized from the outside in.** Privacy policy, App Store labels, user-facing copy all say the same thing the code enforces.

## PIPEDA Compliance Checklist

PIPEDA is Canada's federal privacy law for commercial organizations. Nova Scotia also has PIIDPA (public-sector equivalent) — not directly applicable to us unless/until we sign a municipal contract.

PIPEDA's 10 Principles, mapped to our implementation:

| Principle | How we comply |
|---|---|
| 1. Accountability | Single data controller: Graham Mann. Privacy policy names a contact. |
| 2. Identifying purposes | App onboarding + privacy policy explicitly state: collect accelerometer + GPS to map road quality; aggregate publicly. |
| 3. Consent | Opt-in via iOS permission prompts, explicit onboarding screen. Cellular upload OFF by default. |
| 4. Limiting collection | No PII fields collected. GPS discarded inside privacy zones. Device token is pseudonymous and rotated monthly. |
| 5. Limiting use, disclosure, retention | Raw readings kept 6 months, then deleted (partition drop). Aggregates kept indefinitely. No data sold to third parties at MVP. |
| 6. Accuracy | Quality filters reject bad GPS; crowdsourced averaging improves over time. "Report repair" path (post-MVP) lets users correct stale data. |
| 7. Safeguards | TLS for all API calls. Server-side hashing with pepper. Supabase-managed DB with RLS. No service-role keys on client. |
| 8. Openness | Privacy policy at public URL; open-source repo after launch. |
| 9. Individual access | User can delete all LOCAL data via Settings. Server-side data is anonymous (device token is not knowable to us) — cannot be attributed back. This is the correct PIPEDA stance when data is truly de-identified. |
| 10. Challenging compliance | Contact email in privacy policy; acknowledge within 30 days. |

### Deletion Policy (subtle but important)

**Local:** User can tap "Delete all local data" in Settings → clears SwiftData store. Takes effect immediately.

**Server:** We cannot delete individual users' server-side readings on request because readings are stored only as aggregated, pseudonymous data points — we have no user identifier, email, or account tying any reading to a specific person. The device token hash is one-way and rotates monthly.

What we *can* do if a user asks:
- Provide a snapshot of what a device-token-hash has contributed during the user's known active window, if they give us their hash (surfaced as an optional developer-only diagnostic in Settings)
- Bulk-delete readings from a specific device_token_hash going forward — if the user gives us their current hash we can blacklist it
- Delete aggregates derived from a single user: impossible by design, but because aggregates are means over many contributors, a single person's contribution is already privacy-diffuse

The 6-month readings partition drop is an automatic, recurring deletion — so every reading a user has ever contributed is deleted within 6 months without any action required.

Explain all of the above plainly in the privacy policy and onboarding — don't hide behind "we can't". The honest story is: "we designed it so there's almost nothing to delete, and what exists is automatically deleted within 6 months."

### Minors

No age-gating in MVP. Our data collection model doesn't ID minors because it doesn't ID anyone. If PIPEDA audit pushes for age attestation, add a one-click "I'm 13+" during onboarding.

## Privacy Policy (content outline)

Publish at `https://roadsense.ca/privacy` before TestFlight external review.

Sections:

1. **What we collect** — accelerometer, GPS, speed, timestamps, IP (for rate limiting, not logged), and crash / performance diagnostics from Sentry with PII scrubbing
2. **What we don't collect** — no name, no email, no phone, no account, no raw GPS tracks
3. **How we use it** — aggregate road quality scores shown on a public map
4. **How long we keep it** — raw readings 6 months, aggregates indefinitely
5. **Who we share it with** — nobody, except the public aggregate map
6. **Your choices** — privacy zones, pause collection, delete local data
7. **How we protect it** — TLS, hashing, no PII stored, open-source
8. **Children's privacy** — not directed at children under 13
9. **Changes to this policy** — version + effective date, notify in-app
10. **Contact** — graham.mann14@gmail.com

**Plain language.** If anything reads like a lawyer wrote it, rewrite it. Legal correctness without readability fails PIPEDA principle 8 (openness).

## Phase 2 Web Dashboard Privacy Guardrails

When the public web dashboard ships, keep these rules aligned with [07-web-dashboard-implementation.md](07-web-dashboard-implementation.md):

- no accounts in W1 web
- no cookies except strictly necessary platform/session mechanics if they ever become unavoidable
- no ad tech
- no session replay
- no map-click logging tied to person-like identifiers
- no raw trace, raw reading, or per-device views on the public web

If frontend error monitoring is added later, keep it to error capture only and apply the same PII scrubbing rule as iOS/backend. Do not log free-form search text if it can encode a home address or specific route.

## App Store Privacy Labels

What we enter in App Store Connect:

**Data Types Collected:**
- **Location — Precise Location** ✅
  - Use: App Functionality
  - Linked to user? **Yes**
  - Used for tracking? **No**

**Data NOT collected:**
- Contact info (name, email, phone, address)
- Health & fitness
- Financial
- User content
- Browsing / search history
- Identifiers (user ID, advertising ID)
- Purchases
- Usage data

**Data Types Collected (continued):**
- **Diagnostics — Crash Data** ✅ (Sentry uncaught exceptions + stack traces)
  - Use: App Functionality
  - Linked to user? **No**
  - Used for tracking? **No**
- **Diagnostics — Performance Data** ✅ (Sentry transaction sampling at 10%)
  - Use: App Functionality
  - Linked to user? **No**
  - Used for tracking? **No**

Apple's policy: diagnostics ARE "collected" data under their framework, even if scrubbed. The location answer here is **Linked = Yes** because the uploaded precise location is associated with a rotating device token before aggregation; that token is pseudonymous, but Apple still treats it as linkable app-collected data. This is the honest label — the older rumour that "Sentry doesn't count" is wrong.

**Red flag:** the location answer here is driven by the device-token linkability story. If we ever add a user account feature, or start attaching diagnostics to that same token, the labels change again. Don't do that casually.

## Threat Model

### Assets to protect

1. **User home/work locations** — inferred from privacy-zone gaps, or from raw GPS if uploaded
2. **Individual drive patterns** — unaggregated readings that could show a person's commute
3. **Device identifiability** — long-term tracking of a single device across contributions

### Threat actors

1. **Curious technologists** — scraping public tiles, correlating with known venues
2. **Abusive contributor** — uploading bogus data to skew scores
3. **Network attacker** — MITM on upload
4. **Opportunistic attacker** — stolen phone with app installed
5. **Database attacker** — insider or compromised Supabase access

### Mitigations

| Threat | Mitigation |
|---|---|
| Reverse triangulation of home from privacy zone gaps | Strava-style randomized offset (50-100m) + min zone radius 250m |
| Tracking individual drives | Midpoint-of-window coords (not continuous track); 50m granularity server-side; per-device weekly reading cap of 3 per segment |
| Long-term device identification | Monthly device token rotation; SHA-256 server hash with secret pepper |
| Uploaded data intercepted | TLS 1.3 only; certificate pinning (nice-to-have — evaluate week 6) |
| MITM rewriting traffic | TLS; no signed batch in MVP. If abuse emerges, add request signing / attestation in Phase 2 rather than claiming it now. |
| Stolen phone | iOS device lock is the primary defense. App contains no credentials to steal; SwiftData store contains only local readings (already "my drives") |
| Supabase DB breach | No PII in DB; device tokens are hashed; raw readings are 6-month rolling; aggregates contain nothing identifying |
| Bogus data / trolls | Rate limits (50 batches/device/24h, 10/IP/hr); plausibility checks (NS bbox, speed range, acceleration range); per-device reading cap; statistical outlier trimming in nightly recompute |
| Automated abuse (scripted uploads) | DeviceCheck attestation (Phase 2, when signal is clear); meanwhile per-device + per-IP limits |

## Abuse Mitigation (Data Integrity)

The civic-data value proposition depends on the data being trustworthy. Abuse mitigations already in the pipeline:

- **Plausibility gates** — reject readings outside NS bbox, speeds outside [0, 200], accelerations > 10g, future timestamps, readings > 7 days old
- **Map-matching filters** — discard if no segment within 20m, or heading mismatch > 45° (and not reversed within 45°)
- **Per-device caps** — 3 readings per segment per week per device (enforced at recompute)
- **Outlier trimming** — nightly recompute drops top/bottom 10% per segment
- **Confidence gating** — segments with < 3 unique contributors NOT shown publicly
- **Rate limits** — per-device and per-IP bucketing

**Abuse we don't catch at MVP** (acceptable residual risk, document for future):

- Coordinated attacks from many devices with real data but intentionally destructive driving → hard to distinguish from a really bad road
- VPN-rotated single user → could evade per-IP limit but still hits per-device limit
- Jailbroken device spoofing CoreLocation → DeviceCheck attestation is the right fix, deferred

## Incident Response for Privacy Events

Separate from general ops incidents (see [05-deployment-and-observability.md](05-deployment-and-observability.md)).

### Categories

| Category | Example | SLA |
|---|---|---|
| **P0 — Data leak** | Database dump leaked, PII exposed, privacy zone protections bypassed | Report to Office of the Privacy Commissioner of Canada (OPC) "as soon as feasible" under PIPEDA's breach-reporting amendment; notify affected individuals where possible. No statutory 72h deadline — that's GDPR. Our internal target: OPC report within 72h, public disclosure within 7 days. |
| **P1 — Privacy degradation** | A reader's privacy zones aren't being respected; per-device cap bypassable | Patch within 1 week; notify affected users if identifiable |
| **P2 — Privacy policy drift** | Code now collects something not in policy | Update policy or code within 2 weeks |

### Playbook for P0

1. **Contain** — rotate keys; disable affected endpoints; take tile endpoint read-only
2. **Assess** — scope of data affected, number of users, what fields
3. **Notify** — Office of the Privacy Commissioner of Canada (OPC) "as soon as feasible" if a real risk of significant harm (RROSH) exists (per PIPEDA's breach-reporting regulations; no fixed hour deadline, but our internal target is within 72 hours of confirmation). Notify affected users via in-app banner; we have no email addresses so email notification isn't an option — document that reality in the OPC report.
4. **Remediate** — fix the issue, publish postmortem
5. **Review** — full review of privacy model within 14 days

### Reporting

Contact form at `https://roadsense.ca/privacy#contact` (or a simple `mailto:`). Public GPG key for sensitive reports (post-launch polish, not MVP).

## Security Hardening Checklist

### iOS

- [ ] App Transport Security (ATS) with no exceptions (no `NSAllowsArbitraryLoads`)
- [ ] Keychain-only for any secret (none for MVP; future: signed device token)
- [ ] `NSLocationWhenInUseUsageDescription` and `NSLocationAlwaysAndWhenInUseUsageDescription` have specific, non-generic copy
- [ ] `NSMotionUsageDescription` is specific
- [ ] No `.plist` or resource bundle leaks a secret (API URL is fine, anon key is fine, Mapbox public key is fine, Mapbox SECRET key is NOT fine — never bundle)
- [ ] `AppTransportSecurity` forces TLS 1.2+
- [ ] Jailbreak detection: out of scope for MVP (too much false-positive noise for a civic app)
- [ ] No PII in `os_log` or Sentry breadcrumbs
- [ ] Privacy-zone coords are written with the offset already applied — un-offset coords never hit disk

### Backend

- [ ] TLS only — Supabase enforces this by default; verify no HTTP endpoint exposed
- [ ] Edge Functions use the narrowest viable key: anon-scoped clients for simple read wrappers where RLS is sufficient, service role for ingestion, locked RPC-backed reads (`tiles`), and `/health`
- [ ] RLS policies as in Migration 008 ([02-backend-implementation.md](02-backend-implementation.md))
- [ ] Validate & sanitize ALL user-supplied input before SQL (we use parameterized queries via Supabase client; no raw SQL string concat)
- [ ] Rate limit logic is DB-atomic (`INSERT ... ON CONFLICT UPDATE`)
- [ ] `TOKEN_PEPPER` stored as Supabase secret, not in migrations or code
- [ ] Supabase project dashboard access limited to Graham; 2FA enforced
- [ ] GitHub repo: require PR reviews before merge to main (even for solo dev — acts as a checkpoint)
- [ ] `.github/CODEOWNERS` lists Graham for sensitive paths (migrations, functions, Info.plist)
- [ ] Dependabot enabled for SPM + npm + deno deps
- [ ] Secret scanning enabled (GitHub default); pre-commit gitleaks hook for local catches

### Infrastructure

- [ ] Supabase database backups enabled (Pro tier default)
- [ ] DNS locked to registrar-level 2FA
- [ ] Email account for graham.mann14@gmail.com has 2FA, hardware key if possible
- [ ] No shared credentials with anyone until team grows

## OWASP Top 10 Relevance Check

| OWASP category | Relevant? | Mitigation |
|---|---|---|
| Broken Access Control | Yes | RLS policies; service-role key only on Edge Function, never on client |
| Cryptographic Failures | Yes | TLS; SHA-256 with pepper for device tokens |
| Injection | Yes | Parameterized queries only (supabase-js handles escaping) |
| Insecure Design | N/A at API level, but our privacy-first architecture is itself the design control |
| Security Misconfiguration | Yes | Idempotent migrations; RLS on by default; review each new Edge Function against checklist |
| Vulnerable Components | Yes | Dependabot; quarterly SDK upgrade cadence |
| Authentication Failures | N/A for MVP (no user auth) |
| Software/Data Integrity Failures | Yes | Signed releases via App Store; migrations reviewed; no third-party Edge Function dependencies beyond @supabase/supabase-js |
| Logging & Monitoring Failures | Yes | Sentry + custom metrics; see [05](05-deployment-and-observability.md) |
| SSRF | No | No URL-fetching user input |

## Open-Source Posture

- **When:** right after TestFlight launch
- **License:** MIT for code, CC-BY-4.0 for any documentation/data exports
- **What to keep private if anything:** Nothing for MVP. The server-side pepper is a Supabase secret, not in the repo. No special business logic that would be security-through-obscurity
- **Contribution requirements:** CLA deferred (overkill for a hobby civic project); just require PR reviews

## Security / Privacy Policy Decisions

- **No certificate pinning in MVP.** Standard TLS is enough for launch; pinning can be added later if the threat model changes.
- **Always show freshness context in human-readable UI, not per tile.** Segment detail, trust strips, and report pages should expose "updated" timing; vector-tile attributes do not need to carry user-facing disclaimer copy.
- **Open-data licensing stays deferred until post-launch.** Decide once there is enough real data volume to make the policy concrete.
- **Write a lightweight PIPEDA privacy impact assessment before any municipal partnership discussion, not as an MVP launch blocker.**
