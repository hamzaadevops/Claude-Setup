# Inventory Performance — Change Requirements

**Version:** 1.0 · 12 Sep 2026
**Companion document:** `INVENTORY_PERFORMANCE_FINDINGS.md` (the diagnosis; this document is the spec)
**Repos in scope:** `ocean` (Django backend) · `website_frontend` (Next.js)
**Target branch:** `main-migrated` (`ocean`) · `staging` → `main-migrated` (`website_frontend`)

---

## 0. How to use this document

This is written to be **self-contained context for an AI coding agent** as well as a spec for a human developer. Everything an implementer needs to know is stated here, including facts that were measured on production so nobody has to re-discover them.

**If you are an AI agent reading this:**

- Section 2 is **verified ground truth**. Treat it as fact. Do not re-derive it, and do not contradict it without new measurement.
- Section 3 is **guardrails**. These are things that look like problems but are measured and fine. Do not "fix" them. Several of them were wrong guesses in an earlier draft of the analysis and were corrected by measurement.
- Section 4 contains the change requests. Implement them in the order given unless told otherwise.
- Section 5 pre-answers the questions that will come up. Read it before asking or assuming.
- Section 6 is how to verify your work on the real boxes.

**Do not deploy anything from this document without human approval.** All three VMs run live production traffic for four dealership websites.

---

## 1. System context

Inventory does **not** live in Postgres. It comes from **HomeNet IOL**, a third-party SOAP feed:

- Endpoint `https://services.homenetiol.com/Gateway.asmx`, action `LoadCompressedVehicles`
- One call returns an entire rooftop's inventory
- A Celery beat task (`refresh_homenet_inventory_cache`) fetches it hourly and stores each rooftop as **one JSON blob in Redis**
- There is no query engine — every API request loads the whole blob into Python and processes the full list in memory
- `limit`/`offset` pagination is applied **last**, which is why adding pagination reduced response size but not server cost

Four rooftops are live. Each dealership is configured with `is_multiple=True`, so a request for one dealership loads its whole sister-store group.

Request path, simplified:

```
Browser / Next.js SSR
  → Cloudflare → ALB → nginx → gunicorn → Django
    → RedisCache.get(blob)        # 5.4–7.9 MB per rooftop, ×2–4 rooftops
    → json.loads()
    → apply_overrides() / attach_document_fee()
    → apply_filters() / apply_search() / deduplicate_rows()
    → [filter_options only] build_frontend_filter_payload()
    → sort → paginate → serialize → AES-GCM encrypt → gzip
```

Relevant runtime facts:

- Both app nodes are `t3.large` — **2 vCPU**
- gunicorn: `--workers 3 --threads 4 --worker-class gthread --timeout 60`
- `API_CRYPTO_MODE=required` — every `/api/*` response is AES-256-GCM encrypted with a fresh nonce, so **no `/api/*` response is edge-cacheable**, and a request without a valid `X-Crypto-Key` gets `428`
- Redis is **per-node and local** (`REDIS_HOST=redis`), not shared between Node A and Node B
- `CONN_MAX_AGE=60` is set
- Celery `beat` currently runs on **both** nodes

---

## 2. Verified ground truth

Everything in this section was measured on Node A (`i-061291ea974c4ea1b`) against live production on 11–12 Sep 2026. Read-only; nothing was changed.

### 2.1 Data sizes

| Rooftop | Blob (bytes) | Vehicles | Redis DB (cron) |
|---|---|---|---|
| `puentehillsnissan` | 7,900,932 | 363 | db6 |
| `nissanofsanbernadino` | 7,381,490 | 343 | db12 |
| `coronanissan` | 6,675,230 | 307 | db11 |
| `surfcitynissan` | 5,621,641 | 261 | db2 |

A **Puente Hills request loads all four**: 27,579,293 bytes / 1,274 vehicles, measured at **288 ms** just to load and parse, warm and uncontended.

### 2.2 Dealership groups

| Dealership | `is_multiple` | Group size | Members loaded on every request |
|---|---|---|---|
| Puente Hills Nissan | `True` | 4 | Puente Hills, Corona, San Bernardino, Surf City |
| Corona Nissan | `True` | 3 | Corona, San Bernardino, Puente Hills |
| Nissan Of San Bernardino | `True` | 3 | San Bernardino, Corona, Puente Hills |
| Surf City Nissan | `True` | 2 | Surf City, Puente Hills |

### 2.3 Stage timings — one rooftop (363 vehicles), median of 3 runs in one process

| Stage | Time |
|---|---|
| `build_frontend_filter_payload()` | **853 ms** |
| `json.loads()` | 82 ms |
| Redis `GET` (client-side, 7.9 MB) | 58 ms |
| `apply_overrides` + `attach_document_fee` | 7 ms |
| `sort_rows_by_image_count` | 7 ms |
| `deduplicate_rows` | 1 ms |
| `apply_filters` | 0 ms |
| **Total** | **~1,008 ms** |

