# DealerPulse — what to settle before moving anything

Compiled 2026-09-17. Scope is DealerPulse and its own services only.

Two lists: what we have already established ourselves, and what only the backend
team or the DigitalOcean account can answer. The second list is the one that
should go to them.

---

## A. Already answered — no need to ask

Recorded so nobody wastes a meeting on it.

| Question | Answer |
|---|---|
| Where does the app run? | One DO droplet, `146.190.132.236`, 2 vCPU / 8 GB |
| Where is the database? | **Not on the droplet** — DO Managed Postgres, port 25060, as `doadmin` |
| Is there a staging environment? | Yes — `dp2.back.fluten.xyz` on the `combined` droplet, Apache |
| How do deploys work? | Bitbucket Pipelines → Docker Hub → SSH → blue/green + `sed` on the vhost |
| Is blue/green real? | Yes, automated, with a health gate and a safe failure path |
| What are the media files? | 196 MB; 193 MB is a self-expiring 7-day recording cache |
| Is media on S3? | No — coded but not enabled. Local disk only |
| What runs on a schedule? | Seven Celery beat jobs — see ARCHITECTURE.md §7b |
| Does TLS renew automatically? | Yes, `certbot.timer` active, last run 2026-09-17 10:13 |
| Is SSH password auth open? | No — `PasswordAuthentication no`. `PermitRootLogin yes`, key-only |

---

## B. Ask the backend team

Ordered by what blocks the most work.

### B1. Blocking a migration

**1. Does any third party allowlist `146.190.132.236`?** XTime, Cox Automotive,
Twilio, Retell, Wassenger. This is the one that breaks silently and is only
discovered when a customer cannot book. If any of them do, the new IP has to be
registered before cutover, and some providers take days to action that.

**2. Is `MASTER_ENCRYPTION_KEY` still recoverable, and does it decrypt anything
we would lose?** `SecretManager` (`apps/core/services/secret_manager.py`) uses it
as a Fernet key for the Twilio credentials. Two things make this worth asking
rather than assuming:

- It decrypts **environment values, not database columns**, so losing the key
  means re-fetching Twilio credentials from the Twilio console — recoverable,
  not catastrophic. We want that confirmed, not assumed.
- `SecretManager.get()` **silently falls back to plaintext** when decryption
  fails, so nothing in the app's behaviour tells you whether the values are
  actually encrypted. Someone has to look.

The key exists only in the `.env` on the droplet. It must travel with the app and
must not be regenerated.

**3. Who holds the DigitalOcean account, and can we get access?** Without it we
cannot see the managed database's backup retention, PITR window, metrics or
Trusted Sources — and we cannot enable the last of those.

**4. Who holds the DNS account?** Nameservers are Hostinger's. TTL is 4 hours and
has to come down to ~300s several days before any cutover.

### B2. Blocking the security fixes

**5. What connects to the managed database besides the droplet?** A developer's
laptop, a BI tool, staging? Needed before Trusted Sources is enabled, or we cut
something off.

**6. Does staging point at the production database?** `dp2.back.fluten.xyz` runs
the same image on a shared droplet. If it shares the production cluster, that is
both a data risk and a second thing to add to Trusted Sources.

**7. What is `3.43.243.0/30`?** It has an all-databases, all-users rule in the
droplet's own `pg_hba.conf`. Needed before narrowing that firewall.

### B3. Live problems that need an owner

**8. Were `RETELL_API_KEY` and `OPENROUTER_API_KEY` removed deliberately?** Both
are absent from production right now. Reminder calls and Tony no-show recovery
run every 5 and 10 minutes and place outbound Retell calls, so they are failing
silently. Do not fix this blind — confirm first.

**9. Why is `/api/calls/<id>/get-recording/` returning 502?** 45 times today. The
application raises it when a Twilio recording download does not return 200.

**10. Does Retell retry failed webhooks?** During the 2026-09-16 incident, 479
`log-call-webhook` posts and 171 `inbound-dynamic-variables-webhook` posts were
abandoned by Retell. If there is no retry, those call records are simply lost and
we should know that.

**11. Is there a known cause for the 2026-09-16 20:00–23:00 degradation?** They
deployed twice during it, so someone was reacting to something. They may already
know what it was.

### B4. Worth knowing, not blocking

**12. Are the v1 tenant sites meant to be live?** `surfcity.dealerpulse.cloud`
still resolves and serves a static SPA against a backend that no longer exists.
`/var/www/html` is 3.8 GB of these old builds.

**13. What is the host `redis-server` on `:6379` for?** The stack uses
containerised Redis. Possibly vestigial.

**14. Is `ATOMIC_REQUESTS: True` deliberate?** Combined with synchronous XTime
calls inside booking requests, every slow XTime call holds a database transaction
open for its full duration.

---

## C. What I would check next, on our side

None of these need anyone else, and all are read-only.

1. **Netdata has been running for four months and is already firewalled to
   localhost.** An SSH tunnel to `:19999` may show CPU, memory and per-container
   metrics for the 2026-09-16 incident window — which could answer the root cause
   without DigitalOcean access.
2. **Get logs off the box.** The evidence for the worst of the last incident was
   destroyed by the deploy that followed it. Until logs ship somewhere, every
   incident will be unexplainable after the fact.
3. **Cap the journal.** `SystemMaxUse` is unset and `/var/log/journal` is 4.3 GB.
4. **Measure, then size.** Before any AWS instance type is chosen, we should have
   a fortnight of real CPU and memory data — the same mistake to avoid as on the
   Dealerships migration, where sizing was argued before it was measured.

---

## D. Two fixes ready to go, pending your approval

Both are small, both are on production, neither is urgent enough to do without a
word first.

| | change | risk |
|---|---|---|
| 1 | `client_max_body_size 25m;` in nginx | Nil. Currently the default 1 MB, so uploads above that are failing with 413 today |
| 2 | `proxy_read_timeout 90s;` on `location /` | Low. Currently the 60s default, exactly where the XTime-backed requests time out |

Both need an `nginx -t` and a reload, no container restart, no downtime.
