# Celery push monitoring via Uptime Kuma — status

Built 2026-09-18. **Live and working end to end.**

> ⏳ **OUTSTANDING — failure test not yet performed.** Stopping `beat` to confirm
> Kuma goes red and Slack actually fires has been deferred to a quieter window.
> Until that is done the alerting is unproven. See "prove it works" below.

Final settings, confirmed stable over five consecutive minutes with no false
alarms: both push monitors on a 120s heartbeat, 1 retry, 60s retry interval —
so a real failure alerts in ~3 minutes and a single missed run is absorbed
silently. The droplet timer runs on `OnCalendar=*:*:00` (wall clock, no drift);
an earlier `OnUnitActiveSec` schedule drifted to 65–70s gaps and tripped the
then-60s heartbeat, producing a false DOWN at 18:50:13.

Confirmed in Kuma at 18:49 UTC on 2026-09-18:

```
DealerPulse Database   port   UP   23 ms
Dealer Pulse Beat      push   UP   "beat running and active within 3m"
Dealer Pulse Worker    push   UP   "worker running and active within 10m"
```

The messages are the check script's own text, so the full chain is proven:
droplet → Cloudflare → nginx → Kuma.

**Why this exists:** `worker` and `beat` have no health check and no restart
policy. If either dies it stays dead, nothing restarts it, and the site stays
green while appointment confirmations, reminder calls, no-show recovery and the
hourly BDC report all stop. No HTTP monitor can see that.

---

## Done

| | |
|---|---|
| nginx | 1.24.0 installed and running on team-vpn-box `44.225.91.181` |
| Site config | `/etc/nginx/sites-available/uptime.callingyounow.us`, enabled, default site removed |
| TLS | self-signed cert at `/etc/ssl/cloudflare/uptime.callingyounow.us.{pem,key}` |
| Check script | `/usr/local/bin/check-celery.sh` on the DealerPulse droplet |
| Config file | `/etc/default/check-celery` (mode 600, tokens blank) |
| Timer | `check-celery.timer`, enabled and active, runs every minute |

### Verified working

```
from the droplet:   GET https://uptime.callingyounow.us/api/push/<bad-token>
                    -> 404 {"ok":false,"msg":"Monitor not found or not active."}
                       (that is Kuma answering — the full path works)
from anywhere else: -> 403  (nginx allow/deny)
/ and /dashboard:   -> 404  (the UI is never served here)
script test run:    beat  up - running and active within 3m
                    worker up - running and active within 10m
```

### How it is protected

Four layers, in order:

1. Cloudflare in front — WAF, rate limiting, origin IP hidden
2. nginx serves only `/api/push/`; everything else returns 404
3. `allow 146.190.132.236; deny all;` — only the DealerPulse droplet may push.
   Works because `real_ip_header CF-Connecting-IP` restores the true client IP
   from Cloudflare's headers
4. The push token itself

The Kuma dashboard is **never** served over the internet. It stays on the SSH
tunnel: `ssh -N -L 3001:127.0.0.1:3001 ubuntu@44.225.91.181`

---

## Remaining — step 1 **[you]**: create the two push monitors

Over the tunnel, add two monitors:

| Field | Monitor A | Monitor B |
|---|---|---|
| Monitor Type | Push | Push |
| Friendly Name | DealerPulse Celery Beat | DealerPulse Celery Worker |
| Heartbeat Interval | 120 | 180 |
| Retries | 1 | 1 |

The heartbeat interval must be **longer than the script's 60-second run
interval**, or Kuma marks it down between pushes. 120s and 180s allow one missed
run of headroom.

Copy the token from each push URL — the part after `/api/push/` — then either
send them to me, or:

```bash
ssh dealerpulse
sudo nano /etc/default/check-celery      # fill in PUSH_BEAT and PUSH_WORKER
sudo systemctl start check-celery.service
sudo journalctl -u check-celery.service -n 5 --no-pager
```

Both monitors should go green within two minutes.