End-to-end `filter_options` view, 4-rooftop group: **2,880–3,021 ms** (returned `200`, clean measurement).

### 2.4 `build_frontend_filter_payload` profile (cProfile, 363 rows)

- 1,654,221 function calls per invocation
- 195,855 `re.sub` calls
- 95,364 `_normalize_option_key` calls
- 54,155 equipment items parsed per call
- Sample vehicle field sizes: `interiorequipment` 2,067 chars / 44 items · `standardequipment` 3,953 chars / 82 items · `exteriorequipment` 710 / 17 · `Options` 1,791 chars

### 2.5 Other measured costs

| Thing | Cost |
|---|---|
| JD Power enrichment, 10 rows | 19 ms |
| JD Power enrichment, all 363 rows | 102 ms |
| Serialization of a 10-row page | 0 ms (255,316 bytes output) |
| Next.js render, localhost | 8–124 ms |
| HomeNet SOAP fetch | ~8 s per rooftop (31.9 s for all four) |

### 2.6 Traffic, one day, Node A

| Endpoint | Count |
|---|---|
| `/api/public/components/` | 8,881 |
| `/api/homenet/inventory/filter-options/` | 2,509 |
| `/inventory/` | 2,197 |
| `/api/homenet/inventory/list_inventory/` | 1,889 |
| `/api/public/pages/null/` + `/api/public/pages/null` | 3,042 |
| `OPTIONS` preflights | 2,315 |
| Requests with User-Agent `node` (our own SSR) | 20,481 of 76,585 (**27%**) |
| VIN-detail SSR calls (`/api/homenet/inventory/<VIN>/`) | 2,381 (4,653 across both nodes) |

Response sizes: `list_inventory` median **249,988 B**, max **2,561,051 B**. `filter-options` median 9,773 B, max 18,873 B.

### 2.7 User-facing latency — ALB `TargetResponseTime`, 6h window

| Percentile | Value |
|---|---|
| p50 | 26–49 ms |
| p90 | 0.23–1.64 s |
| p99 | 2.3–25.4 s |
| max | 6–60 s (`60.001677` — gunicorn `--timeout 60` firing) |

### 2.8 The Redis cache-key mismatch — proven

For every dealership:

- The key built by the **view** exists **only in db0**
- The key built by the **cron** exists **only in the dealership's DB**
- `raw_db0 == raw_dealerdb` → **`True`** (byte-identical content)
- `HOMENET_CACHE_FIELD_LIST`, `HOMENET_CACHE_UPDATED_SINCE`, `HOMENET_CACHE_INVENTORY_FILTER`, `REDIS_DEALERSHIP_DB_START`, `REDIS_DEALERSHIP_DB_COUNT` are **all unset**
- db0 TTLs were observed draining to 155–170 s then jumping back to ~7,150 s — being rewritten by user requests, not the cron

---

## 3. Guardrails — do NOT do these

Each of these was measured. They look like problems and are not. An earlier draft of the analysis got several of them wrong; the measurements below are the corrections.

| # | Do not | Why |
|---|---|---|
| G1 | **Do not move inventory into Postgres to "speed up filtering."** | `apply_filters` costs **0–11.6 ms**. Filtering is already free. This would be a large migration for no gain. |
| G2 | **Do not optimise `apply_filters`, `sort_rows_by_image_count`, or `deduplicate_rows`.** | Combined they cost **under 15 ms**. |
| G3 | **Do not prioritise batching the JD Power Redis reads.** | Measured at **102 ms for all 363 rows**. Batch with `MGET` if convenient, but it is not a priority. Per-VIN cache coverage is already complete (367/363, 261/261, 307/307, 344/343). |
| G4 | **Do not chase `list_inventory` 500 errors seen in local tests.** | A 500 from `APIRequestFactory` is `Invalid HTTP_HOST header: 'testserver'` hitting `ALLOWED_HOSTS` at the pagination-link step. Production is 1,925×200 / 3×502 / 1×500 in a day. Not a real bug. |
| G5 | **Do not optimise Next.js SSR rendering.** | Pages render in 8–124 ms on localhost. Not a contributor. |
| G6 | **Do not remove or bypass the per-dealership Redis DB routing.** | `dealership_redis_db.py` is used correctly by JD Power enrichment. The inventory read path is what is inconsistent, not the routing. |
| G7 | **Do not "fix" Postgres.** | `nisan_website` is 51 MB, 100% cache hit ratio, 85/150 connections. Inventory never touches it. |
| G8 | **Do not change `deploy.sh` or the Bitbucket pipelines** as part of this work. | Out of scope and they have their own known behaviours. |
| G9 | **Do not disable response encryption (`API_CRYPTO_MODE`) unilaterally.** | It is a security/business requirement nobody has signed off changing. Raise it as a question, do not act. |
| G10 | **Do not add a second `deployment:` key to node-level pipeline steps.** | Bitbucket rejects duplicate deployment environment names per pipeline. |

