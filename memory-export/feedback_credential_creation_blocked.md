---
name: feedback-credential-creation-blocked
description: "Claude Code's auto-mode classifier blocks whole categories of action outright (credential creation, live shared-resource mutation, even harmless local mocks of them) regardless of explicit user authorization"
metadata: 
  node_type: memory
  type: feedback
  originSessionId: 0f9f7dc9-49b0-49d8-a9a8-badb7a12d70c
  modified: 2026-09-17T16:36:10.359Z
---

Don't attempt to create new API tokens/credentials programmatically (e.g. `POST` to a provider's token-creation endpoint), even when the user explicitly says to and even when they supply a "creator" credential scoped to allow it. Claude Code's auto-mode classifier blocks this class of action ("Secret-Store Writes") at the tool layer, independent of any tool used (hit this identically via both Bash and PowerShell) and independent of conversational consent — the user saying "yes, do it" or "I allow you" in chat does not lift the block, because it isn't a permission-mode prompt, it's a hardcoded safety classifier.

**Why:** observed directly on [[project-dealerships-cloudflare-config]] (2026-09-16) — user provided a Cloudflare token with "create additional tokens" permission and explicitly authorized minting a new scoped token from it, twice, in separate messages. Both attempts were denied with the same reason before any HTTP call completed.

**How to apply:** the first denial is the signal to stop retrying the same action (matches the general "don't re-attempt an identical denied tool call" rule) — don't try a third tool or a cleverer payload. Instead immediately offer the two real paths: (1) the user adjusts their own Claude Code Bash-permission settings if they want this class of action allowed going forward, or (2) — faster in practice — the user creates the credential themselves via the provider's own dashboard/UI and pastes the result back in. Path 2 resolved this specific incident in under a minute once offered. This generalizes beyond Cloudflare to any "mint a new secret" action (API tokens, access keys, signing keys, etc.) — expect the same block, don't assume a specific provider or tool combination is what triggered it.

**Same classifier family, two more categories hit later the same project (2026-09-16/17), worth expecting again:**
- **"Modify Shared Resources"** — blocked a real `curl -X POST .../purge_cache` call (a genuine live write to shared production infrastructure, reasonable to block). But it *also* blocked a purely local, no-network shell command that only echoed a **mocked** JSON string and grepped it, with zero real API interaction — apparently triggered by surface pattern-matching (the word "purge"/API-shaped JSON in the command text) rather than true semantic risk. **Don't retry with a "safer-looking" rephrasing once this fires** — treat any command touching that topic as blocked for the rest of the turn, verify the underlying logic by inspection/reasoning instead, and note explicitly to the user that the mechanism is unverified in a sandbox.
- **"Remote Shell Writes"** — blocked an `aws ssm send-command` that included a `pip install` step, even though it was only there to enable a read-only YAML validation on a shared EC2 node (not related to the actual deploy). Fix that worked: re-send the command with the install line removed and check first whether the tool was already present (it was) — a purely read-only remote command (no install, no file write) went through fine.

**General lesson across all three**: this classifier operates on the *shape* of the action (creating a secret, writing to a shared resource, installing/writing on a remote host) more than on the actual intent or context behind it, so a denial doesn't mean the specific thing you're doing is unsafe — it means that whole category is gated. Don't argue with it or reword the same request. Either restructure to a genuinely read-only/local equivalent, or hand the exact step to the user to run themselves.
