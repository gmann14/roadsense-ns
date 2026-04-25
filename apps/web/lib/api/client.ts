export type PublicStats = {
  total_km_mapped: number;
  total_readings: number;
  segments_scored: number;
  active_potholes: number;
  municipalities_covered: number;
  map_bounds: Bbox | null;
  pothole_bounds: Bbox | null;
  generated_at: string;
};

export type SegmentDetail = {
  id: string;
  road_name: string | null;
  road_type: string;
  municipality: string | null;
  length_m: number;
  has_speed_bump: boolean;
  has_rail_crossing: boolean;
  surface_type: string | null;
  aggregate: {
    avg_roughness_score: number;
    category: "smooth" | "fair" | "rough" | "very_rough" | "unpaved";
    confidence: "low" | "medium" | "high";
    total_readings: number;
    unique_contributors: number;
    pothole_count: number;
    trend: "improving" | "stable" | "worsening";
    score_last_30d: number | null;
    score_30_60d: number | null;
    last_reading_at: string | null;
    updated_at: string;
  };
  history: unknown[];
  neighbors: unknown | null;
};

export type WorstSegmentRow = {
  rank: number;
  segment_id: string;
  road_name: string | null;
  municipality: string | null;
  road_type: string;
  category: "smooth" | "fair" | "rough" | "very_rough" | "unpaved";
  confidence: "low" | "medium" | "high";
  avg_roughness_score: number;
  score_last_30d: number | null;
  score_30_60d: number | null;
  trend: "improving" | "stable" | "worsening";
  total_readings: number;
  unique_contributors: number;
  pothole_count: number;
  last_reading_at: string | null;
};

export type WorstSegmentsResponse = {
  generated_at: string | null;
  municipality: string | null;
  rows: WorstSegmentRow[];
};

export type Bbox = {
  minLng: number;
  minLat: number;
  maxLng: number;
  maxLat: number;
};

export type PotholeRow = {
  id: string;
  lat: number;
  lng: number;
  magnitude: number;
  confirmation_count: number;
  first_reported_at: string;
  last_confirmed_at: string;
  status: string;
  segment_id: string | null;
};

export type PotholeResponse = {
  potholes: PotholeRow[];
};

export const POTHOLE_BBOX_MAX_LNG_SPAN = 0.12;
export const POTHOLE_BBOX_MAX_LAT_SPAN = 0.09;

const DEFAULT_API_BASE_URL = "http://127.0.0.1:54321/functions/v1";
const DEFAULT_MAPBOX_STYLE_URL = "mapbox://styles/mapbox/light-v11";

export function getApiBaseUrl(): string {
  return process.env.NEXT_PUBLIC_API_BASE_URL ?? process.env.ROADSENSE_API_BASE_URL ?? DEFAULT_API_BASE_URL;
}

export function getMapboxToken(): string | null {
  return process.env.NEXT_PUBLIC_MAPBOX_TOKEN ?? null;
}

export function getMapboxStyleUrl(): string {
  const explicitStyleUrl = process.env.NEXT_PUBLIC_MAPBOX_STYLE_URL;
  if (explicitStyleUrl) {
    return explicitStyleUrl;
  }

  const styleId = process.env.NEXT_PUBLIC_MAPBOX_STYLE_ID;
  if (styleId) {
    return `mapbox://styles/${styleId}`;
  }

  return DEFAULT_MAPBOX_STYLE_URL;
}

export function getPublicReadHeaders(): HeadersInit {
  const anonKey =
    process.env.NEXT_PUBLIC_SUPABASE_ANON_KEY ?? process.env.NEXT_PUBLIC_ROADSENSE_ANON_KEY ?? null;

  if (!anonKey) {
    return {};
  }

  return {
    apikey: anonKey,
    Authorization: `Bearer ${anonKey}`,
  };
}

function buildEndpointUrl(path: string): string {
  return `${getApiBaseUrl().replace(/\/$/, "")}${path}`;
}

function getSupabaseRootUrl(): string {
  return getApiBaseUrl()
    .replace(/\/functions\/v1\/?$/, "")
    .replace(/\/$/, "");
}

async function fetchJson<T>(path: string, nextOptions?: RequestInit & { next?: { revalidate: number } }): Promise<T | null> {
  if (process.env.NODE_ENV === "test" || process.env.VITEST === "true") {
    return null;
  }

  try {
    const response = await fetch(buildEndpointUrl(path), {
      ...nextOptions,
      headers: {
        ...getPublicReadHeaders(),
        ...(nextOptions?.headers ?? {}),
      },
    });

    if (!response.ok || response.status === 204) {
      return null;
    }

    return (await response.json()) as T;
  } catch {
    return null;
  }
}

async function fetchRpc<T>(
  rpcName: string,
  body: Record<string, unknown>,
  nextOptions?: RequestInit & { next?: { revalidate: number } },
): Promise<T | null> {
  if (process.env.NODE_ENV === "test" || process.env.VITEST === "true") {
    return null;
  }

  try {
    const response = await fetch(`${getSupabaseRootUrl()}/rest/v1/rpc/${rpcName}`, {
      method: "POST",
      ...nextOptions,
      headers: {
        "content-type": "application/json",
        ...getPublicReadHeaders(),
        ...(nextOptions?.headers ?? {}),
      },
      body: JSON.stringify(body),
    });

    if (!response.ok || response.status === 204) {
      return null;
    }

    return (await response.json()) as T;
  } catch {
    return null;
  }
}

export async function getPublicStats(): Promise<PublicStats | null> {
  return await fetchJson<PublicStats>("/stats", {
    next: { revalidate: 300 },
  });
}

export async function getSegmentDetail(segmentId: string): Promise<SegmentDetail | null> {
  return await fetchJson<SegmentDetail>(`/segments/${segmentId}`);
}

export function getQualityTileUrlTemplate(): string {
  return buildEndpointUrl("/tiles/{z}/{x}/{y}.mvt");
}

export function getCoverageTileUrlTemplate(): string {
  return buildEndpointUrl("/tiles/coverage/{z}/{x}/{y}.mvt");
}

export async function getWorstSegments({
  municipality,
  limit,
}: {
  municipality: string | null;
  limit: number;
}): Promise<WorstSegmentsResponse | null> {
  const query = new URLSearchParams({
    limit: String(limit),
  });

  if (municipality) {
    query.set("municipality", municipality);
  }

  return await fetchJson<WorstSegmentsResponse>(`/segments-worst?${query.toString()}`, {
    next: { revalidate: 900 },
  });
}

export async function getPotholes(bbox: Bbox): Promise<PotholeResponse | null> {
  if (!isPotholeBboxWithinLookupCap(bbox)) {
    return null;
  }

  const query = new URLSearchParams({
    bbox: [bbox.minLng, bbox.minLat, bbox.maxLng, bbox.maxLat].map((value) => value.toFixed(5)).join(","),
  });

  return await fetchJson<PotholeResponse>(`/potholes?${query.toString()}`);
}

export function isPotholeBboxWithinLookupCap(bbox: Bbox): boolean {
  return bbox.maxLng - bbox.minLng <= POTHOLE_BBOX_MAX_LNG_SPAN &&
    bbox.maxLat - bbox.minLat <= POTHOLE_BBOX_MAX_LAT_SPAN;
}

export async function getTopPotholes(limit = 20): Promise<PotholeResponse | null> {
  const rows = await fetchRpc<PotholeRow[]>(
    "get_top_potholes",
    { p_limit: limit },
    { next: { revalidate: 300 } },
  );

  return {
    potholes: rows ?? [],
  };
}