---

## 4. Change requests

Ordered by measured impact. CR-1 and CR-2 together address the large majority of what users experience and should ship together.

---

### CR-1 — Stop re-parsing vehicle equipment text on every request

**Priority:** 1 (highest measured impact — ~85% of the hottest endpoint)
**Repo:** `ocean`
**Files:** `server/apps/homenet_inventory/services/inventory_dropdowns.py`, `server/apps/homenet_inventory/tasks.py`, `server/apps/homenet_inventory/views/inventory/helpers.py`

#### Problem

`build_frontend_filter_payload()` (`inventory_dropdowns.py:141`) loops every vehicle and regex-splits `Options`, `interiorequipment` and `exteriorequipment` to build filter dropdown counts. This runs on **every request**, even though the source data only changes once an hour when the cron refreshes.

The same parsing is *also* done independently in `InventoryHelpers.apply_filters()` (`helpers.py`) whenever an `options` filter is applied — via `_split_option_values()` and `_split_equipment_values()`. So the work is duplicated across two code paths.

#### Required behaviour

The request path must do **no regex parsing of equipment strings**. Parsing happens once, when the cron writes the blob.

**Required — 1a. Precompute parsed equipment per row in the cron.**

When `refresh_homenet_inventory_cache` fetches rows from HomeNet, attach pre-parsed lists to each row before caching, e.g.:

```python
row["_parsed_options"]  = _split_vehicle_options(row.get("Options") or row.get("options"))
row["_parsed_interior"] = _split_vehicle_equipment(row.get("interiorequipment") or row.get("InteriorEquipment"))
row["_parsed_exterior"] = _split_vehicle_equipment(row.get("exteriorequipment") or row.get("ExteriorEquipment"))
```

Then `build_frontend_filter_payload()` and `apply_filters()` both read those keys and fall back to parsing only if the key is absent (so the code is safe against a stale blob written by the previous version).

*Why this shape:* the parse result depends only on the row, never on the filter selection. So it is fully precomputable, and it serves both the dropdown builder and the options filter.

**Required — 1b. Precompute the unfiltered dropdown payload in the cron.**

Also cache `build_frontend_filter_payload(rows)` for the **unfiltered** case, per rooftop, alongside the blob. `filter-options` with no filter params is the most common call and the most expensive (it runs over every row). Serve it directly on a hit.

**Required — 1c. Fix the three defects in `inventory_dropdowns.py`.**

These stand on their own and are worth doing even before 1a/1b land:

1. **Double normalization.** `_split_vehicle_equipment()` already calls `_normalize_option_key()` at **line 75**; the caller calls it again at **line 240**. Same for options: normalized at **line 102**, again at **line 228**. Remove the second pass.
2. **Regexes are inline string patterns.** All 196k `re.sub` calls go through `re._compile`'s cache lookup. Precompile every pattern at module level as `re.compile(...)` constants.
3. **`build_dropdown_metadata(rows)` at line 248 is a third full pass** over all rows, re-deriving makes / body types / models-by-make that the main loop at line 178 already computed. Collect them in the main loop and delete the extra pass.

#### Acceptance criteria

- `build_frontend_filter_payload()` over 363 rows completes in **under 150 ms** (from 853 ms)
- `filter-options` for the Puente Hills group returns in **under 500 ms** (from 2,880–3,021 ms)
- The JSON payload returned by `filter-options` is **byte-identical** to the current output for the same inputs — this is a pure performance change, no behavioural change
- `apply_filters()` with an `options` filter returns the same row set as before
- Works correctly against a blob written by the *previous* version (missing `_parsed_*` keys)

#### Verification

See §6.2. Compare payloads before/after with a diff, not by eye.

#### Rollback

Revert the commit. The `_parsed_*` keys are additive; a blob containing them is still valid input to the old code.

---

### CR-2 — Make the request path read the cache the cron writes

**Priority:** 2 (eliminates the 25–60 s tail; ship with CR-1)
**Repo:** `ocean`
**File:** `server/apps/homenet_inventory/views/inventory/inventory.py`

#### Problem

`_fetch_or_cache_inventory()` builds its cache key **without** `dealership_id` and calls `.get()`/`.set()` with **no** `dealership_id` argument. `RedisCache._db_for_dealership(None)` returns `_default_db()`, and `REDIS_DB` is unset, so it resolves to **db0**.

