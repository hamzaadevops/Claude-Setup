---
name: project-dealerpulse
description: "DealerPulse — separate newer project on a shared DigitalOcean droplet; host details, what else lives on that box, and the critical exposed-Postgres finding"
metadata: 
  node_type: memory
  type: project
  originSessionId: 7d64f915-de6f-4d6a-b53f-be89183a7c23
  modified: 2026-09-17T18:22:58.856Z
---

**DealerPulse is a separate, newer project from Dealerships** — see
[[project-naming-dealerships-vs-dealerpulse]]. Full inspected architecture lives
in `Documentations/DealerPulse/ARCHITECTURE.md`; the ask sent to the backend team
is `Documentations/DealerPulse/ASK_SENIOR_DEV.md`.

**Host** (verified 2026-09-17 by `ssh dealerpulse`, already in `~/.ssh/config`):
DigitalOcean droplet `146.190.132.236`, private `10.124.0.3`, **hostname
`Surfcity-Live`**, 2 vCPU / 8 GB / 90 GB, $54.60/mo, no swap, 202-day uptime.
`app.dealerpulse.cloud` (frontend `:8014`) and `app.backend.dealerpulse.cloud`
(backend `:8004`) both resolve to it. DNS is at **Hostinger**
(`ns1/ns2.dns-parking.com`), 4-hour TTL, **no Cloudflare/CDN/WAF in front**.

**That droplet is not only DealerPulse.** It also runs the complete
`callingyounow` product (owner unknown) plus four dead v1 per-tenant deployments
(corona, snb, puentehills, surfcity) whose static frontends still serve but whose
backends on `:8010/:8020/:8030` are gone. 15 Let's Encrypt certs on the box.

**The database is NOT on the droplet.** DealerPulse uses a **DigitalOcean Managed
Postgres** cluster: `dp2-live-do-user-13151402-0.g.db.ondigitalocean.com`
(`143.244.183.125`) port **25060**, database `defaultdb`, user **`doadmin`** (the
cluster superuser), `sslmode=require`. So droplet snapshots are *not* a backup of
app data. 🔴 **Trusted Sources is not enabled on the cluster** — verified
reachable by TCP from an unrelated machine. Fix = enable Trusted Sources (fast,
DO panel) + stop using `doadmin` (slower, app change). **Not done, needs
approval.** This outranks the load-balancer request.

The droplet *also* runs its own unused Postgres 16.9 on `0.0.0.0:5432` with ufw
open to the world, but its `pg_hba.conf` restricts auth to localhost,
`3.43.243.0/30`, and a stale WrenAI setup — so it is *not* "one password from the
internet". Still worth closing; blocked on identifying `3.43.243.0/30`.

**Why they actually want a load balancer:** nginx hardcodes `proxy_pass
127.0.0.1:8004`, only `web_blue` runs, and the colour is switched by hand-editing
the vhost. It is a deploy-safety problem, not a capacity one. An nginx `upstream`
block fixes it on-host; a DO managed LB cannot reach loopback-bound ports.

**Repos:** `bitbucket.org/nxpt/backend_v2.1` → `Documents/dp_backend_v2`;
`bitbucket.org/nxpt/dp_frontend_v2` → `Documents/dp_frontend_v2`.

**Third parties are ~9, not the 3 in their doc:** Twilio, Retell (4 agent IDs),
XTime, Wassenger (WhatsApp), OpenRouter, AssemblyAI, Cox Automotive, AWS S3,
SMTP — plus `vapi.py`/`tony.py` in settings.

**Note:** reading `/opt/dealerpulse/backend/.env` on the droplet is blocked by the
tooling classifier ("Production Reads"). Use the repo's `env.example` for
structure — see [[feedback-credential-creation-blocked]].
