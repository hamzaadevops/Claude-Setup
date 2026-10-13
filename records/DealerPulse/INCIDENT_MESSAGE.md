# Message to accompany the incident report

Draft for sending to the CTO, senior developer and POC.

---

Sharing the incident report for the DealerPulse outage on the night of 16/17
September. Summary and what I recommend we do about it below.

## What happened

The backend stopped responding for about three hours, 01:00–04:00 PKT on the
17th. It was not down in the usual sense — the servers stayed up and every
dashboard showed green the whole time. It simply stopped answering requests.

**171 live calls** had a customer waiting on the line while our system never
responded, and **479 call records** were abandoned by the voice provider. Staff
login and booking availability were also timing out.

## The cause, in one line

The application was waiting on database connections that had gone silent, and
**nothing anywhere in our stack puts a time limit on that wait** — not the app,
not the database, not nginx. So every incoming request took a worker and never
gave it back, until there were none left.

Two things worth being clear about:

- **It was not a capacity problem.** The server was at 8% CPU and near-zero load
  throughout, handling a tenth of the traffic it had already handled that same
  day without a single error.
- **The three-hour duration was our own doing.** With timeouts configured, this
  would have been about thirty seconds of errors. The only timeout that existed
  anywhere was the operating system's two-hour TCP default, and the outage lasted
  roughly that long.

And we did not detect it. No alert, no monitoring, nobody paged. It was found two
days later by accident. That is the part I would fix first.

---

## 1. Today and this week — the hotfix

**Today, costs nothing, needs no code:**

1. **An external uptime check on the public endpoints**, with a real person
   receiving it. Ten minutes of work. Right now nothing would tell us if this
   happened again tonight.
2. **Raise the upload size limit on nginx.** It is at the 1 MB default while the
   app expects 25 MB, so uploads over 1 MB are failing today, unrelated to the
   outage.

**This week, and this is the actual fix:**

3. **Database timeouts and keepalives in the application config** — a connect
   timeout, a statement timeout, a lock timeout, and TCP keepalives on the
   database connection. This is a handful of lines in the Django settings and it
   is what converts this class of outage from three hours into under a minute.
   It needs the backend team, and it is the single highest-value change
   available to us.
4. **Alerting on error rate and on stuck requests.** The metric that showed this
   incident clearly was worker thread count climbing from 12 to 142. We already
   collect it. Nothing was watching it.
5. **Ship logs off the server.** The logs covering the worst of the incident were
   destroyed by the deployment that fixed it, which is why part of this is still
   unexplained.

**Also this week, separate from the outage but higher risk than it:** our
production database currently accepts connections from anywhere on the internet,
and the application connects using the database's top-level admin account.
DigitalOcean provides a firewall for this and it is not switched on. I can enable
it in minutes — I need to know which systems besides the app server legitimately
connect, so I do not cut something off.

## 2. Should we move to AWS?

My honest position: **yes eventually, no right now, and this incident is not an
argument either way.**

**It is not a reason to migrate.** Nothing about this was DigitalOcean's fault. I
checked their side — no maintenance, no failover, no restart on the day. This was
our application configuration, and it would have happened identically on AWS, on
GCP, or anywhere else. Migrating without fixing the timeouts just moves the same
bug to a more expensive address.

**It is not a reason to stay either.** The real arguments for AWS are unchanged
and still good: the Dealerships stack is already there, so we would have one
account, one set of tooling and one place to look; and RDS Multi-AZ would give us
database failover, which we do not have today — our database is a single node
with no standby, and the database is the component that actually failed.

**The reason not to do it now is sequencing.** Three things:

- We have four tenants committed to go live on AWS in October and that work has
  not started. Adding a second migration to the same window puts both at risk.
- Migrating DealerPulse is not a lift-and-shift. Its DNS sits in a third-party
  account with a four-hour TTL, its media lives on the server's local disk, and
  several integrations may have our current IP address allowlisted on their
  side — that last one breaks silently and is only discovered when a dealership
  cannot book.
- Most importantly: **we should not migrate a system we cannot currently monitor
  or diagnose.** Right now we have no alerting, no log retention, and an outage
  we can only partly explain. If we move it in that state and something goes
  wrong, we will not know whether the migration caused it. Fix the observability
  first and the migration becomes measurable — we would be able to prove it
  improved things.

**What I would propose:** do the fixes above now, on DigitalOcean, because they
are cheap and they are needed on either platform. Revisit the migration after the
October launches are stable, with a proper inventory first. If the answer then is
AWS, we will be migrating a system that is instrumented, understood and quiet —
which is a far smaller job than migrating this one.

## 3. On adding a second server

This came up as a response to the outage and I want to be straight about it: **it
would not have helped.**

A second VM runs the same code with the same missing timeouts against the same
database. It would have hung on the same schedule. And because our health check
opens a database connection, a load balancer would have marked *both* servers
unhealthy and had nowhere to send traffic — possibly reaching total failure
sooner.

There is a real case for a second server, but it is a different one: today a
single host failure takes down every dealership at once. That is worth fixing.
It is just not what happened, and it cannot be done as things stand — media is on
local disk, Redis is on the same box, and the scheduler must never run twice or
customers get duplicate texts and duplicate calls. Those all need solving first.

If the goal is availability for the money, **a database standby node buys more
than a second application server**, because the database is the single point of
failure that actually failed.

## 4. What I need

1. **A decision on who gets alerted and who responds out of hours.** Alerting is
   quick to build; the blocker is agreeing who receives it. Without that we will
   build something nobody watches.
2. **DigitalOcean account access for me.** I am working without sight of database
   metrics, logs and backup settings. One graph I still cannot reach would likely
   close out the remaining unknown in this investigation.
3. **A short session with the backend team** on the timeout configuration. Small
   change, theirs to make, biggest single win available.
4. **An answer on the database firewall** — which systems connect to it besides
   the app server.

Happy to walk through any of it.
