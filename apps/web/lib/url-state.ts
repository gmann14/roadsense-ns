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

export function parseViewportState(input: URLSearchParams): UrlViewportState {
  const parseFloatOrNull = (value: string | null): number | null => {
    if (!value) return null;
    const parsed = Number.parseFloat(value);
    return Number.isFinite(parsed) ? parsed : null;
  };

  return {
    mode: parseMapMode(input.get("mode")),
    segment: input.get("segment"),
    lat: parseFloatOrNull(input.get("lat")),
    lng: parseFloatOrNull(input.get("lng")),
    z: parseFloatOrNull(input.get("z")),
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
