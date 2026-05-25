import { errorResponse, jsonResponse } from "../../supabase/functions/_shared/http.ts";
import {
  createUploadReadingsHandler,
  type RateLimitResult as UploadRateLimitResult,
} from "../../supabase/functions/upload-readings/handler.ts";
import {
  createPotholeActionsHandler,
  type RateLimitResult as PotholeActionRateLimitResult,
} from "../../supabase/functions/pothole-actions/handler.ts";
import { createPotholePhotoHandlers, signPhotoReadToken, verifyPhotoReadToken } from "./photo.ts";
import { RailwayDatabase } from "./db.ts";
import { hashDeviceToken } from "../../supabase/functions/upload-readings/runtime.ts";

type AppConfig = {
  publicApiKey: string;
  publicBaseURL: string;
  uploadSigningSecret: string;
};

function secondsUntilNextUtcDay(now = new Date()): number {
  return Math.ceil((Date.UTC(now.getUTCFullYear(), now.getUTCMonth(), now.getUTCDate() + 1) - now.getTime()) / 1000);
}

function secondsUntilNextUtcHour(now = new Date()): number {
  return Math.ceil(
    (Date.UTC(now.getUTCFullYear(), now.getUTCMonth(), now.getUTCDate(), now.getUTCHours() + 1) - now.getTime()) / 1000,
  );
}

function headerAuthOK(headers: Headers, publicApiKey: string): boolean {
  const apikey = headers.get("apikey");
  const authorization = headers.get("authorization") ?? "";
  return apikey === publicApiKey || authorization === `Bearer ${publicApiKey}`;
}

function byteaToBytes(value: unknown): Uint8Array {
  if (value instanceof Uint8Array) return value;
  if (value instanceof ArrayBuffer) return new Uint8Array(value);
  if (Array.isArray(value)) return new Uint8Array(value);
  if (typeof value === "string") {
    const hex = value.replace(/^\\x/i, "");
    if (hex.length === 0) return new Uint8Array();
    return Uint8Array.from(hex.match(/.{1,2}/g)?.map((pair) => Number.parseInt(pair, 16)) ?? []);
  }
  if (value && typeof value === "object" && "data" in value && Array.isArray((value as { data?: unknown }).data)) {
    return new Uint8Array((value as { data: number[] }).data);
  }
  return new Uint8Array();
}

function mvtResponse(value: unknown, requestId: string): Response {
  const bytes = byteaToBytes(value);
  if (bytes.byteLength === 0) {
    return new Response(null, {
      status: 204,
      headers: {
        "cache-control": "public, max-age=3600, s-maxage=3600",
        "x-request-id": requestId,
        "access-control-allow-origin": "*",
      },
    });
  }
  const body = new Uint8Array(bytes).buffer.slice(0);
  return new Response(body, {
    status: 200,
    headers: {
      "content-type": "application/vnd.mapbox-vector-tile",
      "cache-control": "public, max-age=3600, s-maxage=3600",
      "x-request-id": requestId,
      "access-control-allow-origin": "*",
    },
  });
}

async function createUploadRateLimiter(
  db: RailwayDatabase,
  tokenHashHex: string,
  ip: string,
): Promise<UploadRateLimitResult> {
  const now = new Date();
  const dayBucket = new Date(Date.UTC(now.getUTCFullYear(), now.getUTCMonth(), now.getUTCDate()));
  const hourBucket = new Date(Date.UTC(now.getUTCFullYear(), now.getUTCMonth(), now.getUTCDate(), now.getUTCHours()));
  if (!await db.checkAndBumpRateLimit(`dev:${tokenHashHex}`, dayBucket, 50)) {
    return { ok: false, retryAfterSeconds: secondsUntilNextUtcDay(now) };
  }
  if (!await db.checkAndBumpRateLimit(`ip:${ip}`, hourBucket, 10)) {
    return { ok: false, retryAfterSeconds: secondsUntilNextUtcHour(now) };
  }
  return { ok: true, retryAfterSeconds: 0 };
}

