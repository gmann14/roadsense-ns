# Railway API

This Deno service hosts the production-compatible `/functions/v1/*` API surface when the app is deployed on Railway
instead of Supabase Edge Functions.

Required environment:

- `DATABASE_URL`
- `PUBLIC_API_KEY`
- `TOKEN_PEPPER`
- `PORT` from Railway

Optional environment:

- `PUBLIC_API_BASE_URL` overrides the externally visible API origin used in signed photo URLs.
- `PHOTO_UPLOAD_SIGNING_SECRET` overrides `TOKEN_PEPPER` for photo upload/read signatures.
- `PG_POOL_MAX` controls the Postgres pool size.

Photo uploads:

- `POST /functions/v1/pothole-photos` creates or reissues the metadata row and returns an opaque signed `upload_url`.
- `PUT /functions/v1/pothole-photo-upload/{report_id}` validates `image/jpeg`, byte size, and SHA-256 before storing
  bytes in `pothole_photo_blobs`.
- The API mirrors the uploaded object into `storage.objects` metadata so existing SQL promotion/moderation paths keep
  working.
- `GET /functions/v1/pothole-photo-image` returns an expiring signed preview URL for internal moderation.

Local checks:

```bash
deno test -A api/railway
deno cache api/railway/main.ts
```
