---
name: dealerships-change-control
description: "Mandatory 'know before you change' protocol for the Dealerships AWS platform, Cloudflare, the VPN/Kuma box and the DigitalOcean systems. Use BEFORE any action that writes, restarts, deploys, resizes, deletes, purges, or changes config, env vars, IAM, ALB, security groups, DNS, Cloudflare or pipelines, and whenever the user says fix it, clean up, optimise, upgrade, improve, change, update, remove, or asks about the TODO list."
---

# Change control: know everything before changing anything

The system works and is accepted. The goal is to keep it running with the **fewest possible changes**. The operator may not be a DevOps
engineer, so you carry the responsibility for understanding before acting.

## Step 1 — Know (mandatory, read-only, before proposing anything)
Do all of these, and say that you did:
1. **Architecture:** read the relevant part of `Claude-Setup/ARCHITECTURE.md`, especially §5 Invariants and §6 Accepted trade-offs. If the change
   touches an invariant, stop and explain why it exists.
2. **Topic skill:** load the skill for the area (`dealerships-deploy`, `dealerships-edge-cloudflare`, `dealerships-monitoring`,
   `dealerships-troubleshooting`, `team-vpn-and-uptime`, `dealerpulse-digitalocean`).
3. **History:** `grep -n -i "<service|host|setting|error text>" Claude-Setup/knowledge/*.md Claude-Setup/records/Migration/*.md`, then read the
   hits. The knowledge files list every past issue with its final root cause, the user decisions, and 67+ operational gotchas. Many "obvious fixes" were tried
   before and caused incidents or were deliberately rejected; several early diagnoses were later corrected (use the final version).
4. **Decisions:** check `STATUS.md` §3 Closed decisions. Never reverse a closed decision without the user explicitly reopening it.
5. **Live state:** check the current state read-only (describe/list/get, `docker ps`, config file reads, logs). The docs may be out of date.
6. **Blast radius:** which sites, tenants, services and people are affected if this goes wrong?

If any of steps 1-5 is blocked (no access, classifier denial), say so. Don't propose a change on assumptions.

## Step 2 — Decide whether a change is needed at all
Prefer, in order: no change → a read-only explanation → a reversible configuration change on **one** host → anything bigger.
Never: rename `dealerpulse-*` resources, refactor, upgrade versions, re-architect, "tidy" unrelated things, retune alarms to silence them,
deploy by hand outside the pipeline, edit `records/TODO.md` without discussion.

## Step 3 — Write a change brief (plain language) and wait for "yes"
```
WHAT:      one sentence a non-engineer understands
WHY:       the evidence ([verified] with the output that shows the problem)
HISTORY:   related past incidents/decisions found in step 1 (or "none found")
WHERE:     exact hosts / resources (instance IDs, names)
COMMANDS:  exact commands, in order
RISK:      what could go wrong, which sites/users notice, for how long
ROLLBACK:  exact undo steps
VERIFY:    how we'll know it worked
ESCALATE?: yes if it touches the database, security groups/firewall, DNS, Cloudflare security, deletion, IAM, or DealerPulse
```
Ask for an explicit yes. If ESCALATE is yes, recommend the operator confirms with their escalation contact first (`START_HERE.md` §5).
A general instruction ("fix it", "clean up") is not a yes for a specific command.

## Step 4 — Execute narrowly, verify, record
One host first, then the other, if it's a two-node change (except frontend deploys, which must hit both nodes at once through the pipeline).
Verify with the VERIFY step. Record the change:
- exact command + resulting ID appended to `Claude-Setup/records/Migration/COMMAND_LOG.md` (never edit old entries);
- dated narrative in `MIGRATION_HISTORY.md`;
- the affected `Claude-Setup` file (`INVENTORY.md`, `ARCHITECTURE.md`, `STATUS.md`, `INCIDENTS.md`, or a skill) with `[verified YYYY-MM-DD]`.

## Classifier limits
Claude Code may block credential creation, writes to shared resources (for example a Cloudflare purge), remote installs, and sometimes production
reads. After one denial: stop, don't reword or retry. Give the operator the exact steps to do it themselves (dashboard path or command), or offer a
read-only alternative.
