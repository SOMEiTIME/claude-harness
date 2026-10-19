# claude-harness

Guardrails for every Claude Code session on this Mac, kept in one place. `install.sh` puts them in `~/.claude`, so they apply in any folder. Each repo keeps only its own test command, `.claude/verify.sh`.

Cloud sessions don't get these (they only see the repo). They run in isolated VMs that can't touch this machine, and GitHub rulesets protect the default branches.

## What gets installed

| Where | What it does |
| :- | :- |
| `~/.claude/settings.json` | Turns on the Bash **sandbox** (with its own yarn cache, see below), adds **deny rules** (`sudo`, force/main pushes, `reset --hard origin/...`, deleting main/master, reading `.env`/key/credential files), and registers the two hooks. Merged into your existing settings: lists are unioned, your own values win. |
| `~/.claude/hooks/claude-harness/block-dangerous.sh` | Runs before every Bash command and blocks (exit 2, with the reason) force pushes, pushes to main/master (including `HEAD`/`@` from main), deleting main/master, `git reset --hard origin/...`, recursive `rm` of `/`, `~`, `$VARS`, `..`, the repo, `.git` or anything outside the repo (it follows `cd`), commands naming secret files, and `curl ... \| sh`. If it can't read its input, it blocks everything. |
| `~/.claude/hooks/claude-harness/stop-verify.sh` | Runs when Claude ends a turn. In a repo with `.claude/verify.sh` and work on the branch (uncommitted changes, or commits not on the default branch), it runs the script and, on failure, sends Claude back with the last 40 lines. One forced retry per turn, passes are cached per tree state, and verify is killed after 540s. |
| `~/.claude/hooks/claude-harness/json-field.sh` | Reads the hook input with jq, python3 or node, whichever exists. |
| `~/.claude/CLAUDE.md` | A short "Guardrails" section (between `<!-- claude-harness:start/end -->` markers) telling Claude what's in place. |

How the layers fit:
- **The sandbox** protects the machine. macOS enforces it on every shell command and everything those commands start: writes only inside the current project and temp folders, network only to `allowedDomains`. It blocks things no pattern can catch, like `python -c "shutil.rmtree(...)"`. `allowUnsandboxedCommands: false` takes away Claude's "retry outside the sandbox" fallback, and `failIfUnavailable` stops Claude Code from starting if the sandbox can't. It also stops Claude's shell from writing to `~/.claude`, so Claude can't edit these guardrails. Only `git push *` and `gh pr *` run outside it (they need the keychain), and only as the whole command, not chained.
- **The sandbox's yarn cache.** Yarn's normal cache isn't writable in the sandbox, so `YARN_CACHE_FOLDER` points sandboxed yarn at `~/.cache/yarn-sandbox`. Because it persists, installs mostly skip the network, where yarn 1's downloads through the sandbox proxy sometimes abort (mostly the ~4 MB `@esbuild/*` tarballs). The normal cache stays off limits on purpose: yarn trusts cached packages without rechecking them, so a package planted from inside the sandbox would get installed outside it. For the same reason the Stop hook unsets `YARN_CACHE_FOLDER` before running verify.
- **The hook** covers what the sandbox doesn't: pushes, git history, secrets inside the project. It's pattern matching, so unusual spellings can get past it.
- **Deny rules** are a second net for the same cases. Read rules also become sandbox read blocks, so keep them narrow: an earlier `Read(//**/*.pem)` blocked `/etc/ssl/cert.pem` and broke HTTPS for every command.
- **GitHub rulesets** (require PR, block force push and deletion, no admin bypass) are the hard stop for pushes, locally and in the cloud.

## Install or update

Run these yourself (with `!` inside Claude Code), because the sandbox stops Claude from writing to `~/.claude`:
```
~/Documents/GitHub/claude-harness/install.sh --dry-run   # show what would change
~/Documents/GitHub/claude-harness/install.sh             # do it
```
It's idempotent. Merging only adds entries, so to drop a rule an earlier version added, list it under `claudeHarnessRemove` in `templates/settings.json`. To undo everything, delete the `sandbox`, `hooks` and harness deny entries from `~/.claude/settings.json` (or restore `settings.json.bak-20261018`), delete `~/.claude/hooks/claude-harness/`, and remove the marked section from `~/.claude/CLAUDE.md`.

## Give a repo a verify script

Write `verify/<repo-name>.sh` here (tests, build; exit non-zero on failure), then:
```
./add-verify.sh /path/to/repo
```
and commit `.claude/verify.sh` in the repo on a branch.

## Test

```
hooks/test-block-dangerous.sh [path/to/block-dangerous.sh]
hooks/test-stop-verify.sh [path/to/stop-verify.sh]
```
Written for bash 3.2 (macOS); no jq needed. They work inside the sandbox.

## Known gaps

- The hook is pattern matching: heredocs, `eval`, aliases, and scripts that run git themselves get past it. A commit message mentioning `rm -rf /` or `.env` gets blocked by mistake; rephrase it.
- `.env.example` is blocked too, to match the `.env.*` deny rule (deny rules can't make exceptions).
- Yarn downloads inside the sandbox can still abort when a package isn't cached yet (see "The sandbox's yarn cache" above; the cause in the proxy or yarn's HTTP client isn't pinned down). Retry, or run `yarn install` yourself with `!`. Yarn 1 leaves half-written cache entries behind; if errors name `.yarn-metadata.json`, delete those entries from `~/.cache/yarn-sandbox/v6`.
- Inside the sandbox, `gh` commands other than `gh pr`, `docker`, `open`, and starting another `claude` fail. Run them yourself with `!`.
- The jq path in `json-field.sh` is untested (jq isn't installed here); the python3 and node paths are tested.
