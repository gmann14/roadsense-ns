# RoadSense NS Web

Next.js App Router frontend for the future public RoadSense NS dashboard.

Implemented so far:

- `B090` web shell and routing scaffold
- `B091` quality-map explorer and live segment drawer groundwork
- `B092` municipality/place search and pothole drawer feed
- `B093` coverage mode and live worst-roads report
- `B094` accessibility/deploy hardening groundwork
- static municipality manifest
- typed URL-state parsing
- client-side route-state sync for `mode`, `segment`, and viewport params
- route shells for:
  - `/`
  - `/municipality/[slug]`
  - `/reports/worst-roads`
  - `/methodology`
  - `/privacy`
- unit test coverage for route shells, manifest/url helpers, and drawer/mode-switcher states

Commands:

- `npm install`
- `npm test`
- `npm run build`
- `npm run test:lighthouse`

Manual CI / deploy scaffolding:

- `.github/workflows/web-ci.yml` runs unit tests, production build, and Playwright browser smoke on demand
- `vercel.json` adds baseline response headers for deployed environments

Environment:

- `NEXT_PUBLIC_MAPBOX_TOKEN` — required for the live map canvas
- `NEXT_PUBLIC_MAPBOX_STYLE_ID` or `NEXT_PUBLIC_MAPBOX_STYLE_URL` — optional Mapbox style override
- `NEXT_PUBLIC_API_BASE_URL` — defaults to local Supabase Edge Functions
- `NEXT_PUBLIC_SUPABASE_ANON_KEY` — anon key for public read endpoints

Current scope note:

- Quality mode is now wired to the public vector-tile and segment-detail contracts.
- Municipality-first search/jump is live against the static manifest, including alias matching and ranked suggestions.
- An optional Nova Scotia-scoped Mapbox place-search fallback now activates when there is no municipality match, including a recoverable no-results state and clear-search path.
- Potholes mode isolates active markers and fetches a viewport-bounded pothole list with explicit trust/empty-state framing in the drawer.
- Coverage mode is wired to the dedicated coverage tile contract.
- `Worst Roads` now uses the live ranked-report endpoint.
- Browser smoke now covers keyboard-only navigation and phone-sized viewport behavior, and the CSS honors reduced-motion preferences.
- Repo-side Lighthouse checks now enforce accessibility and CLS budgets for the methodology/privacy trust pages.
- The main remaining web gap is real deployment linking plus hosted-environment performance validation for the live map surface rather than missing core product surfaces.