## Remaining — step 2: prove it works

An untested monitor is an assumption.

```bash
ssh dealerpulse
docker stop dealerpulse_backend-beat-1
# wait ~3 minutes, confirm Kuma goes red and Slack fires
docker start dealerpulse_backend-beat-1
```

Safe: `beat` only schedules jobs, so a three-minute stop delays them rather than
losing them. Do it outside dealership hours.

**Do not test by stopping `worker`** — that interrupts tasks in flight.

## Remaining — step 3: TCP monitor on the database

| Field | Value |
|---|---|
| Monitor Type | TCP Port |
| Friendly Name | DealerPulse Database |
| Hostname | `dp2-live-do-user-13151402-0.g.db.ondigitalocean.com` |
| Port | `25060` |
| Heartbeat Interval | 60 |
| Retries | 1 |

---

## Hardening still open

**Upgrade the origin certificate.** The origin currently uses a self-signed
certificate, which works because Cloudflare's SSL mode is **Full** rather than
**Full (strict)**. Replacing it with a free Cloudflare Origin Certificate
(SSL/TLS → Origin Server → Create Certificate, 15-year validity, no renewal job)
lets you move to Full (strict), which stops Cloudflare accepting any certificate
from anything claiming to be the origin. Drop the files at the same two paths and
reload nginx — no config change needed.

**Narrow the firewall.** Port 443 is open to `0.0.0.0/0` and port 80 is open but
unused. With Cloudflare in front, 443 only needs Cloudflare's published ranges
and 80 can be closed entirely. Blocked for me by a tooling guardrail:

```bash
# close 80
RULE=$(aws ec2 describe-security-group-rules --region us-west-2 \
  --filters "Name=group-id,Values=sg-020165aeddafe5322" \
  --query "SecurityGroupRules[?FromPort==\`80\`].SecurityGroupRuleId" --output text)
aws ec2 revoke-security-group-ingress --region us-west-2 \
  --group-id sg-020165aeddafe5322 --security-group-rule-ids $RULE

# swap public 443 for Cloudflare ranges
RULE=$(aws ec2 describe-security-group-rules --region us-west-2 \
  --filters "Name=group-id,Values=sg-020165aeddafe5322" \
  --query "SecurityGroupRules[?FromPort==\`443\`].SecurityGroupRuleId" --output text)
aws ec2 revoke-security-group-ingress --region us-west-2 \
  --group-id sg-020165aeddafe5322 --security-group-rule-ids $RULE

for cidr in 173.245.48.0/20 103.21.244.0/22 103.22.200.0/22 103.31.4.0/22 \
            141.101.64.0/18 108.162.192.0/18 190.93.240.0/20 188.114.96.0/20 \
            197.234.240.0/22 198.41.128.0/17 162.158.0.0/15 104.16.0.0/13 \
            104.24.0.0/14 172.64.0.0/13 131.0.72.0/22; do
  aws ec2 authorize-security-group-ingress --region us-west-2 \
    --group-id sg-020165aeddafe5322 \
    --ip-permissions "IpProtocol=tcp,FromPort=443,ToPort=443,IpRanges=[{CidrIp=$cidr,Description=\"Cloudflare\"}]"
done
```

The nginx `allow/deny` already restricts who can push, so this is defence in
depth rather than the only control.

**WireGuard.** `51820/udp` is still absent from the security group, so the team
VPN is unreachable. Left alone as instructed — flagging only.

**Nothing watches Kuma itself.** If that container or the box dies, alerting
stops silently. It needs one external heartbeat pointed at it.

---

## Note on the script

`log_has()` deliberately does not use `grep -q`. With `pipefail` set, `grep -q`
exits on the first match, closing the pipe, killing `docker logs` with SIGPIPE,
and making the pipeline report failure even though the pattern matched. That
produced a false "worker is wedged" on the first live run — the worker's log is
large enough for grep to exit early, while beat's is not. Reading the full stream
avoids it. Worth remembering before anyone "tidies" that line.
