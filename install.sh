#!/usr/bin/env bash
set -euo pipefail

DEST="${HOME}/.claude"
SRC="$(cd "$(dirname "$0")" && pwd)"

echo "ADAM installer"
echo "  source: $SRC"
echo "  dest:   $DEST"
echo

if [ ! -d "$DEST" ]; then
  echo "  ! $DEST does not exist. Is Claude Code installed?"
  exit 1
fi

mkdir -p \
  "$DEST/hooks" \
  "$DEST/agents" \
  "$DEST/skills/adam-self-improvement" \
  "$DEST/commands" \
  "$DEST/adam/proposals" \
  "$DEST/adam/applied" \
  "$DEST/adam/rejected" \
  "$DEST/adam/trash" \
  "$DEST/adam/journal" \
  "$DEST/adam/scripts" \
  "$DEST/adam/tests/fixtures"

cp "$SRC/hooks/adam-observe.mjs"                                      "$DEST/hooks/"
cp "$SRC/hooks/adam-nudge.mjs"                                        "$DEST/hooks/"
cp "$SRC/agents/adam.md"                                              "$DEST/agents/"
cp "$SRC/skills/adam-self-improvement/SKILL.md"                       "$DEST/skills/adam-self-improvement/"
cp "$SRC/commands/reflect.md"                                         "$DEST/commands/"
cp "$SRC/adam/scripts/adam-archive.mjs"                               "$DEST/adam/scripts/"
cp "$SRC/adam/tests/run-tests.sh"                                     "$DEST/adam/tests/"
cp "$SRC/adam/tests/fixtures/seed-corrections.jsonl"                  "$DEST/adam/tests/fixtures/"

[ -f "$DEST/adam/journal.jsonl" ] || : > "$DEST/adam/journal.jsonl"
[ -f "$DEST/adam/state.json" ]    || echo '{"cursor":0,"tool_window":[]}' > "$DEST/adam/state.json"
[ -f "$DEST/adam/usage.json" ]    || echo '{}' > "$DEST/adam/usage.json"

echo "  files installed."
echo
echo "  next steps:"
echo "    1. bash $DEST/adam/tests/run-tests.sh    # must show: 21 passed, 0 failed"
echo "    2. merge settings.json.example into $DEST/settings.json"
echo "    3. start a fresh Claude Code session, then run /reflect"
echo
echo "  ADAM is dormant until you invoke /reflect."
