> **Knowledge file (reference).** Extracted 2026-10-13, read-only, from the pipeline files on each repo's remote branches and from the local copies of `deploy.sh`.
> **Citation notation:**
> - `WF@<branch>:L` = `website_frontend` repo, `bitbucket-pipelines.yml` on `origin/<branch>`, line L. `OC@`, `IS@`, `CB@`, `FF@`, `DPB@`, `DPF@` are the same for `ocean`, `integrations_service`, `chat_back`, `framework_frontend`, `dp_backend_v2`, `dp_frontend_v2`.
> - `new.sh` = `records/deploy-scripts/deploy_sh_new_nodeA.sh`; `intvm.txt` = `records/deploy-scripts/deploy_sh_intvm.txt`.
> - `MH` / `CL` = `records/Migration/MIGRATION_HISTORY.md` / `COMMAND_LOG.md`.
>
> The remote refs were last fetched between 10-01 and 10-12, so the branches may have moved since. The live `deploy.sh` on the nodes is **newer** than every local copy: it has a San Bernardino case that no copy has. Verify on the box (read-only) before relying on line-level detail.

# Deploy flows

## Quick map: what a push to each branch does

| Repo | Branch | What happens | Target |
|---|---|---|---|
| website_frontend | `main-migrated` | Build → ECR `website-frontend:<sha7>` + `:latest` → **atomic** SSM to nodeA+nodeB `deploy.sh website_frontend` → purge the Puente Hills zone | Puente Hills |
| website_frontend | `main-surfcity` | Same, tags `<sha7>-surfcity` / `latest_surfcity`, `deploy.sh website_frontend_surfcity` → purge the `callingyounow.us` zone | Surf City |
| website_frontend | `main-corona` | Same, tags `-corona` / `latest_corona`, `deploy.sh website_frontend_corona` → purge `callingyounow.us` | Corona |
| website_frontend | `main-sanbernardino` | Same, tags `-sanbernardino` / `latest_sanbernardino`, `deploy.sh website_frontend_sanbernardino` → purge `callingyounow.us` | San Bernardino |
| website_frontend | `staging` | **Legacy** Docker Hub + SSH model, deploys to a non-AWS host, purges the omnipulse.cc zone | not AWS prod |
| website_frontend | `main`, `development`, `corona-dev`, others | nothing (no matching pipeline key) | — |
| ocean | `main-migrated` | Build → ECR `nisanweb-backend:<sha7>` + `:latest` → Node A automatic → **Node B `trigger: manual` (someone must click)** | both nodes, **not atomic** |
| ocean | `main`, `staging` | **Legacy SSH deploy to the old DigitalOcean droplet. Still fires on push.** | old droplet |
| integrations_service | `main-migrated` | Build → ECR `leads-backend` → SSM `deploy.sh integrations_service` | integration VM |
| integrations_service | `master`, `staging`, `development` | **Legacy SSH deploys. Still fire on push.** | old hosts |
| chat_back | `main-migrated` | Build → ECR `chat-backend` → SSM `deploy.sh chat_back` | integration VM |
| chat_back | `main` | nothing (the file only has a `main-migrated` key now) | — |
| chat_back | `staging` | Legacy SSH | old host |
| framework_frontend | `main-migrated` | Build (env `aws-production`, VITE_* build args) → ECR `admin-dashboard` → SSM `deploy.sh framework_frontend` | integration VM |
| framework_frontend | `staging`, `master`, `production` | Legacy SSH. Still fire on push. | old hosts |
| dp_backend_v2 (DealerPulse) | `main` | Docker Hub → SSH → **blue/green** switch on the droplet | DO droplet |
| dp_frontend_v2 (DealerPulse) | `main` | Docker Hub → SSH → `docker compose up -d` (no blue/green) | DO droplet |

**Pushing to a legacy branch (`main`, `master`, `staging`, `production`, `development`) is not harmless.** Several of them still deploy to old hosts (MH:818, MH:1533).
Production for Dealerships is the `main-*` branches only.

## 1. Mechanics shared by every AWS deploy step
- Image `python:3.12-slim`; each step installs awscli itself. Region us-west-2.
- The step runs `aws ssm send-command --document-name AWS-RunShellScript --parameters commands=["/opt/dealerpulse/deploy.sh <svc> <branch>"]`.
- It then polls `get-command-invocation` 36 × 5 s (180 s maximum) and requires Success (WF@main-migrated:78-103).
  - If SSM is still running after 180 s, the step turns **red while the deploy continues on the node**.
