#!/usr/bin/env bash
# Install the guardrails for every Claude Code session on this machine:
#   install.sh            install or update
#   install.sh --dry-run  show what would change, write nothing
# - copies the hooks into ~/.claude/hooks/claude-harness/
# - merges templates/settings.json into ~/.claude/settings.json (lists are
#   unioned, existing keys and values win)
# - adds the guardrails section to ~/.claude/CLAUDE.md, or refreshes it
# - creates ~/.cache/yarn-sandbox, the yarn cache sandboxed commands use
# Idempotent: a second run changes nothing. Needs python3 for the merges.
# Run it yourself (with `!` inside Claude Code): the sandbox stops Claude's
# shell from writing to ~/.claude, which is what keeps the guardrails safe.
# Repos get their test command separately, with add-verify.sh.
set -euo pipefail

harness="$(cd "$(dirname "$0")" && pwd)"
claude_dir="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
dry_run=""
[ "${1:-}" = "--dry-run" ] && dry_run=1

# write_if_changed <target> <new content file> <label>: show the diff, then write unless --dry-run.
write_if_changed() {
  local target="$1" new="$2" label="$3"
  if [ -f "$target" ] && cmp -s "$new" "$target"; then
    return
  fi
  echo "== $label"
  if [ -f "$target" ]; then diff -u "$target" "$new" | sed 1,2d || true; else echo "  (new file)"; fi
  if [ -z "$dry_run" ]; then
    mkdir -p "$(dirname "$target")"
    cp "$new" "$target"
  fi
}

tmp="$(mktemp -d "${TMPDIR:-/tmp}/claude-harness-install.XXXXXX")"
trap 'rm -rf "$tmp"' EXIT

for hook in block-dangerous.sh stop-verify.sh json-field.sh; do
  target="$claude_dir/hooks/claude-harness/$hook"
  if ! cmp -s "$harness/hooks/$hook" "$target"; then
    echo "== hooks/claude-harness/$hook ($([ -f "$target" ] && echo updated || echo new))"
    if [ -z "$dry_run" ]; then
      mkdir -p "$(dirname "$target")"
      cp "$harness/hooks/$hook" "$target"
    fi
  fi
  [ -n "$dry_run" ] || chmod +x "$target"
done

python3 - "$harness/templates/settings.json" "$claude_dir/settings.json" "$tmp/settings.json" <<'PY'
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

template_path, settings_path, out_path = sys.argv[1:]
with open(template_path) as f:
    template = json.load(f)
# "claudeHarnessRemove" maps a dotted path to entries earlier versions added
# that should go now (merging only ever adds).
remove = template.pop("claudeHarnessRemove", {})
# Claude Code doesn't expand ~ in env values, so do it here.
if "env" in template:
    template["env"] = {k: os.path.expanduser(v) for k, v in template["env"].items()}
existing = {}
if os.path.exists(settings_path):
    with open(settings_path) as f:
        existing = json.load(f)
merged = merge(existing, template)
for path, entries in remove.items():
    *parents, key = path.split(".")
    node = merged
    for parent in parents:
        node = node.get(parent, {})
    if isinstance(node.get(key), list):
        node[key] = [item for item in node[key] if item not in entries]
with open(out_path, "w") as f:
    f.write(json.dumps(merged, indent=2) + "\n")
PY
write_if_changed "$claude_dir/settings.json" "$tmp/settings.json" "settings.json"

# The sandbox's own yarn cache (YARN_CACHE_FOLDER in the template). Yarn falls
# back to a temp folder if it's missing, so create it up front.
yarn_cache="$HOME/.cache/yarn-sandbox"
if [ ! -d "$yarn_cache" ]; then
  echo "== $yarn_cache (new directory)"
  [ -n "$dry_run" ] || mkdir -p "$yarn_cache"
fi

python3 - "$harness/templates/CLAUDE.md.template" "$claude_dir/CLAUDE.md" "$tmp/CLAUDE.md" <<'PY'
import os, re, sys
# Replace the marked section with the current template, or append it.
template_path, path, out_path = sys.argv[1:]
template = open(template_path).read().strip()
text = open(path).read() if os.path.exists(path) else ""
pattern = r"<!-- claude-harness:start -->.*?<!-- claude-harness:end -->"
if re.search(pattern, text, flags=re.S):
    text = re.sub(pattern, lambda m: template, text, count=1, flags=re.S)
else:
    text = (text.rstrip() + "\n\n" if text.strip() else "") + template + "\n"
open(out_path, "w").write(text)
PY
write_if_changed "$claude_dir/CLAUDE.md" "$tmp/CLAUDE.md" "CLAUDE.md"

if [ -n "$dry_run" ]; then echo "Dry run: nothing written."; else echo "Done."; fi
