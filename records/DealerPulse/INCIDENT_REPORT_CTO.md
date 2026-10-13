# Incident report — DealerPulse backend outage

**Date of incident:** Thursday 17 September 2026, 01:00–04:00 PKT
(16 September 20:00–23:00 UTC)
**Duration:** ~3 hours · **Severity:** high — customer-facing, voice path
**Reported:** 18 September · **Status:** resolved, cause partially identified,
**not yet prevented from recurring**

---

## What happened

For about three hours the DealerPulse backend stopped responding to requests. The
servers stayed up and the site looked healthy the whole time — it simply stopped
answering. Incoming requests piled up inside the application until roughly 142
were stuck simultaneously and nothing could get through.

It ended when a deployment replaced the affected container. It did not recover on
its own, and it could not have.

## Customer impact

| | |
|---|---|
| **171 live calls** | the voice agent was waiting on our system while a customer was on the line. The caller heard silence and the call provider gave up |
| **479 call records** | abandoned by the voice provider and, unless it retries, never recorded |
| **Staff dashboards** | 52 failed connections; live updates stopped |
| **Login** | timing out — staff could not sign in |
| **Booking availability** | 20 checks timed out |

The voice path took the worst of it, which is the part customers experience
directly.

## How we found out

**We didn't.** No alert fired, no monitoring flagged it, and nobody reported it at
the time. It happened between 1am and 4am local, and it was found two days later
only because we went looking through server logs during a separate review.

There is currently **no alerting of any kind** on this system — no uptime check,
no error-rate alarm, no notification destination. That is the most significant
finding in this report, above the outage itself.

## Why it happened

**It was not a capacity problem.** The server was almost idle throughout — 8% CPU
on a 2-core machine, memory well within limits, and the traffic at the time was
**one tenth** of the peak the same system had handled without any errors nine
hours earlier.

The application was **waiting** on the database. A database connection stopped
responding, and nothing in our configuration puts a time limit on that wait — not
in the application, not in the database, not in the web server. So each new
request took a worker, waited forever, and never gave it back. Once every worker
was held, the service was effectively down.

**The three-hour duration was self-inflicted.** A well-configured system would
have failed a handful of requests over about thirty seconds and carried on. Ours
had no mechanism to break the deadlock, so it stayed broken until a human
redeployed it.

## What we cannot say, and why

We have confirmed the mechanism precisely. We have **not** confirmed what first
caused the database connection to stall, and we cannot, because nothing recorded
it:

- The database's slow-query logging is **switched off**.
- The database's idle-transaction timeout is **switched off**, so nothing was
  terminated and nothing was logged.
- The application logs request lines only; it recorded no error.
- The affected container's logs were removed when the next deployment recreated
  it.

We verified with DigitalOcean that nothing happened on their side — no
maintenance, no failover, no restart. This was ours.

**This matters more than the individual cause.** As things stand, the next
incident will be equally undiagnosable.

## What we are doing

**This week — stops it lasting three hours again**

| | action | owner |
|---|---|---|
| 1 | Add database timeouts to the application (connect, statement and lock) | backend team |
| 2 | Turn on the database's own query logging and idle-transaction timeout | infrastructure |
| 3 | Add alerting on error rate and on stuck requests | infrastructure |

Item 1 is the one that converts this outage into a brief blip. It is a small,
well-understood configuration change.

**Next — reduces the chance it happens at all**

4. Ship logs off the server so evidence survives deployments.
5. Add a database connection pool; there is none today.
6. Bound the number of concurrent requests so the application sheds load rather
   than accumulating it.

## What we need from you

**1. A decision on who is alerted, and how.** Alerting is quick to build; the
blocker is agreeing who receives it and who is expected to act at 2am. Without
that answer we will build something nobody watches.

**2. Access to the DigitalOcean account.** We are working without visibility of
database metrics, backups and logs. One graph we still cannot see would likely
close out this investigation entirely.

**3. Fifteen minutes with the backend team on item 1.** It is their change, it is
small, and it is the single highest-value fix available.

---

## Also found during the investigation

Separate from the outage, but discovered while investigating it and worth knowing:

**The production database accepts connections from anywhere on the internet.**
DigitalOcean provides a firewall for this ("Trusted Sources") and it is not
configured. The application also connects using the database's top-level
administrator account rather than a restricted one. We can fix the first in
minutes once we know which systems legitimately connect; the second needs a small
application change.

**Two integration keys are missing from production.** Outbound reminder calls and
no-show recovery calls have been failing silently as a result — they run every 5
and 10 minutes. We have not changed anything, as it may have been deliberate, but
it needs an answer.

**Call recording downloads are failing** — around 55 failures on 17 September
alone, and continuing.

**There is no tested recovery.** Backups exist; no restore has ever been
performed. An untested backup is an assumption, not a recovery plan.
