---
name: feedback-todo-change-approval
description: "Discuss and get approval before adding, removing or rewriting items in Documentations/TODO.md - do not edit it unilaterally"
metadata:
  node_type: memory
  type: feedback
---

Never add, remove or rewrite items in `Documentations/TODO.md` without discussing the change
first and getting explicit approval. Propose the item (what it is, why, the estimate) in the
reply, wait for a yes, then edit the file.

**Why:** TODO.md is the user's canonical planning and prioritisation document — it is what they
work from and hand to developers. Reprioritising it or rewriting its status section changes what
the team does next, so that decision is the user's, not mine. They stated this after I added
items 11 and 12, reordered the priority line and rewrote the status section in one pass without
asking.

**How to apply:** treat TODO.md exactly like a production change — read-only investigation needs
no approval, but any edit does. Present findings and a proposed item, let the user accept, reject
or reword it. This is narrower than and consistent with [[feedback-prod-vm-change-approval]].
Logging to `MIGRATION_HISTORY.md` and `COMMAND_LOG.md` remains a standing proactive requirement
([[feedback-migration-logging]]) and is not affected. Related: [[project-dealerpulse-aws-migration]].
