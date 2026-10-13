# Deployment Guide

This document describes how the `ocean` backend is deployed across its two environments — **staging** and **live/production** — including server details, domains, and the exact deployment mechanics. It reflects the state as of **2026-07-10**, when the live environment was first stood up.

> **Secrets policy**: this doc lists variable *names*, IPs, domains, paths, and container/service names. It never lists actual passwords, `SECRET_KEY`, API tokens/client secrets, or private key material — only where those live.

## 1. Overview

`ocean` is a multi-tenant Django/DRF dealership SaaS backend (HomeNet SOAP inventory integration, XTime REST integration). Both environments run the same Docker Compose stack — `web` (Django), `worker` + `beat` (Celery), `db` (Postgres 15), `redis` (Redis 7) — under the legacy project directory name `/var/www/nisanWebsite`. The two environments differ mainly in **how they're exposed publicly** and **which git branch feeds them**.

## 2. Environments at a glance

| | Staging | Live / Production |
|---|---|---|
| Server IP | `137.184.45.248` | `143.198.144.174` |
| Hostname | `Combined` | `Nissan-Websites` |
| OS | Ubuntu 24.10 | Ubuntu 24.04.4 LTS |
| App directory | `/var/www/nisanWebsite` | `/var/www/nisanWebsite` |
| Git branch deployed | `staging` | `main` (fast-forwarded to staging's tip on 2026-07-10) |
| Public domain for this app | **None** — see note below | `https://nissan.staging.flutenwebframework.xyz` |
| Reverse proxy | Nginx/Apache present but not actually wired to this app | Nginx + Certbot (Let's Encrypt) |
| Docker Compose project name | `nisanwebsite` | `nisanwebsite` |
| Web container port | `9000`, published on `0.0.0.0` (wide open in ufw) | `9000`, published on `127.0.0.1` only (not internet-reachable) |
| Shares the box with other apps? | Yes, ~15 unrelated projects (see §4) | Yes, one other app: `leads_backend` (port 8129, `/opt/leads/leads_backend`) |
| CI/CD trigger | Bitbucket Pipelines, push to `staging` | Bitbucket Pipelines, push to `main` (secrets not yet added — see §7) |

**Staging note**: despite the directory being named `nisanWebsite` and Apache having `nisanwebsite.conf`/`nisanwebsite-ssl.conf` vhost files enabled, both are dangling symlinks (their `sites-available` targets don't exist) and Apache doesn't actually register a vhost for this app (`apache2ctl -S` shows nothing). The app is only reachable directly at `http://137.184.45.248:9000/`, with port 9000 wide open in `ufw`. There is currently no domain or TLS in front of staging for this app.

## 3. Deployment mechanics (shared by both environments)

**CI/CD**: `bitbucket-pipelines.yml` defines one pipeline step per branch. On push, Bitbucket's runner SSHes into the target server and runs a deploy script:
- `staging` branch → `deploy/staging.sh`, deployment environment `staging`
- `main` branch → `deploy/production.sh`, deployment environment `production`

Both scripts do the same thing against `/var/www/nisanWebsite`:
```bash
cd /var/www/nisanWebsite
git fetch origin <branch> && git checkout <branch> && git pull origin <branch>
# force-remove any existing web/worker/beat containers by name
docker compose -f docker-compose.yml up -d --build --no-deps web worker beat
```
Note `--no-deps`: this **never** touches `db`/`redis` — those are assumed to already be running long-term. A fresh environment needs `docker compose up -d db redis` run manually once, first.

**`docker-compose.yml` services**:
- `web` — `python server/manage.py runserver 0.0.0.0:9000` (Django's dev server — no gunicorn/uwsgi in front, on either environment)
- `worker` — `celery -A coresite worker -l info`
- `beat` — `celery -A coresite beat -l info`
- `db` — `postgres:15`, named volume `postgres_data`
- `redis` — `redis:7-alpine`, named volume `redis_data`
- Media bind-mount: `/var/www/nisanWebsite/server/coresite/media` on the host → `/app/server/coresite/media` in the containers (hardcoded absolute path in `docker-compose.yml`, which is why both environments use the same `/var/www/nisanWebsite` directory name).

**`docker/entrypoint.sh`** (runs for web/worker/beat on every container start): waits for Postgres to accept connections, runs `python server/manage.py migrate` **unconditionally** (idempotent — no-op if already up to date), and if `RUN_CACHE_WARMUP=1`, queues the `apps.homenet_inventory.tasks.refresh_homenet_inventory_cache` Celery task.

### How the live environment was actually stood up (2026-07-10)

1. `master`/`main` on Bitbucket were both empty (just an initial commit) — all real history lived on `staging`. Fast-forwarded `main` to staging's tip (`git push origin origin/staging:refs/heads/main`), then committed two changes on `main`: uncommented `deploy/production.sh` and the `bitbucket-pipelines.yml` production block (both previously disabled), pointing them at `main` instead of the stale `master` reference.
2. Copied the `bitbucket_deploy` SSH keypair from staging's `/root/.ssh/` to live's `/root/.ssh/` (same keypair, so no new Bitbucket deploy key registration was needed), added a matching `Host bitbucket.org` config entry and `known_hosts` entry.
3. `git clone -b main git@bitbucket.org:nxpt/ocean.git /var/www/nisanWebsite`
4. Copied staging's `.env` directly to live's `/var/www/nisanWebsite/.env`, then edited only `CSRF_TRUSTED_ORIGINS` and `XTIME_BASE_URL` (see §6) — everything else left identical to staging by design.
5. `docker compose up -d db redis` (fresh, empty containers).
6. `pg_dump -Fc` staging's DB (`nisanwebsite-db-1`), transferred the dump, `pg_restore --no-owner --clean --if-exists` into live's fresh DB. `rsync`'d staging's `server/coresite/media/` (~45MB) to the same path on live. Redis was **not** migrated (pure cache/broker).
7. `docker compose up -d --build web worker beat`.
8. Nginx vhost created at `/etc/nginx/sites-available/nisanwebsite`, modeled on the box's existing `leads_backend` vhost pattern (`server_name` → `proxy_pass http://127.0.0.1:9000`), symlinked into `sites-enabled`, then `certbot --nginx -d nissan.staging.flutenwebframework.xyz` for the cert (auto-renews via certbot's systemd timer).
9. **Fixed a firewall gap found during setup**: `docker-compose.yml`'s `ports: "9000:9000"` publishes on `0.0.0.0`, and Docker's own iptables rules for published ports **bypass `ufw` entirely** — so the app was briefly reachable directly on `143.198.144.174:9000` regardless of `ufw`'s ruleset. Fixed by changing it to `"127.0.0.1:9000:9000"` in `docker-compose.yml` (committed to `main`), then recreating the `web` container. Confirmed externally unreachable on 9000 afterward, while nginx (same host, loopback) still reaches it fine.

## 4. Domains

### Directly relevant to this app
| Domain | Server | Proxies to | Notes |
|---|---|---|---|
| `nissan.staging.flutenwebframework.xyz` | 143.198.144.174 (live) | nginx → `127.0.0.1:9000` | This app, live environment. TLS via Certbot. |
| `west-cost.ingeg.staging.flutenwebframework.xyz` | 143.198.144.174 (live) | nginx → `127.0.0.1:8129` | Belongs to `leads_backend`, a separate app on the same box — but also configured as this app's live `XTIME_BASE_URL` (see §6). |
| *(none)* | 137.184.45.248 (staging) | — | This app has no domain on staging; reachable only via `137.184.45.248:9000` directly. |

### Application-level tenant domains (DB-driven, not infra)
Multi-tenancy is resolved per-request by hostname via `apps/tenancy/middleware.py` (`DealershipFromHostMiddleware`), looking up an active `Domain` row — this is unrelated to the nginx/Apache vhosts above. As of the live DB restore, only one `Domain` row exists:
| Hostname | Dealership |
|---|---|
| `nissan-downtown-la.omnipulse.cc` | Puente Hills Nissan |

Four dealerships exist in the data: Corona Nissan, Puente Hills Nissan, Nissan Of San Bernardino, Surf City Nissan. **`nissan.staging.flutenwebframework.xyz` has no `Domain` row yet** — see §7.

### Other domains sharing the staging box (context only, not investigated in depth)
Staging (137.184.45.248) is a heavily shared box. Apache has vhosts for roughly 30 other domains belonging to unrelated projects, including: `chat.dev.omnipulse.cc`, `corona.omnipulse.cc`, `cyn.dev.omnipulse.cc` / `cyn.dev.backend.omnipulse.cc`, `dialer.fluten.xyz`, `dp.fluten.xyz` / `dp.backend.fluten.xyz`, `dp2.front.fluten.xyz` / `dp2.back.fluten.xyz`, `elk.linyay.com` / `elk.omnipulse.cc`, `framework.dev.omnipulse.cc`, `masaimara.pxtn.omnipulse.cc`, `nazdigitalsolutions.omnipulse.cc`, `nissan.omnipulse.cc` (referenced in staging's own `.env` — see §6), `oymayakon.portal.omnipulse.cc`, `phn.omnipulse.cc`, `phone.fluten.xyz` / `phone.backend.fluten.xyz`, `pm.backend.fluten.xyz`, `restaurant.backend.omnipulse.cc` / `restaurant.frontend.omnipulse.cc`, `sbd.omnipulse.cc`, `surfcity.omnipulse.cc`, `tony.fluten.xyz`, `yoda.linyay.com` / `yoda.omnipulse.cc`. None of these were investigated further — they're unrelated to `ocean`.

## 5. Server access

| | Staging | Live |
|---|---|---|
| SSH | `ssh root@137.184.45.248` | `ssh root@143.198.144.174` |
| Outbound git access to Bitbucket | `bitbucket_deploy` keypair in `/root/.ssh/`, `Host bitbucket.org` config entry | Same keypair, copied from staging |
| Inbound CI (Bitbucket Pipelines → server) | Existing key already configured for the `staging` deployment environment (not re-inspected) | Dedicated new `bitbucket_pipelines_inbound` keypair generated on live; public half added to `authorized_keys` — private half needs to go into Bitbucket (§7) |

## 6. Configuration (`.env`)

Lives at `/var/www/nisanWebsite/.env` on each server — not in git (`.gitignore`'d), loaded via `env_file` in `docker-compose.yml` and also used for Compose's own `${VAR}` substitution (e.g. `POSTGRES_DB: ${DATABASE_NAME}`).

**Variables that differ between staging and live** (everything else is intentionally identical, copied verbatim per instruction):
| Variable | Staging value | Live value |
|---|---|---|
| `CSRF_TRUSTED_ORIGINS` | `https://nissan.omnipulse.cc,http://www.nissan.omnipulse.cc,https://nissan.omnipulse.cc:9000` | `https://nissan.staging.flutenwebframework.xyz` |
| `XTIME_BASE_URL` | `https://west-cost.integ.omnipulse.cc` | `https://west-cost.ingeg.staging.flutenwebframework.xyz` |

**All other variable names** (values withheld — same on both environments):
```
DATABASE_NAME, DATABASE_USER, PASSWORD, HOST, PORT, SECRET_KEY,
COMPANY_NAME, COMPANY_COPYRIGHT, COMPANY_ADDRESS, COMPANY_PHONE, COMPANY_EMAIL,
COMPANY_WEBSITE, COMPANY_LOGO, COMPANY_FAVICON, COMPANY_LOGO_TEXT, COMPANY_LOGO_MINI,
COMPANY_STARTING_YEAR, PRIMARY_COLOR, SECONDARY_COLOR, BUTTON_COLOR, TEXT_COLOR,
REACT_DOMAIN, DOMAIN, FILE_UPLOAD_STRATEGY, FILE_UPLOAD_STORAGE, MEDIA_ROOT_NAME,
MEDIA_URL, MEDIA_BASE_URL, EMAIL_FROM_HEADER, EMAIL_FROM, EMAIL_HOST_USER,
EMAIL_HOST_PASSWORD, EMAIL_HOST, EMAIL_PORT, EMAIL_USE_TLS, EMAIL_USE_SSL,
REDIS_HOST, REDIS_PORT, HOMENET_GATEWAY_URL, HOMENET_GATEWAY_NS, HOMENET_SOAP_ENV_NS,
HOMENET_LOAD_ACTION, HOMENET_TIMEOUT, HOMENET_IMAGE_BASE_URL, HOMENET_INTEGRATION_TOKEN,
HOMENET_DEFAULT_DEALERSHIP_ID, HOMENET_CACHE_REFRESH_SECONDS, HOMENET_CACHE_TTL_SECONDS,
XTIME_CLIENT_ID, XTIME_CLIENT_SECRET, XTIME_TIMEOUT, CELERY_BROKER_URL,
CELERY_RESULT_BACKEND, COMPOSE_PROJECT_NAME, WEB_PORT
```

Notably `ALLOWED_HOSTS = ["*"]`, `DEBUG = True`, and `CORS_ALLOW_ALL_ORIGINS = True` are hardcoded in `server/coresite/settings/base.py` / `corsheader.py` — not environment-driven, so identical on both environments as-is.

## 7. Third-party services

**Actually wired into the code**, same on both environments unless noted:

| Service | Used for | Wired via | Notes |
|---|---|---|---|
| **HomeNet (HomeNetIOL)** | Vehicle inventory sync + stock images | `server/apps/homenet_inventory/services/homenet_client.py` — SOAP call to `HOMENET_GATEWAY_URL` (`https://services.homenetiol.com/Gateway.asmx`), action `LoadCompressedVehicles` | Refreshed on a schedule by `apps.homenet_inventory.tasks.refresh_homenet_inventory_cache` (Celery beat) and on container start via `RUN_CACHE_WARMUP=1`. |
| **XTime (service/appointment booking)** | Creating dealership service bookings | `server/apps/homenet_inventory/services/xtime_client.py` — HTTP client with JWT token caching + `IntegrationAuditLog`, posts to `XTIME_BASE_URL` | Not XTime's own servers directly — `XTIME_BASE_URL` actually points at a separate internal FastAPI/uvicorn proxy microservice (its own Postgres + Alembic migrations), documented at repo root in `AUTH_INTEGRATION_GUIDE.md` as the **"Cox Automotive Integrations API"**. On the live server, this proxy *is* the `leads_backend` container (port 8129) — same service, different name in docs vs. infra. `JWT_SECRET_KEY`/`ADMIN_SECRET` in that guide belong to the proxy service itself, not this Django app — they don't appear anywhere in `ocean`'s settings. |
| **Email (SMTP)** | Booking/contact-us notification emails | `server/coresite/settings/email.py` — `EMAIL_BACKEND` defaults to a custom `utils.email_backend.ConfigurableSMTPEmailBackend`, `EMAIL_HOST` defaults to `smtp.gmail.com` unless overridden | Generic configurable SMTP, not a dedicated transactional-email API (no SendGrid/SES-specific backend). |
| **Bitbucket** | Source control + CI/CD | `git@bitbucket.org:nxpt/ocean.git`, Bitbucket Pipelines | Repo also hosts the deploy scripts themselves (§3). |
| **Let's Encrypt** (via Certbot) | TLS certificate for the live domain | `certbot --nginx` | Auto-renews via systemd timer (§8). |
| **DigitalOcean** | Hosting for both droplets | — | Confirmed via the `droplet-agent` systemd service running on both boxes. |

**Present in `requirements.txt` but not actually integrated** — worth knowing so nobody assumes these are live:
- **Stripe** — package installed, zero usage anywhere in `server/apps` or `server/coresite`. No `STRIPE_*` settings exist.
- **AWS S3** (`django-storages`/`boto3`) — `server/coresite/settings/file_storage.py` has conditional S3 support gated behind `FILE_UPLOAD_STORAGE=S3`, but both environments currently run with `FILE_UPLOAD_STORAGE=standard` (local disk) and the S3 packages aren't even installed — dormant unless that env var is flipped and the packages added.
- **Google OAuth** — `server/apps/core/views/googleregister.py` exists but is entirely commented out.

## 8. Outstanding manual steps (live environment)

These require access this process doesn't have (Bitbucket web UI, business knowledge of which dealership owns the new domain):

1. **Add Bitbucket "production" deployment-environment secrets** (repo → Repository settings → Deployments → production) so pushes to `main` auto-deploy to live the same way `staging` pushes do today:
   - `SSH_HOST=143.198.144.174`, `SSH_USER=root`, `SSH_PORT=22`, `SSH_KEY_B64=<base64 of the bitbucket_pipelines_inbound private key generated on live>`
2. **Add a `Domain` row** for `nissan.staging.flutenwebframework.xyz` via `/api/admin/`, pointing at the correct `Dealership` — the tenancy middleware won't resolve this domain to a tenant until this exists.

## 9. Operational notes

- TLS cert on live auto-renews via Certbot's systemd timer; expires 2026-10-08 absent renewal (renewal is automatic).
- A read-timeout retry against the real HomeNet gateway (`services.homenetiol.com`) was observed during the first cache-warmup run on live — same credentials/integration as staging, likely transient, but worth checking if inventory doesn't populate.
- Neither environment runs a production WSGI/ASGI server (gunicorn/uwsgi/daphne) — both use `manage.py runserver`, Django's development server, as-is from `docker-compose.yml`.
