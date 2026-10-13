> **Knowledge file (reference).** Extracted 2026-10-13, read-only, from the DealerPulse docs, scripts and local repo clones.
> Citation keys map to files in this pack: ARCH, INC, CTO, MSG, FIX, DES, MON, PRE, SMS, TPS, ASK = `records/DealerPulse/{ARCHITECTURE, INCIDENT_2026-09-16, INCIDENT_REPORT_CTO, INCIDENT_MESSAGE, BACKEND_FIXES, DESIGN_OVERVIEW, MONITORING, PRE_MOVE_CHECKLIST, SMS_ISSUE_MUDASSAR, THIRD_PARTY_STATUS, ASK_SENIOR_DEV}.md`;
> SETUP, cc, ch, ct, pf, pt, p, nd, kc = `records/DealerPulse/scripts/{SETUP.md, check-celery.sh, check-health.sh, check-thirdparty.sh, thirdparty-probe-fast.py, thirdparty-probe-twilio.py, thirdparty-probe.py, netdata-dealerpulse.conf, uptime.callingyounow.us.conf}`;
> MEM = `memory-export/project_dealerpulse.md`; MH = `records/Migration/MIGRATION_HISTORY.md`; BE / FE = the `dp_backend_v2` / `dp_frontend_v2` repos (local HEAD `88654f8d` 2026-09-29 / `b6873a88` 2026-09-15).
> The newest live observation of the droplet in any source is **2026-09-22**. Everything about live state is at least three weeks old. **Ask before logging in to or probing the droplet.**

# DealerPulse (DigitalOcean) — operations reference

