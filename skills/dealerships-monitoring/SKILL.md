---
name: dealerships-monitoring
description: "Monitoring and routine health checks for the Dealerships AWS platform and side systems: CloudWatch alarms, ALB metrics, dashboards, log groups, SNS -> Slack alerts, Uptime Kuma monitors, the daily read-only sweep, known blind spots, domain and certificate expiry, timezones in logs. Use for 'health check', 'daily check', 'status', 'is everything ok', a Slack alarm, a Kuma alert, or log investigation."
---

# Monitoring and health checks

Everything here is **read-only** and needs no approval. Exact commands as run in past sweeps: `knowledge/ISSUES_AWS_B.md` section (a).

## What exists
- **CloudWatch alarms** (7 at the 2026-10-05 sweep, all OK):
  - `dealerpulse-alb-5xx-rate-fast` / `-burn` (gated rate)
  - per-node target health
  - CPU credits
  - `dealerpulse-alb-latency-p99`
  - The fd-exhaustion alarm was deleted on purpose on 09-14 (its metric filter remains).
- **Alarm tuning:** thresholds were loosened deliberately on 2026-09-14 and calibrated on measured data. **Do not retune them to silence noise.**
- **Alert route:** SNS `dealerpulse-alerts` → AWS Chatbot (logs in **us-east-1**, shows as "Amazon Q") → Slack `#aws-alerts-dealerpulse`. Don't recreate the Chatbot config casually.
- **ALB metrics:** always use dimension `LoadBalancer=app/dealerpulse-alb/dc80177beaa3aa2f`, never a target group.
- **Logs:** `/dealerpulse/*` log groups. Dashboards `DealerPulse-Fleet-Overview`, `DealerPulse-Logs`, `DealerPulse-Per-VM`. CWAgent memory/disk/swap metrics exist, but **no memory alarm**.
- **Uptime Kuma** at `https://uptime.callingyounow.us` (dashboard allowlisted, including the VPN exit IP; public status page `/status/health`).
  - Keyword checks use street addresses: Puente Hills `17320 Gale Ave`, Surf City `17331 Beach Blvd`.
  - Certificate expiry alert at 21 days. Domain-expiry monitors use RDAP.
  - DealerPulse push monitors live here too (see `knowledge/DEALERPULSE_OPS.md` §4).

## Daily sweep (~15 min)
1. `aws sts get-caller-identity` (if the session expired, the operator runs `aws login`).
2. Alarms: `aws cloudwatch describe-alarms --region us-west-2 --query 'sort_by(MetricAlarms,&AlarmName)[].{Name:AlarmName,State:StateValue,Updated:StateUpdatedTimestamp}' --output table`
3. ALB over the last 24-72 h on the LoadBalancer dimension: RequestCount, HTTPCode_ELB_5XX_Count, HTTPCode_Target_5XX_Count, TargetResponseTime p99.
   If the 5xx cluster in one hour, compare with container start times; they're usually a deploy.
4. `aws elbv2 describe-target-health` for `dealerpulse-tg-nodea` and `-nodeb`.
5. Via SSM (commands in a JSON file, `--parameters file://...`) on nodeA, nodeB and integration:
   `sudo docker ps --format '{{.Names}}\t{{.Status}}'`, `free -m`, `df -h /`, `sudo docker stats --no-stream`.
6. **428 canary** on nodeA and nodeB for the last hour: `sudo grep -c ' 428 ' /var/log/nginx/access.log` (nginx time is UTC).
   Plus an external content check: Puente Hills `/faqs/` contains questions; the homepage contains inventory data.
7. integration: swap %, chat_back memory, and its uvicorn `--workers` (expect 2).
8. chat_back logs: OpenRouter 402 errors (chatbot credits).
9. Worker logs: HomeNet warm `ttl=72000 ... failed_dealerships=0`, `refreshed_dealerships=` the tenant count; failed lead tasks.
10. Kuma: anything red; cert and domain expiry.
Report in plain language (what I checked · what it means · what to do). Append a dated entry to `records/Migration/MIGRATION_HISTORY.md`
(templates: the 2026-09-25, 10-01 and 10-05 entries).

## Interpreting alarms
- **`dealerpulse-alb-latency-p99`:** the 2-hourly cache stampede was **fixed on 2026-09-21** (TTL 72000), and the alarm was quiet from then until at least
  10-05 (one flap on 09-27). **A firing now is a new signal; investigate** (skill `dealerships-troubleshooting`).
- **5xx rate:** check for a deploy in that hour first.
- **Target health:** a node unhealthy means nginx/gunicorn trouble. The health check does **not** see a dead Next.js container.

## Blind spots (nothing alarms on these)
1. Pages render with empty content (428), while every alarm stays green.
2. Chatbot out of OpenRouter credits.
3. Integration memory/swap.
4. Nothing outside AWS watches the platform (Kuma runs in the same account).

## Time and dates
- nginx and CloudWatch are **UTC**. Django container log text is **+0500**. The team is in PKT (UTC+5); dealerships are in California (UTC-7/-8).
- **Domain registrations** are not ours, and the user chose to leave them (2026-10-13). This is for information only; don't raise it in sweeps.
