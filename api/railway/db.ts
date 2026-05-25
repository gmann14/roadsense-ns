import pg from "npm:pg@8.13.1";
import type { PotholePhotoPayload } from "../../supabase/functions/pothole-photos/handler.ts";
import type { PhotoRepository, StoredPhotoMetadata } from "./photo.ts";

const { Pool } = pg;

type Queryable = {
  query<T extends Record<string, unknown> = Record<string, unknown>>(
    text: string,
    values?: unknown[],
  ): Promise<{ rows: T[] }>;
};

function byteaHex(value: unknown): string {
  if (value instanceof Uint8Array) {
    return Array.from(value, (byte) => byte.toString(16).padStart(2, "0")).join("");
  }
  if (typeof value === "string") {
    return value.startsWith("\\x") ? value.slice(2) : value;
  }
  return "";
}

export class RailwayDatabase implements PhotoRepository {
  readonly pool: InstanceType<typeof Pool>;

  constructor(databaseURL: string) {
    this.pool = new Pool({
      connectionString: databaseURL,
      max: Number(Deno.env.get("PG_POOL_MAX") ?? "10"),
    });
  }

  async query<T extends Record<string, unknown> = Record<string, unknown>>(text: string, values: unknown[] = []) {
    return await this.pool.query<T>(text, values);
  }

  async ensureRailwayPhotoSchema() {
    await this.query(`
            CREATE TABLE IF NOT EXISTS pothole_photo_blobs (
                report_id UUID PRIMARY KEY REFERENCES pothole_photos(report_id) ON DELETE CASCADE,
                storage_object_path TEXT NOT NULL UNIQUE,
                content_type TEXT NOT NULL,
                byte_size INTEGER NOT NULL,
                content_sha256 BYTEA NOT NULL,
                image_bytes BYTEA NOT NULL,
                uploaded_at TIMESTAMPTZ NOT NULL DEFAULT now()
            )
        `);
  }

  async checkAndBumpRateLimit(key: string, bucketStart: Date, limit: number): Promise<boolean> {
    const result = await this.query<{ ok: boolean }>(
      "SELECT check_and_bump_rate_limit($1::text, $2::timestamptz, $3::integer) AS ok",
      [key, bucketStart.toISOString(), limit],
    );
    return Boolean(result.rows[0]?.ok);
  }

  async ingestReadingBatch(params: {
    batchID: string;
    tokenHashHex: string;
    readings: unknown[];
    clientSentAt: string;
    clientAppVersion: string;
    clientOSVersion: string;
  }) {
    const result = await this.query<{ data: unknown }>(
      `SELECT ingest_reading_batch(
                $1::uuid,
                decode($2::text, 'hex'),
                $3::jsonb,
                $4::timestamptz,
                $5::text,
                $6::text
            ) AS data`,
      [
        params.batchID,
        params.tokenHashHex,
        JSON.stringify(params.readings),
        params.clientSentAt,
        params.clientAppVersion,
        params.clientOSVersion,
      ],
    );
    return result.rows[0]?.data;
  }

  async applyPotholeAction(params: {
    actionID: string;
    tokenHashHex: string;
    actionType: string;
    lat: number;
    lng: number;
    accuracyM: number | null;
    recordedAt: string;
    potholeReportID?: string | null;
  }) {
    const result = await this.query<{ data: unknown }>(
      `SELECT apply_pothole_action(
                $1::uuid,
                decode($2::text, 'hex'),
                $3::pothole_action_type,
                $4::double precision,
                $5::double precision,
                $6::numeric,
                $7::timestamptz,
                $8::uuid
            ) AS data`,
      [
        params.actionID,
        params.tokenHashHex,
        params.actionType,
        params.lat,
        params.lng,
        params.accuracyM,
        params.recordedAt,
        params.potholeReportID ?? null,
      ],
    );
    return result.rows[0]?.data;
  }

  async findPhoto(reportID: string): Promise<StoredPhotoMetadata | null> {
    const result = await this.query<StoredPhotoMetadata>(
      `SELECT
                report_id::text,
                status::text,
                storage_object_path,
                encode(content_sha256, 'hex') AS content_sha256,
                byte_size,
                content_type
            FROM pothole_photos
            WHERE report_id = $1::uuid`,
      [reportID],
    );
    return result.rows[0] ?? null;
  }

  async createPendingPhoto(payload: PotholePhotoPayload, tokenHashHex: string, objectPath: string): Promise<void> {
    await this.query(
      `INSERT INTO pothole_photos (
                report_id,
                device_token_hash,
                segment_id,
                geom,
                accuracy_m,
                captured_at,
                status,
                storage_object_path,
                content_sha256,
                byte_size,
                content_type
            ) VALUES (
                $1::uuid,
                decode($2::text, 'hex'),
                $3::uuid,
                ST_SetSRID(ST_MakePoint($4::double precision, $5::double precision), 4326),
                $6::numeric,
                $7::timestamptz,
                'pending_upload',
                $8::text,
                decode($9::text, 'hex'),
                $10::integer,
                $11::text
            )`,
      [
        payload.report_id,
        tokenHashHex,
        payload.segment_id ?? null,
        payload.lng,
        payload.lat,
        payload.accuracy_m,
        payload.captured_at,
        objectPath,
        payload.sha256,
        payload.byte_size,
        payload.content_type,
      ],
    );
  }

