---
name: project-fluten-rdp-box
description: "Purchased US RDP box FLUTEN-RDP (93.127.140.109:10025) — network is excellent, CPU is 27x slower than a laptop; browsing is CPU-bound, not network-bound"
metadata:
  type: project
---

Rented Windows RDP box used for browsing dealership sites from a US IP. Host `FLUTEN-RDP`, reachable at `93.127.140.109` — **RDP on port 10025** (non-standard; 3389 is closed) and **OpenSSH for Windows 9.5 on port 22**, password auth enabled. Saved credential on the laptop is `TERMSRV/93.127.140.109` as `HAMZA-PC\administrator`. Windows Server 2025 Standard, Hyper-V VM.

**Benchmarked 2026-09-29 — the box is CPU-starved, not network-starved.** Same script, box vs the user's Dell Latitude 5511 (i5-10400H):

- **2 M-iteration single-thread sqrt loop: 8,141 ms on the box vs 300 ms on the laptop — 27x slower.** This is the headline number; quote it to the provider.
- Specs: Xeon Gold 6144 @ 3.5 GHz but only **1 core / 2 threads**, and **2.8 GB RAM with ~0.7 GB free**.
- Reported clock is 3500 MHz now / 3500 MHz max, so nothing throttles *inside* the VM — the loss is hypervisor-level contention (Windows exposes no steal-time counter, so the box reads as ~8% idle while crawling).
- **Network is better than the user's own connection**: 181 Mbps down (laptop: 137), TCP connect to `www.puentehillsnissan.com:443` at **3 ms p50** (laptop: 16 ms), 10 Gbps link. It sits close to a Cloudflare PoP.

**Consequence — do not re-diagnose this as a network issue.** A DevTools capture of the inventory page from the box showed TTFB 390 ms, Stalled 622 ms, Content download 741 ms, total 1.82 s vs 110 ms on the laptop, and a full page load of ~180 s vs ~18 s. All of it is CPU starvation: the tell is **`Request sent` = 35.73 ms vs 0.23 ms**, a phase that is purely local socket-write work and cannot be inflated by any network condition. Real fix is a bigger/less contended box (≥4 vCPU, ≥8 GB) — the Next.js inventory page fires ~271 requests and 1 vCPU cannot keep up.

**Useful technique that worked here:** no password was available and no password-capable SSH tool was installed locally (no sshpass/plink/Posh-SSH), so diagnostics were relayed through the **shared RDP clipboard** — `Set-Clipboard` the script locally, user right-click-pastes into PowerShell on the box, script ends with `Set-Clipboard` of its own report, which syncs back. Two caveats learned writing it: `[Net.Http.HttpClient]` is not loaded in PowerShell 5.1 (use `Net.WebClient.OpenRead`), and `Invoke-WebRequest` is useless for throughput tests — it read 9.8 Mbps on a link curl measured at 116 Mbps, because its parsing overhead dominates.

**Site-vs-box isolation test, 2026-09-29 — the website and its origin are both healthy; only the box's CPU is at fault.** Raw HTTP fetches (no browser, so almost no CPU work), 4 iterations per URL, run on both machines. Total ms, box vs the user's laptop: puentehillsnissan homepage 46 / 43, the inventory page **31 / 34**, google.com **69 / 532**, nissanusa.com **61 / 304**, cloudflare.com 344 / 482, example.com 10 / 19. The box beat the laptop on every URL and its connect times are 2-15 ms vs the laptop's 16-155 ms — its network is far better than the user's own.

Two conclusions worth not re-deriving:
- **The dealership site is fine.** On the box its inventory page fetches faster than google.com does. Nothing to optimize there.
- **The origin is fine.** Cache-bypassed origin fetch (Cloudflare ignores query strings in its cache key, so force a MISS with a random *path* like `/origin-probe-<rnd>`, which returns 308 BYPASS) takes **68 ms from the US box vs 315 ms from Pakistan** — the slow number seen locally is pure distance to us-west-2, not a slow server.

**The closing number: same URL, same box, same network — 31 ms fetched raw by PowerShell vs 1,820 ms fetched by Edge. A 59x inflation with zero network contribution.** The box does show occasional contention spikes (ttfbMax 278/491/405 ms against medians of 34-73 ms) that corroborate host oversubscription.