- AWS credentials are repository variables `AWS_ACCESS_KEY_ID` / `AWS_SECRET_ACCESS_KEY` for IAM user `dealerpulse-cicd-bitbucket` (CL:1422, MH:814).
- ECR registry `409289617504.dkr.ecr.us-west-2.amazonaws.com`. Tags use the first 7 characters of the commit.

## 2. website_frontend production streams (all automatic)
**Step 1, Build & push** (WF@main-migrated:11-61)
- Bitbucket deployment environment per tenant: `aws-production` (Puente Hills), `aws-prod-surfcity`, `aws-prod-corona`, `aws-prod-sanbernardino`.
- `docker build --pull` with 33 build args, all `NEXT_PUBLIC_*`:
  - API_URL, DEALERSHIP_ID, XTIME_API_URL, XTIME_DEALERSHIP_ID, SITE_URL, GOOGLE_MAPS_QUERY_URL, WIGIT_KEY, CHATBOT_API_SOCKET, CHATBOT_API_URL, BRAND_NAME, IMAGE_ALLOWED_DOMAINS
  - AUTO_APR_EXPLORER_ID, TRADEPENDING_TRADE_IN_WIDGET_ID, TRADEPENDING_SELL_CAR_WIDGET_ID, CAPITAL_ONE_CLIENT_TOKEN, CAPITAL_ONE_DEALER_ID, DSS_REGISTERED_HREF, DEALER700_QUICK_QUALIFY_ID
  - AUTO_PIX_MEDIA_PLAYER_URL, AUTO_PIX_MEDIA_PLAYER_KEY, AUTOIPACKET_API_KEY, 700DEALER_API_KEY, CARFAX_PARTNER_KEY, ENVIRONMENT, CHAT_SHOW
  - LEAD_SOURCE_ID_DPW_{CONTACT_US, E_PRICE, MILITARY_FORM, COLLEGE_FORM, TEST_DRIVE, WIDGETS_FORM, SPECIALS}, SUNBIT_DEALER_SLUG
- **The values exist only in the Bitbucket deployment environments.** A tenant's site config is baked into its image.

**Step 2, Deploy to Node A + Node B (atomic)** (:62-103)
- One `send-command --instance-ids i-061291ea974c4ea1b i-0c982c44f93bfbc0a`; both nodes must succeed.
- This replaced the old "A automatic, B manual" design that caused chunk 404s.

**Step 3, Purge cache** (:104-140)
- `deployment: cache-purge`, which gives the step a **Redeploy** button for re-purging without a rebuild.
- Fails if the token is empty, POSTs `purge_everything`, and requires `"success":true`.
- Tokens:
  - Puente Hills: `CF_API_TOKEN_PUENTEHILLS`, zone `d68d738c1d15ec0cd770a9533e16d5ae`.
  - Surf City, Corona and San Bernardino: `CF_API_TOKEN_CALLNOW_US`, zone `283d6090889e4fdd64e23e6790cfa50a`. **This purges all of callingyounow.us**, including phn., api., admin., chat. and leads.
- The `main-sanbernardino` file also carries copies of the other tenants' blocks. They don't apply to that branch, and the copies have drifted.

**Dead keys** in the same file: `nissan-crona`, `nissan-san-bernardino`, `security-workings`, `nissan-surf-city` (Docker Hub + SSH). Ignore them.

## 3. ocean (Django backend, both nodes)
1. **Build & push to ECR** (OC@main-migrated:6-20): no build args, no `--pull`. Tags `nisanweb-backend:<sha7>` and `:latest`.
2. **Deploy to Node A** (`deployment: aws-node-a`, automatic): `deploy.sh ocean main-migrated`.
3. **Deploy to Node B** (`deployment: aws-node-b`, **`trigger: manual`**). **ocean is NOT atomic.** Until someone clicks Node B, the nodes run different backend versions.

There is no Cloudflare purge step.

**Legacy:** `main` and `staging` SSH to `$SSH_HOST` and run `deploy/{production,staging}.sh` on the old droplet.

