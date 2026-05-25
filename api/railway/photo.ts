import { errorResponse, jsonResponse } from "../../supabase/functions/_shared/http.ts";
import {
  type PotholePhotoPayload,
  validatePotholePhotoPayload,
} from "../../supabase/functions/pothole-photos/handler.ts";

export type StoredPhotoMetadata = {
  report_id: string;
  status: string;
  storage_object_path: string;
  content_sha256: string;
  byte_size: number;
  content_type: string;
};

export type PhotoRepository = {
  findPhoto(reportID: string): Promise<StoredPhotoMetadata | null>;
  createPendingPhoto(payload: PotholePhotoPayload, tokenHashHex: string, objectPath: string): Promise<void>;
  objectExists(objectPath: string): Promise<boolean>;
  storeUpload(params: {
    reportID: string;
    objectPath: string;
    contentType: string;
    bytes: Uint8Array;
    sha256Hex: string;
  }): Promise<void>;
};

export type PhotoHandlersDeps = {
  publicApiBaseURL: string;
  signingSecret: string;
  hashDeviceToken(deviceToken: string): Promise<string>;
  checkRateLimit(
    tokenHashHex: string,
    ip: string,
  ): Promise<{ ok: true; retryAfterSeconds: 0 } | { ok: false; retryAfterSeconds: number }>;
  photoRepository: PhotoRepository;
};

const MAX_PHOTO_BYTES = 1_500_000;

function normalizeHex(value: string): string {
  return value.startsWith("\\x") ? value.slice(2) : value;
}

function objectPathFor(reportID: string): string {
  return `pending/${reportID}.jpg`;
}

function extractClientIp(headers: Headers): string {
  const forwarded = headers.get("x-forwarded-for") ?? "";
  return forwarded.split(",")[0]?.trim() ||
    headers.get("x-real-ip") ||
    headers.get("cf-connecting-ip") ||
    "unknown";
}

async function sha256Hex(bytes: Uint8Array | string): Promise<string> {
  const input = typeof bytes === "string" ? new TextEncoder().encode(bytes) : bytes;
  const source = new Uint8Array(input);
  const digest = await crypto.subtle.digest(
    "SHA-256",
    source.buffer.slice(source.byteOffset, source.byteOffset + source.byteLength),
  );
  return Array.from(new Uint8Array(digest), (byte) => byte.toString(16).padStart(2, "0")).join("");
}

async function signedUploadToken(reportID: string, objectPath: string, secret: string): Promise<string> {
  return sha256Hex(`${reportID}:${objectPath}:${secret}`);
}

export async function signPhotoReadToken(reportID: string, expiresAtUnix: number, secret: string): Promise<string> {
  return sha256Hex(`${reportID}:read:${expiresAtUnix}:${secret}`);
}

export async function verifyPhotoReadToken(
  reportID: string,
  expiresAtUnix: number,
  token: string,
  secret: string,
  now = Date.now(),
): Promise<boolean> {
  if (!Number.isFinite(expiresAtUnix) || expiresAtUnix < Math.floor(now / 1000)) return false;
  return token === await signPhotoReadToken(reportID, expiresAtUnix, secret);
}

async function buildUploadURL(baseURL: string, reportID: string, objectPath: string, secret: string): Promise<string> {
  const token = await signedUploadToken(reportID, objectPath, secret);
  const base = baseURL.replace(/\/$/, "");
  return `${base}/functions/v1/pothole-photo-upload/${reportID}?token=${token}`;
}

