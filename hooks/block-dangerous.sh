#!/usr/bin/env bash
# PreToolUse hook for Bash. Reads the hook JSON on stdin and exits 2 (block,
# reason on stderr) for commands that are hard to undo or leak secrets:
#   - recursive rm of /, ~, $VARS, .., the repo root, .git, or anything outside the repo
#   - force pushes, pushes to main/master, git reset --hard to a remote branch,
#     deleting main/master
#   - pushes to a local repo, and gh pr reading files the sandbox can't (both run
#     outside the sandbox)
#   - commands that name .env files, keys or credential files
#   - piping a download into a shell (curl ... | sh)
# Pattern matching is best-effort: it catches the forms Claude usually writes,
# not every possible spelling. Fails closed: if the input can't be parsed (no
# jq, python3 or node), every command is blocked until that's fixed.
# Written for bash 3.2, which is what macOS ships.

set -f # words from the command are data; never glob-expand them
hook_dir="$(cd "$(dirname "$0")" && pwd)"
input="$(cat)"

if ! command="$(printf '%s' "$input" | "$hook_dir/json-field.sh" tool_input.command)"; then
  echo "Blocked by the claude-harness safety hook (block-dangerous.sh): couldn't parse the hook input, so the command can't be checked. It needs jq, python3 or node on PATH; ask the user to fix that." >&2
  exit 2
fi
[ -z "$command" ] && exit 0

cwd="$(printf '%s' "$input" | "$hook_dir/json-field.sh" cwd)"
[ -d "$cwd" ] || cwd="$PWD"
repo_root="$(git -C "$cwd" rev-parse --show-toplevel 2>/dev/null)"
[ -n "$repo_root" ] || repo_root="$(cd "${CLAUDE_PROJECT_DIR:-$cwd}" && pwd -P)"

block() {
  echo "Blocked by the claude-harness safety hook (block-dangerous.sh): $1. If this really is needed, ask the user to run it themselves." >&2
  exit 2
}

# --- whole-command checks ------------------------------------------------------

# Download piped or substituted into an interpreter. Shells run stdin whatever
# their arguments; python/perl/ruby/node only when given no script (bare or "-"),
# so `curl ... | python3 -m json.tool` is fine.
download_pipe='(curl|wget)[^;&]*\|[[:space:]]*(sudo[[:space:]]+)?(env[[:space:]]+)?'
pipe_to_shell="${download_pipe}(sh|bash|zsh|dash|ksh|fish)([[:space:]]|\$)"
pipe_to_interpreter="${download_pipe}(python[0-9.]*|perl|ruby|node)[[:space:]]*(-([[:space:]]|\$)|\$|[;&|)])"
shell_of_download='(^|[^A-Za-z0-9_])(sh|bash|zsh|dash|ksh|source|\.)[[:space:]]+(-[A-Za-z]+[[:space:]]+)*.?(<\(|\$\()[[:space:]]*(curl|wget)'
if [[ $command =~ $pipe_to_shell ]] || [[ $command =~ $pipe_to_interpreter ]] || [[ $command =~ $shell_of_download ]]; then
  block "piping a download into a shell runs unreviewed code"
fi

# Secret files, named anywhere in the command (cat, cp, grep, git add, echo >> ...).
before='(^|[^A-Za-z0-9_.-])'
after='($|[^A-Za-z0-9_.-])'
secret_patterns=(
  "${before}\.env(\.[A-Za-z0-9_.-]+)?${after}"
  "[A-Za-z0-9_-]\.(pem|key)($|[[:space:]\"'])"
  "${before}id_(rsa|dsa|ecdsa|ed25519)"
  "${before}\.(netrc|git-credentials|pypirc)${after}"
  "\.aws/credentials"
  "${before}credentials\.json${after}"
)
for pattern in "${secret_patterns[@]}"; do
  if [[ $command =~ $pattern ]]; then
    block "the command names a secrets file (${BASH_REMATCH[0]# }); .env files, keys and credentials stay unread"
  fi
done

