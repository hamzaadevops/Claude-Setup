# PRE-WIPE CHECKLIST — audited 2026-10-13 (read-only, all [verified] on this laptop)

Do not clear the old laptop until every box in sections 1-3 is ticked or consciously dropped.

## 0. Already deleted on this laptop at the user's request (2026-10-13, permanent, verified gone)
`Downloads\Chrome Passwords.csv`; `Downloads\Joblogic\` (three Azure DevOps repos, all clean and pushed beforehand); `~\wildcard-jlautomationapps.pfx`;
`~\.claude\projects\...Downloads-Joblogic\` transcripts; `Downloads\Tax\` folder, `TaxCertificate_*`, `Tax_Year_2026_Case_Summary_*`, the loose `114(1)` return,
`Payslip_J0469.pdf`, `UBL-8Sep2025-5thOct2025.pdf`, `economic-transactions-summary.xlsx`; both `*_credentials.csv`; `HamzaDevOps.conf`, `ShahzadH-Mac.conf`,
`hamza-windows.conf`; CNIC images; three CV files in Downloads. Sections 2 and 4 below were written **before** these deletions and still list them for the record.
Still on disk: `.ssh` keys, `Documents\vars_*.json`, `env_list.json`, DB dumps, `Default.rdp`, other CV copies in `Documentations\` and `~\hamza\`.
**Not done (needs the user):** credential rotation for anything those files held; wg-easy peer deletion; unpushed branches/stashes in section 1.
Live-server refresh could not be run from this session (classifier denied AWS read and push); the new laptop's first session does it (see the final prompt).
Corona Nissan: user says migrated (2026-10-13, date unverified). Unknown whether the Documentations repo was pushed; Claude-Setup is the repo that matters.

## 1. Work that exists ONLY on this laptop (not on any remote)  — push or export it
| Where | What | Action |
|---|---|---|
| `Documents\website_frontend` branch **`perf/next-image-optimizer-2026-09-22`** | 1 local commit `b9708de` "drop AVIF and the 1920 width from the image optimizer" (the TODO item 12 fix). No remote branch, 204 commits behind main-migrated | Push the branch or tell the dev team; likely needs rebase |
| `website_frontend` branch **`merge/staging-into-main-corona-2026-10-07`** | local merge `d372310` (1 ahead of origin/main-corona, 10 behind) | Push or discard knowingly |
| `website_frontend` branch **`feat/cf-purge-staging-2026-10-01`** | local-only branch `ab9be68` "Add Cloudflare cache purge step to the staging pipeline" | Push or discard knowingly |
| `Documents\framework_frontend` branch `main-migrated` | **3 commits ahead** of origin, tip `2e5e625` merge of origin/staging | Push or discard knowingly |
| `Documentations` | uncommitted `HANDOVER.md` edit; untracked `HANDOVER.docx`, `DevOps_Handover_Dealerships_AWS_Readable.docx` | Commit and push |
| `Claude-Setup` | staged deletions of `memory-export/`, edits, 7 new files, `machine-config/` | Commit and push (STATUS §5 notes) |
| **Git stashes** (never pushed) | `chat_back` 1 (compose + pipeline edits), `integrations_service` 2 (compose, .env.example, .gitignore), `ocean` 1 (pipelines yml, 20 lines removed), `starfish` 1 (next.config.mjs). The three `pre-pull 20261003T021141` stashes are auto-stashes from `deploy.sh`-style pulls | Look at each with `git stash show -p`; keep a `git stash show -p > file.patch` copy if you care, otherwise drop |
| `starfish` branch `hanan` | no unpushed commits, but check it is the branch you want | none |

Verified clean (no unpushed commits, no uncommitted changes): `chat_back`, `ocean`, `integrations_service`, `dp_backend_v2`, `dp_frontend_v2`, `starfish`.
`chat_back` commit `3ed8deb` (uvicorn workers default 2) **is contained in `origin/main-migrated`**, so STATUS item 2 is pushed; whether it was **deployed** is unknown.

## 2. Secrets and credentials on disk (names only; I did not open any of them)
Move securely or recreate; never commit.
- `~\.ssh\`: `digitalocean`, `team-vpn` (+ `.pub`), `config` (copied to `machine-config\ssh_config.txt`), `known_hosts`.
- `~\.aws\`: uses `aws login` console session (`login_session` = `HamzaDevOps`); there is **no static credentials file**. On the new laptop run `aws login` or `aws configure`.
- `~\wildcard-jlautomationapps.pfx`: a certificate private key (appears to belong to Joblogic, not this project).
- `Downloads\`: **`Chrome Passwords.csv`** (plain-text password export), `ShahzadHussain_credentials.csv`, `hamza.zahid@flutenai.com_credentials.csv` (likely IAM/console credentials), `HamzaDevOps.conf`, `ShahzadH-Mac.conf`, `hamza-windows.conf` (small files that look like WireGuard client configs with private keys), `access-tokens.htm`.
  Delete the Chrome export after importing into a password manager. Revoke/rotate the credentials in the CSVs and the WireGuard peers (regenerate in wg-easy) if the company laptop is handed back.
- `Documents\`: `vars_*.json`, `env_list.json`, `Migration\surfcity-pipeline-variables.txt`, `Documentations\*.env` (four tracked in git), dumps `dealerpulse.dump`, `nisan_website.dump`, `Migration\db-backups\*.dump`, `Default.rdp`.
- Saved Windows credential `TERMSRV/93.127.140.109` (RDP box). Cloudflare/Bitbucket tokens were never stored (supplied per session; some may sit in old session scratchpads under `%TEMP%\claude`).
- Browser profiles (Chrome "Hamza - Chrome", Edge), `.docker` login, `.codex`, `.copilot`, `.TurboVPN`: sign out and export bookmarks if wanted.

## 3. Claude data on this laptop
- `~\.claude\projects\` 139 MB Documents project, 26 MB `hamza`, 3.8 MB Joblogic, plus ocean/integrations/website-frontend: **chat transcripts (.jsonl)**. They are the audit trail (why decisions were made). Zip them to private encrypted storage if you want them; do not commit (they may contain pasted secrets).
- Memory: Documents project memory is in the pack history; **other-project memory** is only `website-frontend/multi-frontend-deploy.md` (copied to `machine-config\OLD_...`; it is stale: it predates `main-surfcity/-corona/-sanbernardino` and the atomic deploy). `Joblogic` and `hamza` have no memory.
- `~\.claude\skills\` ConnectWireguardUI + MyUptimeIP: in `skills-export\`. Synced skills return on login.
- `~\.claude.json` (MCP/server state), `settings.json` (copied: model sonnet, effort high), `Documents\.claude\settings.local.json` (old permission allow-list; do not copy).
- Other AI tools with local state: `.codex` (sqlite memories/goals), `.copilot`. Not part of this pack.
- Shell helpers (copied to `machine-config\`): `node_a`, `node_b`, `node_int` SSM shortcuts in `.bashrc` and the PowerShell profile (hard-coded `aws.exe` path).

## 4. Non-Dealerships material found (decide where it lives)
- `Downloads\Joblogic\` (Azure container apps, devops-templates, dev-container-automation) and `~\hamza\` (GitHub profile README, CVs): **another job/personal**, not Dealerships. Check ownership before copying work files off a company laptop.
- Personal documents in `Downloads\` (tax, CNIC, payslip, bank statement, CVs) and `Desktop\`: back up privately; not for any shared repo.
- Installers/tools: `doctl` (DigitalOcean CLI), Docker Desktop, WSL. Reinstall on the new laptop.
- Large files you may not need to move: `ATL_IT.xlsx` (185 MB), `Docker Desktop Installer.exe` (659 MB).

## 5. Repos to re-clone on the new laptop (remote URLs verified)
Bitbucket `nxpt`: `ocean`, `website_frontend`, `integrations_service`, `chat_back`, `framework_frontend`, `starfish`, `backend_v2.1` (-> `dp_backend_v2`), `dp_frontend_v2`. GitHub: `hamzaadevops/Documentations`, `hamzaadevops/Claude-Setup`. Bitbucket remotes use user `hamzakhan18`: log in again with an app password you create yourself.
Git identity: `Hamza Khan <hamza.khan@flutenai.com>`.

## 6. Final go / no-go
[ ] Section 1 pushed or consciously dropped  [ ] Pack committed, pushed, repo private  [ ] SSH keys + any needed files moved securely
[ ] Chrome password export deleted  [ ] Credentials rotated per company policy  [ ] Transcripts archived (optional)
[ ] New laptop: Claude-Setup prompt run, `aws login`, STATUS §6 refresh run
