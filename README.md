# claude-harness

Guardrails for every Claude Code session on a Mac, kept in one place. `install.sh` puts them in `~/.claude`, so they apply in any folder. Each repo keeps only its own test command, `.claude/verify.sh`.

Cloud sessions don't get these (they only see the repo). They run in isolated VMs that can't touch your machine, and GitHub rulesets protect the default branches.

Needs macOS (the sandbox uses Seatbelt), bash, git, and one of jq, python3 or node.

## What gets installed

| Where | What it does |
| :- | :- |
| `~/.claude/settings.json` | Turns on the Bash **sandbox** (with its own yarn cache, see below), adds **deny rules** (`sudo`, force/main pushes, `reset --hard origin/...`, deleting main/master, reading `.env`/key/credential files, and editing or writing `.env` and the credential files), and registers the two hooks. Merged into your existing settings: lists are unioned, your own values win. |
| `~/.claude/hooks/claude-harness/block-dangerous.sh` | Runs before every Bash command and blocks (exit 2, with the reason) force pushes, pushes to main/master (including `HEAD`/`@` from main), deleting main/master, `git reset --hard origin/...`, recursive `rm` of `/`, `~`, `$VARS`, `..`, the repo, `.git` or anything outside the repo (it follows `cd`), commands naming secret files, `curl ... \| sh`, and the git options that run a command (`push --receive-pack`/`--exec`, `fetch --upload-pack`, `ext::` remotes), since push and fetch run outside the sandbox. If it can't read its input, it blocks everything. |
| `~/.claude/hooks/claude-harness/stop-verify.sh` | Runs when Claude ends a turn. In a repo with work on the branch (uncommitted changes, or commits not on the default branch), it runs the repo's test command and, on failure, sends Claude back with the last 40 lines. One forced retry per turn, passes are cached per tree state, and the test command is killed after 540s. |
| | The test command runs in its own sandbox (`verify.sb`, below), since hooks run outside Claude's. If it can't be sandboxed, the stop is blocked rather than running it unsandboxed. |
| `~/.claude/hooks/claude-harness/verify.sb` | The Seatbelt profile for the test command, run with `sandbox-exec`. Like Claude's sandbox: writes only to the repo (but not its `.git/hooks` or `.git/config`, which the unsandboxed `git push` would run), temp, the sandbox's yarn cache and npm logs, and no reading the secret files the settings deny or the keychain. Network is localhost only, since Seatbelt can't filter by domain: a verify script that installs packages needs them installed first (run `yarn install` yourself with `!`). |
| | Work in a repo with no test command blocks the stop: "No test command for this repo. Add .claude/verify.sh or a supported test entry point." |
| | A `.claude/verify.sh` that differs from the branch's base (edited, added, deleted, even untracked or ignored) blocks the stop: Claude mustn't write its own gate. |
| `~/.claude/hooks/claude-harness/detect-verify.sh` | Prints the repo's test command, first match wins: `.claude/verify.sh` (run with `bash` if not executable), a real `test` script in `package.json` (yarn/pnpm/npm by lockfile), `cargo test`, `go test ./...`, pytest config, a Makefile `test:` target, a CMake build dir with `CTestTestfile.cmake`, or `CMakeLists.txt` with `enable_testing()`/`include(CTest)` (both build, then `ctest`). |
| `~/.claude/hooks/claude-harness/json-field.sh` | Reads the hook input with jq, python3 or node, whichever exists. |
| `~/.claude/CLAUDE.md` | A short "Guardrails" section and a "Public repos" section (between `<!-- claude-harness:start/end -->` markers) telling Claude what's in place and what never goes into a public commit. |

How the layers fit:
- **The sandbox** protects the machine. macOS enforces it on every shell command and everything those commands start: writes only inside the current project and temp folders, network only to `allowedDomains`. It blocks things no pattern can catch, like `python -c "shutil.rmtree(...)"`. `allowUnsandboxedCommands: false` takes away Claude's "retry outside the sandbox" fallback, and `failIfUnavailable` stops Claude Code from starting if the sandbox can't. It also stops Claude's shell from writing to `~/.claude`, so Claude can't edit these guardrails. Only `git push *`, `git fetch *` and `gh pr *` run outside it (they need the keychain; the hook blocks the options that make git run a command), and only as the whole command, not chained.
- **The sandbox's yarn cache.** Yarn's normal cache isn't writable in the sandbox, so `YARN_CACHE_FOLDER` points sandboxed yarn at `~/.cache/yarn-sandbox`. Because it persists, installs mostly skip the network, where yarn 1's downloads through the sandbox proxy sometimes abort (mostly the ~4 MB `@esbuild/*` tarballs). The normal cache stays off limits on purpose: yarn trusts cached packages without rechecking them, so a package planted from inside the sandbox would get installed outside it. For the same reason the Stop hook points the sandboxed test command at the sandbox's cache too.
- **Local ports.** `network.allowLocalBinding` lets sandboxed commands listen on localhost (macOS only), so dev servers and browser checks work. The trade-off: your real browser is on localhost too. A compromised dependency could read whatever the sandbox can read and serve it on a local port, and a hostile page in a normal tab could reach that port by DNS rebinding or a cross-origin request and carry the data past the network filter. That takes a malicious package and a hostile page at the same time, so it's unlikely, but it's why: dev servers must never use `--host`/`0.0.0.0`, Vite should stay current (its CORS and file-serving bugs are this attack), and the read-deny list should stay broad. A separate browser profile for dev-server testing helps too.
- **The hook** covers what the sandbox doesn't: pushes, git history, secrets inside the project. It's pattern matching, so unusual spellings can get past it.
- **Deny rules** are a second net for the same cases, and the only net for Claude's Edit and Write tools, which the Bash hook never sees (`Edit(...)` rules cover every built-in file-editing tool). They only cover `.env` and the credential files, not arbitrary text the hook blocks. Read rules also become sandbox read blocks, so keep them narrow: a rule like `Read(//**/*.pem)` would block `/etc/ssl/cert.pem` and break HTTPS for every command.
- **GitHub rulesets** (require PR, block force push and deletion, no admin bypass) are the hard stop for pushes, locally and in the cloud. The installer doesn't create them; set one up on each repo's default branch.

