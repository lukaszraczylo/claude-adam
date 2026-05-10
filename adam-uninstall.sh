#!/usr/bin/env bash
# ADAM uninstaller — reverses install.sh.
# Soft-archives ~/.claude/adam/ (your journal/proposals are preserved by default).
# Removes hook entries from settings.json with a diff prompt.
#
# Usage: ./adam-uninstall.sh [--yes] [--purge]
#   --purge: also delete ~/.claude/adam/ data (destructive)

set -euo pipefail

DEST="${HOME}/.claude"
ASSUME_YES=0
PURGE=0
BAK=""

for arg in "$@"; do
  case "$arg" in
    --yes|-y)  ASSUME_YES=1 ;;
    --purge)   PURGE=1 ;;
    --help|-h) sed -n '2,8p' "$0"; exit 0 ;;
    *) echo "unknown: $arg" >&2; exit 1 ;;
  esac
done

log() { printf '  %s\n' "$*"; }
need() { command -v "$1" >/dev/null 2>&1 || { echo "missing: $1" >&2; exit 1; }; }
need jq

[ -d "$DEST" ] || { echo "$DEST not found"; exit 1; }

log "removing ADAM files"
rm -f  "$DEST/hooks/adam-observe.mjs" "$DEST/hooks/adam-nudge.mjs"
rm -f  "$DEST/agents/adam.md" "$DEST/commands/reflect.md"
rm -rf "$DEST/skills/adam-self-improvement"

if [ -d "$DEST/adam" ]; then
  if [ "$PURGE" = 1 ]; then
    log "purging $DEST/adam (--purge)"
    rm -rf "$DEST/adam"
  else
    BAK="$DEST/adam.bak.$(date +%s)"
    log "archiving $DEST/adam -> $BAK"
    mv "$DEST/adam" "$BAK"
  fi
fi

# settings.json — strip ADAM hook entries
SETTINGS="$DEST/settings.json"
if [ -f "$SETTINGS" ]; then
  TMP="$(mktemp -t adam-uninstall.XXXXXX)"
  jq '
    .hooks //= {}
    | .hooks |= with_entries(
        .value |= (
          map(.hooks |= map(select(
            (.command // "") | test("adam-(observe|nudge)\\.mjs") | not
          )))
          | map(select((.hooks // []) | length > 0))
        )
      )
    | .hooks |= with_entries(select((.value | length) > 0))
  ' "$SETTINGS" > "$TMP"

  if cmp -s "$SETTINGS" "$TMP"; then
    log "settings.json already clean"
    rm -f "$TMP"
  else
    log ""
    log "settings.json changes:"
    diff -u "$SETTINGS" "$TMP" | sed 's/^/    /' || true
    log ""
    if [ "$ASSUME_YES" = 1 ]; then REPLY=y
    else printf '  apply? [y/N] '; read -r REPLY </dev/tty || REPLY=n
    fi
    case "$REPLY" in
      y|Y|yes|YES)
        cp "$SETTINGS" "$SETTINGS.adam-bak.$(date +%s)"
        mv "$TMP" "$SETTINGS"
        log "  settings.json cleaned"
        ;;
      *) rm -f "$TMP"; log "  skipped — edit settings.json manually" ;;
    esac
  fi
fi

log ""
log "ADAM uninstalled."
[ "$PURGE" = 0 ] && [ -n "$BAK" ] && [ -d "$BAK" ] && log "data archive: $BAK"
