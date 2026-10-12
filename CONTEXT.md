# Full context — everything done in this Claude account (to 2026-10-13)

Written for: you on the new laptop, and any teammate or Claude agent that needs full context.

**Provenance convention.** `[doc]` = taken from a file in this repo or from Claude's saved memory,
not re-checked live when this was written. `[verified]` = checked directly in the session that wrote
this. No AWS, Cloudflare or server was queried while writing this document, so **everything about live
state is `[doc]` and dated**. Re-verify before acting (commands in §9).

---

## 1. Who and what

- User: Hamza (shamas.haq@flutenai.com), DevOps. Works for the Fluten / Nexrupt team; the team is in
  Pakistan, customers are California Nissan dealerships.
- Claude Code settings (`~/.claude/settings.json`) `[verified]`: model `sonnet`, effort `high`,
  auto-updates `latest`.
- Everything was done through Claude Code with the working directory `C:\Users\Hamza DevOps\Documents`.

## 2. The two projects (do not confuse them)

| | **Dealerships** | **DealerPulse** |
|---|---|---|
| What | Multi-tenant Nissan dealership website platform | Separate, newer product (calls/AI voice agents, SMS) |
| Where | **AWS** `409289617504`, `us-west-2` (migrated from DigitalOcean) | **DigitalOcean** droplet `146.190.132.236` (hostname `Surfcity-Live`) |
| Our role | We built and run it | Inspected read-only; changes need approval |
| Naming trap | Recorded as "DealerPulse" until 2026-09-17; all AWS resources stay `dealerpulse-*` | Genuinely named DealerPulse |

### 2.1 Dealerships
Tenants `[doc]`: Puente Hills Nissan (`www.puentehillsnissan.com`, third-party Cloudflare zone, ~99% of
historical traffic), Surf City Nissan, Corona Nissan, Nissan of San Bernardino (both live by early Oct 2026;
final domain cutover noted as pending in HANDOVER.md).

Apps `[doc]`: `ocean` (Django + Celery + Redis; CMS/inventory API), `website_frontend` (Next.js, one container
per tenant), `integrations_service` (lead delivery to VinSolutions/Cox), `chat_back` (FastAPI chatbot via
OpenRouter), `framework_frontend` (admin dashboard).

Infrastructure `[doc]`: Cloudflare -> ALB `dealerpulse-alb` (Cloudflare IPs only) -> nginx :443 on nodeA/nodeB
-> containers on localhost; shared Postgres on the integration VM. Source in Bitbucket (`nxpt/*`); Bitbucket
Pipelines -> ECR -> `aws ssm send-command` -> `/opt/dealerpulse/deploy.sh`. Full diagram, inventory with
instance/SG/ALB IDs, deploy rules and monitoring are in **`HANDOVER.md` §1-§5** — do not duplicate them here.

### 2.2 DealerPulse `[doc]`
Droplet 2 vCPU / 8 GB, also hosts the unrelated `callingyounow` product and four dead v1 tenant deployments.
App DB is a **DigitalOcean Managed Postgres** (`...:25060`, user `doadmin`), not on the droplet.
**Highest-severity open finding in the account:** as of 2026-09-22 the managed DB had Trusted Sources
disabled (reachable from any IP). Fix = enable Trusted Sources in the DO panel + stop using `doadmin`.
Needs approval; re-test with a plain TCP connect. Docs: `DealerPulse/` (ARCHITECTURE, BACKEND_FIXES with 17
items, INCIDENT_2026-09-16, MONITORING, scripts).

## 3. Side systems

- **Team VPN** `[doc]`: WireGuard via wg-easy on `i-0ad5d9743f6c95721`, EIP `44.225.91.181`, `t4g.micro`, SG
  `team-vpn-sg`. Gives the Pakistan team a US exit IP. Confirmed working against a live dealership site
  (2026-09-12); exit is an AWS datacenter ASN, not residential. **Throughput bottleneck**: 11.3 vs 116 Mbps
  with VPN on/off (2026-09-29), likely the t4g.micro. Admin SSH restricted to one admin IP; the
  **`MyUptimeIP`** skill updates it. Uptime Kuma also runs here (`uptime.callingyounow.us`).
  Docs: `TeamVPN/`, `Monitoring/`.
