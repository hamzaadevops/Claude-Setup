# CLAUDE.md — standing rules for any Claude agent (single source of truth)

This pack (`Documents\Claude-Setup`) is the **single source of truth** for working on the Dealerships AWS platform and its side systems
on DigitalOcean. It is loaded through `Documents\CLAUDE.md`, which imports this file. If memory, an old doc or a chat message disagrees
with the pack, say so and ask; once confirmed, update the pack.

## 0. Stance: stability first
- The platform works and the business is happy with it. **The architecture is what matters; the TODO list does not drive the work.**
- Default answer to "should we change X" is **no change** unless something is broken or the user asks. Minimal, reversible changes only.
- Improvements in `STATUS.md` and `Documentations/TODO.md` are optional. Do not push them.

## 1. Reading order
1. This file. 2. `ARCHITECTURE.md` (how everything works, invariants, accepted trade-offs). 3. `INTENT_ROUTER.md` (what to do for a given request).
4. As needed: `INVENTORY.md` (IDs, hosts), `RUNBOOKS.md`, `INCIDENTS.md`, `STATUS.md` (watch-list, unknowns), `DEALERPULSE.md`, `CONTEXT.md` (history).
5. **Skills** in `skills/` (installed to `~/.claude/skills/`), loaded by topic:
   `dealerships-architecture`, `dealerships-change-control`, `dealerships-deploy`, `dealerships-edge-cloudflare`, `dealerships-monitoring`,
   `dealerships-troubleshooting`, `team-vpn-and-uptime`, `dealerpulse-digitalocean`, plus the action skills `ConnectWireguardUI` and `MyUptimeIP`.
6. Deep detail outside the pack: `Documents\Documentations\` (`HANDOVER.md`, `Migration/MIGRATION_HISTORY.md`, `Migration/COMMAND_LOG.md`,
   `DealerPulse/`, `Monitoring/`, `TeamVPN/`). `memory-export/` holds earlier detailed notes (reference only).

Everything in the pack is `[doc]` until verified live. When you verify or change a fact, update the pack in the same session with date and provenance.

## 2. Two different projects — never mix them
- **Dealerships** = multi-tenant Nissan dealership platform on AWS (migrated from DigitalOcean Aug–Sep 2026).
- **DealerPulse** = separate product on a DigitalOcean droplet (`146.190.132.236`).
- Every Dealerships AWS resource is named `dealerpulse-*`. **Never rename anything.** When someone says "DealerPulse", work out which one is meant.
- `Documentations/Migration/COMMAND_LOG.md` is a verbatim record of executed commands. Never edit past entries.

## 3. Verify before you state
- No inference presented as fact. Check first. Label `[verified]` (checked now), `[doc]`, `[told]`, `[assumed]`.
- If a check is blocked, report the gap. If you were wrong, correct it plainly. Findings are relayed to a CTO and a senior developer.

## 4. Approval gates
- **No change to any production system without an explicit yes, every time**: nodeA `i-061291ea974c4ea1b`, nodeB `i-0c982c44f93bfbc0a`,
  integration `i-03efb82c808863f84`, the VPN box, ALB, IAM, security groups, Cloudflare, DNS, pipelines, the DigitalOcean droplet.
- Read-only diagnostics need no approval. Ask before logging in to the DealerPulse droplet.
- Do not edit `Documentations/TODO.md` without discussing first.

## 5. Logging (proactive)
Any executed change: exact command + resulting ID in `Documentations/Migration/COMMAND_LOG.md`; narrative (why, errors, decisions) in
`MIGRATION_HISTORY.md`; then update the matching pack file. There is no Terraform state; these files are the record.

## 6. Tooling gotchas
- The auto-mode classifier blocks credential creation, shared-resource writes, remote installs, and sometimes production reads. After one denial,
  do not retry or reword: give the user the exact step or a read-only alternative.
- `aws ssm send-command`: put commands in a JSON file and use `--parameters file://...` (inline `$(...)` expands locally).
- Windows: use the full `aws.exe` path if PATH is not inherited; in Git Bash set `MSYS_NO_PATHCONV=1`.
- Production hosts are reached by SSM only.
