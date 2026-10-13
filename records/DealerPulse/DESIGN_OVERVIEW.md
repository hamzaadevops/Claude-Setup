# DealerPulse — system design overview

A high-level map of what the system is and how the pieces connect. Everything
here was verified against the running environment and the source on 2026-09-17.

Detail lives elsewhere and is not repeated here:
`ARCHITECTURE.md` (full inventory and findings) ·
`INCIDENT_2026-09-16.md` · `PRE_MOVE_CHECKLIST.md`

---

## 1. What it is

DealerPulse is a **multi-tenant service-appointment platform for car
dealerships**. An AI voice agent answers and places calls, books service
appointments into the dealership's DMS, and chases confirmations, reminders and
no-shows over voice, SMS and WhatsApp. Dealership staff watch and manage it all
from a web dashboard.

**Tenancy is real and already modelled.** `Company` is the tenant. Bots, phone
numbers, office hours, booking schedules, holidays and DMS dealer IDs all hang
off it in a shared database. Adding a dealership is data, not a deployment.

**Everything runs on one server.** Frontend, backend, background workers and
cache are containers on a single DigitalOcean droplet (2 vCPU / 8 GB). The
database is the one piece that lives outside it.

---

## 2. The system in one picture

```
                        ┌──────────────────────────────┐
   dealership staff ───►│  app.dealerpulse.cloud       │  React SPA
                        └──────────────┬───────────────┘
                                       │  REST + WebSocket
                                       ▼
   ════════════════ ONE DROPLET · 146.190.132.236 · 2 vCPU / 8 GB ════════════
   ║                                                                         ║
   ║   nginx :443  ── TLS, the only front door ──┬─────────────┐             ║
   ║                                             │             │             ║
   ║                      ┌──────────────────────▼──┐   ┌──────▼──────────┐  ║
   ║                      │ BACKEND  (blue/green)   │   │ FRONTEND        │  ║
   ║                      │ Django + Daphne (ASGI)  │   │ static SPA      │  ║
   ║                      │ HTTP API + 4 WS routes  │   │ :8014           │  ║
   ║                      │ :8004 / :8006           │   └─────────────────┘  ║
   ║                      └───┬─────────────────┬───┘                        ║
   ║                          │                 │                            ║
   ║             ┌────────────▼───┐    ┌────────▼─────────┐                  ║
   ║             │ Redis          │◄───┤ Celery worker    │                  ║
   ║             │ broker + WS    │    │ Celery beat      │                  ║
   ║             │ channel layer  │    │ (7 scheduled     │                  ║
   ║             └────────────────┘    │  jobs)           │                  ║
   ║                                   └──────────────────┘                  ║
   ║             media/ on host disk — call recordings, uploads              ║
   ════════════════════════════════════════════════════════════════════════════
                    │                              │
                    ▼                              ▼
       ┌────────────────────────┐    ┌──────────────────────────────────┐
       │ DO Managed PostgreSQL  │    │  THIRD PARTIES                   │
       │ :25060 · off-droplet   │    │  Twilio · Retell · XTime · Cox   │
       │ single shared database │    │  Wassenger · OpenRouter          │
       └────────────────────────┘    │  AssemblyAI · SMTP               │
                                     └──────────────────────────────────┘
```

---

## 3. Services

| Service | What it is | Where |
|---|---|---|
| **nginx** | TLS termination, routing, serves `/media/`. Only public entry point | host package |
| **frontend** | React/Vite SPA, built to static, served by nginx in-container | container `:8014` |
| **backend (web)** | Django on Daphne — REST API **and** WebSockets in one process | containers `:8004` / `:8006` |
| **worker** | Celery — outbound calls, SMS, WhatsApp, transcription, analysis | container |
| **beat** | Celery scheduler — 7 recurring jobs. **Must never run twice** | container |
| **redis** | Celery broker/results **and** the WebSocket channel layer | container |
| **PostgreSQL** | The only durable store. DO Managed cluster | **off-droplet** |
| **media volume** | Call recordings (7-day cache) + user uploads (permanent) | host disk |

Two colours of the backend exist, blue and green. Only one serves at a time —
the other exists so a release can be swapped without downtime.

**Redis being the channel layer is why the backend can scale horizontally.** Any
backend instance can push a WebSocket event raised by any other, so no sticky
sessions are needed.