The cron writes with `dealership_id` in both the key and the DB selection, landing in db2/db6/db11/db12.

Result: the hourly warm-up is never read. Every ~2 hours each rooftop's db0 copy expires and a real user's request makes the HomeNet SOAP call and waits ~8–30 s. There is no stampede lock, so concurrent misses each fire their own SOAP call.

**Root cause:** commit `703f716` "change in redis and services" (11 Mar 2026) added the per-dealership routing, migrated `tasks.py` (+179 lines) and `helpers.py` (+42 lines), but changed `inventory.py` by only one line — a timeout bump. The `dealership_id: Optional[str] = None` default meant the un-migrated read path kept working silently.

#### Current code

```python
        cache_params = {
            'rooftop_collection': rooftop_collection,
            'field_list': field_list,
            'updated_since': updated_since,
            'inventory_filter': inventory_filter
        }
        cache_key = self.redis_cache.generate_cache_key(cache_params)
        cached_data = self.redis_cache.get(cache_key)

        if cached_data is not None:
            return cached_data
        ...
        self.redis_cache.set(cache_key, rows, timeout=CACHE_TTL_SECONDS)
```

#### Required behaviour

`_fetch_or_cache_inventory()` takes a `dealership_id` (or `Dealership`) argument and:

- includes `dealership_id` in `cache_params`, matching `_inventory_cache_params()` in `tasks.py` **exactly** (same keys, same order-independent content)
- passes `dealership_id=` to both `.get()` and `.set()`

**Both call sites must be updated — this is easy to miss:**

1. `_collect_inventory_rows()` — iterates `for dealership, rooftop_collection in sources:`, so the dealership is already in scope.
2. `associate_dealerships()` — the inner `_raw_rows(code)` closure calls `_fetch_or_cache_inventory(code, DEFAULT_INVENTORY_FIELDS)` with no dealership. It has `member` available in the enclosing loop; thread the member's id through.

#### Acceptance criteria

- For each active dealership, the key the view computes **exists in that dealership's Redis DB** and is a cache hit
- No new blobs are written to db0 by the request path (db0 should hold only `celery-task-meta-*` keys after the old entries expire)
- A cold start (cron has not yet run for a dealership) still works — the view fetches and writes to the dealership DB, so it self-heals
- HomeNet SOAP call volume drops to the cron's rate only

#### Verification

See §6.3.

#### Rollback

Revert the commit. Both caches hold identical data, so there is nothing to migrate or backfill in either direction.

---

### CR-3 — Confirm whether sister-store aggregation is intended

**Priority:** 3 — **needs a product answer before any code**
**Owner:** product / business, then `ocean`

#### Problem

All four dealerships have `is_multiple=True`, so every inventory request loads the whole group (see §2.2). A Puente Hills request parses 27.6 MB / 1,274 vehicles instead of 7.9 MB / 363.

The group sizes are asymmetric — 2 / 3 / 3 / 4 — which looks more like configuration drift than a deliberate design.

#### Required action

1. Confirm with the business whether each dealership site is **supposed** to show its sister stores' inventory, and whether the specific groupings are correct.
2. If aggregation can be narrowed or removed, that is a **3–4× reduction in work per request with zero code change** — just configuration.
3. If it is intended, then CR-1's cached dropdown payload must be keyed per **group**, not per rooftop. Flag this back to whoever implements CR-1.

#### Acceptance criteria

A written answer recorded in this document, and the `is_multiple` / association rows corrected if needed.

---

### CR-4 — Stop the filters panel firing redundant full-pipeline requests

**Priority:** 4
**Repo:** `website_frontend`
**Files:** `components/inventrory/InventoryPageContent.tsx`, `services/public/inventoryApi.ts`, `hooks/usePaginatedInventory.ts`

#### Problem

Two compounding issues:

1. `filterOptionsRefreshKey` is bound to the whole query string, so every intermediate filter state triggers a fresh `filter-options` call. Production logs show **three different `filter-options` calls inside one second** as one user's selection settled.
2. `inventoryApi.ts` sets `keepUnusedDataFor: 0` on `getInventory`, `getInventoryFilterOptions` and `getAssociateDealerships`, and `usePaginatedInventory.ts` passes `refetchOnMountOrArgChange: true`. Together these discard every inventory response on unmount and always refetch, so navigating away and back re-runs the full backend pipeline.

Each of those calls currently costs the backend ~3 s.

#### Required behaviour

- One settled filter state produces **one** `filter-options` request. Debounce or coalesce the refetch.
- Give the three RTK Query endpoints a real `keepUnusedDataFor` (60 s is ample). Remove `keepUnusedDataFor: 0`.
- Scope `refetchOnMountOrArgChange` to where it is actually needed rather than applying it blanket.

