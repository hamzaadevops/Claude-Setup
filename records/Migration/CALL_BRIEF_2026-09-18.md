# Call brief — 12:00am PKT, agenda: AWS consolidation, Datadog, monitoring, access, DO load balancers

Prepared 2026-09-17. Positions below are drawn from `MIGRATION_HISTORY.md`, `COMMAND_LOG.md` and project memory. ⚠️ The AWS CLI session is expired, so nothing here was re-verified live tonight.

---

## Read this first: a naming correction that changes how item 4 should be read

**The project migrated to AWS in September is called `Dealerships`. `DealerPulse` is a separate, newer project.** Every document in this folder has been corrected accordingly. Two things follow from that, and both matter tonight.

**First — do not "correct" anyone on item 4.** An earlier draft of this brief argued that item 4 was based on a false premise, because DealerPulse had already left DigitalOcean. That reasoning applied to Dealerships, not DealerPulse, and it is withdrawn. Walking into the call to correct the CTO on this would have been wrong and would have cost credibility on everything else in the brief.

**Second — the honest position on item 4 is that we know nothing about it.**

> "Digital Ocean server needs LBs at urgent bases for DealerPulse."

There is **no record of DealerPulse anywhere** — not in `MIGRATION_HISTORY.md`, `COMMAND_LOG.md`, the architecture documents, or project memory. We have no idea what it runs on, what its topology is, whether it is one droplet or several, or what is driving the urgency. That is not a gap in the request; it is a gap in what has been shared with us.

So the goal on this item is **discovery, not delivery**. Useful questions:

- What is DealerPulse, and is it live with real users today?
- Which droplet(s) does it run on — is it on `combined` (`137.184.45.248`, ~15 unrelated projects), or somewhere we have never seen?
- What is "urgent" responding to? An outage that already happened, an expected traffic increase, or a launch?
- Who currently owns and deploys it?

**Do not commit to a timeline on this item tonight.** Committing to load-balancer work on infrastructure nobody on our side has ever logged into is how a two-hour job becomes a fortnight.

### The technical point worth making regardless

A load balancer in front of **one** droplet buys TLS termination and a health check. **It does not buy redundancy.** One droplet behind an LB is still one droplet, and it still goes down when that droplet goes down. If the underlying concern is "we keep having outages and need availability urgently," the load balancer is not the fix — a second droplet behind it is, or the migration is. Worth establishing what problem the LB is meant to solve before anyone budgets for it.

### And the conflict between items 1 and 4

Item 1 is "move all production software to AWS." Item 4 is "urgently invest in DigitalOcean infrastructure." Those pull in opposite directions and we would be paying for both — and if DealerPulse is on DigitalOcean, then item 1 presumably covers DealerPulse too, which makes the tension explicit rather than theoretical.

That is still a reasonable thing to do *if* the migration is more than a couple of months out and the outage risk is real in the meantime. But it should be a stated decision with a defined window, not an accident. Ask: **is the DO load balancer a stopgap for a known period, or has the migration timeline slipped?** And: **is DealerPulse in scope for item 1, or is it staying on DigitalOcean?**

---

## Item 1 — Move all production software to AWS

### What we know

- The Dealerships stack is already migrated. Five apps across three EC2 instances, ALB, shared Postgres, ECR, Bitbucket pipelines, CloudWatch Logs, Cloudflare in front.
- What we know remains on DigitalOcean: **~15 unrelated projects on the `combined` droplet**, plus the original `prod` droplet still running the legacy Dealerships stack.
- **Plus DealerPulse**, wherever it lives — see item 4. It is entirely unrecorded on our side, so it may or may not be one of the ~15.
- **We have no inventory of any of it.** No list of what these projects are, what they run on, who owns them, what their data footprint is, or which are actually still in use.

### The one thing to ask for

**A written inventory of everything on that droplet before any timeline is discussed.** Per project: runtime and version, database, domain, traffic, owner, and whether it is actually still in use. In our experience on Dealerships, a meaningful fraction of "production" turns out to be dormant, and knowing that changes the estimate more than anything else.

Without it, any date given on this call is a guess. With it, the work sorts quickly into "lift and shift", "needs rework", and "switch it off instead" — and the third category is usually larger than anyone expects.

### A live footgun worth raising

**The legacy Bitbucket pipelines are still active in all five Dealerships repos.** Pushing to `master`, `main` or `staging` still builds and deploys to the old DigitalOcean droplet over SSH. This was a deliberate decision — they come out when the droplet is decommissioned — but it means the old box is still a live deploy target that anyone can push to by accident. If item 1 moves forward, decommissioning `prod` and removing those pipeline blocks should be an explicit task with an owner, not an assumption.

### Calibration from the Dealerships migration

