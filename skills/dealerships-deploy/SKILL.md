---
name: dealerships-deploy
description: "How code reaches production for the Dealerships AWS platform (and the DealerPulse DigitalOcean product): which branch deploys what, the Bitbucket Pipelines -> ECR -> SSM -> deploy.sh flow, Cloudflare purge, ocean's manual Node B step, rollback, env var changes, failed or red pipelines, dirty-tree errors, 502s or blank pages after a deploy, adding a NEXT_PUBLIC variable, onboarding a new dealership. Use for any deploy, release, rollback, pipeline or 'what will this merge do' question."
---

# Deploy and release

Full detail with line citations: `Claude-Setup/knowledge/DEPLOY_FLOWS.md`. Deploys change production, so follow skill
`dealerships-change-control` before triggering or re-running anything. **Never deploy by hand on the servers.**

## What a merge to each branch does (production = `main-*` branches only)
| Repo | Branch | Result |
|---|---|---|
| website_frontend | `main-migrated` / `main-surfcity` / `main-corona` / `main-sanbernardino` | Build tenant image → ECR → **one SSM command to nodeA + nodeB** → Cloudflare purge |
| ocean (backend) | `main-migrated` | Build → ECR → Node A automatic → **Node B is a manual "Run" button in Bitbucket**. Until it's clicked, the two nodes run different backend versions |
| integrations_service, chat_back, framework_frontend | `main-migrated` | Build → ECR → SSM to the integration VM |
| DealerPulse backend / frontend | `main` | Docker Hub → SSH → blue/green switch (backend) / plain recreate (frontend) on the droplet |
**Danger:** pushes to legacy branches (`main`/`staging` in ocean; `master`/`staging`/`development` in integrations_service; `staging`/`master`/`production`
in framework_frontend; `staging` in chat_back and website_frontend) **still deploy to old hosts**. Treat them as live.
Ignore `nissan-*` and `security-workings` in website_frontend; they're dead.

## Before a deploy (read-only)
1. Which branch, which repo, which tenant? Use the table above.
2. Is it peak time for US dealerships? Frontend deploys give a short burst of 502s (about 20-50 requests). That's accepted, but avoid peak hours.
3. Is anything uncommitted in the deploy directory on the VM? deploy.sh refuses to run on a dirty tree (that's good). See below.

## After a deploy (always check, read-only)
1. Pipeline steps green. But **the pipeline colour alone isn't proof.** The step polls SSM for only 180 s, and ocean can take about 3 min to start.
2. On both nodes, `docker ps`: container start times for the tenant are within seconds of each other (frontends).
3. **428 canary** on both nodes: `sudo grep -c ' 428 ' /var/log/nginx/access.log` over the last minutes (UTC). A jump means the frontend cached a failed
   crypto bootstrap: pages render with empty content. Fix (approval): restart only the affected frontend container(s), nodeA first, then nodeB.
4. Public check: open the tenant site and confirm real content (inventory, FAQs), not just a 200.
5. For ocean: confirm Node B was clicked, and both nodes run the same image digest:
   `docker inspect -f '{{index .RepoDigests 0}}' nisanwebsite-web-1` compared with `aws ecr describe-images --repository-name nisanweb-backend`.

## deploy.sh (on each VM, `/opt/dealerpulse/deploy.sh <service> <branch> [tag]`)
- Services: `ocean`, `website_frontend`, `website_frontend_surfcity` (:3001), `website_frontend_corona` (:3002), `website_frontend_sanbernardino`
  (live script only; read its port from the box), `integrations_service` (:8129), `chat_back` (:9002), `framework_frontend` (:3003). Puente Hills frontend is :3000.
- **Dirty-tree guard:** if the repo checkout has changes, it prints them and exits 1. Don't "fix" this by stashing.
  Commit or push the change through git first. Never edit tracked files in deploy directories, and never leave backups inside them.
  `.env` is safe to edit (gitignored); keep `.env` backups **outside** the repo.
- ocean: `compose pull` + `up -d --no-deps web worker beat`; web runs `migrate` and `collectstatic` on start.
- Frontends: `docker pull` → `rm -f` → `docker run` (no draining, hence the short 502 window).
- Health check: 24 × 5 s; 2xx-4xx counts as up. There is no automatic rollback.

## Rollback
- Standard: revert the bad commit on the same `main-*` branch and let the pipeline run. Or re-run the previous good pipeline in Bitbucket.
- ECR keeps about the last 10 images per tenant stream.
- `revert-surfcity` was **removed from production branches on 2026-10-01**; don't rely on it. `revert-puentehills` was cancelled by the user; don't recreate it.
- DealerPulse backend: re-run the previous good pipeline (goes through the health gate). Manual colour flip only with approval (`knowledge/DEALERPULSE_OPS.md` §2.3).

## Common situations
| Situation | Meaning / action |
|---|---|
| Pipeline red on "Deploy to Node A" but the site works | Health window too short or SSM still running. Check the node, not the colour |
| "uncommitted or untracked changes" | The dirty-tree guard. Find what changed (`git status` on the VM, read-only), get it into git or moved out, then re-run |
| Pipeline stopped but deploy still happened | Stopping Bitbucket doesn't cancel SSM already sent |
| New `.env` value not taking effect | `docker compose up -d --no-deps <svc>` (not `restart`). Approval needed |
| Wrong dealership name or placeholder images on a new build | The build couldn't reach the backend; rebuild once the backend is reachable |
| chat_back memory high after a deploy | Check `--workers` (should be 2 via `UVICORN_WORKERS`); a deploy restores what's committed |
| YAML error / pipeline won't start | Bitbucket rejects `: ` in plain script lines (use `- |`); `deployment:` env must exist |

## New NEXT_PUBLIC variable
Add `ARG` in the Dockerfile, a `--build-arg` in every relevant build step, and the value in each tenant's Bitbucket deployment environment.
Values live only in Bitbucket.

## New dealership
Ask first: hostname and DNS owner, vendor IDs, vendor callback registration, capacity. Then follow `RUNBOOKS.md` §2 (one container, port, tag,
`deploy.sh` case, vhost and cert on **both** nodes, ACM cert on the ALB, Cloudflare DNS and cache rules, ocean `ALLOWED_HOSTS`/`CORS_ALLOWED_ORIGINS`/CSRF on both nodes,
own `main-<name>` branch and Bitbucket environment, Kuma monitor with the street-address keyword, Redis DB index).