#### Acceptance criteria

- Applying a single filter produces **one** `filter-options` request and **one** `list_inventory` request in the browser Network tab
- Navigating from `/inventory/` to a detail page and back does not refetch if within the cache window
- Filter counts still update correctly when filters change — do not break the feature to save the request

#### Note

Every one of these calls is preceded by a CORS preflight `OPTIONS` (2,315 in one day) because the `X-Crypto-Key` header forces one. Reducing request count reduces preflights one-for-one.

---

### CR-5 — Single-VIN lookups must not load the whole group

**Priority:** 5
**Repo:** `ocean` (+ a frontend review)
**File:** `server/apps/homenet_inventory/views/inventory/inventory.py` (`retrieve()`)

#### Problem

`retrieve()` calls `_collect_inventory_rows()` and then linear-scans for the VIN via `InventoryHelpers.find_by_vin()`. Returning one ~30 KB vehicle costs a 27.6 MB load and parse. These run **4,653 times per day** across both nodes, almost entirely from Next.js SSR revalidating vehicle detail pages.

#### Required behaviour

Have the cron also write a per-VIN lookup structure — either a per-VIN key (`inventory:vin:{rooftop}:{vin}`) or a Redis hash keyed by VIN — so `retrieve()` is a single `HGET`/`GET` instead of a full blob load.

Must still apply `apply_overrides()` and `attach_document_fee()` for that dealership, and JD Power enrichment for the single row, exactly as today.

#### Acceptance criteria

- `retrieve()` performs no full-blob load on a cache hit
- Response body is byte-identical to current output for the same VIN
- Falls back to the existing path if the per-VIN key is missing

#### Related frontend question

Worth a look alongside this: whether detail pages need to revalidate as often as they currently do. 4,653 SSR lookups/day for ~1,274 vehicles is roughly 3.7 revalidations per vehicle per day.

---

### CR-6 — Secondary items

Real, worth fixing, lower impact. Can be done independently.

| ID | Change | Repo / owner | Detail |
|---|---|---|---|
| 6a | Fix `/api/public/pages/null` | `website_frontend` | **6,152 requests/day** across both nodes send the literal string `"null"` as a page reference. ~4% of all traffic. Also every SSR page endpoint is requested twice, with and without a trailing slash — use the canonical URL. |
| 6b | Run Celery `beat` on one node only | infra | Currently running on both, so every scheduled task executes twice. HomeNet is called ~12×/hour when the requirement is 4. Use a lock or designate one node. |
| 6c | Validate `updated_since` / `inventory_filter` | `ocean` | Both come straight off the query string, become part of the Redis cache key, **and** are passed into the SOAP call. Any distinct value forces a fresh HomeNet request cached 2h in a Redis with `maxmemory=0`/`noeviction`. Whitelist, validate, or drop them from the public endpoint — the frontend never sends either. Mitigated today by `API_CRYPTO_MODE=required` (a bare request gets `428`), so this is "should fix", not urgent. |
| 6d | Set a Redis memory ceiling | infra | `maxmemory=0`, `maxmemory-policy=noeviction` on both nodes. Fine at 60 MB today; will OOM the box rather than evict as rooftops are added. Note CR-2 frees ~27 MB of duplicate data. |
| 6e | Add timing to the nginx log format | infra | Plain `combined` on all three VMs — no `$request_time` or `$upstream_response_time`, so per-request latency is invisible and this investigation had to use ALB metrics. One-line change. |
| 6f | Relieve Integrations VM memory pressure | infra | 3,834 MB total, ~102 MB free, **898 MB swapped**, load 4.80 on 2 vCPUs. netdata is installed using ~280 MB. `effective_cache_size` is set to 5 GB on a 3.8 GB box. This host runs the shared Postgres. |
| 6g | Batch JD Power cache reads with `MGET` | `ocean` | One sequential Redis round-trip per row on price sort/filter. Only **102 ms for all 363 rows** — do it when convenient, not as a priority (see G3). |

---

## 5. Pre-answered questions

These are the questions a developer or an agent will raise. They are answered here so nobody has to guess or re-measure.

### About the Redis cache mismatch (CR-2)

**Q: Why is the app reading db0 at all? Who chose db0?**
Nobody chose it. `RedisCache.get()` / `.set()` take `dealership_id: Optional[str] = None`. When it is `None`, `_db_for_dealership()` returns `_default_db()`, which reads the `REDIS_DB` env var and falls back to `0`. `REDIS_DB` is not set on either node. So db0 is the silent default, not a decision.

**Q: Is the data in db0 different from the data in the dealership DBs?**
No. Verified byte-for-byte: `raw_db0 == raw_dealerdb` → `True` for every dealership. Same content, two locations.