For honesty about what this costs: Dealerships was five applications and it ran from late August to a 9–10 September cutover, with roughly two further weeks of stabilisation afterwards — cert architecture, CI/CD, cross-node cache bugs, a nginx connection-limit incident, alarm rebuilds, and a significant inventory performance project. It is still not finished. **Fifteen projects will not be three times that effort, but it will not be a fortnight either**, and the honest answer on the call is that it cannot be estimated until the inventory exists.

---

## Item 1b — Datadog

### Current position

**Nothing. No Datadog anywhere in the account.** Monitoring today is CloudWatch: centralised logs under `/dealerpulse/*`, seven alarms, and Container Insights not enabled.

### What Datadog genuinely fixes for us

This is not resistance — Datadog solves several problems we currently have and cannot easily solve with CloudWatch:

- **Per-container metrics out of the box.** The Docker integration gives CPU, memory, restart counts and health per container. Right now we cannot answer "how much CPU is each `website_frontend` container using" without an ad-hoc SSM session, and that question directly blocks the October capacity sizing.
- **It routes around the IAM blocker.** We have had **zero memory metrics on any box** for weeks because `CloudWatchAgentServerPolicy` was never attached to `dealerpulse-ec2-ssm-role`. The Datadog agent does not need that.
- **APM.** Real distributed traces through Django would have found the inventory cache-key bug in an afternoon rather than across several sessions of manual profiling.

### What to raise before committing

1. **Cost, and specifically the shape of it.** Host-based pricing is predictable; log ingestion and custom metrics are where Datadog bills surprise people. With three hosts today it is modest. After migrating ~15 projects it is a different number, and log volume from a chatty Django app is the line item to watch. **Ask for a budget ceiling on the call**, and configure exclusion filters from day one rather than after the first invoice.
2. **Pick one source of truth for alerting.** Running CloudWatch alarms and Datadog monitors in parallel indefinitely produces two half-configured systems and duplicate pages, which is how people learn to ignore alerts. Proposal: Datadog becomes primary, CloudWatch alarms stay only for AWS-native signals that Datadog sees less well (ALB target health, EBS, billing), and we consciously retire the overlap.
3. **A practical constraint on my side, worth stating plainly.** Installing the Datadog agent on the three production VMs is a remote install, which this tooling blocks categorically — and there is a standing rule that nothing changes on those VMs without explicit approval first. So the agent rollout is either **you running the install**, or a permissions change. Not a blocker, but it affects who does what and should not be discovered mid-task.

---

## Item 2 — API-level monitoring of all Docker containers

### Where we actually stand

| | Status |
|---|---|
| Centralised logs | ✅ All services → CloudWatch Logs under `/dealerpulse/*` |
| Alarms | ⚠️ Seven exist, all deliberately loosened on 14 Sep |
| Memory / swap metrics | ❌ **None, on any box** — agent configured, never permitted to publish |
| Per-container metrics | ❌ None |
| APM / tracing | ❌ None |
| nginx error logs → CloudWatch | ❌ Broken since a config wipe; must be read over SSM |
| fd-exhaustion alarm | ❌ Deleted; its metric filter still publishes to nothing |

### The number to bring to this call

On 15 September, post-fix latency was first reported as p99 0.60–3.2 s. **That was wrong — it was queried against a target group that was mid-decommission.** The correct LoadBalancer-dimension query for the same window showed **p99 up to 8.39 s, max up to 24.80 s, and 25 target 5xx.**

The improvement against the 12 September baseline is still real: the 60-second gunicorn-timeout maxima are genuinely gone. But our latency alarm threshold is set at **8 seconds**, which means it is sitting almost exactly on the real p99.

This is the strongest argument for the whole agenda item, and it is worth saying out loud: **our dashboards currently read green partly because the thresholds were set loosely enough to stay green.** That is a deliberate and defensible choice — a noisy alarm set gets muted wholesale and then nothing is monitored — but it is not the same as the system being healthy, and it should not be presented as such.

### What "all bells and whistles on every live software" should mean concretely

Rather than agreeing to an open-ended phrase, propose a definition and get it accepted:

1. Every container exports CPU, memory, restart count and health state.
2. Every service has a real health endpoint — **ours currently do not.** Both target groups health-check `/` with a `200-499` matcher, meaning a node returning 4xx for everything still reads as healthy. That is a no-op health check and it has been carried unchanged into the current topology.
3. Every public endpoint has an uptime check from outside our own infrastructure.
4. APM tracing on the request path for the Django services.
5. Log-based alerts for error patterns, not just metric thresholds.
6. One notification destination that a named human actually watches. `dealerpulse-alerts` currently has exactly one subscriber, a chatbot endpoint.

Point 2 is worth flagging as the cheapest real win on the list.

---

## Item 3 — Access management and fire exit

### Access management: better than people probably assume

Two IAM groups were created on 2026-09-06 and both are scoped to this project only:

- **`developers`** — read-only: CloudWatch Logs scoped to `/dealerpulse/*`, S3 read on the two project buckets.
- **`sr-developers`** — read-write: S3 read/write on those buckets, Logs read/write, and **SSM Session Manager shell access scoped to the three project instances only**.

Session Manager activity is audit-logged to `/dealerpulse/ssm-session-logs` with 90-day retention. So the structure exists and is reasonably scoped.

**The gap is that nobody is in the groups.** A named list of who gets production access has been an open blocker since the original architecture document and is still open. That is a decision for this call, not a technical task — **come away with names**.

Other genuine gaps worth naming:

- No MFA enforcement policy on IAM users.
- No SSO / Identity Center. Fine at this size; it is the right answer once ~15 more projects and their teams arrive, and it is much cheaper to adopt before than after.
- Static long-lived access keys are in use, including a personal one belonging to an IAM user.
- Nothing equivalent exists for the DigitalOcean side at all.

### Fire exit: the honest position

**What exists:**
- DLM daily EBS snapshots, 03:00 UTC, 7-day retention, tag-targeted on `Project=dealerpulse` so new volumes are covered automatically.
- An S3 backups bucket holding retired volume archives and migration dumps.
- A `revert-surfcity` custom pipeline for tag-based redeploy of a previous image without a rebuild.
- The old `dealerpulse-tg-nginx` target group, deliberately kept registered-but-unreferenced as an instant ALB listener rollback.
- Timestamped `.bak` files for every `deploy.sh` and `.env` change.

**What does not exist, and should be said plainly:**

- **No restore has ever been tested.** We take snapshots; we have never restored one. An untested backup is a hypothesis, not a recovery plan. This is the single most valuable thing on this entire agenda and the cheapest to fix — restore one snapshot into a throwaway instance and time it.
- **No documented RTO or RPO.** Nobody has agreed how much downtime or data loss is acceptable, so nobody can say whether the current setup meets it.
- **No runbook and no on-call rotation.** Recovery currently depends on specific people being awake.
- **The Integrations VM is a single point of failure for all four tenants** — it hosts the shared Postgres behind both app nodes, plus chat, leads and the admin dashboard, and it has been swapping persistently for weeks. There is no failover.
- **The old DigitalOcean droplet is no longer a viable rollback target.** It is worth being explicit, because people assume otherwise: production data diverged at the 9–10 September cutover, and everything since then exists only in AWS. Falling back to DO would mean losing two weeks of real customer data.

**Suggested framing for the call:** we have backups, we do not have a tested recovery. Proposed first step is a restore drill on a throwaway instance — no production risk, and it converts an assumption into a measured RTO.

---

## Sequencing — the thing most likely to go unsaid

All four agenda items land in the same window as an existing commitment: **four tenants live on AWS within October, two of them on 5 October.** That work has a written plan (`OCTOBER_CAPACITY_PLAN.md`) and **none of it has started.** Phase 0 alone is blocked on one IAM policy attachment and an `aws login`.

The capacity position in one line: Node A is a `t3.large` already sitting exactly on its burstable CPU baseline with an empty credit bucket, and the plan doubles the number of frontend containers on it.

It is entirely reasonable for the business to want all four agenda items. It is not reasonable for all of them to happen in the same three weeks as the tenant launches, by the same people. **Propose an explicit order rather than letting it be decided by whatever gets asked for most recently:**

1. **Now → 5 Oct:** capacity plan Phase 0–2, then the Corona buildout. Protects a committed launch date.
2. **In parallel, cheap and high value:** the DigitalOcean project inventory (someone else can produce it), a Datadog trial on *one* non-production box, the restore drill, and the named access list.
3. **October, after launch stabilises:** full Datadog rollout, SSR hairpin fix, RDS migration.
4. **November onward:** the ~15-project migration, with a real estimate built from the inventory.

---

## Five things to come away with

1. **What DealerPulse actually is** — where it runs, whether it is live, who owns it, and what is driving the urgency. No commitment on item 4 until that exists. And, if the concern is availability, that one droplet behind a load balancer is still one droplet.
2. **A written inventory of the ~15 DigitalOcean projects**, and whether DealerPulse is among them. No inventory, no timeline.
3. **A budget ceiling for Datadog**, and agreement that it becomes the primary alerting system rather than running two in parallel forever.
4. **Names for the `developers` and `sr-developers` groups**, plus a decision on MFA.
5. **Agreement that the October tenant launches take priority**, and explicit acknowledgement if anything on this agenda is meant to displace them.

## Two asks that unblock work immediately

- Attach `CloudWatchAgentServerPolicy` to `dealerpulse-ec2-ssm-role` — one click, and it ends weeks of having no memory data on any box. Needed whether or not Datadog goes ahead.
- Re-authenticate the AWS CLI session so live verification can resume.
