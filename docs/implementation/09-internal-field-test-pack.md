# 09 — Internal Field-Test Pack

*Last updated: 2026-04-20*

Covers: the concrete checklist for internal dogfooding once Apple signing/TestFlight are available. This is intentionally operational rather than architectural: the goal is that a tester can run through it without inventing their own procedure.

## Purpose

Use this pack for:

- first signed on-device installs
- family / friend internal dogfood
- pre-TestFlight staging validation
- repeatable regression checks after sensor, privacy, upload, or map changes

Do not use this as a substitute for unit, simulator-harness, or staging smoke coverage. It sits on top of those layers.

## Entry Criteria

Before any human drive:

- latest `main` build installs successfully on the target iPhone
- local simulator checks are green:
  - `cd ios && swift test`
  - `xcodebuild build-for-testing -project ios/RoadSenseNS.xcodeproj -scheme RoadSenseNS -configuration "Local Debug" -destination 'platform=iOS Simulator,name=iPhone 17 Pro' CODE_SIGNING_ALLOWED=NO COMPILER_INDEX_STORE_ENABLE=NO ENABLE_PREVIEWS=NO`
- backend checks are green:
  - `supabase db reset`
  - `supabase test db`
  - `deno test -A $(find supabase/functions -type f -name '*_test.ts' | sort)`
  - `./scripts/api-smoke.sh`
  - `./scripts/seeded-e2e-smoke.sh`
- staging environment exists if the test is not pointed at local backend
- privacy policy URL resolves
- tester knows this is a road-quality beta, not turn-by-turn navigation

## Tester Setup Checklist

Per tester / device:

- install latest signed build
- confirm iPhone has:
  - Developer Mode enabled if sideloaded
  - Location Services enabled
  - Motion & Fitness enabled
  - Background App Refresh enabled
  - Low Power Mode off for baseline runs
- open app once on Wi‑Fi before driving
- complete onboarding
- create at least one privacy zone before passive collection starts
- verify the home shell shows the ready state
- verify map tiles load
- verify Stats and Settings open
- verify delete-local-data control is visible but do not use it before the first drive

## Required Drive Scenarios

Run these on internal builds before inviting broader testers:

1. Smooth arterial drive
   - 10–15 minutes
   - steady 40–60 km/h
   - expected result: accepted readings, no pothole spam
2. Rough road / patched surface
   - 5–10 minutes
   - mixed roughness but not obvious potholes
   - expected result: elevated roughness without pathological spikes
3. Known pothole or strong road defect
   - 1–3 clean passes
   - safe legal speed only
   - expected result: pothole or very-rough classification appears plausibly
4. Stop-and-go urban drive
   - several lights / intersections
   - expected result: stopped periods do not create bogus readings
5. Privacy-zone departure / arrival
   - leave from home-like zone and return
   - expected result: no locally visible contribution inside the protected area
6. Background continuity check
   - lock screen during drive
   - optionally switch away from app before movement starts
   - expected result: collection resumes/survives within documented limits short of force-quit

## Optional Stress Scenarios

Use when touching the relevant subsystem:

- downtown / poor GPS canyon
- warm device / thermal pressure
- phone mounted vs loose in cupholder
- short trips under 5 minutes
- intermittent network and delayed upload drain
- delete-local-data after a drive, then re-open Stats

## During-Drive Rules

- do not interact with the phone while driving
- no manual pothole prompts or photo capture in MVP
- if a tester needs to note a location, have a passenger do it or record it after stopping
- do not disable privacy zones “just to see more data”
- if the app appears stuck, finish the drive safely first and note the time rather than troubleshooting on the road

## What To Record

For every drive:

- tester name or nickname
- device model
- iOS version
- app build number / git commit if sideloaded
- backend target:
  - local
  - staging
  - production
- route summary
- approximate duration
- expected roughness profile:
  - smooth
  - mixed
  - rough
  - pothole present
- whether privacy zones were crossed
- whether the phone was mounted, pocketed, or loose

## Post-Drive Verification

Immediately after each run:

- open Stats
- confirm accepted readings increased plausibly
- confirm privacy-filtered count increased if the drive crossed a protected zone
- confirm pending uploads either drain or remain queued with an understandable state
- confirm the local dashed-drive overlay appears before upload and disappears after successful upload
- if pointing at staging/local backend:
  - verify `/stats`
  - verify `/segments/{id}` for a touched segment if known
  - verify quality tile presence in the test area

## Bug Report Template

Capture every issue in this shape:

```text
Title:
Build:
Device / iOS:
Backend target:
Scenario:
Expected:
Observed:
Time window:
Location / road context:
Was a privacy zone involved?:
Was the app foregrounded, backgrounded, or lock-screened?:
Screenshots / screen recording:
Relevant logs / xcresult / backend request id:
```

## Evidence To Attach

When a run looks wrong, gather as much of this as possible:

- app screenshot or screen recording
- approximate timestamp of the event
- backend request ID if surfaced
- relevant simulator or device console logs
- if reproducible, export a sensor CSV and add it to the harness corpus

If a bug cannot be reduced to a simulator harness fixture, it is not fully closed.

## Go / No-Go Gates For Wider Internal Dogfood

Do not expand tester count until these are true:

- no crashes across 5+ internal drives
- privacy-zone behavior looks correct in at least two separate home/work-style scenarios
- one known pothole route produces believable output
- one smooth route stays smooth
- uploads succeed without manual intervention on at least two devices
- no forbidden fields appear in backend logs, `os_log`, or Sentry events

## Manual Follow-Ups Still Required

These remain human-only even after the repo-side prep is complete:

- Apple signing / provisioning
- actual on-device installation
- TestFlight distribution
- physical driving
- App Store Connect privacy-label submission

This doc reduces the remaining human work to execution and evidence capture rather than ad hoc decision-making.
