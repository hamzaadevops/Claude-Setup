---
name: multi-frontend-deploy
description: How one website_frontend repo deploys many dealership sites (Bitbucket deployments + build-arg-baked images)
metadata:
  node_type: memory
  type: project
  originSessionId: 44c77a6c-32e8-42d2-8b1e-7cb99dd70ca2
  modified: 2026-09-25T19:59:09.696Z
---

One Next.js codebase serves multiple dealership sites. Per-site differences are NEXT_PUBLIC_* vars baked in at `docker build` via --build-arg, sourced from a Bitbucket **Deployment environment** per site (so each site = its own image).

- Legacy/VPS sites: one git branch per site (staging, nissan-crona, nissan-san-bernardino, security-workings, nissan-surf-city). Each: build -> push to Docker Hub `dealerships_website_frontend:<tag>` -> ssh+scp docker-compose.yml to `/opt/dealerships/websites/<site>` -> `docker compose up -d` with per-env STACK_NAME / HOST_PORT.
- AWS prod (branch main-migrated): multiple sites on SAME branch as sequential steps. Puente Hills (deployment aws-production, ECR tags `<sha>`/`latest`, `deploy.sh website_frontend`) then Surf City (deployment aws-prod-surfcity, tags `<sha>-surfcity`/`latest_surfcity`, `deploy.sh website_frontend_surfcity`). Deploy = SSM send-command `/opt/dealerpulse/deploy.sh <app> main-migrated` on Node A (auto) and Node B (manual trigger).
- Adding a new NEXT_PUBLIC var means adding a --build-arg to every relevant build step (and ARG in Dockerfile) plus setting it in each deployment env.

**Why:** user asked to recall this setup on 2026-09-26; no prior memory existed.
**How to apply:** when adding a site or env var, follow these patterns; Surf City steps are intentionally after Puente Hills so failures don't block it.
