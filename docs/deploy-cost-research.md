# Deployment Cost Research + Cold-Outreach Site Generator

Two related questions:
1. What's the most cost-effective backend for many small no-auth projects (vs. Supabase at scale)?
2. How do we spin up demo sites at scale for cold outreach?

---

# Part 1 — Backend Hosting Cost Comparison

## The Supabase reality

Supabase Free tier caps at **2 active projects per org**. Adding a 3rd forces Pro:

| Projects | Supabase cost |
|---|---|
| 1–2 | $0 (Free, pauses after 1 week inactive) |
| 3 | $45/mo ($25 base + $10 + $10) |
| 5 | $65/mo |
| 10 | $115/mo |

Custom domain is +$10/project on top. So a 5-project portfolio with custom domains = **$115/mo**.

## Cheaper alternatives, ranked

### 1. Neon Launch — $19/mo, unlimited projects in one org
- PostGIS supported (works for RoadSense)
- Scale-to-zero on idle databases
- No built-in auth/storage/realtime — pair with **Hono on Cloudflare Workers** (free tier: 100k req/day) for the API layer
- **Best fit if you want managed Postgres + 3+ projects.** Wins over Supabase Pro starting at project #3.

### 2. Self-hosted Postgres on Hetzner — ~€5/mo, ~10 small projects
- One Hetzner CX22 (€4.50/mo, 4GB RAM) running a single Postgres + PostgREST
- Each project gets its own database (or schema) inside the same Postgres
- DigitalOcean equivalent: $6/mo droplet, ~half the resources for the same price
- **Don't try to run multiple Supabase Docker stacks** — each is ~10 containers and would need 32GB+ RAM
- Tradeoff: you own backups, security patches, connection pooling, monitoring

### 3. Cloudflare Workers + D1 or Neon — near-free for small workloads
- D1 free tier: 5GB storage, 5M reads/day
- Workers free: 100k req/day
- No PostGIS on D1, so wrong for RoadSense specifically
- Great for content/CRUD apps without geospatial needs

### 4. Fly.io with Postgres — $5/mo+
- Simpler than Hetzner, more expensive
- PostGIS via standard Postgres image
- Good middle ground if you want managed-ish without Supabase prices

## Recommendation by scenario

- **RoadSense alone:** Supabase Pro ($25) is fine. PostGIS, MVT, auth, storage all out of the box.
- **3+ small public projects:** **Neon Launch ($19/mo)** + Workers. Best price/effort ratio.
- **5+ projects, willing to ops:** **Self-hosted Hetzner (~€5/mo)**. Cheapest, most control.

---

# Part 2 — Cold-Outreach Site Generator

Goal: send a cold email/DM to a local business with a link to a live, personalized demo site of what you'd build for them. Do this at scale (50–500 prospects) with as little manual work as possible.

The whole pipeline is 4 stages: **find → enrich → generate → deploy → outreach**. Each can run as a script.

---

## Stage 1 — Finding businesses

### Best source: Google Places API (New)

- Endpoint: `places.googleapis.com/v1/places:searchText`
- Cost: $32 per 1k requests for Text Search; $17 per 1k for Place Details. Free $200/mo credit covers ~6k lookups.
- Returns: name, address, phone, website (or absence of it!), rating, review count, business category, hours.
- Filter: query by city + category (e.g. "plumbers in Halifax, NS"), then filter client-side for `websiteUri` missing OR rating ≥ 4.0 (you want viable businesses).

```bash
curl -X POST "https://places.googleapis.com/v1/places:searchText" \
  -H "Content-Type: application/json" \
  -H "X-Goog-Api-Key: $GOOGLE_API_KEY" \
  -H "X-Goog-FieldMask: places.displayName,places.websiteUri,places.nationalPhoneNumber,places.formattedAddress,places.rating,places.userRatingCount,places.primaryType" \
  -d '{"textQuery": "plumbers in Halifax NS", "pageSize": 20}'
```

### Alternatives

- **OpenStreetMap Overpass API** — free, but business data is sparse outside major cities.
- **Yelp Fusion API** — free 5k/day, decent for restaurants/services but no email enrichment.
- **Apify "Google Maps Scraper" actor** — ~$7 per 1000 results, no API key needed, includes emails sometimes scraped from websites. Good for hands-off batches.

### Filter heuristic for "good prospects"

```
no website OR (website is GoDaddy/Wix template AND last_updated > 2 years)
AND rating >= 4.0
AND review_count >= 10
AND has phone OR email
```

You want businesses that are real but underserved.

---

## Stage 2 — Enriching (getting an email + branding)

Google Places rarely returns email. You need:

### Email discovery
- **Hunter.io** — $49/mo for 500 lookups, accurate. `domain → emails` API.
- **Apollo.io** — free tier gives 50 credits/mo, then $49/mo.
- **Manual fallback:** scrape `mailto:` from their site, check Facebook page (`/about` often has email).

### Branding extraction
If they have *any* existing website (even a bad one):
1. Fetch homepage HTML
2. Extract: `<title>`, meta description, primary color (sample CSS or favicon), logo (`<img>` near `<header>` or favicon)
3. Pull a hero photo from their Google Business listing photos (Place Photos API: $7/1k)

If no website: pull the storefront photo + logo guess from Google Business + use a generic neutral palette tied to their category (e.g. plumbing = navy/orange).

---

## Stage 3 — Site generation

### Template approach

One Astro or 11ty static site template with placeholders:

```
template/
  src/
    pages/
      index.astro
    components/
      Hero.astro
      Services.astro
      Contact.astro
    styles/
      theme.css        # uses CSS vars: --primary, --accent
  public/
    logo.png           # replaced per-prospect
    hero.jpg
  site.config.json     # source of truth per build
```

`site.config.json` per prospect:

```json
{
  "business_name": "Acme Plumbing",
  "tagline": "Halifax's trusted plumbers since 2008",
  "phone": "(902) 555-1234",
  "email": "info@acmeplumbing.ca",
  "address": "123 Main St, Halifax, NS",
  "services": ["Drain cleaning", "Water heaters", "Emergency repairs"],
  "primary_color": "#1e3a8a",
  "accent_color": "#f97316",
  "logo_url": "https://.../logo.png",
  "hero_image_url": "https://.../hero.jpg",
  "google_reviews": [...]
}
```

### LLM-assisted copywriting

For each prospect, call Claude/GPT once to generate:
- A custom hero headline based on their category + reviews
- 3 service cards rewritten in their voice
- An "About" paragraph that subtly references their location

Cost: ~$0.01 per site with Haiku/Sonnet.

```python
# pseudocode
copy = claude.messages.create(
  model="claude-haiku-4-5",
  messages=[{
    "role": "user",
    "content": f"Write a hero headline + 3 service blurbs for {business_name}, "
               f"a {category} in {city}. Their best reviews mention: {top_review_themes}. "
               f"Tone: warm, local, trustworthy. JSON only."
  }]
)
```

### Build

```bash
# in generator script
cp -r template/ /tmp/build-$slug
echo "$config_json" > /tmp/build-$slug/site.config.json
cd /tmp/build-$slug && npm run build  # outputs dist/
```

---

## Stage 4 — Deployment via Cloudflare Pages

### Setup (one-time)
1. Buy one domain, e.g. `previewstudio.dev`, on Cloudflare Registrar (~$10/yr).
2. Add wildcard DNS: `*.previewstudio.dev → CNAME → pages.dev`
3. Get Cloudflare API token with `Pages:Edit` permission.

### Per-prospect deploy

Cloudflare Pages has two routes:
- **Direct upload via Wrangler** — fastest, no GitHub repo needed.
- **GitHub integration** — required only if you want auto-rebuilds.

Use Wrangler direct upload for one-shot demo sites:

```bash
# Each prospect = one Pages "project"
wrangler pages project create acme-plumbing --production-branch main
wrangler pages deploy /tmp/build-acme/dist \
  --project-name acme-plumbing \
  --branch main

# Add custom subdomain
curl -X POST "https://api.cloudflare.com/client/v4/accounts/$ACCOUNT_ID/pages/projects/acme-plumbing/domains" \
  -H "Authorization: Bearer $CF_API_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"name": "acme-plumbing.previewstudio.dev"}'
```

Result: live at `https://acme-plumbing.previewstudio.dev` in ~30 seconds.

### Limits (Cloudflare Pages free)
- 500 builds/month — plenty
- 100 custom domains/account — you'll hit this. Solution: rotate (delete sites after 30 days if no response) or upgrade to Workers Paid ($5/mo, raises limits significantly).
- Unlimited bandwidth, unlimited sites.

---

## Stage 5 — Outreach

### Email
- **Resend** — $20/mo for 50k emails, simple API, good deliverability.
- Warm up the sending domain for 2 weeks before blasting.
- Send from `you@previewstudio.dev`, not the prospect's subdomain.

### Template

```
Subject: Made a free preview of a new site for {{business_name}}

Hi {{first_name}},

Saw {{business_name}} on Google — {{specific_compliment_from_review}}.

I built a quick preview of what a refreshed site could look like:
{{prospect_url}}

No catch — if you like it, I can hand it off for $X. If not, it's yours
to keep as inspiration. The link will stay live for 30 days.

— {{your_name}}
```

