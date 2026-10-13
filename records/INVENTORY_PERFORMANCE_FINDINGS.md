# Inventory Latency Teardown

**Date:** 12 Sep 2026
**Repos:** `ocean` (backend) · `website_frontend` (frontend)
**Hosts:** Node A (`i-061291ea974c4ea1b`) · Node B (`i-0c982c44f93bfbc0a`) · Integrations VM (`i-03efb82c808863f84`)
**Method:** live profiling on the running containers, read-only — nothing in production was changed

Pagination shipped and inventory is still slow. It was always going to be: pagination is applied at the very end of the pipeline, after the backend has already done all of the work. This document records where the time actually goes, measured.

---

## The short version

1. **One function burns ~85% of the time.** `build_frontend_filter_payload()` regex-splits every vehicle's equipment strings on every request to build the filter dropdown counts — 776–909 ms for one rooftop, ~2.7 s for a real request.
2. **The warm cache is never read.** The hourly cron writes inventory to one Redis DB under one key; the app reads a different DB under a different key. So every ~2 hours a real user's request goes out to HomeNet and waits 8–30 s.
3. **Every request loads four dealerships, not one.** `is_multiple=True` on all four rooftops means a Puente Hills request parses **27.6 MB / 1,274 vehicles** — including for a single-VIN lookup.

---

## How inventory works today

Inventory is not in Postgres. It comes from **HomeNet IOL**, a third-party SOAP feed (`services.homenetiol.com/Gateway.asmx`, action `LoadCompressedVehicles`), which returns an entire rooftop's inventory in one call. A Celery task fetches that feed hourly and stores each rooftop as a **single JSON blob in Redis**.

Because there is no query engine, every API request pulls the whole blob into Python, parses it, and filters and sorts the full list in memory. The `limit`/`offset` slice happens last — which is exactly why adding pagination changed the response size but not the server cost.

| Rooftop | Blob size | Vehicles | Redis DB | Sister stores pulled in |
|---|---|---|---|---|
| `puentehillsnissan` | 7,900,932 B | 363 | db6 | 4 (all rooftops) |
| `nissanofsanbernadino` | 7,381,490 B | 343 | db12 | 3 |
| `coronanissan` | 6,675,230 B | 307 | db11 | 3 |
| `surfcitynissan` | 5,621,641 B | 261 | db2 | 2 |

---

## The cache that never gets read

```
CRON PATH — works, but lands where nobody looks

  Celery beat  ──SOAP──>  HomeNet IOL  ──writes──>  Redis db2/db6/db11/db12
   (hourly)                (~8 s)                    key = md5(dealership_id + rooftop)
                                                     TTL 7200s, refreshed hourly
                               ^                              |
                               |                              X  different key, different DB
              on MISS (every 2h):                             |  — never read
              direct SOAP call,                               |
              user blocks 8–30 s                              |
                               |                              |
REQUEST PATH — reads the wrong place, then calls the vendor   |
                                                              |
  Browser/SSR  ──GET──>  gunicorn · Django  ──reads──>  Redis db0
  (27% is our own SSR)   (3 workers, 2 vCPU)             key = md5(rooftop) — no dealership_id
                                                         its own copy, expires every 2h
```

`_fetch_or_cache_inventory()` in `server/apps/homenet_inventory/views/inventory/inventory.py` builds its cache key **without** `dealership_id` and calls `.get()`/`.set()` with **no** `dealership_id` argument. With `REDIS_DB` unset, that pins it to db0 forever. The cron (`server/apps/homenet_inventory/tasks.py`, `refresh_homenet_inventory_cache`) passes `dealership_id=` and lands in db2/6/11/12.

**Verified on Node A, per dealership:**

- VIEW key exists **only** in db0; CRON key exists **only** in the dealership DB
- `raw_db0 == raw_dealerdb` → **`True`** — byte-identical, so redirecting the read is safe
- `HOMENET_CACHE_FIELD_LIST`, `HOMENET_CACHE_UPDATED_SINCE`, `HOMENET_CACHE_INVENTORY_FILTER` are all **unset**, so the remaining key components line up exactly
- db0 TTLs observed draining to 155–170 s then jumping back to ~7,150 s — i.e. being rewritten by user requests, not the cron

---

