# START HERE — for the engineer taking over

You don't need to be a DevOps specialist to look after this setup. Claude Code does the investigating and explaining. This
repository is what makes it reliable: it holds everything we learned while building and running the systems, and the rules your Claude must
follow before it touches anything.

## 1. What you are looking after (one paragraph)
Four Nissan dealership websites (Puente Hills, Surf City, Corona, San Bernardino) run on **AWS** as one shared platform called **Dealerships**.
Visitors go through **Cloudflare** (security and caching) to an AWS **load balancer**, which sends them to two identical web servers (**nodeA**, **nodeB**).
A third server (**integration**) holds the database, the chatbot, the lead delivery service and the admin dashboard. Code changes reach production
automatically through **Bitbucket Pipelines** when developers merge to the right branch. Around this are three side systems: a **team VPN** (so the team
can browse from a US IP) with **Uptime Kuma** monitoring on the same small server, a rented **Windows RDP box**, and a separate product called
**DealerPulse** on **DigitalOcean**. The setup works and the business is happy with it: **your job is to keep it running, not to redesign it.**

## 2. One-time setup
1. Install Claude Code, Git, the AWS CLI v2 and OpenSSH.
2. Put this repository at `Documents\Claude-Setup`. Copy `CLAUDE-root-pointer.md` to `Documents\CLAUDE.md`.
3. Copy every folder in `skills\` into `C:\Users\<you>\.claude\skills\`.
4. Get access from your lead (Claude cannot create these for you): AWS console/CLI login for account `409289617504`, Bitbucket workspace `nxpt`,
   Cloudflare dashboard, SSH keys `team-vpn` and `digitalocean`, Slack channel `#aws-alerts-dealerpulse`.
5. Open Claude Code in your `Documents` folder and type: **"I'm new. Read the Claude-Setup pack and explain what I'm looking after."**

## 3. How to work with your Claude
Just describe what you see or want, in plain words. Claude finds the right skill. Examples:

| You want to... | Type something like |
|---|---|
| Understand the system | "Explain how a visitor reaches the Puente Hills website." |
| Daily check | "Do the daily health check and tell me if anything needs attention." |
| React to an alert | "I got a Slack alert called dealerpulse-alb-latency-p99. What does it mean, and do I need to do anything?" |
| A site looks broken | "The Surf City site loads but the vehicle list is empty." |
| Chatbot problem | "The chatbot on the website says it's temporarily unavailable." |
| A developer wants to release | "A developer merged to main-corona. Walk me through what the pipeline will do and what to check after." |
| Something went wrong after a release | "Since the last deploy, some pages show errors. Help me find out why." |
| Give someone VPN access | "Add a VPN user called ali-laptop." |
| My IP changed and I can't reach Kuma | "MyUptimeIP 203.0.113.5" (your new public IP) |
| DealerPulse question | "Is the DealerPulse backend healthy?" |
| Before any change | "I want to change X. Tell me everything I need to know first." |

Claude will:
- **look before it acts.** It reads the architecture and the history and checks the live state (read-only) first;
- **explain** what it found in plain language and say how sure it is ([verified] means it checked just now);
- **ask your permission** before changing anything, explaining what could go wrong and how to undo it.

## 4. Safety rules (please keep these)
- **Read-only is always fine.** Looking at logs, alarms, container status or settings never breaks anything.
- **Any change needs your explicit "yes".** If you don't understand the risk Claude describes, don't approve it. Ask Claude to explain again, or
  ask your escalation contact (below).
- **Never deploy by hand.** Releases go through the Bitbucket pipeline only.
- **Never rename** anything called `dealerpulse-*` in AWS. The name looks wrong but it's correct, and renaming breaks the sites.
- **Some actions Claude is not allowed to do** (create passwords or keys, purge Cloudflare cache by API, install software on servers). Claude will
  tell you the exact steps to do them yourself.
- **"DealerPulse" means two things.** It's the prefix of the AWS resource names, and also a separate product on DigitalOcean. Claude asks which one you mean.

## 5. When to escalate (don't fix alone)
- Anything touching the **database**, **security groups / firewall**, **DNS**, **Cloudflare security rules**, or **deleting** anything.
- The site is down for everyone for more than ~10 minutes.
- Anything on the **DealerPulse** server or its database.
- Claude says it is unsure, or the evidence contradicts the docs.

Escalation contact: **____________________** (fill in: name / Slack / phone)

## 6. Words you'll hear
| Term | Meaning |
|---|---|
| ALB | AWS load balancer. Splits visitors between nodeA and nodeB |
| nodeA / nodeB | The two identical web servers |
| integration | The third server: database, chatbot, leads, admin dashboard |
| ocean | The backend app (Django): content, inventory, API |
| website_frontend | The website app (Next.js). One copy per dealership |
| tenant / rooftop | One dealership |
| SSM | How we log in to the AWS servers (no passwords or SSH needed) |
| ECR | Where built app images are stored in AWS |
| Pipeline | Bitbucket's automatic build-and-deploy process |
| Cloudflare purge | Clearing Cloudflare's cache so visitors get the new version |
| 428 | An error code. Here it usually means the website lost its secure session with the backend after a deploy |
| Kuma | Uptime Kuma, the website-uptime monitor at `uptime.callingyounow.us` |
| wg-easy | The web UI for managing VPN users |
| Alarm | CloudWatch alert, sent to Slack `#aws-alerts-dealerpulse` |

## 7. Map of this repository
`ARCHITECTURE.md` (how it all works) · `INTENT_ROUTER.md` (what Claude does for each kind of request) · `INVENTORY.md` (IDs and addresses) ·
`RUNBOOKS.md` (procedures) · `INCIDENTS.md` (problems we've had and how they were fixed) · `STATUS.md` (things to watch, open questions) ·
`DEALERPULSE.md` · `CONTEXT.md` (history) · `skills\` (topic knowledge Claude loads automatically) · `CLAUDE.md` (Claude's rules) ·
`knowledge\` (every deploy flow and every past issue in detail, which Claude searches when something breaks) · `records\` (the original logs and documents).

You'll rarely need to open these yourself. Ask Claude, e.g. "Has this happened before?" or "What exactly happens when we merge to main-corona?"

## 8. Things that need someone with authority soon
See `STATUS.md` §2a: dealership **domain renewals** (surfcitynissan.com expires 2026-11-12), the **DealerPulse database exposure**, and rotating the
previous engineer's credentials. Raise these with your lead; they aren't changes to make on your own.
