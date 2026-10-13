# RUNBOOKS — how to do the recurring things

`[doc]` = from our files. Anything that writes to production needs explicit approval first (CLAUDE.md §3).
After any change: append to `records/Migration/COMMAND_LOG.md` and `MIGRATION_HISTORY.md`.

## 1. Deploy (normal path): full detail in skill `dealerships-deploy` and `knowledge/DEPLOY_FLOWS.md`
1. Code is merged to the right branch: frontends `main-migrated` (Puente Hills), `main-surfcity`, `main-corona`, `main-sanbernardino`;
   ocean, integrations_service, chat_back and framework_frontend use `main-migrated`. **Never push to `main`/`master`/`staging`** expecting nothing to
   happen: legacy pipelines still deploy to old hosts.
2. Bitbucket builds the image → ECR → SSM runs `/opt/dealerpulse/deploy.sh <service> <branch>`:
   - frontends: both nodes in one command, then an automatic Cloudflare purge;
   - **ocean: Node A automatic, then click the manual "Deploy to Node B" step;**
   - integration services: the integration VM.
3. Rules:
   - Avoid US peak hours (frontend deploys give a brief 502 burst).
   - A red pipeline step isn't proof of failure; check the node.
   - Stopping a run doesn't cancel an SSM command already sent.
   - A "dirty files" failure means someone edited the checkout on the VM; get the change into git, then re-run.
4. Verify after:
   - target groups healthy;
   - ` 428 ` count per node (canary for blank pages);
   - real content on the site;
   - container start times close together on both nodes;
   - for ocean, both nodes on the same image digest.
5. Rollback: revert the commit on the same branch (pipeline redeploys), or re-run the previous good pipeline. `revert-surfcity` no longer exists on
   production branches (removed 2026-10-01); there is no Puente Hills revert pipeline (user decision).

## 1a. Blank pages after a deploy (428): approved fix only
Evidence: the ` 428 ` count jumped in the deploy hour; the page shows header and footer with no content. With approval, restart only the affected
frontend container(s): nodeA first, verify the 428 rate drops and content renders, then nodeB. Then purge Cloudflare (the user, in the dashboard, or the
pipeline's purge step Redeploy button). Log it.

## 1b. Change an `.env` value (approval)
Back up `.env` **outside** the repo (for example `/opt/dealerpulse/backups/`), edit with a one-line `sed`, `diff` to show one line changed,
confirm `git status --porcelain` is empty, then `docker compose up -d --no-deps <services>`. Verify inside the container that the variable is set,
printing **set/not set only, never the value**. Deploys never touch `.env`, so the change persists. Example: the 2026-09-21 HomeNet TTL change (`knowledge/ISSUES_AWS_B.md` D-01).

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
Commands: skill `dealerships-monitoring` and `knowledge/ISSUES_AWS_B.md` section (a). Remember nginx is UTC, container logs `+0500`.
SSM tips:
- Write the command array to a JSON file and use `--parameters file://`; never inline `$(...)`.
- The remote shell is `sh`, not bash.
- Avoid `\|` in JSON; use `grep -E`.
- Git Bash mangles leading-`/` arguments: `export MSYS_NO_PATHCONV=1`, or use PowerShell.

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
`MyUptimeIP <ip>` skill; `ConnectWireguardUI` skill. VPN peers are created in the browser by the operator (keypair uses `crypto.subtle`, which needs
`localhost` or HTTPS). Never send the user to the IP directly. Check the generated config's `Endpoint` is `44.225.91.181:51820` (wg-easy still stores
the old address); set `PersistentKeepalive = 25`. Easiest admin access: connect to the VPN (its exit IP is allowlisted for Kuma; SSH via `vpn-box`).

## 7. Logging templates
COMMAND_LOG.md: heading with date, the exact command, the resulting ID, no paraphrase.
MIGRATION_HISTORY.md: `## YYYY-MM-DD — <what>`: symptom, evidence (numbers, commands), root cause, decision, what is NOT done.
Use `[verified]/[doc]/[told]/[assumed]` and UTC with PKT in brackets.

## 8. Handling blocked actions
Classifier denies secret creation, shared-resource writes (even mocked), remote installs. After the first denial, stop. Restructure
to read-only, or give the user the exact step. Never reword and retry.
