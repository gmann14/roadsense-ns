# Road Quality Monitoring App — Research Supplement

Research conducted 2026-03-22. Covers technical feasibility, framework choices, and algorithm considerations for a crowdsourced road quality monitoring iOS app.

---

## 1. iOS Core Motion Framework

### CMMotionActivityManager for Driving Detection

CMMotionActivityManager provides automatic activity classification (walking, running, cycling, driving, stationary). iOS uses the M-series motion coprocessor to classify activities with low power overhead. The "Do Not Disturb While Driving" feature (iOS 11+) uses this same pipeline.

At low vehicle speeds, distinguishing driving from other transport is unreliable with accelerometer alone. iOS likely supplements with magnetometer data (vehicles create electromagnetic shielding) and possibly Bluetooth/CarPlay connection status.

**Key difference:** CMMotionManager (raw accelerometer/gyro) does NOT require user permission. CMMotionActivityManager (activity classification) DOES require the "Motion & Fitness" permission — iOS prompts automatically on first use.

### Accelerometer Access

- CMMotionManager provides push (handler-based) or pull (polling) access to accelerometer data
- Rates up to 100Hz are available on modern iPhones
- The M-series coprocessor handles motion data collection without waking the main CPU

### Required Permissions

| Permission | Key in Info.plist | Required For |
|---|---|---|
| Motion & Fitness | `NSMotionUsageDescription` | CMMotionActivityManager (driving detection) |
| Location Always | `NSLocationAlwaysAndWhenInUseUsageDescription` | Background GPS tracking |
| Location When In Use | `NSLocationWhenInUseUsageDescription` | Foreground GPS |
| Background Modes | `UIBackgroundModes` = `location` | Background operation |

### Battery Impact

Apple's guidance: larger update intervals = fewer events = better battery life. Continuous accelerometer at 100Hz is expensive. Practical strategies:

- Use CMMotionActivityManager (low power) to detect driving state first
- Only activate high-frequency accelerometer sampling once driving is confirmed
- Stop accelerometer updates explicitly when not needed — hardware powers down
- Target 50Hz rather than 100Hz for road roughness (research shows this is sufficient)
- Estimated impact: continuous accelerometer + GPS will consume 5-15% battery per hour depending on sampling rate and GPS accuracy settings

---

## 2. iOS Background Processing

### What Is Allowed for Continuous Sensor Collection

iOS provides several background execution modes relevant to this app:

**Background Location Updates (primary mechanism):**
- Enable `UIBackgroundModes` > `location` in Info.plist
- Set `locationManager.allowsBackgroundLocationUpdates = true`
- Set `locationManager.pausesLocationUpdatesAutomatically = false` (important — otherwise iOS will pause updates when it detects the user has stopped)
- This keeps the app alive in the background as long as location updates are being delivered

**Accelerometer in Background:**
- There is NO dedicated background mode for accelerometer/motion data
- The workaround: use background location updates to keep the app alive, then read accelerometer data while the app is running in the background via location updates
- This is the standard approach used by apps like SmartRoadSense and road monitoring research projects
- CMMotionManager continues to deliver accelerometer updates as long as the app process is alive

**Audio Background Mode (alternative keep-alive):**
- Some apps play silent audio to maintain background execution
- Apple has been rejecting this approach in App Store review — avoid it

### iOS 17/18/26 Changes

- **iOS 17:** No major changes to background location or sensor APIs. Continued tightening of background execution scrutiny during App Store review.
- **iOS 18:** Introduced stricter user-facing indicators for background location usage (status bar indicators). No API-level changes to sensor access.
- **iOS 26 (2025):** Introduced `BGContinuedProcessingTask` — a new background task type requiring continuous progress reporting, allowing users to monitor progress and cancel. This is for discrete tasks, not continuous sensor monitoring. The primary mechanism for this app remains background location updates.

### App Store Review Considerations

Apple scrutinizes apps requesting "Always" location permission. The app must:
- Clearly justify why background location is needed
- Show the blue status bar indicator when tracking in background
- Provide clear user controls to start/stop tracking
- Demonstrate genuine user benefit from background operation

