import { defineCloudflareConfig } from "@opennextjs/cloudflare";

// No incremental (ISR/data) cache is configured, so OpenNext uses its "dummy"
// cache: every request renders on demand and `next: { revalidate }` hints in
// lib/api/client.ts are not persisted between requests on Cloudflare. This is
// deliberate — it needs no Cloudflare resources, so a deploy cannot fail on a
// missing binding.
//
// To turn on a persistent cache (KV namespace + memory queue + the matching
// wrangler.jsonc bindings), follow "Enabling the OpenNext incremental cache"
// in docs/implementation/07-web-dashboard-implementation.md.
export default defineCloudflareConfig({});
