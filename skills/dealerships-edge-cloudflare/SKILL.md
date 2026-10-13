---
name: dealerships-edge-cloudflare
description: "Cloudflare and network edge for the Dealerships platform: zones, SSL mode, cache rules, WAF, country allow-list, HSTS, hotlink protection, purge, origin lockdown via security groups and Cloudflare prefix lists, certificates (ACM + Let's Encrypt). Use for 52x errors, redirect loops, stale content or images, blocked visitors/vendors, cache questions, cert expiry, DNS, or any Cloudflare/SG question."
---

# Edge: Cloudflare, security groups, certificates

## Zones
- `callingyounow.us` (ours, Free plan): zone `283d6090889e4fdd64e23e6790cfa50a`, account `b99522927fa24d3bce77b812f591b7a3`.
- `puentehillsnissan.com`: dealer group's account (zone `d68d738c1d15ec0cd770a9533e16d5ae`). We have access; coordinate before changing.
- API tokens are never stored. Ask the user for one per session. Token creation is blocked for Claude; the user creates tokens in the dashboard.

## Settings in force
SSL **Full**; always HTTPS; HSTS 300 s (no includeSubDomains/preload); min TLS 1.2; early hints; hotlink protection on; Auto Minify cannot be enabled (no-ops).
WAF Free Managed Ruleset (Block, zone-wide). Custom rule: block unless country in **US, CA, PK, JP**; ACME challenge path exempt. Rulesets are full-replace PUT.

## Cache rules
Static assets 30 days by **extension** (also catches `public/` images); `/_next/image` cached; HTML edge-cached respecting origin ISR headers,
excluding `/api/*`, `/_next/*` and RSC headers (`rsc`, `next-router-state-tree`, `next-router-prefetch`, `next-url`; keep this or the cache is poisoned);
response-phase `strip_set_cookie` (may be API-only, not visible in the UI); 4xx/5xx edge TTL 0 on the static rule. "Cache Everything [Template]" must stay **disabled**.
Purge runs automatically after each frontend deploy.

## Origin lockdown
ALB SG `sg-034a06fe048939fc5` and integration SG `sg-097c63c5851f32550` allow 80/443 only from prefix lists `pl-0dc48316ba9fa95bd` (v4) and
`pl-0a7981fd8cec1fa9a` (v6). Node SG `sg-0587ebfd9dd3a52a7` allows only the ALB SG. Direct IP access times out by design.

## Certificates
ALB: ACM (SNI per hostname). Nodes: Let's Encrypt via `certbot.timer` (once found silently broken) or a self-signed cert for some hosts
(acceptable because SSL mode is Full and the origin is locked). DNS-01 is needed for hosts behind the ALB.

## Debug order
1. SG/prefix-list drift (522/524) or a node carrying a second SG. 2. Extension-based static cache (old image/asset). 3. HSTS window after an HTTPS hiccup.
4. Hotlink protection (broken social previews / partner images). 5. Country rule (Security -> Events). 6. Expired origin cert (525/526). Only then the app.
Dashboard: Security -> WAF / Events; Caching -> Cache Rules.