---

## 3. SmartRoadSense (Open Source Project)

### Current GitHub State

GitHub organization: https://github.com/SmartRoadSense

Available repositories:
- **Mobile clients** — Android and iOS raw data collector apps (source code available)
- **Backend service** — Server-side data processing
- **osm-tiles** — OpenStreetMap tile server for visualization
- **denmark-analysis** — Analysis scripts for Danish road data
- **QGIS plugin** — For desktop GIS analysis (separate repo by geodrinx)

### Algorithm Details

**Important caveat:** The core road roughness processing algorithm is currently closed source. The mobile apps and infrastructure code are open, but the signal processing pipeline that converts raw accelerometer data into roughness scores is proprietary.

What is known about their approach:
- Monitors vertical accelerations inside a moving vehicle
- Extracts a roughness index (PPE — Power of the Pavement Excitation) from the acceleration signal
- Accounts for vehicle speed influence on readings (documented in their 2017 Sensors journal paper)
- Output data fields include: latitude, longitude, IRI estimate, PPE value, OSM road ID, highway classification, timestamp

### Open Data

SmartRoadSense releases processed data under Open Database License (ODbL). The dataset includes roughness scores mapped to OpenStreetMap road segments — useful for validation and benchmarking.

### Relevance to Our App

- Their architecture (smartphone sensor collection -> server aggregation -> map visualization) validates the overall approach
- The closed-source algorithm means we need to implement our own roughness scoring
- Their published research papers describe the challenges (speed normalization, device variability, mounting position) — worth reading for practical pitfalls

---

## 4. MapKit vs Mapbox for Heat Map Visualization

### MapKit

**Pros:**
- Free, no API key management, no usage-based pricing
- Native SwiftUI integration (`Map` view)
- No additional SDK dependency
- Apple Maps data improving steadily

**Cons:**
- No built-in heat map layer — must implement custom `MKOverlay` + `MKOverlayRenderer`
- Limited styling control compared to Mapbox
- Third-party heat map libraries exist (DTMHeatmap, JDSwiftHeatMap) but are dated and not well-maintained
- No vector tile styling — cannot easily color individual road segments by quality score

### Mapbox Maps SDK for iOS

**Pros:**
- Built-in `HeatmapLayer` with configurable color ramps, weight, intensity, radius — all adjustable by zoom level
- Full vector tile styling — can color individual road segments (LineString features) by roughness score
- Supports custom tile sources — can serve pre-processed road quality tiles from your own backend
- Uses Metal for GPU-accelerated rendering
- Offline maps support
- Better for data-heavy visualization use cases

**Cons:**
- Paid after free tier (50,000 monthly active users on free tier as of 2025)
- Additional SDK dependency (~30MB)
- More complex setup than MapKit
- API changes between major versions (v10+ has significant API differences from v6)

### Recommendation

**Mapbox is the clear choice for this use case.** Road quality visualization specifically requires:
1. Coloring road segments by quality score (Mapbox line layers with data-driven styling)
2. Heat map overlays for coverage density (Mapbox built-in HeatmapLayer)
3. Custom styling to distinguish road quality levels visually

MapKit would require substantial custom rendering code to achieve the same result, and the outcome would be less performant and harder to maintain.

---

## 5. PostGIS for Road Quality Data

### Schema Design

Recommended approach using two core tables:

```sql
-- Raw readings from devices
CREATE TABLE road_readings (
    id BIGSERIAL PRIMARY KEY,
    geom GEOMETRY(Point, 4326),
    roughness_score FLOAT,
    speed_kmh FLOAT,
    device_id UUID,
    vehicle_type TEXT,
    recorded_at TIMESTAMPTZ,
    raw_accel_rms FLOAT
);

CREATE INDEX idx_readings_geom ON road_readings USING GIST(geom);
CREATE INDEX idx_readings_time ON road_readings (recorded_at);

-- Aggregated road segments (materialized from OSM or computed)
CREATE TABLE road_segments (
    id BIGSERIAL PRIMARY KEY,
    osm_way_id BIGINT,
    geom GEOMETRY(LineString, 4326),
    avg_roughness FLOAT,
    reading_count INT,
    last_updated TIMESTAMPTZ
);

CREATE INDEX idx_segments_geom ON road_segments USING GIST(geom);
```