**Q: Then does the bug actually cause wrong results?**
No. It causes **wasted work and cold-start latency only**. That is exactly why it went unnoticed for six months — there is no incorrect output to observe.

**Q: Which key is the "correct" one — should I change the view or the cron?**
Change the **view** (CR-2). Strictly speaking the view's key is more *correct* — what HomeNet returns depends only on `(rooftop_collection, field_list, updated_since, inventory_filter)`, and `dealership_id` does not change the data. But the cron's per-dealership **DB routing** is a deliberate sharding design that JD Power enrichment already uses correctly. Aligning the view with the existing convention is more consistent than tearing out the sharding. Do not "fix" the cron instead.

**Q: Do I need to migrate or backfill the existing db0 data?**
No. The dealership DBs already hold identical, fresher data. Once the view reads the correct key, the db0 entries simply expire on their own TTL (max 2 hours) and are never rewritten.

**Q: What happens if the cron has not run yet for a dealership, or the cron fails?**
The view misses, fetches from HomeNet, and writes to the **dealership DB under the cron's key**. So it self-heals and the next request is a hit. This is why CR-2 is low-risk.

**Q: Will this break JD Power enrichment?**
No. JD Power already passes `dealership_id=` and reads the per-dealership DBs correctly. CR-2 makes the inventory path consistent with it.

**Q: Does the view's key really match the cron's after the change?**
It will, provided `cache_params` contains the same content as `_inventory_cache_params()`. The other components already line up: `HOMENET_CACHE_FIELD_LIST`, `HOMENET_CACHE_UPDATED_SINCE` and `HOMENET_CACHE_INVENTORY_FILTER` are all unset on both the web and worker containers, so both sides use `DEFAULT_INVENTORY_FIELDS` and empty strings. **Verify this rather than assume it** — see §6.3.

**Q: Could a dealership be assigned db0 by the router, causing a collision?**
Possible but harmless. `REDIS_DEALERSHIP_DB_START` defaults to `default_db` (0) and `REDIS_DEALERSHIP_DB_COUNT` to 16, so db0 is inside the assignable range. If a dealership were assigned db0, the cron and the view would both use db0 with the same dealership-scoped key — which is correct behaviour. Current assignments are db2/6/11/12.

**Q: How many extra Redis connections and DB queries does this add?**
Roughly 4 more Redis connections per worker process (`_connections` caches one per DB index), and one extra Postgres query per dealership per worker lifetime — `_db_for_dealership` memoizes into the class-level `_dealership_db_cache`. Negligible.

**Q: If this only affects 0.6% of requests, is it worth doing?**
Yes, but understand what it buys. It removes ~96 requests/day that block 8–30 s, removes the stampede risk, cuts HomeNet calls from ~12/hour to 4/hour, and frees ~27 MB of Redis. It does **nothing** for the median request — a warm db0 hit is exactly as fast as a warm db6 hit. **The everyday slowness is CR-1.** Ship both; do not ship CR-2 alone and expect users to notice.

**Q: Users sometimes see "no vehicles found" — is that related?**
Yes, probably. The miss path swallows fetch failures:
```python
except Exception as exc:
    logger.error("Inventory fetch error: %s", exc)
    return []
```
It returns an empty list, not an error. So if HomeNet is slow or down exactly when a cache expires, that user sees an empty inventory page. CR-2 removes most of the exposure because users stop hitting the fetch path.

### About the dropdown builder (CR-1)

**Q: The dropdown counts depend on the current filter selection. How can it be precomputed?**
Two separate things are being cached, and only one of them depends on the filter:
- The **per-row parsed equipment lists** (`_parsed_options` etc.) depend only on the row. Fully precomputable. This is where nearly all the cost is.
- The **counts** depend on which rows survive filtering. Precompute only the **unfiltered** payload (the most common and most expensive case) and compute filtered variants on the fly — which becomes cheap once parsing is precomputed.

**Q: Won't storing parsed lists make the blob much bigger?**
Somewhat — expect roughly 30–50% growth, so ~7.9 MB → ~11 MB, adding perhaps 35 ms to `json.loads()`. You are trading ~35 ms to save ~850 ms. Clearly worth it. If blob size becomes a concern later, the raw `interiorequipment`/`exteriorequipment` strings could be dropped once nothing else reads them — check first, do not assume.

**Q: Should I cache the dropdown payload per rooftop or per group?**
Depends on CR-3. Today every request is a group request, so a per-rooftop cache only helps if you can merge per-rooftop payloads into a group payload (you can — the counts are additive per key, but you must merge the label maps too and re-apply the top-30 truncation **after** merging, not before). If CR-3 concludes aggregation should be narrowed, per-rooftop becomes directly usable. **Resolve CR-3 before finalising this design.**