## 0. Naming hazards (read first)
- **"DealerPulse" means two things.** Every AWS resource of the separate *Dealerships* project is named `dealerpulse-*`. This file covers only the DigitalOcean product (MEM:11-12).
- **"Surf City" means three things:** Surf City Nissan (a Dealerships tenant on AWS, `surfcity.callingyounow.us`); `surfcity.dealerpulse.cloud` (a dead DealerPulse v1 tenant); and `Surfcity-Live` (this droplet's hostname) (ARCH:20, 299-301; MH:982).
- **callingyounow.com vs .us.** `app.callingyounow.com` is an unrelated product on the DealerPulse droplet (ARCH:285-286). `*.callingyounow.us` is the Dealerships/AWS side; `uptime.callingyounow.us` is the Kuma box on AWS, not on the droplet (MON:34-36).
- **Two local files with misleading names:** `dealerpulse-infra-diagram.html` (2026-09-08, before the rename) is the **Dealerships** AWS diagram. `dealerpulse.dump` (2026-09-02) is very likely the Dealerships chat_back DB (whose database is named `dealerpulse`), not a DealerPulse backup [assumed; not opened].
- The **OpenRouter credits outage of 2026-10-02** (MH:3451-3472) hit the **Dealerships** chatbot, not DealerPulse.

## 1. Architecture

### 1.1 Host [verified 2026-09-17 unless noted]
- **Identity:** DigitalOcean droplet, public `146.190.132.236`, private `10.124.0.3`, hostname `Surfcity-Live` (ARCH:19-20).
- **Size and cost:** 2 vCPU, 8 GB RAM, 90 GB disk. $42/mo plus $12.60/mo backups (ARCH:21-22).
- **Region:** sfo3, the same as the DB (INC:323).
- **State at inspection:** uptime 202 days, never rebooted. **No swap.** Disk 30%. 4.8 GB of memory free (ARCH:23-26).
- **Backups:** DO automated daily, 7-day retention, **never restored** (ARCH:27).
- **Access:**
  - SSH alias `dealerpulse` (root, key `~/.ssh/digitalocean`).
  - Key-only login (`PasswordAuthentication no`, `PermitRootLogin yes`) (PRE:26).
  - Port 22 is open to the world (ARCH:486).
  - Reading the backend `.env` is blocked by the tooling classifier (MEM:54-56).
- **Deploy dirs:** `/opt/dealerpulse/{backend,frontend}/`, `/opt/callingyounow/{backend,frontend}/` and `/opt/deployer/`. Each holds a compose file plus `.env` (ARCH:118-120).

### 1.2 Containers [verified `docker ps` 2026-09-17] (ARCH:39-51)

| Container | Port | Notes |
|---|---|---|
| dealerpulse_backend-web_blue-1 (`fluten/dealerpulse_backend`) | 127.0.0.1:8004 | healthy; the only colour running |
| dealerpulse_backend-worker-1, -beat-1, -redis-1 | — | |
| dealerpulse_frontend-frontend-1 (`fluten/dealerpulse_frontend`) | 127.0.0.1:8014 | |
| callingyounow_backend-web_blue-1 (+ worker, beat, redis) | :8007 | separate product |
| callingyounow_frontend-frontend-1 | :8018 | separate product |
| netdata | 19999 (firewalled) | |

- **`web_green` is not running** (ARCH:63).
- **The running backend code is likely newer than the docs describe.** The backend image observed was `899c747c` (2026-09-16), but the local clone is 41 commits later and the pipeline auto-deploys `main` [assumed].
- **Not in Docker** (ARCH:53-61):
  - Host Postgres 16.9 on `0.0.0.0:5432`. **Not the app DB.**
  - Host `redis-server` on 127.0.0.1:6379, purpose unknown.
  - nginx 1.26.0 on :80/:443.
  - otel-plugin, part of netdata.

### 1.3 Compose (BE/docker-compose.yml)
- Project `dealerpulse_backend`. Image `fluten/dealerpulse_backend:${IMAGE_TAG}`. **`IMAGE_TAG` must be set for any manual compose command.**
- **Web colours:**
  - `web_blue` runs daphne on 8004; `web_green` on 8006.
  - Health check calls `/health/ready/` (15 s interval, 5 s timeout, 3 retries, 40 s start period).
  - `RUN_MIGRATIONS=1` on web.
- **worker:** `celery … --concurrency=3`.
- **beat:** `--pidfile=` (empty), which disables the single-instance lock.
- **worker and beat have no restart policy and no health check.**
- **redis:** `appendonly`, `maxmemory 1gb`, `allkeys-lru`. At the cap it evicts keys, including queued tasks.
- **Resource limits:** about 5.1 GB is reserved with one colour, about 6.6 GB during a blue/green overlap. CPU limits sum to 6 on 2 vCPU (ARCH:239-248).
- **Health endpoints** (BE/server/coresite/urls.py:38-63):
  - `/health/live/` always returns 204.
  - `/health/ready/` and `/health/startup/` return 204 when the DB is reachable, otherwise 503.
  - `/` redirects to `/api/admin/`.

### 1.4 nginx (ARCH:254-279)
- **Already done:** forwarded headers are set; `/ws/` WebSocket is configured correctly; Let's Encrypt via `certbot.timer` with 15 certs on the host.
- **Gaps:**
  - `client_max_body_size` is unset, so the 1 MB default applies and larger uploads get 413.
  - No `proxy_read_timeout`, so the 60 s default applies.
  - No HTTP/2.
- `/media/` is served directly, with CORS limited to `https://app.dealerpulse.cloud`.

### 1.5 Domains and DNS
- **Hostnames:**
  - `app.dealerpulse.cloud` → :8014
  - `app.backend.dealerpulse.cloud` → :8004 (blue) or :8006 (green)
  - `app.callingyounow.com` / `app.backend.callingyounow.com` → :8018 / :8007
- **DNS host:** Hostinger (`dns-parking.com`), TTL 4 h, **no CDN/WAF**. The account holder is unknown (ARCH:127-130, 523).
- **The frontend picks its backend from a hardcoded hostname map** (FE/src/site-config.ts:13-63). **Any unlisted hostname falls back to the staging backend `https://dp2.back.fluten.xyz`** (line 61).

### 1.6 Database: DO Managed Postgres (off-droplet)
- **Connection:** host `dp2-live-do-user-13151402-0.g.db.ondigitalocean.com` (143.244.183.125), port **25060**, DB `defaultdb`, user **`doadmin`** (superuser), `sslmode=require` (ARCH:71-84).
- **Cluster** (INC:318-328):
  - `dp2-live`, plan `db-s-2vcpu-4gb`, PostgreSQL 18, 60 GB.
  - **1 node, no standby.** `max_connections` 100, no pools.
  - **Trusted Sources: none.**
  - Daily backups at 10:19.
- **Settings in force:** slow-query logging on at 1000 ms; `idle_in_transaction_session_timeout` 24 h; connection logging on; `pg_stat_statements` not installed (INC:241-302).
- **Django DB config** (BE database.py:58-73):
  - `ATOMIC_REQUESTS: True`, `CONN_MAX_AGE: 0`, `CONN_HEALTH_CHECKS: True`.
  - **No connect, statement or lock timeouts and no keepalives.**
- **Droplet snapshots do not back up app data.**
- **The droplet's own Postgres (:5432):**
  - Not used by the app.
  - A stale WrenAI database (`dealerpulse`, user `wrenuser`), reachable from several IPs including the unidentified `3.43.243.0/30`.
  - Whether it holds real customer data is unknown (ARCH:105-116, 452-477).

### 1.7 Redis
Redis is the Celery broker and result backend **and** the WebSocket channel layer (DES:78, 85-87).

### 1.8 Celery beat schedule (UTC)

| Task | Schedule | What stops if beat dies |
|---|---|---|
| Recording cleanup | 02:00 | disk fills with recordings |
| Catch-phrase backfill | 02:30 | call analysis |
| Appointment reminders | every 5 min | reminder calls |
| **Tony recovery calls** | **every minute** | no-show recovery (changed from 10 min on 2026-09-29) |
| Appointment confirmations | every minute | confirmation texts |
| BDC hourly reports | hourly | BDC reports |
| Attendance prompts | every 10 min | attendance prompts |

- Task limit: 20 min (soft limit 15 min).
- **Two tasks are short-circuited with `return;` in code** (commit 75c46c22): `notify_unbooked_booking_intent` and `process_call_transcript_summary`. Both features are effectively **off**.

### 1.9 Media (ARCH:352-382)
- 196 MB in total. `call_recordings/` is 193 MB, a 7-day cache re-fetched from Twilio and cleaned nightly.
- About 2.7 MB of permanent user uploads. **S3 is coded but not enabled**, so the only backup of those uploads is the droplet snapshot.
- **Journal logs are uncapped at 4.3 GB.**

### 1.10 Third parties (ARCH:319-345; TPS:13-20)

| Service | Use | Last known status |
|---|---|---|
| Twilio | Numbers, SMS, voice, recordings | API healthy 2026-09-18. **Staff SMS failing** (I-2) |
| Retell | AI voice agents (5 agent IDs in code) | **Key missing; outbound calls fail** (I-5) |
| XTime / Cox | Writes service appointments to the DMS (synchronous) | healthy |
| Wassenger | WhatsApp gateway | healthy |
| OpenRouter | LLM | key missing |
| AssemblyAI | Call transcription | **account disabled at the provider** |
| SMTP (`mail.spacemail.com:465`) | Email | in use, not monitored |
| AWS S3 | File storage | coded, not enabled |
| Vapi | Second voice provider | undocumented |

- **Only the four TWILIO_* values are Fernet-encrypted (SecretManager).** Probing the raw env var returns 401 and looks like an outage, so always go through `TwilioConfigService` (TPS:97-102).
- **`MASTER_ENCRYPTION_KEY` exists only in the droplet `.env` and must never be regenerated** (PRE:41-54).
- **Credentials are global, not per tenant.**

### 1.11 Other things on the droplet and in staging
- **callingyounow:** a full second product, owner unknown.
- **v1 tenants:** `surfcity.dealerpulse.cloud` serves a site whose backend is gone. Certs are still renewed for dead hosts (ARCH:291-311).
- **Staging:** the `staging` branch deploys to `dp2.back.fluten.xyz` on the legacy `combined` droplet (137.184.45.248), using `kill -9`, `fuser -k` and `docker container prune -f`. Whether staging uses the prod DB is unknown (ARCH:524-533).
- **Kuma monitoring** runs on the AWS team-VPN box, not on the droplet (MON:30-41).

## 2. Deploy flow

### 2.1 Backend, production (BE/bitbucket-pipelines.yml:10-178)
1. On a push to `main`, build and push `dealerpulse_backend:$IMAGE_TAG` and `:latest_production` to Docker Hub.
2. `scp` the compose file to `/opt/dealerpulse/backend/`.
3. Over SSH: read `active_env` and pick the other colour (green 8006 if blue, otherwise blue 8004).
4. Wait for the new port to be free, then `docker compose up -d web_$NEW`.
5. Poll the container health 30 × 5 s.
   - If it isn't healthy: dump 100 log lines, stop the new colour, exit 1.
   - **The old colour keeps serving, which is the safe failure path.**
6. `nginx -t`, then back up the vhost to `.bak`, then `sed -i "s/:$OLD_PORT/:$NEW_PORT/g"` on `/etc/nginx/sites-enabled/app.backend.dealerpulse.cloud`. Then `nginx -t` again and reload.
7. Stop the old colour and write `active_env`.
8. `docker compose up -d --force-recreate worker beat`.
9. `docker image prune -af` and `docker builder prune -af`.

Pipeline variable names: DOCKER_USERNAME, DOCKER_TOKEN, PROD_SSH_KEY_B64, PROD_SSH_HOST, SSH_PORT, SSH_USER.

**Weaknesses:**
- No automatic rollback after the switch.
- The health gate only proves the DB is reachable.
- The `sed` is a global replace over the whole vhost.
- worker and beat are recreated after the traffic switch.
- The new colour runs `migrate` while the old one still serves traffic.
- A manual `docker compose up -d` without a service name would start both colours and race migrations (ARCH:208-235).

### 2.2 Frontend (FE/bitbucket-pipelines.yml:10-66)
- Build and push `dealerpulse_frontend:$IMAGE_TAG` and `:production_latest`.
- `scp` the compose file, then `docker compose up -d`. **There is no blue/green and no health gate.**
- Old hashed chunks are kept for 30 days in the `frontend_assets` volume.

### 2.3 Rollback (not documented by the team; [assumed] from the pipeline; needs approval)
- **Preferred:** revert the commit on `main`, or re-run the previous good pipeline. Both go through the same health gate.
- **Manual backend flip:**
  1. Start the previous colour (`docker compose start web_<old>`, or `IMAGE_TAG=<old> docker compose up -d web_<old>`).
  2. Wait for it to report healthy.
  3. Restore the `.bak` vhost or reverse the port. Then `nginx -t` and reload.
  4. Stop the bad colour, write `active_env`, and recreate worker and beat with the old tag.
- The `.bak` is only one generation deep.
- **Possible hazard:** the `.bak` is written into `sites-enabled/`. On the Kuma box, a `.bak` inside `sites-enabled` was parsed as live config (MH:3066). Check with `sudo nginx -T 2>&1 | grep -iE 'conflicting|\.bak'`.

## 3. Known issues

**I-1 · 2026-09-16 backend outage (thread exhaustion)**
- **Symptom:** from 20:00 to 23:00 UTC the site looked up but stopped answering.
  - 171 live calls heard silence; 479 call logs were abandoned.
  - WebSocket failures and login 504s.
- **Root cause (mechanism certain, trigger unproven):**
  - Requests blocked on DB connections that went silent; threads climbed from 12 to 142.
  - Nothing bounds a DB wait: no statement, lock or connect timeout, no keepalives, no pool, and `ATOMIC_REQUESTS` is on.
- **What it was not:** load, OOM, a crash, or DigitalOcean.
- **How it ended:** a deploy replaced the container.
- **Prevention is not shipped:** no DB timeouts in code at local HEAD.
- **Open actions:**
  - Backend: add DB timeouts and keepalives, bound concurrency.
  - Infra (needs approval): ship logs off the box; set `idle_in_transaction_session_timeout` to 60 s; install `pg_stat_statements`; add a DO connection pool. Raise nginx `proxy_read_timeout` to 90 s **only after** the DB timeouts land (INC:492-493).
- **Detection now:** Kuma "DealerPulse Backend Threads" (>30) and "Error Rate" (>10 per minute).
- **Prompt:** "DealerPulse is down / calls going silent / staff can't log in."

**I-2 · All staff SMS failing**
- **Symptom:** staff stopped receiving booking and missed-call texts. 32 recipients affected since at least 2026-09-08.
- **Cause:** `send_sms_task.py:39` falls back to `settings.TWILIO_FROM_NUMBER`, which is not one of the account's 13 numbers, so Twilio returns HTTP 400. 3,484 failures in 3 days.
- **Not affected:** customer confirmation and BDC texts.
- **Status:** open as of 2026-09-22.
  - The fix is a valid number or Messaging Service `MGb1ff1ae67e06c17775739a7387b53543`. It could be an env-only change.
  - The Kuma Twilio monitor stays green because it checks auth, not delivery.
- **Owner:** backend team (Mudassar).
- **Prompt:** "Staff aren't getting booking texts."

**I-3 · Call transfer failures never recorded**
- **Symptom:** none visible; warnings saying `name 'disconnection_reason' is not defined`.
- **Status:** fixed in code (11a329a4, 2026-09-22). Whether it is deployed is unknown.

**I-4 · `get-recording` returns 502**
- **Symptom:** a call recording fails to play, about 12% of attempts.
- **Cause:** the Twilio recording isn't ready yet, which raises `RecordingDownloadFailed` (declared as 502). It is not a credentials problem.
- Nothing is lost. **First answer: wait a minute and retry.**

**I-5 · `RETELL_API_KEY` missing**
- **Symptom:** confirmation, reminder and Tony calls are not placed (75 errors in 24 h).
- **Status:** unknown. It may have been restored since Tony moved to every minute on 2026-09-29.
- **Check:** the startup log line "RETELL_API_KEY is not set". Confirm with the backend team; don't fix it blind.

**I-6 · OpenRouter and AssemblyAI off**
- **Symptom:** no transcripts, and no follow-up for callers who didn't book.
- **Status:** both tasks are short-circuited in code. The feature being off is a product decision for the backend team or CTO.

**I-7 · nginx upload limit and read timeout**
- **Symptom:** uploads over 1 MB get 413; slow XTime requests get 504.
- **Status:** two one-line fixes are pending approval. The timeout change comes only after I-1's DB timeouts.

**I-8 · CRITICAL: managed DB reachable from the internet, app connects as superuser**
- **Finding:** Trusted Sources is empty, and the app connects as `doadmin`. Still open on 2026-09-22 (MH:2861-2865).
- **The `doadmin` password was printed into a transcript on 2026-09-18. Treat it as exposed and rotate it.**
- **Fix:**
  1. Enable Trusted Sources restricted to the droplet. This is a DO panel change, fast and reversible.
  2. Then create a least-privilege role.
- **Blockers:** the other DB clients, whether staging uses this DB, and who holds the DO account.
- **Re-test after the fix:** a TCP connect from another machine should fail.

**I-9 · Droplet hygiene**
- The droplet's own Postgres on 5432 is open to the world in ufw, though `pg_hba` restricts who can log in.
- Stale ufw rules for ports 8000 and 465; SSH open to the world.
- **Five webhooks accept unauthenticated POSTs;** a forged Twilio STOP could silence a dealership. `SECURE_PROXY_SSL_HEADER` is unset and Twilio signatures are unchecked.

**I-10 · Celery fragility**
- worker and beat have no restart policy, and beat has no lock.
- If beat dies, every scheduled customer contact stops silently. If it runs twice, customers get duplicate texts and calls.
- Watched by the Kuma Beat and Worker push monitors.

**I-11 · Monitoring gaps**
- The alert path is untested; nothing watches Kuma; there is no on-call rota; logs are not shipped off the box; netdata notifications have never worked.
- Office IP rotation lockouts are mitigated by allowlisting the VPN exit IP `44.225.91.181`.
- **Kuma box trap:** `sites-enabled` holds a regular file, not a symlink. **Never put `.bak` files in `sites-enabled`.**

**I-12 · Unexplained 403s** on `/api/companies/users/` and booking-dashboard-stats. Asked of Mudassar; unresolved.

**I-13 · Capacity and hygiene:** no swap, CPU oversubscribed, journal uncapped, Redis eviction policy, and callingyounow sharing the box.

**I-14 · v1 tenant leftovers:** out of scope for now.

## 4. Health checks

**Gate:** Tier 0 involves no contact with the droplet. Tiers 1 and 2 need the operator's yes first.

**Tier 0: Kuma**
- On the VPN, open `https://uptime.callingyounow.us/dashboard`, or tunnel with `ssh -N -L 3001:127.0.0.1:3001 ubuntu@44.225.91.181` and open `http://localhost:3001`.
- **DealerPulse monitors:** Backend HTTP (`/health/ready/`), Frontend HTTP, Beat, Worker, Backend Threads, Error Rate, Host Resources, Database (TCP 25060), XTime, Twilio, Wassenger.
- **Good messages look like:** "10 threads on blue", "0 errors in the last minute", "disk 30%, mem 4828MB free, redis 0%", "beat running and active within 3m".

**Tier 1: external endpoints**
```
curl -s -o /dev/null -w '%{http_code} %{time_total}s\n' https://app.backend.dealerpulse.cloud/health/ready/
curl -s -o /dev/null -w '%{http_code} %{time_total}s\n' https://app.backend.dealerpulse.cloud/health/live/
curl -s -o /dev/null -w '%{http_code} %{time_total}s\n' https://app.dealerpulse.cloud/
```
- **Good:** ready 204 in about 1.2 s; live 204; frontend 200.
- **Bad:**
  - ready 503: the app can't reach the DB.
  - ready hangs or returns 502/504 while live is 204: the I-1 signature.
  - Both fail: the process or nginx is down.
- **The homepage is not proof of health.** It returned 200 throughout the I-1 outage.

**Tier 2: on the droplet, read-only, ask first**
```
cat /opt/dealerpulse/backend/active_env
docker ps --format 'table {{.Names}}\t{{.Status}}\t{{.Image}}' | grep -E 'dealerpulse|callingyounow'
C=dealerpulse_backend-web_$(cat /opt/dealerpulse/backend/active_env)-1
docker inspect -f '{{.State.Health.Status}} restarts={{.RestartCount}}' $C
systemctl list-timers 'check-*' --no-pager
docker logs --since 3m dealerpulse_backend-beat-1 2>&1 | grep -c 'Sending due task'                 # > 0
docker logs --since 10m dealerpulse_backend-worker-1 2>&1 | grep -cE 'Task .*(received|succeeded)'  # > 0
docker logs $C 2>&1 | grep -E 'is not set'                                                          # missing keys
docker inspect -f '{{range .Config.Env}}{{println .}}{{end}}' $C | cut -d= -f1                       # env NAMES only
```
- **Threads:** normal is 9-14. Above 30 is an alert; the outage reached 142.
- **Check scripts:** `/usr/local/bin/check-{celery,health,thirdparty}.sh` with configs in `/etc/default/check-*`. They push to Kuma.
- **Expected DOWN until someone fixes them:** RETELL, OPENROUTER and ASSEMBLYAI. **Twilio UP does not mean SMS is delivered.**
- **Do not:**
  - restart worker as a test;
  - run `docker compose up -d` without a service name and `IMAGE_TAG`;
  - read `.env`;
  - run the beat-stop alert test without approval and outside dealership hours.

## 5. Open risks (ranked)
1. **DB open to the internet, superuser login, exposed `doadmin` password (I-8).** Needs the DO account holder and the CTO.
2. **I-1 could recur:** the DB timeouts are not in code (backend team).
3. **Silent customer-impact failures (I-2, I-5, I-6):** the monitors test auth, not outcomes.
4. **Single points of failure:** one droplet and one DB node; backups never restored; media only in the droplet snapshot.
5. **Celery fragility (I-10)**, with an unproven alert path.
6. **Deploy safety** (the §2.1 weaknesses).
7. **Unauthenticated webhooks.**
8. **Droplet attack surface.**
9. **Capacity and hygiene.**
10. **The nginx upload limit and timeout** (small, ready, awaiting approval).
11. **Migration hazards if the product moves:**
    - provider IP allowlists are unknown;
    - 4 h DNS TTL with an unknown Hostinger account holder;
    - the frontend's fallback to the staging backend;
    - `MASTER_ENCRYPTION_KEY`;
    - local media;
    - the shared box.
12. **Staging on the shared `combined` droplet.**

## 6. Unknown
- **Current production state:** which commit is deployed, the key states, and whether any of the fixes were applied.
- **Accounts:** the DO account holder, the Hostinger account holder, and the owner of callingyounow.
- **Database:** every client besides the droplet; whether staging uses the prod DB; PITR and restore testing.
- **Network:** what `3.43.243.0/30` is; whether any provider allowlists the droplet IP.
- **Incident:** the trigger of 2026-09-16.
- **Expectations:** RTO/RPO, and who responds out of hours.

## 7. Stale statements corrected
- MEM says the blue/green colour is switched by hand. **It is automated.**
- CTO says slow-query logging and the idle timeout are off. **Both are on** (1000 ms, 24 h).
- "No alerting" is superseded by Kuma.
- Tony recovery runs every minute, not every 10 minutes. There are five Retell agent IDs, not four.
- The 2026-09-16 outage cause is DB waits with no timeouts, not "missing proxy_read_timeout".