### Snapping Points to Road Segments

Use `ST_LineLocatePoint` to associate readings with road segments:

```sql
-- Find the nearest road segment for each reading
SELECT r.id, s.osm_way_id,
       ST_LineLocatePoint(s.geom, r.geom) AS position_on_segment,
       ST_Distance(s.geom::geography, r.geom::geography) AS distance_m
FROM road_readings r
CROSS JOIN LATERAL (
    SELECT osm_way_id, geom
    FROM road_segments
    ORDER BY geom <-> r.geom
    LIMIT 1
) s
WHERE ST_Distance(s.geom::geography, r.geom::geography) < 30; -- within 30m
```

### Aggregating by Road Segment

```sql
-- Materialized view for aggregated scores
CREATE MATERIALIZED VIEW road_quality AS
SELECT
    s.id AS segment_id,
    s.osm_way_id,
    s.geom,
    AVG(r.roughness_score) AS avg_roughness,
    PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY r.roughness_score) AS median_roughness,
    COUNT(*) AS reading_count,
    MAX(r.recorded_at) AS last_reading
FROM road_segments s
JOIN road_readings r ON ST_DWithin(s.geom::geography, r.geom::geography, 30)
GROUP BY s.id, s.osm_way_id, s.geom;
```

### Performance Tips

- **GiST indexes** are essential — keep index size within available RAM
- **`ST_DWithin` with geography type** for accurate distance-based matching (meters, not degrees)
- **Materialized views** for pre-computed aggregations — refresh on a schedule (e.g., hourly)
- **Partitioning** road_readings by time (monthly) for large datasets
- **`ST_SnapToGrid`** can reduce precision of stored points to save space (e.g., snap to 0.00001 degree ~ 1m)
- Consider **H3 hexagonal grid** (via h3-pg extension) as an alternative aggregation strategy — aggregate by hex cell rather than road segment for simpler queries

---

## 6. Privacy Zones Implementation

### How Strava Implements It

Strava's privacy zone system works as follows:

1. **User sets a home/work address** and selects a radius (200m to 1 mile)
2. **GPS points within that radius are stripped** from the visible activity, but only at the start and end of activities
3. **Mid-activity pass-throughs are NOT hidden** — if you ride past your home mid-ride, that data is visible (this is a known limitation)

### The Randomization Problem and Solution

Original implementation centered the exclusion circle exactly on the user's address. Researchers demonstrated that by overlaying many activities, the center point (and thus the home address) could be triangulated from where tracks consistently disappeared.

**Strava's fix (documented in their engineering blog):**
- The exclusion center is offset to a random nearby point (not the actual address)
- The offset distance is slightly randomized each time
- This prevents triangulation from activity endpoints

### Implementation for Our App

For a road quality app, privacy zones are simpler than Strava's case because:
- Road quality data is anonymous aggregate data, not personal activity tracks
- We only need to suppress individual GPS readings near protected locations
- No need to preserve activity continuity (we can just drop readings)

Recommended approach:
```
// On device, before uploading:
for each reading in batch:
    for each privacy_zone in user.privacy_zones:
        if distance(reading.location, privacy_zone.center) < privacy_zone.radius:
            drop reading  // don't upload at all
```

Key decisions:
- **Filter on-device** (before upload) — the server never sees readings near home
- Radius options: 200m, 400m, 800m, 1600m
- Apply a small random offset (50-100m) to the zone center stored on-device to prevent reverse engineering from gaps in public data
- Allow multiple zones (home, work, etc.)

---

## 7. React Native vs Swift

### For Continuous Background Accelerometer + GPS

**Swift (Native iOS) — Recommended**

