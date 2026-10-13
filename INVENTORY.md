# INVENTORY — IDs, hostnames, ports, accounts

All `[doc]` unless marked; sources: HANDOVER.md, TENANTS_PUENTE_HILLS_SURF_CITY.md, memory notes, history to
2026-10-06. Re-verify before acting (RUNBOOKS §3). No secrets here, by design.

## 1. AWS (account `409289617504`, region `us-west-2`, IAM user `HamzaDevOps`)

| Resource | ID / value |
|---|---|
| nodeA | `i-061291ea974c4ea1b`, us-west-2a, `10.0.1.94`, EIP `184.32.92.25`, t3.large |
| nodeB | `i-0c982c44f93bfbc0a`, us-west-2b, `10.0.2.129`, EIP `35.95.214.123`, t3.large |
| integration | `i-03efb82c808863f84`, 2a, `10.0.1.92`, EIP `52.12.241.229`, t3.medium (3.8 GB, most constrained) |
| team VPN + Kuma | `i-0ad5d9743f6c95721`, t4g.micro, EIP `44.225.91.181` (old `44.242.4.12` is gone) |
| VPC | `vpc-04362594fced3c6f0` `10.0.0.0/16`; subnets `subnet-067d90425d81116e3` (2a), `subnet-02464b852778c1e06` (2b) |
| SG ALB | `sg-034a06fe048939fc5` (Cloudflare prefix lists `pl-0dc48316ba9fa95bd` v4, `pl-0a7981fd8cec1fa9a` v6) |
| SG nodes | `sg-0587ebfd9dd3a52a7` (`dealerpulse-sg-merged`): 80/443 from sg-alb only. A node must carry **only** this SG |
| SG integration | `sg-097c63c5851f32550`: 80/443 Cloudflare only; 5432/6379 from sg-merged only |
| SG VPN | `team-vpn-sg` `sg-020165aeddafe5322` (22 from admin IP only) |
| ALB | `dealerpulse-alb`, DNS `dealerpulse-alb-158980700.us-west-2.elb.amazonaws.com`; TGs `dealerpulse-tg-nodea`, `-nodeb`; `-nginx` detached (rollback). Weighting: **HANDOVER says 50/50, TENANTS doc says 35/65 since 09-14. Conflict: verify** |
| ECR | `nisanweb-backend`, `leads-backend`, `chat-backend`, `website-frontend`, `admin-dashboard` (lifecycle policies 2026-10-03, JSON in `Migration/ecr-lifecycle/`). Tags: `latest`, `latest_surfcity`, commit SHA |
| S3 | `dealerpulse-media-409289617504`, `dealerpulse-backups-409289617504` (media via EC2 role, no static keys) |
| IAM | `dealerpulse-ec2-ssm-role`, `dealerpulse-dlm-role`, `dealerpulse-chatbot-role`, `dealerpulse-developers-readonly`, `dealerpulse-sr-developers-readwrite`, CI/CD user `dealerpulse-cicd-bitbucket` |
| Alerts | SNS `dealerpulse-alerts` -> AWS Chatbot -> Slack `#aws-alerts-dealerpulse` (workspace "Nexrupt Tech"). Don't recreate Chatbot casually |
| Logs/metrics | CloudWatch log groups `/dealerpulse/*` (9); dashboards `DealerPulse-Fleet-Overview`, `-Logs`, `-Per-VM`; namespace `DealerPulse/nginx`; CWAgent metrics live since 2026-09-15 |
| SSM params | `/dealerpulse/shared/postgres-superuser-password`, `/dealerpulse/shared/ocean-db-password` (SecureString) |
| Alarms (7, all OK on 10-05) | ALB 5xx (gated), per-node target health, CPU credits, `dealerpulse-alb-latency-p99`, nginx fd-exhaustion (deleted once; verify it exists) |
| Tags | `Project=dealerpulse`, `Environment=production`, `ManagedBy=cli-manual`; DLM snapshots target the Project tag |
| EBS | encryption by default ON; EC2 serial console access enabled |

## 2. On-host layout
- Deploy tool: `/opt/dealerpulse/deploy.sh <service> <branch>` (one script per VM, `case "$SERVICE"`).
- Clones: `/opt/dealerpulse/frontend/website_frontend`, `.../website_frontend_surfcity`, `/opt/dealerpulse/chat/chat_back`.
- `ocean` containers: `nisanwebsite-web-1`, `-worker-1`, `-beat-1` (compose). `docker-compose.override.yml` on nodes holds the real DB `HOST` (untracked; once lost to a deploy auto-stash).
- DB env names (ocean): `DATABASE_NAME`, `DATABASE_USER`, `PASSWORD`, `HOST` (port hardcoded 5432).
- Shared Postgres: `ocean-shared-postgres` (postgres:15) on integration, role `ocean_app`, DB `nisan_website`, `max_connections` 150.
- Integration containers: `chat_back-postgres` (pgvector), `leads_backend-postgres`, `ocean-shared-postgres`, `website-shared-redis`, `chat_back-web-1`, `framework-frontend` (:3003, misnamed), leads :8129, chat :9002 (WS).
- Redis is **per node** (accepted decision). HomeNet cache DB index: db2 Surf City, db6 Puente Hills, db11 Corona, db12 San Bernardino.

## 3. Hostnames and tenants

