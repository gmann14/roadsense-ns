# RoadSense NS — Product Spec

*Draft: 2026-03-22*
*Updated: 2026-03-23 (stress-tested)*
*Status: Spec*

---

## Overview

An iOS app that passively collects road quality data using your phone's accelerometer while you drive. Aggregates data into a public heat map showing road roughness scores and pothole locations. Start hyper-local (Halifax), make it open-source, and eventually offer municipal dashboards.

**Working name:** RoadSense NS (or PaveScore, BumpMap, RoadPulse — TBD)

---

## Problem

Roads in Nova Scotia are rough. Municipalities know some roads are bad but lack continuous, data-driven prioritization. Current road assessments cost $80-170/mile using dedicated survey vehicles. A passive crowdsourced approach could provide continuous monitoring at near-zero cost.

---

## Target Users

### Drivers (data contributors)
- Nova Scotia drivers who care about road quality
- Community-minded people who want to "do something" about potholes
- Fleet drivers (delivery, municipal vehicles) who cover lots of ground

### Data consumers (future)
- Municipal public works departments
- Provincial Department of Public Works (NS maintains 90% of roads)
- Insurance companies
- Navigation/fleet management services

---

## Core Features (MVP)

### 1. Passive Background Collection
- Detect driving via CMMotionActivityManager (iOS activity recognition)
- When driving detected AND speed > 15 km/h, start collecting:
  - Accelerometer data (z-axis primarily, sampled at 50Hz)
  - GPS coordinates (sampled at 1Hz — battery optimization)
  - GPS horizontal accuracy (for quality filtering)
  - Speed and heading/bearing (from GPS)
  - Timestamp
- All collection is automatic — user just installs the app and drives
- Discard readings where `CLLocation.horizontalAccuracy > 20m` (urban canyon / poor GPS)
- Discard readings where speed < 15 km/h (engine vibration dominates) or > 160 km/h (implausible)

### 2. Road Roughness Scoring
- Process accelerometer data into roughness scores per GPS reading (point-based)
- **On-device: upload point readings (lat, lng, roughness, speed, heading, timestamp)**
- **Server-side: assign points to road segments** (the server owns the road network and segment boundaries — this eliminates segment alignment bugs and removes the need to ship road geometry to the device)
- Road segments are ~50m sections derived from OSM
- Score each section using simplified IRI (International Roughness Index):
  - Smooth (green): < 0.3 g RMS
  - Fair (yellow): 0.3 - 0.6 g RMS
  - Rough (orange): 0.6 - 1.0 g RMS
  - Very rough / pothole (red): > 1.0 g RMS
- Aggregate multiple passes from multiple users for reliability
- **Known feature filtering:** Cross-reference with OSM tags to suppress false positives at speed bumps (`traffic_calming=bump`), railroad crossings (`railway=level_crossing`), and unpaved roads (`surface=gravel/unpaved`)

### 3. Phone Orientation Handling
- Use `CMDeviceMotion.gravity` to determine the gravity vector direction relative to the device
- Rotate the raw accelerometer reading into a consistent Earth-frame reference (vertical = true up)
- This allows accurate z-axis (vertical) isolation regardless of phone position (pocket, mount, seat, purse)

### 4. Heat Map Visualization
- Interactive map showing road quality as colored road overlays
- Green -> red gradient based on roughness score
- Tap a road segment -> see score, number of data points, last updated
- Filter by date range
- **Local data rendered immediately** from SwiftData (user sees their own drives before upload/server processing — critical for first-drive retention)
- Local data visually distinguished from community data (e.g., "Your drives" toggle or different line styling)
- **Vector tile rendering** (not GeoJSON) for smooth performance at all zoom levels
- Zoom-level filtering: at zoom < 12, show only major roads; at zoom 12-14, add tertiary; at zoom 14+, show all roads

### 5. Cold Start / Empty Map Experience
- Empty regions show the base map with no road overlays
- Banner: "No road quality data in this area yet. Drive here to start mapping!"
- Show personal driving stats prominently: "You've mapped X km of Halifax roads"
- Coverage percentage for the user's municipality
- Segments with < 3 unique contributors shown as "low confidence" with dashed/faded styling

### 6. Privacy Zones
- User defines home/work radius (default **500m**)
- Radius options: 250m, 500m, 1km, 2km
- No data collected within privacy zones
- Zone center is never stored server-side — only a geofence checked on-device
- Strava-style implementation: randomized offset (50-100m) applied to zone center to prevent triangulation from data gaps
- **Partial overlap handling:** If a GPS point falls within any privacy zone, drop that individual reading (not the entire segment — segment assignment happens server-side)
- **Edge case:** If a user's entire commute falls within zones, show a notice: "Your privacy zones cover your recent route — no data was contributed. Consider adjusting your zone radius."

### 7. Data Upload
- Batch upload processed data when on WiFi (default)
- **Optional cellular upload toggle** (default OFF) — for users who rarely connect to WiFi
- Upload in batches of **1,000 readings max per request** with retry logic and resume from last successful batch
- Only upload: GPS point, roughness score, heading, speed, GPS accuracy, timestamp, device_token
- Never upload raw GPS tracks or continuous location data
- All data anonymized before upload — device token is hashed server-side
- **Upload failure handling:** Exponential backoff retry (1s, 2s, 4s, 8s, max 5 retries). Surface persistent failures to user in Settings ("X readings pending upload").
- **Local data retention:** Cap at 100MB or 30 days, whichever comes first. FIFO deletion of oldest processed data. Notify user if data is being dropped.