- **Fluten RDP box** `[doc]`: rented Windows RDP `93.127.140.109`, RDP port **10025**, SSH 22. Network is excellent,
  CPU ~27x slower than the laptop (1 core, 2.8 GB). Browsing slowness there is CPU, not network. Fix = bigger box.
- **Legacy DigitalOcean** `prod`, `combined`: on the decommission path, do not build on them.
- **Personal/other**: CV HTML/PDFs in `Documentations/` are personal documents, unrelated to the infra work.

## 4. Timeline of what was done `[doc]` (detail in `Migration/MIGRATION_HISTORY.md`, 3,599 lines)

| When | What |
|---|---|
| Aug 2026 | AWS migration built with raw AWS CLI (deliberately no Terraform): VPC, nodes, S3, IAM, SSM, ECR, DLM snapshots, Chatbot -> Slack alerts. Pivoted to merged FE+BE on two nodes + ALB. |
| 2026-09-01 | ALB live, shared Postgres, origin locked down to Cloudflare, `phn`/`api` cut over. Several deploy.sh auto-stash bugs found. |
| 2026-09-03/04 | Cloudflare config, 5-service ECR CI/CD, nginx cache audit, CSP enforcing, WAF + country allow-list (US/CA/PK/JP). |
| 2026-09-09/10 | puentehillsnissan.com cutover; Cloudflare cache rules; Team VPN built. |
| 2026-09-11/12 | Surf City got its own pipeline (`main-surfcity`); inventory slowness root-caused (Redis cache written/read in different places). |
| 2026-09-14/15 | Rightsizing; nodeA CPU-credit exhaustion -> ALB weighted 35/65; netdata proven to be the CPU burn and removed; memory metrics fixed. |
| 2026-09-16 | Cross-node chunk-404 incident on PHN; DealerPulse incident report. |
| 2026-09-17 | Latency alarm root-caused (Redis stampede every 2h + Next image optimizer); project renamed Dealerships. |
| 2026-09-18 -> 25 | Call prep with CTO; uptime monitoring plan; fleet audit; incident review; domain-expiry monitors. |
| 2026-09-29 | VPN throughput and RDP-box benchmarks. |
| 2026-10-01 | Incident: SSR data loading broken site-wide after a deploy (resolved). |
| 2026-10-02/03 | Chatbot down (OpenRouter out of credits); AWS cost cleanup, ECR lifecycle policies, nodes now t3.large. |
| 2026-10-05 | Sweep: all alarms OK; San Bernardino live; integration node swapping because chat_back reverted to 4 workers. |
| 2026-10-06 | Graviton (arm64) trial rolled back (all ECR images amd64-only; user chose not to pursue). |
| 2026-10-12 | `HANDOVER.md` written and pushed to GitHub (`hamzaadevops/Documentations`). |

## 5. Open items `[doc]` — last updated 2026-09-17 (TODO.md) plus Oct history. **Re-verify each.**

1. DealerPulse managed Postgres Trusted Sources (security, highest severity).
2. Integration VM memory/swap: no alarm; chat_back `--workers` fix `3ed8deb` was **local-only, unpushed** as of
   2026-10-05. Verify it was pushed.
3. No real health endpoint (matcher `200-499`); do not switch matcher to `200` until one exists.
4. HomeNet Redis cache stampede and Next.js image optimizer (the cause of the latency alarm).
5. Legacy `.htm` URLs falling through to SSR (up to 350 s).
6. Django `LOGGING`/Sentry missing; VPN box IAM profile; integration reboot + resize window.
7. One failed e-Price lead (422 from leads service, 2026-10-05).
8. Corona / San Bernardino: update `NEXT_PUBLIC_IMAGE_ALLOWED_DOMAINS` / `NEXT_PUBLIC_SITE_URL` and cut domains over.
9. Duplicate Celery beat on both nodes.
`TODO.md` is the canonical list. It was last edited 2026-09-17, so it is **stale versus October history**.
Do not edit it without discussing with the user.

## 6. Documentation map (all under `Documents/Documentations/` unless noted)

