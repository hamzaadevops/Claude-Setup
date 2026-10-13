---
name: MyUptimeIP
description: "Given an IP address, allowlists it for SSH (port 22) on the team-vpn-sg security group and adds it to the nginx allow-list for uptime.callingyounow.us on node_vpn. Use when the user says a phrase like 'MyUptimeIP <ip>' or asks to allowlist their current/new IP for uptime monitoring access."
---

# MyUptimeIP

Allowlists a given IP address in two places so it can reach the team VPN box's SSH port and the internal uptime dashboard.

## Input

The user provides an IPv4 address, e.g. "MyUptimeIP 154.192.227.165" or "MyUptimeIP add 203.0.113.9". Extract the IP address from the request. If no IP is given, ask for one — do not guess or reuse a prior IP.

## Steps

1. **Add the IP to the `team-vpn-sg` security group (port 22 only).**
   Security group: `sg-020165aeddafe5322` (named `team-vpn-sg`, in `vpc-04362594fced3c6f0`).
   ```
   MSYS_NO_PATHCONV=1 aws ec2 authorize-security-group-ingress \
     --group-id sg-020165aeddafe5322 \
     --protocol tcp --port 22 --cidr <IP>/32 \
     --tag-specifications 'ResourceType=security-group-rule,Tags=[{Key=Name,Value=MyUptimeIP-<IP>}]'
   ```
   Before adding, check the rule doesn't already exist (`aws ec2 describe-security-group-rules --filters Name=group-id,Values=sg-020165aeddafe5322` and look for the CIDR) — `authorize-security-group-ingress` errors on an exact duplicate, which is fine to treat as "already allowlisted," not a failure.

2. **SSH to `node_vpn` and add the IP to nginx's allow-list for `uptime.callingyounow.us`.**
   Host alias `node_vpn` is already configured in `~/.ssh/config` (`44.225.91.181`, user `ubuntu`, key `~/.ssh/team-vpn`).
   The config file is `/etc/nginx/sites-enabled/uptime.callingyounow.us`. Existing entries look like:
   ```
   allow 154.192.227.165;
   ```
   Add a new `allow <IP>;` line inside the same block as the existing `allow` lines (do not duplicate if already present), keeping the deny-by-default structure intact. Back up the file first (`cp uptime.callingyounow.us uptime.callingyounow.us.bak-before-myuptimeip-<timestamp>`), then `nginx -t` before reloading, then `systemctl reload nginx` (or `nginx -s reload`).

   Example of the full remote command (adjust `<IP>`):
   ```bash
   ssh node_vpn 'sudo bash -s' <<'EOF'
   set -e
   FILE=/etc/nginx/sites-enabled/uptime.callingyounow.us
   TS=$(date +%Y%m%d-%H%M%S)
   cp "$FILE" "${FILE}.bak-before-myuptimeip-${TS}"
   grep -q "allow <IP>;" "$FILE" || sed -i "/allow [0-9.]*;/a\\        allow <IP>;" "$FILE"
   nginx -t
   systemctl reload nginx
   grep <IP> "$FILE"
   EOF
   ```

3. **Verify both changes landed** — re-describe the security group rule, and re-`cat`/`grep` the nginx file over SSH to confirm the new `allow` line is present and nginx reloaded cleanly.

## Known gotcha

Remote SSH commands that *write* to a host (not just read) have been blocked before by Claude Code's auto-mode classifier ("Remote Shell Writes"), independent of user authorization already given. If step 2 gets blocked:
- Do not retry the same or a reworded command.
- Hand the exact script from step 2 to the user to run themselves over their own SSH session, with the real IP substituted in.
- Step 1 (the AWS security group change) has gone through fine via the AWS CLI in this project before and is not expected to hit the same block — but if it does, hand that command to the user too, same pattern.

## Report back

State plainly what was verified vs. inferred: confirm the SG rule exists (describe-security-group-rules output) and confirm the nginx file actually contains the new line post-reload — don't just report "done" because the commands returned exit 0.