# --- per-command checks --------------------------------------------------------

# Prints path $1 made absolute from $cwd, with symlinks in its parent resolved
# (macOS /var -> /private/var) to compare with git's path. Nothing if $cwd is unknown.
absolute_path() {
  local path="$1" parent
  case "$path" in
    /*) ;;
    *) [ -n "$cwd" ] || return; path="$cwd/$path" ;;
  esac
  while [ "${path%/}" != "$path" ] && [ "$path" != "/" ]; do path="${path%/}"; done
  path="${path%/.}"
  parent="$(cd "$(dirname "$path")" 2>/dev/null && pwd -P)" && path="${parent%/}/$(basename "$path")"
  echo "$path"
}

# True if absolute path $1 is in the repo or a temp folder.
in_repo_or_temp() {
  case "$1" in
    "$repo_root"/*|/tmp/*|/private/tmp/*|/var/folders/*|/private/var/folders/*) return 0 ;;
  esac
  [ -n "$TMPDIR" ] && [[ $1 == "${TMPDIR%/}"/* ]]
}

# Prints the reason if rm -r on path $1 isn't safe, nothing if it is.
unsafe_rm_target() {
  local target="$1" path
  case "$target" in
    "~"*) echo "it targets your home directory"; return ;;
    "\$"*) echo "it starts with a variable ($target) whose value can't be checked; use a literal path"; return ;;
    ..|../*|*/..|*/../*) echo "it uses .. to leave the current directory"; return ;;
    .|./|"*") echo "it deletes the whole working directory"; return ;;
  esac
  path="$(absolute_path "$target")"
  [ -n "$path" ] || { echo "an earlier cd went somewhere that can't be checked"; return; }
  if [ "$path" = "$repo_root" ] || [ "$path" = "$repo_root/.git" ]; then
    echo "it deletes the repo or its .git directory"; return
  fi
  in_repo_or_temp "$path" || echo "$target is outside the repo ($repo_root)"
}

check_rm() {
  local recursive="" args_done="" word reason
  local -a targets=()
  for word in "$@"; do
    if [ -z "$args_done" ]; then
      case "$word" in
        --) args_done=1; continue ;;
        --recursive) recursive=1; continue ;;
        --*) continue ;;
        -*) [[ $word == *[rR]* ]] && recursive=1; continue ;;
      esac
    fi
    targets+=("$word")
  done
  [ -n "$recursive" ] || return
  for word in ${targets[@]+"${targets[@]}"}; do
    reason="$(unsafe_rm_target "$word")"
    [ -n "$reason" ] && block "recursive rm refused: $reason"
  done
}

# True if git remote URL $1 is on the network. Pushes run outside the sandbox
# (settings.json), and pushing to a local repo (a path, file://) runs its hooks there.
scp_style='^[^/:]+:' # host:path; git reads it as ssh when no / comes before the :
is_network_url() {
  case "$1" in
    *::*) return 1 ;; # transport::address, e.g. ext::<command>
    https://*|http://*|ssh://*|git+ssh://*|ssh+git://*|git://*) return 0 ;;
    *://*) return 1 ;; # file:// and anything else
  esac
  [[ $1 =~ $scp_style ]]
}

# Blocks a push whose remote (name or URL) $2, as seen from directory $1, isn't on the network.
check_push_remote() {
  local git_dir="$1" remote="$2" urls url
  urls="$(git -C "$git_dir" remote get-url --push --all "$remote" 2>/dev/null ||
    git -C "$git_dir" ls-remote --get-url "$remote" 2>/dev/null)"
  [ -n "$urls" ] || urls="$remote"
  while IFS= read -r url; do
    is_network_url "$url" ||
      block "git push to $url is refused: push runs outside the sandbox, and pushing to a local repo runs that repo's hooks; push to a network remote"
  done <<<"$urls"
}

# Prints the reason if gh pr (outside the sandbox) mustn't read file $1, nothing
# if it may: only regular files in the repo or a temp folder, where the sandbox
# could have read them too.
unsafe_body_file() {
  local file="$1" path
  case "$file" in
    "~"*) echo "it's outside the repo"; return ;;
    "\$"*) echo "it starts with a variable whose value can't be checked"; return ;;
  esac
  path="$(absolute_path "$file")"
  [ -n "$path" ] || { echo "an earlier cd went somewhere that can't be checked"; return; }
  in_repo_or_temp "$path" || { echo "it's outside the repo and temp folders"; return; }
  [ -L "$path" ] && { echo "it's a symlink"; return; }
  [ -n "$(find "$path" -prune -links +1 2>/dev/null)" ] && echo "it's a hard link"
}

# gh pr runs outside the sandbox (settings.json), so it mustn't read files the sandbox can't.
input_redirect='(^|[^<])<([^<]|$)' # < file or <(...), not << or <<<
check_gh_pr() {
  local word file reason
  if [[ $command =~ $input_redirect ]] || [[ $command == *'$('* ]] || [[ $command == *'`'* ]]; then
    block "gh pr runs outside the sandbox, so it can't take input from < or \$(...); write the text to a file in the repo and use --body-file"
  fi
  while [ $# -gt 0 ]; do
    word="$1"; shift
    case "$word" in
      --body-file=*|--recover=*) file="${word#*=}" ;;
      -F?*) file="${word#-F}" ;;
      --body-file|--recover|-F) file="${1-}"; [ $# -gt 0 ] && shift ;;
      *) continue ;;
    esac
    [ "$file" = - ] && continue
    reason="$(unsafe_body_file "$file")"
    [ -n "$reason" ] && block "gh pr runs outside the sandbox, so reading $file is refused: $reason"
  done
}

is_main() { [ "$1" = main ] || [ "$1" = master ]; }

# Prints the branch checked out in directory $1.
current_branch() { git -C "${1:-.}" branch --show-current 2>/dev/null; }

check_git() {
  # Skip git's global options (-C <dir>, -c <key=value>, --no-pager, ...).
  local git_dir="$cwd"
  while [ $# -gt 0 ]; do
    case "$1" in
      -C) [ $# -ge 2 ] && git_dir="$2"; shift; [ $# -gt 0 ] && shift ;;
      -c) shift; [ $# -gt 0 ] && shift ;;
      -*) shift ;;
      *) break ;;
    esac
  done
  local subcommand="$1" word
  shift

  case "$subcommand" in
    push)
      local -a positional=()
      while [ $# -gt 0 ]; do
        word="$1"; shift
        case "$word" in
          --force*|--force-with-lease*|--force-if-includes) block "force pushes are not allowed" ;;
          --mirror|--all) block "git push $word would push main/master too" ;;
          --receive-pack*|--exec*) block "git push $word runs a command outside the sandbox" ;;
          --repo*) block "git push --repo isn't checked; name the remote as the first argument" ;;
          --recurse-submodules=check|--recurse-submodules=no) ;;
          --recurse-submodules*) block "git push $word pushes submodules to remotes that aren't checked" ;;
          -o|--push-option) shift ;;
          --*) ;;
          -*) [[ $word == *f* ]] && block "force pushes are not allowed" ;;
          +*) block "a +refspec is a force push" ;;
          *) positional+=("$word") ;;
        esac
      done
      # positional[0] is the remote; the rest are refspecs (src:dst or just a branch).
      # HEAD and @ (alone, or as the destination) mean the current branch.
      local i dst
      for ((i = 1; i < ${#positional[@]}; i++)); do
        dst="${positional[$i]##*:}"
        dst="${dst#refs/heads/}"
        case "$dst" in HEAD|@) dst="$(current_branch "$git_dir")" ;; esac
        is_main "$dst" && block "pushing to $dst is not allowed; push a branch and open a PR"
      done
      local current remote="${positional[0]-}"
      current="$(current_branch "$git_dir")"
      if [ ${#positional[@]} -le 1 ]; then
        is_main "$current" && block "a bare git push from $current would push to $current; push a branch and open a PR"
      fi
      if [ -z "$remote" ]; then
        remote="$(git -C "$git_dir" config "branch.$current.pushRemote" 2>/dev/null ||
          git -C "$git_dir" config remote.pushDefault 2>/dev/null ||
          git -C "$git_dir" config "branch.$current.remote" 2>/dev/null || echo origin)"
      fi
      check_push_remote "$git_dir" "$remote"
      ;;
    fetch)
      # git fetch runs outside the sandbox (settings.json), so nothing may make it run a command.
      for word in "$@"; do
        case "$word" in
          --upload-pack*) block "git fetch $word runs a command outside the sandbox" ;;
          ext::*) block "an ext:: remote runs a command outside the sandbox" ;;
        esac
      done
      ;;
    branch)
      local deleting="" names=""
      for word in "$@"; do
        case "$word" in
          --delete|-d|-D|-df|-fd|-Df|-fD) deleting=1 ;;
          -*) ;;
          *) names="$names $word" ;;
        esac
      done
      if [ -n "$deleting" ]; then
        for word in $names; do
          is_main "$word" && block "deleting the $word branch is not allowed"
        done
      fi
      ;;
    reset)
      local hard="" remote_target=""
      for word in "$@"; do
        case "$word" in
          --hard) hard=1 ;;
          origin/*|upstream/*|*@{u}*|*@{upstream}*) remote_target="$word" ;;
        esac
      done
      [ -n "$hard" ] && [ -n "$remote_target" ] &&
        block "git reset --hard $remote_target throws away local commits and changes"
      ;;
  esac
}

# Prints where `cd $1` from $cwd lands, or nothing if that can't be known
# (a variable, `cd -`, or a directory that doesn't exist yet and uses ..).
resolve_cd() {
  local target="$1"
  [ -n "$cwd" ] || return
  case "$target" in
    ""|"~") target="$HOME" ;;
    "~/"*) target="$HOME/${target#\~/}" ;;
    "-"|"\$"*|"~"*) return ;;
    /*) ;;
    *) target="$cwd/$target" ;;
  esac
  if [ -d "$target" ]; then
    (cd "$target" && pwd -P)
  else
    # Not created yet (e.g. `mkdir -p src && cd src`): use the path as written.
    case "$target" in */..|*/../*) return ;; esac
    echo "$target"
  fi
}

# Split into simple commands at ; & | && || newlines and $( ( ) `, then check each.
segments="$(printf '%s\n' "$command" | awk '{ gsub(/&&|\|\||[;&|`()]/, "\n"); print }')"
while IFS= read -r segment; do
  read -ra words <<<"$segment"
  [ ${#words[@]} -gt 0 ] || continue
  # Strip quotes from each word (best-effort; this is not a full shell parser).
  for i in "${!words[@]}"; do
    words[$i]="${words[$i]//\"/}"
    words[$i]="${words[$i]//\'/}"
  done
  # Skip VAR=value prefixes and wrapper commands (sudo, env, xargs, ...) and their flags.
  start=0
  while [ $start -lt ${#words[@]} ]; do
    case "${words[$start]}" in
      sudo|env|command|nohup|time|exec|xargs|nice) start=$((start + 1))
        while [ $start -lt ${#words[@]} ] && [[ ${words[$start]} == -* ]]; do start=$((start + 1)); done ;;
      [A-Za-z_]*=*) start=$((start + 1)) ;;
      *) break ;;
    esac
  done
  [ $start -lt ${#words[@]} ] || continue
  program="${words[$start]##*/}"
  args=("${words[@]:$((start + 1))}")
  case "$program" in
    rm) check_rm ${args[@]+"${args[@]}"} ;;
    git) check_git ${args[@]+"${args[@]}"} ;;
    gh) [ "${args[0]:-}" = pr ] && check_gh_pr ${args[@]+"${args[@]}"} ;;
    cd|pushd) cwd="$(resolve_cd "${args[0]:-}")" ;;
  esac
done <<<"$segments"

exit 0
