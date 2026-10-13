# CLAUDE.md — standing rules for any Claude agent (single source of truth)

This pack (`Documents\Claude-Setup`, repo `hamzaadevops/Claude-Setup`) is the **single source of truth** for how to work in this
account. It is loaded by `Documents\CLAUDE.md`, which imports this file. If a Claude memory note, an old doc or a chat message
disagrees with this pack, say so and ask; when something is confirmed, update the pack.

## 0. How to use the pack (read in this order)
1. This file: rules that always apply.
2. `INTENT_ROUTER.md`: maps the user's words to the right action, check and approval requirement. **Start here for any request.**
3. `STATUS.md`: open / closed / unknown right now. `INVENTORY.md`: IDs, hosts, ports. `RUNBOOKS.md`: procedures.
4. `INCIDENTS.md`: symptom -> cause -> fix history. `DEALERPULSE.md`: the separate project. `CONTEXT.md`: narrative overview and timeline.
5. Deep detail lives outside the pack in `Documents\Documentations\` (`HANDOVER.md`, `Migration/MIGRATION_HISTORY.md`,
   `Migration/COMMAND_LOG.md`, `TODO.md`, `DealerPulse/`, `Monitoring/`, `TeamVPN/`). `memory-export/` is the old Claude memory (reference copy).

Maintenance: when you learn or change a fact, update the matching file here in the same session, with date and provenance.
Everything in the pack is `[doc]` until you verify it live. Paths below starting `Migration/` mean `Documents\Documentations\Migration\`.

## 1. Two different projects — never mix them
- **Dealerships** = the multi-tenant Nissan dealership platform, migrated DigitalOcean -> AWS (Aug–Sep 2026).
- **DealerPulse** = a separate, newer project on a DigitalOcean droplet (`146.190.132.236`).
- Every AWS resource of **Dealerships** is still literally named `dealerpulse-*`. **Never rename
  anything.** Renaming breaks production (target groups, IAM roles, S3 buckets, log groups,
  `/opt/dealerpulse/*`, the `Project=dealerpulse` tag that DLM snapshots depend on, a Postgres DB name).
- When someone says "DealerPulse", work out which one is meant before acting.
- `Migration/COMMAND_LOG.md` is a verbatim record of executed commands. Never "correct" it.

## 2. Verify before you state
- Do not present an inference as fact. Run the command / read the file / resolve the DNS first.
- Label provenance: `[verified]` (you checked it now), `[doc]` (a file says so), `[told]` (the user said so),
  `[assumed]`. If a check is blocked, report the gap instead of inferring around it.
- If you were wrong, correct it plainly and immediately. The user relays your reports to a CTO and a
  senior developer; a confident wrong statement costs real credibility.

## 3. Approval gates (production)
- **Never change anything on the production VMs without asking first, every time**: nodeA
  `i-061291ea974c4ea1b`, nodeB `i-0c982c44f93bfbc0a`, integration `i-03efb82c808863f84`.
  Writes, installs, purges, restarts, stops, and any IAM / ALB / security-group change need an explicit
  yes. A broad instruction ("fix it", "delete X") is not a licence to act fleet-wide: propose the narrowest
  version, name the exact hosts and commands, wait.
- Read-only diagnostics (ps, free, df, docker stats, log reads, CloudWatch queries) need no approval.
- **Do not edit `TODO.md` without discussing first.** Propose the item (what, why, estimate), wait for a yes.
- Do not log in to or probe the DealerPulse droplet without asking.

## 4. Logging requirement (standing, proactive)
- Every AWS CLI command that creates/changes/destroys something is appended to
  `Migration/COMMAND_LOG.md` (exact command + resulting resource ID).
- Every substantive session gets a narrative entry in `Migration/MIGRATION_HISTORY.md`
  (rationale, errors hit, decisions) — not just raw commands. There is no Terraform/CDK state file;
  these two files ARE the record of what exists and why. Do it without being asked.

## 5. Tooling gotchas (cost time before)
- Claude Code's auto-mode classifier blocks whole categories regardless of consent: creating
  credentials/tokens, writes to shared resources (even a mocked "purge" string), and remote installs.
  After the first denial **do not retry or reword**. Hand the step to the user or restructure to a
  read-only equivalent.
- `aws ssm send-command` with `$(...)` inline in the local shell gets expanded locally and silently sends
  wrong values. Write the commands to a JSON file and use `--parameters file://...`.
- AWS CLI on this Windows laptop: `C:\Users\Hamza DevOps\AppData\Local\Programs\Amazon\AWSCLIV2\aws.exe`
  (use the full path in tool shells that did not inherit PATH). Update the path on the new laptop.
- Nodes are reached by **SSM only** (no SSH keys, no open port 22).
- A new `.env` variable needs `docker compose up -d --no-deps`, never a plain `restart`.
- Cloudflare strips cookies, so ALB stickiness must stay OFF.
- Do not retune CloudWatch alarms to silence noise; the latency alarm correctly reports real incidents.
- Timezone `Asia/Karachi` in Django is a deliberate, closed decision. Do not re-raise it.
- Slow browsing on the rented RDP box is CPU starvation, not network. Do not re-diagnose.
