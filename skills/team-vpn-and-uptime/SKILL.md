---
name: team-vpn-and-uptime
description: "Side systems: the team WireGuard VPN (wg-easy) and Uptime Kuma on one AWS t4g.micro box, plus the rented US Windows RDP box. Use for VPN access, US exit IP, adding VPN users, Kuma monitors, SSH to the VPN box, admin IP allowlisting, or slowness on the VPN or RDP box."
---

# Team VPN, Uptime Kuma, RDP box

## VPN + Kuma box
- Instance `i-0ad5d9743f6c95721`, `t4g.micro`, EIP `44.225.91.181` (exit IP, AWS us-west-2, datacenter ASN), SG `team-vpn-sg` `sg-020165aeddafe5322`.
  Same AWS account as Dealerships, separate subnet/SG/key; nothing shared with production.
- Purpose: the team in Pakistan exits through a US IP for dealership sites that allow-list countries. Confirmed working 2026-09-12.
- wg-easy v15 in Docker (host network), full tunnel. Admin UI only through an SSH tunnel to `http://localhost:51821` (keys are generated in the browser
  and need a secure context). Use skill **`ConnectWireguardUI`**.
- Uptime Kuma bound to 127.0.0.1:3001, published as `https://uptime.callingyounow.us` behind nginx. Monitor list: `Documentations/Monitoring/MONITOR_CHECKLIST.md`.
- SSH: key `~/.ssh/team-vpn`, user `ubuntu`. Off the VPN use aliases `node_vpn` / `kuma` / `wg-ui` (needs your IP in the SG; skill **`MyUptimeIP <ip>`**
  adds it to the SG and the Kuma nginx allow-list). On the VPN use `vpn-box` / `kuma-vpn` / `wg-ui-vpn` (10.8.0.1); the public aliases time out while connected.
- Limits: ~11 Mbps through the tunnel. Not for RDP/video/large transfers; split-tunnel by narrowing `AllowedIPs` (the WireGuard kill-switch blocks route tricks).
- History and commands: `Documentations/TeamVPN/HISTORY.md`, `COMMAND_LOG.md`.

## Rented RDP box
`93.127.140.109`, RDP port **10025** (not 3389), OpenSSH on 22, Windows Server 2025, 1 vCPU / 2.8 GB. Network is excellent; the CPU is about 27x slower
than a laptop, so browsing is slow there. The dealership sites and origin are fine. Real fix: a larger box (>=4 vCPU, >=8 GB). Do not re-diagnose as network.

Changes to either box need approval (skill `dealerships-change-control`).
