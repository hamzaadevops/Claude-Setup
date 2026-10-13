---
name: team-vpn-and-uptime
description: "Side systems: the team WireGuard VPN (wg-easy) and Uptime Kuma on one AWS t4g.micro box, plus the rented US Windows RDP box. Use for VPN access or users, US exit IP, VPN not connecting, Kuma monitors or alerts, 403 on the Kuma dashboard, SSH to the VPN box timing out, admin IP allowlisting, or slowness on the VPN or RDP box."
---

# Team VPN, Uptime Kuma, RDP box

Full issue history and procedures: `knowledge/ISSUES_AWS_B.md` (V-01..V-20, R-01, section (c)). Records: `records/TeamVPN/`, `records/Monitoring/`.
Changes to these boxes need approval (skill `dealerships-change-control`). The box has **no SSM**; access is SSH only.

## The box
- Instance `i-0ad5d9743f6c95721`, t4g.micro, EIP **`44.225.91.181`** (the team's US exit IP; an AWS datacenter address).
- SG `team-vpn-sg` `sg-020165aeddafe5322`, which must contain:
  - UDP 51820 open (WireGuard)
  - 80/443 (Kuma via nginx)
  - TCP 22 from listed admin IPs only
- Same AWS account as Dealerships, but its own subnet, SG and key; nothing shared with production.
- Backed up daily by DLM policy `policy-01e45e775632d7de9` (volume tag `Project=team-vpn`). These snapshots are the only backup of the VPN peers.

## SSH access
- Key `~/.ssh/team-vpn`, user `ubuntu`. Check where you are first: `curl -s https://checkip.amazonaws.com`.
  - Returns `44.225.91.181`: you're **on** the VPN. Use aliases `vpn-box` / `kuma-vpn` / `wg-ui-vpn` (10.8.0.1). No SG rule is needed.
  - Anything else: you're **off** the VPN. Use `node_vpn` / `kuma` / `wg-ui`. Your IP must be in the SG; skill **`MyUptimeIP <ip>`** adds it.
- The public aliases always time out while you're connected to the VPN. It looks like a firewall block, but it isn't.

## VPN users (wg-easy)
- Use skill **`ConnectWireguardUI`**. It always opens `http://localhost:51821` through an SSH tunnel.
  Never use the IP directly: keys are generated in the browser and need a secure context.
- **The operator creates the client in the UI; Claude never generates private keys.** Name the peer after the person; set `PersistentKeepalive = 25`.
- Known issue: wg-easy's stored host is the old `44.242.4.12`, so **check that every generated config's `Endpoint` is `44.225.91.181:51820`**.
- "Nobody can connect": check the SG still has the **UDP** 51820 rule. It was once replaced by a TCP rule, and the VPN was down for 3-5 days before anyone noticed.
- Throughput is about 11 Mbps (t4g.micro). Fine for browsing and APIs; not for RDP, video or large transfers. Split-tunnel by narrowing `AllowedIPs`.
- Don't restart wg-easy while you're connected through it.

## Uptime Kuma
- Kuma 2.x in Docker, bound to 127.0.0.1:3001 (on purpose; never publish it on 0.0.0.0). nginx publishes `https://uptime.callingyounow.us`:
  - `/dashboard` is IP-allowlisted. The VPN exit IP is allowlisted, so being on the VPN is the easy way in. Otherwise use `MyUptimeIP`.
  - `/status/health` is public.
  - `/api/push/` is accepted only from the DealerPulse droplet.
- nginx traps:
  - `sites-enabled/uptime.callingyounow.us` is a regular file, not a symlink.
  - **Never put backups in `sites-enabled/`**; use `/etc/nginx/backups/`.
- "Everything down but sites are fine": Kuma memory pressure. It was fixed with swap and `mem_limit: 512m`. Check
  `sudo docker inspect uptime-kuma --format '{{.RestartCount}}'` and `sudo docker exec uptime-kuma cat /sys/fs/cgroup/memory.events`.
  Don't raise the limit without swap, and don't run the old `louislam/uptime-kuma:1` image.
- Docker quirks: use `sudo docker`; the compose project is `ubuntu` (run it from `~`).
- New monitor: retries 3, interval 60 s, keyword = the dealership's **street address**, Slack notification. Domain expiry uses RDAP json-query
  (`.us` → `https://rdap.nic.us/domain/<d>`, `.com` → `https://rdap.verisign.com/com/v1/domain/<d>`). Edit monitors in the UI, not the database.
- Monitor list: `records/Monitoring/MONITOR_CHECKLIST.md` (partly stale: use street-address keywords).

## Rented RDP box
- `93.127.140.109`, RDP port **10025** (not 3389), OpenSSH on 22, Windows Server 2025, 1 vCPU / 2.8 GB.
- Network is excellent; the CPU is about 27x slower than a laptop, so browsing there is slow. The sites and origin are fine.
- Real fix: a bigger box (at least 4 vCPU and 8 GB). **Do not re-diagnose as a network problem.**
