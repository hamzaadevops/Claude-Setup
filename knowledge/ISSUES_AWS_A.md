> **Knowledge file (reference).** Extracted 2026-10-13, read-only, from the Dealerships records. Citation keys: **MH:n** = `records/Migration/MIGRATION_HISTORY.md` line n; **MEM:n** = `memory-export/project_dealerships_aws_migration.md` line n; **TODO:n** = `records/TODO.md`; **TEN:n** = `records/TENANTS_PUENTE_HILLS_SURF_CITY.md`; **INV:n** = `records/INVENTORY_PERFORMANCE_FINDINGS.md`. Status lines are as of the last mention in the records (mostly 2026-09-17), not live. Verify live before acting.

# Dealerships AWS platform: catalogue of issues, incidents and gotchas

**Scope:** I read all four requested sources in full, read-only.
- `records/Migration/MIGRATION_HISTORY.md` lines 1–1810.
- `Claude-Setup/memory-export/project_dealerships_aws_migration.md`, all 735 lines.
- `records/TODO.md`, `records/TENANTS_PUENTE_HILLS_SURF_CITY.md` and `records/INVENTORY_PERFORMANCE_FINDINGS.md`.

I did not run AWS, SSH, curl or git, and I copied no secret values.

**Status reflects the documents, not a live check.** Every "status" below is as of the latest mention in these files (the latest is 2026-09-17). All of it is [doc], meaning a file says so; I verified none of it live.

**Citation keys:**
- **MH:n** = `records/Migration/MIGRATION_HISTORY.md` line n
- **MEM:n** = `memory-export/project_dealerships_aws_migration.md` line n (each line is one dense paragraph)
- **TODO:n** = `records/TODO.md`
- **TEN:n** = `records/TENANTS_PUENTE_HILLS_SURF_CITY.md`
- **INV:n** = `records/INVENTORY_PERFORMANCE_FINDINGS.md`

**Host key** (needed to read logs correctly):
- nodeA `i-061291ea974c4ea1b`, EIP 184.32.92.25 (MH:276, MEM:41)
- nodeB `i-0c982c44f93bfbc0a`, EIP 35.95.214.123 (MH:566)
- integration `i-03efb82c808863f84`, EIP 52.12.241.229, private IP 10.0.1.92 (MH:582, MEM:41)

---

## PART 0 — Contradictions and corrections between the sources (read first)

C-1. **The ".php scanner IP" is nodeA's own address.**
- MH:1100 names 184.32.92.25 as "a vulnerability scanner" (701 requests, 830 `.php` probes).
- MH:276 and MEM:41 say 184.32.92.25 is nodeA's Elastic IP.
- MH:1102 correctly recognised nodeB's IP (35.95.214.123) as the SSR hairpin, but never noticed this.
- So the nodeA-IP traffic is most likely nodeA's own SSR hairpin. The external scanner is probably `5.175.189.113` and/or others. Unresolved in the docs.

C-2. **Postgres `max_connections` is recorded inconsistently.**
- MEM:358 says it was raised 100→150 on 2026-09-10. MEM:434, MEM:575, TEN:34 and INV:259 all say 150.
- MH:1104 (2026-09-14) says "`max_connections` is 100 against 10 in use."
- One of these is wrong. Check live before relying on either.

C-3. **The `limit_conn` fix was not all "unlogged".**
- MH:1034 says someone fixed it "and never wrote it down".
- MEM:386 records the 60→300 raise as done (2026-09-10/11).
- Only the `_rsc` exemption map has no recorded author (MEM:475-485).

C-4. **The fd-exhaustion alarm was deleted on purpose.**
- MEM:550, TEN:47 and TEN:216 say "deleted by someone else, reason unknown".
- MH:1160 records that the 2026-09-14 alarm rebuild deleted it on purpose, because its metric had only 2 datapoints in 14 days.
- Context the deletion reasoning ignored [inference]: a metric filter only publishes when a log line matches. Also, nginx error-log shipping was dead from 2026-09-12 01:25 until 09-16 (MH:1297). So "nobody emits it" was not evidence the filter was broken.
- The metric filter still exists (MEM:550). Not recreated as of 2026-09-17 (TEN:47).

C-5. **Stickiness never protected anything.**
- MEM:35 and MEM:564 say both stickiness layers are "required" to prevent cross-node chunk 404s.
- This is superseded by MEM:664-670, MH:1321-1336 and TODO:379-384. Cloudflare's `strip_set_cookie` stripped `AWSALB`, so stickiness never worked at the edge. It was removed 2026-09-16.
- The real chunk-404 protections are: the same ECR image on both nodes, an atomic deploy, a Cloudflare `status_code_ttl`, and an automatic purge (MEM:695-721, TEN:99-104).

C-6. **The chunk-404 root cause changed three times** (F-1):
- 09-01: independent builds on each node.
- 09-11: the `:latest` tag moved mid-iteration.
- 09-16: deploy-timing skew plus Cloudflare caching the 404 (final).

C-7. **nodeA "throttled" vs. unlimited mode.**
- MH:1132 says nodeA was "already throttling to baseline".
- MH:1058 retracts throttling: both nodes are T3 `unlimited`, so they bill surplus credits instead of throttling.

C-8. **The memory-metrics fix was not the managed policy.**
- MH:1136, MEM:329 and MH:1535 say "attach `CloudWatchAgentServerPolicy`".
- The actual fix (2026-09-15) was an inline policy `dealerpulse-cloudwatch-metrics-write` (`cloudwatch:PutMetricData`, conditioned on namespace `CWAgent`) (MH:1268).
- MH:1535 (2026-09-17 call prep) is stale on this point.

C-9. **The inventory warm cron is 3x/day, not hourly.**
- INV:22, INV:41 and MEM:584 say the cron is hourly.
- MH:1581 shows `INVENTORY_WARM_HOURS_UTC = 1,15,20` (3x/day). The user confirmed this is a business requirement (MH:1740).
- TODO:315 (fix 1, "make it hourly") therefore conflicts with that decision.
- TODO:319 recommends TTL 57600. The later analysis recommends 72000 plus a forced refresh after restart plus a cache-age alarm (MH:1777-1806).

C-10. **The stampede symptom was attributed to the wrong bug first.**
- It was first blamed on the db0/DB-routing mismatch. That routing was a real bug and was fixed (MEM:528).
- The TTL-shorter-than-warm-gap mechanism survived that fix (MH:1613-1620).

C-11. **The latency alarm's cause was revised.**
- First attributed to legacy `.htm` URLs (MH:1403-1459).
- Corrected: the main drivers are the cache stampede and the image optimizer. `.htm` is minor (MH:1546-1548, MH:1658-1660).

C-12. **nodeA's `/_next/image` concentration has no explanation.** The stickiness explanation (MH:1066-1076) was retracted (MH:1332-1336, TODO:389-392). The cause is now unexplained; netdata is the better candidate.

C-13. **Can the `netdata-edge` apt source bring netdata back?**
- MH:1291 says the source was left in place, so netdata could return.
- TODO:401-402 (later) says it was removed together with `netdata-repo-edge`, so it cannot return.

C-14. **`ocean` entrypoint migrate race.**
- MEM:216 says the fix was "written locally, not committed".
- MH:748 mentions an uncommitted `entrypoint.sh` fix belonging to someone else.
- MH:920 and MEM:305 say all four "as-is" issues are closed. There is no deployment evidence for this item in my sources.

C-15. **The latency report from 2026-09-15 was wrong.**
- It said p99 0.60–3.2 s with zero 5xx. That query used the TargetGroup dimension of a target group mid-decommission.
- Correct LoadBalancer-only figures: p99 up to 8.39 s, max 24.8 s, 25 target 5xx (MEM:571, MH:1537).

C-16. **The shared-Redis ISR fix does not exist.**
- MEM:289 corrects an earlier claim that a PR "just needs merging".
- No such code exists on any `website_frontend` branch. Don't cite it.

C-17. **The CPU-credit picture improved after the capacity warning was written.**
- After netdata was removed, nodeA's credits went 3 → 324 → 358 (MEM:673, TODO:29-32).
- The capacity warning (MH:1217) is less acute than written.

---

## PART 1 — Issue catalogue

Format for each issue: component; symptom (as a non-technical person would notice it); how it was detected; root cause; fix; verification; status; "if it happens again"; a simple prompt; citations.

Approval markers:
- **[PROD]** = a change to a production VM, ALB, SG or IAM.
- **[PROD-user]** = the user ran it manually because the classifier blocked it.

### A. Alerting (SNS → AWS Chatbot → Slack)