## Install or update

Run these yourself (with `!` inside Claude Code), because the sandbox stops Claude from writing to `~/.claude`:
```
~/.claude/hooks/claude-harness/install-from-github.sh --dry-run   # show what would change
~/.claude/hooks/claude-harness/install-from-github.sh             # do it
```
It clones `main` from GitHub into a temp folder and runs that `install.sh`, never the local clone. Claude can write to your local clone and move its local branches, and `install.sh` runs outside the sandbox, so installing from the local clone would run whatever a session left there. `main` on GitHub only changes when you merge a PR (the ruleset blocks direct pushes), so reviewing the PR is the review of what gets installed. The dry run shows full diffs of the scripts as well as the settings.

The first time, before `install-from-github.sh` is in `~/.claude`, copy `~/.claude/settings.json` somewhere safe, then run `install.sh` from a clone of `main` you've checked. If you fork this repo, point `repo=` in `install-from-github.sh` at your fork, and the "come from" path in `templates/CLAUDE.md.template` at your clone.

It's idempotent. Merging only adds entries, so to drop a rule an earlier version added, list it under `claudeHarnessRemove` in `templates/settings.json`. To undo everything, delete the `sandbox`, `hooks` and harness deny entries from `~/.claude/settings.json` (or restore that copy), delete `~/.claude/hooks/claude-harness/`, and remove the marked section from `~/.claude/CLAUDE.md`.

## Give a repo a verify script

Each repo keeps its verify script in its own `.claude/verify.sh`; `verify/` here only holds this repo's. Repos with a test entry point `detect-verify.sh` knows don't need one, but a verify script can also build, lint, or anything else. To add one, write `verify/<repo-name>.sh` here (tests, build; exit non-zero on failure), then:
```
./add-verify.sh /path/to/repo
```
commit `.claude/verify.sh` in the repo on a branch, and delete the copy here once it's merged, so there's only one to keep up to date.

## Test

```
hooks/test-block-dangerous.sh [path/to/block-dangerous.sh]
hooks/test-stop-verify.sh [path/to/stop-verify.sh]
```
Written for bash 3.2 (macOS); no jq needed. They work inside the sandbox. This repo's own `.claude/verify.sh` (from `verify/claude-harness.sh`) syntax-checks every script and runs both.

## Known gaps

- The hook is pattern matching: heredocs, `eval`, aliases, and scripts that run git themselves get past it. A commit message mentioning `rm -rf /` or `.env` gets blocked by mistake; rephrase it.
- `.env.example` is blocked too, to match the `.env.*` deny rule (deny rules can't make exceptions).
- Yarn downloads inside the sandbox can still abort when a package isn't cached yet (see "The sandbox's yarn cache" above; the cause in the proxy or yarn's HTTP client isn't pinned down). Retry, or run `yarn install` yourself with `!`. Yarn 1 leaves half-written cache entries behind; if errors name `.yarn-metadata.json`, delete those entries from `~/.cache/yarn-sandbox/v6`.
- Inside the sandbox, `gh` commands other than `gh pr`, `docker`, `open`, and starting another `claude` fail. Run them yourself with `!`.
- Only `.claude/verify.sh` is protected from Claude's edits. Detected entry points (a `package.json` test script, a Makefile target, CMake test definitions) can be weakened in the same diff they're supposed to check; review those changes too.
- The verify sandbox's own checks in `test-stop-verify.sh` only run outside a sandbox, because Seatbelt sandboxes can't nest. Inside Claude's sandbox or a sandboxed verify run they're skipped with a note, so once this version is installed they only run when you run the tests yourself with `!`.
- The verify sandbox's keychain block (denying the `securityd` lookups) is untested. `security find-generic-password` answers "not found" whether or not it can reach the keychain, and testing with a real stored password would put it in the test output.
- In a repo with no `origin/HEAD`, `origin/main` or `origin/master`, the verify.sh check compares against HEAD, so an edit Claude commits there isn't caught.
- The fail-closed blocks only cost one retry per turn (then `stop_hook_active` lets Claude stop), so they're a loud warning, not a wall.
- The jq path in `json-field.sh` is untested; the python3 and node paths are tested.
