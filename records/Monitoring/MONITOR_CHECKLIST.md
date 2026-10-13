# Uptime Kuma — monitors to add

Tick through this in the UI rather than inventing monitors at 2am. Instance is live on the VPN box; reach it with:

```bash
ssh -i ~/.ssh/team-vpn -L 3001:127.0.0.1:3001 ubuntu@44.225.91.181
# then http://localhost:3001
```

**Global settings first:** set retries to **3** and heartbeat interval to **60s** on everything below unless stated. A single blip must not notify — the 14 September alarm rebuild taught us that a noisy set gets muted wholesale, and then nothing is monitored at all.

---

## Group 1 — Public sites (HTTP(s), accepted status `200-299`)

| Name | URL | Keyword to assert |
|---|---|---|
| PHN — public | `https://www.puentehillsnissan.com/` | `Puente Hills` |
| PHN — internal host | `https://phn.callingyounow.us/` | *(expect 301 — set accepted status `200-399`)* |
| Surf City | `https://surfcity.callingyounow.us/` | `Surf City Nissan` |

**Why the keyword matters more than the status code here:** a frontend built while the backend was unreachable silently bakes in hardcoded fallback branding and still returns a clean `200`. `DEFAULT_SITE_NAME = "Surf City Nissan"` is the tell. Asserting each site contains *its own* dealership name is the only check that catches it.

**Watch for the trap:** because the fallback value *is* "Surf City Nissan", the Surf City monitor cannot distinguish a good build from a fallback build. For that site, assert something unique to its real content instead — a phone number, address, or a model-line block that Puente Hills does not share. Worth doing properly rather than having one monitor that can never fail.

**This group grows with every tenant.** Corona and San Bernardino each need their own row the day they go live.

## Group 2 — APIs and admin surfaces

| Name | URL | Note |
|---|---|---|
| API | `https://api.callingyounow.us/` | Expect `302` — set accepted status `200-399` |
| Admin dashboard | `https://admin.callingyounow.us/` | Integrations VM |
| Chat backend | `https://chat.callingyounow.us/` | Integrations VM |
| Leads backend | `https://leads.callingyounow.us/` | Integrations VM |

The last three all live on the Integrations VM, which is the single point of failure behind all tenants and has been swapping persistently. If all three alert together, suspect the box, not the apps.

**These are worth having even though the ALB has health checks**, because both target groups check `/` with a `200-499` matcher — a node returning 4xx for everything currently reads as healthy. Nothing else is watching for that.

## Group 3 — Certificate expiry

Enable **Certificate Expiry Notification** globally and set the threshold to **21 days**. It applies to every HTTPS monitor above, so no separate entries are needed.

**Why:** the `certbot.timer` renewal path was found on 2026-09-07 to have never actually worked despite appearing correctly configured. It was fixed, but "appears configured" was already the failure mode once. Let's Encrypt certs here run 71–82 days.

## Group 4 — Celery beat heartbeat — **only alongside the single-beat change**

Add a **Push** monitor named `celery-beat-homenet-refresh`, heartbeat interval **9000s (2.5h)**, retries **1**.

Kuma gives you a push URL. The `refresh_homenet_inventory_cache` task should hit it on success. If no heartbeat arrives in 2.5 hours, the scheduler is dead and inventory is about to go stale (TTL is 2h).

**Do not disable `beat` on Node A until this is in place.** That change trades duplicate cron execution for a single point of failure, and this heartbeat is the entire reason that trade is acceptable.

## Group 5 — Deliberately NOT added

**Per-node direct checks.** Useful for telling "one node down" from "site down", but the nodes' security group only accepts ALB traffic, so probes from this box would be blocked. Enabling it needs a production SG change — approval-gated, and against the VPN project's standing "don't touch existing security groups" instruction. Raise it as a request.

---

## Notifications

Add one Slack incoming webhook pointed at **`#aws-alerts-dealerpulse`** — the channel CloudWatch alarms already reach via SNS → AWS Chatbot. One stream people already watch beats a second one they do not.

Apply it as the default notification on every monitor. Enable "resend if down X times" sparingly.

---

## The external layer — still outstanding, still not optional

Everything above runs **inside the same AWS account and region as the things it watches**, so none of it can report a region- or account-level event. Sign up for a free tier (UptimeRobot, Better Stack, Healthchecks.io) and add:

- `https://www.puentehillsnissan.com/`
- `https://surfcity.callingyounow.us/`
- `https://api.callingyounow.us/`
- `https://admin.callingyounow.us/`
- **The VPN box itself** — a TCP check on `44.225.91.181:51820`, so you find out when the monitor *and* the team VPN are down

5-minute interval is fine on a free tier. This is the layer that makes the self-hosted one trustworthy.
