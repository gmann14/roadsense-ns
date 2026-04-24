# RoadSense NS — Implementation Specs

These docs translate [product-spec.md](../product-spec.md) into concrete, actionable implementation plans designed to get a production-ready MVP to TestFlight as fast as realistically possible.

**Target:** Halifax-only TestFlight beta with functioning end-to-end pipeline (collect → upload → aggregate → render) in **8 weeks** from kickoff, assuming 1 full-time engineer plus ~0.25 FTE on backend/ops.

## Reading Order

| # | Doc | Purpose |
|---|---|---|
| 00 | [Execution Plan](00-execution-plan.md) | Week-by-week roadmap, critical path, parallelizable work, risks to watch |
| 01 | [iOS Implementation](01-ios-implementation.md) | Xcode project layout, sensor pipeline, data layer, UI, background execution |
| 02 | [Backend Implementation](02-backend-implementation.md) | Supabase setup, schema migrations, OSM import, ingestion pipeline, tile serving |
| 03 | [API Contracts](03-api-contracts.md) | Endpoint shapes, error codes, versioning, idempotency |
| 04 | [Testing & Quality](04-testing-and-quality.md) | Unit/integration/field test strategy, simulator harness, calibration runs |
| 05 | [Deployment & Observability](05-deployment-and-observability.md) | Environments, CI/CD, logs, metrics, alerts, on-call basics |
| 06 | [Security & Privacy](06-security-and-privacy.md) | PIPEDA checklist, threat model, abuse mitigation, incident response |
| 07 | [Web Dashboard Implementation](07-web-dashboard-implementation.md) | Future public + municipal web UX, IA, visual system, data presentation patterns |
| 08 | [Implementation Backlog](08-implementation-backlog.md) | Literal task order, dependencies, red/green plan, and acceptance criteria |
| 09 | [Internal Field-Test Pack](09-internal-field-test-pack.md) | Operational checklist for signed-device dogfooding and evidence capture |

## Conventions Used Across Specs

- **Acceptance criteria** — every milestone has a testable "done" condition
- **Decision markers** — `[DECISION]` tags flag choices that are hard to reverse; revisit explicitly in review
- **Open questions** — `[OPEN]` tags mark items that need resolution before that module starts
- **Code snippets** — illustrative, not copy-paste final; authoritative source lives in the repo once implementation starts

If you are starting implementation rather than reviewing architecture, read [08-implementation-backlog.md](08-implementation-backlog.md) after skimming the roadmap in [00-execution-plan.md](00-execution-plan.md).

## What's Intentionally Deferred

These are real product needs, but punted past MVP launch to keep the critical path short:

- Android client (product-spec Phase 6)
- Web dashboard implementation deferred from MVP launch, but now specified in [07-web-dashboard-implementation.md](07-web-dashboard-implementation.md)
- iOS DeviceCheck attestation — wait until abuse is a real problem
- Gamification (leaderboards, badges)
- Broader pothole follow-up prompt polish on top of the shipped `Mark pothole` + segment-detail follow-up actions (see [01 §Manual Pothole Reporting And Follow-up](01-ios-implementation.md) + [02 §Explicit Pothole Actions](02-backend-implementation.md))
- Vehicle-type calibration factors — crowdsourced averaging absorbs this at MVP scale
- Supabase Row-Level Security beyond basic read-only public aggregates — no authenticated users in MVP
- My Drives list (spec'd in [01 §My Drives List](01-ios-implementation.md), not built)
