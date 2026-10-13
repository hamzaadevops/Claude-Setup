# CLAUDE.md — standing rules for any Claude agent (single source of truth)

This pack (`D:\Nexrupt Data\Repositories\Claude-Setup`) is the **single source of truth** for working on the Dealerships AWS platform and its side systems
on DigitalOcean. It is loaded through `D:\Nexrupt Data\Repositories\CLAUDE.md`, which imports this file. That folder is the **workspace root**: the pack
and every application repo are cloned side by side in it. If memory, an old doc or a chat message disagrees
with the pack, say so and ask; once confirmed, update the pack.

## 0. Stance: stability first
- The platform works and the business is happy with it. **The architecture is what matters; the TODO list does not drive the work.**
- Default answer to "should we change X" is **no change** unless something is broken or the user asks. Minimal, reversible changes only.
- Improvements in `STATUS.md` and `records/TODO.md` are optional. Do not push them.

## 0a. Who you are working with
The operator may **not be a DevOps engineer** (see `START_HERE.md`). Explain in plain language, define acronyms, say what each command does
before running it and whether it reads or changes something. Report as: what I checked (evidence) · what it means · what to do.
Use skill `dealerships-onboarding` for new-operator questions.

## 0b. Know everything before changing anything (mandatory)
Before proposing or making **any** change, follow skill `dealerships-change-control`: read the relevant architecture and invariants, load the
topic skill, search `INCIDENTS.md` and `MIGRATION_HISTORY.md` for that component, check closed decisions, check live state read-only, work out
the blast radius, then present a plain-language change brief and wait for an explicit yes. No exceptions for "small" changes.

## 1. Reading order
1. This file, then `START_HERE.md` (the operator's guide). 2. `ARCHITECTURE.md` (how everything works, invariants, accepted trade-offs). 3. `INTENT_ROUTER.md` (what to do for a given request).
4. As needed: `INVENTORY.md` (IDs, hosts), `RUNBOOKS.md`, `INCIDENTS.md`, `STATUS.md` (watch-list, unknowns), `DEALERPULSE.md`, `CONTEXT.md` (history).
5. **Skills** in `skills/` (installed to `~/.claude/skills/`), loaded by topic:
   `dealerships-architecture`, `dealerships-change-control`, `dealerships-deploy`, `dealerships-edge-cloudflare`, `dealerships-monitoring`,
   `dealerships-troubleshooting`, `team-vpn-and-uptime`, `dealerpulse-digitalocean`, `dealerships-onboarding`, plus the action skills
   `ConnectWireguardUI` and `MyUptimeIP`.
6. **Knowledge** in `knowledge/` (search with `grep -n -i "<symptom or component>" Claude-Setup/knowledge/*.md`):
   `DEPLOY_FLOWS.md` (every pipeline and deploy.sh step), `ISSUES_AWS_A.md` + `ISSUES_AWS_B.md` (every past issue, final root cause, exact fix,
   gotchas, user decisions), `DEALERPULSE_OPS.md`.
7. **Records** in `records/` (the original evidence, cited by line from the knowledge files): `Migration/MIGRATION_HISTORY.md` (narrative),
   `Migration/COMMAND_LOG.md` (every executed command), `HANDOVER.md`, `TODO.md`, `Monitoring/`, `TeamVPN/`, `DealerPulse/`, `deploy-scripts/`,
   `pre-migration/` (historical). `memory-export/` holds the earlier session notes (reference).

File paths written inside `records/` and `memory-export/` reflect the folder layout of the machine they were written on. The files they point to
are in `records/` (same sub-folder names, e.g. `Migration/`, `Monitoring/`, `TeamVPN/`, `DealerPulse/`).

Everything in the pack is `[doc]` until verified live. When you verify or change a fact, update the pack in the same session with date and provenance.

## 2. Two different projects — never mix them
- **Dealerships** = multi-tenant Nissan dealership platform on AWS (migrated from DigitalOcean Aug–Sep 2026).
- **DealerPulse** = separate product on a DigitalOcean droplet (`146.190.132.236`).
- Every Dealerships AWS resource is named `dealerpulse-*`. **Never rename anything.** When someone says "DealerPulse", work out which one is meant.
- `records/Migration/COMMAND_LOG.md` is a verbatim record of executed commands. Never edit past entries.

## 3. Verify before you state
- No inference presented as fact. Check first. Label `[verified]` (checked now), `[doc]`, `[told]`, `[assumed]`.
- If a check is blocked, report the gap. If you were wrong, correct it plainly. Findings are relayed to a CTO and a senior developer.

## 4. Approval gates
- **No change to any production system without an explicit yes, every time**: nodeA `i-061291ea974c4ea1b`, nodeB `i-0c982c44f93bfbc0a`,
  integration `i-03efb82c808863f84`, the VPN box, ALB, IAM, security groups, Cloudflare, DNS, pipelines, the DigitalOcean droplet.
- Read-only diagnostics need no approval. Ask before logging in to the DealerPulse droplet.
- Do not edit `records/TODO.md` without discussing first.

## 5. Logging (proactive)
Any executed change: exact command + resulting ID in `records/Migration/COMMAND_LOG.md`; narrative (why, errors, decisions) in
`MIGRATION_HISTORY.md`; then update the matching pack file. There is no Terraform state; these files are the record.

## 6. Tooling gotchas
- The auto-mode classifier blocks credential creation, shared-resource writes, remote installs, and sometimes production reads. After one denial,
  do not retry or reword: give the user the exact step or a read-only alternative.
- `aws ssm send-command`: put commands in a JSON file and use `--parameters file://...` (inline `$(...)` expands locally).
- Windows: use the full `aws.exe` path if PATH is not inherited; in Git Bash set `MSYS_NO_PATHCONV=1`.
- Production hosts are reached by SSM only.
