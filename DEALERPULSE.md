# DEALERPULSE — the separate product on DigitalOcean (summary)

**Full operations reference: `knowledge/DEALERPULSE_OPS.md`.** It covers architecture, deploy, incidents I-1..I-14, health checks, risks and unknowns,
with citations. Source documents: `records/DealerPulse/`. Skill: `dealerpulse-digitalocean`.

Not the AWS-migrated Dealerships platform, and not migrated by us. **Ask before logging in to or probing the droplet.** Changes need approval and
usually the backend team (Mudassar is the named contact on the SMS issue).

## In one screen `[doc, last observed 2026-09-22]`
- **Host:** droplet `146.190.132.236`, hostname `Surfcity-Live`, sfo3, 2 vCPU / 8 GB, no swap. SSH alias `dealerpulse`.
- **Apps:** `app.dealerpulse.cloud` (frontend :8014) and `app.backend.dealerpulse.cloud` (daphne :8004 blue / :8006 green). Celery worker and beat; Redis.
  The unrelated `callingyounow` product shares the box. DNS at Hostinger, no CDN.
- **Database:** DO Managed Postgres `dp2-live` (:25060, `defaultdb`, user `doadmin`), 1 node. Trusted Sources off and `doadmin` used by the app (known;
  left as-is by user decision 2026-10-13, see `STATUS.md` §3). Droplet snapshots don't cover app data.
- **Deploy:** backend `main` → Docker Hub → automatic blue/green with a health gate; frontend `main` → plain recreate. Staging is on the legacy `combined` droplet.
- **Health:** `/health/ready/` and `/health/live/` should both return 204. The homepage is not proof. Kuma has DealerPulse monitors.
- **Known issues:**
  - Thread pile-up on DB waits (2026-09-16, prevention not shipped).
  - Staff SMS failing (`TWILIO_FROM_NUMBER`).
  - Retell key missing (state unknown).
  - Transcripts and unbooked follow-ups switched off in code.
  - nginx 1 MB upload limit.
  - Unauthenticated webhooks.
  - Celery worker and beat with no restart policy.

## Name traps
- "DealerPulse" also prefixes every Dealerships AWS resource.
- "Surf City" is also a Dealerships tenant and a dead v1 site.
- `Documents/dealerpulse.dump` and `Documents/dealerpulse-infra-diagram.html` belong to **Dealerships**, not this product.
- The 2026-10-02 OpenRouter outage was the **Dealerships** chatbot.

## Provenance
Keep `[verified]` / `[told]` / `[doc]` / `[assumed]`. Earlier wrong claims about this host came from skipping verification:
- that the blue/green switch is manual (it's automated);
- that the droplet's own Postgres is the prod DB (it isn't);
- that the 09-16 outage was an nginx timeout (it was DB waits).
