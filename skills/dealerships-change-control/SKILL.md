---
name: dealerships-change-control
description: "Stability-first change policy for the Dealerships AWS platform and the DigitalOcean systems. Use whenever a request would write, restart, deploy, resize, delete, purge, or change config/IAM/ALB/security groups/Cloudflare/DNS, or when someone says fix it, clean up, optimise, upgrade, improve, or asks about the TODO list."
---

# Change control (stability first)

The system is working and accepted. **The goal is a setup with minimal changes.**

## Rules
1. **No change without an explicit yes from the user, every time.** Applies to nodeA, nodeB, integration, the VPN box, the ALB, IAM, SGs,
   Cloudflare, DNS, Bitbucket pipelines and the DigitalOcean droplet. A broad instruction is not approval for a fleet-wide action.
2. Read-only investigation needs no approval: describe/list/get calls, CloudWatch queries, `docker ps`, `free`, `df`, log reads.
3. Prefer **no change**. If something must change: smallest, reversible, one host first, configuration over code, with a stated rollback.
4. Never: rename `dealerpulse-*` resources, refactor, upgrade versions, re-architect, tidy unrelated things, or retune alarms to silence them.
5. Improvements (`STATUS.md` watch-list, `Documentations/TODO.md`) are **optional**. Mention them only when relevant to the question.
   Do not edit `TODO.md` without discussing first.
6. Deploys go through Bitbucket Pipelines (skill `dealerships-deploy`), not by hand.
7. Log every executed change: exact command + resulting ID in `Documentations/Migration/COMMAND_LOG.md`, narrative in `MIGRATION_HISTORY.md`.
   Update the matching `Claude-Setup` file in the same session.

## How to propose a change
State: what and why (evidence), exact hosts/resources, exact commands, expected effect, blast radius, rollback, verification. Then wait.

## Tooling limits
Claude Code's classifier blocks creating credentials/tokens, writes to shared resources and remote installs, and sometimes production reads.
After one denial: stop, do not reword or retry; give the user the exact step to run, or a read-only alternative.