**A-01 · Slack gets nothing from manual test alerts (2026-08-26)**
- **Component:** SNS `dealerpulse-alerts` → AWS Chatbot (appears in Slack as "Amazon Q") → Slack channel `C0BSKFCAV1T` (#aws-alerts-dealerpulse).
- **Symptom:** "I sent a test alert and nothing showed up in Slack."
- **Detected:** the user tested.
  - SNS `NumberOfNotificationsFailed`=0 and `Delivered`>0, so the AWS side worked.
  - The Chatbot log group was found in **us-east-1**, not us-west-2.
  - The log said `"Event received is not supported"`.
- **Root cause:** Chatbot only renders AWS-service JSON schemas, such as CloudWatch Alarms and Budgets. A freeform `sns publish` is always rejected.
  - Co-existing latent issues: the bot was never added to the channel (authorising the workspace does not add it to a channel), and the logs live in us-east-1.
  - Red herring: the channel ID looked like it might be `COBSK…` (letter O) instead of `C0BSK…` (zero). It was correct.
- **Fix:** add the app through the channel's Integrations tab → Add an App. Typing `/invite @AWS Chatbot` fails. Test with a real CloudWatch alarm, not freeform text.
- **Status:** understood. **Cost Anomaly Detection is not a Chatbot-supported source**, so `dealerpulse-cost-anomaly-alerts` will never reach Slack. This is a known, accepted, unfixed gap (an email subscriber could be added).
- **If again:** check SNS delivery metrics → `/aws/chatbot/dealerpulse-alerts` in us-east-1 with INFO logging → if the log says "not supported", the message source is the problem.
- **Prompt:** "AWS alerts aren't showing up in Slack — can you check?"
- **Cites:** MH:194-226, MEM:110, MEM:114.

**A-02 · Even real alarms didn't arrive: the Chatbot channel config was silently broken (2026-08-26)**
- **Symptom:** a real CloudWatch alarm test still produced nothing, with zero Chatbot log activity even at INFO.
- **Root cause (inferred from the pattern, AWS internals are opaque):** the config was created with the default `AdministratorAccess` guardrail and patched to `ReadOnlyAccess` afterwards. It could still reject unsupported messages but could not forward supported ones.
- **Fix [PROD]:** deleted and recreated the channel config, with guardrail `ReadOnlyAccess` and the logging level set at creation time.
- **Verified:** two independent test alarms arrived, one of them sent after an update call to prove the fix holds.
- **Status:** fixed. The stable resource is `dealerpulse-alerts`, LoggingLevel ERROR. Don't recreate it casually.
- **Security note:** new Chatbot configs default to the `AdministratorAccess` guardrail. Always set it explicitly.
- **If again:** if SNS shows clean delivery but Chatbot logs nothing for a supported type, delete and recreate with every setting specified at creation.
- **Prompt:** "Slack alerts stopped arriving even for real alarms."
- **Cites:** MH:177, MH:230-262, MEM:108, MEM:112.

### B. VM bootstrap, access and workstation

**B-01 · New VM bootstrap aborted: Ubuntu 24.04 has no `awscli` apt package (2026-08-26)**
- **Component:** EC2 user-data on nodeA.
- **Symptom:** the new server comes up with Docker and nginx not running and no swap.
- **Detected:** an SSM Run Command diagnostic showed `E: Package 'awscli' has no installation candidate`. `set -e` aborted everything after it.
- **Fix [PROD]:** install AWS CLI v2 with the official curl+unzip installer. Re-ran the corrected script through SSM, base64-encoded, because user-data does not re-run after launch.
- **Verified:** CLI v2.36.31, Docker active, nginx active, 4 GB swap, swappiness 10.
- **Status:** fixed. nodeB and integration used the corrected script; nodeB's was recovered from `/tmp/dealerpulse-bootstrap.sh` on nodeA (MH:560). The runbook `AWS_MIGRATION_PLAN.md` §2.1 was not corrected (MH:296).
- **Prompt:** "The new server came up but Docker isn't running."
- **Cites:** MH:280-296, MH:405, MH:560, MEM:120.

**B-02 · All sites look down from my laptop: workstation DNS resolver (2026-09-15)**
- **Symptom:** every hostname returns `code=000` from the workstation.
- **Root cause:** resolver `100.100.100.1` (CGNAT range, likely VPN-pushed) times out. The DNS records and sites were fine.
- **Verified:** resolving against `1.1.1.1` and `curl --resolve` gave 200/301/302.
- **Status:** a workstation issue, unresolved in the docs.
- **If again:** test with `nslookup host 1.1.1.1` before declaring an outage.
- **Prompt:** "All our sites look down from my machine."
- **Cites:** MH:1251.

**B-03 · Team VPN box has no management path at all (2026-09-15)**
- **Component:** `i-0ad5d9743f6c95721` (team VPN, same AWS account).
- **Symptom:** cannot SSM or SSH into the VPN box.
- **Root cause:** there is no IAM instance profile, so SSM reports `InvalidInstanceId`. The SSH allowlist (`223.123.18.138/32`) is stale.
- **Fix proposed:** attach an instance profile with `AmazonSSMManagedInstanceCore` (15 min, API only).
- **Status:** open (TODO item 6).
- **Prompt:** "I can't get into the VPN server."
- **Cites:** MH:1249, TODO:203-212.

### C. `ocean` (Django backend) configuration and runtime

**C-01 · ocean deployed "as-is" with four known defects (2026-08-26 → closed 2026-09-07/08)**
- **The four defects:** `DEBUG=True`; `ALLOWED_HOSTS=["*"]`; Django `runserver` instead of gunicorn; `entrypoint.sh` runs `migrate` unconditionally.
- **Symptom of the migrate race:** worker and beat logs show `relation "X" already exists` after a deploy, and the containers self-heal through restarts. It recurred 2026-08-28 (MH:478).
- **Detected:** a code read before deploying (MH:310). The race was confirmed live (MH:326).
- **Fixes:**
  - Gunicorn has been live since 2026-09-01 (3 workers × 4 threads, `--timeout 60`), verified with `docker compose top web` (MH:798-800, MEM:160).
  - A teammate's PR made DEBUG, ALLOWED_HOSTS and CORS env-driven. **`ALLOWED_HOSTS` and `CORS_ALLOWED_ORIGINS` fail open if unset**, so the real values had to be set in `.env` on both nodes. Containers were recreated with `up -d --no-deps`, not `restart` [PROD].
  - The PR also removed the `CORS_ALLOW_ALL_ORIGINS=True` + `CORS_ALLOW_CREDENTIALS=True` vulnerability (any site could make credentialed requests).
- **Verified:** `settings.DEBUG=False`. A bare-IP Host now returns 400 (was 302). A CORS preflight from an allowed origin gets headers; a bogus origin gets none.
- **Side effect:** the ALB health check now gets 400, which the `200-499` matcher tolerates (see H-03).
- **Status:** closed (MH:920, MEM:305). The migrate-race closure is not evidenced in my range (C-14).
- **Prompt:** "Is the backend still in debug mode / accepting any host?"
- **Cites:** MH:304-334, MH:478, MH:898-920, MEM:126, MEM:299-305.

**C-02 · ocean used a personal IAM access key instead of the instance role (2026-08-27 → fixed 2026-08-28)**
- **Fix [PROD, confirmed by the user after a classifier block]:**
  - Backed up `.env` to `.env.bak-before-instancerole`.
  - Blanked `AWS_S3_ACCESS_KEY_ID` and `AWS_S3_SECRET_ACCESS_KEY`.
  - Ran `docker compose restart web worker beat`.
- **Verified:** no boto3 errors; `collectstatic` reported "192 unmodified"; S3 image URLs return 200.
- **Status:** fixed. The user's own key was left untouched on purpose.
- **Prompt:** "Is the backend still using a hard-coded AWS key?"
- **Cites:** MH:427, MH:455-467, MEM:77.

**C-03 · CSRF trusted origins still pointed at the old staging domain (found 2026-08-28)**
- **Symptom:** session/CSRF-protected form posts get silently rejected with 403. JWT endpoints are unaffected.
- **Root cause:** `CSRF_TRUSTED_ORIGINS=https://nissan.staging.flutenwebframework.xyz` on both nodes.
- **Fix [PROD]:** `.env` edit with a backup (`.env.bak-before-csrf-fix`).
- **Status:** fixed. **Rule:** whenever a new hostname is added, check both CSRF and CORS (MEM:57).
- **Prompt:** "Saving a form gives 403 on the new domain."
- **Cites:** MH:607, MEM:57.

**C-04 · Chat REST calls blocked by CORS: `chat_back` origins hardcoded (2026-08-28 → env-driven 2026-09-05)**
- **Symptom:** the chat widget's REST calls (for example chat history) fail with a CORS error in the browser console. WebSockets are unaffected.
- **Root cause:** `chat_back/main.py` had a hardcoded `allow_origins` list containing only `omnipulse.cc` and localhost.
- **Fix history:**
  - A local uncommitted patch on integration (`main.py.bak-before-cors-fix`).
  - The patch was **silently reverted by the deploy.sh auto-stash** and broke chat history until it was reapplied (MEM:37).
  - Permanent fix: an env var `CORS_ALLOWED_ORIGINS`, merged into `main-migrated` (MEM:204).
- **Status:** fixed. The new domain's bare and `www.` forms were added 2026-09-08 (MEM:309).
- **Prompt:** "The chat widget shows a CORS error."
- **Cites:** MH:609, MEM:37, MEM:57, MEM:204, MEM:309.

**C-05 · "FIELD_ENCRYPTION_KEY is not set" after adding it to `.env` (2026-09-04)**
- **Symptom:** saving dealership SMTP settings crashes with `ImproperlyConfigured: FIELD_ENCRYPTION_KEY is not set`.
- **Detected:** `docker exec … printenv` was empty inside the container, and the container's `StartedAt` was earlier than the `.env` edit.
- **Root cause:** `docker compose restart` does not re-read `.env`.
- **Fix [PROD]:** `docker compose up -d --no-deps web worker beat` on both nodes.
- **Verified:** the variable is present in the containers (checked with a set/not-set boolean, never echoing the value), and there are no encryption errors.
- **Risk note:** the key is per-node `.env` while the DB is shared. A mismatched key across nodes means decrypt failures (MH:707).
- **Status:** fixed. **Rule:** a new `.env` variable needs `up -d`, never `restart`.
- **Prompt:** "I added a variable to .env and the app still says it's not set."
- **Cites:** MH:705-713, MEM:247-249.

**C-06 · Production 500s leave no trace: no Django LOGGING config and no Sentry (found 2026-09-10, re-confirmed 2026-09-14)**
- **Symptom:** the site intermittently errors and nobody can say why.
- **Root cause:** with `DEBUG=False`, Django's default console handler never fires. Even the apicrypto middleware's `logger.exception` goes nowhere. `website_frontend` produced zero log lines in 45 minutes.
- **Status:** open (TODO item 8, about 1 h, plus 1–2 h for Sentry). Left to the dev team by the user's explicit choice (MEM:357). This is why the eleven 500s on 2026-09-14 can never be explained.
- **Prompt:** "We got 500 errors — what caused them?" (Expect the answer: unknowable until LOGGING exists.)
- **Cites:** MH:1104-1106, MEM:355, MEM:362, TODO:231-236.

**C-07 · "The website is slow" plus about 5% 500s: shared Postgres connection exhaustion (2026-09-10)**
- **Symptom:** slow pages with intermittent errors, p99 4–25 s+, 767 of 15,700 requests returning 500 (mostly `/api/public/components/`).
- **Detected:** ALB metrics, then the Postgres container log: `FATAL: sorry, too many clients already`, timestamp-matched to the bursts.
- **Root cause:** no `CONN_MAX_AGE` (a new connection per request) against `max_connections=100` shared by both nodes. Triggered partly by bursts of the frontend `pages/null` bug (F-07).
- **Fix [PROD, user chose 150 over 300 because of RAM]:** `ALTER SYSTEM SET max_connections = 150;` then `docker restart ocean-shared-postgres`. This means brief shared-DB downtime.
- **Later:** the dev team set `CONN_MAX_AGE=60` (MEM:434).
- **Verified:** both nodes reconnected and the targets were healthy. The FATALs stopped after 2026-09-10 19:15 (MEM:434).
- **Status:** mitigated. PgBouncer is the durable option (MEM:362). See C-2 for the 100-vs-150 contradiction.
- **Prompt:** "The site is slow and throwing errors — is the database overloaded?"
- **Cites:** MEM:353-362, MEM:434, INV:259.

**C-08 · Backend crash-loops during a migration: restored tables owned by the `postgres` role (2026-09-03)**
- **Symptom:** after a deploy the backend hangs at `Applying cms.0041…` and the site errors.
- **Detected:** `pg_stat_activity` showed no active queries; container state showed a fast crash-loop.
- **Root cause:** the original `pg_restore` lacked `--no-owner`. All 45 tables and 38 sequences were owned by `postgres`, not `ocean_app`, so `ALTER TABLE` failed.
- **What does not work:** `REASSIGN OWNED BY postgres TO ocean_app` (Postgres refuses it for the `postgres` role).
- **Fix [PROD]:** a `DO $body$ … $body$;` loop running `ALTER TABLE` / `ALTER SEQUENCE … OWNER TO ocean_app`. The `psql -c` argument must be single-quoted, because the shell expands `$$` as a PID inside double quotes.
- **Status:** fixed. The same playbook applies to `leads_db` or `dealerpulse` if needed.
- **Prompt:** "The backend is stuck applying a migration after deploy."
- **Cites:** MEM:229, MEM:237.

**C-09 · Backend connects to the wrong (local) DB even though `.env` points at shared Postgres (2026-08-28)**
- **Symptom:** a new node has empty or wrong data, or a local `db` container keeps reappearing.
- **Root cause:**
  - `ocean/docker-compose.yml` hardcodes `HOST: db` / `PORT: "5432"` in `environment:` (lines 12-13, 35-36, 57-58), which overrides `.env`.
  - `depends_on: [db, redis]` re-creates `db` unless `--no-deps` is passed.
- **Fix [PROD]:**
  - A local `docker-compose.override.yml` setting `HOST: 10.0.1.92` (later replaced by an `.env`-substitution fix; the override file is gone, MEM:235).
  - `--no-deps` added to deploy.sh's ocean case on all VMs.
- **Verified:** the web log said "No migrations to apply", which proves it hit the populated shared DB.
- **Status:** fixed.
- **Prompt:** "The backend on the new node shows no data."
- **Cites:** MH:580-588, MEM:49, MEM:235.

**C-10 · Backend stuck "Waiting for PostgreSQL…": override file lost to the deploy.sh auto-stash (2026-08-28/09-01, three occurrences)**
- **Symptom:** after a deploy, the site returns HTTP 000 or errors, and the web logs loop on `Waiting for PostgreSQL...` even though the host can reach `10.0.1.92:5432`.
- **Root cause:** the untracked `docker-compose.override.yml` was stashed by deploy.sh on a branch switch, so the hardcoded `HOST: db` won again.
- **Detected:** `git stash list` showed `deploy.sh auto-stash` entries.
- **Fix:** recreate the override and restart. Structural fix in E-01; the override file is no longer needed (MEM:235).
- **Status:** fixed structurally.
- **If again:** run `git stash list` in the repo first whenever config looks reverted.
- **Prompt:** "After deploy the backend can't reach the database."
- **Cites:** MEM:39, MEM:140, MEM:235.

**C-11 · Accepted trade-off: Celery beat on both nodes plus per-node Redis (decided 2026-08-27)**
- **Consequences:**
  1. `detect_sold_inventory` (03:00 UTC) can write duplicate `SoldInventory` rows, since there is no unique constraint and no distributed lock.
  2. Per-node inventory cache skew.
  3. HomeNet and JD Power refreshes run twice per cycle.
- **Fix proposed and declined by the user:** shared Redis plus RedBeat.
- **Status:** accepted trade-off. Don't fix unilaterally.
- **Related operational note:** the Celery broker is per-node (`redis://localhost:6379/0`). Tasks queued on a node with a dead worker never fail over (MH:1358-1362, TODO:385-388).
- **Prompt:** "Why do we see duplicate sold-vehicle rows?"
- **Cites:** MH:344-350, MEM:29, MEM:431, MH:1221.

**C-12 · Offers expire about 12–13 hours early for California tenants: `TIME_ZONE='Asia/Karachi'` (closed decision 2026-09-14/16)**
- **Symptom:** specials disappear early. Logs show `+0500` while nginx shows UTC.
- **Root cause:** `coresite/settings/base.py:47`. `timezone.localdate()` drives `public_views.py:538` (specials), the dashboard window, and the CRM `requestdate`.
- **Status:** **closed decision. Do not change and do not re-raise.** A change to UTC was briefly made and reverted the same day, never deployed.
- **Prompt:** none. Explain that this is an accepted decision.
- **Cites:** MH:1126-1128, MH:1392-1393, TODO:60-76, TODO:173-186.

**C-13 · Admin "revalidate" updates only one of the two nodes: cross-node ISR (found 2026-09-04)**
- **Symptom:** after editing CMS content in the admin dashboard, the site sometimes shows the old content and sometimes the new, depending on the request.
- **Root cause:** `revalidate.js` makes one `fetch()` to the public hostname, and the ALB sends it to one node. Each node has its own Next.js ISR filesystem cache with no shared `cacheHandler`.
- **Proven:** nginx logs on both nodes show every POST landing on exactly one node.
- **Fix options:** (1) a shared Redis or S3 `cacheHandler`; (2) revalidate both nodes' private IPs (needs an SG rule).
- **Status:** open. Infra-only `website-shared-redis` (`10.0.1.92:6379`) exists unused; **no app code exists** (MEM:289).
- **Prompt:** "I edited content in the dashboard but the site still shows the old version sometimes."
- **Cites:** MH:701-703, MEM:245, MEM:289.

**C-14 · Weakness: the revalidate secret falls back to a hardcoded shared string (2026-08-28)**
- **Root cause:** when unset, `VITE_REVALIDATE_SECRET` and `REVALIDATE_SECRET` both fall back to the same string committed in both repos.
- **Status:** open, not blocking.
- **Cites:** MH:433, MEM:63.

**C-15 · Broken CMS images: hardcoded absolute media URLs in CMS content (2026-08-27; root fix 2026-08-28)**
- **Symptom:** logos and banners are broken after a domain or infra change.
- **Root cause:** the CMS stores full absolute URLs in 210 rows across 5 columns in 4 tables. The largest source is `cms_componentitem.url` (122 rows).
- **Debug traps on the way:** a stale Docker build cache (E-12) and ISR were both suspected.
- **Fix:** first, manual SQL after an `information_schema` scan. Now: **use the `rewrite_media_urls` management command** (dry-run by default; `--apply --verify`).
- **Status:** fixed. A fresh prod dump on 2026-08-28 had zero stale rows.
- **If again:** run the systematic scan SQL (MEM:82-89) first, then `rewrite_media_urls`.
- **Prompt:** "Images on the site are broken after the domain change."
- **Cites:** MH:381-387, MH:413-423, MH:475-479, MEM:79-90.

### D. Database and data-handling incidents

**D-01 · Shared Postgres container crash-loops on first start (2026-08-28)**
- **Root cause:** `postgres:15` was started without `POSTGRES_PASSWORD`.
- **Fix:** generated passwords stored in SSM `/dealerpulse/shared/postgres-superuser-password` and `/dealerpulse/shared/ocean-db-password`; recreated the container.
- **Cites:** MH:574.

**D-02 · Restore throws "already exists" errors: an earlier "failed" attempt actually succeeded (2026-08-28)**
- **Root cause:** `docker exec psql` over the Unix socket uses `trust` auth and ignores `PGPASSWORD`. An earlier run that looked failed (empty password from the `$(...)` expansion bug) had already restored the data.
- **Verified:** row counts matched nodeA (cms_component 374, cms_componentitem 1706, 46 tables).
- **Cites:** MH:578, MEM:61.

**D-03 · Decision: `leads_db` refreshed from prod without backing up the AWS-side data (2026-09-02)**
- **Status:** the user chose to proceed without a backup. Any leads captured on AWS before that restore are **not recoverable**.
- **Verified after:** booked_leads 57, audit_logs 147, dealerships 5; `/health` 200.
- **Cites:** MH:657-661.

**D-04 · Orphaned duplicate chat Postgres on integration (found 2026-09-12)**
- **Symptom:** none visible. Wasted memory, and a trap for cleanup commands.
- **Root cause:** `chat_backend-postgres-1` (compose project `chat_backend` instead of `chat_back`) was created 2026-09-10 by unlogged work. It sits on an isolated network, moved about 7 KB in 28 h, and holds a real 114 MB database.
- **Fix:**
  - `docker stop`, approved (MEM:594).
  - Container `docker rm` without `-v` on 2026-09-16 (TODO:253-254).
  - Volume `chat_backend_postgres_data` **kept**: it failed the user's "unused for 3 days" condition (MEM:628).
- **If again:** **never run `docker volume prune` on integration** while that volume exists.
- **Cites:** MH:996-1000, MEM:588, MEM:594, MEM:628, TODO:253-254.

**D-05 · nodeA turned out to be on shared Postgres already (found 2026-09-03)**
- **Status:** the user decided shared Postgres is the source of truth; nodeA's local DB is retired, not merged.
- On 2026-09-12 both nodes' `nisanwebsite_postgres_data` volumes were tarred to `s3://dealerpulse-backups-409289617504/retired-volumes/` and then removed.
- **Cites:** MEM:45, MEM:227, MEM:626.

**D-06 · Postgres `effective_cache_size = 5 GB` on a 3.8 GB box (2026-09-11/12)**
- **Status:** open. It is a one-line change but alters query plans, so it is not zero-impact.
- **Cites:** MH:1004, MEM:435, MEM:590.

### E. Deploy script (`/opt/dealerpulse/deploy.sh`) and CI/CD

**E-01 · Local fixes silently disappear after a deploy: the deploy.sh auto-stash (2026-08-28 → fixed 2026-09-05)**
- **Symptom:** a hand-applied fix (CORS list, DB override) reverts after any deploy.
- **Root cause:** deploy.sh ran `git stash push --include-untracked` on a dirty tree before switching branches, and nothing ever popped the stash. This caused data loss three times (MH:846).
- **Fix [PROD, approved after a classifier block]:** replaced the stash with fail-loud behaviour: print the dirty files and `exit 1`. Applied on all 3 VMs with backups `deploy.sh.bak-<timestamp>` and `bash -n` checks. All 5 repos were confirmed clean first.
- **Status:** fixed.
- **If again:** a deploy failing with a "dirty files" error is the guard working. Commit, discard or move the file. It is not a regression.
- **Prompt:** "Deploy failed saying files are dirty / my config change got reverted."
- **Cites:** MH:529, MH:842-846, MEM:37-39, MEM:203.

**E-02 · Pipeline shows red "Deploy to Node A" but the site is fine: health-check window too short (2026-08-28; 2026-09-04/05)**
- **Symptom:** the Bitbucket deploy step fails while the site keeps working.
- **Root cause:** deploy.sh's health check gave up too early. First a 5 s sleep (`HTTP 000000`), then 6×5 s = 30 s. ocean's cold start (migrate + collectstatic) takes up to about 3 minutes.
- **Fix [PROD]:** a 24×5 s (120 s) retry loop on all 3 VMs (backup `deploy.sh.bak-before-healthcheck-window`).
- **Verified:** the user re-ran the pipeline and both nodes were clean.
- **If again:** check the container logs and a direct health curl before assuming bad code.
- **Prompt:** "The deploy pipeline failed on Node A — is the site broken?"
- **Cites:** MH:534-542, MH:750-756, MEM:275.

**E-03 · Deploying `integrations_service` from a branch changed nothing (2026-09-03)**
- **Symptom:** "I deployed from master but my changes aren't live."
- **Root cause:** its compose `web` service had no `build:`, only a DockerHub image from the legacy pipeline. `up -d --build` is a no-op without `build:`.
- **Fix:** `docker compose pull`. Then all 5 services moved to ECR builds on `main-migrated`.
- **Status:** fixed.
- **Behaviour change (permanent):** deploy.sh now **ignores the branch argument**; it always pulls the ECR image (MEM:223).
- **Cites:** MH:669-675, MEM:223.

**E-04 · The first ECR pipeline run reported success but the containers did not swap (2026-09-03)**
- **Status:** **open and unexplained.** The leading theory is IAM propagation delay. Re-running `docker compose pull && up -d` by hand fixed it.
- **If again:** investigate. Do not just re-run.
- **Cites:** MH:685, MEM:237.

**E-05 · `framework_frontend` deploy fails: `.env not found`, then `Dashboard: command not found` (2026-09-02..05)**
- **Root cause:**
  1. The gitignored `.env` vanished; there is no git trace of why.
  2. deploy.sh sources `.env` as shell, and `VITE_SITE_NAME=Dealer Dashboard` had an unquoted space.
- **Fix:** the user restored the values (writing them was classifier-blocked) and quoted the value.
- **Rule:** quote any `.env` value containing spaces.
- **Cites:** MH:820-824.

**E-06 · Landmine: deploy.sh's `website_frontend` case assumed a single tenant (2026-09-10)**
- **Risk:** deploying Surf City through the existing case would have `docker rm -f`'d Puente Hills' live container.
- **Fix:** a separate `website_frontend_surfcity` case (own container, port 3001, tag `:latest_surfcity`, own log stream).
- **Rule:** every new tenant gets its own case. Never reuse one.
- **Cites:** MH:986, MEM:366, MEM:390.

**E-07 · Bitbucket pipeline won't start or validate (2026-09-03..17, recurring classes)**
- `deployment: <name>` must exist as an environment first, or validation fails with `plan-service.parse.invalid-deployment-name` (MEM:233).
- A deployment environment may appear on only one step per pipeline. The fix used was to drop `deployment:` from node-deploy steps (MEM:388).
- A plain YAML script item containing `": "` is rejected. The reported index can be misleading. Wrap the line in `- |`. PyYAML accepts it but Bitbucket does not (MEM:636, MEM:717).
- `python:3.12-slim` has no `curl`; add an `apt-get install curl` line (MEM:719).
- **Prompt:** "The pipeline won't even start / says invalid YAML."

**E-08 · Legacy pipelines still deploy to the old DigitalOcean droplet (found 2026-09-02)**
- **What happens:** pushes to `master` / `main` / `staging` in the Dealerships repos still build and deploy to the DigitalOcean `prod` droplet.
- **Status:** user decision: leave them as-is until the droplet is decommissioned. Pushing to those branches is **not** inert.
- **Cites:** MH:816-818, MH:840, MH:1533, MEM:176.

**E-09 · `main` / `master` branches are broken (2026-08-28, 2026-09-02)**
- **Root cause:** `framework_frontend`'s `main` has no Dockerfile. `website_frontend`'s `main` Dockerfile copies `/app/dist`, which Next.js never produces.
- **Status:** moot by user decision. **`main-migrated` is the production branch** (MEM:206). Nothing deploys from plain `main`.
- **Cites:** MH:449-453, MH:638-644, MEM:67, MEM:206.

**E-10 · False "healthy" after a failed build (2026-08-28)**
- **Root cause:** in a chained command a failed `docker build` was followed by `docker run`, which restarted the old image and returned 200.
- **Rule:** check the build log for success; a following `docker run` proves nothing.
- **Cites:** MH:451, MEM:67.

**E-11 · Content fix "didn't take": stale Docker layer cache (2026-08-27)**
- **Root cause:** `RUN npm run build` was marked `CACHED` despite different build args.
- **Rule:** use `docker build --pull --no-cache` for `website_frontend` content fixes. (Mostly historical now that CI builds the images.)
- **Cites:** MH:419, MEM:92.

**E-12 · Stopping a Bitbucket run does not cancel an SSM command already dispatched (2026-09-16/17)**
- **Cites:** MEM:727.

**E-13 · Revert pipelines (2026-09-11/16)**
- `revert-surfcity` exists (custom pipeline; `REVERT_SHA`; the tag must exist in ECR). It has passed YAML validation but has never actually been run (MEM:632-640).
- `revert-puentehills` was **cancelled by the user. Do not reintroduce** (MEM:731).

### F. Frontend (`website_frontend` / `framework_frontend`)

**F-01 · Pages half-load / "ChunkLoadError" / random 404s on JS files (2026-09-01, 2026-09-11, 2026-09-16)**
- **Symptom:** a page breaks with a ChunkLoadError or missing scripts, often right after a deploy.
- **Root cause history:**
  - 09-01: each node built its own image, producing different chunk hashes. The fix at the time was ALB stickiness (MEM:35).
  - 09-11: the moving `:latest` tag put the two nodes on different digests. Fixed by pinning both nodes to tag `1ed35a8` and purging the Cloudflare cache (MEM:384).
  - **09-16 (final):** deploy-timing skew. nodeB's deploy was a manual step about 2.5 min after nodeA's, so HTML from one build requested assets from the other. **The Cloudflare static-asset rule then cached the 404.**
- **Fixes [PROD]:**
  - Atomic deploy: one `aws ssm send-command --instance-ids <nodeA> <nodeB>`.
  - Cloudflare `status_code_ttl` forces a 0 TTL on 4xx/5xx.
  - Automatic `purge_everything` after deploy (tokens `CF_API_TOKEN_CALLNOW_US`, `CF_API_TOKEN_PUENTEHILLS`).
- **Verified:** on Surf City, containers were created within 0–1 s of each other and MISS→HIT after a purge.
- **Status:** merged into `main-migrated` (commit `22eb761`) but **not yet exercised on a real Puente Hills deploy** as of 09-17. The fingerprint to check afterwards is the gap in container creation times.
- **Pending:** a non-blocking `ChunkLoadError` reload handler for tabs that were open before a deploy (assigned to Ghulam Ali).
- **If again:** compare `docker inspect` image digests and container creation times on both nodes, and purge Cloudflare.
- **Prompt:** "The site shows broken pages/ChunkLoadError after the deploy."
- **Cites:** MEM:35, MEM:384, MEM:691-735, TEN:93-107.

**F-02 · About half of requests 404 on a newly added hostname (2026-09-01)**
- **Root cause:** nodeA lacked the `phn2`/`api2` vhosts, so the ALB-routed share of traffic landing there 404'd.
- **Rule:** every node needs `server_name` blocks and certs for every hostname the ALB can route to it.
- **Related (09-09):** a missing vhost for a new domain makes nginx fall through to the alphabetically first vhost (`api`), and Django answers 400 (MH:962).
- **Cites:** MEM:31, MH:962.

**F-03 · Wrong dealership name and hatched placeholder banners after building a new node (2026-08-28)**
- **Symptom:** the page title says "Surf City Nissan" on a Puente Hills site, or hero banners show diagonal hatching.
- **Root cause:** `next build` fetches backend data at build time. The backend's HTTPS endpoint didn't exist yet, so the fetch failed softly and fell back to hardcoded defaults (`DEFAULT_SITE_NAME = "Surf City Nissan"` in `utilis/getSiteConfig.ts:8-12`).
- **Fix:** rebuild with `--no-cache` once the backend is live.
- **Rule:** stand up the backend's HTTPS endpoint before building the frontend, and verify `<title>` and branding, not just the HTTP status.
- **Prompt:** "The site shows the wrong dealership name."
- **Cites:** MH:613-621, MEM:59.

**F-04 · Admin dashboard login gives a Django 404 (2026-08-28)**
- **Root cause:** `VITE_API_BASE_URL` lacked `/api/`. It must be `https://api.<host>/api/`.
- **Fix:** rebuilt (from `staging`, since `main` was broken).
- **Prompt:** "Admin login says page not found."
- **Cites:** MH:447-451, MEM:66.

**F-05 · `.env` drift on the nodes (2026-09-02)**
- **Found:**
  - nodeA had stale `NEXT_PUBLIC_API_URL` / `SITE_URL` values pointing at the retired `phn2`/`api2`.
  - nodeB had the typo `gEXT_PUBLIC_XTIME_API_URL`, so the real variable was unset.
  - nodeB's `NEXT_PUBLIC_DEALER700_QUICK_QUALIFY_ID` ended `-g023817` instead of `-2023817`.
- **Fix:** `sed` and redeploy.
- **Status:** **the corrected values were inferred from nodeA and never confirmed** against a source of truth.
- **Cites:** MH:646-655.

**F-06 · False alarm: a build-time variable "missing" on one page (2026-09-02)**
- `NEXT_PUBLIC_DSS_REGISTERED_HREF` renders only on pages with `dssDivId`.
- **Rule:** grep the compiled bundle (`/app/.next/server/chunks/`) before concluding a build is bad.
- **Cites:** MH:644.

**F-07 · The frontend requests the literal "null" page slug (2026-09-10 → open)**
- **Symptom:** none for visitors directly. It feeds load bursts, 404 noise and hairpin traffic.
- **Volume:** about 6,152–13,545 requests/day; 242 per 30 minutes measured 09-16; about 4% of traffic.
- **Root cause:** `getCmsPageFetcher` in `utilis/createPageMetadata.ts` guards the dealership ID but not the slug.
- **Fix history:** a fix (`0ce4a55`) was merged then reverted (`9a0ee99`) around the 09-11 ChunkLoadError incident. The revert was likely mistaken (TEN:212-215).
- **Status:** open (TODO item 3).
- **Cites:** MH:1064, MH:1309-1317, MEM:353, MEM:428, MEM:546, TEN:188-189, TODO:162-164.

**F-08 · Some old links take minutes to load: legacy `.htm` URLs fall through to SSR (2026-09-17)**
- **Symptom:** old bookmarked or search links such as `/new-inventory/index.htm` hang 11–128 s on average and up to 350 s before redirecting.
- **Root cause:** `next.config.ts`'s `LEGACY_REDIRECTS` (fast 308s, 0.027 s) lists bare paths, not their `.htm` / `index.htm` variants. Those land in catch-all SSR, which fetches the page, components and galleries (1,603 CMS calls/day, each through the hairpin) and then issues a 307.
- **Fix proposed:** add the `.htm` variants; add a catch-all `*.htm` redirect; resolve the slug first and bail out on 404.
- **Status:** open (TODO 3a). A real but **minor** contributor to the latency alarm (C-11).
- **Prompt:** "Old links to the dealership site are extremely slow."
- **Cites:** MH:1403-1521, TODO:119-152.

**F-09 · Static assets routed into the pages API; `payment-calculator` 404s (2026-09-16)**
- **Volume:** `meta.json`, `favicon.ico` and apple-touch icons are requested against `/api/public/pages/`. `payment-calculator` gets 78 404s per 30 minutes; it may be genuinely missing CMS content.
- **Status:** open.
- **Cites:** MH:1314-1317, TODO:165-169.

**F-10 · SSR "hairpin": the site calls its own API through the public internet (2026-09-14 → open)**
- **Root cause:** the frontend reaches the backend through the public hostname, so every SSR fetch goes out to Cloudflare and back in through the ALB.
- **Scale:** about half of ALB `RequestCount`; 27% of nodeA requests carry the User-Agent `node`. It amplifies scanners and dead URLs, pollutes the 5xx metrics, and consumes the 12 gunicorn slots.
- **Fix:** point the frontend at the internal network (2–4 h), **then** re-tighten the alarms. That order matters because the alarm denominator halves.
- **Status:** open (TODO item 5).
- **Cites:** MH:1102, MH:1110, MH:1122, MH:1221, MH:1447-1451, MEM:430, TODO:190-199.

**F-11 · Vehicle photos load slowly: the Next.js image optimizer (2026-09-17 → open)**
- **Symptom:** vehicle galleries take 5–20 s. This is 83% of all slow requests (833 of about 1,000 in 11 h).
- **Root cause:** `next.config.ts:112-117` asks for AVIF (the most expensive encode) and widths up to 1920 on 1280-wide HomeNet sources. The 20 s tail comes from concurrency: whole galleries queueing at once. A single cold image costs only about 2–3 s.
- **Fix proposed:** drop `image/avif`; remove 1920 from `deviceSizes`.
- **Do not "fix":** Cloudflare image caching, `minimumCacheTTL` and the origin cache all work.
- **Related history:** nodeA logged 54 504s on `/_next/image` on 09-12, triggered by the session's own heavy log scans on a credit-starved node (MH:1060-1062). Run diagnostics as single targeted passes.
- **Prompt:** "Car photos on the inventory page load really slowly."
- **Cites:** MH:1626-1650, TODO:332-363.

**F-12 · Vehicle detail pages take about 20 s on a cold cache (2026-09-16/17)**
- **Detail:** the page is blocked on its own `/api/homenet/inventory/<VIN>/` call. Likely cold JD Power enrichment.
- **Status:** open, investigation needed.
- **Cites:** MH:1415-1420, TODO:154-160.

**F-13 · Inventory filter interactions trigger repeated requests (CR-4, partly fixed by 2026-09-15)**
- **Still open:** `getInventoryFilterOptions` and `getAssociateDealerships` use `keepUnusedDataFor: 0`, and `filterOptionsRefreshKey` is bound to the whole query string (`InventoryPageContent.tsx:241`).
- **Cites:** MEM:545, INV:216-225.

### G. nginx, rate limiting, TLS and certificates

**G-01 · Slow pages from no compression and HTTP/1.1 (2026-08-28)**
- **Root cause:** `gzip on` without `gzip_types` (so only HTML was compressed); no HTTP/2; nginx 1.24 needs the inline `listen 443 ssl http2`.
- **Fix [PROD]:** gzip_types, TLS session cache, HTTP/2 on all vhosts, `static_cache` zone (backups `*.bak-before-perf`).
- **Related:** nodeB's gzip was later found to be a commented-out stub and was aligned 2026-09-02 (MH:806).
- **Cites:** MH:494-517, MH:806.

**G-02 · Rate limiting silently non-functional behind the ALB (found 2026-09-01)**
- **Root cause:** no `real_ip`, so every visitor shared the ALB's IP bucket. The first fix trusted only the VPC CIDR, so logs then showed Cloudflare edge IPs.
- **Fix [PROD]:** `set_real_ip_from 10.0.0.0/16` plus all 22 Cloudflare CIDRs, `real_ip_header X-Forwarded-For`, `real_ip_recursive on` on all 3 VMs.
- **Verified:** after cache-busting, a 100-request burst got about 30 rejections.
- **Rule:** list every proxy hop's range in `set_real_ip_from`.
- **Cites:** MEM:146-152.

**G-03 · Rate-limit rejections look like outages: 503 instead of 429 (2026-09-02; 2026-09-16)**
- **Fix:** `limit_req_status 429;` on all 3 VMs (2026-09-02). `limit_conn_status 429;` on nodeA and nodeB (2026-09-16).
- **Note:** 503 passes through Cloudflare unchanged.
- **Cites:** MH:805, MEM:154, MEM:171, MEM:495, MH:1383, TODO:242.

**G-04 · QA testers getting 429 "Too Many Requests" (2026-09-02)**
- **Fix [PROD, exact numbers approved by the user]:** `burst=60` first, then `rate=50r/s`, `burst=150` on all site configs on all 3 VMs.
- **Status:** **open:** revisit after QA; these values were raised for testing convenience.
- **Prompt:** "Testers are getting 'too many requests' errors."
- **Cites:** MH:832-836, MEM:186, MEM:195.

**G-05 · "Site is down / not accessible" for a visitor: `limit_conn 60` vs Next.js prefetch (2026-09-08 → fixed 2026-09-11)**
- **Symptom:** a visitor reports the site unreachable; ALB 5xx rises. Reported for IP 50.216.9.124.
- **Root cause:** one page load fires dozens of concurrent `?_rsc=` link prefetches from one IP, exceeding `limit_conn conn 60`. nginx then returned 503 because `limit_conn_status` was unset.
- **Detected:** the nginx error log says `limiting connections by zone "conn"`. The app logs show no 5xx.
- **Fix [PROD]:** raised to 300 on all 4 live vhosts on nodeA and nodeB, plus a `map $arg__rsc $frontend_conn_key` that exempts `_rsc` prefetches (the durable fix, author unrecorded); then `limit_conn_status 429` (09-16).
- **Verified:** zero `limiting connections` events since 2026-09-11 00:02.
- **Status:** fixed on nodeA and nodeB. **The integration VM is still at `limit_conn conn 20` with no `_rsc` map** (open).
- **If again:** check the error log for "limiting connections" over SSM. The third party's Cloudflare WAF is not visible to us.
- **Prompt:** "A customer says the site is down for them."
- **Cites:** MH:1026-1046, MEM:386, MEM:473-496, TEN:40-44.

**G-06 · Latent "too many open files" ceiling (2026-09-12)**
- **Fix [PROD, approved, staged nodeA then nodeB]:** `worker_rlimit_nofile 8192;` plus a systemd drop-in `LimitNOFILE=16384`. The drop-in applies to the master process at the next nginx restart.
- **Rollback:** `nginx.conf.bak-before-rlimit-*`.
- **Status:** done on nodeA and nodeB. **Integration is unchanged** (soft limit 1024).
- **Symptom to watch for:** `Too many open files` (capital T) in the error log.
- **Cites:** MEM:496-520.

**G-07 · Landmine: nodeB's `api` vhost pointed at a cert directory that didn't exist (found 2026-09-04)**
- **Risk:** any fresh nginx start on nodeB would have failed.
- **Fix:** repointed the vhost. On 09-08 `api` got its own cert on nodeB and the combined cert was retired.
- **Cites:** MH:730, MH:936-938, MEM:259, MEM:317.

**G-08 · nodeB `nginx -t` failed: missing `static_cache` zone (2026-09-09)**
- **Root cause:** nodeB's nginx.conf never had the `proxy_cache_path` that nodeA had.
- **Fix:** added it. A `sed` escape had mangled into a literal `t`; `nginx -t` caught it.
- **Cites:** MH:964, MEM:333.

**G-09 · Backend-down errors show a CORS block in the browser (gateway-down handler, 2026-09-04)**
- **Fix [PROD-user]:** `proxy_intercept_errors` plus `@gateway_down` (204 for OPTIONS, 502 JSON otherwise) on the `api` vhost, with a `map` in `/etc/nginx/conf.d/cors-gateway-down-map.conf`.
- **Bug found by a live-fire test:** two `Content-Type` headers. Fixed with `default_type application/json;` (`add_header` only adds).
- **Status:** **Cloudflare replaces origin 502s with its own page**, so the frontend still sees a CORS block. The fix (502→503 plus frontend `GATEWAY_DOWN_STATUSES`) was **declined by the user**; the frontend degrades gracefully.
- **Cites:** MH:717-736, MEM:253-267.

**G-10 · Images or iframes blocked by the Content-Security-Policy (2026-09-04/05)**
- **Symptom:** S3 product images are blocked (`media-src` unset); later every third-party widget iframe broke (TradePending trade-in, AutoAPR, 700Dealer, Sunbit, Google Maps, CMS map and consent banner).
- **Fix [PROD-user]:**
  - Built a report endpoint `POST /api/csp-report/` (logger `csp.violations`).
  - Added `media-src 'self' https://dealerpulse-media-409289617504.s3.us-west-2.amazonaws.com` and `report-uri`.
  - Flipped to enforcing.
  - Added `frame-src 'self' https:` (broad on purpose).
  - The directive appears twice per file (server and location level).
- **Verified:** headers, reload timing, and no new violations after 30 minutes. Real-browser confirmation was pending.
- **If again:** `docker compose logs web | grep csp-violation`.
- **Prompt:** "A widget/iframe on the site is blank."
- **Out of scope:** `starfish.omnipulse.cc` CORS failures (a third party).
- **Cites:** MH:740-792, MEM:273-279.

**G-11 · Certificate renewal never worked (found 2026-09-07)**
- **Root cause:**
  - nodeA (HTTP-01): the Cloudflare country-block WAF blocked Let's Encrypt validators, and certbot's nginx plugin couldn't inject into the customised vhosts.
  - nodeB: a manual DNS-01 hook needed a human.
- **Fix [PROD]:**
  - A Cloudflare path exception for `/.well-known/acme-challenge/*`.
  - Switched to `certbot-dns-cloudflare` with a zone-scoped token in SSM `/dealerpulse/shared/cloudflare-dns-token`.
  - `--force-renewal`, matching each node's cert shape.
- **Verified:** `certbot renew --dry-run` reports "all simulated renewals succeeded" on both nodes. Integration's simpler vhosts were already fine (MEM:297).
- **Cites:** MH:866-892, MEM:293-297.

**G-12 · Design: self-signed origin certificates (2026-09-07/08)**
- **Fact:** `phn`, `www.puentehillsnissan.com` and `surfcity` use a self-signed cert at `/etc/nginx/selfsigned-test/phn-test.{crt,key}`.
- **Why it is safe:** the ALB doesn't validate target certs, and Cloudflare SSL mode is "Full". Proven with real traffic.
- **It breaks if:** Cloudflare is ever set to "Full (strict)".
- **Not a mistake.** Only the `api` vhost uses a real Let's Encrypt cert (`api-only.callingyounow.us`).
- **Cites:** MH:924-946, MEM:315-321, TEN:72.

**G-13 · nginx access log could not tell which site or how slow (found 2026-09-12; fixed 2026-09-16)**
- **Fix:** a `combined_host` log format with `host=` and `rt=` appended, so existing parsers keep working.
- **Cites:** MH:1042-1050, MH:1383, TODO:243-246.

### H. ALB, target groups, security groups and health checks

**H-01 · A node reachable directly despite the lockdown (2026-09-01)**
- **Root cause:** nodeA still had the old `sg-backend` attached; AWS unions all security groups on an instance.
- **Fix:** removed `sg-backend`.
- **If again:** run `describe-instances … SecurityGroups` first.
- **Cites:** MEM:26.

**H-02 · Design gotcha: the ALB cannot reach the containers directly (2026-09-01)**
- Container ports are bound to loopback only (`127.0.0.1:9000/3000`). The ALB targets nginx on 443.
- **Cites:** MEM:19, MEM:31.

**H-03 · The ALB health check is effectively a no-op (2026-09-12 → open)**
- **Detail:** `GET /` with a bare-IP Host gets 400 from Django, which counts as healthy under the `200-499` matcher. It writes about 16,000 junk log lines per node per day.
- **Do not flip the matcher to 200:** no path returns 200 (`/`, `/healthz` and `/health` return 400; `/api/health/` returns 428), so it would take the site down.
- **Rejected:** a static nginx `/healthz`.
- **Fix needed:** a Django health endpoint.
- **Status:** open (TODO item 2).
- **Cites:** MH:1064, MH:1108, MH:1389-1392, TODO:89-110.

**H-04 · Listener change silently blinded the alarms (2026-09-14)**
- **Symptom:** `dealerpulse-frontend-unhealthy-targets` fired (a false positive), while the 5xx alarms sat at OK on stale data.
- **Root cause:** a `ModifyListener` repointed the 443 listener to the weighted `dealerpulse-tg-nodea` (35) / `-nodeb` (65). The alarms were dimensioned on the now-detached `dealerpulse-tg-nginx`.
- **Fix:** rebuilt the whole alarm set (L-04).
- **Rule:** dimension site-wide alarms and queries on LoadBalancer only.
- **Cites:** MH:1142-1172, MEM:571.

**H-05 · ALB stickiness: believed necessary, actually never functional (2026-09-01 → removed 2026-09-16)**
- See C-5.
- **Rule:** do not re-enable it "to be safe". Removal order: target-group attributes first, then the listener `TargetGroupStickinessConfig`.
- **Cites:** MH:1321-1356, MEM:664-670, TODO:379-384.

**H-06 · Decision: keep the detached `dealerpulse-tg-nginx`**
- It is the instant-rollback path; the user's request to delete it was declined with reasons.
- **Cites:** MH:1138, MEM:569.

### I. Cloudflare edge

**I-01 · Cloudflare not caching anything on the new domain (2026-09-10)**
- **Root cause:** ALB `Set-Cookie` headers prevent caching. The `http_response_cache_settings` phase with `strip_set_cookie` was missing on `puentehillsnissan.com`.
- **Fix:** created it.
- **Verified:** `cf-cache-status: HIT`.
- **Known difference:** static TTL is 24 h here vs. 30 days on `phn`, not reconciled.
- **Cites:** MH:978, MEM:345.

**I-02 · `puentehillsnissan.com` cutover problems, in order (2026-09-09/10)**
1. **Unproxied DNS was blocked by the Cloudflare-only SG.** A temporary `0.0.0.0/0:443` rule was added [PROD-user] and reverted once proxying was on.
2. **TLS mismatch.** Attached the already-issued ACM cert via SNI.
3. **Django 400.** No vhost existed; built one.
4. **nodeB `nginx -t`.** See G-08.
5. **Redirect loop.** Cloudflare SSL was "Flexible"; it resolved within minutes.

Afterwards: rebuilt with the new `NEXT_PUBLIC_SITE_URL`, and set up a 301 from `phn.callingyounow.us` to the new domain on our zone.

- **If a redirect loop appears:** check the Cloudflare SSL mode first.
- **Cites:** MH:950-976, MEM:333-339.

**I-03 · `.php` scanner page triggered the 5xx alarm (2026-09-14)**
- **Symptom:** a "frontend 5xx elevated" alert for six minutes.
- **Root cause:** a scanner probing `.php` paths. Each probe triggered SSR plus 8–10 hairpinned API calls, and 11 transient 500s followed (cause unprovable, see C-06). The earlier guess (`limit_conn` 503s) was wrong.
- **Fix:** alarm redesign (L-04).
- **Open:** block or challenge `.php` at Cloudflare. See C-1 about the scanner IP.
- **Cites:** MH:1080-1110.

**I-04 · Prototype-pollution probe traffic returning 200 (2026-09-05)**
- **Status:** not investigated.
- **Cites:** MEM:287.

### J. Inventory performance (HomeNet / Redis)

**J-01 · Inventory pages slow despite pagination (2026-09-11/12 → mostly fixed 2026-09-15)**
- **Root causes:**
  - (CR-2) The request path read Redis db0 under a key without `dealership_id`; the cron wrote db2/6/11/12. Introduced by commit `703f716`.
  - (CR-1) `build_frontend_filter_payload` took about 85% of `filter-options` time (about 3 s).
  - (CR-3) `is_multiple=True` on all four tenants loads 27.6 MB / 1,274 rows per request.
- **Fix:** the dev team shipped commit `1334574` per the requirements doc.
  - `filter_options` went from about 3 s to 21–48 ms.
  - db0 copy gone; per-VIN keys; params no longer taken from the query string; slim list responses.
- **Verified:** on deployed containers on both nodes.
- **Still open:** CR-3 (a product question), CR-4 (frontend, F-13), Redis `maxmemory`.
- **Corrections recorded:** filtering, sorting and JD Power are cheap; the 500 seen in testing was an `APIRequestFactory` artifact.
- **Cites:** MEM:406-471, MEM:522-548, INV:1-322.

**J-02 · Inventory stalls 17–53 s about every 2 hours: HomeNet cache stampede (2026-09-17 → open; the main driver of the latency alarm)**
- **Symptom:** a few times a day inventory or VIN pages hang, and the p99 latency alarm fires.
- **Root cause:** the cache TTL is 7200 s, but the warm cron runs at 01, 15 and 20 UTC (gaps of 14 h, 5 h and 5 h). There is no single-flight lock, so every concurrent miss makes a SOAP call.
- **Proven by timing:** spikes every 2 h; absent exactly at 15:00 and 21:00.
- **Additional finding (cache poisoning):** the request-path fallback writes a degraded blob without per-VIN or dropdown keys and with a fresh 2 h TTL. Result: 5–9x slower for about 12 h a day.
- **The user confirmed 3x/day warming is a business requirement.**
- **Fix:**
  - Raise `HOMENET_CACHE_TTL_SECONDS` to 72000.
  - **Ordering trap:** env change → restart → **immediately** force `refresh_homenet_inventory_cache`. Otherwise a degraded entry gets a 20 h lease.
  - Add a cache-age alarm off `sync_meta.refreshed_at`.
  - Single-flight and serve-stale is the durable fix.
- **Dead config:** `HOMENET_CACHE_REFRESH_SECONDS=3600`.
- **Status:** open, no prod change. See C-9 for the conflict with TODO fix 1.
- **Prompt:** "The latency alarm keeps firing / inventory is slow every couple of hours."
- **Cites:** MH:1543-1662, MH:1684-1809, TODO:261-328.

**J-03 · "No vehicles found" when HomeNet is slow at cache expiry**
- **Root cause:** on a fetch exception, the miss path returns an empty list.
- **Cites:** INV:183-193.

**J-04 · Homepage time-to-first-byte about 1.7 s; public CMS views uncached (2026-09-04/05)**
- **Plan agreed, not implemented:** per-dealership content-version cache for the `Public*` views and `PublicSiteConfigView`.
- **Cites:** MEM:210-214.

### K. Capacity and host resources

**K-01 · nodeA CPU credits exhausted (2026-09-12/14)**
- **Detail:** credits at 0 with surplus being billed (not throttling, see C-7).
- **Mitigation [PROD]:** per-node target groups weighted 35/65 toward nodeB (2026-09-14).
- **Real cause:** netdata (K-02).
- **Status:** credits recovered 3→358.
- **Rule:** judge sizing by CPU credit balance and memory, never CPU average alone (MEM:331).
- **Cites:** MH:1056-1058, MH:1130-1140, MEM:323-331, MEM:673.

**K-02 · Docker daemons burning about 30% of a CPU core: netdata (2026-09-12 → removed 2026-09-15)**
- **Proof:** a before/after test: `dockerd`+`containerd` went 33%→0% on nodeA and 30%→0% on nodeB.
- **Scope incident:** an agent purged netdata on **both** nodes before the user's message requiring individual approval per host arrived. That produced the standing rule in CLAUDE.md §3.
- **Integration VM:** netdata was claimed to Netdata Cloud and listened on `0.0.0.0:19999` with `ufw` off. It was removed 2026-09-12; the archive is at `/opt/dealerpulse/backups/netdata-config-20260912.tar.gz`.
- **If someone asks why their Netdata Cloud node went offline:** this is why.
- **Cites:** MH:1010-1024, MH:1078, MH:1229-1243, MH:1274-1293, MEM:606-610.

**K-03 · Integration VM memory-starved and swapping: a single point of failure (2026-09-11 → open)**
- **Detail:** 3.8 GB, about 764 MB–1 GB of swap, zero CPU credits at times. It hosts the shared Postgres for both nodes plus 3 more databases plus `chat_back-web` (979 MB). `dockerd` holds about 431 MB.
- **Rejected:** `swapoff`/`swapon` (OOM risk to Postgres). Don't tune swappiness (already 10).
- **Pending:** enable `live-restore` before any daemon restart; reboot (two kernels behind); resize, which was **deferred, not rejected**.
- **Triage technique:** use cgroup `memory.stat` `anon` vs `file`, not `systemd-cgtop` (MEM:612).
- **Cites:** MH:992-1008, MH:1219, MH:1247, MH:1397-1399, MEM:590, MEM:596, MEM:614, TODO:216-227.

**K-04 · Nightly docker-cleanup cron is a silent no-op on nodeA and nodeB (2026-09-12)**
- **Root cause:** under the containerd snapshotter, `until=48h` matches nothing (6.7 GB accumulated).
- **Mistake on the way:** `prune -a` deleted rollback pin `website-frontend:1ed35a8` (still in ECR).
- **Rule:** use dangling-only `docker image prune -f`.
- **Status:** the cron change needs a decision; it is not recorded as applied.
- **Cites:** MEM:598, MEM:616-620.

**K-05 · Pending reboots on all three VMs (2026-09-15 → open)**
- `LimitNOFILE` and `daemon.json` log rotation (50m × 3) only take effect after a restart.
- **Cites:** MEM:578, TODO:216-227, TODO:256-257.

**K-06 · Redis has no memory cap or eviction (2026-09-11 → open)**
- **Detail:** `maxmemory 0` and `noeviction`. A warm write would fail silently under pressure.
- **Fix:** must be `volatile-lru`, not `allkeys-lru`, because Redis is also the Celery broker.
- **Cites:** MEM:432, MH:1221, MH:1749-1752.

**K-07 · October launch of 4 tenants: capacity not sized (2026-09-15 → open)**
- Two more frontend containers per node.
- **Cites:** MH:1196-1227, TEN:155-176.

### L. Observability (CloudWatch logs, metrics and alarms)

**L-01 · No central logs (2026-09-05 → built)**
- **What was built:** 9 log groups (nginx via the CloudWatch agent; containers via the `awslogs` driver).
- **Trap:** a `logging:` block in compose is dead code for `website_frontend` and `framework_frontend`, which use raw `docker run`. The flags had to go into deploy.sh [PROD-user].
- **Stray log groups** `0` and `197121` were deleted 2026-09-06.
- **Cites:** MH:850-862, MEM:196-200, MEM:281-291.

**L-02 · nginx logs silently stop arriving in CloudWatch (2026-09-10; 2026-09-14 → 26 h outage, repaired 09-15/16)**
- **Symptom:** nginx log panels are empty while the app logs are fine.
- **Root cause:**
  - 09-10: the console "Configure CloudWatch Agent" wizard (`-multi-config remove`) wiped the logs config; the `cwagent` user was also not in group `adm` (permission denied).
  - 09-14 17:51: a `fetch-config -c file:` metrics config overwrote the logs config in `amazon-cloudwatch-agent.d/`.
- **Fix [PROD]:**
  - Restored as a separate file (`dealerpulse-nginx-logs.json`) in `.d/`.
  - `usermod -a -G adm cwagent`.
  - Later a single merged logs+metrics config with `timestamp_format`.
- **If again:** list `amazon-cloudwatch-agent.d/` and grep the generated YAML for nginx. "Agent active" proves nothing. App logs use a separate path.
- **Prompt:** "The nginx log panels in CloudWatch are empty."
- **Cites:** MEM:359-360, MH:1295-1305, TODO:406-408.

**L-03 · No memory metrics: agent lacked `cloudwatch:PutMetricData` (2026-09-14 → fixed 2026-09-15)**
- **Detected:** the agent log showed AccessDenied (retry 1,446).
- **Fix [PROD-user]:** inline policy `dealerpulse-cloudwatch-metrics-write`, conditioned on namespace `CWAgent` (policy file `records/Migration/cwagent-putmetricdata.json`).
- **False diagnosis to avoid:** IAM propagation took about 3 minutes. Don't "fix" a just-attached conditioned policy; wait.
- **Ignore:** the stray metric `claude_permission_probe`.
- **Cites:** MH:1253-1272.

**L-04 · Alarm noise and blindness (2026-09-14)**
- **Before:** the old count-based 5xx alarm paged on one bad minute.
- **Replacement:**
  - Gated-rate alarms `dealerpulse-alb-5xx-rate-fast` / `-burn` (LoadBalancer dimension).
  - Per-node health alarms with `breaching` on missing data.
  - CPU-credit alarms and a p99 latency alarm.
- **Measuring showed two thresholds sat below normal behaviour, so they were loosened:**
  - latency 3 s → 8 s
  - credits <30 → <10 over 30 min
  - 5xx 5%/2% → 10%/5%
  - health 3 of 3
- **Status:** current. Re-tighten after the hairpin fix. **Don't retune the latency alarm to silence it;** it is reporting real problems (J-02, F-11).
- **Cites:** MH:1112-1124, MH:1156-1186, MH:1662, TODO:18.

**L-05 · No memory or swap alarm on integration (open, TODO item 1)**
- Proposed: `swap_used_percent >= 60` and `mem_available < 300 MB`, damped.
- **Cites:** TODO:80-85.

**L-06 · fd-exhaustion alarm missing**
- See C-4.
- **Rule:** always `test-metric-filter` a pattern; the patterns are case-sensitive (MEM:516).

---

## PART 2 — Operational gotchas and rules learned

**Windows, CLI and SSM**
1. `aws.exe` may not be on PATH in tool shells opened before the install. Use its full path, typically `C:\Program Files\Amazon\AWSCLIV2\aws.exe` or
   `%LOCALAPPDATA%\Programs\Amazon\AWSCLIV2\aws.exe` for a per-user install (MH:70-78, MEM:15).
2. Git Bash (MSYS) mangles any argument starting with `/` (`file://`, `/dealerpulse/...` log groups, SSM parameter names). Use PowerShell or `export MSYS_NO_PATHCONV=1` (MH:97, MH:147, MH:562, MEM:31, MEM:134, MEM:283).
3. PowerShell `Set-Content -Encoding utf8` writes a BOM, which gives `MalformedPolicyDocument`. Write with `[System.IO.File]::WriteAllText(path, content, (New-Object System.Text.UTF8Encoding $false))` (MH:97).
4. **`aws ssm send-command --parameters commands="[...]"` containing `$(...)` is expanded locally and silently sends empty values.** Always write a JSON file and pass `--parameters file://...` (MH:488, MH:576, MEM:55).
5. Arguments with embedded quotes get mangled in PowerShell. Use `--cli-input-json file://...` (MEM:518).
6. Multi-line scripts over SSM: base64-encoding worked early on (MH:286, MH:523), but base64 payloads were later **blocked by the classifier**. Send plain readable commands (MEM:592).
7. Go-template `--format` strings fail inside the SSM JSON. Use plain `docker ps` and filter locally (MEM:592).
8. The CLI crashes on non-ASCII output (`charmap`). Pipe through `tr -cd "\11\12\15\40-\176"` on the remote side (MEM:604).
9. Authentication is `aws login` (browser). A session expiry needs the user (MH:236, MH:1084, MEM:116).
10. Some SSM reads were blocked via Bash but worked unchanged via PowerShell (MEM:347, MEM:441).
11. **Classifier:** after the first denial do not retry or reword (CLAUDE.md §5). Credential creation, IAM grants, `Set-ExecutionPolicy`, raw secrets in commands, and moving private keys between boxes are all blocked. Generate a fresh deploy key per box instead (MH:407, MH:814, MH:830, MEM:96, MEM:249).
12. A heredoc pasted into an interactive SSM session garbles the echoed output; the file itself may be fine. Prefer single-line `sed` or `tee` (MH:768, MH:858).
13. SSM shells don't load the deploy key. Set `GIT_SSH_COMMAND` (MH:441, MEM:63).
14. `docker ps` needs `sudo` for `ssm-user` (MH:306).
15. `systemctl is-active amazon-ssm-agent` reports `inactive`, which is false. It runs as a snap unit (MEM:582).
16. `hostnamectl` silently strips underscores. `echo -e` under the SSM `sh` writes a literal `-e`; use `printf` (MH:828).
17. Monitor polling: query `StandardOutputContent` separately (MEM:122). Arithmetic `$((...))` in a poll script produced a false positive (MH:240).
18. `printenv | grep PREFIX` leaked secrets into the transcript. Grep exact variable names, and verify that any redaction actually redacts (MEM:249, MEM:441).

**Docker, Compose and deploy**

19. A new `.env` variable needs `docker compose up -d --no-deps`, never `restart` (MH:709).
20. Always pass `--no-deps` for ocean; the hardcoded `HOST: db` overrides `.env` (MH:584-586).
21. ocean's compose project is `nisanwebsite` (containers `nisanwebsite-*`) (MEM:45).
22. The `website_frontend` and `framework_frontend` cases run raw `docker run`, not compose (MH:858, MEM:695).
23. **Untracked files in deploy.sh-managed repos are fragile.** The guard now fails loudly; run `git stash list` when config looks reverted (MEM:39).
24. deploy.sh ignores the branch argument since the ECR migration (MEM:223).
25. A first `curl` right after a slow entrypoint returns 000. Retry before calling it broken (MH:330, MEM:128).
26. Use dangling-only `docker image prune -f` on nodeA and nodeB. **Never run `docker volume prune` on integration** (MEM:594, MEM:620).
27. Deploy `website_frontend` to both nodes in one swap. Don't use a moving `:latest` during iteration; pin the SHA tag (MEM:384, MEM:702).
28. Pipeline changes: prove them on `main-surfcity` first, then merge to `main-migrated` (MEM:715).
29. Bitbucket API: UUIDs contain `{}`, so use `curl --globoff` (MEM:231).

**nginx, TLS and the ALB**

30. **Every node needs a vhost and cert for every hostname the ALB can route to it** (MEM:31, MH:962).
31. Verify a reload took: nginx worker start time later than the config mtime (MH:736).
32. `add_header` doesn't replace a `return`'s Content-Type; use `default_type` (MH:732).
33. `add_header` sets don't merge across the server/location boundary, so the CSP is repeated (MH:760).
34. `set_real_ip_from` must list every hop: the VPC plus Cloudflare (MEM:150).
35. `map` directives must sit in `http`/`conf.d`, not inside `server` (MH:728).
36. nginx 1.24 needs the inline `listen 443 ssl http2` (MH:498).
37. When changing SG rules on live paths, add the new rule before revoking the old one (MEM:31).
38. `--matcher HttpCode=200,428` is mis-parsed. Use JSON `'{"HttpCode":"200,428"}'` (MEM:31).
39. Certbot DNS-01 used to need a manual-auth-hook file plus a "go" signal file pattern (MEM:33). It is now superseded by `certbot-dns-cloudflare` with a zone-scoped token from SSM (MH:884-886).
40. Check origin certificates over SSM. The public domain only shows Cloudflare's edge cert (MH:890).
41. nodeA has two certs; nodeB had one combined SAN cert. Don't assume the nodes are symmetric (MH:890, MH:938).
42. Removing stickiness: target-group attributes first, then the listener config (MEM:665).

**Cloudflare**

43. `curl -I` sends HEAD, which always shows `DYNAMIC`. Use a GET: `curl -s -o /dev/null -D -` (MEM:349).
44. `Set-Cookie` blocks caching. The response phase needs `strip_set_cookie` (MEM:345).
45. Cloudflare replaces origin 500/502/504/52x pages; 503 passes through (MEM:267, MEM:495).
46. Cache-rule PUTs are full replacements. Resubmit every rule (MEM:375, MEM:390).
47. Mint zone-scoped tokens; account-wide grants are blocked. Tokens saved earlier may be stale (MEM:295, MEM:347).
48. The Free plan has only `purge_everything` (MEM:721).
49. Bust the cache with a random query parameter to reach the origin (MH:1086).

**CloudWatch**

50. A console wizard or `fetch-config file:` can overwrite the logs config (L-02). `cwagent` must be in group `adm` (MEM:359).
51. Metric-filter patterns are case-sensitive. Always `test-metric-filter` (MEM:516).
52. `describe-log-streams` and `storedBytes` lag. Use `filter-log-events` to confirm ingestion (TODO:374-376, MEM:283).
53. Query site-wide metrics on the LoadBalancer dimension only (MEM:571).
54. Logs Insights bills per GB scanned. Keep time ranges short (TODO:377).
55. Timestamps: nginx is UTC and container text is `+0500`. Mixing them in one grep returns nothing (MH:1110, TODO:369-373).
56. Chatbot logs live in us-east-1, and the app shows as "Amazon Q" in Slack (MEM:114).
57. IAM changes take minutes to propagate (MH:1270).

**Data**

58. Postgres socket connections use `trust` auth (MEM:61).
59. `pg_restore` must use `--no-owner`. The ownership fix is a `DO` block; `REASSIGN OWNED` doesn't work for `postgres` (MEM:229).
60. ocean's DB env var names are `DATABASE_NAME`, `DATABASE_USER`, `PASSWORD` and `HOST` (MEM:53).
61. Tenants resolve by `?dealership_id=`, not the Host header (MEM:51).

**Diagnostics discipline**

62. Heavy log scans on a credit-starved node cause 504s. Use targeted single passes (MH:1060-1062).
63. A "node is dead / zero traffic" conclusion came from a bug in the analysis's own output filter. Cross-check request counts on both nodes (MEM:437).
64. `APIRequestFactory` produces a `testserver` 500, which is a test artifact (MEM:470).
65. `/api/` returning `428 Encrypted transport required` is normal. A WebSocket probe returning 403 is app authentication (MH:463, MH:515).
66. The AWS groundwork APIs have quirks; see MH:93, MH:143-146 and MH:180:
    - SG `GroupName` can't start with `sg-`.
    - DLM rejects commas and colons.
    - Cost Anomaly over SNS needs `IMMEDIATE`.
    - `SSM-SessionManagerRunShell` needs `create-document`.
    - Chatbot tags use `TagKey`/`TagValue` separated by spaces.
    - Cost Explorer needs about 24 h after enabling (MH:218).
67. Grep this file's whole history for a resource before treating a finding as new (MEM:554).

---

## PART 3 — User decisions that must not be reversed without asking

1. **Never rename `dealerpulse-*` resources.** Don't touch the `Project=dealerpulse` tag or the `dealerpulse` chat DB name. Leave `COMMAND_LOG.md` verbatim (MH:3, MH:1664-1678).
2. Infrastructure is raw AWS CLI, no IaC. Log every command to `COMMAND_LOG.md` and every session to `MIGRATION_HISTORY.md` (MH:62-63, MEM:100).
3. **Redis stays per-node.** Shared Redis and RedBeat were declined, accepting duplicate sold-inventory rows and cache skew (MH:348-350, MEM:29).
4. Postgres is a self-hosted container colocated on the integration VM, not RDS (MH:354-355).
5. The media bucket is public-read with no CloudFront for now (MH:395).
6. The admin dashboard runs as a container on the integration VM. S3+CloudFront is deferred (MH:437, MEM:63).
7. Slack alerting goes through Chatbot, not a Lambda relay (MH:170).
8. Shared Postgres is the source of truth. nodeA's old local DB was retired, not merged (MEM:45, MEM:227).
9. `leads_db` was overwritten without a backup, historically (MH:659).
10. **Legacy DigitalOcean pipelines stay as-is** until the droplet is decommissioned (MH:818, MH:840, MEM:176). Decommissioning the droplet is "not our headache" (MEM:217).
11. **`main-migrated` is the production branch.** Plain `main` is irrelevant (MEM:206).
12. Redirecting unmatched paths to the homepage (soft-404) is intentional (MH:840, MEM:205).
13. CSP was set to enforcing immediately, without a report-only window, and `frame-src https:` is deliberately broad (MH:762, MH:784).
14. The gateway-down 502→503 change was declined (MEM:267).
15. **`TIME_ZONE='Asia/Karachi'` stays.** It is a closed decision; don't re-raise it (MH:1126, TODO:60-76, CLAUDE.md §5).
16. **Inventory warms 3x/day as a business requirement** (MH:1740-1745).
17. Alarm guardrail: leave anything that affects live visitors alone (MH:1114). **Don't retune the latency alarm to silence it** (TODO:18, MH:1662, CLAUDE.md §5).
18. Shared Postgres `max_connections` is 150, not 300 (MEM:358). App-code fixes are left to the dev team (MEM:357).
19. ALB weighting is 35/65 nodeA/nodeB (MH:1134). Keep the detached `dealerpulse-tg-nginx` as rollback (MH:1138, MEM:569). **Do not re-enable stickiness** (TODO:379).
20. Surf City is on its own `main-surfcity` branch. For the next tenant, ask which pipeline pattern to use (MEM:396, TEN:170-172). The old `nissan-surf-city` / `nissan-crona` / `nissan-san-bernardino` / `security-workings` pipeline branches are dead code; ignore them (MEM:380).
21. `revert-puentehills` was cancelled; don't reintroduce it (MEM:731).
22. Origin certificates are self-signed by design. Keep Cloudflare SSL mode on "Full" (MH:924-946).
23. `phn.callingyounow.us` 301-redirects to `www.puentehillsnissan.com` (MEM:311, MEM:339).
24. Rate limits are 50 r/s with burst 150 at the user's chosen numbers, to revisit after QA (MH:836, MEM:195).
25. `ALLOWED_HOSTS` and `CORS_ALLOWED_ORIGINS` include all public hostnames (MH:910).
26. Integration VM: resize **deferred, not rejected** (MH:1024, MEM:614). The `chat_backend_postgres_data` volume is kept until its provenance is known (MEM:628).
27. netdata removal was the user's call and is done on all 3 VMs (MH:1018, MH:1276).
28. **Every write, install, purge, restart, IAM, ALB or SG change on prod VMs needs individual approval, even under a broad instruction** (MH:1276, TODO:6-8, CLAUDE.md §3).
29. Logging cost choices: gunicorn's access log stays local, and retention is 14 days for nginx access and 30 days for the rest (MH:854).
30. Secrets are placed by the user directly on the VM, never through chat (MH:320).
31. Japan is on the Cloudflare country allowlist, alongside US, CA and PK (MEM:337).
32. CloudFront for the media bucket is explicitly deferred until traffic justifies it (MH:395).

**Out of my range:** the rest of `MIGRATION_HISTORY.md` (lines 1811 onward) and the separate Cloudflare-config memory file, which several entries reference (I-01, F-01's `status_code_ttl`).
