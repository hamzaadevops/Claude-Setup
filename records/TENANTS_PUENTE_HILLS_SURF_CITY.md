# Puente Hills & Surf City — Tenant Reference

Compiled 2026-09-17 from `project_dealerships_aws_migration.md`, `project_dealerships_cloudflare_config.md`,
`COMMAND_LOG.md`/`MIGRATION_HISTORY.md`, and `TODO.md`. This is meant to be the **single current-state
reference** for these two tenants — architecture and config, not chronological history (that's
`MIGRATION_HISTORY.md`) and not open work-items (that's `TODO.md`, which stays canonical for tasks).

**Naming note**: this project is called **Dealerships** in prose (not DealerPulse — that's a separate,
newer, unrelated project). Every AWS resource is still literally named `dealerpulse-*` and that is
correct — do not rename anything.

**Standing rule**: no write/install/restart/purge on nodeA (`i-061291ea974c4ea1b`), nodeB
(`i-0c982c44f93bfbc0a`), or the integration node (`i-03efb82c808863f84`) without asking first, every time,
even under a broad instruction. Read-only checks don't need approval.

---

## 1. Shared architecture (both tenants sit on this)

- **2 EC2 nodes** (nodeA, nodeB, both `t3.large`) behind ALB `dealerpulse-alb`, each running `ocean`
  (Django backend, containers `nisanwebsite-web/worker/beat-1`) + one `website_frontend` container **per
  tenant** + per-node Redis.
- **ALB routing, current shape (since 2026-09-14/15)**: the 443 listener's default action is a **weighted
  forward** to two *per-node* target groups — `dealerpulse-tg-nodea` (weight 35) and `dealerpulse-tg-nodeb`
  (weight 65) — not the original single `dealerpulse-tg-nginx` group, which is now **detached** (kept
  attached-to-nothing on purpose, as an instant-rollback path — do not delete without checking the
  2026-09-14 rationale first). No listener rules; nginx does hostname dispatch via `server_name`.
- **ALB stickiness is fully removed** (2026-09-16, both the per-target-group setting and the listener's
  `TargetGroupStickinessConfig`). It turned out to already be non-functional anyway — Cloudflare's
  `strip_set_cookie` cache rule strips the `AWSALB`/`AWSALBCORS` cookie before it reaches any browser, on
  every zone using the HTML-caching pattern. Nothing in the app needs it: sessions are DB-backed in the
  shared Postgres, auth is stateless `simplejwt`, no `request.session` usage anywhere, per-node Redis holds
  only content-keyed caches. **Do not re-enable stickiness "to be safe."**
- **Shared Postgres** on the integration node (`ocean-shared-postgres`), `max_connections` raised
  100→150 (2026-09-10). `CONN_MAX_AGE=60` now set by the dev team. Not currently a bottleneck (51 MB DB,
  100% cache hit ratio).
- **Redis is per-node**, not shared. Each tenant gets its own DB index for the HomeNet inventory cache:
  db2 Surf City, db6 Puente Hills, db11 Corona, db12 San Bernardino (Corona/San Bernardino have no
  infrastructure yet, just CMS rows + cron-warmed cache).
- **Rate limiting**: `limit_conn conn 300` (raised from 60) on all 4 live vhosts, plus (2026-09-12, the
  actual durable fix) an nginx `map` that exempts any request carrying `?_rsc=...` from the connection-limit
  key entirely — this is what actually stopped the repeating "site down" 503 storms caused by Next.js's
  automatic link-prefetch behavior. `limit_conn_status 429` added 2026-09-16 (was defaulting to 503,
  which is why these incidents looked like outages in ALB/Cloudflare metrics).
- **fd limits raised** on nodeA/nodeB (2026-09-12): `worker_rlimit_nofile 8192` in nginx.conf + systemd
  drop-in `LimitNOFILE=16384` (takes effect at next nginx restart). CloudWatch alarm for this
  (`dealerpulse-nginx-fd-exhaustion`) was later **deleted by someone else** — metric filter survives, alarm
  does not. Not yet recreated as of 2026-09-17.
- **Observability**: CloudWatch agent metrics (mem/swap/disk/CPU) went fully live 2026-09-15 (was missing
  an IAM permission the whole time). nginx access/error log shipping was silently dead for ~26+ hours on
  two separate occasions (a "Configure CloudWatch Agent" console wizard action overwrites the log-config
  file with a metrics-only one) — check `amazon-cloudwatch-agent.d/` directly if logs ever go quiet again,
  don't trust the agent process being "active" as proof logs are flowing.
- **Deploy mechanism**: `deploy.sh` on nodeA/nodeB is one shared script, `case "$SERVICE"` per app. For
  `website_frontend`/`website_frontend_surfcity` it's a plain `docker pull` → `docker rm -f` → `docker run`
  (not docker-compose) against a pre-built ECR image — the pipeline builds the image, `deploy.sh` never
  builds anything itself for these two.

---

## 2. Puente Hills Nissan

| | |
|---|---|
| Domain | `www.puentehillsnissan.com` (+ bare apex, 301→www) |
| Cloudflare zone | Third-party account (`18bcf34342aa0ce918118b335f5ccdb9`, "It@gkmotors.com's Account"), zone ID `d68d738c1d15ec0cd770a9533e16d5ae` — **we don't own this account**, but the user's own Cloudflare login has visibility into it |
| Dealership ID (CMS) | `6d40ffe3-ed43-4c1b-8ca9-d5d09d89ff84` |
| Local container port | `3000` |
| ECR tag | `website-frontend:latest` |
| Git clone path (both nodes) | `/opt/dealerpulse/frontend/website_frontend` |
| Pipeline branch | `main-migrated` |
| nginx cert | Self-signed (`/etc/nginx/selfsigned-test/phn-test.crt`) — reused test cert, not a real cert for this domain. ALB doesn't validate origin cert hostname/trust, so this is safe by the same reasoning used for `phn`. Noted as "not yet investigated further" whether this should ever be a real cert. |
| ACM cert (ALB-side) | Attached via SNI to the ALB's HTTPS listener |
| `is_multiple` group | **4 dealerships** (Puente Hills, Corona, San Bernardino, Surf City) — every inventory request for this tenant loads/parses all 4 rooftops' blobs (~27.6 MB). Flagged as possibly unintended drift, not yet confirmed with the business. |

**Pipeline (`main-migrated`, in `website_frontend/bitbucket-pipelines.yml`)**: Build & push to ECR
(`deployment: aws-production`) → **Deploy to Node A + Node B (atomic)** — one `aws ssm send-command`
targeting both instance IDs at once, fixed 2026-09-16/17 from the old two-step design (Node A automatic,
Node B `trigger: manual`) that was the root cause of the recurring ChunkLoadError incidents → **Purge
Cloudflare cache (Puente Hills)**, automatic, `purge_everything: true`, using token
`CF_API_TOKEN_PUENTEHILLS`.

**Status of this fix as of 2026-09-17: merged into `main-migrated`, NOT yet exercised on a real deploy.**
A test run (`#510`) was deliberately stopped before the deploy step to test stop/resume safety. The last
*real* deploy under the old design left a measured ~2.5-minute gap between nodeA and nodeB container
creation (2026-09-15 21:59:43 vs 22:02:14 UTC) — that's the fingerprint to check after the next real
deploy to confirm the gap closes to ~0-1s the way it did on Surf City.

**Revert pipeline**: `revert-puentehills` was built, then **explicitly cancelled by the user** — do not
reintroduce. Consequence: `deploy.sh`'s `website_frontend` case has no tag-override support (only
`website_frontend_surfcity` does).

