# Team VPN — Command Log

Same account as the Dealerships migration (`409289617504`, `us-west-2`), but a fully separate subnet/SG/IAM footprint dedicated to this project. No production resource was modified. Append-only, exact commands + resulting resource IDs.

## Resource index

| Resource | ID |
|---|---|
| Subnet | `subnet-092145b36659b0b3d` (10.0.3.0/24, us-west-2a) |
| Route table (reused, association added only) | `rtb-080753ccf3366c52a` (association `rtbassoc-0ebc0bf7cb6f5c92e`) |
| Security group | `sg-020165aeddafe5322` (`team-vpn-sg`) |
| SSH key pair | `team-vpn-key` (private key local only: `~/.ssh/team-vpn`) |
| Elastic IP | `eipalloc-09d9cc6a2f6bc2826` → `44.242.4.12` (assoc `eipassoc-0c6aa35a10a6acbbb`) |
| EC2 instance | `i-0ad5d9743f6c95721` (t4g.micro, Ubuntu 24.04 arm64, `ami-05c117a6593f02954`) |

## 2026-09-10 — Initial provisioning

```
aws ec2 create-subnet --vpc-id vpc-04362594fced3c6f0 --cidr-block 10.0.3.0/24 --availability-zone us-west-2a \
  --tag-specifications 'ResourceType=subnet,Tags=[{Key=Name,Value=team-vpn-subnet},{Key=Project,Value=team-vpn}]'
→ subnet-092145b36659b0b3d

aws ec2 associate-route-table --route-table-id rtb-080753ccf3366c52a --subnet-id subnet-092145b36659b0b3d
→ rtbassoc-0ebc0bf7cb6f5c92e

aws ec2 modify-subnet-attribute --subnet-id subnet-092145b36659b0b3d --map-public-ip-on-launch

aws ec2 create-security-group --group-name team-vpn-sg \
  --description "Team US-egress WireGuard VPN - isolated, no production access" \
  --vpc-id vpc-04362594fced3c6f0 \
  --tag-specifications 'ResourceType=security-group,Tags=[{Key=Name,Value=team-vpn-sg},{Key=Project,Value=team-vpn}]'
→ sg-020165aeddafe5322

aws ec2 authorize-security-group-ingress --group-id sg-020165aeddafe5322 --protocol udp --port 51820 --cidr 0.0.0.0/0
→ sgr-0e60cd1614e242201 (WireGuard, open to all — this is the whole point of the box)

# IAM role creation for SSM management was BLOCKED by the Claude Code auto-mode classifier.
# User chose SSH-key access instead of SSM for this box.

aws ec2 authorize-security-group-ingress --group-id sg-020165aeddafe5322 --protocol tcp --port 22 --cidr 103.147.42.47/32
→ sgr-046fe4729c73dd843 (SSH restricted to admin's IP at time of setup — re-authorize for new admin IPs as needed, don't widen to 0.0.0.0/0)

ssh-keygen -t ed25519 -f ~/.ssh/team-vpn -N "" -C "team-vpn-admin"

aws ec2 import-key-pair --key-name team-vpn-key --public-key-material <base64 of team-vpn.pub>
→ team-vpn-key (private key never uploaded to AWS)

aws ec2 allocate-address --domain vpc \
  --tag-specifications 'ResourceType=elastic-ip,Tags=[{Key=Name,Value=team-vpn-eip},{Key=Project,Value=team-vpn}]'
→ eipalloc-09d9cc6a2f6bc2826, 44.242.4.12

aws ec2 run-instances \
  --image-id ami-05c117a6593f02954 --instance-type t4g.micro --key-name team-vpn-key \
  --subnet-id subnet-092145b36659b0b3d --security-group-ids sg-020165aeddafe5322 \
  --associate-public-ip-address --user-data <base64 of vpn-userdata.sh, WG_HOST baked in as 44.242.4.12> \
  --metadata-options HttpTokens=required \
  --block-device-mappings '[{"DeviceName":"/dev/sda1","Ebs":{"VolumeSize":15,"VolumeType":"gp3","DeleteOnTermination":true}}]' \
  --tag-specifications 'ResourceType=instance,Tags=[{Key=Name,Value=team-vpn-box},{Key=Project,Value=team-vpn}]'
→ i-0ad5d9743f6c95721

aws ec2 wait instance-running --instance-ids i-0ad5d9743f6c95721
aws ec2 associate-address --instance-id i-0ad5d9743f6c95721 --allocation-id eipalloc-09d9cc6a2f6bc2826
→ eipassoc-0c6aa35a10a6acbbb
```

**CLI gotcha hit again this session (same class as the migration's file-loading issues):** `fileb://<path>` paramfile loading failed repeatedly for both `--public-key-material` and `--user-data` — tried with/without `MSYS_NO_PATHCONV`, forward slashes, backslashes, no-space paths — every variant errored `No such file or directory` even though the file existed and was readable directly. **Working fix: skip `fileb://` entirely, base64-encode the file content in bash (`base64 -w0 <path>`) and pass the resulting string directly as the parameter value** — the blob-typed parameters accept a raw base64 string without a file reference. Faster and more reliable than chasing the path-conversion issue; use this pattern first next time instead of debugging `fileb://`.

## 2026-09-10 — Bootstrap fix (user-data ran but wg-easy failed to start)

The instance's `user-data` script installed Docker and started wg-easy, but the container failed:
```
OCI runtime create failed: runc create failed: sysctl "net.ipv4.conf.all.src_valid_mark" not allowed in host network namespace
```
Cause: `docker-compose.yml`'s `sysctls:` block is invalid combined with `network_mode: host` (sysctls can't be set per-container when sharing the host network namespace).

Fix applied over SSH:
```
echo "net.ipv4.ip_forward=1" | sudo tee /etc/sysctl.d/99-wireguard.conf
echo "net.ipv4.conf.all.src_valid_mark=1" | sudo tee -a /etc/sysctl.d/99-wireguard.conf
sudo sysctl -p /etc/sysctl.d/99-wireguard.conf
# removed the `sysctls:` block from /opt/team-vpn/docker-compose.yml, set both values on the host instead
sudo docker compose -f /opt/team-vpn/docker-compose.yml down
sudo docker compose -f /opt/team-vpn/docker-compose.yml up -d
```
Verified after fix: `wg show` (inside container) shows `wg0` listening on 51820; `ss -tulnp` on host confirms 51820/udp and 51821/tcp bound; `iptables-legacy -t nat -L POSTROUTING` shows `MASQUERADE ... 10.8.0.0/24 -> eth0`; `FORWARD` chain accepts both directions on `wg0`.

**Standing rule for any future rebuild of this box: never put a `sysctls:` block in a compose service that uses `network_mode: host` — set the sysctl on the host directly instead.**

## Still pending (not yet done)

- **wg-easy first-run setup wizard** (`/setup/1`, admin account creation) requires a browser — it's a Nuxt SPA with no discoverable REST/tRPC path found via `curl` probing (`/api/session`, `/api/wireguard/client`, `/api/trpc/...` all 404). Could not complete headlessly in this environment (no browser tool available here — see `[[project-dealerships-aws-migration]]`'s "no Playwright" note, same constraint applies). **User must open `http://localhost:51821` in a browser via the SSH tunnel below to finish setup**, then add peers through that same UI.
- SSH tunnel already open from this session for that purpose: `ssh -i ~/.ssh/team-vpn -L 51821:localhost:51821 ubuntu@44.242.4.12` (background PID visible via `ps aux | grep ssh`).
- No dealership site has been tested yet against `44.242.4.12`'s ASN/country — do before wide team rollout.
