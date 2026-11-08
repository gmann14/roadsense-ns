export type PublicStats = {
  // Numeric fields are nullable post-normalization: the API can omit or send
  // malformed values, and we'd rather render a placeholder than "NaN".
  total_km_mapped: number | null;
  total_readings: number | null;
  segments_scored: number | null;
  active_potholes: number | null;
  municipalities_covered: number | null;
  map_bounds: Bbox | null;
  focus_bounds: Bbox | null;
  pothole_bounds: Bbox | null;
  /** When the stats materialized view was refreshed. Not a data-freshness signal. */
  generated_at: string | null;
  /**
   * When road aggregates last actually changed (day-rounded). Optional: older
   * API builds don't send it, and then the UI shows no freshness claim at all.
   */
  data_updated_at: string | null;
};

export type ApiFailureReason =
  | "disabled"
  | "invalid_request"
  | "aborted"
  | "timeout"
  | "network"
  | "http"
  | "invalid_response";

/**
 * Every read helper returns this instead of `null`, so callers can tell
 * "the API said there is nothing here" apart from "we couldn't reach the API".
 */
export type ApiResult<T> =
  | { ok: true; data: T }
  | { ok: false; reason: ApiFailureReason; status: number | null };

export type ReadOptions = {
  signal?: AbortSignal;
  timeoutMs?: number;
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

function apiFetchesDisabledInTests(): boolean {
  return (process.env.NODE_ENV === "test" || process.env.VITEST === "true") &&
    process.env.ROADSENSE_ALLOW_API_FETCHES_IN_TEST !== "true";
}

const DEFAULT_TIMEOUT_MS = 3_000;

function failure(reason: ApiFailureReason, status: number | null = null): { ok: false; reason: ApiFailureReason; status: number | null } {
  return { ok: false, reason, status };
}

export async function fetchJson(
  path: string,
  options: ReadOptions & { revalidate?: number } = {},
): Promise<ApiResult<unknown>> {
  if (apiFetchesDisabledInTests()) {
    return failure("disabled");
  }

  const { signal, timeoutMs = DEFAULT_TIMEOUT_MS, revalidate } = options;
  if (signal?.aborted) {
    return failure("aborted");
  }

  // One controller aborts on either the caller's signal or our timeout, so a
  // caller-supplied signal never disables the timeout.
  const controller = new AbortController();
  let timedOut = false;
  const timeout = setTimeout(() => {
    timedOut = true;
    controller.abort();
  }, timeoutMs);
  const forwardAbort = () => controller.abort();
  signal?.addEventListener("abort", forwardAbort, { once: true });

  try {
    const response = await fetch(buildEndpointUrl(path), {
      signal: controller.signal,
      headers: getPublicReadHeaders(),
      ...(revalidate !== undefined ? { next: { revalidate } } : {}),
    } as RequestInit);

    if (!response.ok) {
      return failure("http", response.status);
    }

    if (response.status === 204) {
      return failure("invalid_response", response.status);
    }

    try {
      return { ok: true, data: (await response.json()) as unknown };
    } catch {
      return failure("invalid_response", response.status);
    }
  } catch {
    if (signal?.aborted) {
      return failure("aborted");
    }
    return failure(timedOut ? "timeout" : "network");
  } finally {
    clearTimeout(timeout);
    signal?.removeEventListener("abort", forwardAbort);
  }
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

/** Returns null when the stats could not be loaded (outage, timeout, bad payload). */
export async function getPublicStats(options: ReadOptions = {}): Promise<PublicStats | null> {
  const result = await fetchJson("/stats", { ...options, revalidate: 300 });
  if (!result.ok || !isRecord(result.data)) {
    return null;
  }
  return normalizePublicStats(result.data as Partial<PublicStats>);
}

export async function getSegmentDetail(
  segmentId: string,
  options: ReadOptions = {},
): Promise<ApiResult<SegmentDetail>> {
  if (segmentId.trim().length === 0) {
    return failure("invalid_request");
  }

  const result = await fetchJson(`/segments/${encodeURIComponent(segmentId)}`, options);
  if (!result.ok) {
    return result;
  }

  const body = result.data;
  if (!isRecord(body) || !isRecord(body.aggregate) || typeof body.id !== "string") {
    return failure("invalid_response");
  }

  return { ok: true, data: body as unknown as SegmentDetail };
}

function toPotholeResponse(result: ApiResult<unknown>): ApiResult<PotholeResponse> {
  if (!result.ok) {
    return result;
  }
  const potholes = isRecord(result.data) ? result.data.potholes : undefined;
  if (!Array.isArray(potholes)) {
    return failure("invalid_response");
  }
  return { ok: true, data: { potholes: potholes as PotholeRow[] } };
}

export function getQualityTileUrlTemplate(): string {
  return buildEndpointUrl("/tiles/{z}/{x}/{y}.mvt");
}

export function getCoverageTileUrlTemplate(): string {
  return buildEndpointUrl("/tiles/coverage/{z}/{x}/{y}.mvt");
}

export async function getPotholes(bbox: Bbox, options: ReadOptions = {}): Promise<ApiResult<PotholeResponse>> {
  if (!isPotholeBboxWithinLookupCap(bbox)) {
    return failure("invalid_request");
  }

  const query = new URLSearchParams({
    bbox: [bbox.minLng, bbox.minLat, bbox.maxLng, bbox.maxLat].map((value) => value.toFixed(5)).join(","),
  });

  return toPotholeResponse(await fetchJson(`/potholes?${query.toString()}`, options));
}

export function isPotholeBboxWithinLookupCap(bbox: Bbox): boolean {
  return bbox.maxLng - bbox.minLng <= POTHOLE_BBOX_MAX_LNG_SPAN &&
    bbox.maxLat - bbox.minLat <= POTHOLE_BBOX_MAX_LAT_SPAN;
}

export async function getTopPotholes(limit = 20, options: ReadOptions = {}): Promise<ApiResult<PotholeResponse>> {
  const query = new URLSearchParams({ limit: String(limit) });
  return toPotholeResponse(
    await fetchJson(`/top-potholes?${query.toString()}`, {
      timeoutMs: 1_500,
      ...options,
      revalidate: 300,
    }),
  );
}

function normalizeNumber(value: unknown): number | null {
  if (value === null || value === undefined || value === "") {
    return null;
  }
  const parsed = Number(value);
  return Number.isFinite(parsed) ? parsed : null;
}

function normalizeTimestamp(value: unknown): string | null {
  return typeof value === "string" && value.trim().length > 0 ? value : null;
}

export function normalizePublicStats(stats: Partial<PublicStats> | null | undefined): PublicStats | null {
  if (!stats) {
    return null;
  }

  return {
    total_km_mapped: normalizeNumber(stats.total_km_mapped),
    total_readings: normalizeNumber(stats.total_readings),
    segments_scored: normalizeNumber(stats.segments_scored),
    active_potholes: normalizeNumber(stats.active_potholes),
    municipalities_covered: normalizeNumber(stats.municipalities_covered),
    map_bounds: normalizeBbox(stats.map_bounds),
    focus_bounds: normalizeBbox(stats.focus_bounds),
    pothole_bounds: normalizeBbox(stats.pothole_bounds),
    generated_at: normalizeTimestamp(stats.generated_at),
    data_updated_at: normalizeTimestamp(stats.data_updated_at),
  };
}

export function normalizeBbox(value: unknown): Bbox | null {
  if (!value || typeof value !== "object") {
    return null;
  }

  const candidate = value as Record<string, unknown>;
  const minLng = Number(candidate.minLng ?? candidate.min_lng ?? candidate.minlon ?? candidate.min_lon);
  const minLat = Number(candidate.minLat ?? candidate.min_lat ?? candidate.minlat);
  const maxLng = Number(candidate.maxLng ?? candidate.max_lng ?? candidate.maxlon ?? candidate.max_lon);
  const maxLat = Number(candidate.maxLat ?? candidate.max_lat ?? candidate.maxlat);

  if (![minLng, minLat, maxLng, maxLat].every(Number.isFinite)) {
    return null;
  }

  if (minLng >= maxLng || minLat >= maxLat) {
    return null;
  }

  return { minLng, minLat, maxLng, maxLat };
}

export type FeedbackCategoryValue =
  | "bug"
  | "feature"
  | "map_issue"
  | "pothole_issue"
  | "privacy_safety"
  | "other";

export type FeedbackSubmissionInput = {
  category: FeedbackCategoryValue;
  message: string;
  replyEmail?: string | null;
  contactConsent?: boolean;
  route?: string | null;
  locale?: string | null;
};

export type FeedbackSubmissionOutcome =
  | { kind: "accepted"; id: string; requestId: string | null }
  | { kind: "validation_failed"; fieldErrors: Record<string, string>; requestId: string | null }
  | { kind: "rate_limited"; retryAfterSeconds: number | null; requestId: string | null }
  | { kind: "network_error"; message: string }
  | { kind: "server_error"; statusCode: number; requestId: string | null };

export async function submitFeedback(
  input: FeedbackSubmissionInput,
  fetchImpl: typeof fetch = fetch,
): Promise<FeedbackSubmissionOutcome> {
  const trimmedMessage = input.message.trim();
  const trimmedEmail = input.replyEmail?.trim() ?? "";
  const payload = {
    source: "web" as const,
    category: input.category,
    message: trimmedMessage,
    reply_email: trimmedEmail.length > 0 ? trimmedEmail : null,
    contact_consent: input.contactConsent === true,
    app_version: process.env.NEXT_PUBLIC_APP_VERSION ?? "web",
    platform: "web",
    locale: input.locale ?? null,
    route: input.route ?? null,
  };

  let response: Response;
  try {
    response = await fetchImpl(buildEndpointUrl("/feedback"), {
      method: "POST",
      headers: {
        "content-type": "application/json",
        ...getPublicReadHeaders(),
      },
      body: JSON.stringify(payload),
    });
  } catch (error) {
    return {
      kind: "network_error",
      message: error instanceof Error ? error.message : "Network request failed",
    };
  }

  const requestId = response.headers.get("x-request-id");

  if (response.status === 201) {
    const body = (await response.json().catch(() => null)) as { id?: string; request_id?: string } | null;
    return {
      kind: "accepted",
      id: body?.id ?? "",
      requestId: body?.request_id ?? requestId,
    };
  }

  if (response.status === 400) {
    const body = (await response.json().catch(() => null)) as
      | { field_errors?: Record<string, string>; request_id?: string }
      | null;
    return {
      kind: "validation_failed",
      fieldErrors: body?.field_errors ?? {},
      requestId: body?.request_id ?? requestId,
    };
  }

  if (response.status === 429) {
    const retryAfterHeader = response.headers.get("Retry-After");
    const retryAfterSeconds = retryAfterHeader ? Number(retryAfterHeader) : NaN;
    return {
      kind: "rate_limited",
      retryAfterSeconds: Number.isFinite(retryAfterSeconds) ? retryAfterSeconds : null,
      requestId,
    };
  }

  return {
    kind: "server_error",
    statusCode: response.status,
    requestId,
  };
}
