# RUNBOOKS — how to do the recurring things

`[doc]` = from our files. Anything that writes to production needs explicit approval first (CLAUDE.md §3).
After any change: append to `Documentations/Migration/COMMAND_LOG.md` and `MIGRATION_HISTORY.md`.

## 1. Deploy (normal path)
1. Code is merged to the branch for the tenant (`main-migrated`, `main-surfcity`, `main-corona`, `main-sanbernardino`).
2. Bitbucket Pipeline builds the image -> pushes to ECR -> **one** `aws ssm send-command` to both nodes -> runs
   `/opt/dealerpulse/deploy.sh <service> <branch>` -> automatic Cloudflare purge (`purge_everything`).
3. Services: `ocean`, `integrations_service`, `chat_back` use docker compose; `website_frontend*`, `framework_frontend`
   use `docker pull` / `rm -f` / `run`. A compose-level `logging:` change is dead for the latter two.
4. Rules: never deploy the two nodes separately (cross-node chunk 404s). New `.env` var -> `docker compose up -d --no-deps`.
   Stopping a Bitbucket run does **not** cancel an SSM command already dispatched. Avoid peak hours: frontend deploys give a
   brief 502. Use `docker build --pull --no-cache` when proving a Next.js content fix.
5. Verify after: both target groups healthy; ` 428 ` count in nginx log (canary, INCIDENTS #1); `cf-cache-status` MISS->HIT;
   `docker ps` start times (the nodeA/nodeB gap should be ~0-1 s; old design had ~2.5 min).
6. Revert: Surf City `revert-surfcity` custom pipeline (by 7-char SHA, verifies tag in ECR). Puente Hills: no revert pipeline.
7. Known weakness: frontend and Django are replaced within seconds, so a deploy can race (INCIDENTS #1). Pending code fix.

## 2. Add a new dealership (standing 8-step pattern) `[doc]`
Ask first: real hostname + who controls DNS; which pipeline pattern (single-branch vs per-branch `main-<name>`); real vendor IDs
(Capital One, Dealer700, DSS href); whether Cox/xtime know the new host; capacity for one more container per node.
1. `Dealership` row exists in the CMS (or create). 2. Clone `website_frontend_<name>` on both nodes. 3. ACM cert + SNI attach on the ALB
(DNS validation trivial for `*.callingyounow.us`). 4. nginx vhost (same self-signed origin cert), new local port, and a Let's Encrypt cert
per node if the host needs one. 5. Cloudflare CNAME to the ALB + cache rules (full-replace PUT: resubmit every existing rule).
6. `ocean` `ALLOWED_HOSTS` / `CORS_ALLOWED_ORIGINS` on **both** nodes. 7. New `deploy.sh` case with its own container/port/tag
(never reuse). 8. Pipeline steps + a new Bitbucket deployment environment with that dealership's build variables
(`NEXT_PUBLIC_DEALERSHIP_ID`, `NEXT_PUBLIC_SITE_URL`, `NEXT_PUBLIC_IMAGE_ALLOWED_DOMAINS`, ...).
Also: Redis DB index per tenant, a Kuma monitor row with its street-address keyword, and a build-order check (the build calls the
backend; if unreachable it bakes in fallback branding such as "Surf City Nissan").

## 3. Daily sweep (read-only, ~15 min) `[doc]`
Alarm states; ALB 5xx and target health (check the metric is scoped to the LoadBalancer, a past report was wrong from that);
`docker ps` restart counts, `free -m`, `df -h /`, `docker stats --no-stream` on all three VMs via SSM; ` 428 ` count on
`nisanwebsite-web-1` last hour; integration swap (expect trouble if `chat_back` runs 4 workers); cert expiry; dashboards over a short
window; chatbot errors (OpenRouter 402). Log result in MIGRATION_HISTORY as a dated entry; templates: 2026-09-25, 10-01, 10-05.
Commands: HANDOVER.md §7. Remember nginx is UTC, container logs `+0500`.
SSM tip: write the command array to a JSON file and use `--parameters file://`; do not use inline `$(...)`.
Git Bash mangles leading-`/` args: `export MSYS_NO_PATHCONV=1` or use PowerShell. A command blocked in Bash may succeed in PowerShell.

## 4. Reaching things
- Nodes/integration: `aws ssm start-session --target <id>`; scripted: `aws ssm send-command --document-name AWS-RunShellScript`.
- WireGuard UI: skill `ConnectWireguardUI` (SSH tunnel -> `http://localhost:51821`).
- Kuma: `ssh -i ~/.ssh/team-vpn -L 3001:127.0.0.1:3001 ubuntu@44.225.91.181` then `http://localhost:3001`, or `https://uptime.callingyounow.us`.
- Allowlist a new admin IP for SSH + Kuma: skill `MyUptimeIP <ip>`.
- DealerPulse droplet: `ssh dealerpulse` (ask first).

## 5. Cloudflare changes `[doc]`
Ask the user for a token each session (never stored; token creation is classifier-blocked, they mint it in the dashboard).
Editing an existing token's permissions in the UI did not persist; a new token did. Custom WAF rules need the **Zone WAF Write**
permission group, not just "Firewall Services". Rulesets are replaced with PUT: always resubmit the full list (country list US/CA/PK/JP).
Verify with the API read, not the dashboard summary. Debug order for odd behaviour: SG/prefix-list drift -> extension-based cache rule ->
HSTS window -> hotlink protection -> only then app bugs.

## 6. Add an admin IP / VPN client
`MyUptimeIP <ip>` skill; `ConnectWireguardUI` skill. VPN peers are created in the browser (keypair uses `crypto.subtle`, which needs
`localhost` or HTTPS). Never send the user to the IP directly.

## 7. Logging templates
COMMAND_LOG.md: heading with date, the exact command, the resulting ID, no paraphrase.
MIGRATION_HISTORY.md: `## YYYY-MM-DD — <what>`: symptom, evidence (numbers, commands), root cause, decision, what is NOT done.
Use `[verified]/[doc]/[told]/[assumed]` and UTC with PKT in brackets.

## 8. Handling blocked actions
Classifier denies secret creation, shared-resource writes (even mocked), remote installs. After the first denial, stop. Restructure
to read-only, or give the user the exact step. Never reword and retry.
