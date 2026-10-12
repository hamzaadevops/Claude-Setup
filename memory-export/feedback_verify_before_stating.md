---
name: feedback-verify-before-stating
description: "Verify every claim before telling the user — no inference presented as fact, mark provenance explicitly"
metadata: 
  node_type: memory
  type: feedback
  originSessionId: 7d64f915-de6f-4d6a-b53f-be89183a7c23
  modified: 2026-09-17T18:39:07.821Z
---

Do not state anything to this user that has not been verified. Check it first —
run the command, read the file, resolve the DNS, test the connection — and if
something genuinely cannot be verified, say so explicitly and label it as an
assumption rather than folding it into the narrative.

**Why:** given 2026-09-17 during DealerPulse discovery, after several inferences
turned out to be wrong in ways that would have changed decisions:

- Claimed blue/green colour was switched by hand-editing nginx. It is actually
  automated in `bitbucket-pipelines.yml` (`sed -i` on the vhost, then reload).
- Claimed the exposed droplet Postgres was the production DB. The real DB is a
  DO managed cluster; the droplet's Postgres is a separate, unused instance.
- Called it "one password from the open internet" before reading `pg_hba.conf`,
  which actually restricts auth to specific source IPs.
- Said `corona.dealerpulse.cloud` was "still live". It is NXDOMAIN publicly —
  only `surfcity.dealerpulse.cloud` resolves.
- Assumed a 502 on `/api/calls/<id>/get-recording/` came from a missing
  `RETELL_API_KEY`. It is an application-level 502 from a **Twilio** recording
  download failing.

This user is making infrastructure decisions from what I report, on production
systems, and often relaying it to a CTO and a senior developer. A confident wrong
statement costs them credibility and can misdirect real work.

**How to apply:** treat it as standing for all work with this user, not just
DealerPulse. Keep the `[verified] / [told] / [doc] / [assumed]` provenance
convention used in `Documentations/DealerPulse/ARCHITECTURE.md`. When a check is
blocked by tooling, report the gap rather than inferring around it. Correct
earlier claims plainly and immediately once shown wrong — see
[[project-dealerpulse]].
