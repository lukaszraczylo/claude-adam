#!/usr/bin/env bash
# ADAM installer — pure bash + git + curl + jq.
# Idempotent. Safe for upgrades. Supports `curl | bash` via auto-clone.
#
# Usage:
#   ./install.sh                      # local install from cwd
#   curl -fsSL <raw>/install.sh | bash
#   VERSION=v0.3.0 ./install.sh       # pin a tag
#   ./install.sh --yes                # skip settings.json prompt
#   ./install.sh --dry-run            # show actions, write nothing

set -euo pipefail

REPO_GIT="https://github.com/lukaszraczylo/claude-adam.git"
DEST="${HOME}/.claude"
ASSUME_YES=0
DRY_RUN=0
VERSION="${VERSION:-${BRANCH:-}}"   # env var pin; empty = latest tag

log()  { printf '  %s\n' "$*"; }
warn() { printf '  ! %s\n' "$*" >&2; }
die()  { printf '  ! %s\n' "$*" >&2; exit 1; }
run()  { if [ "$DRY_RUN" = 1 ]; then printf '    [dry-run] %s\n' "$*"; else eval "$@"; fi; }

# --------------------------------------------------------------------- args
for arg in "$@"; do
  case "$arg" in
    --yes|-y)     ASSUME_YES=1 ;;
    --dry-run|-n) DRY_RUN=1 ;;
    --version=*)  VERSION="${arg#--version=}" ;;
    --help|-h)    sed -n '2,12p' "$0"; exit 0 ;;
    *) die "unknown arg: $arg (try --help)" ;;
  esac
done

# --------------------------------------------------------------------- prereqs
need() { command -v "$1" >/dev/null 2>&1 || die "missing: $1 — $2"; }
need git  "install: brew install git || apt install git"
need curl "install: brew install curl || apt install curl"
need jq   "install: brew install jq || apt install jq"
command -v node >/dev/null 2>&1 || warn "node not found — hooks need node 18+; install: brew install node"

# --------------------------------------------------------------------- locate source
# If invoked via `curl | bash`, $0 is bash and there are no local files.
PIPED=0
SCRIPT_PATH="${BASH_SOURCE[0]:-$0}"
if [ ! -f "$SCRIPT_PATH" ] || [ "$SCRIPT_PATH" = "bash" ] || [ "$SCRIPT_PATH" = "-" ]; then
  PIPED=1
elif [ ! -d "$(dirname "$SCRIPT_PATH")/hooks" ]; then
  PIPED=1
fi

CLEANUP_TMP=""
cleanup() { [ -n "$CLEANUP_TMP" ] && rm -rf "$CLEANUP_TMP" 2>/dev/null || true; }
trap cleanup EXIT INT TERM

if [ "$PIPED" = 1 ]; then
  log "running via curl|bash — cloning repo to tmp"
  CLEANUP_TMP="$(mktemp -d -t claude-adam-install.XXXXXX)"
  REF="$VERSION"
  if [ -z "$REF" ]; then
    # latest semver tag from remote (no local clone needed)
    REF="$(git ls-remote --tags --refs "$REPO_GIT" \
            | awk -F/ '{print $NF}' \
            | grep -E '^v[0-9]+\.[0-9]+\.[0-9]+$' \
            | sort -V | tail -1)"
    [ -z "$REF" ] && REF="main"
  fi
  log "fetching $REF"
  run "git clone --quiet --depth=1 --branch=\"$REF\" \"$REPO_GIT\" \"$CLEANUP_TMP\""
  SRC="$CLEANUP_TMP"
else
  SRC="$(cd "$(dirname "$SCRIPT_PATH")" && pwd)"
fi

log "ADAM installer"
log "  source: $SRC"
log "  dest:   $DEST"
log "  mode:   $([ "$DRY_RUN" = 1 ] && echo dry-run || echo apply)$([ "$ASSUME_YES" = 1 ] && echo ' --yes' || true)"
log ""

[ -d "$DEST" ] || die "$DEST does not exist. Install Claude Code first: https://claude.com/claude-code"

# --------------------------------------------------------------------- dirs
DIRS=(
  "hooks" "agents" "skills/adam-self-improvement" "commands"
  "adam/proposals" "adam/applied" "adam/rejected" "adam/trash"
  "adam/journal" "adam/scripts" "adam/tests/fixtures"
)
for d in "${DIRS[@]}"; do run "mkdir -p \"$DEST/$d\""; done

# .gitkeep markers so the layout survives `git init` for users who VCS ~/.claude
for d in adam/proposals adam/applied adam/rejected adam/trash adam/journal; do
  [ -e "$DEST/$d/.gitkeep" ] || run ": > \"$DEST/$d/.gitkeep\""
done

# --------------------------------------------------------------------- file copy
# Conservative: if dest exists and differs from src AND user-modified after install,
# write to <file>.adam-new and warn instead of clobbering.
copy_file() {
  local src="$1" dst="$2"
  [ -f "$src" ] || die "missing source file: $src"
  if [ -f "$dst" ] && ! cmp -s "$src" "$dst"; then
    if [ -f "$DEST/adam/.install-marker" ] \
       && [ "$(stat -f %m "$dst" 2>/dev/null || stat -c %Y "$dst")" \
          -gt "$(stat -f %m "$DEST/adam/.install-marker" 2>/dev/null || stat -c %Y "$DEST/adam/.install-marker")" ]; then
      warn "modified locally, NOT overwriting: $dst"
      warn "  new version written to: $dst.adam-new (review and merge manually)"
      run "cp \"$src\" \"$dst.adam-new\""
      return
    fi
  fi
  run "cp \"$src\" \"$dst\""
  log "  copied: ${dst#$HOME/}"
}