| Tenant | Host | Container / port | ECR tag | Pipeline branch |
|---|---|---|---|---|
| Puente Hills Nissan | `www.puentehillsnissan.com` (+ `phn.callingyounow.us`) | `website_frontend` :3000 | `latest` | `main-migrated` |
| Surf City Nissan | `surfcity.callingyounow.us` | `website_frontend_surfcity` :3001 | `latest_surfcity` | `main-surfcity` |
| Corona Nissan | **migrated per user (2026-10-13; exact date and hostname not recorded, verify live)**; container running since ~09-26 | `website_frontend_corona` | n/a | `main-corona` |
| Nissan of San Bernardino | pending cutover (up since ~10-03) | `website_frontend_sanbernardino` | n/a | `main-sanbernardino` |

Our own hostnames (`callingyounow.us`): `phn.`, `api.` (ALB, encrypted API), `admin.`, `chat.`, `leads.` (integration VM, Cloudflare-proxied nginx), `uptime.` (Kuma). Dealership IDs (CMS): Surf City `c3e9748b-353d-49b7-9599-86a3ba314fa2`.
Keyword monitors use street address: Puente Hills `17320 Gale Ave`, Surf City `17331 Beach Blvd`.
Puente Hills `is_multiple` group = 4 rooftops (loads ~27.6 MB per inventory request); Surf City = 2. Intentional or drift: unconfirmed.

## 4. Cloudflare
- Our zone `callingyounow.us` (Free plan): Zone ID `283d6090889e4fdd64e23e6790cfa50a`, account `b99522927fa24d3bce77b812f591b7a3` ("Shahzad@nexrupt.com's Account"). Not secrets.
- `puentehillsnissan.com`: **third party's account** `18bcf34342aa0ce918118b335f5ccdb9` ("It@gkmotors.com's Account"), zone `d68d738c1d15ec0cd770a9533e16d5ae`. Coordinate before changes. User has visibility.
- Tokens are never stored. Ask the user each session. Pipeline vars: `CF_API_TOKEN_PUENTEHILLS`, `CF_API_TOKEN_CALLNOW_US`.
- Dashboard paths: Security -> WAF / Events; Caching -> Cache Rules.
- Settings made: SSL "Full" (not Strict), always_use_https, HSTS max_age 300 (never ramped), min TLS 1.2, early hints, hotlink protection ON, Auto Minify impossible (silently no-ops).
- WAF: Free Managed Ruleset (zone-wide, Block); country allow-list **US/CA/PK/JP** (rule edited via full-replace PUT; ACME challenge path exempted 2026-09-07). Highest-risk setting: could silently block Cox/xtime vendor callbacks.
- Cache rules (phn): static assets 30 d override-origin (matches **extension**, incl. `public/` images); `/_next/image` rule; HTML edge cache `respect_origin` excluding `/api/*`, `/_next/*`, RSC headers (**do not remove the RSC exclusion**: cache poisoning); response-phase `strip_set_cookie` (kills ALB cookie, hence no stickiness); 4xx/5xx edge TTL 0 on the static rule. Zone-wide "Cache Everything [Template]" must stay **disabled**.

## 5. Source control / CI
Bitbucket workspace `nxpt` (repos `ocean`, `website_frontend`, `integrations_service`, `chat_back`, `framework_frontend`, `backend_v2.1`, `dp_frontend_v2`). GitHub: `hamzaadevops/Documentations`, `hamzaadevops/Claude-Setup`. Pipeline deployment environments: `aws-production`, `aws-prod-surfcity`, Staging. Variables snapshots: `Documents/vars_*.json` (sensitive).
`website_frontend/bitbucket-pipelines.yml` also holds dead branches `nissan-surf-city`, `nissan-crona`, `nissan-san-bernardino`, `security-workings`: ignore.

## 6. SSH hosts (`~/.ssh/config`)
`combined` 137.184.45.248 and `prod` 143.198.144.174 (legacy DO, root); `dealerpulse` 146.190.132.236 (root, key `~/.ssh/digitalocean`); `node_vpn`/`kuma`/`wg-ui` 44.225.91.181 (ubuntu, key `~/.ssh/team-vpn`); `vpn-box`/`kuma-vpn`/`wg-ui-vpn` 10.8.0.1 (use these while connected to the VPN). Nodes/integration: **no SSH, SSM only**.

## 7. Third parties
OpenRouter (chatbot LLM), HomeNet (inventory SOAP + image CDN `content.homenetiol.com`), JD Power (rebates), VinSolutions/Cox (leads), xtime, Capital One / Dealer700 / DSS (financing IDs), Podium (reviews sync every 2 h at :15, not yet connected), Slack/Chatbot, Bitbucket, Cloudflare, Hostinger (DealerPulse DNS). DealerPulse adds Twilio, Retell, Wassenger, AssemblyAI, Cox Automotive, S3, SMTP.

## 8. People `[doc]`
Hamza (DevOps, owner of this account). Mudassar (addressee of `DealerPulse/SMS_ISSUE_MUDASSAR.md`). Ghulam Ali (was given the proposed frontend ChunkLoadError handler; role not stated). A CTO and a senior backend dev receive the user's relayed findings. Roles beyond that are not recorded; ask.

## 9. Local machine layout
`Documents\Documentations` (docs, git -> `hamzaadevops/Documentations`), `Documents\Claude-Setup` (this pack), repos `ocean`, `website_frontend`, `integrations_service`, `chat_back`, `framework_frontend`, `dp_backend_v2`, `dp_frontend_v2`, `starfish`. Scripts/artefacts in `Documents\`: `deploy_sh_*`, nginx confs, dumps (`dealerpulse.dump`, `nisan_website.dump`), `AWS_Cost_Report_Sep-Oct_2026.pdf`, `dealerpulse-infra-diagram.html`, `env_list.json`, `vars_*.json`.
