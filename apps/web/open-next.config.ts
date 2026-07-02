import { defineCloudflareConfig } from "@opennextjs/cloudflare";
import kvIncrementalCache from "@opennextjs/cloudflare/overrides/incremental-cache/kv-incremental-cache";

// Wires Next's ISR/data cache (the `next: { revalidate }` hints used in
// lib/api/client.ts) to a Cloudflare KV-backed implementation so cached
// responses actually persist across requests in the Workers runtime.
//
// NOTE: this only takes effect once the `NEXT_INC_CACHE_KV` binding below is
// bound to a real KV namespace in wrangler.jsonc — see the comment there.
// Without that binding, OpenNext falls back to an in-memory/no-op cache and
// every request still refetches from the API, same as before this change.
export default defineCloudflareConfig({
  incrementalCache: kvIncrementalCache,
});
