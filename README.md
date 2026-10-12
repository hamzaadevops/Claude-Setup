# Claude setup pack — moving to a new laptop

| File / folder | Purpose |
|---|---|
| `CONTEXT.md` | Full description of everything done in this account: projects, systems, timeline, open items, doc map, config inventory, security notes |
| `CLAUDE.md` | Standing rules for any Claude agent. Goes at the root of `Documentations` |
| `memory-export/` | Copy of Claude's saved memory (11 notes + index) |
| `skills-export/` | The two custom skills (`ConnectWireguardUI`, `MyUptimeIP`) |

## Steps on the new laptop

1. Install Claude Code, log in with your own account (do not copy `~/.claude/.credentials.json`), and install the
   AWS CLI v2, Git and an SSH client.
2. Clone the repo: `git clone https://github.com/hamzaadevops/Documentations.git` into `Documents/Documentations`.
   Commit this `Claude-Setup` folder first from the old laptop **only after** the review in step 7.
3. Copy `Claude-Setup/CLAUDE.md` to `Documentations/CLAUDE.md`. This is what lets a teammate's agent follow the
   same rules with no memory of its own.
4. Restore memory so your own agent has it. The folder name encodes the working directory path, so it must match
   the new path (replace `<new-folder>` with the encoded path Claude creates when you first open the project):
   `~/.claude/projects/<new-folder>/memory/` <- contents of `memory-export/`. Start Claude once in the project
   folder, then copy the files in.
5. Copy `skills-export/*` into `~/.claude/skills/`. Update the `~/.ssh/config` host aliases they depend on.
6. Re-create secrets by hand and by secure channel, never git: AWS credentials (`aws configure`), SSH keys
   (`team-vpn`, `digitalocean`), Bitbucket/Cloudflare tokens, the `.env`/`vars_*.json` files, DB dumps.
7. Review before pushing the pack to GitHub (see `CONTEXT.md` §8): the repo already tracks four `.env` files.
8. First session on the new laptop, ask the agent: *"Read Claude-Setup/CONTEXT.md and HANDOVER.md, then run the
   read-only checks in CONTEXT.md §9 and tell me what differs from what the docs say."*
9. Re-authorize claude.ai connectors you need (Slack, Notion, Gmail, ...).

## How a teammate (or their agent) confirms things on their own

- Point their Claude at `Documentations/` with `CLAUDE.md` in place. The rules, doc map and provenance convention
  load automatically.
- Anything marked `[doc]` is a claim from a file, not live truth. Each has a read-only command in `HANDOVER.md` §7
  or `CONTEXT.md` §9. The agent should run them and report differences.
- `MIGRATION_HISTORY.md` + `COMMAND_LOG.md` are the evidence trail for every resource.
