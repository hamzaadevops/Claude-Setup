# Claude-Setup — single source of truth for this account

Repo: `hamzaadevops/Claude-Setup`. Lives at `Documents\Claude-Setup`. **Keep the repo private** (see STATUS §5).

| File | Purpose |
|---|---|
| `CLAUDE.md` | Rules that always apply + reading order. Loaded through `Documents\CLAUDE.md` |
| `INTENT_ROUTER.md` | "When someone says X, do Y": disambiguation, triage, deploys, monitoring, writing, side systems, approval needs |
| `STATUS.md` | Open items, closed decisions, document conflicts, unknowns, security notes, refresh checklist |
| `INVENTORY.md` | AWS / Cloudflare / host / tenant / SSH / third-party identifiers |
| `RUNBOOKS.md` | Deploy, new dealership, daily sweep, access, Cloudflare changes, logging templates |
| `INCIDENTS.md` | Symptom -> cause -> fix table and recurring failure shapes |
| `DEALERPULSE.md` | The separate DigitalOcean project |
| `CONTEXT.md` | Narrative overview, timeline, doc map, Claude config inventory |
| `memory-export/`, `skills-export/` | Reference copy of old Claude memory and the two custom skills |
| `CLAUDE-root-pointer.md` | Copy of `Documents\CLAUDE.md` (the 4-line file that imports this pack) |

## Set up on a new laptop
1. Install Claude Code (log in fresh; never copy `~/.claude/.credentials.json`), AWS CLI v2, Git, OpenSSH.
2. `cd Documents`; clone `Claude-Setup` and `Documentations` (`hamzaadevops/...`) and the app repos (Bitbucket `nxpt/*`).
3. Copy `Claude-Setup\CLAUDE-root-pointer.md` to `Documents\CLAUDE.md`. Now any Claude session opened in `Documents` loads the rules, and a
   teammate's agent behaves the same with no private memory.
4. Copy `skills-export\*` to `~\.claude\skills\`. Restore SSH config aliases (INVENTORY §6), keys, `aws configure` by secure channel.
5. Optional: copy `memory-export\*.md` into `~\.claude\projects\<encoded-path>\memory\`. The pack already supersedes it.
6. First prompt: *"Read Claude-Setup/CLAUDE.md, INTENT_ROUTER.md and STATUS.md. Run the refresh checklist in STATUS §6 read-only and tell me
   what differs from the docs."*
7. Re-authorize claude.ai connectors you use.

## Keeping it true
Update the file in the same session you learn something. Mark `[verified]` with a date when you checked it live. Never store secrets here.
