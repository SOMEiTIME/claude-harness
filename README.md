# claude-harness

Guardrails for every Claude Code session on a Mac, kept in one place. `install.sh` puts them in `~/.claude`, so they apply in any folder. Each repo keeps only its own test command, `.claude/verify.sh`.

Cloud sessions don't get these (they only see the repo). They run in isolated VMs that can't touch your machine, and GitHub rulesets protect the default branches.

Needs macOS (the sandbox uses Seatbelt), bash, git, and one of jq, python3 or node. The installer needs python3.

## What gets installed

| Where | What it does |
| :- | :- |
| `~/.claude/settings.json` | Turns on the Bash **sandbox** (with its own yarn cache, see below), adds **deny rules** (`sudo`, force/main pushes, `reset --hard origin/...`, deleting main/master, reading `.env`/key/credential files, editing or writing `.env` and the credential files), and registers the two hooks. Merged into your existing settings: lists are unioned, your own values win. |
| `~/.claude/hooks/claude-harness/block-dangerous.sh` | Runs before every Bash command and blocks (exit 2, with the reason) force pushes, pushes to main/master (including `HEAD`/`@` from main), deleting main/master, `git reset --hard origin/...`, recursive `rm` of `/`, `~`, `$VARS`, `..`, the repo, `.git` or anything outside the repo (it follows `cd`), commands naming secret files, `curl ... \| sh`, the git options that run a command (`push --receive-pack`/`--exec`, `fetch --upload-pack`, `ext::` remotes), pushes to a local repo (a path or `file://`, whose hooks the push would run), and `gh pr` reading a body file that isn't a regular file in the repo or temp, or input from `<` or `$(...)`, since push, fetch and `gh pr` run outside the sandbox. If it can't read its input, it blocks everything. |
| `~/.claude/hooks/claude-harness/stop-verify.sh` | Runs when Claude ends a turn. In a repo with work on the branch (uncommitted changes, or commits not on the default branch), it runs the repo's test command and, on failure, sends Claude back with the last 40 lines. One forced retry per turn, passes are cached per tree state, and the test command is killed after 540s. |
| | It also blocks the stop if there's work but no test command ("No test command for this repo. Add .claude/verify.sh or a supported test entry point."), if `.claude/verify.sh` differs from the branch's base (edited, added, deleted, even untracked or ignored: Claude mustn't write its own gate), or if the test command can't be sandboxed. Hooks run outside Claude's sandbox, so the test command runs in its own (`verify.sb`), never unsandboxed. |
| `~/.claude/hooks/claude-harness/verify.sb` | The Seatbelt profile for the test command, run with `sandbox-exec`. Like Claude's sandbox: writes only to the repo (but not its `.git/hooks` or `.git/config`, which the unsandboxed `git push` would run), temp, the sandbox's yarn cache and npm logs; no reading the secret files the settings deny or the keychain. Network is localhost only, since Seatbelt can't filter by domain, so install dependencies first (run `yarn install` yourself with `!`). |
| `~/.claude/hooks/claude-harness/detect-verify.sh` | Prints the repo's test command, first match wins: `.claude/verify.sh` (run with `bash` if not executable), a real `test` script in `package.json` (yarn/pnpm/npm by lockfile), `cargo test`, `go test ./...`, pytest config, a Makefile `test:` target, a CMake build dir with `CTestTestfile.cmake`, or `CMakeLists.txt` with `enable_testing()`/`include(CTest)` (both build, then `ctest`). |
| `~/.claude/hooks/claude-harness/json-field.sh` | Reads the hook input with jq, python3 or node, whichever exists. |
| `~/.claude/CLAUDE.md` | A "Guardrails" and a "Public repos" section (between `<!-- claude-harness:start/end -->` markers) telling Claude what's in place and what never goes into a public commit. |

How the layers fit:
- **The sandbox** protects the machine. macOS enforces it on every shell command and everything it starts: writes only inside the current project and temp folders, network only to `allowedDomains`. It blocks what no pattern can catch, like `python -c "shutil.rmtree(...)"`, and stops Claude's shell from writing to `~/.claude`, so Claude can't edit these guardrails. `allowUnsandboxedCommands: false` removes Claude's "retry outside the sandbox" fallback, and `failIfUnavailable` stops Claude Code from starting without the sandbox. Only `git push *`, `git fetch *` and `gh pr *` run outside it (they need the keychain; the hook blocks the ways they could run a command or read a file the sandbox can't), and only as the whole command, not chained.
- **The sandbox's yarn cache.** Yarn's normal cache isn't writable in the sandbox, so `YARN_CACHE_FOLDER` points sandboxed yarn (and the Stop hook's test command) at `~/.cache/yarn-sandbox`. Because it persists, installs mostly skip the network, where yarn 1's downloads through the sandbox proxy sometimes abort (mostly the ~4 MB `@esbuild/*` tarballs). The normal cache stays off limits on purpose: yarn trusts cached packages without rechecking them, so a package planted from inside the sandbox would get installed outside it.
- **Local ports.** `network.allowLocalBinding` lets sandboxed commands listen on localhost (macOS only), so dev servers and browser checks work. The trade-off: your real browser is on localhost too. A compromised dependency could read whatever the sandbox can read and serve it on a local port, and a hostile page in a normal tab could reach that port by DNS rebinding or a cross-origin request and carry the data past the network filter. That needs a malicious package and a hostile page at once, so it's unlikely, but it's why dev servers must never use `--host`/`0.0.0.0`, Vite should stay current (its CORS and file-serving bugs are this attack), and the read-deny list should stay broad. A separate browser profile for dev-server testing helps too.
- **The hook** covers what the sandbox doesn't: pushes, git history, secrets inside the project. It's pattern matching, so unusual spellings can get past it.
- **Deny rules** are a second net for the same cases, and the only net for Claude's Edit and Write tools, which the Bash hook never sees (`Edit(...)` rules cover every built-in file-editing tool). They only cover `.env` and the credential files, not everything the hook blocks. Read rules also become sandbox read blocks, so keep them narrow: `Read(//**/*.pem)` would block `/etc/ssl/cert.pem` and break HTTPS for every command.
- **GitHub rulesets** (require PR, block force push and deletion, no admin bypass) are the hard stop for pushes, locally and in the cloud. The installer doesn't create them; set one up on each repo's default branch.