Advantages:
- Direct access to CMMotionManager and CLLocationManager with no bridging overhead
- Accelerometer polling at 100Hz+ with consistent timing
- Full control over background execution lifecycle
- No JavaScript bridge latency for real-time sensor processing
- Smaller app binary
- Battery optimization is more granular

Disadvantages:
- iOS only (no Android code reuse)
- Longer development time if targeting both platforms

**React Native**

Advantages:
- Cross-platform code sharing (significant for Android+iOS)
- `react-native-background-geolocation` (by Transistor Software) is mature and handles background location well
- Expo Sensors API provides accelerometer access
- Faster UI development for non-sensor screens

Disadvantages:
- **JavaScript bridge adds latency** to sensor data (problematic at high sampling rates)
- Background accelerometer access requires native modules — you end up writing native code anyway
- `react-native-sensors` library is not as mature as native CMMotionManager
- Battery overhead from the JS runtime running alongside native sensor code
- Background execution is ultimately managed by native code; React Native just wraps it
- Debugging background sensor issues requires understanding both native and JS layers

### Verdict

**Use Swift for this app.** The core value proposition is continuous background sensor data collection — this is fundamentally a native capability. In React Native, you would end up writing the critical sensor + background code in native Swift/Kotlin anyway, with the JS layer only handling the UI.

If Android is required later, consider:
- Swift for iOS, Kotlin for Android (shared backend/algorithms)
- Or: native sensor collection modules with a shared React Native UI layer on top (hybrid approach)

---

## 8. IRI (International Roughness Index)

### What Is IRI

IRI is the internationally standardized metric for road surface roughness, measured in m/km (or in/mi). It simulates a standard quarter-car model traveling at 80 km/h over the measured road profile. The accumulated suspension travel divided by distance traveled gives the IRI value.

| IRI (m/km) | Road Condition |
|---|---|
| < 2 | Good (highway quality) |
| 2-4 | Fair |
| 4-6 | Poor |
| > 6 | Very poor / unpaved |

### Standard Quarter-Car Model

The IRI reference model is called the "Golden Car" — a quarter-car model with fixed parameters:

- Sprung mass (vehicle body): ms
- Unsprung mass (wheel/axle): mu
- Suspension spring rate: ks
- Suspension damping: cs
- Tire spring rate: kt

Standard parameter ratios (dimensionless):
- mu/ms = 0.15
- ks/ms = 63.3 s^-2
- cs/ms = 6.0 s^-1
- kt/ms = 653 s^-2

Simulated at 80 km/h reference speed.

### Calculating IRI from Smartphone Accelerometer Data

This is a multi-step process and an active area of research. There is no single "plug and play" algorithm, but the general pipeline is:

**Step 1: Data Collection**
- Record vertical acceleration (z-axis) at 50-100Hz
- Record GPS position and speed simultaneously
- Mounting position matters — dashboard-mounted vs. pocket introduces different transfer functions

**Step 2: Preprocessing**
- Apply low-pass filter (typically Butterworth, cutoff 30-40Hz) to remove high-frequency noise
- Apply high-pass filter (cutoff 0.5-1Hz) to remove gravity component and sensor drift
- Normalize for vehicle speed (roughness perception varies with speed)

**Step 3: Profile Estimation (two approaches)**

*Approach A — Double Integration (direct but noisy):*
- Integrate acceleration once to get velocity
- Integrate velocity to get displacement (road profile)
- Apply the standard quarter-car IRI simulation to the profile
- Challenge: double integration amplifies low-frequency drift; requires careful filtering (Newmark-beta method is recommended for numerical stability)

*Approach B — Statistical Correlation (practical for smartphones):*
- Compute RMS (root mean square) of vertical acceleration over fixed-length windows (e.g., 100m road segments)
- Correlate acceleration RMS with known IRI values from calibration runs
- Use regression model: `IRI_estimated = a * accel_RMS + b`
- This avoids the double-integration problem entirely
- Requires calibration per vehicle type

*Approach C — Frequency Domain (more sophisticated):*
- Convert acceleration to frequency domain via FFT
- Apply transfer function to convert measured vehicle response to standard quarter-car response
- Estimate IRI from the transformed frequency response
- Vehicle model parameters can be identified through calibration (e.g., driving over a known bump)