---

## 4. Third-party integrations

| Service | Used for | Direction | If it's down |
|---|---|---|---|
| **Twilio** | Phone numbers, SMS, WhatsApp, call recordings | both | No calls in or out; no texts |
| **Retell** | The AI voice agents (5 configured) | both | Voice agent dead |
| **XTime** (Cox) | Writing service appointments to the DMS | outbound | **Bookings fail** |
| **Cox Automotive** | Dealership/inventory data | outbound | Degraded lookups |
| **Wassenger** | WhatsApp gateway | both | No WhatsApp |
| **OpenRouter** | LLM for call analysis | outbound | Analysis stops |
| **AssemblyAI** | Call transcription | outbound | No transcripts |
| **SMTP** | Notification email | outbound | No email |

Retell and Twilio **call into us** on unauthenticated webhook endpoints. XTime,
Cox, OpenRouter and AssemblyAI are things **we call out to**.

---

## 5. The three flows that matter

### A. Inbound call → booking (the critical path)

```
customer dials Twilio number
   └─► Twilio hands the call to a Retell agent
         └─► Retell POSTs inbound-dynamic-variables-webhook   ◄── LIVE CALL,
               └─► we look up the customer + appointment          CALLER WAITING
               └─► we return the agent's context
         └─► agent talks, and to book calls XTime synchronously
         └─► at hang-up Retell POSTs log-call-webhook
               └─► call stored, recording fetched from Twilio on demand
               └─► dashboard updated over WebSocket
```

**This path has a human waiting on the line.** Anything slow here is silence in
the caller's ear; anything failing stalls the agent mid-call. It is the strictest
latency constraint in the system and it runs through the same 2 vCPU as
everything else.

### B. Scheduled outbound

`beat` fires on a timer → `worker` picks it up → Retell places a call, or Twilio
sends an SMS, or Wassenger sends a WhatsApp:

| every minute | appointment confirmations |
|---|---|
| every 5 min | appointment reminders |
| every 10 min | no-show recovery, attendance prompts |
| hourly | BDC reports |
| nightly | recording cleanup, call analysis backfill |

If `beat` stops, all of it stops **silently** — the site stays up and looks
healthy while no customer is contacted.

### C. Staff dashboard

Browser loads the SPA → REST calls for data → a WebSocket stays open for live
call and notification events.

---

## 6. How releases work

Push to `main` → Bitbucket Pipelines builds the image → pushes to Docker Hub →
SSHes into the droplet → starts the **other** colour → waits up to 150s for it
to report healthy → repoints nginx at it → stops the old colour.

If the new colour never goes healthy, it is stopped and the old one keeps
serving. There is **no automatic rollback after** the switch.

A `staging` branch deploys the same way to `dp2.back.fluten.xyz`, on a different
server running Apache.

---

## 7. Where the design is strong

- **Multi-tenancy is genuine.** New dealerships are configuration, not
  infrastructure.
- **Blue/green works** and has a safe failure path.
- **Redis as channel layer** means the backend can be scaled to several
  instances without sticky sessions — the hard part of scaling ASGI is already
  solved.
- **The database is already off the server**, so moving or resizing the
  application does not move the data.
- **Call recordings self-expire** after 7 days and can be re-fetched from
  Twilio, so the storage footprint stays flat.

## 8. Where it will not scale as-is

Stated plainly, in the order they will hurt:

1. **Everything is one server.** One droplet is a single point of failure for
   every dealership at once. Nothing fails over.
2. **The latency-critical voice path shares 2 vCPU** with the dashboard,
   background workers and deploys.
3. **Nothing is watching.** No alerting, no uptime check, no metrics retained,
   and container logs are destroyed on every deploy — the last outage is already
   un-diagnosable.
4. **Integration credentials are global, not per-tenant.** One Twilio account and
   one XTime API credential serve every dealership, so one customer's rate limit
   or suspension is everyone's.
5. **`beat` is a single point of failure with no restart policy**, and its
   failure is invisible.
6. **The database is reachable from the whole internet** and the application
   connects as the cluster superuser.

Items 1–3 are what "enterprise-ready" means before anything else. Item 6 is the
one that should be fixed this week regardless of any other plan.
