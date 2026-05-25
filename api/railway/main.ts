import { RailwayDatabase } from "./db.ts";
import { createRailwayApp } from "./server.ts";

function requireEnv(name: string): string {
  const value = Deno.env.get(name);
  if (!value) {
    throw new Error(`Missing required environment variable: ${name}`);
  }
  return value;
}

const database = new RailwayDatabase(requireEnv("DATABASE_URL"));
await database.ensureRailwayPhotoSchema();

const publicDomain = Deno.env.get("RAILWAY_PUBLIC_DOMAIN") ?? Deno.env.get("RAILWAY_SERVICE_API_URL");
const publicBaseURL = Deno.env.get("PUBLIC_API_BASE_URL") ??
  (publicDomain ? `https://${publicDomain}` : `http://127.0.0.1:${Deno.env.get("PORT") ?? "8000"}`);

const app = createRailwayApp(database, {
  publicApiKey: requireEnv("PUBLIC_API_KEY"),
  publicBaseURL,
  uploadSigningSecret: Deno.env.get("PHOTO_UPLOAD_SIGNING_SECRET") ?? requireEnv("TOKEN_PEPPER"),
});

const port = Number(Deno.env.get("PORT") ?? "8000");
Deno.serve({ port }, app);
