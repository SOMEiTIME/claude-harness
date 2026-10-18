# claude-harness

Guardrails for long-running Claude Code sessions, installed into each repo as committed files so they also apply in cloud sessions (which only read the repo's `.claude/settings.json`, not `~/.claude/settings.json`).

## What it installs

| File in the repo | What it does |
| :- | :- |
| `.claude/hooks/block-dangerous.sh` | `PreToolUse` hook on Bash. Exits 2 (blocks, with the reason) for force pushes, pushes to main/master, deleting main/master, `git reset --hard origin/...`, recursive `rm` of `/`, `~`, `$VARS`, `..`, the repo, `.git` or anything outside the repo, commands naming `.env`/`*.pem`/`*.key`/SSH keys/credential files, and `curl ... \| sh`. |
| `.claude/hooks/stop-verify.sh` | `Stop` hook. When Claude ends a turn with work on the branch (uncommitted changes, or commits not on the default branch), runs `.claude/verify.sh`. On failure it exits 2 with the last 40 lines, so Claude keeps fixing. One forced retry per turn (`stop_hook_active`), passes are cached per tree state, and verify is killed after 540s. |
| `.claude/hooks/json-field.sh` | Reads one field from the hook JSON with jq, python3 or node, whichever exists. |
| `.claude/verify.sh` | The repo's "done" check (tests, build, ...), from `verify/<repo-name>.sh`. |
| `.claude/settings.json` | Registers the hooks and adds `permissions.deny` rules for the same push/reset/branch/secret cases. |
| `CLAUDE.md` | Gets a short "Guardrails" section between `<!-- claude-harness:start/end -->` markers. |

How the layers fit, and their limits:
- **Deny rules** apply in every permission mode, but they match the command text as Claude writes it. The docs say they're not a security boundary: other spellings, and scripts that read files themselves, get past them.
- **The hook** catches more spellings (flags in any order, `git -C`, compound commands, `$(...)`), but it's still pattern matching. It fails open if it can't parse its input.
- **GitHub rulesets** (require PR, block force push and deletion) are the only hard stop for pushes. Set them up on every repo.
- Claude Code also has its own built-in refusal of `rm` on critical paths.

## Install into a repo

```
./install.sh /path/to/repo
```
Then commit `.claude/` and `CLAUDE.md` on a branch and open a PR. The script is idempotent and merges rather than overwrites: lists in an existing `settings.json` are unioned with the template, existing values win, an existing `verify.sh` is left alone, and the CLAUDE.md section is only added once. Needs python3 for the merge.

For a new repo, add `verify/<repo-name>.sh` first (the name comes from the origin URL). Otherwise install writes a stub that always passes.

Updating: edit the files here, re-run `install.sh` on each repo, commit. `install.sh` updates the hooks and adds new settings entries, but it won't remove deny rules or rewrite an existing `verify.sh` or CLAUDE.md section. Edit those by hand.

## Test

```
hooks/test-block-dangerous.sh [repo/.claude/hooks/block-dangerous.sh]
hooks/test-stop-verify.sh [repo/.claude/hooks/stop-verify.sh]
```
Scripts are written for bash 3.2 (macOS) and don't need jq.

## Known gaps

- Pattern matching, not parsing: heredocs, `eval`, aliases, or a script that runs `git push --force` internally get through. So does a commit message containing `rm -rf /` or `.env`, which gets blocked by mistake (rephrase it).
- `.env.example` is blocked too, to match the `Read(**/.env.*)` deny rule, which can't make exceptions.
- `stop-verify.sh` runs `verify.sh` with whatever toolchain the session has. In a fresh cloud container, the verify scripts install node deps if `node_modules` is missing; other tools (yarn, gtest) have to be in the image.
