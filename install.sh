#!/usr/bin/env bash
# Install the harness into a repo: install.sh <repo-path>
# - copies the hooks into <repo>/.claude/hooks/
# - merges templates/settings.json into <repo>/.claude/settings.json (lists are
#   unioned, existing keys and values win)
# - creates <repo>/.claude/verify.sh from verify/<repo-name>.sh if it's missing
#   (<repo-name> comes from the origin URL, so it works in worktrees too)
# - appends the guardrails section to <repo>/CLAUDE.md, or refreshes it in place
# Idempotent: a second run changes nothing. Needs python3 for the JSON merge.
set -euo pipefail

harness="$(cd "$(dirname "$0")" && pwd)"
repo="$(cd "${1:?usage: install.sh <repo-path>}" && git rev-parse --show-toplevel)"
name="$(basename "$(git -C "$repo" remote get-url origin 2>/dev/null || echo "$repo")" .git)"

changed() { echo "  updated $1"; }

echo "Installing claude-harness into $repo ($name)"
mkdir -p "$repo/.claude/hooks"

for hook in block-dangerous.sh stop-verify.sh json-field.sh; do
  target="$repo/.claude/hooks/$hook"
  if ! cmp -s "$harness/hooks/$hook" "$target"; then
    cp "$harness/hooks/$hook" "$target"
    changed ".claude/hooks/$hook"
  fi
  chmod +x "$target"
done

settings="$repo/.claude/settings.json"
merged="$(python3 - "$harness/templates/settings.json" "$settings" <<'PY'
import json, os, sys

def merge(existing, template):
    """Deep-merge template into existing: dicts recurse, lists union, existing scalars win."""
    if isinstance(existing, dict) and isinstance(template, dict):
        result = dict(existing)
        for key, value in template.items():
            result[key] = merge(existing[key], value) if key in existing else value
        return result
    if isinstance(existing, list) and isinstance(template, list):
        return existing + [item for item in template if item not in existing]
    return existing

template_path, settings_path = sys.argv[1:]
with open(template_path) as f:
    template = json.load(f)
existing = {}
if os.path.exists(settings_path):
    with open(settings_path) as f:
        existing = json.load(f)
print(json.dumps(merge(existing, template), indent=2))
PY
)"
if [ ! -f "$settings" ] || [ "$merged" != "$(cat "$settings")" ]; then
  printf '%s\n' "$merged" >"$settings"
  changed ".claude/settings.json"
fi

verify="$repo/.claude/verify.sh"
if [ ! -f "$verify" ]; then
  if [ -f "$harness/verify/$name.sh" ]; then
    cp "$harness/verify/$name.sh" "$verify"
  else
    printf '%s\n' '#!/usr/bin/env bash' \
      '# Verify command for this repo (lint, tests, build). Exit non-zero on failure.' \
      'echo "No verify command configured yet; edit .claude/verify.sh." >&2' >"$verify"
    echo "  WARNING: no verify/$name.sh in the harness; wrote a stub that always passes"
  fi
  chmod +x "$verify"
  changed ".claude/verify.sh"
fi

claude_md="$repo/CLAUDE.md"
if ! grep -qs '<!-- claude-harness:start -->' "$claude_md"; then
  [ -s "$claude_md" ] && echo >>"$claude_md"
  cat "$harness/templates/CLAUDE.md.template" >>"$claude_md"
  changed "CLAUDE.md"
elif python3 - "$harness/templates/CLAUDE.md.template" "$claude_md" <<'PY'
import re, sys
# Replace the marked section with the current template; exit 1 if it's already current.
template = open(sys.argv[1]).read().strip()
path = sys.argv[2]
text = open(path).read()
updated = re.sub(r"<!-- claude-harness:start -->.*?<!-- claude-harness:end -->",
                 lambda m: template, text, count=1, flags=re.S)
if updated == text:
    sys.exit(1)
open(path, "w").write(updated)
PY
then
  changed "CLAUDE.md (guardrails section)"
fi

echo "Done."
