---
name: dealerships-monitoring
description: "Monitoring and routine health checks for the Dealerships AWS platform: CloudWatch alarms, dashboards, log groups, SNS -> Slack alerts, Uptime Kuma, the daily read-only sweep, known blind spots, timezones in logs. Use when asked for a health check, status, sweep, report, 'is everything ok', alarm questions, or log investigation."
---

# Monitoring and health checks

All of this is read-only and needs no approval.

## What exists
- 7 CloudWatch alarms (all OK at last check, 2026-10-05): ALB 5xx (gated rate), per-node target health, CPU credits, `dealerpulse-alb-latency-p99`,
  nginx fd exhaustion (verify it exists). Thresholds are calibrated; do not retune to silence them.
- SNS `dealerpulse-alerts` -> AWS Chatbot -> Slack `#aws-alerts-dealerpulse`.
- Logs `/dealerpulse/*`; dashboards `DealerPulse-Fleet-Overview`, `DealerPulse-Logs`, `DealerPulse-Per-VM`; CWAgent memory/disk/swap metrics.
- Uptime Kuma at `uptime.callingyounow.us` (on the VPN box). Keyword checks use street addresses (PHN `17320 Gale Ave`, Surf City `17331 Beach Blvd`).

## Daily sweep (~15 min)
1. `aws cloudwatch describe-alarms --query "MetricAlarms[].[AlarmName,StateValue]" --output table`
2. ALB 5xx (scope the metric to the LoadBalancer dimension) and `describe-target-health` for both target groups.
3. Via SSM on nodeA, nodeB, integration: `docker ps` (restarts), `free -m`, `df -h /`, `docker stats --no-stream`.
4. 428 canary on both nodes over the last hour.
5. integration swap and `chat_back` memory; chat_back logs for OpenRouter 402 errors.
6. Cert expiry; Kuma state.
Report with evidence, `[verified]`, and append a dated entry to `Documentations/Migration/MIGRATION_HISTORY.md` (templates: 2026-09-25, 10-01, 10-05).

## Blind spots (no alarm covers them)
SSR returning 200 with empty data (428 incident); chatbot "temporarily unavailable" (OpenRouter credits); integration memory/swap.

## Reading logs
nginx and CloudWatch timestamps are **UTC**; Django container log text is **+0500**; the team works in PKT (UTC+5). The latency alarm firing near
even-hour UTC boundaries is the known HomeNet cache stampede, not a new incident. The API cannot be probed with curl (428 by design).
