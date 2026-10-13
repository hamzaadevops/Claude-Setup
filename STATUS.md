# STATUS — what is open, decided, and unknown (living file)

**Last full refresh: 2026-10-13, from documents only. No live system was queried.** Newest source entry is
`MIGRATION_HISTORY.md` 2026-10-06 and `HANDOVER.md` (2026-10-12). `TODO.md` itself was last edited 2026-09-17.
When you verify or change anything, edit this file and add the date. Keep one line per item.
Do not edit `Documentations/TODO.md` without discussing with the user.

## 1. Open items (priority order, as best the docs allow)
| # | Item | Last known state | Needs |
|---|---|---|---|
| 1 | DealerPulse managed Postgres: Trusted Sources off, app uses `doadmin` | Open since 2026-09-17, re-confirmed 09-22 | User approval; DO panel |
| 2 | Integration VM memory: `chat_back` workers 4 vs 2 | Fix `3ed8deb` is on `origin/main-migrated` [verified 2026-10-13]; whether deployed to integration is unknown | Verify `--workers` on the container; deploy needs approval |
| 3 | Memory + swap alarms (integration swap had **no alarm**) | Not built (TODO 1, 20 min, API only) | Approval to create alarms |
| 4 | **Alarm on 428 rate / SSR success** (blind spot from the 10-01 incident) | Not built | Approval |
| 5 | Code fix for `apiCrypto.ts` null-session caching + deploy ordering | Not done | Frontend dev |
| 6 | HomeNet cache stampede (TODO 11) and Next image optimizer (TODO 12) | Not deployed as of 09-21 | Dev + deploy |
| 7 | Legacy `.htm` URLs hitting SSR, worst 350 s (TODO 3a) | Message to frontend dev drafted | Dev + deploy |
| 8 | Real health endpoint; only then matcher `200` | Blocked | Dev |
| 9 | Corona: **migrated** [told by user 2026-10-13, written as "12th Agust"; date unverified, probably 12 Oct]. San Bernardino: set `NEXT_PUBLIC_IMAGE_ALLOWED_DOMAINS` / `NEXT_PUBLIC_SITE_URL`, cut domain to the ALB URL | Corona: verify live (DNS, cert, vhost, Kuma monitor). SB: containers running, cutover pending (HANDOVER §1, older than the Corona news) | Domains + DNS owners |
| 10 | Surf City placeholder vendor IDs (Capital One, Dealer700, DSS href) | Open, real-money risk if financing goes live | Vendor IDs from business |
| 11 | Cox/xtime allowlisting of new hostnames; CF country rule may block vendor callbacks | Unconfirmed, oldest blocker | Vendor contact |
| 12 | Django `LOGGING` / Sentry | Not done | Dev |
| 13 | Duplicate Celery beat on both nodes (P4) | Open | Dev/approval |
| 14 | One failed e-Price lead (VinSolutions 422) | 10-05 | Investigate |
| 15 | integration reboot + resize window; VPN box IAM profile; nginx hygiene; cleanup (TODO 6-10) | Open | Approval / window |
| 16 | `dealerpulse-nginx-fd-exhaustion` alarm (deleted once; metric filter survived) | Verify exists | Approval |
| 17 | External uptime checker (Kuma runs in the same account/region it watches) | "Not yet confirmed done" | Decision |
| 18 | HSTS never ramped beyond 300 s | Deliberate, revisit | Decision |
| 19 | Reverted `page=null` fix (`0ce4a55` -> `9a0ee99`), ~11,600 req/day wasted | Not reapplied | Dev decision |
| 20 | VPN throughput bottleneck (t4g.micro) / RDP box too small | Documented | Spend decision |
| 21 | Podium reviews sync wired but no dealership connected | 10-05 | Business |

## 2. Decided / closed (do not re-raise)
TIME_ZONE `Asia/Karachi` stays. Redis stays per-node. ALB stickiness stays off. No revert pipeline for Puente Hills. Graviton dropped (10-06).
Terraform not used. Country allow-list US/CA/PK/JP is a risk-accepted decision. Latency alarm not to be retuned. Resource names not to be renamed.
`min_tls_version` 1.2 done (user: fix breakages after the fact).

## 3. Known conflicts between documents (resolve live, then fix the loser)
- ALB weights: HANDOVER 50/50 vs TENANTS and ONBOARDING 35/65.
- `ONBOARDING.md` (09-17) says Corona and SB had "zero infrastructure"; HANDOVER (10-12) says both running.
- HANDOVER lists 7 alarms; TENANTS notes the fd-exhaustion alarm was deleted. Count live.
- Puente Hills pipeline "atomic deploy" was merged but unexercised at 09-17; later history implies it ran. Confirm.

## 4. Unknowns (ask, do not assume)
Real production hostnames and DNS owners for Corona, SB, Surf City. What `NEXT_PUBLIC_DSS_REGISTERED_HREF` is for. Whether `is_multiple` grouping is intended.
Owner of the `callingyounow` product on the DealerPulse droplet and of `3.43.243.0/30`. Who deleted the fd alarm. Whether the user's company wants the old
laptop's credentials rotated. Whether `Claude-Setup` and `Documentations` GitHub repos are private.

## 5. Security notes
- `Documentations/` tracks `backend.env`, `chat_backend.env`, `frontend.env`, `leads_backend.env` in git (history since commits `c29d354`, `8dbd22c`) and is pushed to GitHub. Contents not inspected. Rotate if live, and purge history.
- `Claude-Setup/memory-export/` contains AWS access-key **IDs** and account details. Keep the repo private.
- `Documents/` holds `vars_*.json`, `env_list.json`, dumps, `.rdp` files; do not commit.
- Credentials never live in this pack. Cloudflare/Bitbucket tokens are supplied per session.

## 6. Refresh checklist (run on the new laptop, update this file)
`aws sts get-caller-identity` -> instances/types -> alarms (count + states) -> ALB weights -> target health -> `docker ps`/`free -m` on 3 VMs ->
428 canary -> chat_back workers -> cert expiry -> repo HEADs on origin -> DO Trusted Sources TCP test. Commands in `RUNBOOKS.md` §3, `HANDOVER.md` §7.
