# DealerPulse — monitoring

Operational source of truth for what is watched and how alerts reach a human.
Build history and setup steps are in `scripts/SETUP.md`.

Last verified **2026-09-22 17:00 UTC**.

---

## Alert routing — all 14 monitors verified

Every monitor is attached to the **Slack Critical Alerts** notification, verified
2026-09-18 after the bindings were repaired.

Five had been created without a notification — Database, Beat, Worker, Backend
Threads and XTime API — meaning they would have gone red and told nobody. Kuma's
"default notification" setting only pre-ticks the box on the *create* form; it
does not retrofit, and it clearly did not apply consistently. **Worth checking
this column after adding any new monitor**, because the failure is invisible:
the monitor looks healthy and functional right up until it needs to alert.

```sql
SELECT m.name, (SELECT COUNT(*) FROM monitor_notification mn
                WHERE mn.monitor_id = m.id) AS slack
FROM monitor m ORDER BY m.id;
```

---

## Where it runs

| | |
|---|---|
| Uptime Kuma | `uptime-kuma:2.5.5` on team-vpn-box `44.225.91.181` (AWS, us-west-2) |
| Why there | Deliberately off DigitalOcean — a DO outage cannot take the monitoring with it |
| Public name | `uptime.callingyounow.us`, proxied via Cloudflare |
| Dashboard | Reachable only from the office IPv4 and IPv6 prefix, plus the SSH tunnel |
| Push endpoint | `/api/push/` — reachable only from the DealerPulse droplet |

Layers protecting it: Cloudflare in front → AWS security group → nginx path and
source-IP rules → the push token itself.

### ⚠️ Access breaks when the office IP rotates

Both SSH to the box and the dashboard are restricted by source IP, and the
office connection is residential — **the address changes on its own**. It
rotated on 2026-09-19 and locked us out of both at once. Monitoring itself was
unaffected; the droplet kept pushing normally.

When it happens, the symptom is SSH timing out and the dashboard returning 403.
Recovery is two steps:

```bash
# 1. current address
curl -s -4 https://ifconfig.me ; curl -s -6 https://ifconfig.me

# 2. allow SSH again (must be run by a human - blocked for Claude)
aws ec2 authorize-security-group-ingress \
  --group-id sg-020165aeddafe5322 --region us-west-2 \
  --ip-permissions 'IpProtocol=tcp,FromPort=22,ToPort=22,IpRanges=[{CidrIp=<NEW_IP>/32}]'
```

Then add the new IPv4 and IPv6 prefix to the `location /` allow list in
`/etc/nginx/sites-available/uptime.callingyounow.us` and reload nginx.

**This is the wrong long-term control.** Either put Cloudflare Access in front
of the dashboard, which authenticates by identity rather than address, or repair
the WireGuard rule (`51820/udp`, still missing from the security group) so the
team connects from one stable VPN address that gets allowlisted once.

---

## What is watched

### HTTP checks (Kuma reaches out)

| Monitor | Target |
|---|---|
| DealerPulse Backend | `app.backend.dealerpulse.cloud/health/ready/` |
| DealerPulse Frontend | `app.dealerpulse.cloud` |
| Puente Hills Nissan, API Nissan, Admin Framework, Chat Backend, Leads Backend | Dealerships stack |

The backend check deliberately targets the API health endpoint, **not** the
homepage — during the outage the homepage kept returning 200 throughout.

### Push checks (the droplet reports in)

Two scripts on the droplet, run by systemd timers, offset so they never collide:

| Timer | Runs | Script |
|---|---|---|
| `check-celery.timer` | `*:*:00` | `/usr/local/bin/check-celery.sh` |
| `check-health.timer` | `*:*:30` | `/usr/local/bin/check-health.sh` |

| Monitor | What it proves | Trips when |
|---|---|---|
| Dealer Pulse Beat | Scheduler is dispatching, not just running | No `Sending due task` in 3m |
| Dealer Pulse Worker | Worker is consuming, not just running | No task activity in 10m |
| DealerPulse Backend Threads | Requests are completing | >30 threads (normal 9–14, outage hit 142) |
| DealerPulse Error Rate | Customers are being served | >10 5xx/499 in one minute |
| DealerPulse Host Resources | Slow-burn capacity | disk >80%, mem <500MB, redis >80% of cap |
| DealerPulse Database | Managed Postgres reachable | TCP 25060 fails |
| DealerPulse XTime API | Booking DMS auth + read | OAuth or services read fails |
| DealerPulse Twilio API | Calls/SMS credentials valid | Account endpoint not 2xx |
| DealerPulse Wassenger | WhatsApp gateway reachable | Devices endpoint not 2xx |

Third-party probes run every 5 minutes (`check-thirdparty.timer`), deliberately
slower than the internal checks because they call somebody else's API.