### Practical Recommendation for a Crowdsourced App

**Do not attempt to compute true IRI from smartphones.** Instead:

1. Compute a **relative roughness index** based on vertical acceleration RMS, normalized by speed
2. Use **crowdsourced averaging** to smooth out vehicle-specific and mounting-specific variations
3. Aggregate many readings per road segment — the law of large numbers compensates for individual measurement noise
4. Optionally allow users to specify vehicle type (sedan, SUV, truck) and apply correction factors
5. Map your relative index to IRI-like categories (good/fair/poor/very poor) rather than claiming absolute IRI values

This is the approach SmartRoadSense and most successful crowdsourced road quality projects use — they report a roughness index that correlates with IRI but do not claim to measure IRI directly.

---

## Sources

- [CMMotionManager — Apple Developer Documentation](https://developer.apple.com/documentation/coremotion/cmmotionmanager)
- [CMMotionActivityManager — Apple Developer Documentation](https://developer.apple.com/documentation/coremotion/cmmotionactivitymanager)
- [CMMotionActivity — NSHipster](https://nshipster.com/cmmotionactivity/)
- [Energy Efficiency Guide for iOS — Motion Best Practices](https://developer.apple.com/library/archive/documentation/Performance/Conceptual/EnergyGuide-iOS/MotionBestPractices.html)
- [Handling Location Updates in the Background — Apple](https://developer.apple.com/documentation/corelocation/handling-location-updates-in-the-background)
- [iOS 26 Background APIs — BGContinuedProcessingTask](https://dev.to/arshtechpro/wwdc-2025-ios-26-background-apis-explained-bgcontinuedprocessingtask-changes-everything-9b5)
- [SmartRoadSense — GitHub Organization](https://github.com/SmartRoadSense)
- [SmartRoadSense — Official Site](https://smartroadsense.it/)
- [SmartRoadSense Speed Influence Study — MDPI Sensors](https://www.mdpi.com/1424-8220/17/2/305)
- [Mapbox iOS Heat Map Example](https://docs.mapbox.com/ios/maps/examples/heatmap/)
- [DTMHeatmap — CocoaPods](https://cocoapods.org/pods/DTMHeatmap)
- [JDSwiftHeatMap — GitHub](https://github.com/jamesdouble/JDSwiftHeatMap)
- [PostGIS Spatial Queries Documentation](https://postgis.net/docs/using_postgis_query.html)
- [ST_LineLocatePoint — PostGIS](https://postgis.net/docs/ST_LineLocatePoint.html)
- [ST_SnapToGrid — PostGIS](https://postgis.net/docs/ST_SnapToGrid.html)
- [Linear Referencing — PostGIS Workshop](http://postgis.net/workshops/postgis-intro/linear_referencing.html)
- [Strava Privacy Zone — How It Works](https://the5krunner.com/2019/02/21/strava-privacy-zone/)
- [Strava Engineering — Update to Privacy Zones](https://medium.com/strava-engineering/update-to-privacy-zones-functionality-98a570f6ebb)
- [Strava Privacy Zones — DC Rainmaker](https://www.dcrainmaker.com/2021/08/privacy-features-options.html)
- [React Native Background Geolocation — Transistor Software](https://github.com/transistorsoft/react-native-background-geolocation)
- [Expo Accelerometer Documentation](https://docs.expo.dev/versions/latest/sdk/accelerometer/)
- [IRI — Wikipedia](https://en.wikipedia.org/wiki/International_roughness_index)
- [Road Quality Assessment Using IRI and Android Accelerometer](https://www.researchgate.net/publication/335721418_Road_Quality_Assessment_Using_International_Roughness_Index_Method_and_Accelerometer_on_Android)
- [IRI Estimation by Frequency Domain Analysis](https://www.sciencedirect.com/science/article/pii/S1877705817320039)
- [Pavement Condition Assessment Using Smartphone Accelerometers — IJERT](https://www.ijert.org/pavement-condition-assessment-using-smartphone-accelerometers)