**Known incident history** (see `MIGRATION_HISTORY.md` for full narrative):
- 2026-09-01: original chunk-mismatch incident, root cause at the time was independent per-node Docker
  builds. **Stale as an explanation now** — since the 2026-09-03 ECR migration both nodes pull the same
  pre-built image, so this specific mechanism no longer applies.
- 2026-09-11: recurrence, root cause at the time diagnosed as a moving `:latest` tag during rapid pipeline
  iteration; fixed live by pinning both nodes to one immutable digest + a manual cache purge.
- 2026-09-16: recurrence again, root cause **refined and fully closed this time**: deploy-timing skew
  between the two nodes (Node A finishing ~2 min before manually-triggered Node B), made worse by
  Cloudflare's static-asset cache rule caching the transient 404 with a long TTL instead of it self-healing.
  Both halves now fixed: the atomic single-SSM-call deploy (above) and a `status_code_ttl` override
  forcing `0` TTL on 4xx/5xx for the static-asset cache rule (confirmed live via API read,
  `9e2aa524e75841ec9de83813cf0d584c`).
- A **pending, non-blocking, not-yet-implemented** frontend-side belt-and-suspenders fix was proposed and
  explained to Ghulam Ali: a global `ChunkLoadError` handler doing one guarded `window.location.reload()`,
  for the separate case of a browser tab already open before *any* deploy (not specific to node-sync).