## Where the time actually goes

Measured inside `nisanwebsite-web-1` on Node A, warm cache, three consecutive runs in one process. Figures are for **one rooftop (363 vehicles)** — a real Puente Hills request does this across four rooftops.

```
build_frontend_filter_payload()  ████████████████████████████████████████  853 ms
json.loads()                     ████                                       82 ms
Redis GET                        ███                                        58 ms
overrides + document fee         ▌                                           7 ms
sort                             ▌                                           7 ms
dedupe                           ▏                                           1 ms
filters                          ▏                                           0 ms
                                                             one rooftop:  ~1,008 ms
                                          real request (4 rooftops):  2,880–3,021 ms
```

Everything the pipeline is nominally "about" — filtering, sorting, deduping — costs under 15 ms combined.

This endpoint is called **more often than the listing endpoint itself**: 2,546 vs 1,935 on Node A in one day.

---

## Findings, ranked by measured impact

### 1. The filter-dropdown builder re-parses every vehicle's equipment text on every request

**Owner:** `ocean` / backend — **~85% of `filter-options`**

`build_frontend_filter_payload()` in `server/apps/homenet_inventory/services/inventory_dropdowns.py:141` loops every vehicle and regex-splits `Options`, `interiorequipment` and `exteriorequipment` to build the filter counts. The underlying data only changes once an hour, but this runs on every request.

**Evidence — cProfile, 363 vehicles:**

- **1,654,221** function calls per invocation
- **195,855** `re.sub` calls · **95,364** `_normalize_option_key` calls
- **54,155** equipment items parsed per call (×3.5 for a real 4-rooftop request)
- Sample vehicle: `interiorequipment` 2,067 chars / 44 items, `standardequipment` 3,953 chars / 82 items

**Three specific defects in that file:**

- **Every item is normalized twice.** `_split_vehicle_equipment` calls `_normalize_option_key` at line 75, then the caller calls it again at line 240. Same for options: line 102, then line 228.
- **Regexes are inline string patterns**, so all 196k calls go through `re._compile`'s cache lookup instead of being precompiled at module level.
- **`build_dropdown_metadata(rows)` at line 248 is a third full pass**, re-deriving makes / body types / models-by-make that the main loop already computed.

**Fix:** Build the dropdown payload in the cron, not the request. The Celery task already has the rows in hand when it refreshes hourly — compute the payload there and cache it alongside the blob. Requests then serve it directly.

Quick partial win while that lands: removing the double-normalization and precompiling the regexes is roughly 20 lines and should about halve the cost.

---

### 2. The request path reads a different Redis cache than the cron writes

**Owner:** `ocean` / backend — **correctness bug, causes the 25–60 s tail**

See the diagram above. Consequence: roughly every two hours each rooftop's db0 entry expires and a real visitor's request makes the HomeNet SOAP call and waits. There is no stampede lock, so concurrent misses each fire their own request. The cron log shows a HomeNet fetch takes **~8 s per rooftop** (31.9 s for all four); the view's timeout is 30 s with 2 retries.

#### Why this happened

Commit **`703f716` "change in redis and services"** (11 Mar 2026) introduced per-dealership Redis sharding:

| File | Change in that commit |
|---|---|
| `services/dealership_redis_db.py` | **+153 lines** — the whole routing system, new file |
| `tasks.py` (the cron) | **+179 lines** — migrated to use it |
| `views/inventory/helpers.py` | **+42 lines** — added `dealership_id` to `RedisCache` |
| `views/inventory/inventory.py` | **1 line** — and it was a timeout bump, unrelated to caching |

The **writer** was migrated. The **reader** was never touched.

What let it survive unnoticed is the signature choice:

```python
def get(self, key, dealership_id: Optional[str] = None)
def set(self, key, value, timeout=3600, dealership_id: Optional[str] = None)
```

`dealership_id` is **optional with a silent fallback to db0**. Existing call sites kept compiling, kept running, and kept returning correct data — they just quietly began maintaining a second cache. No exception, no warning, no failing test, and because both caches hold byte-identical data there is no wrong output to notice either. The only symptom is latency, which reads as "the site is sometimes slow" rather than as a bug. (`INVENTORY_CACHE_VERSION = "v3"` suggests this area has been reworked at least three times, which is consistent with that kind of drift.)

