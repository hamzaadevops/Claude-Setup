---
name: project-naming-dealerships-vs-dealerpulse
description: "The AWS-migrated project is called Dealerships, NOT DealerPulse; DealerPulse is a separate newer project. All AWS resources are still literally named dealerpulse-* and must not be renamed."
metadata: 
  node_type: memory
  type: project
  modified: 2026-09-17T17:23:13.585Z
  originSessionId: 74ee371c-9b1c-452f-ac76-4c3d6d415bf6
---

The multi-tenant Nissan dealership platform migrated from DigitalOcean to AWS in Aug–Sep 2026 is called **Dealerships**. It was recorded as "DealerPulse" throughout until the user corrected it on **2026-09-17**: **DealerPulse is a separate, newer project.**

**FIRST CONCRETE FACT, found 2026-09-18:** `~/.ssh/config` has had a `dealerpulse` host entry all along — **`146.190.132.236`, user `root`, key `~/.ssh/digitalocean`**. That IP is in DigitalOcean space, which **confirms DealerPulse runs on DigitalOcean** and makes the CTO agenda item *"Digital Ocean server needs LBs at urgent bases for DealerPulse"* a legitimate request rather than the misunderstanding it was first assessed as. Note the entry predates the naming correction, so it was sitting in plain sight while DealerPulse was assumed to mean the migrated stack.

**Still unknown:** what runs on it, whether it is one droplet or several, traffic, owners, and whether it is among the ~15 projects on `combined`. Nothing on that box has been inspected — it is production for a project we have no record of, so do not log in or probe it without asking first. **Ask before assuming anything about it, and never assume a statement about DealerPulse applies to Dealerships or vice versa.**

**The trap: every AWS resource for the Dealerships project is still literally named `dealerpulse-*`, and that is correct and must not be "fixed".** The naming correction applies to prose only. Renaming any of these would break live production infrastructure:

- Target groups `dealerpulse-tg-nodea` / `-nodeb` / `-nginx`; all `dealerpulse-alb-*`, `dealerpulse-nodea/nodeb-*`, `dealerpulse-tg-*` CloudWatch alarms
- IAM: `dealerpulse-ec2-ssm-role`, `dealerpulse-dlm-role`, `dealerpulse-chatbot-role`, policies `dealerpulse-developers-readonly` / `dealerpulse-sr-developers-readwrite`
- S3: `dealerpulse-media-409289617504`, `dealerpulse-backups-409289617504`
- CloudWatch Logs `/dealerpulse/*`; SSM parameters `/dealerpulse/shared/*`; dashboards `DealerPulse-Fleet-Overview` / `-Logs` / `-Per-VM`; metric namespace `DealerPulse/nginx`
- On-host paths `/opt/dealerpulse/*`; the `Project=dealerpulse` tag (DLM snapshot targeting depends on it); SNS topic `dealerpulse-alerts`; Slack channel `#aws-alerts-dealerpulse`; the inferred domain `dealerpulse.cloud`

**Two further false-positive traps when searching or renaming:**
1. **`dealerpulse` is also the name of chat_backend's Postgres database** (`pg_dump -U postgres -d dealerpulse`). Unrelated to the project name, must not change.
2. **`Documentations/Migration/COMMAND_LOG.md` is a verbatim record of executed commands** and was deliberately left untouched — it contains real `--description "DealerPulse Frontend VM"` security-group values and an SNS `--subject "DealerPulse test alert"`. Rewriting a command log falsifies the record.

**Why:** the user asked on 2026-09-17 to "change and note it everywhere." A blind find-and-replace across the docs would have corrupted ~538 live resource identifiers, a database name, and an execution log — only ~58 of ~596 occurrences were prose. The rewrite applied was capitalised `DealerPulse` only, excluding anything followed by `-`, `/` or a word character, and excluding `COMMAND_LOG.md`.

**How to apply:** call the migrated project Dealerships in all prose, titles and future documents. Leave every resource identifier exactly as deployed. When something says "DealerPulse", check whether it means the resource prefix, the chat database, or the genuinely separate new project before acting on it. Related: [[project-dealerships-aws-migration]], [[project-dealerships-cloudflare-config]], [[feedback-prod-vm-change-approval]].