---

## 3. Surf City Nissan

| | |
|---|---|
| Domain | `surfcity.callingyounow.us` — **our own zone**, not a real external launch hostname yet |
| Cloudflare zone | `callingyounow.us`, zone ID `283d6090889e4fdd64e23e6790cfa50a`, our own account |
| Dealership ID (CMS) | `c3e9748b-353d-49b7-9599-86a3ba314fa2` (pre-existing row, no CMS work needed) |
| Local container port | `3001` |
| ECR tag | `website-frontend:latest_surfcity` |
| Git clone path (both nodes) | `/opt/dealerpulse/frontend/website_frontend_surfcity` |
| Pipeline branch | `main-surfcity` (deliberately split OUT of `main-migrated` on 2026-09-11, at the user's explicit request — a push to `main-migrated` now deploys only Puente Hills, a push to `main-surfcity` deploys only Surf City) |
| nginx cert | Same reused self-signed test cert as Puente Hills |
| `is_multiple` group | 2 (Surf City, Puente Hills) |

**Pipeline (`main-surfcity`)**: Build & push to ECR (`deployment: aws-prod-surfcity`) → **Surf City: Deploy
to Node A + Node B (atomic)** → **Purge Cloudflare cache (Surf City)** (`CF_API_TOKEN_CALLNOW_US`). This
branch is where the atomic-deploy-plus-purge design was built and proven first (cheaper blast radius),
*then* mirrored onto `main-migrated` once verified.

**Revert pipeline**: `revert-surfcity` (custom pipeline, `pipelines.custom.revert-surfcity`) — redeploys an
already-built image by 7-char commit SHA without rebuilding. Verifies the tag exists in ECR first. Only
`website_frontend_surfcity`'s `deploy.sh` case supports the tag-override 3rd argument this depends on.

**Dead code, explicitly left alone**: `website_frontend`'s pipeline file also has an older, never-actually-
used `nissan-surf-city` branch (plus `nissan-crona`/`nissan-san-bernardino`/`security-workings`) — a
completely different SSH+SCP-to-one-generic-host model from before the ALB/2-node architecture existed,
pointed at nothing real. **Ignore it; don't confuse it with `main-surfcity`.**

**3 pipeline variables still carrying Puente Hills' placeholder values** (file:
`Documentations/Migration/surfcity-pipeline-variables.txt`), flagged as a real-money defect risk if
financing goes live on Surf City's real traffic before these are corrected:
- `NEXT_PUBLIC_CAPITAL_ONE_DEALER_ID`
- `NEXT_PUBLIC_DEALER700_QUICK_QUALIFY_ID`
- `NEXT_PUBLIC_DSS_REGISTERED_HREF` (set to `https://surfcity.callingyounow.us/` per an explicit user
  correction — but Puente Hills' own value for this field is a third, unrelated legacy domain
  (`phn.omnipulse.cc`), so what this field is actually *for* is still unclear)

**Verification history**: title/branding correct, no Puente-Hills bleed-through, chunk-consistency checked
clean across both nodes after the branch split, cache rules (static-asset/HTML/`/_next/image` + response-
phase Set-Cookie strip) mirror Puente Hills' pattern exactly, purge verified live via `cf-cache-status`
MISS→HIT pattern.

---

## 4. CTO deadline (2026-09-15) — what's actually still needed

**Surf City + Corona Nissan must launch 5 October; all 4 tenants migrated and live within October.**

- Puente Hills: done, live on its real domain.
- Surf City: infra done and healthy, but only reachable at `surfcity.callingyounow.us` — **not a real
  external launch hostname**. Needs its actual production domain + DNS coordination before "launch."