#### Which key is actually correct?

Worth settling before writing the patch. What HomeNet returns depends only on:

```
(rooftop_collection, field_list, updated_since, inventory_filter)
```

`dealership_id` does **not** change the fetched data. So strictly, **the view's key is the more correct one** and the cron's is over-specified — two dealerships sharing a rooftop code would cache identical bytes twice.

But the cron's *DB routing* is a deliberate sharding design, and JD Power enrichment already uses it correctly. So this is not "fix a typo", it is "pick one convention and apply it consistently."

#### Two ways to fix

**Option A — minimal, ~5 lines.** Make the view match the established convention: add `dealership_id` to the cache params and pass `dealership_id=` to both `.get()` and `.set()`, matching `_inventory_cache_params()` in `tasks.py`. Self-healing — if the cron ever stops, the view fetches and writes the same key, repairing itself.

**Option B — the coherent shape.** Have the cron write everything the request path needs, under one convention per rooftop: the rows blob, the **precomputed dropdown payload** (item 1), and a **per-VIN index** (item 5). More work, but it collapses items 1, 2 and 5 into one restructure instead of three separate patches.

**Recommendation: A now, B as the target shape.**

#### Do we actually need to fix it?

Straight answer: **yes, but it will not make the inventory page feel faster.**

*What fixing it buys:*

- Removes ~96 requests/day that block 8–30 s on HomeNet (4 rooftops × 2 nodes, every 2h). That is the p99.
- Removes the stampede risk — no lock today, so concurrent misses each fire their own SOAP call and can eat the worker pool.
- Cuts HomeNet calls from ~12/hour to 4/hour.
- Frees ~27 MB of duplicate Redis.

*What it does not buy:*

- Nothing on the median request. A warm db0 hit is exactly as fast as a warm db6 hit. **The typical slow inventory page is item 1, not this.**

96 of ~15,288 daily inventory requests is **0.6%**, which lines up almost exactly with p99 being measured in seconds. Fix only this and p99 improves but nobody notices; fix only item 1 and everyone notices immediately. Do both.

*Risk of fixing: low.* Self-heals if the cron dies; the DB-index lookup is memoized per process, so it is one extra query per dealership per worker lifetime; it adds ~4 Redis connections per worker; and the data is proven byte-identical, so there is nothing to migrate or backfill.

#### A user-visible side effect of the miss path

On a fetch failure the miss path does:

```python
except Exception as exc:
    logger.error("Inventory fetch error: %s", exc)
    return []
```

It returns an **empty list**, not an error. So if HomeNet is slow or down when a cache expires, that user gets *"no vehicles found"* rather than a failure. Fixing the cache mismatch removes most of the exposure, because users stop hitting the fetch path at all.

---

### 3. Every request loads all sister-store inventories, including single-VIN lookups

**Owner:** `ocean` / backend + product decision

`is_multiple=True` on all four dealerships, so `_collect_inventory_rows()` fetches and parses the whole group on every request. A Puente Hills request loads **27,579,293 bytes / 1,274 vehicles** — measured at 288 ms just for load and parse, warm and uncontended.

| Dealership | Group size | Members pulled on every request |
|---|---|---|
| Puente Hills Nissan | 4 | Puente Hills, Corona, San Bernardino, Surf City |
| Corona Nissan | 3 | Corona, San Bernardino, Puente Hills |
| Nissan Of San Bernardino | 3 | San Bernardino, Corona, Puente Hills |
| Surf City Nissan | 2 | Surf City, Puente Hills |

The groups are asymmetric (2 / 3 / 3 / 4), which reads more like config drift than a deliberate design.

**Fix — needs a product answer first:** Confirm whether every store is supposed to show all sister stores' inventory. If it can be narrowed, that is a 3–4× cut with zero code change. If it is intended, then the dropdown payload (item 1) must be cached per *group*, not per rooftop.

---

### 4. The filters panel fires several full-pipeline requests per interaction, and caches none of them

**Owner:** `website_frontend`