## 4. integration VM services
- **integrations_service:** `main-migrated` → ECR `leads-backend` → SSM to `i-03efb82c808863f84` running `deploy.sh integrations_service main-migrated`. `master`, `staging` and `development` are legacy SSH deploys that **still fire**.
- **chat_back:** `main-migrated` → ECR `chat-backend` → `deploy.sh chat_back main-migrated`. `main` is a no-op; `staging` is legacy.
- **framework_frontend:** `main-migrated` → build (env `aws-production`; args `VITE_API_BASE_URL`, `VITE_REVALIDATE_SECRET`, `VITE_SITE_NAME`, `VITE_SITE_AT`) → ECR `admin-dashboard` → `deploy.sh framework_frontend main-migrated`.

None of these has a Cloudflare purge step.

## 5. Custom pipelines (rollback)
- **`revert-surfcity` no longer exists on any production branch.** It was removed by commit 7f35d64 on 2026-10-01.
  - It survives only on dev branches (`development`, `corona-dev`, `nissan-branding`, `quick-changes-9/26/2026`).
  - Input: `REVERT_SHA` (7 characters). It checks that `website-frontend:${REVERT_SHA}-surfcity` exists in ECR, then deploys Node A automatically and Node B **manually**. It has no purge.
- **`revert-puentehills`** was cancelled by the user. Do not reintroduce it.
- **Practical rollback today:**
  1. Revert the commit on the `main-*` branch and let the pipeline run. This is the standard path.
  2. Or re-run the pipeline for the previous good commit in Bitbucket.
  - ECR lifecycle keeps the last 10 images per tenant stream, so very old SHAs may be gone (MH:3502-3508).

## 6. `/opt/dealerpulse/deploy.sh` (one script per VM, `set -euo pipefail`)
**Usage:** `deploy.sh <service> [branch] [tag]`.

**Services and aliases** (new.sh:34-48):
- `ocean` (backend, nisanweb-backend)
- `website_frontend` (frontend)
- `website_frontend_surfcity` (surfcity)
- `website_frontend_corona` (corona)
- `website_frontend_sanbernardino` (live only; not in any local copy)
- `integrations_service` (leads, leads_backend)
- `chat_back` (chat, chat_backend)
- `framework_frontend` (admin, admin_dashboard)

**Per-service directory and health URL** (new.sh:52-90):

| Service | Directory | Health URL | Container / port |
|---|---|---|---|
| ocean | `/opt/dealerpulse/backend/ocean` | `127.0.0.1:9000/api/` | compose `nisanwebsite-{web,worker,beat}-1` |
| website_frontend | `/opt/dealerpulse/frontend/website_frontend` | `:3000/` | `website_frontend`, 127.0.0.1:3000 |
| website_frontend_surfcity | `.../website_frontend_surfcity` | `:3001/` | `website_frontend_surfcity`, 3001 |
| website_frontend_corona | `.../website_frontend_corona` | `:3002/` | `website_frontend_corona`, 3002 |
| website_frontend_sanbernardino | live only, not in local copies | read from the box | `website_frontend_sanbernardino` |
| integrations_service | `/opt/dealerpulse/leads/integrations_service` | `:8129/health` | compose |
| chat_back | `/opt/dealerpulse/chat/chat_back` | `:9002/health` | compose |
| framework_frontend | `/opt/dealerpulse/framework/framework_frontend` | `:3003/` | `framework-frontend`, 127.0.0.1:3003→80 |

**Steps:**
1. **Wrong-box check:** exits 1 if the directory or deploy key is missing.
2. **Dirty-tree guard** (new.sh:103-110): if `git status --porcelain` shows anything, it prints the files and **exits 1**. It no longer auto-stashes.
   - Never edit tracked files in a deploy directory, and never leave backups inside it. `.env` is gitignored and safe to edit; `.env.bak` is **not** gitignored, so keep backups outside the repo.
