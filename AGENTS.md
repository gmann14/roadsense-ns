# RoadSense NS Agent Instructions

RoadSense NS is an iOS app that passively collects road quality data while driving and publishes aggregated road condition data through a public map.

Current stack:
- iOS: Swift, SwiftUI, Core Motion, Core Location, Mapbox Maps SDK, SwiftData
- Web: Next.js/OpenNext deployed to Cloudflare Workers
- API: Supabase-compatible Deno function handlers deployed through Railway
- Database: Railway Postgres/PostGIS
- Source layout: `supabase/migrations` and `supabase/functions` remain the backend source of truth

## Task Tracking

- The canonical task source is the tracked project task file, usually `.claude/tasks.md` and occasionally root `tasks.md` in older repos.
- In worktrees, update the task file in your current worktree only. Do not edit the main checkout's copy from another worktree.
- Commit task-file updates together with the implementation/docs change that changes task status.
- Treat `main`/`origin/main` as the source of truth; local checkout copies can be stale until pulled.
- Public repos must keep task entries free of secrets, credentials, private customer details, and unpublished personal context.