The personalization (specific review compliment, live link with their name) is what makes this work. Generic outreach doesn't.

### Throttling
Send 30–50/day per sending domain. Beyond that you'll trip spam filters. For higher volume, rotate 3–5 sending domains.

---

## End-to-end orchestrator (sketch)

```python
# generator.py
import json, subprocess, anthropic, requests
from pathlib import Path

def find_prospects(query: str, limit: int = 50) -> list[dict]:
    r = requests.post(
        "https://places.googleapis.com/v1/places:searchText",
        headers={
            "X-Goog-Api-Key": os.environ["GOOGLE_API_KEY"],
            "X-Goog-FieldMask": "places.displayName,places.websiteUri,places.nationalPhoneNumber,places.formattedAddress,places.rating,places.userRatingCount,places.primaryType,places.photos",
        },
        json={"textQuery": query, "pageSize": limit},
    )
    return [
        p for p in r.json().get("places", [])
        if not p.get("websiteUri") and (p.get("userRatingCount") or 0) >= 10
    ]

def enrich(prospect: dict) -> dict:
    # find email via Hunter, extract branding, etc.
    ...

def generate_copy(prospect: dict) -> dict:
    client = anthropic.Anthropic()
    msg = client.messages.create(
        model="claude-haiku-4-5",
        max_tokens=1024,
        messages=[{"role": "user", "content": build_prompt(prospect)}],
    )
    return json.loads(msg.content[0].text)

def build_site(slug: str, config: dict) -> Path:
    build_dir = Path(f"/tmp/build-{slug}")
    subprocess.run(["cp", "-r", "template/", str(build_dir)], check=True)
    (build_dir / "site.config.json").write_text(json.dumps(config))
    subprocess.run(["npm", "run", "build"], cwd=build_dir, check=True)
    return build_dir / "dist"

def deploy(slug: str, dist: Path) -> str:
    subprocess.run(["wrangler", "pages", "project", "create", slug,
                    "--production-branch", "main"], check=True)
    subprocess.run(["wrangler", "pages", "deploy", str(dist),
                    "--project-name", slug, "--branch", "main"], check=True)
    # attach custom subdomain via CF API
    ...
    return f"https://{slug}.previewstudio.dev"

def send_email(prospect: dict, url: str):
    requests.post("https://api.resend.com/emails", ...)

# main loop
for prospect in find_prospects("plumbers in Halifax NS", limit=50):
    enriched = enrich(prospect)
    copy = generate_copy(enriched)
    config = {**enriched, **copy}
    slug = slugify(enriched["business_name"])
    dist = build_site(slug, config)
    url = deploy(slug, dist)
    log_to_csv(slug, url, enriched["email"])
    # batch the email sends separately, throttled
```

---

## Cost breakdown for 100 prospects/month

| Item | Cost | What it does |
|---|---|---|
| Hunter.io Starter | **$49** | Email discovery, 500 lookups/mo (dominant cost) |
| Resend | **$20** | Outreach + follow-ups, 50k emails/mo |
| Google Places API | ~$3 | Finding businesses (mostly within $200 free credit) |
| Domain | ~$1 | `previewstudio.dev` amortized |
| Claude Haiku | ~$1 | Copywriting ~100 sites at ~$0.01 each |
| Cloudflare Pages | $0 | Hosting |
| **Total** | **~$74/mo** | |

### Scrappy minimum: ~$25/mo

The $49 Hunter.io is the dominant cost. Cut it by combining free tiers:

- **Hunter free:** 25 lookups/mo
- **Apollo free:** 50 credits/mo
- **Snov.io free:** 50 credits/mo
- Manual fallback: scrape `mailto:` from sites + Facebook `/about` pages

Combined: ~150 emails/mo for $0. Total then drops to **~$25/mo** (Resend + domain only) for 50–100 prospects.

Break-even at ~1 closed deal at $500+. Realistic conversion on personalized outreach with live demo: 2–5%.

---

## Open decisions

1. **Astro vs 11ty vs plain HTML template** — Astro gives nicer DX and easier component reuse; 11ty builds faster at scale.
2. **Keep sites live forever or expire?** — Suggest 30-day TTL with a banner: creates urgency, frees up Cloudflare domain quota.
3. **Do you want a "claim this site" flow?** — One-click Stripe checkout on the demo site itself. Increases conversion, adds complexity.
4. **Vertical specialization** — Going deep on one trade (e.g. only plumbers) lets you reuse photography, copy patterns, and case studies. Recommended over going broad.