### 8. Road Repair / Pothole Expiry
- **Automatic detection:** When the most recent N readings (e.g., 5) from 2+ unique contributors show "smooth" for a previously "rough" segment, apply accelerated recency weighting to bring the score down faster
- **Pothole expiry:** If no pothole spikes are detected at a flagged location for 10+ readings from 3+ contributors, auto-remove the pothole marker. Add `last_confirmed_at` timestamp to pothole records — expire after 90 days without confirmation.
- **User report (post-MVP):** "This road was repaired" button on segment detail — flags the segment for accelerated score recalculation on next readings

---

## Permission Strategy

### Progressive Permission Flow
iOS best practice: don't request "Always" location on first launch (high denial rate).

1. **First launch:** Request "When In Use" location + Motion & Fitness
2. **After first successful drive (foreground):** Show value ("You just mapped 12 km of roads!"), then explain why "Always" permission enables passive background collection
3. **Prompt for "Always" upgrade** with clear justification

### Degraded Permission States

| Permission State | App Behavior |
|---|---|
| Motion denied | Fall back to GPS-only driving detection (speed > 15 km/h = likely driving). Show banner explaining reduced accuracy. |
| Location "When In Use" only | Foreground-only collection. Persistent banner: "Enable 'Always' location for passive background collection" with Settings button. |
| Location denied entirely | App cannot collect data. Show onboarding-style screen explaining why location is needed, with Settings button. Map browsing still works. |
| Precise Location off (iOS 14+) | Approximate location makes segment matching impossible. Show alert explaining precise location is required for road quality mapping. |
| Permissions revoked mid-session | Detect via `CLLocationManagerDelegate` and gracefully stop collection. Show notification explaining data collection has paused. |

---

## Background Processing

### Driving Detection
```swift
let activityManager = CMMotionActivityManager()
activityManager.startActivityUpdates(to: queue) { activity in
    if activity?.automotive == true {
        startCollection()
    } else {
        stopCollection()
    }
}
```

### Background Modes Required
- **Location updates** (`UIBackgroundModes: location`) — keeps app alive for GPS + accelerometer
- **Background processing** — for batch data upload
- Set `allowsBackgroundLocationUpdates = true` and `pausesLocationUpdatesAutomatically = false`
- Show blue status bar indicator when tracking in background
- Provide clear start/stop controls (Apple requires user controls for background location)

### App Lifecycle Edge Cases

| Scenario | Behavior |
|---|---|
| App force-quit by user | iOS will NOT restart background location. Register for `significantLocationChange` as a relaunch mechanism. |
| iOS kills app for memory | Same as force-quit — `significantLocationChange` relaunches. |
| Phone reboot | App must be manually reopened. Send local notification after 48 hours of no data collection: "RoadSense isn't collecting — tap to resume." |
| iOS Low Power Mode enabled | Detect via `ProcessInfo.isLowPowerModeEnabled`. Reduce accelerometer to 25Hz, increase GPS interval to every 3 seconds. |
| Thermal throttle (phone on dashboard in sun) | Detect via `ProcessInfo.thermalState`. At `.serious` or `.critical`, pause collection and notify user. |
| Data buffer on crash | Persist accelerometer buffer to disk incrementally (every 60 seconds), not just in-memory. Max data loss on crash: 60 seconds of readings. |
| "Pause collection" | Add explicit pause/resume toggle (visible in app and as notification action). Pauses without changing settings. |

### Battery Optimization Strategy
1. **Use `kCLLocationAccuracyNearestTenMeters`** instead of `kCLLocationAccuracyBest` — 30-40% less GPS power draw, sufficient for 50m segments
2. **GPS sampling:** 1Hz is sufficient. Reduce to every 3s in battery saver mode.
3. **Adaptive duty cycling:** If driving on a road with >10 existing high-confidence readings, reduce sampling to every 5th second
4. **Batch processing:** Buffer accelerometer data, process in batches every 5 minutes
5. **WiFi-only upload by default:** Never upload over cellular unless user opts in
6. **Pause GPS at low speeds:** When speed drops below 5 km/h (stopped at light), reduce GPS accuracy temporarily

### Expected Battery Impact
- **Realistic estimate: 8-12% per hour** (varies by GPS signal quality, device age)
- Accelerometer only: ~1-2% per hour (negligible)
- Accelerometer + GPS at 1Hz: ~8-12% per hour
- For reference: Google Maps navigation uses ~10-15% per hour
- **Communicate honestly:** "RoadSense uses about 10% battery per hour of driving — similar to a navigation app, but you don't need your screen on."

---

## Data Quality Filtering

### False Positive Mitigation

| Source | Detection Method | Action |
|---|---|---|
| Speed bumps | OSM tag `traffic_calming=bump` at location | Suppress pothole flag; optionally exclude from roughness scoring |
| Railroad crossings | OSM tag `railway=level_crossing` at location | Same as speed bumps |
| Construction zones | Temporary — no reliable detection | Accept readings; they will age out via recency weighting |
| Unpaved/gravel roads | OSM tag `surface=gravel/unpaved` | Show in separate category ("Unpaved — not scored for roughness") or adjust thresholds significantly upward |
| Parking lots | OSM tag `amenity=parking` / `highway=service` + `service=parking_aisle` | Exclude readings matched to parking area segments |
| Braking events | Sudden deceleration without the "dip then spike" pothole pattern | Z-axis RMS stays high but lacks the characteristic pothole waveform. Filter by requiring dip-spike pattern. |
| Engine vibration (idle/low speed) | Speed < 15 km/h | Discard readings |
| Poor GPS fix | `horizontalAccuracy > 20m` | Discard readings |
| Phone orientation | Uncompensated gravity vector | Apply `CMDeviceMotion.gravity` rotation to isolate true vertical acceleration |