  async objectExists(objectPath: string): Promise<boolean> {
    const result = await this.query<{ exists: boolean }>(
      `SELECT EXISTS (
                SELECT 1 FROM storage.objects WHERE bucket_id = 'pothole-photos' AND name = $1::text
                UNION ALL
                SELECT 1 FROM pothole_photo_blobs WHERE storage_object_path = $1::text
            ) AS exists`,
      [objectPath],
    );
    return Boolean(result.rows[0]?.exists);
  }

  async storeUpload(params: {
    reportID: string;
    objectPath: string;
    contentType: string;
    bytes: Uint8Array;
    sha256Hex: string;
  }): Promise<void> {
    const client = await this.pool.connect();
    try {
      await client.query("BEGIN");
      await ensureBlobSchema(client);
      await client.query(
        `INSERT INTO pothole_photo_blobs (
                    report_id,
                    storage_object_path,
                    content_type,
                    byte_size,
                    content_sha256,
                    image_bytes
                ) VALUES (
                    $1::uuid,
                    $2::text,
                    $3::text,
                    $4::integer,
                    decode($5::text, 'hex'),
                    $6::bytea
                )
                ON CONFLICT (report_id) DO UPDATE
                SET storage_object_path = EXCLUDED.storage_object_path,
                    content_type = EXCLUDED.content_type,
                    byte_size = EXCLUDED.byte_size,
                    content_sha256 = EXCLUDED.content_sha256,
                    image_bytes = EXCLUDED.image_bytes,
                    uploaded_at = now()`,
        [
          params.reportID,
          params.objectPath,
          params.contentType,
          params.bytes.byteLength,
          params.sha256Hex,
          params.bytes,
        ],
      );
      await client.query(
        "DELETE FROM storage.objects WHERE bucket_id = 'pothole-photos' AND name = $1::text",
        [params.objectPath],
      );
      await client.query(
        `INSERT INTO storage.objects (
                    id,
                    bucket_id,
                    name,
                    metadata,
                    path_tokens,
                    created_at,
                    updated_at,
                    last_accessed_at
                ) VALUES (
                    gen_random_uuid(),
                    'pothole-photos',
                    $1::text,
                    jsonb_build_object('mimetype', $2::text, 'size', $3::integer),
                    string_to_array($1::text, '/'),
                    now(),
                    now(),
                    now()
                )`,
        [params.objectPath, params.contentType, params.bytes.byteLength],
      );
      await client.query(
        `UPDATE pothole_photos
                SET status = 'pending_moderation',
                    uploaded_at = COALESCE(uploaded_at, now())
                WHERE report_id = $1::uuid`,
        [params.reportID],
      );
      await client.query("COMMIT");
    } catch (error) {
      await client.query("ROLLBACK");
      throw error;
    } finally {
      client.release();
    }
  }

  async getPhotoBlob(reportID: string) {
    const result = await this.query<{ content_type: string; image_bytes: Uint8Array | string; status: string }>(
      `SELECT pp.status::text, pb.content_type, pb.image_bytes
            FROM pothole_photo_blobs pb
            JOIN pothole_photos pp ON pp.report_id = pb.report_id
            WHERE pb.report_id = $1::uuid`,
      [reportID],
    );
    const row = result.rows[0];
    if (!row) return null;
    const imageBytes = typeof row.image_bytes === "string"
      ? Uint8Array.from(
        row.image_bytes.replace(/^\\x/, "").match(/.{1,2}/g)?.map((hex: string) => Number.parseInt(hex, 16)) ?? [],
      )
      : new Uint8Array(row.image_bytes);
    return {
      status: row.status,
      contentType: row.content_type,
      imageBytes,
    };
  }
}

async function ensureBlobSchema(client: Queryable) {
  await client.query(`
        CREATE TABLE IF NOT EXISTS pothole_photo_blobs (
            report_id UUID PRIMARY KEY REFERENCES pothole_photos(report_id) ON DELETE CASCADE,
            storage_object_path TEXT NOT NULL UNIQUE,
            content_type TEXT NOT NULL,
            byte_size INTEGER NOT NULL,
            content_sha256 BYTEA NOT NULL,
            image_bytes BYTEA NOT NULL,
            uploaded_at TIMESTAMPTZ NOT NULL DEFAULT now()
        )
    `);
}

export function normalizeByteaHexForTesting(value: unknown): string {
  return byteaHex(value);
}
