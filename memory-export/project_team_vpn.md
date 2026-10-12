---
name: project-team-vpn
description: "Team US-egress WireGuard VPN — AWS resources built, current status, open manual step"
metadata: 
  node_type: memory
  type: project
  originSessionId: 5d328751-c6eb-42ac-9083-0ee878fd0ef4
  modified: 2026-09-09T20:38:45.656Z
---

Standing service so the team (5-10 people, working from Pakistan) can make browser + CLI/API traffic exit through a US IP, since dealership sites behind Cloudflare are removing Pakistan from their country allow-lists. Full plan/runbook artifact was published; then built for real in the same account as [[project-dealerships-aws-migration]] (`409289617504`, `us-west-2`) — user explicitly said isolation from production doesn't matter here, only "don't touch existing security groups," so it's a brand-new subnet/SG/key with zero shared resources, not a separate account/provider.

**Live as of 2026-09-10:** `t4g.micro` instance `i-0ad5d9743f6c95721`, Elastic IP `44.225.91.181`, running `wg-easy` (WireGuard + peer-mgmt UI) via Docker with `network_mode: host`, full-tunnel config. SSH access only (IAM role for SSM was blocked by the Claude Code permission classifier; user chose SSH over asking again), key at `~/.ssh/team-vpn`, port 22 restricted to admin IP `103.147.42.47/32` in `team-vpn-sg` (`sg-020165aeddafe5322`) — update this rule if the admin's IP changes.

**Full resource IDs, exact commands, and the two bugs hit (sysctl-in-host-network Compose error; `fileb://` paramfile loading failure worked around via base64) are in `Documentations/TeamVPN/COMMAND_LOG.md` and `HISTORY.md`** — always check those before assuming this doc alone is current.

**Open item blocking handoff:** wg-easy v15's first-run setup wizard needs a browser (no headless/API path found, no browser tool in this environment) — user must open `http://localhost:51821` via an SSH tunnel to `44.225.91.181` and complete admin setup + add peers themselves.

**Open item blocking team-wide rollout:** no real dealership site tested yet against this box's exit IP/ASN — do that before distributing WireGuard configs to the rest of the team.

**Correction + real-world confirmation, 2026-09-12:** the Elastic IP recorded here was previously `44.242.4.12`; that address is no longer allocated to this account at all. The box's current EIP is **`44.225.91.181`** (assoc `eipassoc-0e76e4ba6645daa4c`, reverse DNS `ec2-44-225-91-181.us-west-2.compute.amazonaws.com`), verified via `describe-instances`/`describe-addresses`. Use this address, not the old one.

**The "no real dealership site tested against this exit IP" open item is now closed.** The user browsed `https://www.puentehillsnissan.com/testingwhichcountryiamfrom` through the VPN on 2026-09-12 01:18 UTC and the request reached our origin normally (nginx on Node A logged client `44.225.91.181`, served a 308→307 to the Next.js not-found page — a missing page, not a block). Exit geolocation resolves cleanly to the US: ARIN lists `44.224.0.0/11` as Amazon.com, Inc., `Country: US`, and AWS's own `ip-ranges.json` places it in `us-west-2` (Oregon). So the US-egress requirement this box exists for is confirmed working end to end against a live dealership site behind Cloudflare. Caveat worth keeping: the exit is an **AWS datacenter ASN**, not a residential one — it passes country checks, but any future vendor that blocks hosting-provider ASNs rather than countries would still reject it.

**Measured performance cost, 2026-09-29 (from a team laptop in Pakistan, full-tunnel active):** the box is a hard throughput bottleneck. Same laptop, same minute, VPN on vs VPN off — download **11.3 Mbps vs 116 Mbps (~10x)**, upload **10.6 Mbps vs 48.7 Mbps (~4.6x)**, TCP connect RTT to a US host **342 ms vs 243 ms p50 (~100 ms of Oregon detour)**. Latency through the tunnel is very stable (stdev ~3 ms, 0% loss) — the link is healthy, the pipe is just narrow. Root cause is almost certainly the `t4g.micro` (WireGuard encryption on 2 shared ARM vCPUs + burstable network baseline); not yet confirmed against instance CPU/network metrics. Practical consequence: the box is fine for browser/API calls that need US egress, but anything bandwidth-heavy (RDP, video, large transfers) should be split-tunnelled around it or the instance sized up. Note wg-easy's default full-tunnel config sets `AllowedIPs = 0.0.0.0/0`, which also arms WireGuard's WFP kill-switch — while it's up, traffic **cannot** be forced out the physical NIC even with an explicit source-address bind (fails `WSAEACCES`), so split-tunnelling must be done by narrowing `AllowedIPs`, not by adding routes.
