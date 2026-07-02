export type MapMode = "quality" | "potholes" | "coverage";

export type SearchParamRecord = Record<string, string | string[] | undefined>;

export type UrlViewportState = {
  mode: MapMode;
  segment: string | null;
  lat: number | null;
  lng: number | null;
  z: number | null;
  q: string | null;
};

export function parseMapMode(raw: string | null | undefined): MapMode {
  if (raw === "potholes" || raw === "coverage") {
    return raw;
  }
  return "quality";
}

// Mapbox GL throws if constructed with coordinates/zoom outside these ranges.
// See https://docs.mapbox.com/mapbox-gl-js/api/map/ (LngLat, valid zoom range).
export const MIN_LAT = -90;
export const MAX_LAT = 90;
export const MIN_LNG = -180;
export const MAX_LNG = 180;
export const MIN_ZOOM = 0;
export const MAX_ZOOM = 22;

function parseBoundedFloatOrNull(value: string | null, min: number, max: number): number | null {
  if (!value) return null;
  const parsed = Number.parseFloat(value);
  if (!Number.isFinite(parsed)) return null;
  if (parsed < min || parsed > max) return null;
  return parsed;
}

export function parseViewportState(input: URLSearchParams): UrlViewportState {
  const lat = parseBoundedFloatOrNull(input.get("lat"), MIN_LAT, MAX_LAT);
  const lng = parseBoundedFloatOrNull(input.get("lng"), MIN_LNG, MAX_LNG);
  const z = parseBoundedFloatOrNull(input.get("z"), MIN_ZOOM, MAX_ZOOM);

  // Viewport is only meaningful as a full triple — if any one of lat/lng/z is
  // missing or invalid, fall back to the app's default viewport resolution
  // (see resolveInitialViewport in road-quality-map-view.tsx) instead of
  // passing a partial/garbage viewport into Mapbox.
  const hasCompleteViewport = lat !== null && lng !== null && z !== null;

  return {
    mode: parseMapMode(input.get("mode")),
    segment: input.get("segment"),
    lat: hasCompleteViewport ? lat : null,
    lng: hasCompleteViewport ? lng : null,
    z: hasCompleteViewport ? z : null,
    q: input.get("q"),
  };
}

export function searchParamRecordToUrlSearchParams(record: SearchParamRecord): URLSearchParams {
  const params = new URLSearchParams();

  for (const [key, value] of Object.entries(record)) {
    if (Array.isArray(value)) {
      if (value[0]) {
        params.set(key, value[0]);
      }
      continue;
    }

    if (value) {
      params.set(key, value);
    }
  }

  return params;
}

export function withUpdatedRouteState(
  current: URLSearchParams,
  patch: Partial<UrlViewportState>,
): URLSearchParams {
  const next = new URLSearchParams(current);

  const setOrDelete = (key: string, value: string | null) => {
    if (!value) {
      next.delete(key);
      return;
    }

    next.set(key, value);
  };

  if (patch.mode !== undefined) {
    next.set("mode", patch.mode);
  }

  if (patch.segment !== undefined) {
    setOrDelete("segment", patch.segment);
  }

  if (patch.q !== undefined) {
    setOrDelete("q", patch.q);
  }

  if (patch.lat !== undefined) {
    setOrDelete("lat", patch.lat === null ? null : patch.lat.toFixed(5));
  }

  if (patch.lng !== undefined) {
    setOrDelete("lng", patch.lng === null ? null : patch.lng.toFixed(5));
  }

  if (patch.z !== undefined) {
    setOrDelete("z", patch.z === null ? null : patch.z.toFixed(2));
  }

  return next;
}