### Heartbeat sizing — the rule and how it has already been broken twice

**A push monitor's heartbeat must be at least 2× the interval the script sends
at.** Anything tighter and Kuma's window expires at roughly the moment the next
push lands, which produces false DOWN alerts.

Current settings, all compliant:

| Monitor | Sends every | Heartbeat | Ratio |
|---|---|---|---|
| Beat, Threads, Error Rate, Host Resources | 60s | 120s | 2× |
| Worker | 60s | 180s | 3× |
| XTime, Wassenger | 300s | 600s | 2× |
| Twilio | 1800s | 3600s | 2× |

This has caught us out twice, both times the same way:

- **Beat and Worker at 60s/60s** — flapped immediately, fixed to 120s.
- **Twilio at 300s/1800s** — when the probe moved to a 30-minute timer to save
  CPU, the monitor's heartbeat was left at 300s. It alerted DOWN then UP every
  30 minutes for several hours before anyone noticed.

**So: whenever a timer's frequency changes, change the matching heartbeat in the
same breath.** The script and the monitor are two halves of one setting stored
in two different places, which is exactly the kind of thing that drifts.

### ⚠️ A reachable API is not a working integration

Found 2026-09-22, and it is the most important lesson here so far. The Twilio
monitor checks that `/Accounts/{sid}.json` returns 2xx. It did, continuously,
while **every staff SMS had been failing for two weeks** because
`TWILIO_FROM_NUMBER` points at a number the account does not own.

Valid credentials are not the same as messages being delivered. Every probe we
have tests authentication and reachability; none tests an outcome.

The cheap fix for this class of gap is to watch the application's own record of
what it sent. `OutboundMessage` already stores per-message status, so a check
along the lines of "failed:sent ratio over the last hour" catches any delivery
failure regardless of cause — wrong number, suspended account, carrier
rejection — without calling anybody's API.

Worth applying the same reasoning to the others: XTime auth succeeding does not
mean bookings are landing, and a healthy Retell key would not mean calls are
being placed.

### Not monitored, deliberately

| Service | Why |
|---|---|
| AssemblyAI | Account disabled at the provider; decommissioned by the backend team |
| OpenRouter | Key removed; described as unused, though `notify_unbooked_booking_intent` still calls it |
| Retell | Key missing — add a monitor once the backend fix ships |
| SMTP (`mail.spacemail.com:465`) | Reachable and in use, but not yet monitored. A plain TCP Port monitor covers it — no script or token needed |

The probe already covers AssemblyAI, Retell and OpenRouter in code. Each has a
blank push token in `/etc/default/check-thirdparty`, so results are logged but
not sent. Filling in a token is the only step needed once each is fixed — this
keeps permanently-red monitors off the dashboard, which is what trains people to
ignore it.

**Why push rather than pull.** A push monitor is a dead man's switch: the droplet
says "I am alive" and *silence* is the alarm. That covers cases a pull check
cannot — the script breaking, the droplet dying, the network path failing. Every
push monitor uses a 120s heartbeat against a 60s send, so one missed run is
absorbed and a real fault alerts in about three minutes.

**Checking a process is running is not enough.** A wedged Celery process stays
`Running: true` indefinitely — that is precisely what happened on 16 September.
Both scripts therefore read container logs for evidence of recent work.

---

## netdata — collection only, deliberately

netdata runs on the droplet with roughly four months of retention and per-second
resolution. It is **not** used for alerting, by choice: it carries ~290 stock
alarms that are largely noise for this workload, and wiring them up would
recreate alert fatigue.

It stays because it is the best forensic tool available here. The 2026-09-16
investigation was solved with it — thread counts, CPU, network and per-container
metrics for a window whose container logs had already been destroyed.

One custom alarm was added (`/etc/netdata/health.d/dealerpulse.conf`, copy in
`scripts/`) for thread exhaustion. It evaluates but does not notify; the Kuma
push monitor covers the same signal and does.

**Worth knowing:** netdata's own notifications have never worked. Two CRITICAL
alerts fired historically — system CPU at 96.9% for ten minutes on 2026-06-09 —
and both failed to deliver with `sendmail: account default not found`. Five
failed deliveries are logged. The detection was correct every time; the delivery
never existed.

---

## Still open

1. **Attach Slack to the four monitors above.** Highest priority.
2. **Prove it fires.** Stop `beat` for ~3 minutes outside dealership hours and
   confirm Slack arrives. Until then the alerting is unproven. Do not test with
   `worker` — that interrupts tasks in flight.
3. **Nothing watches Kuma.** If that container or the VPN box dies, alerting
   stops silently. It needs one external heartbeat pointed at it.
4. **No on-call.** Alerts reach a channel, not a rota.
5. **Log shipping.** Container logs still die with the container, which is why
   part of the 16 September investigation remains unresolved.