# Hooks
copy_file "$SRC/hooks/adam-observe.mjs"                              "$DEST/hooks/adam-observe.mjs"
copy_file "$SRC/hooks/adam-nudge.mjs"                                "$DEST/hooks/adam-nudge.mjs"
# Agent / skill / command
copy_file "$SRC/agents/adam.md"                                      "$DEST/agents/adam.md"
copy_file "$SRC/skills/adam-self-improvement/SKILL.md"               "$DEST/skills/adam-self-improvement/SKILL.md"
copy_file "$SRC/commands/reflect.md"                                 "$DEST/commands/reflect.md"
# Adam internals
copy_file "$SRC/adam/scripts/adam-archive.mjs"                       "$DEST/adam/scripts/adam-archive.mjs"
copy_file "$SRC/adam/tests/run-tests.sh"                             "$DEST/adam/tests/run-tests.sh"
copy_file "$SRC/adam/tests/fixtures/seed-corrections.jsonl"          "$DEST/adam/tests/fixtures/seed-corrections.jsonl"

# Preserve user data — never overwrite
[ -f "$DEST/adam/journal.jsonl" ] || run ": > \"$DEST/adam/journal.jsonl\""
[ -f "$DEST/adam/state.json" ]    || run "echo '{\"tool_window\":[]}' > \"$DEST/adam/state.json\""
[ -f "$DEST/adam/usage.json" ]    || run "echo '{}' > \"$DEST/adam/usage.json\""

# install marker — used by future runs to detect local mtime drift
run "touch \"$DEST/adam/.install-marker\""

# --------------------------------------------------------------------- settings.json
SETTINGS="$DEST/settings.json"
EXAMPLE="$SRC/settings.json.example"
[ -f "$EXAMPLE" ] || die "missing $EXAMPLE"

# Build target settings via jq merge (preserves all user keys/hooks).
TMP_NEW="$(mktemp -t adam-settings.XXXXXX)"
TMP_DIFF="$(mktemp -t adam-settings-diff.XXXXXX)"
cleanup_full() { cleanup; rm -f "$TMP_NEW" "$TMP_DIFF" 2>/dev/null || true; }
trap cleanup_full EXIT INT TERM

if [ -f "$SETTINGS" ]; then
  jq --slurpfile add "$EXAMPLE" '
    . as $cur
    | ($add[0].hooks // {}) as $new
    | .hooks = (
        ($cur.hooks // {}) as $cur_hooks
        | reduce ($new | keys[]) as $k ($cur_hooks;
            .[$k] = (
              ((.[$k] // []) + $new[$k])
              | unique_by(tojson)
            )
          )
      )
  ' "$SETTINGS" > "$TMP_NEW"
else
  jq 'del(._comment)' "$EXAMPLE" > "$TMP_NEW"
fi

if [ -f "$SETTINGS" ] && cmp -s "$SETTINGS" "$TMP_NEW"; then
  log "settings.json already wired — no changes"
else
  log ""
  log "settings.json changes proposed:"
  if [ -f "$SETTINGS" ]; then
    diff -u "$SETTINGS" "$TMP_NEW" > "$TMP_DIFF" || true
  else
    diff -u /dev/null "$TMP_NEW" > "$TMP_DIFF" || true
  fi
  sed 's/^/    /' "$TMP_DIFF"
  log ""
  if [ "$ASSUME_YES" = 1 ]; then
    REPLY=y
  else
    printf '  apply settings.json changes? [y/N] '
    read -r REPLY </dev/tty || REPLY=n
  fi
  case "$REPLY" in
    y|Y|yes|YES)
      [ -f "$SETTINGS" ] && run "cp \"$SETTINGS\" \"$SETTINGS.adam-bak.$(date +%s)\""
      run "mv \"$TMP_NEW\" \"$SETTINGS\""
      log "  settings.json updated (backup at *.adam-bak.<ts> if pre-existing)"
      ;;
    *)
      log "  skipped — wire entries from $EXAMPLE manually"
      ;;
  esac
fi

# --------------------------------------------------------------------- summary
log ""
log "installed:"
log "  hooks/adam-observe.mjs, hooks/adam-nudge.mjs"
log "  agents/adam.md"
log "  skills/adam-self-improvement/SKILL.md"
log "  commands/reflect.md"
log "  adam/scripts/adam-archive.mjs"
log "  adam/tests/run-tests.sh"
log ""
log "preserved (if existed):"
log "  adam/journal.jsonl, adam/state.json, adam/usage.json"
log ""
log "next:"
log "  1. bash $DEST/adam/tests/run-tests.sh    # expect: all passed"
log "  2. start a fresh Claude Code session"
log "  3. run /reflect to invoke the analyst"
log ""
log "ADAM is dormant until you run /reflect."
log "journal:   $DEST/adam/journal.jsonl"
log "proposals: $DEST/adam/proposals/"