export function createPotholePhotoHandlers(deps: PhotoHandlersDeps) {
  async function handleMetadata(req: Request): Promise<Response> {
    const requestId = req.headers.get("x-request-id") ?? crypto.randomUUID();

    if (req.method !== "POST") {
      return new Response(null, { status: 405, headers: { "x-request-id": requestId } });
    }

    let rawPayload: unknown;
    try {
      rawPayload = await req.json();
    } catch {
      return errorResponse("validation_failed", "Payload is malformed.", 400, requestId, {
        field_errors: { payload: "must be valid JSON" },
      });
    }

    const validation = validatePotholePhotoPayload(rawPayload);
    if (!validation.ok) {
      return errorResponse("validation_failed", "Payload is malformed.", 400, requestId, {
        field_errors: validation.fieldErrors,
      });
    }

    const payload = validation.payload;
    const objectPath = objectPathFor(payload.report_id);

    try {
      const tokenHashHex = await deps.hashDeviceToken(payload.device_token);
      const rateLimit = await deps.checkRateLimit(tokenHashHex, extractClientIp(req.headers));
      if (!rateLimit.ok) {
        return errorResponse(
          "rate_limited",
          "Device or IP exceeded pothole photo rate limit.",
          429,
          requestId,
          { retry_after_s: rateLimit.retryAfterSeconds },
          { "Retry-After": String(rateLimit.retryAfterSeconds) },
        );
      }

      const existing = await deps.photoRepository.findPhoto(payload.report_id);
      if (existing) {
        if (
          normalizeHex(existing.content_sha256) !== payload.sha256 ||
          existing.byte_size !== payload.byte_size ||
          existing.content_type !== payload.content_type
        ) {
          return errorResponse(
            "content_sha_mismatch",
            "This report_id was retried with different image bytes.",
            400,
            requestId,
          );
        }

        if (
          existing.status !== "pending_upload" || await deps.photoRepository.objectExists(existing.storage_object_path)
        ) {
          return errorResponse(
            "already_uploaded",
            "This report_id has already been submitted.",
            409,
            requestId,
          );
        }
      } else {
        await deps.photoRepository.createPendingPhoto(payload, tokenHashHex, objectPath);
      }

      return jsonResponse(
        {
          report_id: payload.report_id,
          upload_url: await buildUploadURL(deps.publicApiBaseURL, payload.report_id, objectPath, deps.signingSecret),
          upload_expires_at: new Date(Date.now() + 2 * 60 * 60 * 1000).toISOString(),
          expected_object_path: objectPath,
        },
        200,
        {},
        requestId,
      );
    } catch (error) {
      console.error("pothole-photos failed", { request_id: requestId, report_id: payload.report_id, error });
      return errorResponse("processing_failed", "Pothole photo processing failed.", 502, requestId);
    }
  }

  async function handleUpload(req: Request, reportID: string): Promise<Response> {
    const requestId = req.headers.get("x-request-id") ?? crypto.randomUUID();

    if (req.method !== "PUT") {
      return new Response(null, { status: 405, headers: { "x-request-id": requestId } });
    }

    const photo = await deps.photoRepository.findPhoto(reportID);
    if (!photo || photo.status !== "pending_upload") {
      return errorResponse("not_found", "Pending pothole photo upload not found.", 404, requestId);
    }

    const expectedToken = await signedUploadToken(reportID, photo.storage_object_path, deps.signingSecret);
    const actualToken = new URL(req.url).searchParams.get("token") ?? "";
    if (actualToken !== expectedToken) {
      return errorResponse("forbidden", "Invalid pothole photo upload token.", 403, requestId);
    }

    const contentType = req.headers.get("content-type")?.split(";")[0]?.trim().toLowerCase() ?? "";
    if (contentType !== "image/jpeg") {
      return errorResponse("validation_failed", "Pothole photo upload must be image/jpeg.", 400, requestId);
    }

    const bytes = new Uint8Array(await req.arrayBuffer());
    if (bytes.byteLength <= 0 || bytes.byteLength > MAX_PHOTO_BYTES) {
      return errorResponse("validation_failed", "Pothole photo upload size is invalid.", 400, requestId);
    }

    if (bytes.byteLength !== photo.byte_size) {
      return errorResponse("content_size_mismatch", "Uploaded image size does not match metadata.", 400, requestId);
    }

    const actualSha = await sha256Hex(bytes);
    if (actualSha !== normalizeHex(photo.content_sha256)) {
      return errorResponse("content_sha_mismatch", "Uploaded image hash does not match metadata.", 400, requestId);
    }

    await deps.photoRepository.storeUpload({
      reportID,
      objectPath: photo.storage_object_path,
      contentType,
      bytes,
      sha256Hex: actualSha,
    });

    return new Response(null, { status: 200, headers: { "x-request-id": requestId } });
  }

  return { handleMetadata, handleUpload };
}

export const testing = {
  objectPathFor,
  signedUploadToken,
  signPhotoReadToken,
  verifyPhotoReadToken,
  sha256Hex,
};