async function createPotholeActionRateLimiter(
  db: RailwayDatabase,
  tokenHashHex: string,
  ip: string,
): Promise<PotholeActionRateLimitResult> {
  const now = new Date();
  const dayBucket = new Date(Date.UTC(now.getUTCFullYear(), now.getUTCMonth(), now.getUTCDate()));
  const hourBucket = new Date(Date.UTC(now.getUTCFullYear(), now.getUTCMonth(), now.getUTCDate(), now.getUTCHours()));
  if (!await db.checkAndBumpRateLimit(`pothole-action-device:${tokenHashHex}`, dayBucket, 100)) {
    return { ok: false, retryAfterSeconds: secondsUntilNextUtcDay(now) };
  }
  if (!await db.checkAndBumpRateLimit(`pothole-action-ip:${ip}`, hourBucket, 200)) {
    return { ok: false, retryAfterSeconds: secondsUntilNextUtcHour(now) };
  }
  return { ok: true, retryAfterSeconds: 0 };
}

async function createPotholePhotoRateLimiter(db: RailwayDatabase, tokenHashHex: string, ip: string) {
  const now = new Date();
  const dayBucket = new Date(Date.UTC(now.getUTCFullYear(), now.getUTCMonth(), now.getUTCDate()));
  const hourBucket = new Date(Date.UTC(now.getUTCFullYear(), now.getUTCMonth(), now.getUTCDate(), now.getUTCHours()));
  if (!await db.checkAndBumpRateLimit(`pothole-photo-device:${tokenHashHex}`, dayBucket, 20)) {
    return { ok: false as const, retryAfterSeconds: secondsUntilNextUtcDay(now) };
  }
  if (!await db.checkAndBumpRateLimit(`pothole-photo-ip:${ip}`, hourBucket, 40)) {
    return { ok: false as const, retryAfterSeconds: secondsUntilNextUtcHour(now) };
  }
  return { ok: true as const, retryAfterSeconds: 0 as const };
}