**Q: Can I just memoize it in-process with `functools.lru_cache`?**
It would help, but it is per-worker (3 workers × 2 nodes = 6 cold caches) and gives no invalidation hook when the cron refreshes. Prefer Redis, keyed so a cron refresh naturally supersedes it. An in-process layer on top is fine as an extra.

**Q: Is `standardequipment` parsed too? It is the biggest field.**
Not currently — `build_frontend_filter_payload` parses `Options`, `interiorequipment` and `exteriorequipment` only. `standardequipment` (3,953 chars / 82 items on the sample row) is not parsed. Do not add it without being asked; it would increase cost significantly.

**Q: Will changing the normalization change the output?**
It must not. The double normalization is idempotent — `_normalize_option_key()` applied twice gives the same result as once — so removing the second call is safe. **Prove it** by diffing the full `filter-options` payload before and after (§6.2), not by reasoning about it.

### General

**Q: Why didn't pagination help?**
Pagination is applied at the very end, after the full blob is loaded, parsed, filtered and sorted. It reduced response size, not server work.

**Q: Should we cache `/api/*` responses at Cloudflare?**
Not possible today. `API_CRYPTO_MODE=required` means every `/api/*` response is AES-256-GCM encrypted with a fresh nonce, so the bytes differ every time and nothing can be cached at the edge — structurally, for any endpoint. Changing that is a security/business decision (see G9), not an engineering one. Raise it; do not act on it.

**Q: Is the slowness a load-balancing problem? Is one node doing all the work?**
No. Both ALB targets are healthy and handle near-identical volume (7,663 vs 7,625 blob-loading requests/day). A transient 102% CPU reading on one node coincided with a cache-expiry window.

**Q: Should we scale up the boxes instead of fixing the code?**
It would mask the problem, not fix it. The nodes are `t3.large` (2 vCPU) and the dropdown build is CPU-bound, so more cores would raise concurrency — but you would be paying to run 850 ms of avoidable regex work per request. Fix CR-1 first, then re-measure before deciding on instance size.

**Q: How do I test any of this without a production crypto key?**
Call the view directly inside the container rather than over HTTP — see §6.1. Note that `APIRequestFactory` requests fail at the pagination-link step with `Invalid HTTP_HOST header: 'testserver'` unless you add `testserver` to `ALLOWED_HOSTS` in your test settings, or use the Redis/helper functions directly (which is what all the measurements in §2 did).

---

## 6. Verification playbook

All commands below are read-only and were used to produce §2. Run them on Node A (`i-061291ea974c4ea1b`) unless stated.

### 6.1 Running code inside the live container

```bash
# from a workstation with AWS CLI + SSM access
aws ssm send-command --instance-ids i-061291ea974c4ea1b \
  --document-name AWS-RunShellScript --parameters file://cmd.json

# inside the instance, feed a script to the Django shell:
docker exec -i -w /app/server nisanwebsite-web-1 \
  python manage.py shell < /tmp/script.py
```

Write the commands array to a JSON file and pass `file://...` — do **not** build it inline if any command contains `$(...)`, or the local shell will expand it before it reaches AWS.

### 6.2 Verifying CR-1

```python
import json, time
from apps.homenet_inventory.views.inventory.helpers import RedisCache
from apps.homenet_inventory.views.inventory.constants import DEFAULT_INVENTORY_FIELDS
from apps.homenet_inventory.services.inventory_dropdowns import build_frontend_filter_payload
from apps.tenancy.models import Dealership

d = Dealership.objects.filter(homenet_dealership_code='puentehillsnissan').first()
rc = RedisCache()
k = rc.generate_cache_key({'dealership_id': str(d.id), 'rooftop_collection': 'puentehillsnissan',
                           'field_list': DEFAULT_INVENTORY_FIELDS, 'updated_since': '', 'inventory_filter': ''})
rows = json.loads(rc.get_connection(str(d.id)).get(k))

t0 = time.time(); payload = build_frontend_filter_payload(rows); t1 = time.time()
print('ms =', round((t1-t0)*1000))
print('payload sha =', __import__('hashlib').sha256(
      json.dumps(payload, sort_keys=True, default=str).encode()).hexdigest())
```

Capture the `payload sha` **before** your change and compare after. It must be identical.

Target: `ms` under 150 (baseline 853).

### 6.3 Verifying CR-2