3. **Git update:** `git fetch`, `checkout $BRANCH`, `pull` (using the deploy key).
4. **Per-service action:**
   - **ocean:** ECR login → `docker compose pull web worker beat` → `docker compose up -d --no-deps web worker beat`. The image is `:latest`, and web runs `migrate` and `collectstatic` on start.
   - **integrations_service / chat_back:** ECR login → `docker compose pull` → `docker compose up -d`. chat_back uses `--workers ${UVICORN_WORKERS:-2}`; override it in `.env`, never by editing the file.
   - **website_frontend\*:** `docker pull` the tenant tag → `docker rm -f <container>` → `docker run -d --restart unless-stopped` (awslogs group `/dealerpulse/website-frontend`) on 127.0.0.1:300x.
     - Only the Surf City case honours a third tag argument.
     - The pull happens before `rm -f`, so a failed pull leaves the old container running.
     - If `docker run` fails after the `rm -f`, that tenant has no container.
   - **framework_frontend:** `admin-dashboard:latest`, `docker run` on 127.0.0.1:3003→80.
5. **Health check:** up to 24 × 5 s. Any 2xx, 3xx or 4xx counts as success, so ocean's expected 428 passes. Otherwise it exits 1. **There is no automatic rollback.**

**Integration VM copy** (intvm.txt): two arguments only, no tenant cases. Otherwise the same logic.

## 7. DealerPulse (DigitalOcean)
**Backend `main`** (DPB@main:10-167), one automatic step, `deployment: production`:
1. Build and push Docker Hub `dealerpulse_backend:$IMAGE_TAG` and `:latest_production`.
2. `scp` the compose file to `/opt/dealerpulse/backend/`.
3. Read `active_env` (blue 8004 / green 8006) and pick the other colour.
4. Wait for the new port. This loop has **no timeout**.
5. `docker compose up -d web_$NEW`, then health-poll 30 × 5 s.
   - If it fails: stop the new colour, exit 1. **The old colour keeps serving.**
6. `nginx -t`, back up the vhost to `.bak`, `sed` the port, `nginx -t` again, reload.
7. Stop the old colour, write `active_env`, `--force-recreate` worker and beat.
8. `docker image prune -af` and `docker builder prune -af`.

**Backend `staging`:** the same switch on Apache, at `dp2.back.fluten.xyz` on the `combined` droplet. It uses `kill -9` and `fuser -k`.

**Frontend `main`:** push `dealerpulse_frontend:$IMAGE_TAG` and `:production_latest` → `scp` → `docker compose up -d` on 127.0.0.1:8014. **No blue/green and no health gate.** Old chunks are kept for 30 days in the `frontend_assets` volume.

Target host from the docs: droplet `146.190.132.236`. Registry: Docker Hub.

## 8. Deploy lessons (with sources)
- **Atomic frontend deploys still give a short 502 burst**, because there is no draining and the ALB doesn't check :3000. Measured at 21-52 user-facing 502s per deploy. Accepted; blue/green was not built (MH:2032-2049, MH:2957-2961, MH:3156-3160).
- **Stopping a Bitbucket run does not cancel an SSM command already dispatched.**
- **`.env`:** `docker compose restart` does not re-read it; use `up -d --no-deps <svc>`. deploy.sh never touches `.env`, so `.env` tuning survives deploys (MH:709, MH:2889-2892).
- **Dirty-tree guard:** a "dirty files" failure is the guard working, not a regression. Push the change to git first, then deploy (MH:2475-2531).
  - A "revert-pull-deploy" once restored a committed value and silently undid a tuning (`--workers 2`) (MH:3532-3541).
- **428 after a deploy:** the frontend can cache a failed crypto bootstrap if it starts before Django.
  - Check the 428 canary after every deploy.
  - Fix: restart the affected frontend containers, one node at a time, with approval.
  - The code fix and the deploy ordering are still open (MH:3332-3399).
- **Which version is running?** Everything uses `:latest`, so compare `docker inspect -f '{{index .RepoDigests 0}}'` with `aws ecr describe-images` (MH:3425-3431).
- **Pipeline YAML:** Bitbucket rejects plain script lines containing `: `; wrap them in `- |`. Test pipeline edits on `main-surfcity` first.
- **Health windows:** ocean's cold start can take about 3 minutes. **Never trust the pipeline's colour alone**; check the node.
- **Images are amd64-only.** NEXT_PUBLIC values exist only in the Bitbucket deployment variables (MH:3592-3596).
- **Logging flags:** a compose `logging:` block has no effect on services started with `docker run` (MH:858).
- **The first ECR deploy once reported success without swapping the container** (cause unconfirmed, MH:685). Verify container start times after deploys.
