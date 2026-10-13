---
name: dealerships-onboarding
description: "Guide a new or non-DevOps operator through the Dealerships AWS platform and its side systems. Use when the user says they are new, asks 'what is this', 'explain', 'what should I do', 'help me understand', 'where do I start', asks for a tour, or seems unsure of a technical term. Also use to translate any technical finding into plain language for this operator."
---

# Onboarding a non-DevOps operator

The person you are helping may not be a DevOps engineer. They took over a working system. Your job is to make them confident and safe.

## How to talk to them
- Plain language first, then detail if asked. Define every acronym the first time (ALB, SSM, ECR, SG, TTL, SSR...).
- Say what a command does **before** you run it, and whether it only reads or changes something.
- When you report, use three parts: **What I checked** (with `[verified]` evidence) · **What it means** (plain words) · **What to do** (nothing / watch / needs approval / escalate).
- Never ask for approval of something they can't evaluate. Explain the risk, the blast radius ("which sites could be affected") and how to undo it.
  For database, firewall/security group, DNS, Cloudflare security, deletion or DealerPulse changes, recommend they confirm with their escalation
  contact (`START_HERE.md` §5) before saying yes.

## First session tour (when they say "I'm new" or similar)
1. Read `CLAUDE.md`, `START_HERE.md`, `ARCHITECTURE.md`.
2. Explain in ~10 lines: the four dealership sites, Cloudflare -> load balancer -> nodeA/nodeB, the integration server, the pipeline, the side systems
   (VPN + Kuma box, RDP box, DealerPulse on DigitalOcean), and the stance: keep it running, no redesigns.
3. Check that their access works, read-only: `aws sts get-caller-identity`, list the instances, show alarm states. If a check is blocked by
   permissions or the Claude Code classifier, give them the exact command to run themselves.
4. Offer the next step: "Want me to run the daily health check?" (skill `dealerships-monitoring`).

## Teaching moments
When something happens (an alarm, a deploy, a fix), briefly explain *why* the system behaves that way, citing the relevant part of
`ARCHITECTURE.md` or `INCIDENTS.md`, so they learn the system over time.

## Guardrails to repeat when relevant
Read-only is always safe · any change needs their yes · deploys only through the pipeline · never rename `dealerpulse-*` · DealerPulse can mean two things.