export function createRailwayApp(db: RailwayDatabase, config: AppConfig) {
  const uploadReadings = createUploadReadingsHandler({
    hashDeviceToken,
    checkRateLimit: (tokenHashHex, ip) => createUploadRateLimiter(db, tokenHashHex, ip),
    ingestBatch: async ({ payload, tokenHashHex }) => {
      const data = await db.ingestReadingBatch({
        batchID: payload.batch_id,
        tokenHashHex,
        readings: payload.readings,
        clientSentAt: payload.client_sent_at,
        clientAppVersion: payload.client_app_version,
        clientOSVersion: payload.client_os_version,
      });
      if (!data) throw new Error("ingest_reading_batch returned no data");
      return data as never;
    },
  });

  const potholeActions = createPotholeActionsHandler({
    hashDeviceToken,
    checkRateLimit: (tokenHashHex, ip) => createPotholeActionRateLimiter(db, tokenHashHex, ip),
    applyAction: async ({ payload, tokenHashHex }) => {
      const data = await db.applyPotholeAction({
        actionID: payload.action_id,
        tokenHashHex,
        actionType: payload.action_type,
        lat: payload.lat,
        lng: payload.lng,
        accuracyM: payload.accuracy_m,
        recordedAt: payload.recorded_at,
        potholeReportID: payload.pothole_report_id,
      });
      if (!data) throw new Error("apply_pothole_action returned no data");
      return data as never;
    },
  });

  const photoHandlers = createPotholePhotoHandlers({
    publicApiBaseURL: config.publicBaseURL,
    signingSecret: config.uploadSigningSecret,
    hashDeviceToken,
    checkRateLimit: (tokenHashHex, ip) => createPotholePhotoRateLimiter(db, tokenHashHex, ip),
    photoRepository: db,
  });

  return async function handleRequest(req: Request): Promise<Response> {
    const requestId = req.headers.get("x-request-id") ?? crypto.randomUUID();
    const url = new URL(req.url);
    const path = url.pathname.replace(/\/$/, "");

    if (path === "/functions/v1/health") {
      try {
        const result = await db.query<{ status: string }>("SELECT db_healthcheck() AS status");
        const dbStatus = result.rows[0]?.status ?? "ok";
        return jsonResponse(
          { status: "ok", db: dbStatus, version: "railway", commit: "local", deployed_at: null },
          200,
          {},
          requestId,
        );
      } catch {
        return errorResponse("service_unavailable", "Health check failed.", 503, requestId);
      }
    }

    const uploadMatch = path.match(/^\/functions\/v1\/pothole-photo-upload\/([0-9a-f-]+)$/i);
    if (uploadMatch) {
      return await photoHandlers.handleUpload(req, uploadMatch[1]);
    }

    const blobMatch = path.match(/^\/functions\/v1\/pothole-photo-blob\/([0-9a-f-]+)$/i);
    if (blobMatch && (req.method === "GET" || req.method === "HEAD")) {
      const expiresAt = Number(url.searchParams.get("expires_at") ?? "");
      const token = url.searchParams.get("token") ?? "";
      if (!await verifyPhotoReadToken(blobMatch[1], expiresAt, token, config.uploadSigningSecret)) {
        return errorResponse("forbidden", "Invalid pothole photo read token.", 403, requestId);
      }
      const blob = await db.getPhotoBlob(blobMatch[1]);
      if (!blob || (blob.status !== "pending_moderation" && blob.status !== "approved")) {
        return errorResponse("photo_not_found", "Pothole photo not found.", 404, requestId);
      }
      return new Response(req.method === "HEAD" ? null : blob.imageBytes, {
        status: 200,
        headers: {
          "content-type": blob.contentType,
          "cache-control": "private, max-age=60",
          "x-request-id": requestId,
        },
      });
    }

    if (!headerAuthOK(req.headers, config.publicApiKey)) {
      return jsonResponse({ error: "missing_apikey" }, 401, {}, requestId);
    }

    if (path === "/functions/v1/upload-readings") return await uploadReadings(req);
    if (path === "/functions/v1/pothole-actions") return await potholeActions(req);
    if (path === "/functions/v1/pothole-photos") return await photoHandlers.handleMetadata(req);

    if (path === "/functions/v1/stats" && (req.method === "GET" || req.method === "HEAD")) {
      const result = await db.query(
        `SELECT
                    total_km_mapped::double precision AS total_km_mapped,
                    total_readings::integer AS total_readings,
                    segments_scored::integer AS segments_scored,
                    active_potholes::integer AS active_potholes,
                    municipalities_covered::integer AS municipalities_covered,
                    generated_at
                FROM public_stats_mv
                LIMIT 1`,
      );
      return jsonResponse(result.rows[0] ?? null, 200, { "cache-control": "public, max-age=300" }, requestId);
    }

    const tileMatch = path.match(/^\/functions\/v1\/tiles\/(\d+)\/(\d+)\/(\d+)\.mvt$/);
    if (tileMatch && (req.method === "GET" || req.method === "HEAD")) {
      const result = await db.query<{ tile: unknown }>(
        "SELECT get_tile($1::integer, $2::integer, $3::integer) AS tile",
        [
          Number(tileMatch[1]),
          Number(tileMatch[2]),
          Number(tileMatch[3]),
        ],
      );
      return mvtResponse(result.rows[0]?.tile, requestId);
    }

    const coverageTileMatch = path.match(/^\/functions\/v1\/tiles\/coverage\/(\d+)\/(\d+)\/(\d+)\.mvt$/);
    if (coverageTileMatch && (req.method === "GET" || req.method === "HEAD")) {
      const result = await db.query<{ tile: unknown }>(
        "SELECT get_coverage_tile($1::integer, $2::integer, $3::integer) AS tile",
        [
          Number(coverageTileMatch[1]),
          Number(coverageTileMatch[2]),
          Number(coverageTileMatch[3]),
        ],
      );
      return mvtResponse(result.rows[0]?.tile, requestId);
    }

    if (path === "/functions/v1/potholes" && (req.method === "GET" || req.method === "HEAD")) {
      const bbox = url.searchParams.get("bbox")?.split(",").map(Number) ?? [];
      if (bbox.length !== 4 || bbox.some((value) => !Number.isFinite(value))) {
        return errorResponse(
          "validation_failed",
          "bbox must be four comma-separated floats within the 10km cap.",
          400,
          requestId,
        );
      }
      const result = await db.query(
        "SELECT * FROM get_potholes_in_bbox($1::double precision, $2::double precision, $3::double precision, $4::double precision)",
        bbox,
      );
      return jsonResponse({ potholes: result.rows }, 200, { "cache-control": "public, max-age=60" }, requestId);
    }

    const segmentMatch = path.match(/^\/functions\/v1\/segments\/([0-9a-f-]+)$/i);
    if (segmentMatch && (req.method === "GET" || req.method === "HEAD")) {
      const result = await db.query(
        `SELECT
                    rs.id::text,
                    rs.road_name,
                    rs.road_type,
                    rs.municipality,
                    rs.length_m::double precision AS length_m,
                    rs.has_speed_bump,
                    rs.has_rail_crossing,
                    rs.surface_type,
                    jsonb_build_object(
                        'avg_roughness_score', sa.avg_roughness_score::double precision,
                        'category', sa.roughness_category::text,
                        'confidence', sa.confidence::text,
                        'total_readings', sa.total_readings,
                        'unique_contributors', sa.unique_contributors,
                        'pothole_count', sa.pothole_count,
                        'trend', sa.trend::text,
                        'score_last_30d', sa.score_last_30d::double precision,
                        'score_30_60d', sa.score_30_60d::double precision,
                        'last_reading_at', sa.last_reading_at,
                        'updated_at', sa.updated_at
                    ) AS aggregate
                FROM road_segments rs
                JOIN segment_aggregates sa ON sa.segment_id = rs.id
                WHERE rs.id = $1::uuid`,
        [segmentMatch[1]],
      );
      if (!result.rows[0]) return errorResponse("not_found", "Segment not found.", 404, requestId);
      return jsonResponse({ ...result.rows[0], history: [], neighbors: null }, 200, {
        "cache-control": "public, max-age=60",
      }, requestId);
    }

    if (path === "/functions/v1/segments/worst" && (req.method === "GET" || req.method === "HEAD")) {
      const limit = Math.min(Math.max(Number(url.searchParams.get("limit") ?? "25") || 25, 1), 100);
      const municipality = url.searchParams.get("municipality");
      const result = await db.query(
        `SELECT
                    row_number() OVER (ORDER BY avg_roughness_score DESC, pothole_count DESC, total_readings DESC)::integer AS rank,
                    segment_id::text,
                    road_name,
                    municipality,
                    road_type,
                    category,
                    confidence,
                    avg_roughness_score::double precision AS avg_roughness_score,
                    score_last_30d::double precision AS score_last_30d,
                    score_30_60d::double precision AS score_30_60d,
                    trend,
                    total_readings,
                    unique_contributors,
                    pothole_count,
                    last_reading_at
                FROM public_worst_segments_mv
                WHERE ($1::text IS NULL OR municipality = $1::text)
                ORDER BY avg_roughness_score DESC, pothole_count DESC, total_readings DESC
                LIMIT $2::integer`,
        [municipality, limit],
      );
      return jsonResponse({ generated_at: new Date().toISOString(), municipality, rows: result.rows }, 200, {
        "cache-control": "public, max-age=300",
      }, requestId);
    }

    if (path === "/functions/v1/pothole-photo-image" && (req.method === "GET" || req.method === "HEAD")) {
      const reportID = url.searchParams.get("report_id");
      if (!reportID) return errorResponse("validation_failed", "report_id must be a UUID string.", 400, requestId);
      const blob = await db.getPhotoBlob(reportID);
      if (!blob || (blob.status !== "pending_moderation" && blob.status !== "approved")) {
        return errorResponse("photo_not_found", "Pothole photo not found.", 404, requestId);
      }
      const expiresAt = Math.floor(Date.now() / 1000) + 60;
      const readToken = await signPhotoReadToken(reportID, expiresAt, config.uploadSigningSecret);
      const signedURL = new URL(
        `${config.publicBaseURL.replace(/\/$/, "")}/functions/v1/pothole-photo-blob/${reportID}`,
      );
      signedURL.searchParams.set("expires_at", String(expiresAt));
      signedURL.searchParams.set("token", readToken);
      return jsonResponse(
        {
          report_id: reportID,
          status: blob.status,
          signed_url: signedURL.toString(),
          expires_in_s: 60,
        },
        200,
        {},
        requestId,
      );
    }

    return jsonResponse({ error: "not_found" }, 404, {}, requestId);
  };
}
