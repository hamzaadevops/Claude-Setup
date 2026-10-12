---
name: feedback-migration-logging
description: Standing requirement to log every AWS command and keep a detailed narrative history during the Dealerships migration
metadata: 
  node_type: memory
  type: feedback
  originSessionId: 1408d996-2125-4239-9d84-ab67467c9311
  modified: 2026-08-25T20:53:28.617Z
---

Every AWS CLI command run for [[project-dealerships-aws-migration]] must be appended to `Documentations/Migration/COMMAND_LOG.md` (exact command + resulting resource ID), and each substantive work session needs a narrative entry in `Documentations/Migration/MIGRATION_HISTORY.md` covering rationale, errors hit, and decisions made — not just the raw commands.

**Why:** the team chose raw AWS CLI scripts over Terraform/CDK, so there is no state file — these two docs are the only record of what exists and why. User explicitly said this is for future debugging.

**How to apply:** treat this as standing instruction for the whole migration project, not a one-off request — update both files proactively after any AWS resource is created/changed/destroyed in this project, without needing to be asked each time.
