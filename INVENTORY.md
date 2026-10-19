# Inventory (2026-10-18)

All four repos are under `SOMEiTIME/` on GitHub and cloned in `~/Documents/GitHub/`. None had a `.claude/settings.json` or hooks before the harness. music_viz_gltchr had an empty, untracked `.claude/worktrees/`. All four have a CLAUDE.md (35–46 lines) with a git workflow section: branch per change, never commit/push to the default branch, PRs without asking, no merging.

Local toolchain (macOS): bash 3.2, Node 18.16, yarn 1.22, Python 3.6.3 (Anaconda), Apple clang 14. **Not installed: jq, `timeout`, gtest, docker.**

## Media-Eroder
- Stack: vanilla JS on Vite 4. Early stage (PLAN.md).
- Install `yarn`; build `yarn build`; dev `yarn dev`. **No tests, no linter.**
- CI: none.
- Default branch: `master` (origin/HEAD isn't set locally; checked with `gh repo view`).
- Visibility: was **private**. Made public on 2026-10-18 at the user's request, after a history scan: 12 source/doc files, no secret-like strings, only the GitHub noreply author email.
- Branch protection: none. Before going public: 403 "Upgrade to GitHub Pro or make this repository public". After: no rulesets.
- verify.sh: `yarn build` (installs deps first if `node_modules` is missing).

## Media-Glitcher
- Stack: Python 3, stdlib only (also runs in a-Shell on iPhone).
- No install step. Tests: `python3 -m unittest discover -s tests`. No linter, no build.
- CI: none.
- Default branch: `master`.
- Branch protection: classic protection 404 "Branch not protected"; **rulesets** on `master`:
  - "no deletions, block force push": deletion + non_fast_forward, no bypass.
  - "basic PR": require PR, 0 approvals. **Bypass: repository admin, always.**
- verify.sh: the unittest suite.

## midi-interval-processor
- Stack: C++11, Makefile with explicit rules, GoogleTest.
- Build `make midiToInterval`; test `make test` (needs gtest; the Dockerfile's Ubuntu 18.04 image has it). No linter; flags `-std=c++11 -Wall`, code meant to stay warning-free.
- CI: none. No `.gitignore`, so build outputs would show as untracked.
- Default branch: `master`.
- Branch protection: classic 404; **rulesets** on `master`:
  - "master-1": deletion + non_fast_forward, no bypass.
  - "master-2": require PR, 0 approvals. **Bypass: repository admin, always.**
- verify.sh: build, failing on any compiler warning, then `make test` if gtest headers are found (skipped with a message otherwise).

## music_viz_gltchr
- Stack: vanilla JS on Vite 4, Vitest 0.34.
- Install `yarn`; tests `yarn test`; build `yarn build`. No linter.
- CI: `.github/workflows/test.yml` (`yarn test` on PRs and pushes to main, Node 20) and `pages.yml` (build + deploy to GitHub Pages on push to main).
- Default branch: `main`.
- Branch protection: classic 404; **ruleset** "Default" on `~DEFAULT_BRANCH`: deletion, non_fast_forward, require PR (0 approvals). No bypass. **No required status checks**, even though CI exists.
- verify.sh: `yarn test` then `yarn build`.

## Install results (Phase 3, 2026-10-18)

| Repo | PR | verify.sh |
| :- | :- | :- |
| Media-Eroder | [#5](https://github.com/SOMEiTIME/Media-Eroder/pull/5) | pass (build only, 1.6s) |
| Media-Glitcher | [#11](https://github.com/SOMEiTIME/Media-Glitcher/pull/11) | pass (25 tests, 3.9s, Python 3.6) |
| midi-interval-processor | [#5](https://github.com/SOMEiTIME/midi-interval-processor/pull/5) | **fail**: clang `-Wdelete-non-abstract-non-virtual-dtor` (`musicalConcept` has no virtual destructor; already on master). gtest missing, so tests skipped |
| music_viz_gltchr | [#32](https://github.com/SOMEiTIME/music_viz_gltchr/pull/32) | pass (tests + build, 3.9s) |

Hook self-tests (89 + 10 cases) pass against every repo's installed copies. Live `claude -p` check in music_viz_gltchr: PreToolUse blocked `git push --dry-run origin HEAD:main` with the hook's message; Stop ran verify and cached the pass.

Follow-up the same day: turned on the Bash sandbox and made the hook fail closed (second commit on each PR). Live sandbox check from the project settings alone: writes to `~` refused (`touch` and Python), repo writes, `yarn test`, `git push --dry-run`, and `gh pr list` OK. Without the exclusion, `git push` fails in the sandbox (osxkeychain can't be reached), as do `gh` commands other than `gh pr` (TLS certificate checks). The midi build warning is fixed in [midi-interval-processor#6](https://github.com/SOMEiTIME/midi-interval-processor/pull/6).

## Moved to one setup (2026-10-18, evening)

The hooks, deny rules, sandbox and CLAUDE.md section now live once in `~/.claude` (`install.sh`, run by the user). The four repo PRs were cut down to just `.claude/verify.sh` (plus midi's `.gitignore`), and retitled "Add .claude/verify.sh". Hook bugs found by a second review are fixed: `git push origin HEAD`/`@` from main, `cd` before `rm`, a `git -C` hang, `curl | python3 -m json.tool` false positive, and the `git branch x main` deny rule. midi#6 now also fixes `catch (exception(stoul))`. A `Read(//**/*.pem)` deny rule had blocked `/etc/ssl/cert.pem` inside the sandbox, which broke HTTPS for `git fetch` and `gh`; it's now limited to `~`, and `git fetch` works.