- `filterOptionsRefreshKey` is bound to the whole query string in `components/inventrory/InventoryPageContent.tsx`, so every intermediate filter state triggers a fresh `filter-options` call. Real traffic shows **three different `filter-options` calls inside one second** as one user's selection settled.
- `services/public/inventoryApi.ts` sets `keepUnusedDataFor: 0` on `getInventory`, `getInventoryFilterOptions` and `getAssociateDealerships`, and `hooks/usePaginatedInventory.ts` passes `refetchOnMountOrArgChange: true`. Together these discard every inventory response on unmount and always refetch — navigating away and back re-runs the full backend pipeline.

Each of those calls costs the backend ~3 s today. There were also **2,315 CORS preflight `OPTIONS`** requests on Node A in one day, because the `X-Crypto-Key` header forces a preflight on every call.

**Fix:** Debounce or coalesce the `filter-options` refetch so one settled filter state produces one request. Give the RTK Query endpoints a real `keepUnusedDataFor` (60 s is plenty) and scope `refetchOnMountOrArgChange` rather than applying it blanket.

---

### 5. A single-VIN lookup loads the entire group's inventory to find one vehicle

**Owner:** `ocean` / backend + `website_frontend`

`retrieve()` calls `_collect_inventory_rows()` and then linear-scans for the VIN — so returning one ~30 KB vehicle costs a 27.6 MB load and parse. These run **4,653 times per day** across both nodes (2,381 + 2,272), almost entirely from Next.js SSR revalidating vehicle detail pages.

**Fix:** Have the cron also write a per-VIN key (or a Redis hash keyed by VIN) so detail lookups are a single `HGET` instead of a full blob load. Worth pairing with a frontend review of how often detail pages actually need to revalidate.

---

## Secondary items

Real, worth fixing, but not what is making inventory slow.

| # | Item | Owner | Detail |
|---|---|---|---|
| 6 | `/api/public/pages/null` | frontend | **6,152 requests/day** across both nodes — the literal string `"null"` as a page reference. ~4% of all traffic, pure waste. Also every SSR page endpoint is requested twice, with and without a trailing slash. |
| 7 | Celery beat runs on both nodes | infra | Every scheduled task executes twice. HomeNet is being called ~12×/hour when the requirement is 4. Fixing this plus item 2 makes vendor load predictable and takes it off the user request path entirely. |
| 8 | `updated_since` / `inventory_filter` unvalidated | backend | Both come straight off the query string, become part of the Redis cache key, *and* are passed into the SOAP call. Any distinct value forces a fresh HomeNet request cached for 2h in a Redis with `maxmemory=0` and `noeviction`. Mitigated by `API_CRYPTO_MODE=required` (a bare request gets 428), so "should fix", not "drop everything". The frontend never sends either param. |
| 9 | Redis has no memory ceiling | infra | `maxmemory=0`, `maxmemory-policy=noeviction` on both nodes. Fine at 60 MB today; it will OOM the box rather than evict as rooftops are added. Roughly half of current usage is the db0 copy that item 2 makes redundant. |
| 10 | nginx logs have no timing field | infra | Plain `combined` format on all three VMs — no `$request_time` or `$upstream_response_time`, so per-request latency is invisible and this investigation had to use ALB metrics instead. One-line change, big observability win. |
| 11 | Integrations VM is memory-starved | infra | 3,834 MB total, ~102 MB free, **898 MB swapped**, load 4.80 on 2 vCPUs. netdata is installed and using ~280 MB. Also `effective_cache_size` is set to 5 GB on a 3.8 GB box. Unrelated to inventory, but this host runs the shared Postgres. |
| 12 | JD Power cache reads aren't batched | backend | One sequential Redis round-trip per row on price sort/filter. Measured at only **102 ms for all 363 rows**, so genuinely minor — batch with `MGET` when convenient, don't prioritise. |

---

## What we checked and cleared

Please don't spend time here — each was measured and is fine.

