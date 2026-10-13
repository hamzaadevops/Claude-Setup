---
name: dealerships-deploy
description: "How code reaches production on the Dealerships AWS platform: Bitbucket branches per tenant, Pipelines -> ECR -> single SSM command to both nodes -> deploy.sh -> Cloudflare purge; rollback; env var changes; adding a dealership. Use when someone asks to deploy, release, roll back, redeploy, change an env var, add a NEXT_PUBLIC variable, or onboard a new dealership/rooftop."
---

# Deploy and release

Approval required for anything that runs (skill `dealerships-change-control`).

## Branch -> what deploys
| Branch | Deploys |
|---|---|
| `main-migrated` | Puente Hills frontend + shared services (ocean, integrations_service, chat_back, framework_frontend) |
| `main-surfcity` | Surf City frontend |
| `main-corona` | Corona frontend |
| `main-sanbernardino` | San Bernardino frontend |
Ignore the old `nissan-*` / `security-workings` branches in `website_frontend/bitbucket-pipelines.yml` (dead SSH model).

## Pipeline
Build image (tenant vars from the Bitbucket deployment environment, e.g. `aws-production`, `aws-prod-surfcity`) -> push to ECR (`<sha>`, `latest`/`latest_<tenant>`)
-> **one** `aws ssm send-command` targeting nodeA + nodeB -> `/opt/dealerpulse/deploy.sh <service> <branch>` -> Cloudflare `purge_everything`.
`deploy.sh`: `ocean`, `integrations_service`, `chat_back` use docker compose; `website_frontend*` and `framework_frontend` use docker pull/rm/run.

## Rules
- Never deploy one node only (old and new chunk hashes -> ChunkLoadError).
- Stopping a Bitbucket run does not cancel an SSM command already sent.
- Frontend deploys cause a brief 502 window; avoid peak traffic.
- After a deploy check the **428 canary** (`grep -c ' 428 ' /var/log/nginx/access.log`): a frontend that started before Django can cache a failed
  crypto bootstrap and render empty pages. Remedy: restart the frontend containers, one node at a time (approval).
- `.env` change -> `docker compose up -d --no-deps <svc>`, never `restart`. `deploy.sh` never touches `.env`.
- Hand-edited files in deploy-managed repos can be auto-stashed by a deploy (`git stash list`); the ocean `docker-compose.override.yml` must exist on nodes.
- When proving a Next.js content fix, build with `--pull --no-cache`.

## Rollback
Surf City: custom pipeline `revert-surfcity` (redeploy an existing ECR tag by 7-char SHA). Others: run the pipeline on the previous commit.
Infrastructure: the detached `dealerpulse-tg-nginx` target group is the instant ALB rollback path.

## New NEXT_PUBLIC variable
Add `ARG` in the Dockerfile, `--build-arg` in every relevant pipeline build step, and the value in each deployment environment.

## New dealership (8 steps)
Ask first: hostname and DNS owner; pipeline pattern (own branch is the current pattern); vendor IDs; vendor callback registration; capacity.
1 CMS `Dealership` row. 2 clone `website_frontend_<name>` on both nodes. 3 ACM cert + SNI on the ALB. 4 nginx vhost + new local port + origin cert on both
nodes. 5 Cloudflare DNS to the ALB + cache rules (full-replace PUT). 6 ocean `ALLOWED_HOSTS` / `CORS_ALLOWED_ORIGINS` on both nodes. 7 new `deploy.sh`
case (own container/port/tag). 8 pipeline steps + Bitbucket deployment environment. Then a Kuma monitor (street-address keyword) and a Redis DB index.