```python
import json
from apps.homenet_inventory.views.inventory.helpers import RedisCache
from apps.homenet_inventory.views.inventory.constants import DEFAULT_INVENTORY_FIELDS
from apps.tenancy.models import Dealership

rc = RedisCache()
for d in Dealership.objects.filter(is_active=True):
    code = (d.homenet_dealership_code or '').strip()
    if not code:
        continue
    base = {'rooftop_collection': code, 'field_list': DEFAULT_INVENTORY_FIELDS,
            'updated_since': '', 'inventory_filter': ''}
    k_view = rc.generate_cache_key(base)                                   # old view key
    k_cron = rc.generate_cache_key(dict(base, dealership_id=str(d.id)))    # cron key
    c0, cd = rc.get_connection(None), rc.get_connection(str(d.id))
    print(code, 'db=', rc._db_for_dealership(str(d.id)))
    print('   view key in db0        :', bool(c0.exists(k_view)), 'ttl', c0.ttl(k_view))
    print('   cron key in dealer db  :', bool(cd.exists(k_cron)), 'ttl', cd.ttl(k_cron))
```

**Before the fix:** view key present in db0, cron key present in the dealership DB.
**After the fix:** the view must compute `k_cron` and hit the dealership DB. db0 should stop receiving new inventory blobs; existing ones expire within 2 hours.

Confirm db0 drains:

```bash
docker exec nisanwebsite-redis-1 redis-cli -n 0 --scan --pattern 'inventory:v3:*'
```

### 6.4 Confirming the cron is healthy

```bash
docker logs nisanwebsite-worker-1 --since 2h 2>&1 \
  | grep -E 'Refreshed cache for dealership|HomeNet cache refresh complete'
```

Expect four `Refreshed cache for dealership_id=... items=N redis_db=N` lines per run.

### 6.5 Measuring user-facing impact

```bash
aws cloudwatch get-metric-statistics --namespace AWS/ApplicationELB \
  --metric-name TargetResponseTime \
  --dimensions Name=LoadBalancer,Value=app/dealerpulse-alb/dc80177beaa3aa2f \
               Name=TargetGroup,Value=targetgroup/dealerpulse-tg-nginx/fd3cc6516b477ef1 \
  --start-time <ISO8601> --end-time <ISO8601> --period 1800 \
  --extended-statistics p50 p90 p99 --statistics Maximum
```

Success looks like p99 dropping out of the seconds range and the 60 s maxima disappearing.

### 6.6 Endpoint counts from nginx

```bash
awk '{print $7}' /var/log/nginx/access.log | sed 's/?.*//' | sort | uniq -c | sort -rn | head -15
awk '$7 ~ /filter-options/ && $9==200 {print $10}' /var/log/nginx/access.log \
  | sort -n | awk '{a[NR]=$1} END {print "median="a[int(NR/2)], "max="a[NR], "n="NR}'
```

---

## 7. Environment reference

| Item | Value |
|---|---|
| AWS account / region | `409289617504` / `us-west-2` |
| Node A | `i-061291ea974c4ea1b` — `t3.large`, 2 vCPU |
| Node B | `i-0c982c44f93bfbc0a` — `t3.large`, 2 vCPU |
| Integrations VM | `i-03efb82c808863f84` — hosts shared Postgres |
| ALB target group | `targetgroup/dealerpulse-tg-nginx/fd3cc6516b477ef1` |
| `ocean` containers | `nisanwebsite-web-1` / `-worker-1` / `-beat-1` / `-redis-1` |
| Shared Postgres | `ocean-shared-postgres` on the Integrations VM, `10.0.1.92:5432` |
| Redis | per-node, local (`REDIS_HOST=redis`), **not** shared between nodes |

Relevant env values confirmed on both nodes:

```
API_CRYPTO_MODE=required
CONN_MAX_AGE=60
DEBUG=False
HOMENET_CACHE_REFRESH_SECONDS=3600
HOMENET_CACHE_TTL_SECONDS=7200
JDPOWER_MAX_VINS_PER_REQUEST=50
REDIS_HOST=redis
REDIS_DB                      (unset → 0)
HOMENET_CACHE_FIELD_LIST      (unset)
HOMENET_CACHE_UPDATED_SINCE   (unset)
HOMENET_CACHE_INVENTORY_FILTER(unset)
REDIS_DEALERSHIP_DB_START     (unset)
REDIS_DEALERSHIP_DB_COUNT     (unset)
```

---

## 8. Open questions for the team

Record answers here as they come in.

| # | Question | Owner | Answer |
|---|---|---|---|
| 1 | Should each dealership site show sister-store inventory, and are the 2/3/3/4 groupings correct? (CR-3) | product | |
| 2 | Can the public inventory endpoints be exempted from response encryption, or is it a hard requirement? (G9) | security / business | |
| 3 | Do vehicle detail pages need to revalidate ~3.7×/vehicle/day? (CR-5) | frontend | |
| 4 | Which node should own Celery beat? (6b) | infra | |
| 5 | Are `updated_since` / `inventory_filter` used by any consumer at all? (6c) | backend | |