- Corona Nissan / Nissan Of San Bernardino: CMS rows + cron-warmed Redis exist; **zero infrastructure** —
  no clone, cert, vhost, port, `deploy.sh` case, pipeline, Cloudflare DNS/cache rules, or
  `ALLOWED_HOSTS`/CORS entries. Full build is the same standing 8-step pattern used for Surf City (see
  `project_dealerships_aws_migration.md`'s "Standing pattern" note), but the real bottleneck last time was
  external coordination (DNS/vendor), not the infra work itself.

**Open inputs needed before 5 Oct, not yet chased down:**
1. Real production hostnames for Surf City and Corona, and who controls each zone's DNS.
2. Which pipeline pattern Corona should use — the older single-branch-multi-dealership model, or the
   decoupled per-dealership branch model (`main-surfcity`)'s pattern. **Both exist in this repo on purpose
   — ask, don't assume a default.**
3. The 3 placeholder vendor IDs above, for Surf City — and Corona will need its own real set too.
4. Whether Cox/xtime have the new hostnames registered for vendor callbacks — oldest open blocker,
   vendor lead times run to weeks, silent-lead-loss risk if missed.
5. Capacity: 2 more tenants = 2 more `website_frontend` containers per node. Not yet sized for.

---

## 5. Things relevant to these two tenants specifically, from `TODO.md`

- **Item 3a (legacy `.htm` URLs falling through to SSR)** is currently the single worst latency
  contributor on the site (up to 350s), affects Puente Hills' real traffic. `next.config.ts`'s
  `LEGACY_REDIRECTS` table lists bare paths but real traffic still arrives with `.htm` suffixes.
- **Item 11 (HomeNet inventory cache stampede)** and **item 12 (Next.js image optimizer)** are the two
  actual drivers of the recurring `dealerpulse-alb-latency-p99` alarm — both affect every tenant sharing
  the inventory/image pipeline, Puente Hills most visibly given its request volume.
- **Item 3 (`/api/public/pages/null`)**: ~11,600 requests/day, still unfixed as of 2026-09-16 — a prior fix
  attempt (`0ce4a55`) was merged then reverted (`9a0ee99`) around the 2026-09-11 ChunkLoadError incident,
  and the revert was never followed up on.

---

## 6. What I'm confused about / need your input on

1. **`NEXT_PUBLIC_DSS_REGISTERED_HREF`'s actual purpose is still unknown.** Puente Hills' value is a
   completely unrelated third domain (`phn.omnipulse.cc`), not its own site and not `callingyounow.us`.
   I don't know what "DSS" refers to or what consumes this value — worth asking whoever owns the frontend
   vendor integrations before Surf City (or Corona) goes live with financing.
2. **Whether Puente Hills' nginx cert should ever become a real cert.** It's currently reusing a
   self-signed test cert from early in the migration. Functionally fine (ALB doesn't check it), but it's
   flagged in memory as "noticed, not investigated" — I don't know if there's a reason it needs to change
   before a compliance/security review.
3. **Whether the `is_multiple` sister-store grouping (Puente Hills sees 4 rooftops, Surf City sees 2) is
   intentional product behavior or accidental drift.** This is a real, measured performance cost (every
   Puente Hills inventory request loads ~27.6 MB across 4 dealerships), and nobody has confirmed with the
   business whether that's supposed to happen.
4. **Corona / San Bernardino's actual hostnames and DNS ownership** — needed before their buildout can even
   start, and I have no information on who controls those domains.
5. **Which pipeline pattern Corona should follow** — I can build either one from a standing pattern, but
   shouldn't guess which you want.
6. **Whether the reverted `page=null` fix (`0ce4a55` → `9a0ee99`) should be reapplied.** It looked like a
   correct, clean fix for a real ~11,600-req/day bug, and I couldn't find a technical reason in the diffs
   for why it was reverted — it may have been reverted based on a mistaken belief that it caused the
   2026-09-11 ChunkLoadError incident (it didn't, per the later 2026-09-16 root-cause refinement).
7. **The deleted `dealerpulse-nginx-fd-exhaustion` alarm** — I don't know who deleted it or why; the
   metric filter is still live and it's a one-line recreate, but I don't want to assume it should just be
   silently restored without knowing if it was removed on purpose.
8. **The real, first Puente-Hills deploy under the new atomic-deploy pipeline hasn't happened yet** — I
   don't know if that's still pending purely on timing/availability, or if something else is blocking it.

Let me know which of these you want me to chase, and I'll update this file as the answers come in — happy
to keep it current as the single source of truth going forward.
