# DealerPulse — architecture and infrastructure

Source of truth. Last verified **2026-09-17** by direct inspection of the droplet
(`ssh dealerpulse`, read-only) and the two repos.

Provenance: **[verified]** we checked it · **[told]** stated by the backend team
· **[doc]** from their `LOAD_BALANCER_README.md` · **[assumed]** our inference.

> **Read §8 first if you read nothing else.** The production database accepts
> connections from anywhere on the internet, and the application connects to it
> as the cluster superuser. That outranks the load balancer question.

---

## 1. The host

| | |
|---|---|
| IP | `146.190.132.236` (public) · `10.124.0.3` (private) |
| Hostname | **`Surfcity-Live`** — not "dealerpulse" [verified] |
| Spec | 2 vCPU · 8 GB RAM · 90 GB disk · DigitalOcean |
| Cost | $42.00/mo droplet + $12.60/mo backups = **$54.60/mo** |
| Uptime | 202 days [verified] — kernel 6.11.0-29, never rebooted since |
| Swap | **none** [verified] |
| Disk | 26 GB used of 87 GB (30%) |
| Memory | 2.9 GB used, 4.8 GB available [verified] |
| Backups | DO automated daily, 7-day retention, last one 1 hour ago. **Never restored.** |

**This droplet is not just DealerPulse.** It also runs a second, unrelated
product — `callingyounow` — and the remains of four older per-tenant DealerPulse
deployments. Any migration plan is really an untangling plan. See §6.

---

## 2. What is actually running

[verified — `docker ps`, 2026-09-17]

| Container | Image | Port | Up |
|---|---|---|---|
| `dealerpulse_backend-web_blue-1` | `fluten/dealerpulse_backend:899c747…` | `127.0.0.1:8004` | 18h (healthy) |
| `dealerpulse_backend-worker-1` | same image | — | 18h |
| `dealerpulse_backend-beat-1` | same image | — | 18h |
| `dealerpulse_backend-redis-1` | `redis:7-alpine` | internal | 4 months |
| `dealerpulse_frontend-frontend-1` | `fluten/dealerpulse_frontend:b6873a8…` | `127.0.0.1:8014` | 20h |
| `callingyounow_backend-web_blue-1` | `fluten/callingyounow_backend:571d0c3…` | `127.0.0.1:8007` | 3 months |
| `callingyounow_backend-worker-1` | same | — | 3 months |
| `callingyounow_backend-beat-1` | same | — | 3 months |
| `callingyounow_backend-redis-1` | `redis:7-alpine` | internal | 4 months |
| `callingyounow_frontend-frontend-1` | `fluten/callingyounow_frontend:9db5d51…` | `127.0.0.1:8018` | 4 months |
| `netdata` | `netdata/netdata` | `19999` (firewalled) | 4 months |

Also on the host, **not** in Docker [verified]:

- **PostgreSQL 16.9** — `0.0.0.0:5432`, a host package, not a container.
  **This is not the DealerPulse database** — see §2a. Nothing was connected to it
  at the time of inspection.
- **redis-server** — `127.0.0.1:6379`, host package, *in addition to* the two
  Redis containers. Purpose unknown; possibly vestigial.
- **nginx** — `:80` and `:443`, the only front door.
- **otel-plugin** — `127.0.0.1:4317`, part of netdata.

**`web_green` is not running.** Only blue. See §4.

---

## 2a. The database — not on the droplet

