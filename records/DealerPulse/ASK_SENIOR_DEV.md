# DealerPulse — what infrastructure needs from the backend team

Follow-up to the load balancer handover doc.

---

## First, the LB doc is good

It answers "how do I put a proxy in front of this backend" properly — WebSocket
upgrade, the real health endpoint and its limits, drain timing, trailing slashes,
the webhook latency constraint. That level of detail is unusual to get and it
saves us a week of discovery. Thank you.

It is scoped to one thing, though: the proxy in front of one service. The
decisions in front of us are bigger than that — whether DealerPulse gets a load
balancer on DigitalOcean, or moves to AWS, and what monitoring it gets either
way. Those need a layer of information above the proxy. Hence the two asks below.

---

## Ask 1 — A system architecture document

One document, kept in the backend repo so it travels with the code and can be
updated by whoever changes the thing it describes. Compact is fine — high
overview, not exhaustive. What matters is that it is complete at the level of
"which boxes exist and what talks to what", because that is what a migration
plan and a monitoring plan are both built from.

Suggested contents, in the order that is most useful to us:

**1. Service inventory.** Every deployable unit in DealerPulse: name, language
and framework, what it is for, which repo, which container/image. Including the
frontend(s), any admin or internal tooling, and anything that runs on a schedule.
If a service exists but nobody has touched it in a year, say so — that is useful.

**2. The topology diagram.** Which host each service runs on, which ports, which
are public and which are internal. If several services share a droplet, show that
— shared hosts are where our capacity and blast-radius problems come from.

**3. Service-to-service calls.** For each pair that talks: direction, protocol,
whether it is over a public address or a private one, and whether the caller
degrades gracefully or fails hard when the callee is down. Synchronous calls
inside a request path are the ones we most need flagged — the LB doc already
names XTime as one, and we would expect there are others.

**4. Datastores.** Every Postgres, Redis, queue, object store or file volume:
which service owns it, whether it is a managed service or a container, version,
rough size, and whether anything else shares it. Please be explicit about which
data is on a host disk rather than in a database — that is what gets lost in a
migration.

**5. Third-party APIs — the part we most need.** We know about Twilio, Retell
and XTime from the LB doc. Please list all of them, and for each:

  - what it is used for, and what breaks for a customer if it is unavailable
  - direction: do we call them, do they call us, or both
  - which service holds the credentials, and whose account it is
  - whether there is a sandbox/test tenant or only production
  - any rate limits, quotas or IP allowlists that exist on their side
  - whether anything is pinned to our current IP address

That last point is the one that quietly breaks migrations. If any provider has
our current egress IP on an allowlist, moving the box breaks it silently and we
find out from a customer.

**6. Async and scheduled work.** What Celery beat actually runs, at what
frequency, and what the customer-visible consequence is when it stops. The LB
doc lists confirmation texts, reminder calls, Tony recovery and the hourly BDC
report — that list, with schedules, is exactly right.

**7. Environments.** Is there a staging environment, or is production the only
one. How code reaches production today — pipeline, manual deploy, or both.

**8. Known gaps.** §9 of the LB doc is the model here. The things you already
know are wrong and would tell a new engineer on day one.

We are not asking for anything to be built for this document. If the honest
answer to a section is "we don't know" or "it was set up before my time", write
that — a documented unknown is more useful to us than a plausible guess, because
we plan around it instead of discovering it during a cutover.

---

## Ask 2 — Operational handover

Separate from the document. These are the things infrastructure needs in order
to own DealerPulse rather than ask someone every time.

| | What we need |
|---|---|
| **Hosts** | Which droplet(s) DealerPulse runs on, size, region, and what else runs on the same box |
| **Access** | SSH or console access for the platform team, and a DigitalOcean team account with visibility of the project |
| **Code** | Repo URLs and read access for every service in the inventory |
| **Deploy** | How a release reaches production today, and how a rollback is performed |
| **DNS / TLS** | Which registrar and DNS provider hold the zone, where certificates come from, and how they renew |
| **Secrets** | Where environment files live, who holds the canonical copy, and how they are updated — via a secrets channel, please, not chat or email |
| **Backups** | What is backed up, on what schedule, where it lands, and whether a restore has ever been tested |
| **Monitoring** | Anything that exists today — logs, alerts, uptime checks — and which human currently receives them |
| **Traffic** | Rough request volume, peak hours, and how many dealerships are live |
| **Expectations** | How much downtime and how much data loss is acceptable. We would rather be told a number than invent one |

---

## Three things from the LB doc that need an answer before we can plan

**1. The loopback binding decides the whole design.** Both web ports are bound
to `127.0.0.1`, and the doc correctly notes the proxy must therefore live on the
same host. A DigitalOcean managed load balancer does not — it is a separate host,
so those bind addresses have to change and the ports then need firewalling. So:
is the intent nginx on the same droplet, or a managed LB in front of it? They are
different pieces of work and only one of them is a five-minute change.

**2. Blue and green on one droplet is not redundancy.** If the driver here is
availability, it is worth being blunt: two containers on one host still go down
together when the host does. A load balancer in front of a single droplet buys
TLS termination and a health check, not uptime. If the real problem is repeated
outages, the fix is a second host or the migration — so it would help to know
what incident or expectation triggered the urgency.

**3. The migration race is a deploy problem, not a proxy problem.** Both web
services run `migrate` on start, so blue and green cannot come up together. A
load balancer does not solve that — whatever orchestrates deploys has to
serialise it, or migrations move to a one-shot step with `RUN_MIGRATIONS: "0"`
on the web services. Which of those the backend team prefers determines how we
build the deploy path, so we would rather decide it now than discover it.

Two smaller ones we can act on as soon as there is somewhere to act:

- `X-Forwarded-Proto: https` we can send today, but it does nothing until
  `SECURE_PROXY_SSL_HEADER` is set on the Django side. Since webhook signature
  verification is blocked behind it, is there an owner and a rough date?
- The IP allowlist for the Twilio and Retell webhook paths is ours to configure
  and we are happy to. We need the current published ranges and a window to do
  it in, since getting them wrong drops live calls.
