# RoadSense NS Tasks

Source of truth for RoadSense NS project work. Keep this public-safe: no secrets, credentials, private tester details, or unpublished personal context.

## Worktree Coordination

- Source of truth: this task file on the repo's `main` branch.
- In worktrees, update this file in the worktree you are using; do not edit another checkout's copy.
- Commit task updates with the code/docs change that changes task status.
- Pull or rebase from `origin/main` before long-running work and resolve task-file conflicts explicitly.
- For public repos, keep this file free of secrets, credentials, private customer details, and unpublished personal context.

## Active

- [ ] Reconcile the historical implementation backlog in `docs/implementation/08-implementation-backlog.md` with the current beta/live-web state.
- [ ] Keep deployment docs and workflows aligned with the current Railway Postgres/PostGIS + Cloudflare/OpenNext stack.
- [ ] Track beta/TestFlight issues here once external testers start reporting problems.

## Done

- [x] Created project task source of truth.
