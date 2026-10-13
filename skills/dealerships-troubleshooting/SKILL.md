---
name: dealerships-troubleshooting
description: "Symptom-to-cause guide for the Dealerships platform and side systems, built from real incidents: site down/5xx/502, blank pages with no data (428), chatbot unavailable, ChunkLoadError after deploy, broken or stale images, latency alarm, 52x errors, redirect loops, Postgres too many clients, lead delivery failures, slow VPN, slow RDP box. Use when anyone reports something broken or slow."
---

# Troubleshooting

Investigate read-only first; any fix needs approval (skill `dealerships-change-control`). Full history: `Claude-Setup/INCIDENTS.md`.

| Symptom | Most likely cause (seen before) | First checks |
|---|---|---|
| Page shell renders, content empty | Frontend cached a failed API-crypto bootstrap (started before Django) -> 428 on every SSR call | 428 count; container start times. Fix: restart frontend containers one node at a time |
| Chatbot "temporarily unavailable" | OpenRouter credits exhausted | chat_back logs for 402; user tops up |
| 502 burst | Frontend deploy window (expected) or node unhealthy | target health; deploy time; `docker ps` |
| ChunkLoadError / JS 404 | Nodes on different builds or a cached 404 | image digest on both nodes; `cf-cache-status` |
| Latency alarm every ~2 h | HomeNet inventory cache stampede + Next image optimizer | firing time vs even-hour UTC; slow `/api/homenet/inventory/` and `/_next/image` |
| Images broken | HomeNet image CDN stall; hotlink protection; optimizer timeouts | nginx 500/504 on `/_next/image` |
| Old image after replacement | 30-day extension-based Cloudflare cache | user purges |
| 522/524 | SG/prefix-list drift; second SG on a node | SGs on instance; prefix lists vs cloudflare.com/ips |
| 525/526, redirect loop | Origin cert expired or SSL mode changed | `certbot certificates`; SSL mode Full |
| "Waiting for PostgreSQL..." loop | ocean override file lost to a deploy auto-stash | `git stash list` in the repo dir on the node |
| `too many clients` | JD Power fan-out after an inventory warm | Postgres logs; non-fatal |
| Lead not delivered (VinSolutions 422) | Payload rejected or country rule blocked a vendor | worker + leads logs; Cloudflare Security Events |
| integration slow, swap high | chat_back running 4 uvicorn workers instead of 2 | `docker inspect` command; `free -m` |
| ~50% of requests fail for one host | A node lacks that vhost or cert | vhosts/certs on both nodes |
| Direct IP times out | By design | use SSM |
| Slow through VPN | t4g.micro throughput (~11 Mbps) | expected; split-tunnel via `AllowedIPs` |
| Slow on the RDP box | Box CPU (1 core, 27x slower than a laptop), not network | do not re-diagnose |

Habits: confirm before claiming; a green dashboard does not mean a working site; earlier diagnoses have been wrong, so label provenance.