## Install or update

Run these yourself (with `!` inside Claude Code), because the sandbox stops Claude from writing to `~/.claude`:
```
~/.claude/hooks/claude-harness/install-from-github.sh --dry-run   # show what would change
~/.claude/hooks/claude-harness/install-from-github.sh             # do it
```
It clones `main` from GitHub into a temp folder and runs that `install.sh`, never the local clone. Claude can write to your local clone and move its branches, and `install.sh` runs outside the sandbox, so installing from the local clone would run whatever a session left there. `main` on GitHub only changes when you merge a PR (the ruleset blocks direct pushes), so reviewing the PR is reviewing what gets installed. The dry run shows full diffs of the scripts and the settings.

The first time, before `install-from-github.sh` is in `~/.claude`, back up `~/.claude/settings.json`, then run `install.sh` from a clone of `main` you've checked. If you fork this repo, point `repo=` in `install-from-github.sh` at your fork, and the "come from" path in `templates/CLAUDE.md.template` at your clone.

It's idempotent. Merging only adds entries, so to drop a rule an earlier version added, list it under `claudeHarnessRemove` in `templates/settings.json`. To undo everything, delete the `sandbox`, `hooks` and harness deny entries from `~/.claude/settings.json` (or restore the backup), delete `~/.claude/hooks/claude-harness/`, and remove the marked section from `~/.claude/CLAUDE.md`.

## Give a repo a verify script

Repos with a test entry point `detect-verify.sh` knows don't need one, but a verify script can also build, lint, or anything else. Write `verify/<repo-name>.sh` here (exit non-zero on failure), run `./add-verify.sh /path/to/repo`, commit `.claude/verify.sh` in the repo on a branch, and delete the copy here once it's merged, so there's only one to keep up to date. `verify/` only keeps this repo's own.

## Test

```
hooks/test-block-dangerous.sh [path/to/block-dangerous.sh]
hooks/test-stop-verify.sh [path/to/stop-verify.sh]
```
Written for bash 3.2 (macOS); no jq needed. They work inside the sandbox. This repo's `.claude/verify.sh` (from `verify/claude-harness.sh`) syntax-checks every script and runs both.

## Known gaps

- The hook is pattern matching: heredocs, `eval`, aliases, and scripts that run git themselves get past it. A commit message mentioning `rm -rf /` or `.env` gets blocked by mistake; rephrase it.
- `.env.example` is blocked too, to match the `.env.*` deny rule (deny rules can't make exceptions).
- Yarn downloads inside the sandbox can still abort when a package isn't cached yet (the cause, in the proxy or yarn's HTTP client, isn't pinned down). Retry, or run `yarn install` yourself with `!`. Yarn 1 leaves half-written cache entries behind; if errors name `.yarn-metadata.json`, delete those entries from `~/.cache/yarn-sandbox/v6`.
- Inside the sandbox, `gh` commands other than `gh pr`, `docker`, `open`, and starting another `claude` fail. Run them yourself with `!`.
- Only `.claude/verify.sh` is protected from Claude's edits. Detected entry points (a `package.json` test script, a Makefile target, CMake test definitions) can be weakened in the same diff they're supposed to check; review those changes too.
- Seatbelt sandboxes can't nest, so `test-stop-verify.sh` skips the verify sandbox's own checks (with a note) inside Claude's sandbox or a sandboxed verify run. Once installed, they only run when you run the tests yourself with `!`.
- The verify sandbox's keychain block (denying the `securityd` lookups) is untested: `security find-generic-password` answers "not found" whether or not it reaches the keychain, and testing with a real stored password would put it in the test output.
- In a repo with no `origin/HEAD`, `origin/main` or `origin/master`, the verify.sh check compares against HEAD, so an edit Claude commits there isn't caught.
- `git push` with an environment variable in front (`GIT_SSH_COMMAND=... git push`) gets past the hook. Whether Claude Code still runs it outside the sandbox (matching `git push *`) is unchecked.
- The Stop hook's pass record (`.git/claude-verify-passed`) is writable from Claude's sandbox, so Claude could fake a pass. It's a quality gate, not a security boundary.
- The fail-closed blocks only cost one retry per turn (then `stop_hook_active` lets Claude stop), so they're a loud warning, not a wall.
- The jq path in `json-field.sh` is untested; the python3 and node paths are tested.
