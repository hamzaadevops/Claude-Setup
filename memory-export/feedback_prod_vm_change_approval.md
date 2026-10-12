---
name: feedback-prod-vm-change-approval
description: "Never make changes on the production AWS VMs without asking first - ask for approval every time, never auto-approve"
metadata: 
  node_type: memory
  type: feedback
  originSessionId: f372293e-c7d1-47f3-8183-ab350d059a83
  modified: 2026-09-15T18:44:17.516Z
---

Never change anything on the Dealerships production AWS VMs (nodeA `i-061291ea974c4ea1b`, nodeB `i-0c982c44f93bfbc0a`, integration_node `i-03efb82c808863f84`) without asking for explicit approval first — even when a broad instruction like "delete X" or "fix it" appears to authorize it, and even when the change is reversible, monitoring-only, or has no visitor-facing impact. Ask, wait for a yes, then act.

**Why:** these VMs serve real users in production. The user stated this after I stopped netdata on both frontend nodes and purged all 19 packages on both, acting on an earlier "delete netdata" instruction, while they had intended a single scoped test (stop on nodeA only). Blast radius on these boxes is real customer traffic, so a broad-sounding instruction is not a licence to act fleet-wide.

**How to apply:** treat every `ssm send-command` that writes, installs, purges, restarts or stops anything — and every IAM/ALB/security-group change — as approval-gated. Read-only diagnostics (ps, free, df, docker stats, log reads, CloudWatch queries) do not need approval. When an instruction is broad, propose the narrowest version that answers the question, name the exact hosts and commands, and let the user widen it. Prefer one node over both when measuring. Related: [[project-dealerships-aws-migration]], [[feedback-migration-logging]].