### Speed Normalization
- Apply speed correction factor to roughness RMS (calibrated against known surfaces)
- At very low speeds (15-30 km/h), readings are noisier — downweight in aggregation
- At highway speeds (100+ km/h), suspension dynamics change — apply highway-specific correction factor
- **Do not claim absolute IRI values** — report relative roughness index that correlates with IRI

---

## Tech Stack

### iOS App (Swift)
- **SwiftUI** — UI framework
- **Core Motion** — CMMotionActivityManager (driving detection), CMDeviceMotion (gravity-compensated acceleration)
- **Core Location** — GPS coordinates, speed, heading, horizontal accuracy
- **Mapbox Maps SDK for iOS** — map display with road quality overlays
  - `LineLayer` with data-driven styling for road segment coloring
  - Vector tile source (not GeoJSON) for performance at scale
  - Metal-accelerated rendering, offline maps support
  - Free up to 50K monthly active users
- **SwiftData** — local data persistence (processed readings, upload queue, personal stats)
- **Background Modes** — location updates + motion processing

### Backend
- **Supabase** — PostgreSQL + PostGIS
  - PostGIS for spatial queries (assign readings to road segments)
  - Row-level security for data isolation
  - **Budget for Pro tier ($25/month)** — free tier's 500MB database limit will be hit within 2-3 months of active use
- **PostgreSQL stored procedures** for data ingestion (NOT Edge Functions for spatial operations — Edge Functions have a 150ms CPU limit that spatial batch processing will exceed)
  - Supabase Edge Function acts as thin validation/auth layer
  - Calls a `plpgsql` stored procedure that performs batch map matching and aggregation
- **Partition `readings` table by month** from day one (cheap to implement, painful to retrofit)

