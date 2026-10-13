# Claude-Setup — operating knowledge for the Dealerships platform and side systems

Single source of truth for any engineer or Claude agent working on:
- the **Dealerships** multi-tenant dealership platform on **AWS** (`409289617504`, `us-west-2`), and
- the **side systems**: team VPN + Uptime Kuma box, rented RDP box, and the **DigitalOcean** estate (DealerPulse product, legacy hosts).

**Stance:** the system works and is accepted. Keep it running with minimal change. The architecture is the core knowledge; improvement lists are optional.

## Contents
| File | Purpose |
|---|---|
| `CLAUDE.md` | Rules every agent follows; reading order |
| `ARCHITECTURE.md` | **Primary reference**: systems, request flow, components, security, invariants, accepted trade-offs |
| `INTENT_ROUTER.md` | "When someone says X, do Y", with approval requirements |
| `INVENTORY.md` | IDs, hostnames, ports, zones, SSH aliases, third parties |
| `RUNBOOKS.md` | Procedures: deploy, new dealership, health sweep, access, Cloudflare, logging |
| `INCIDENTS.md` | Past incidents: symptom -> cause -> fix |
| `STATUS.md` | Watch-list (optional improvements), closed decisions, open questions |
| `DEALERPULSE.md` | The DigitalOcean product in detail |
| `CONTEXT.md` | History and timeline |
| `START_HERE.md` | Guide for the engineer taking over (not necessarily a DevOps specialist) |
| `skills/` | Topic skills that feed an agent the right context on demand |
| `knowledge/` | Deep reference: `DEPLOY_FLOWS.md`, `ISSUES_AWS_A.md`, `ISSUES_AWS_B.md`, `DEALERPULSE_OPS.md` (every flow and past issue, with citations) |
| `records/` | Original evidence: migration history, command log, handover, monitoring, VPN, DealerPulse docs, deploy-script copies (no secrets) |
| `memory-export/` | Earlier session notes (reference only) |

## Skills
| Skill | Triggers on |
|---|---|
| `dealerships-architecture` | how things work, where things run, before any change |
| `dealerships-change-control` | any write/deploy/restart/config change, "fix", "optimise", TODO |
| `dealerships-deploy` | deploy, release, rollback, env vars, new dealership |
| `dealerships-edge-cloudflare` | Cloudflare, cache, WAF, 52x, certs, security groups |
| `dealerships-monitoring` | health checks, alarms, dashboards, logs, Kuma |
| `dealerships-troubleshooting` | anything reported broken or slow |
| `team-vpn-and-uptime` | VPN, US exit IP, Kuma, VPN box, RDP box |
| `dealerpulse-digitalocean` | DealerPulse product, droplet, DO database, legacy hosts |
| `dealerships-onboarding` | new operator, "explain", plain-language guidance |
| `ConnectWireguardUI` | open the wg-easy UI / add a VPN client (action) |
| `MyUptimeIP` | allowlist an admin IP on the VPN box (action) |

## Using it with Claude Code
1. Clone the pack to `D:\Nexrupt Data\Repositories\Claude-Setup` and copy `CLAUDE-root-pointer.md` to `D:\Nexrupt Data\Repositories\CLAUDE.md`
   (it imports the pack's rules). Clone the application repos beside it (layout and URLs: `INVENTORY.md` §9).
2. Copy every folder in `skills\` to `~\.claude\skills\`.
3. Open Claude Code in `D:\Nexrupt Data\Repositories`. Ask it to read `ARCHITECTURE.md` and run the read-only refresh in `STATUS.md` §5 to confirm
   the docs match live state.
4. Access needed for live work: AWS CLI v2 session for the account, SSH keys `~/.ssh/team-vpn` and `~/.ssh/digitalocean` with the aliases in
   `INVENTORY.md` §6, Bitbucket `nxpt` access, Cloudflare dashboard access. Secrets never live in this pack.

## Keeping it true
Update the matching file in the same session you learn something; mark `[verified]` with a date when checked live.