| Path | Contains |
|---|---|
| `HANDOVER.md` / `.docx` | Operational handover, 7 sections (best single file for a new engineer) |
| `Migration/COMMAND_LOG.md` | Verbatim AWS commands + resource IDs |
| `Migration/MIGRATION_HISTORY.md` | Narrative of every session, incidents, decisions |
| `Migration/OCTOBER_CAPACITY_PLAN.md`, `CALL_BRIEF_2026-09-18.md` | Planning docs |
| `Migration/*.json`, `ecr-lifecycle/`, `scripts/`, `db-backups/` | Dashboards, policies, scripts, a DB dump |
| `DealerPulse/` | Separate-project docs and probe scripts |
| `Monitoring/`, `TeamVPN/` | Kuma setup, nginx configs, VPN history |
| `pre-migration/` | Original architecture and AWS plan (stale, historical) |
| `TODO.md`, `INVENTORY_PERFORMANCE_*.md`, `TENANTS_PUENTE_HILLS_SURF_CITY.md` | Planning and analysis |
| `../ONBOARDING.md` | Older onboarding (2026-09-17; says ALB 35/65, HANDOVER says 50/50. **Conflict: check live**) |
| `../` repos | `ocean`, `website_frontend`, `integrations_service`, `chat_back`, `framework_frontend`, `dp_backend_v2`, `dp_frontend_v2`, `starfish` |

## 7. Claude configuration inventory (what to recreate on the new laptop)

`[verified]` present on this laptop:
- **Memory** (11 files + index) in `~/.claude/projects/c--Users-Hamza-DevOps-Documents/memory/`. Copy in `memory-export/`.
- **Custom skills** `~/.claude/skills/ConnectWireguardUI` and `MyUptimeIP` (copy both folders).
- **Synced skills** (docs, docx, pdf, pptx, xlsx, google-workspace, morning, skill-creator, import-memory)
  come from the claude.ai account, so they reappear after login. No copying needed.
- **Permissions allow-list**: `Documents/.claude/settings.local.json` (~9 KB of approved AWS CLI commands, hard-coded
  to the old laptop's AWS path). Review it, do not blindly copy; prefer a fresh allow-list for read-only commands.
- **SSH**: `~/.ssh/config` hosts `combined`, `prod`, `dealerpulse`, `node_vpn`, `kuma`, `wg-ui`, `vpn-box`,
  `kuma-vpn`, `wg-ui-vpn`; keys `~/.ssh/team-vpn`, `~/.ssh/digitalocean`.
- **AWS CLI v2**, IAM user `HamzaDevOps`; credentials are in `~/.aws`. Not in this pack.
- **Connectors needing re-auth** (claude.ai settings): Slack, Notion, Gmail, Microsoft 365, etc. are listed as
  unauthenticated here; Atlassian and Claude Docs are available.
- **Other Claude project folders**: `Downloads/Joblogic`, `hamza` (chat transcripts only, no memory worth moving).
- Chat transcripts (`~/.claude/projects/*/*.jsonl`) hold the session history. Optional to copy; useful for audit.

## 8. Credentials and security: read before copying anything

- **Four `.env` files are tracked in git and pushed to GitHub** `[verified]`: `backend.env`,
  `chat_backend.env`, `frontend.env`, `leads_backend.env` (in `Documentations/`, in history since commits
  `c29d354`/`8dbd22c`). I did not open them. Check whether the repo is private. If any contain live secrets,
  rotate them and remove from history. This is a finding in its own right.
- `Documents/` also contains `vars_*.json`, `env_list.json`, `surfcity-pipeline-variables.txt`, `dealerpulse.dump`,
  `nisan_website.dump` and `.rdp` files. These are likely sensitive; transfer them by encrypted means, not git.
- `.credentials.json` in `~/.claude` is the Claude login. **Do not copy it.** Log in fresh on the new laptop and
  log out of the old one.
- The memory export includes AWS access-key **IDs** (not secrets) and account IDs. Keep this pack in a private repo.
- Company-laptop exit: revoke the `HamzaDevOps` access keys and the laptop's SSH keys at the right time,
  and confirm with the user what the company wants wiped.

## 9. Re-verify current state (read-only, run first on the new machine)

```bash
aws sts get-caller-identity
aws ec2 describe-instances --filters "Name=tag:Project,Values=dealerpulse" \
  --query "Reservations[].Instances[].[InstanceId,InstanceType,State.Name]" --output table
aws cloudwatch describe-alarms --query "MetricAlarms[].[AlarmName,StateValue]" --output table
aws elbv2 describe-target-groups --query "TargetGroups[].TargetGroupArn" --output text   # then describe-target-health
aws elbv2 describe-rules --listener-arn <arn>      # confirm 50/50 vs 35/65 weighting
git -C Documentations log --oneline -5
```