[verified 2026-09-17 from the running container's environment]

**DealerPulse uses a DigitalOcean Managed PostgreSQL cluster, not the droplet.**

| | |
|---|---|
| Host | `dp2-live-do-user-13151402-0.g.db.ondigitalocean.com` |
| Resolves to | `143.244.183.125` |
| Port | `25060` (DO managed default, not 5432) |
| Database | `defaultdb` |
| User | **`doadmin`** — the cluster superuser |
| SSL | `sslmode=require` |

Django config is `server/coresite/settings/database.py`, reading `HOST`, `PORT`,
`DATABASE_NAME`, `DATABASE_USER`, `PASSWORD`, `SSL_MODE` from the environment,
with `ATOMIC_REQUESTS: True`.

Three things follow from this, and all three matter:

**The database is already separate from the droplet.** That is good news for a
migration — moving the application does not move the data. It also means the
droplet's DO snapshots are *not* a backup of the application data; whatever
backup exists is the managed cluster's own, and its retention and PITR settings
have not been checked by us.

**The application connects as `doadmin`.** That is the cluster superuser, in the
default database, with no dedicated role or database of its own. Any SQL
injection or leaked `.env` is full cluster compromise rather than one
application's data. A least-privilege role and a named database is the fix, and
it is a migration-friendly change to make.

**`ATOMIC_REQUESTS: True`** wraps every request in a transaction. Combined with
the synchronous XTime call inside booking requests [doc §7], a slow XTime holds
a database transaction open for its full duration. Worth knowing before tuning
any timeout.

### The separate Postgres on the droplet

The host also runs its own PostgreSQL 16.9 on `:5432`, which the application does
**not** use. Its `pg_hba.conf` shows a `dealerpulse` database with a `wrenuser`
account reachable from `172.18.0.0/16` — the `wrenai_wren` Docker network — plus
two external IPs (`34.57.198.97`, `174.138.88.142`). The `wrenai_*` Docker
networks still exist on the box but **no WrenAI containers are running**.

So this looks like a stale analytics/text-to-SQL deployment holding a `dealerpulse`
database. **Whether it contains real customer data is unknown and worth finding
out** — a forgotten copy that nobody monitors is a worse liability than a live
one.

Deployment files live in `/opt/dealerpulse/{backend,frontend}/` and
`/opt/callingyounow/{backend,frontend}/`, each a `docker-compose.yml` plus a
`.env`. There is also `/opt/deployer/`.

---

## 3. Request paths

```
                      Internet (no CDN, no WAF, no proxy)
                                    │
                        DNS: ns1/ns2.dns-parking.com
                             (Hostinger), TTL 4h
                                    │
                         146.190.132.236  ·  nginx :443
                                    │
        ┌───────────────────────────┼───────────────────────────┐
        │                           │                           │
 app.dealerpulse.cloud   app.backend.dealerpulse.cloud   app[.backend].callingyounow.com
        │                           │                           │
   :8014 frontend            :8004 web_blue  ◄── hardcoded      :8018 / :8007
   (static SPA in nginx)          │    │                        (separate product)
                                  │    └── /ws/ WebSocket, 3600s timeouts
                                  │
                    ┌─────────────┼─────────────┐
                    ▼             ▼             ▼
            DO Managed         Redis (ctr)   Celery worker + beat
            PostgreSQL         channel layer   (no restart policy)
            :25060, as         + broker
            doadmin, open
            to the world — §8

            (the droplet's own Postgres on :5432 is a
             separate, unused instance — see §2a)
```

**The voice path**, which is the one with a customer on the line [told + doc]:

```
Twilio ──► Retell ──► POST app.backend.dealerpulse.cloud
                           /api/calls/inbound-dynamic-variables-webhook/
                      (called DURING the call, caller is waiting)
                                    │
                            XTime (synchronous, in-request) ──► booking
                                    │
                            frontend updated over /ws/ [assumed]
```

A slow response here is dead air on a live call; a non-200 stalls the agent
mid-call [doc §6]. This path shares 2 vCPU with everything else in §2.

---

## 4. Deploys — and what the load balancer is actually for

> **Correction, 2026-09-17.** An earlier version of this section said the colour
> was switched by hand. That was wrong. It is automated in
> `bitbucket-pipelines.yml`, which I had not read at the time. Corrected below.

**Blue/green is real and automated — there is just no load balancer involved**
[verified from `bitbucket-pipelines.yml` and confirmed by file timestamps on the
droplet].

Deploys run from Bitbucket Pipelines on the `main` branch:

1. Build the image, push to **Docker Hub** as `$IMAGE_TAG` and
   `latest_production`.
2. `scp` `docker-compose.yml` to `/opt/dealerpulse/backend/`.
3. SSH in and run the switch: read `active_env`, pick the other colour, wait for
   its port to be free, `docker compose up -d web_$NEW`.
4. Poll `docker inspect` health for up to **150 seconds** (30 × 5s). If it never
   reports healthy, dump 100 log lines, stop the new container, exit 1 — the old
   colour keeps serving. That failure path is sound.
5. `nginx -t`, back up the vhost to `.bak`, **`sed -i "s/:$OLD_PORT/:$NEW_PORT/g"`**
   on the vhost, `nginx -t` again, reload.
6. Stop the old colour, write the new colour to `active_env`.
7. `docker compose up -d --force-recreate worker beat`.
8. `docker image prune -af` and `docker builder prune -af`.

The 2026-09-16 23:47–23:48 file timestamps on the droplet match this sequence
exactly, step for step.

**So what does a load balancer actually buy here?** Not much that this does not
already do, and that is worth saying before anyone spends money on one. What it
would replace is the `sed` — rewriting a live nginx config on every deploy. An
nginx `upstream` block with both colours and `proxy_next_upstream` gets the same
result without editing config at deploy time. A DigitalOcean managed load
balancer still cannot reach the loopback-bound ports without a change, and still
provides no redundancy behind one droplet.

**Real weaknesses in this pipeline**, in the order they will bite:

- **No automated rollback after the switch.** If the new colour passes its health
  check and *then* misbehaves, nothing reverts. The `.bak` vhost and the old
  image tag on Docker Hub make manual rollback possible, but it is manual.
- **The health check is the container's own**, which calls `/health/ready/` —
  and that only proves Django can reach Postgres [doc §3]. A container that is
  broken in any other way passes and takes traffic.
- **`sed -i "s/:$OLD_PORT/:$NEW_PORT/g"` is a global replace** over the whole
  vhost file. It works today because `:8004` appears only in the two
  `proxy_pass` lines, but any future use of that port number anywhere in the file
  gets silently rewritten too.
- **`worker` and `beat` are recreated *after* the traffic switch**, so for a few
  seconds the new code serves web requests while the old code processes the
  queue.
- **`docker image prune -af` runs every deploy**, so the previous image is gone
  from the box. Rollback means re-pulling from Docker Hub, which needs the
  registry reachable.

**Migration race — the doc's §9 warning does not apply to the pipeline path**
[verified]. `x-web-common` does set `RUN_MIGRATIONS: "1"` on both colours, but
the pipeline starts exactly one colour at a time, so they cannot race. The risk
is real only if someone runs `docker compose up -d` by hand and both come up
together. Worth keeping in mind, not worth treating as a live defect.

The genuine migration concern is different: the new colour runs `migrate` **while
the old colour is still serving traffic**, so any non-backward-compatible schema
change breaks the running version for the length of the deploy.

**Resource limits** [verified] — worth noting before green is ever started:

| | mem_limit | cpus |
|---|---|---|
| web_blue / web_green | 1536m each | 1.5 each |
| worker | 2048m | 1.5 |
| beat | 512m | 0.5 |
| redis | 1024m | 1.0 |

DealerPulse alone reserves ~5.1 GB with one colour up, ~6.6 GB during a
blue/green overlap — on an 8 GB box that also runs the whole `callingyounow`
stack and host Postgres, **with no swap**. CPU limits sum to 6 on 2 vCPU.

---

## 5. nginx — three corrections and two gaps

[all verified from `/etc/nginx/sites-enabled/app.backend.dealerpulse.cloud`]

**`X-Forwarded-Proto` is already being sent.** The handover doc asks us to send
it. nginx sets it on both `location /` and `location /ws/` today. The gap is
entirely Django-side — `SECURE_PROXY_SSL_HEADER` is unset — so nothing is
blocked on infrastructure. Worth telling them: it removes a to-do from our side
and puts it squarely on theirs.

**WebSocket config is already correct.** Upgrade headers set, HTTP/1.1,
`proxy_read_timeout 3600` / `proxy_send_timeout 3600`. The doc asked for ≥10
minutes; it has an hour.

**`X-Forwarded-For` is already sent.** Also already done.

**Gap — `client_max_body_size` is not set anywhere in `/etc/nginx/`.** That means
the nginx default of **1 MB**. The handover doc says file uploads go to `/media/`
and "25 MB is comfortable". Any upload over 1 MB is being rejected with a 413
today. Cheap to fix, and someone is probably already hitting it.

**Gap — no `proxy_read_timeout` on `location /`.** Default is 60s. The doc asks
for "60s minimum" on `/api/` because XTime is called synchronously in-request.
We are sitting exactly on the boundary, so an XTime call taking 61 seconds
becomes a 504 rather than a slow success.

TLS is Let's Encrypt via certbot, `certbot.timer` active, **15 certificates** on
this host. HTTP redirects to HTTPS. No HTTP/2.

---

## 6. The other things on this box

**`callingyounow`** — a complete second product: backend, frontend, worker, beat
and its own Redis, on `app.callingyounow.com` / `app.backend.callingyounow.com`.
Containers up 3–4 months, so no recent deploys. There is a
`phn.callingyounow.us Resilience.pdf` in our Documents folder, so it is known to
us, but it has never been treated as ours. **Owner unknown.**

**Four dead-or-dying per-tenant DealerPulse deployments** [verified] — the v1
architecture, before consolidation into `app.dealerpulse.cloud`:

> **Correction, 2026-09-17.** An earlier version said `corona.dealerpulse.cloud`
> was "still live". It is **NXDOMAIN** publicly — the vhost exists and serves
> locally, but no DNS record points at it. Only `surfcity.dealerpulse.cloud`
> actually resolves. Corrected below.

| vhost | serves locally | public DNS |
|---|---|---|
| `surfcity.dealerpulse.cloud` | static SPA, HTTP 200 | **resolves to the droplet — publicly reachable** |
| `corona.dealerpulse.cloud` | static SPA, HTTP 200 | **NXDOMAIN** |
| `snb.`, `puentehills.dealerpulse.cloud` | same pattern | not checked |
| `*.backend.dealerpulse.cloud` (corona, snb, puentehill, surfcity) | proxy to `:8010` `:8020` `:8030` — **nothing listens on those ports** | — |
| `sigma.fluten.xyz` | proxies to `:8000` — **nothing listening** | — |

So v1 split the backend into auth/advisor/retell microservices on 8010/8020/8030.
That is gone. `surfcity.dealerpulse.cloud` is the one that still resolves, so it
is the one where a stale bookmark gets a site that loads and then fails every
request. certbot is renewing certificates for all of it, including
`huntington.alpha.dealerpulse.cloud`, which has a certificate but no vhost at all.

*Out of scope for now at your direction — recorded so it is not lost.*

---

## 7. Third-party services — the real list

The handover doc named three. The backend's `env.example` shows **nine or more**
[verified, `dp_backend_v2/env.example`]:

| Service | Purpose | Env keys |
|---|---|---|
| **Twilio** | SMS, voice origination | `TWILIO_ACCOUNT_SID`, `TWILIO_AUTH_TOKEN`, `TWILIO_API_KEY_*`, `TWILIO_FROM_NUMBER` |
| **Retell** | Voice agents — four of them | `RETELL_API_KEY`, `LYRA_AGENT_ID`, `OLIVIA_AGENT_ID`, `PAC_OLIVIA_AGENT_ID`, `RETELL_REMINDER_AGENT_ID` |
| **XTime** | Appointment booking (DMS) | `XTIME_CLIENT_ID/SECRET/API_KEY/DEALER_ID/SCOPES` |
| **Wassenger** | WhatsApp gateway | `WASSENGER_API_KEY`, `WASSENGER_DEVICE_ID`, `WASSENGER_WEBHOOK_TOKEN/SIGNATURE_HEADER` |
| **OpenRouter** | LLM | `OPENROUTER_API_KEY`, `_BASE_URL`, `_MODEL` |
| **AssemblyAI** | Call transcription | `ASSEMBLY_AI_API_KEY` |
| **Cox Automotive** | DMS / inventory | `COXAUTO_API_BASE_URL` |
| **AWS S3** | File storage | `AWS_S3_ACCESS_KEY_ID/SECRET`, `AWS_STORAGE_BUCKET_NAME`, `FILE_UPLOAD_STORAGE` |
| **SMTP** | Email | `EMAIL_HOST`, `EMAIL_HOST_USER/PASSWORD` |

`server/coresite/settings/` also contains `vapi.py` and `tony.py`, so there is at
least one more voice provider and the "Tony recovery" flow has its own config.

**Wassenger has webhook signature verification configured**
(`WASSENGER_WEBHOOK_TOKEN`, `WASSENGER_WEBHOOK_SIGNATURE_HEADER`) while Twilio
and Retell do not. So the pattern already exists in this codebase — which
weakens the case that Twilio signature verification is hard.

**Unknown for all of them:** whose accounts, whether sandboxes exist, rate
limits, and — critical for any migration — **whether any of them allowlists
`146.190.132.236`.** If XTime or Cox does, moving the box breaks booking silently.

---

## 7a. Media and files on disk

[all verified 2026-09-17]

Bind-mounted from the host: `/var/www/dealerpulse_backend/media` →
`/app/server/coresite/media`. nginx serves it directly at `/media/` with CORS
headers scoped to `https://app.dealerpulse.cloud`. **196 MB, 332 files.**

| directory | size | files | nature |
|---|---|---|---|
| `call_recordings/` | 193 MB | 318 `.mp3` | **7-day rolling cache — disposable** |
| `support/` | 2.2 MB | png | support ticket attachments — **permanent** |
| `images/` | 276 KB | png/avif | **permanent** |
| `company_members/` | 276 KB | png | **permanent** |

**Call recordings are a cache, not a system of record.** The Celery beat job
`cleanup-recordings-every-night` runs at 02:00 UTC and deletes anything in
`call_recordings/` older than 7 days
(`apps/calls/tasks/cleanup_old_recordings_tasks.py`). **Verified it is actually
running** — the oldest file on disk is dated exactly 7 days ago and
`find -mtime +7` returns zero. Recordings are pulled on demand from Twilio and
cached (`apps/calls/views/service_calls.py`), so Twilio holds the originals.

That means **~98% of the media volume does not need to be migrated** — it will
refill itself. The ~2.7 MB in `support/`, `images/` and `company_members/` is
real user-uploaded data going back to 2026-03-01, and that does.

**S3 is coded but not enabled.** `env.example` has a full `AWS_S3_*` /
`FILE_UPLOAD_STORAGE` block, but `docker inspect` on the running container shows
**none of those variables are set**. Production writes to local disk only. There
is no object-storage copy of anything.

**The only backup of the permanent files is the droplet snapshot** — daily,
7-day retention. Delete a support attachment and notice 8 days later and it is
gone.

### Other disk consumers, for migration sizing

| path | size | note |
|---|---|---|
| `/var/lib/docker` | 9.2 GB | images, containers, volumes |
| `/var/log/journal` | **4.3 GB** | `SystemMaxUse` is not set — uncapped |
| `/var/www/html` | **3.8 GB** | the v1 tenant static builds (§6) |
| `/var/www/dealerpulse_backend` | 196 MB | the media above |

Total disk is 26 GB of 87 GB used. The journal alone is 5% of the disk and needs
one line in `journald.conf`.

---

## 7b. Scheduled work

[verified, `server/coresite/settings/celery.py`]

| job | schedule | what stops if `beat` dies |
|---|---|---|
| `dispatch-appointment-confirmations` | **every minute** | confirmation texts |
| `dispatch-appointment-reminders` | every 5 min | reminder calls |
| `dispatch-tony-recovery-calls` | every 10 min | no-show recovery |
| `dispatch-attendance-prompts` | every 10 min | attendance prompts |
| `dispatch-bdc-hourly-reports` | hourly | BDC reports |
| `cleanup-recordings-every-night` | 02:00 | disk fills with recordings |
| `backfill-catch-phrases-daily` | 02:30 | call analysis |

`beat` has **no restart policy and no health check** [verified, §4]. If it dies,
all seven stop silently and the site looks perfectly healthy.

`CELERY_TASK_TIME_LIMIT` is 20 minutes, soft limit 15.

**Two of these are currently broken**: reminders and Tony recovery both place
outbound Retell calls, and `RETELL_API_KEY` is not set in production — see
`INCIDENT_2026-09-16.md` §7.1.

---

## 8. Security findings

### 8.1 CRITICAL — the managed database has no network restriction, and the app is superuser

[verified 2026-09-17 by a successful TCP connection to `143.244.183.125:25060`
from an unrelated external machine]

DigitalOcean Managed Postgres clusters support **Trusted Sources** — a firewall
restricting which droplets or IPs may connect. **It is not configured on this
cluster.** The database accepts connections from anywhere on the internet.

What still stands between an attacker and the data is a password and TLS. That is
not nothing — DO enforces SSL and the port is not a default 5432 — but it is the
only layer, and the account it protects is **`doadmin`, the cluster superuser**,
connecting to `defaultdb`. There is no separate application role and no separate
database, so a leaked `.env`, a `docker inspect` by anyone with droplet access, or
one SQL injection is total compromise rather than partial.

**Two fixes, in order:**

1. **Enable Trusted Sources on the cluster** and restrict it to the droplet. This
   is a DigitalOcean control-panel change, takes a minute, and is reversible.
   Before enabling, confirm nothing else connects — a developer's laptop or a BI
   tool would be cut off, and that is exactly the sort of thing nobody remembers
   until it breaks.
2. **Stop using `doadmin`.** Create a dedicated database and a role with rights
   only on it. This is an application change and a migration, so it is the slower
   of the two, but it removes the worst consequence of every other exposure.

### 8.1b The droplet's own Postgres on :5432

Separate instance, not used by the application (§2a). It listens on `0.0.0.0` and
ufw allows `5432/tcp` from anywhere, so the port is reachable from the internet
[verified externally].

**Its `pg_hba.conf` is much tighter than the firewall suggests**, and this is
worth stating plainly because the raw firewall rule looks alarming on its own:
authentication is restricted to `127.0.0.1`, `::1`, `3.43.243.0/30`, the WrenAI
Docker network and two external IPs. A connection from any other address is
rejected at the `pg_hba` stage, so this is **not** "one password from the open
internet".

What remains is still worth closing:

- Postgres 16.9 is exposed to pre-authentication traffic from the whole internet.
  That is unnecessary attack surface and it matters the moment a Postgres CVE
  lands.
- The `3.43.243.0/30` rule grants **all databases, all users, `md5`** — broad,
  and `md5` rather than `scram-sha-256`.
- Nobody knows what `3.43.243.0/30` is. It must be established before the ufw
  rule is narrowed, or something breaks silently.

The fix is to drop the blanket `5432/tcp ALLOW IN Anywhere` ufw rule and keep the
specific sources. **Not done — needs approval and needs question §10.1 answered
first.**

### 8.2 Other open ports

| Port | ufw rule | Reality |
|---|---|---|
| `8000` | ALLOW Anywhere | nothing listening [verified externally] — stale rule |
| `465` | ALLOW Anywhere | nothing listening — stale rule; inbound SMTP is not wanted |
| `19999` | **DENY** | netdata correctly blocked [verified externally] |
| `22` | ALLOW Anywhere | SSH open to the world; key-only auth not yet confirmed |

### 8.3 Unauthenticated webhooks

Five webhook endpoints accept unauthenticated POSTs [doc §6]. A forged Twilio
`STOP` silences a dealership's outreach. With nothing in front of the origin, an
IP allowlist has to be nginx or ufw on this box — there is no edge to put it at.
Needs the current Twilio and Retell published ranges first; getting it wrong
drops live calls.

---

## 9. Monitoring — what exists

- **netdata** is running and has been for 4 months, correctly firewalled to
  local access only. Nobody appears to be using it. It is per-container metrics
  for free, already installed — worth an SSH tunnel and a look before buying
  anything.
- **The DigitalOcean panel reports no memory metric** ("—"), the same blind spot
  we have on the AWS side, for a different reason.
- **No alerting of any kind found.** No uptime check, no notification target.
- Docker logs are capped at 50 MB × 5 per container. Nothing ships them
  anywhere; when a container is recreated, its history is gone.

---

## 10. Open questions

1. **What connects to the managed database besides the droplet?** Blocks turning
   on Trusted Sources (§8.1). And **what is `3.43.243.0/30`**, which blocks
   narrowing the droplet firewall (§8.1b).
2. **What backup and PITR settings does the managed cluster have, and has a
   restore ever been tested?** The droplet snapshots do not cover the data.
3. Does the `dealerpulse` database on the droplet's own Postgres hold real
   customer data, and can the stale WrenAI setup be removed?
4. Does any third party — XTime, Cox, Twilio, Retell — allowlist
   `146.190.132.236`? Breaks silently on migration.
5. Who holds the Hostinger / DNS account?
6. ~~Is there a staging environment?~~ **Answered: yes** [verified]. The
   `staging` branch deploys to `dp2.back.fluten.xyz`, which resolves to
   **`137.184.45.248` — the `combined` droplet**, the one carrying ~15 unrelated
   projects. It runs **Apache**, not nginx, and the pipeline does the same
   blue/green switch there with `apachectl` and `sed` on
   `/etc/apache2/sites-enabled/dp2.back.fluten.xyz-le-ssl.conf`. Its staging
   deploy step is more violent than production's: it `kill -9`s whatever holds
   the port and falls back to `fuser -k`. Open question becomes: **is staging
   sharing a box with 15 other projects acceptable, and does it point at the
   production database?**
7. What is the host `redis-server` on `:6379` for, given the stack uses
   containerised Redis?
8. Are the v1 tenant sites (corona, snb, puentehills, surfcity) meant to be
   live? Customers may still be reaching broken pages. *Out of scope for now —
   recorded so it is not lost.*

---

## 11. Repos

| | |
|---|---|
| Backend | `bitbucket.org/nxpt/backend_v2.1` → cloned to `Documents/dp_backend_v2` |
| Frontend | `bitbucket.org/nxpt/dp_frontend_v2` → cloned to `Documents/dp_frontend_v2` |

Backend: Django + Daphne + Channels + Celery, settings split under
`server/coresite/settings/`. Frontend: Vite/React SPA, built to static and served
by nginx in-container; a `vercel.json` is present, so it has been or could be
deployed to Vercel too.