### Road Segment Matching (Server-Side)
- **OpenStreetMap road network** — import NS road data into PostGIS via `osm2pgsql`
- **Segment OSM ways into ~50m pieces** during import using `ST_Segmentize` + `ST_Dump`
- **Map matching pipeline:**
  1. KNN nearest-neighbor: `ORDER BY geom <-> point LIMIT 3` (get 3 candidates)
  2. Filter by heading: compare GPS bearing with segment bearing via `ST_Azimuth` (eliminates parallel roads)
  3. Filter by speed: discard candidates incompatible with observed speed (e.g., 100 km/h reading can't be on a residential street)
  4. Filter by distance: reject if nearest match > 20m
  5. If no match passes all filters, discard the reading
- **Municipality attribution:** Spatial join with Statistics Canada census boundary polygons (OSM ways don't reliably carry municipality info)
- **OSM data refresh:** Quarterly manual re-import for MVP. Stable segment identity via `(osm_way_id, segment_index)` natural key.

### Vector Tile Serving
- **Serve Mapbox Vector Tiles (MVT)** from PostGIS using `ST_AsMVT` endpoint
- Pre-rendered tiles at standard zoom levels, cached aggressively (1-hour TTL)
- `ST_Simplify` geometry at low zoom levels
- Alternative: use Martin (Rust-based tile server) if Supabase function performance is insufficient

### Web Dashboard (Phase 2+)
- **Next.js** — municipal viewer
- **Mapbox GL JS** — road quality overlay (consumes same vector tiles)
- **Vercel** — hosting

---

## Architecture

```
┌──────────────────────────────────────────────────────┐
│                    iOS App                            │
│                                                       │
│  ┌───────────┐  ┌──────────────┐  ┌──────────────┐  │
│  │ Activity   │  │ Accel + GPS  │  │ Privacy      │  │
│  │ Detection  │──│ Collection   │──│ Zone Filter  │  │
│  │ (driving?) │  │ (50Hz + 1Hz) │  │ (on-device)  │  │
│  └───────────┘  └──────┬───────┘  └──────────────┘  │
│                         │                             │
│                         ▼                             │
│  ┌───────────────────────────────────────────────┐   │
│  │       On-Device Processing                    │   │
│  │                                                │   │
│  │  1. Rotate accel to Earth frame (gravity comp)│   │
│  │  2. High-pass filter (Butterworth, 0.5Hz)     │   │
│  │  3. Compute roughness RMS per ~50m of travel  │   │
│  │  4. Strip privacy zone readings               │   │
│  │  5. Quality filter (speed, GPS accuracy)      │   │
│  │  6. Store as POINT readings (SwiftData)        │   │
│  │  7. Render local data on map immediately       │   │
│  └──────────────────┬───────────────────────────┘   │
│                      │ (WiFi batch upload, 1K/batch)  │
└──────────────────────┬──────────────────────────────┘
                       │
                       ▼
┌──────────────────────────────────────────────────────┐
│              Supabase Backend                         │
│                                                       │
│  ┌──────────────────────────────────────────────┐    │
│  │  Edge Function: /api/upload-readings          │    │
│  │  - Validate data format + plausibility        │    │
│  │  - Rate limit (10 batches/IP/hr,              │    │
│  │    50 batches/device/day)                     │    │
│  │  - Geographic bounds check (NS only)          │    │
│  │  - Hash device token                          │    │
│  │  - Call stored procedure for batch processing │    │
│  └──────────────────┬───────────────────────────┘    │
│                      │                                │
│  ┌──────────────────▼───────────────────────────┐    │
│  │  PostgreSQL Stored Procedure                  │    │
│  │  - Batch spatial match (KNN + heading filter) │    │
│  │  - Insert into readings (partitioned monthly) │    │
│  │  - Incremental aggregate update               │    │
│  └──────────────────┬───────────────────────────┘    │
│                      │                                │
│  ┌──────────────────▼───────────────────────────┐    │
│  │  PostgreSQL + PostGIS                         │    │
│  │                                                │    │
│  │  road_segments: geom, osm_way_id, road_type   │    │
│  │  segment_aggregates: avg_score, readings, etc. │    │
│  │  readings: segment_id, rms, speed, heading, ts │    │
│  │  pothole_reports: location, magnitude, status  │    │
│  └──────────────────┬───────────────────────────┘    │
│                      │                                │
│  ┌──────────────────▼───────────────────────────┐    │
│  │  Vector Tile Endpoint: /api/tiles/{z}/{x}/{y} │    │
│  │  - ST_AsMVT from segment_aggregates           │    │
│  │  - 1-hour cache TTL                           │    │
│  │  - Zoom-level filtering + geometry simplify   │    │
│  └──────────────────────────────────────────────┘    │
└──────────────────────────────────────────────────────┘
                       │
                       ▼
┌──────────────────────────────────────────────────────┐
│          Web Map / Dashboard (Phase 2)                │
│          Next.js + Mapbox GL JS                       │
└──────────────────────────────────────────────────────┘
```

---

## Roughness Scoring Algorithm

### Approach: Simplified IRI from Accelerometer

The International Roughness Index (IRI) is the standard for road quality (measured in m/km — <2 good, 2-4 fair, 4-6 poor, >6 very poor). Full IRI requires a calibrated vehicle using a quarter-car model simulation at 80 km/h. **Do not attempt to compute true IRI from smartphones.** Instead, compute a relative roughness index (acceleration RMS, speed-normalized) and map it to IRI-like categories. Crowdsourced averaging across many users/vehicles naturally compensates for individual device and vehicle variation.

### Algorithm (on-device)

```
For each ~50m of GPS travel distance:

1. Collect accelerometer data via CMDeviceMotion at 50Hz
2. Rotate acceleration vector to Earth frame using gravity vector
   - vertical_accel = raw_accel projected onto gravity direction
   - This handles any phone orientation (pocket, mount, seat)
3. Apply high-pass filter (Butterworth, cutoff ~0.5Hz)
   - Removes gravity component and vehicle vibration baseline
4. Compute RMS (root mean square) of filtered vertical acceleration
5. Normalize by speed:
   - Apply speed correction factor (calibrated against known surfaces)
   - Readings at 15-30 km/h get lower confidence weight
   - Highway correction factor for > 100 km/h
6. Quality checks:
   - GPS accuracy must be < 20m
   - Speed must be 15-160 km/h
   - Discard if any check fails
7. Output: (lat, lng, roughness_rms, speed, heading, gps_accuracy, timestamp)
8. Store locally (SwiftData) for immediate map rendering + later upload
```

### Roughness Categories (thresholds need real-world calibration)

```
< 0.3 g RMS: Smooth (green)
0.3 - 0.6 g: Fair (yellow)
0.6 - 1.0 g: Rough (orange)
> 1.0 g:     Very rough / pothole (red)
```

### Pothole Detection (Spike Detection)

```
In addition to segment RMS, detect individual pothole events:

1. Monitor vertical acceleration for sudden spikes: |z| > 2.0g within 100ms window
2. Require "dip then spike" pattern (tire drops into hole, then bounces)
   - This distinguishes potholes from braking events
3. Record: location, magnitude, heading, timestamp
4. Server-side: multiple users reporting spikes at same location = confirmed pothole
5. Server-side: cross-reference with OSM speed bumps / railroad crossings
   - Suppress pothole flags at known features
```

### Aggregation (backend)

```
For each road segment (incremental, on new readings):

1. Insert new readings with segment_id assigned by spatial matching
2. Incrementally update segment_aggregates:
   - Running weighted average (recency-weighted)
   - Cap each device_token_hash at 3 readings per segment per week
     (prevents power-user dominance)
3. Outlier handling: readings > 3 std dev from segment mean are downweighted
4. Confidence score based on unique contributors:
   - < 3 unique device hashes: Low confidence (dashed/faded on map)
   - 3-10: Medium
   - > 10: High
5. Decay: readings > 6 months old get progressively downweighted
6. Road repair detection: if recent readings (last 5, from 2+ contributors)
   shift dramatically smoother, apply accelerated recency weighting

Nightly batch job:
- Full recompute of aggregates with outlier trimming (top/bottom 10%)
- Pothole expiry check (no confirmation in 90 days -> remove)
- Refresh vector tile cache
```

---

## Data Model

### road_segments (static — populated from OSM import)
```sql
CREATE TABLE road_segments (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  osm_way_id BIGINT NOT NULL,
  segment_index INTEGER NOT NULL, -- position along the OSM way
  geom GEOMETRY(LINESTRING, 4326) NOT NULL,
  length_m NUMERIC(8,1),
  road_name TEXT,
  road_type TEXT, -- highway, residential, etc.
  surface_type TEXT, -- paved, gravel, unpaved (from OSM)
  municipality TEXT,
  has_speed_bump BOOLEAN DEFAULT false, -- from OSM traffic_calming tags
  has_rail_crossing BOOLEAN DEFAULT false, -- from OSM railway tags
  created_at TIMESTAMPTZ DEFAULT now(),
  UNIQUE(osm_way_id, segment_index) -- stable identity across re-imports
);

CREATE INDEX idx_segments_geom ON road_segments USING GIST (geom);
CREATE INDEX idx_segments_municipality ON road_segments (municipality);
CREATE INDEX idx_segments_way ON road_segments (osm_way_id);
```

### segment_aggregates (derived — updated incrementally + nightly batch)
```sql
CREATE TABLE segment_aggregates (
  segment_id UUID PRIMARY KEY REFERENCES road_segments(id),
  avg_roughness_score FLOAT,
  roughness_category TEXT, -- smooth, fair, rough, very_rough
  total_readings INTEGER DEFAULT 0,
  unique_contributors INTEGER DEFAULT 0,
  confidence TEXT DEFAULT 'low', -- low, medium, high
  last_reading_at TIMESTAMPTZ,
  pothole_count INTEGER DEFAULT 0,
  trend_direction TEXT, -- improving, stable, worsening
  updated_at TIMESTAMPTZ DEFAULT now()
);

CREATE INDEX idx_aggregates_score ON segment_aggregates (avg_roughness_score DESC);
CREATE INDEX idx_aggregates_category ON segment_aggregates (roughness_category);
```

### readings (append-only, partitioned by month)
```sql
CREATE TABLE readings (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  segment_id UUID REFERENCES road_segments(id),
  batch_id UUID NOT NULL, -- for idempotent uploads
  device_token_hash TEXT NOT NULL, -- hashed on server, for dedup + contributor counting
  roughness_rms FLOAT NOT NULL,
  speed_kmh NUMERIC(5,1) NOT NULL,
  heading_degrees NUMERIC(5,1), -- for map matching validation
  gps_accuracy_m NUMERIC(5,1),
  is_pothole BOOLEAN DEFAULT false,
  pothole_magnitude FLOAT,
  recorded_at TIMESTAMPTZ NOT NULL,
  uploaded_at TIMESTAMPTZ DEFAULT now()
) PARTITION BY RANGE (recorded_at);

-- Create monthly partitions (example)
CREATE TABLE readings_2026_03 PARTITION OF readings
  FOR VALUES FROM ('2026-03-01') TO ('2026-04-01');

CREATE INDEX idx_readings_segment ON readings (segment_id);
CREATE INDEX idx_readings_recorded ON readings (recorded_at DESC);
CREATE INDEX idx_readings_batch ON readings (batch_id);
CREATE INDEX idx_readings_device ON readings (device_token_hash);
```

### pothole_reports
```sql
CREATE TABLE pothole_reports (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  segment_id UUID REFERENCES road_segments(id),
  geom GEOMETRY(POINT, 4326) NOT NULL,
  magnitude FLOAT NOT NULL,
  first_reported_at TIMESTAMPTZ NOT NULL,
  last_confirmed_at TIMESTAMPTZ NOT NULL,
  confirmation_count INTEGER DEFAULT 1,
  unique_reporters INTEGER DEFAULT 1,
  status TEXT DEFAULT 'active', -- active, expired, resolved
  created_at TIMESTAMPTZ DEFAULT now()
);

CREATE INDEX idx_potholes_geom ON pothole_reports USING GIST (geom);
CREATE INDEX idx_potholes_segment ON pothole_reports (segment_id);
CREATE INDEX idx_potholes_status ON pothole_reports (status);
```

### Privacy: No users table for MVP
- App generates a random device token (rotated monthly, for dedup only)
- Token is hashed server-side (SHA-256), never stored in readable form
- Used for: unique contributor counting, rate limiting, per-device reading caps
- **Note:** Monthly rotation means one device appears as multiple contributors over time. Accept this as approximate — contributor counts are directionally useful, not exact.
- **Retention policy:** Delete readings older than 6 months (aggregates are preserved). Archive to cold storage if needed for trend analysis.

---

## API Design

### MVP Endpoints

| Endpoint | Method | Purpose |
|---|---|---|
| `POST /api/upload-readings` | POST | Batch upload readings (max 1,000 per request). Validates, rate limits, hashes device token, calls stored procedure. |
| `GET /api/tiles/{z}/{x}/{y}.mvt` | GET | Vector tiles for map rendering. Returns MVT with segment geometry + roughness score + confidence. Cached 1 hour. |
| `GET /api/segments/{id}` | GET | Single segment detail: score, confidence, reading count, trend, pothole count, last 6 months history. |
| `GET /api/potholes?bbox=...` | GET | Pothole markers within bounding box. For map overlay layer. |
| `GET /api/stats` | GET | Global stats: total km mapped, total readings, segments scored. |
| `GET /api/health` | GET | Health check. |

### Post-MVP Endpoints

| Endpoint | Purpose |
|---|---|
| `GET /api/segments/worst?municipality=...` | Top N worst segments. Powers "worst roads" reports. |
| `GET /api/segments/export?format=geojson&bbox=...` | GeoJSON/KML export for a region. |
| `POST /api/report-repair` | User-reported road repair. Flags segment for accelerated recalculation. |

### Rate Limiting & Abuse Protection

- **Per IP:** 10 batch uploads per hour
- **Per device hash:** 50 batches per day
- **Plausibility checks:**
  - Reject readings outside Nova Scotia bounding box
  - Reject readings with timestamps in the future
  - Reject batches with impossible speeds between consecutive readings (teleportation check)
  - Reject roughness values outside physically possible range (> 10g)
- **Statistical outlier detection:** Readings > 3 std dev from segment mean (based on other contributors) are downweighted, not auto-discarded
- **Minimum contributor threshold:** Segment scores not publicly displayed until 3+ unique device hashes have contributed
- **Future:** iOS DeviceCheck attestation if abuse becomes a real problem (proves real Apple device without identifying user)

---

## Design System v2 (planning — 2026-04-20)

> Full audit + rationale: [.context/design-audit.md](../.context/design-audit.md). This section captures the *contract* for implementation. The audit captures the *why*.

**North star:** *Apple-grade clarity with the quiet authority of a public-infrastructure tool.* Simple, clear, beautiful — the map is the hero, chrome yields to content, and contribution moments are quietly celebrated.

### Brand tokens (single source of truth)

A token map lives in `docs/design-tokens.md` (to be generated) and is consumed by both iOS (`Resources/DesignTokens.swift`) and web (`apps/web/app/tokens.css`). The existing duplicated palette (`MapColorPalette.swift` hexes + `globals.css` CSS vars) will be replaced with generated files so iOS and web can never drift.

**Color**
| Token | Light | Dark |
|---|---|---|
| `canvas` | `#F6F1E8` | `#0B1419` |
| `ink` | `#0F1E26` | `#EEF2F4` |
| `muted` | `#55707D` | `#90A4AE` |
| `deep` (brand) | `#0E3B4A` | `#0E3B4A` |
| `signal` (accent, user moments) | `#E9A23B` | `#E9A23B` |

**Roughness ramp (unified iOS + web, colour-blind tested)**
| Category | Color |
|---|---|
| Smooth | `#2F8F6D` |
| Fair | `#E2B341` |
| Rough | `#D97636` |
| Very rough | `#C04242` |
| Unpaved / unscored | `#8A9AA2` |

**Typography**
- Web: **Fraunces** (display), **Manrope** (UI), **IBM Plex Mono** (numerals).
- iOS: **SF Pro Rounded** (display numerals), **SF Pro** (UI), **SF Mono** (tabular data).
- Scale: `display 40/44`, `title 28/32`, `headline 20/26`, `body 16/24`, `callout 15/20`, `caption 13/16`, `eyebrow 11/14 uppercase +0.12em`, `number-lg 48` (monospaced).

**Space / radius**
- Spacing: `4 · 8 · 12 · 16 · 20 · 24 · 32 · 48` — no other values.
- Radii: `8 · 14 · 20 · 28`.

**Motion**
- `standard` — cubic-bezier(0.2, 0, 0, 1) @ 220 ms (UI state changes).
- `enter` — cubic-bezier(0.16, 1, 0.3, 1) @ 360 ms (sheets, drawers).
- `map` — linear @ 600 ms (map data settle).
- Celebration pulse — 900 ms spring on the Signal accent, fires only on personal-contribution moments. All motion collapses to cross-fade under Reduce Motion.

**Iconography**
- Phase 1: SF Symbols (iOS) + inline SVGs (web), mapped to a shared 16-name vocabulary.
- Phase 2 (post Apple approval): custom 24×24 / 1.5px-stroke set.

### Screen redesign scope (v2)

**iOS**
1. **Map (home)** — remove center-screen overlay; replace three-panel glass chrome with one bottom card (peek / expanded), compact top bar, `…` menu, "my drives" toggle.
2. **Segment detail** — editorial infographic: hero score tile, real 6-month sparkline (driven by `scoreLast30D` / `score30To60D`), confidence filled-dots, promoted primary CTA.
3. **Onboarding** — 4-card `TabView` flow (welcome → permissions → privacy zones → ready) with illustration, progress dots, primary + secondary actions.
4. **Settings** — grouped card sections with inline status chips (recording, zone count, sync); "Your data" mini-dashboard.
5. **Stats** — contribution hero: km-mapped medallion, 14-day bar strip, milestones list with progress, shareable card stub.
6. **Privacy zones** — full-screen Mapbox surface with detented bottom sheet (20 / 60 / 100%), FAB to add, slider at spec-defined 250 / 500 / 1000 / 2000 m ticks, haptic tick on radius change.

**Web**
1. **Home / Explorer** — editorial header *above* the map (headline + lede + inline trust strip + mode switcher + search); map becomes full-width hero; legend floats as a collapsible chip; segment drawer slides in as an overlay (does not shrink the map); URL state preserved.
2. **Worst Roads** — editorial ranked list with mini bar chart per row, large rank numbers, methodology as bottom banner, CSV export button.
3. **Municipality page** — adds a municipality hero above the shared explorer (km, roads scored, most improved / worsened).
4. **Methodology / Privacy** — long-form editorial with numbered sections, inline diagrams, serif-led typography.

### Accessibility guardrails (must not regress)

- Every text-on-tint combo ≥ 4.5:1 contrast; ramp colors verified against `canvas` and `deep` backgrounds.
- Existing `dynamicTypeSize.isAccessibilitySize` branching preserved and extended to new cards.
- Sparklines, medallions, and bars expose an `accessibilityLabel` sentence summary.
- `prefers-reduced-motion` collapses every spring / slide to a ≤ 200 ms fade on both platforms.
- Web maintains skip-link and focus-visible behaviour; iOS maintains current `accessibilityIdentifier` coverage for UI tests.

### Performance guardrails

- Map rendering continues to use vector tiles only (no GeoJSON overlays added for visuals).
- First-run illustration ships as an SVG ≤ 8 KB (iOS) / inline SVG (web).
- Web LCP element remains server-rendered (the editorial header); the map hydrates after.
- Token CSS is inlined in `<head>` for zero-flash styling.

### Implementation sequence

1. **Phase A — Tokens & foundation** (iOS + web in parallel): write `docs/design-tokens.md`; generate iOS `DesignTokens.swift` and web `tokens.css`; swap all hardcoded hex usages.
2. **Phase B — iOS screens** in order: Map → Onboarding → Segment detail → Stats → Settings → Privacy zones.
3. **Phase C — Web screens** in order: Home/Explorer → Worst Roads → Municipality → Methodology/Privacy.
4. **Phase D — Polish**: motion, empty states & first-run illustrations, cross-platform screenshot QA, accessibility audit, and a final rewrite of the UI/UX Design section below to match shipped state.

### Open questions (resolve before Phase B)

- Confirm unified roughness ramp (both platforms shift slightly; field-test users will see colors change).
- Scope of "Signal" accent celebration (any milestone, or km/segments only).
- App icon redesign — in this pass or later.
- Custom icon set — now (blocks Phase B finish) or post-launch.

---

## UI/UX Design

The app should feel **simple, beautiful, and modern** — approachable for non-technical users. Think Strava's polish applied to civic tech. Use the `frontend-design` skill for implementation.

### Design Principles
- Minimal chrome, maximum map
- Data visualization should feel alive (subtle animations on score updates, smooth color transitions)
- Progressive disclosure: simple surface, detail on tap
- Dark mode support from day one
- Accessibility: VoiceOver support, Dynamic Type, sufficient color contrast on map overlays

### Main View (Map)
```
┌─────────────────────────────────────────┐
│  RoadSense               [Recording ●]  │
│─────────────────────────────────────────│
│                                         │
│     [    MAP OF HALIFAX AREA        ]   │
│     [    with colored road overlays ]   │
│     [    ━━━ green (smooth)         ]   │
│     [    ━━━ yellow (fair)          ]   │
│     [    ━━━ red (rough)            ]   │
│     [    ● pothole markers          ]   │
│     [                               ]   │
│                                         │
│─────────────────────────────────────────│
│  ┌─────────────────────────────────┐    │
│  │ Your Contributions              │    │
│  │ 142 km recorded · 67 segments   │    │
│  │ 3 potholes · Last: Today 2:30pm│    │
│  └─────────────────────────────────┘    │
└─────────────────────────────────────────┘
```

### Segment Detail (tap a road)
```
┌─────────────────────────────────────────┐
│  Barrington Street                      │
│  Spring Garden to South                 │
│─────────────────────────────────────────│
│  Roughness: ██████░░░░  Rough (0.72)    │
│  Confidence: High (34 readings)         │
│  Last updated: March 20, 2026           │
│  Potholes: 2 active                     │
│                                         │
│  Trend:                                 │
│  Jan ████████░░  0.65                   │
│  Feb █████████░  0.71                   │
│  Mar ██████████  0.72  ← getting worse  │
│                                         │
│  [Share]  [Report Repair]               │
└─────────────────────────────────────────┘
```

### Settings
```
┌─────────────────────────────────────────┐
│  Settings                               │
│─────────────────────────────────────────│
│                                         │
│  Privacy Zones                          │
│  🏠 Home          500m radius     [Edit]│
│  🏢 Work          500m radius     [Edit]│
│  + Add privacy zone                     │
│                                         │
│  Data Collection                        │
│  Auto-detect driving        [ON]        │
│  Upload on WiFi only        [ON]        │
│  Allow cellular upload      [OFF]       │
│  Battery saver mode         [OFF]       │
│  Pause collection           [OFF]       │
│                                         │
│  Upload Status                          │
│  Pending: 0 readings                    │
│  Last upload: Today, 3:15pm             │
│                                         │
│  Your Data                              │
│  Total km recorded: 142 km              │
│  Delete all local data      [Delete]    │
│                                         │
│  About                                  │
│  Privacy policy                         │
│  How it works                           │
│  Open source (GitHub)                   │
└─────────────────────────────────────────┘
```

### Offline Experience
- Mapbox offline tile packs: auto-download tiles for the user's municipality on first use
- Local data (personal drives) always visible from SwiftData
- Previously-viewed community data cached and visible
- "Offline" indicator in header when no connectivity
- Data collection continues normally (upload queues for later)

---

## Development Phases

### Phase 1: Sensor Prototype (1-2 weeks)
- [ ] Create iOS project with SwiftUI
- [ ] Implement CMMotionActivityManager driving detection
- [ ] Implement CMDeviceMotion (gravity-compensated) accelerometer collection
- [ ] Implement Core Location with `kCLLocationAccuracyNearestTenMeters`
- [ ] Implement progressive permission flow (When In Use -> Always escalation)
- [ ] Handle all degraded permission states
- [ ] Implement quality filters (speed threshold, GPS accuracy threshold)
- [ ] Log processed point readings to SwiftData
- [ ] Register for `significantLocationChange` (background relaunch)
- [ ] Implement `ProcessInfo.thermalState` and `isLowPowerModeEnabled` checks
- [ ] Drive around Halifax, verify data looks reasonable
- [ ] Implement roughness scoring (gravity-compensated z-axis RMS)
- [ ] Test battery impact — document real numbers

### Phase 2: Map Visualization (1-2 weeks)
- [ ] Mapbox integration with vector tile source architecture
- [ ] Display local data on map immediately (from SwiftData, before any backend)
- [ ] Color-coded road segments (data-driven LineLayer styling)
- [ ] Privacy zone implementation (500m default, randomized offset)
- [ ] Cold start / empty map experience with onboarding messaging
- [ ] Segment detail view (tap for score, confidence, trend)
- [ ] Basic stats screen (km recorded, segments scored)
- [ ] Offline tile pack download for user's municipality
- [ ] Zoom-level feature filtering (major roads only at low zoom)

### Phase 3: Backend + Aggregation (2-3 weeks)
- [ ] Set up Supabase with PostGIS (Pro tier)
- [ ] Import OpenStreetMap road network for NS via `osm2pgsql`
- [ ] Segment ways into 50m pieces with `ST_Segmentize`
- [ ] Spatial join with municipality boundaries (Statistics Canada)
- [ ] Import OSM feature tags (speed bumps, rail crossings, surface type)
- [ ] Build PostgreSQL stored procedure for batch map matching (KNN + heading + speed filtering)
- [ ] Implement `batch_id` for idempotent uploads
- [ ] Upload batching (1,000 readings/request, retry with exponential backoff)
- [ ] Incremental aggregation with per-device reading caps
- [ ] Nightly batch job: full recompute with outlier trimming, pothole expiry
- [ ] Vector tile endpoint (`ST_AsMVT`) with 1-hour cache
- [ ] Rate limiting and plausibility validation in Edge Function
- [ ] Map reads from backend vector tiles instead of local-only
- [ ] Monthly partition creation (automated or manual)
- [ ] Data retention policy: archive readings > 6 months

### Phase 4: Polish + Launch (1-2 weeks)
- [ ] Privacy policy (PIPEDA compliant — data is anonymized, no PII stored, consent is opt-in)
- [ ] Onboarding flow explaining what the app does + permission justifications
- [ ] "Battery saver mode" implementation (25Hz accel, 3s GPS, skip high-confidence roads)
- [ ] Upload status display in Settings (pending readings count, last upload time)
- [ ] "Delete all local data" with clear explanation (server data is anonymous, cannot be attributed back)
- [ ] App Store listing + screenshots
- [ ] TestFlight beta with friends/local community
- [ ] Open-source the repo
- [ ] Honest battery impact messaging in app and App Store description

### Phase 5: Community Launch
- [ ] Post on r/halifax, r/novascotia, local Facebook groups
- [ ] "Worst roads in Halifax" report from initial data -> pitch to local media
- [ ] Contact local cycling advocacy groups (they care about road quality)
- [ ] Approach municipal contacts informally

### Phase 6: Municipal Dashboard (future)
- [ ] Web dashboard (Next.js + Mapbox GL JS, consuming same vector tiles)
- [ ] GIS export (Shapefile, GeoJSON, KML)
- [ ] Trend analysis over time
- [ ] Automated "worst roads" reports per municipality
- [ ] Road repair tracking: integrate municipal repair schedules if available
- [ ] Fleet mode (higher frequency collection, real-time upload, vehicle type tagging)
- [ ] Android version (Kotlin, shared backend)
- [ ] Gamification: leaderboard for km contributed, badges
- [ ] iOS DeviceCheck attestation for anti-abuse

---

## Key Risks & Mitigations

| Risk | Likelihood | Mitigation |
|------|-----------|------------|
| App Store rejection for background location | MEDIUM | Progressive permission flow (When In Use first). Clear privacy justification. Blue status bar indicator. User controls. Similar apps approved. |
| Battery drain complaints | HIGH | Honest messaging (~10%/hr). Battery saver mode. Adaptive sampling. Use `kCLLocationAccuracyNearestTenMeters`. |
| Not enough users for useful data | HIGH | Hyper-local launch (Halifax only). Partner with municipal fleet vehicles. Cycling advocacy groups. Media-friendly "worst roads" report. |
| Accelerometer readings vary between vehicles | MEDIUM | Crowdsourced averaging normalizes. Per-device reading caps. Outlier trimming. Focus on relative rankings. |
| Privacy concerns (location tracking) | MEDIUM | Privacy-first design. No raw GPS stored server-side. 500m privacy zones. Anonymous contributions. Open-source. |
| False positives (speed bumps, rail crossings) | HIGH | OSM tag cross-referencing. Suppress known features. Separate unpaved road category. |
| Data poisoning / abuse | MEDIUM | Rate limiting. Plausibility checks. Min contributor threshold. Statistical outlier detection. DeviceCheck (future). |
| Map performance at scale (40K+ segments) | HIGH | Vector tiles (not GeoJSON). Zoom-level filtering. Geometry simplification. Aggressive caching. |
| Supabase Edge Function limits | MEDIUM | Spatial operations in PostgreSQL stored procedures, not Edge Functions. Batch uploads capped at 1,000 readings. |
| PIPEDA compliance | LOW | Data is anonymized before upload. No PII stored. Privacy policy reviewed. Consent is explicit (opt-in). |
| Phone on hot dashboard thermal throttle | MEDIUM | Detect `ProcessInfo.thermalState`. Pause collection at `.serious`/`.critical`. Notify user. |

---

## Cost Estimate

| Service | Cost |
|---------|------|
| Apple Developer Account | $99/year |
| Mapbox Maps SDK | Free up to 50K MAU |
| Supabase Pro | $25/month ($300/year) |
| Vercel (web dashboard, future) | Free tier |
| Domain | ~$12/year |
| Martin tile server or Fly.io (if needed) | ~$5/month |
| **Total** | **~$470/year** |

---

## Open Questions (Resolved)

1. **Swift vs React Native?** → **Swift.** Core value is background sensor collection — fundamentally native. React Native adds bridge latency and you'd write native code anyway.
2. **Start with Lunenburg or Halifax?** → **Halifax.** More users, more media potential, more impact.
3. **Pothole button in MVP?** → **No.** MVP is fully passive. Add pothole button later (only usable when stopped — liability).
4. **Open-source from day one?** → **Yes.** Builds trust, civic tech ethos, strongest portfolio signal.
5. **Cold start problem?** → Show personal data immediately. "Be the first to map" messaging. Coverage percentage gamification.
6. **Privacy zone default?** → **500m** (changed from 200m). Safer default, especially in low-density areas.
7. **On-device vs server-side segmentation?** → **Server-side.** Client uploads point readings. Server owns road network and segment assignment.
8. **MapKit vs Mapbox?** → **Mapbox.** Built-in heat map layers, data-driven line styling, vector tiles, offline support. MapKit would require extensive custom rendering.

---

## References

- Detailed technical research on iOS Core Motion, background processing, SmartRoadSense, MapKit vs Mapbox, PostGIS schema/queries, privacy zone implementation, React Native vs Swift, and IRI calculation: [research-supplement.md](research-supplement.md)