- **Postgres.** `nisan_website` is 51 MB with a 100% cache hit ratio and 85/150 connections in use. Inventory never touches it. The `too many clients` errors are all from before the `max_connections` raise — that mitigation held, and `CONN_MAX_AGE=60` is now in place.
- **Next.js / frontend rendering.** Pages render in 8–124 ms measured on localhost. SSR is not a contributor.
- **Filtering, sorting and deduping.** `apply_filters` 0–11.6 ms, sort 1.5–7.7 ms, dedupe 0.6–6.7 ms. There is no case for moving inventory into Postgres to "speed up filtering" — filtering is already free.
- **Serialization.** 0 ms for a 10-row page.
- **Load balancing.** Both ALB targets healthy, near-identical volume (7,663 vs 7,625 blob-loading requests/day). Node B is not idle.
- **nginx, Cloudflare, rate limits.** Only 2 upstream timeouts and 10 client-aborted requests all day. The `limit_conn` raise from yesterday is holding.
- **`list_inventory` returning 500s.** A 500 seen during testing was a test artifact (`Invalid HTTP_HOST header: 'testserver'` from `APIRequestFactory`). Production today: 1,925×200, 3×502, 1×500.

---

## What the numbers look like to a user

From ALB `TargetResponseTime` over a six-hour window of real traffic. The site is not uniformly slow — it has a brutal tail:

| Percentile | Latency | What it is |
|---|---|---|
| p50 | 26–49 ms | Cloudflare-cached HTML and static assets — never reaches Django |
| p90 | 0.23–1.64 s | Requests queuing behind the 3-second dropdown builds on 2 vCPUs |
| p99 | 2.3–25.4 s | Landed on a cache expiry and waited for HomeNet |
| max | 6–60 s | 60.001677 s exactly — gunicorn's `--timeout 60` killing the worker |

**Why it feels random rather than "always slow":** boxes are `t3.large` — 2 vCPUs, gunicorn 3 workers × 4 threads, Python GIL. The dropdown build is CPU-bound, so threads don't help and requests queue behind each other. Most traffic is edge-cached and fast; the unlucky requests either queue behind a CPU burn or land on a cache expiry and block on a third-party SOAP call.

---

## Suggested order of work

| Order | Change | Team | Expected effect |
|---|---|---|---|
| 1 | Precompute the dropdown payload in the Celery refresh task | backend | Removes ~85% of the hottest endpoint's cost |
| 2 | Pass `dealership_id` into the inventory cache key and Redis DB selection | backend | Eliminates the 25–60 s tail; ~3× fewer HomeNet calls |
| 3 | Confirm whether the 4-way sister-store aggregation is intended | product | Potentially 3–4× less work per request, no code |
| 4 | Debounce `filter-options`; restore RTK Query caching | frontend | Cuts request count per user interaction |
| 5 | Per-VIN Redis key for detail lookups | backend | Removes 4,653 full-blob loads/day |
| 6 | Fix `pages/null`; run beat on one node; validate the two SOAP params | frontend / infra / backend | Removes waste and an abuse vector |

Items 1 and 2 are both small, self-contained changes in `ocean`, and between them they address the large majority of what users experience. They are worth doing together.

---

## How this was measured

So anyone can reproduce or challenge a number. Everything was read-only.

Profiling ran inside the live container via SSM, feeding a script into the Django shell:

```bash
aws ssm send-command --instance-ids i-061291ea974c4ea1b \
  --document-name AWS-RunShellScript --parameters file://cmd.json

# inside the instance, per command:
docker exec -i -w /app/server nisanwebsite-web-1 \
  python manage.py shell < /tmp/profile.py
```

- **Stage timings** — `time.time()` around each stage, 3 consecutive runs in one process so contention affects all stages equally.
- **Hot function** — `cProfile` on `build_frontend_filter_payload()`, sorted by cumulative time. cProfile adds ~4× overhead; the 853 ms figure is from the untimed direct measurement, not the profiled run.
- **Cache proof** — computed both key variants with the app's own `generate_cache_key()`, then checked existence and TTL in each Redis DB and compared the raw bytes.
- **Blob sizes** — `redis-cli STRLEN` / `MEMORY USAGE` / `TTL`.
- **Request counts** — `awk` over `/var/log/nginx/access.log` on both nodes.
- **Latency percentiles** — CloudWatch `AWS/ApplicationELB` `TargetResponseTime`, extended statistics p50/p90/p99 plus Maximum, 30-minute periods.

**Caveat worth stating plainly:** a `list_inventory` timing taken through `APIRequestFactory` fails at the pagination-link step because of `ALLOWED_HOSTS`, so those particular numbers are a lower bound on the real view cost rather than a clean measurement. The `filter-options` figures returned `200` and are clean.
