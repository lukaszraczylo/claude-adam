#!/usr/bin/env bash
# Test harness: ALWAYS runs against an isolated $HOME under mktemp.
# The hook/nudge/archive scripts being tested are sourced from the real $HOME
# but invoked with HOME="$TMP_HOME" so journal/state/usage write to the sandbox.
set -euo pipefail

REAL_HOME="$HOME"
HOOK="$REAL_HOME/.claude/hooks/adam-observe.mjs"
NUDGE="$REAL_HOME/.claude/hooks/adam-nudge.mjs"
ARCHIVE="$REAL_HOME/.claude/adam/scripts/adam-archive.mjs"
WINDOW="$REAL_HOME/.claude/adam/scripts/adam-window.mjs"
EXPLAIN="$REAL_HOME/.claude/adam/scripts/adam-explain.mjs"
ELIGIBILITY="$REAL_HOME/.claude/adam/scripts/adam-nudge-eligibility.mjs"
COOLDOWN="$REAL_HOME/.claude/adam/scripts/adam-cooldown.mjs"
SCORE="$REAL_HOME/.claude/adam/scripts/adam-score.mjs"
ABMEASURE="$REAL_HOME/.claude/adam/scripts/adam-ab-measure.mjs"
APPLYREIN="$REAL_HOME/.claude/adam/scripts/adam-apply-reinforcement.mjs"
UPGRADE="$REAL_HOME/.claude/adam/scripts/adam-upgrade.mjs"

TMP_HOME="$(mktemp -d -t adam-test.XXXXXX)"
trap 'rm -rf "$TMP_HOME"' EXIT INT TERM
mkdir -p "$TMP_HOME/.claude/adam/proposals" "$TMP_HOME/.claude/adam/applied" "$TMP_HOME/.claude/adam/rejected" "$TMP_HOME/.claude/adam/journal"

ROOT="$TMP_HOME/.claude/adam"
HOOK_RUN()    { HOME="$TMP_HOME" node "$HOOK" "$@"; }
NUDGE_RUN()   { HOME="$TMP_HOME" node "$NUDGE" "$@"; }
ARCHIVE_RUN() { HOME="$TMP_HOME" node "$ARCHIVE" "$@"; }
WINDOW_RUN()  { HOME="$TMP_HOME" node "$WINDOW" --home "$TMP_HOME/.claude" "$@"; }
EXPLAIN_RUN() { HOME="$TMP_HOME" node "$EXPLAIN" --home "$TMP_HOME/.claude" "$@"; }
ELIG_RUN()    { HOME="$TMP_HOME" node "$ELIGIBILITY" --home "$TMP_HOME/.claude" "$@"; }
COOLDOWN_RUN(){ HOME="$TMP_HOME" node "$COOLDOWN" --home "$TMP_HOME/.claude" "$@"; }
SCORE_RUN()   { HOME="$TMP_HOME" node "$SCORE" --home "$TMP_HOME/.claude" "$@"; }
ABMEASURE_RUN(){ HOME="$TMP_HOME" node "$ABMEASURE" --home "$TMP_HOME/.claude" "$@"; }
APPLYREIN_RUN(){ HOME="$TMP_HOME" node "$APPLYREIN" "$@" --home "$TMP_HOME/.claude"; }
UPGRADE_RUN() { HOME="$TMP_HOME" node "$UPGRADE" "$@"; }

PASS=0
FAIL=0

reset_state() {
  : > "$ROOT/journal.jsonl"
  echo '{"cursor":0,"tool_window":[]}' > "$ROOT/state.json"
  echo '{}' > "$ROOT/usage.json"
}

assert_lines() {
  local file="$1" expected="$2" name="$3"
  local actual
  actual=$(wc -l < "$file" | tr -d ' ')
  if [ "$actual" = "$expected" ]; then
    echo "  PASS: $name ($file has $actual lines)"
    PASS=$((PASS+1))
  else
    echo "  FAIL: $name (expected $expected lines in $file, got $actual)"
    FAIL=$((FAIL+1))
  fi
}

assert_grep() {
  local file="$1" pattern="$2" name="$3"
  if grep -qE "$pattern" "$file"; then
    echo "  PASS: $name"
    PASS=$((PASS+1))
  else
    echo "  FAIL: $name (pattern $pattern not in $file)"
    FAIL=$((FAIL+1))
  fi
}

# --- Test 1: correction signal ---
echo "Test 1: user correction"
reset_state
echo '{"hook_event_name":"UserPromptSubmit","prompt":"no, that is wrong","session_id":"s1","cwd":"/tmp/x"}' \
  | HOOK_RUN >/dev/null 2>&1 || true
assert_lines "$ROOT/journal.jsonl" 1 "correction creates journal entry"
assert_grep  "$ROOT/journal.jsonl" '"type":"correction"' "entry has correct type"

# --- Test 2: retry loop ---
echo "Test 2: retry loop"
reset_state
for i in 1 2 3; do
  echo '{"hook_event_name":"PostToolUse","tool_name":"Bash","tool_input":{"command":"ls"},"session_id":"s1","cwd":"/tmp/x"}' \
    | HOOK_RUN >/dev/null 2>&1 || true
done
assert_grep "$ROOT/journal.jsonl" '"type":"retry_loop"' "3x same Bash logs retry_loop"

# --- Test 3: usage counter ---
echo "Test 3: usage counter"
reset_state
echo '{"hook_event_name":"PreToolUse","tool_name":"Skill","tool_input":{"skill":"foo"},"session_id":"s1","cwd":"/tmp/x"}' \
  | HOOK_RUN >/dev/null 2>&1 || true
assert_grep "$ROOT/usage.json" '"skill:foo"' "Skill invocation increments usage counter"

# --- Test 3b: agent prefix in usage counter ---
echo "Test 3b: agent prefix"
reset_state
echo '{"hook_event_name":"PreToolUse","tool_name":"Agent","tool_input":{"subagent_type":"bar"},"session_id":"s1","cwd":"/tmp/x"}' \
  | HOOK_RUN >/dev/null 2>&1 || true
assert_grep "$ROOT/usage.json" '"agent:bar"' "Agent invocation increments prefixed counter"

# --- Test 4: weak agent ---
echo "Test 4: weak agent"
reset_state
echo '{"hook_event_name":"PostToolUse","tool_name":"Agent","tool_input":{"subagent_type":"x"},"session_id":"s1","cwd":"/tmp/x"}' \
  | HOOK_RUN >/dev/null 2>&1 || true
echo '{"hook_event_name":"PostToolUse","tool_name":"Agent","tool_input":{"subagent_type":"x"},"session_id":"s1","cwd":"/tmp/x"}' \
  | HOOK_RUN >/dev/null 2>&1 || true
assert_grep "$ROOT/journal.jsonl" '"type":"weak_agent"' "2x same agent logs weak_agent"

# --- Test 5: hook never blocks (exit 0) ---
echo "Test 5: hook always exit 0 even on garbage input"
reset_state
if echo 'not json' | HOOK_RUN >/dev/null 2>&1; then
  echo "  PASS: garbage input exit 0"; PASS=$((PASS+1))
else
  echo "  FAIL: garbage input non-zero exit"; FAIL=$((FAIL+1))
fi

# --- Test 6: journal rotation when file exceeds size safety fuse ---
echo "Test 6: journal rotation (size safety fuse)"
reset_state
# Seed journal with > test-threshold bytes. New code: weekly ISO rotation is
# primary path; size rotation is a safety fuse capped at MAX_JOURNAL_BYTES
# (overridable via $ADAM_MAX_JOURNAL_BYTES). Lower the fuse to make this test
# fast — 256 KB of synthetic content easily exceeds it.
head -c 300000 /dev/urandom | base64 > "$ROOT/journal.jsonl"
ADAM_MAX_JOURNAL_BYTES=200000 HOME="$TMP_HOME" node "$HOOK" \
  <<< '{"hook_event_name":"UserPromptSubmit","prompt":"no, that is wrong","session_id":"s1","cwd":"/tmp/x"}' \
  >/dev/null 2>&1 || true
rotated=$(ls "$ROOT/journal/" 2>/dev/null | wc -l | tr -d ' ')
if [ "$rotated" -ge "1" ]; then
  echo "  PASS: journal rotated ($rotated archive present)"; PASS=$((PASS+1))
else
  echo "  FAIL: journal not rotated"; FAIL=$((FAIL+1))
fi
# Cleanup rotated archive so it doesn't pollute subsequent runs
rm -f "$ROOT/journal/"*.jsonl 2>/dev/null

# --- Test 7: nudge prints reminder when ≥3 proposals ---
echo "Test 7: SessionStart nudge"
rm -f "$ROOT/proposals/"*.md 2>/dev/null
touch "$ROOT/proposals/2026-05-10-001-memory-a.md" "$ROOT/proposals/2026-05-10-002-skill_new-b.md" "$ROOT/proposals/2026-05-10-003-skill_edit-c.md"
out=$(echo '{"hook_event_name":"SessionStart"}' | NUDGE_RUN 2>&1 || true)
if echo "$out" | grep -q "3 proposals queued"; then
  echo "  PASS: nudge prints reminder"; PASS=$((PASS+1))
else
  echo "  FAIL: nudge missing reminder (got: $out)"; FAIL=$((FAIL+1))
fi
rm -f "$ROOT/proposals/"*.md

echo "Test 8: nudge silent when 0 proposals"
out=$(echo '{"hook_event_name":"SessionStart"}' | NUDGE_RUN 2>&1 || true)
if [ -z "$out" ]; then
  echo "  PASS: nudge silent"; PASS=$((PASS+1))
else
  echo "  FAIL: nudge spoke when empty (got: $out)"; FAIL=$((FAIL+1))
fi

# --- Test 9: tool_error_loop ---
echo "Test 9: tool_error_loop on repeated identical error"
reset_state
for i in 1 2 3; do
  echo '{"hook_event_name":"PostToolUse","tool_name":"Bash","tool_input":{"command":"foo"},"tool_response":{"is_error":true,"content":"Error: command not found: foo"},"session_id":"s9","cwd":"/tmp/x"}' \
    | HOOK_RUN >/dev/null 2>&1 || true
done
assert_grep "$ROOT/journal.jsonl" '"type":"tool_error_loop"' "3x same error logs tool_error_loop"

# --- Test 10: dead_end on long autonomous run ---
echo "Test 10: dead_end after 8 tools without UserPromptSubmit"
reset_state
for i in 1 2 3 4 5 6 7 8; do
  echo "{\"hook_event_name\":\"PostToolUse\",\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"step$i\"},\"session_id\":\"s10\",\"cwd\":\"/tmp/x\"}" \
    | HOOK_RUN >/dev/null 2>&1 || true
done
assert_grep "$ROOT/journal.jsonl" '"type":"dead_end"' "8x PostToolUse without prompt logs dead_end"

# --- Test 11: dead_end resets on UserPromptSubmit ---
echo "Test 11: dead_end counter resets on UserPromptSubmit"
reset_state
for i in 1 2 3 4 5 6 7; do
  echo "{\"hook_event_name\":\"PostToolUse\",\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"step$i\"},\"session_id\":\"s11\",\"cwd\":\"/tmp/x\"}" \
    | HOOK_RUN >/dev/null 2>&1 || true
done
echo '{"hook_event_name":"UserPromptSubmit","prompt":"continue","session_id":"s11","cwd":"/tmp/x"}' \
  | HOOK_RUN >/dev/null 2>&1 || true
for i in 8 9 10 11 12; do
  echo "{\"hook_event_name\":\"PostToolUse\",\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"step$i\"},\"session_id\":\"s11\",\"cwd\":\"/tmp/x\"}" \
    | HOOK_RUN >/dev/null 2>&1 || true
done
if grep -qE '"type":"dead_end"' "$ROOT/journal.jsonl"; then
  echo "  FAIL: dead_end fired despite reset"; FAIL=$((FAIL+1))
else
  echo "  PASS: dead_end suppressed after UserPromptSubmit reset"; PASS=$((PASS+1))
fi

# --- Test 12: session change resets struggle counters ---
echo "Test 12: session change resets dead_end counter"
reset_state
for i in 1 2 3 4 5 6 7; do
  echo "{\"hook_event_name\":\"PostToolUse\",\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"a$i\"},\"session_id\":\"sA\",\"cwd\":\"/tmp/x\"}" \
    | HOOK_RUN >/dev/null 2>&1 || true
done
# Now switch to session sB. First post-tool in new session should NOT trigger dead_end.
echo '{"hook_event_name":"PostToolUse","tool_name":"Bash","tool_input":{"command":"b1"},"session_id":"sB","cwd":"/tmp/x"}' \
  | HOOK_RUN >/dev/null 2>&1 || true
if grep -qE '"type":"dead_end"' "$ROOT/journal.jsonl"; then
  echo "  FAIL: dead_end fired across session boundary"; FAIL=$((FAIL+1))
else
  echo "  PASS: dead_end did not leak across session"; PASS=$((PASS+1))
fi

# --- Test 13: edit_churn ---
echo "Test 13: edit_churn fires after 4 edits to same file"
reset_state
for i in 1 2 3 4; do
  echo '{"hook_event_name":"PostToolUse","tool_name":"Edit","tool_input":{"file_path":"/tmp/x.py"},"session_id":"sE","cwd":"/tmp/x"}' \
    | HOOK_RUN >/dev/null 2>&1 || true
done
assert_grep "$ROOT/journal.jsonl" '"type":"edit_churn"' "4x edits to same file logs edit_churn"

# --- Test 14: build_loop ---
echo "Test 14: build_loop fires after 2 failed builds"
reset_state
for i in 1 2; do
  echo '{"hook_event_name":"PostToolUse","tool_name":"Bash","tool_input":{"command":"go test ./..."},"tool_response":{"is_error":true,"content":"FAIL: TestFoo"},"session_id":"sB","cwd":"/tmp/x"}' \
    | HOOK_RUN >/dev/null 2>&1 || true
done
assert_grep "$ROOT/journal.jsonl" '"type":"build_loop"' "2x failed test logs build_loop"

# --- Test 15: subagent_dispatch_pattern ---
echo "Test 15: subagent_dispatch_pattern fires after 3 same-type dispatches"
reset_state
for i in 1 2 3; do
  echo '{"hook_event_name":"PreToolUse","tool_name":"Agent","tool_input":{"subagent_type":"orchestrator"},"session_id":"sD","cwd":"/tmp/x"}' \
    | HOOK_RUN >/dev/null 2>&1 || true
done
assert_grep "$ROOT/journal.jsonl" '"type":"subagent_dispatch_pattern"' "3x same subagent logs subagent_dispatch_pattern"

# --- Test 16: build_loop ignores non-build Bash errors ---
echo "Test 16: build_loop ignores non-build commands"
reset_state
for i in 1 2 3; do
  echo '{"hook_event_name":"PostToolUse","tool_name":"Bash","tool_input":{"command":"ls /nope"},"tool_response":{"is_error":true,"content":"No such file"},"session_id":"sN","cwd":"/tmp/x"}' \
    | HOOK_RUN >/dev/null 2>&1 || true
done
if grep -qE '"type":"build_loop"' "$ROOT/journal.jsonl"; then
  echo "  FAIL: build_loop fired on non-build command"; FAIL=$((FAIL+1))
else
  echo "  PASS: build_loop correctly ignored non-build command"; PASS=$((PASS+1))
fi

# --- Test 17: adam-archive moves matching entries to actioned file ---
echo "Test 17: adam-archive moves matching journal entries"
reset_state
rm -f "$ROOT/journal/actioned-test-archive-001.jsonl"
cat > "$ROOT/journal.jsonl" <<EOF
{"ts":"2026-01-01T00:00:00Z","session":"sX","type":"correction"}
{"ts":"2026-01-02T00:00:00Z","session":"sX","type":"correction"}
{"ts":"2026-01-03T00:00:00Z","session":"sX","type":"dead_end"}
EOF
mkdir -p /tmp/adam-test-17
cat > /tmp/adam-test-17/proposal.md <<EOF
---
id: test-archive-001
type: memory
target: /tmp/test
confidence: 5
blast_radius: low
auto_apply_eligible: false
status: applied
source_entries:
  - "2026-01-01T00:00:00Z"
  - "2026-01-02T00:00:00Z"
---
# Why
test
EOF
ARCHIVE_RUN /tmp/adam-test-17/proposal.md >/dev/null 2>&1 || true
remaining=$(wc -l < "$ROOT/journal.jsonl" | tr -d ' ')
archived=$(wc -l < "$ROOT/journal/actioned-test-archive-001.jsonl" 2>/dev/null | tr -d ' ' || echo 0)
if [ "$remaining" = "1" ] && [ "$archived" = "2" ]; then
  echo "  PASS: archive moved 2 matching, kept 1 unmatched"; PASS=$((PASS+1))
else
  echo "  FAIL: expected 1 remaining + 2 archived, got $remaining + $archived"; FAIL=$((FAIL+1))
fi
rm -rf /tmp/adam-test-17 "$ROOT/journal/actioned-test-archive-001.jsonl"

# --- Test 18: adam-archive no-op when source_entries missing ---
echo "Test 18: adam-archive no-op when source_entries missing"
reset_state
echo '{"ts":"2026-01-01T00:00:00Z","type":"correction"}' > "$ROOT/journal.jsonl"
mkdir -p /tmp/adam-test-18
cat > /tmp/adam-test-18/proposal.md <<EOF
---
id: test-noop-002
type: memory
---
# Why
no source_entries
EOF
ARCHIVE_RUN /tmp/adam-test-18/proposal.md >/dev/null 2>&1 || true
if [ -f "$ROOT/journal/actioned-test-noop-002.jsonl" ]; then
  echo "  FAIL: archive file created when no source_entries"; FAIL=$((FAIL+1))
else
  echo "  PASS: no archive file created"; PASS=$((PASS+1))
fi
remaining=$(wc -l < "$ROOT/journal.jsonl" | tr -d ' ')
if [ "$remaining" = "1" ]; then
  echo "  PASS: journal unchanged"; PASS=$((PASS+1))
else
  echo "  FAIL: journal modified ($remaining lines, expected 1)"; FAIL=$((FAIL+1))
fi
rm -rf /tmp/adam-test-18

# --- Test 19: correction_free_streak fires after 5 clean prompts ---
echo "Test 19: correction_free_streak after 5 clean prompts"
reset_state
for i in 1 2 3 4 5; do
  echo "{\"hook_event_name\":\"UserPromptSubmit\",\"prompt\":\"please do step $i\",\"session_id\":\"sCF\",\"cwd\":\"/tmp/x\"}" \
    | HOOK_RUN >/dev/null 2>&1 || true
done
assert_grep "$ROOT/journal.jsonl" '"type":"correction_free_streak"' "5 clean prompts logs correction_free_streak"

# --- Test 20: correction phrase resets streak counter ---
echo "Test 20: correction phrase breaks correction_free_streak"
reset_state
for i in 1 2 3 4; do
  echo "{\"hook_event_name\":\"UserPromptSubmit\",\"prompt\":\"please do step $i\",\"session_id\":\"sCB\",\"cwd\":\"/tmp/x\"}" \
    | HOOK_RUN >/dev/null 2>&1 || true
done
echo '{"hook_event_name":"UserPromptSubmit","prompt":"no, undo that","session_id":"sCB","cwd":"/tmp/x"}' \
  | HOOK_RUN >/dev/null 2>&1 || true
echo '{"hook_event_name":"UserPromptSubmit","prompt":"go on","session_id":"sCB","cwd":"/tmp/x"}' \
  | HOOK_RUN >/dev/null 2>&1 || true
if grep -qE '"type":"correction_free_streak"' "$ROOT/journal.jsonl"; then
  echo "  FAIL: correction_free_streak fired despite intervening correction"; FAIL=$((FAIL+1))
else
  echo "  PASS: correction phrase reset the streak counter"; PASS=$((PASS+1))
fi

# --- Test 21: clean_recovery fires after struggle + 3 clean tools ---
echo "Test 21: clean_recovery after struggle + 3 clean tools"
reset_state
for i in 1 2 3; do
  echo '{"hook_event_name":"PostToolUse","tool_name":"Bash","tool_input":{"command":"foo"},"tool_response":{"is_error":true,"content":"Error: command not found: foo"},"session_id":"sR","cwd":"/tmp/x"}' \
    | HOOK_RUN >/dev/null 2>&1 || true
done
for i in 1 2 3; do
  echo "{\"hook_event_name\":\"PostToolUse\",\"tool_name\":\"Read\",\"tool_input\":{\"file_path\":\"/tmp/ok-$i\"},\"tool_response\":{\"content\":\"ok\"},\"session_id\":\"sR\",\"cwd\":\"/tmp/x\"}" \
    | HOOK_RUN >/dev/null 2>&1 || true
done
assert_grep "$ROOT/journal.jsonl" '"type":"clean_recovery"' "3 clean tools after struggle logs clean_recovery"
assert_grep "$ROOT/journal.jsonl" '"recovered_from":"tool_error_loop"' "recovered_from set on clean_recovery"

# --- Test 22: clean_recovery resets when error breaks the streak ---
echo "Test 22: clean_recovery suppressed by intervening error"
reset_state
for i in 1 2 3; do
  echo '{"hook_event_name":"PostToolUse","tool_name":"Bash","tool_input":{"command":"foo"},"tool_response":{"is_error":true,"content":"Error: command not found: foo"},"session_id":"sRE","cwd":"/tmp/x"}' \
    | HOOK_RUN >/dev/null 2>&1 || true
done
for i in 1 2; do
  echo "{\"hook_event_name\":\"PostToolUse\",\"tool_name\":\"Read\",\"tool_input\":{\"file_path\":\"/tmp/ok-$i\"},\"tool_response\":{\"content\":\"ok\"},\"session_id\":\"sRE\",\"cwd\":\"/tmp/x\"}" \
    | HOOK_RUN >/dev/null 2>&1 || true
done
echo '{"hook_event_name":"PostToolUse","tool_name":"Bash","tool_input":{"command":"x"},"tool_response":{"is_error":true,"content":"Error: again"},"session_id":"sRE","cwd":"/tmp/x"}' \
  | HOOK_RUN >/dev/null 2>&1 || true
echo '{"hook_event_name":"PostToolUse","tool_name":"Read","tool_input":{"file_path":"/tmp/ok-3"},"tool_response":{"content":"ok"},"session_id":"sRE","cwd":"/tmp/x"}' \
  | HOOK_RUN >/dev/null 2>&1 || true
if grep -qE '"type":"clean_recovery"' "$ROOT/journal.jsonl"; then
  echo "  FAIL: clean_recovery fired despite intervening error"; FAIL=$((FAIL+1))
else
  echo "  PASS: clean_recovery suppressed by intervening error"; PASS=$((PASS+1))
fi

# --- Test 23: active_skills payload populated on win signals ---
echo "Test 23: correction_free_streak payload includes active skill"
reset_state
echo '{"hook_event_name":"PreToolUse","tool_name":"Skill","tool_input":{"skill":"caveman"},"session_id":"sAS","cwd":"/tmp/x"}' \
  | HOOK_RUN >/dev/null 2>&1 || true
for i in 1 2 3 4 5; do
  echo "{\"hook_event_name\":\"UserPromptSubmit\",\"prompt\":\"step $i\",\"session_id\":\"sAS\",\"cwd\":\"/tmp/x\"}" \
    | HOOK_RUN >/dev/null 2>&1 || true
done
assert_grep "$ROOT/journal.jsonl" '"active_skills":\["caveman"\]' "active_skills payload includes invoked skill"

# --- Test 24: task_completed fires on diverse multi-tool task ---
echo "Test 24: task_completed after 5 tools / 3 kinds / no corrections"
reset_state
for kind in Bash Read Edit Write Grep; do
  echo "{\"hook_event_name\":\"PostToolUse\",\"tool_name\":\"$kind\",\"tool_input\":{},\"session_id\":\"sT\",\"cwd\":\"/tmp/x\"}" \
    | HOOK_RUN >/dev/null 2>&1 || true
done
echo '{"hook_event_name":"UserPromptSubmit","prompt":"go on","session_id":"sT","cwd":"/tmp/x"}' \
  | HOOK_RUN >/dev/null 2>&1 || true
assert_grep "$ROOT/journal.jsonl" '"type":"task_completed"' "5 tools + 5 kinds + 0 corrections emits task_completed"

# --- Test 25: task_completed suppressed when tool diversity < 3 ---
echo "Test 25: task_completed suppressed on single-tool run"
reset_state
for i in 1 2 3 4 5; do
  echo "{\"hook_event_name\":\"PostToolUse\",\"tool_name\":\"Edit\",\"tool_input\":{\"file_path\":\"/tmp/$i\"},\"session_id\":\"sT2\",\"cwd\":\"/tmp/x\"}" \
    | HOOK_RUN >/dev/null 2>&1 || true
done
echo '{"hook_event_name":"UserPromptSubmit","prompt":"go on","session_id":"sT2","cwd":"/tmp/x"}' \
  | HOOK_RUN >/dev/null 2>&1 || true
if grep -qE '"type":"task_completed"' "$ROOT/journal.jsonl"; then
  echo "  FAIL: task_completed fired on single-tool task"; FAIL=$((FAIL+1))
else
  echo "  PASS: task_completed suppressed (low tool diversity)"; PASS=$((PASS+1))
fi

# --- Test 26: task_completed suppressed when correction fires mid-task ---
echo "Test 26: task_completed suppressed after correction"
reset_state
for kind in Bash Read Edit Write Grep; do
  echo "{\"hook_event_name\":\"PostToolUse\",\"tool_name\":\"$kind\",\"tool_input\":{},\"session_id\":\"sT3\",\"cwd\":\"/tmp/x\"}" \
    | HOOK_RUN >/dev/null 2>&1 || true
done
# Correction phrase resets task_corrections inside the same UserPromptSubmit cycle, so the prior run is disqualified.
echo '{"hook_event_name":"UserPromptSubmit","prompt":"no, undo that","session_id":"sT3","cwd":"/tmp/x"}' \
  | HOOK_RUN >/dev/null 2>&1 || true
if grep -qE '"type":"task_completed"' "$ROOT/journal.jsonl"; then
  echo "  FAIL: task_completed fired despite correction on the closing prompt"; FAIL=$((FAIL+1))
else
  echo "  PASS: task_completed suppressed by correction"; PASS=$((PASS+1))
fi

# --- Test 27: weekly ISO rotation triggers when active journal is from prior week ---
echo "Test 27: weekly rotation triggers when active journal is from prior ISO week"
reset_state
# Seed an entry stamped 14 days ago (definitely a prior ISO week).
prev_ts=$(node -e 'console.log(new Date(Date.now() - 14*86400000).toISOString())')
echo "{\"ts\":\"$prev_ts\",\"session\":\"sROT1\",\"type\":\"correction\",\"phrase\":\"old\"}" > "$ROOT/journal.jsonl"
echo '{"hook_event_name":"UserPromptSubmit","prompt":"hello world","session_id":"sROT1","cwd":"/tmp/x"}' \
  | HOOK_RUN >/dev/null 2>&1 || true
# Active journal should be fresh (the old entry rotated out, optionally new
# entries appended for the current event).
if grep -q "$prev_ts" "$ROOT/journal.jsonl" 2>/dev/null; then
  echo "  FAIL: prior-week entry still in active journal"; FAIL=$((FAIL+1))
else
  echo "  PASS: prior-week entry no longer in active journal"; PASS=$((PASS+1))
fi
# A rotated file matching YYYY-Www should exist.
rotated_iso=$(ls "$ROOT/journal/" 2>/dev/null | grep -E '^[0-9]{4}-W[0-9]{2}\.jsonl$' | wc -l | tr -d ' ')
if [ "$rotated_iso" -ge "1" ]; then
  echo "  PASS: ISO-week rotated file created"; PASS=$((PASS+1))
else
  echo "  FAIL: no ISO-week rotated file (got: $(ls "$ROOT/journal/" 2>/dev/null))"; FAIL=$((FAIL+1))
fi
rm -f "$ROOT/journal/"*.jsonl 2>/dev/null

# --- Test 28: adam-window.mjs reads both legacy and new rotated formats ---
echo "Test 28: adam-window reads legacy size-rotated AND new ISO-week files"
reset_state
recent_ts=$(node -e 'console.log(new Date(Date.now() - 2*86400000).toISOString())')
echo "{\"ts\":\"$recent_ts\",\"session\":\"sLEG\",\"type\":\"correction\",\"phrase\":\"legacy\"}" \
  > "$ROOT/journal/2025-12-01-1733000000000.jsonl"
recent_ts2=$(node -e 'console.log(new Date(Date.now() - 3*86400000).toISOString())')
echo "{\"ts\":\"$recent_ts2\",\"session\":\"sISO\",\"type\":\"correction\",\"phrase\":\"new format\"}" \
  > "$ROOT/journal/2026-W18.jsonl"
out=$(WINDOW_RUN 2>/dev/null)
if echo "$out" | grep -q "legacy"; then
  echo "  PASS: legacy-format file readable"; PASS=$((PASS+1))
else
  echo "  FAIL: legacy-format entry missing from output"; FAIL=$((FAIL+1))
fi
if echo "$out" | grep -q "new format"; then
  echo "  PASS: new ISO-week file readable"; PASS=$((PASS+1))
else
  echo "  FAIL: ISO-week entry missing from output"; FAIL=$((FAIL+1))
fi
rm -f "$ROOT/journal/"*.jsonl 2>/dev/null

# --- Test 29: window filter excludes stale entries per signal type ---
echo "Test 29: per-signal window drops stale entries"
reset_state
old_de=$(node -e 'console.log(new Date(Date.now() - 8*86400000).toISOString())')
new_de=$(node -e 'console.log(new Date(Date.now() - 3*86400000).toISOString())')
old_co=$(node -e 'console.log(new Date(Date.now() - 31*86400000).toISOString())')
new_co=$(node -e 'console.log(new Date(Date.now() - 7*86400000).toISOString())')
cat > "$ROOT/journal.jsonl" <<EOF
{"ts":"$old_de","session":"sW","type":"dead_end","count":8}
{"ts":"$new_de","session":"sW","type":"dead_end","count":8}
{"ts":"$old_co","session":"sW","type":"correction","phrase":"old"}
{"ts":"$new_co","session":"sW","type":"correction","phrase":"new"}
EOF
out=$(WINDOW_RUN 2>/dev/null)
de_count=$(echo "$out" | grep -c '"type":"dead_end"' || true)
co_count=$(echo "$out" | grep -c '"type":"correction"' || true)
if [ "$de_count" = "1" ] && echo "$out" | grep -q "$new_de"; then
  echo "  PASS: only fresh dead_end kept (8d cutoff)"; PASS=$((PASS+1))
else
  echo "  FAIL: dead_end window wrong (got $de_count entries, expected 1)"; FAIL=$((FAIL+1))
fi
if [ "$co_count" = "1" ] && echo "$out" | grep -q "$new_co"; then
  echo "  PASS: only fresh correction kept (30d cutoff)"; PASS=$((PASS+1))
else
  echo "  FAIL: correction window wrong (got $co_count entries, expected 1)"; FAIL=$((FAIL+1))
fi

# --- Test 30: default window applies to unknown signal types ---
echo "Test 30: unknown signal type uses DEFAULT_WINDOW_DAYS (30)"
reset_state
ts_in=$(node -e 'console.log(new Date(Date.now() - 25*86400000).toISOString())')
ts_out=$(node -e 'console.log(new Date(Date.now() - 35*86400000).toISOString())')
cat > "$ROOT/journal.jsonl" <<EOF
{"ts":"$ts_in","session":"sU","type":"foo_bar","data":"within-default"}
{"ts":"$ts_out","session":"sU","type":"foo_bar","data":"past-default"}
EOF
out=$(WINDOW_RUN 2>/dev/null)
if echo "$out" | grep -q "within-default" && ! echo "$out" | grep -q "past-default"; then
  echo "  PASS: unknown signal uses 30d default (25d in, 35d out)"; PASS=$((PASS+1))
else
  echo "  FAIL: default window misapplied (out: $out)"; FAIL=$((FAIL+1))
fi

# --- Test 31: actioned-exclusion still works through adam-window ---
echo "Test 31: applied/*.md source_entries excluded from window output"
reset_state
ts1=$(node -e 'console.log(new Date(Date.now() - 1*86400000).toISOString())')
ts2=$(node -e 'console.log(new Date(Date.now() - 1*86400000 + 5000).toISOString())')
cat > "$ROOT/journal.jsonl" <<EOF
{"ts":"$ts1","session":"sX","type":"correction","phrase":"already actioned"}
{"ts":"$ts2","session":"sX","type":"correction","phrase":"still fresh"}
EOF
cat > "$ROOT/applied/2026-05-12T00-00-00Z-test-excl-001.md" <<EOF
---
id: test-excl-001
type: memory
target: /tmp/test
source_entries:
  - "$ts1"
---
# Why
fake applied proposal
EOF
out=$(WINDOW_RUN 2>/dev/null)
if echo "$out" | grep -q "already actioned"; then
  echo "  FAIL: actioned ts1 leaked into window output"; FAIL=$((FAIL+1))
else
  echo "  PASS: actioned ts1 excluded from window output"; PASS=$((PASS+1))
fi
if echo "$out" | grep -q "still fresh"; then
  echo "  PASS: unactioned ts2 still present"; PASS=$((PASS+1))
else
  echo "  FAIL: unactioned ts2 dropped unexpectedly"; FAIL=$((FAIL+1))
fi
rm -f "$ROOT/applied/"*.md

# --- Test 32: safety fuse forces rotation mid-week when size exceeds limit ---
echo "Test 32: safety fuse rotates even within same ISO week"
reset_state
# Build a current-week journal that exceeds a tiny ADAM_MAX_JOURNAL_BYTES.
current_ts=$(node -e 'console.log(new Date().toISOString())')
# Write enough lines to comfortably exceed 4096 bytes. Same ISO week (today).
for i in $(seq 1 200); do
  echo "{\"ts\":\"$current_ts\",\"session\":\"sFUSE\",\"type\":\"correction\",\"phrase\":\"padding line $i — lorem ipsum dolor sit amet consectetur adipiscing elit\"}" >> "$ROOT/journal.jsonl"
done
size_before=$(wc -c < "$ROOT/journal.jsonl" | tr -d ' ')
ADAM_MAX_JOURNAL_BYTES=4096 HOME="$TMP_HOME" node "$HOOK" \
  <<< '{"hook_event_name":"UserPromptSubmit","prompt":"continue","session_id":"sFUSE","cwd":"/tmp/x"}' \
  >/dev/null 2>&1 || true
rotated_files=$(ls "$ROOT/journal/" 2>/dev/null | wc -l | tr -d ' ')
if [ "$rotated_files" -ge "1" ] && [ "$size_before" -gt "4096" ]; then
  echo "  PASS: safety fuse rotated mid-week (had $size_before bytes, $rotated_files file(s) in journal/)"; PASS=$((PASS+1))
else
  echo "  FAIL: safety fuse did not rotate (size_before=$size_before, rotated=$rotated_files)"; FAIL=$((FAIL+1))
fi
rm -f "$ROOT/journal/"*.jsonl 2>/dev/null

# --- Test 33: fingerprint — phrase variant collapses to same ECONNREFUSED bucket ---
echo "Test 33: fingerprint collapses 'Connection refused' and 'ECONNREFUSED' variants"
fp_a=$(node -e "import('$HOOK').then(m => console.log(m.errorFingerprint({is_error:true,content:'Connection refused on port 5432'})))")
fp_b=$(node -e "import('$HOOK').then(m => console.log(m.errorFingerprint({is_error:true,content:'ECONNREFUSED 127.0.0.1:5432'})))")
if [ "$fp_a" = "$fp_b" ] && echo "$fp_a" | grep -q "^ECONNREFUSED:"; then
  echo "  PASS: ECONNREFUSED variants share fingerprint ($fp_a)"; PASS=$((PASS+1))
else
  echo "  FAIL: fingerprint mismatch (a=$fp_a b=$fp_b)"; FAIL=$((FAIL+1))
fi

# --- Test 34: fingerprint — ENOENT phrase + literal share bucket ---
echo "Test 34: fingerprint collapses 'no such file' variants to ENOENT bucket"
fp_a=$(node -e "import('$HOOK').then(m => console.log(m.errorFingerprint({is_error:true,content:\"ENOENT: no such file or directory, open '/tmp/foo.txt'\"})))")
fp_b=$(node -e "import('$HOOK').then(m => console.log(m.errorFingerprint({is_error:true,content:'no such file or directory: /var/log/baz.log'})))")
if [ "$fp_a" = "$fp_b" ] && echo "$fp_a" | grep -q "^ENOENT:"; then
  echo "  PASS: ENOENT variants share fingerprint ($fp_a)"; PASS=$((PASS+1))
else
  echo "  FAIL: ENOENT fingerprint mismatch (a=$fp_a b=$fp_b)"; FAIL=$((FAIL+1))
fi

# --- Test 35: fingerprint — path + line:col stripping (raw bucket) ---
echo "Test 35: fingerprint strips paths and line/col refs"
fp_a=$(node -e "import('$HOOK').then(m => console.log(m.errorFingerprint({is_error:true,content:'Error at /Users/alice/foo.js:42:7'})))")
fp_b=$(node -e "import('$HOOK').then(m => console.log(m.errorFingerprint({is_error:true,content:'Error at /home/bob/bar.js:100:3'})))")
if [ "$fp_a" = "$fp_b" ] && echo "$fp_a" | grep -q "^raw:"; then
  echo "  PASS: paths+linecol stripped, same raw bucket ($fp_a)"; PASS=$((PASS+1))
else
  echo "  FAIL: path-strip fingerprint mismatch (a=$fp_a b=$fp_b)"; FAIL=$((FAIL+1))
fi

# --- Test 36: fingerprint — hex addr + epoch stripping ---
echo "Test 36: fingerprint strips hex addresses and epoch timestamps"
fp_a=$(node -e "import('$HOOK').then(m => console.log(m.errorFingerprint({is_error:true,content:'Segfault at 0xdeadbeef at 1733000000000'})))")
fp_b=$(node -e "import('$HOOK').then(m => console.log(m.errorFingerprint({is_error:true,content:'Segfault at 0xcafebabe at 1733999999999'})))")
if [ "$fp_a" = "$fp_b" ] && echo "$fp_a" | grep -q "^raw:"; then
  echo "  PASS: hex+epoch stripped, same raw bucket ($fp_a)"; PASS=$((PASS+1))
else
  echo "  FAIL: hex/epoch fingerprint mismatch (a=$fp_a b=$fp_b)"; FAIL=$((FAIL+1))
fi

# --- Test 37: correction corpus — strong tokens fire ---
echo "Test 37: strong-correction tokens each emit correction signal"
strong_ok=1
for phrase in "stop, that's wrong" "wait, hold on" "try again differently" "different approach please"; do
  reset_state
  echo "{\"hook_event_name\":\"UserPromptSubmit\",\"prompt\":\"$phrase\",\"session_id\":\"sSTR\",\"cwd\":\"/tmp/x\"}" \
    | HOOK_RUN >/dev/null 2>&1 || true
  if ! grep -qE '"type":"correction"' "$ROOT/journal.jsonl"; then
    echo "  FAIL: strong token did not fire for: $phrase"
    strong_ok=0
  fi
done
if [ "$strong_ok" = "1" ]; then
  echo "  PASS: all four strong-token prompts emitted correction"; PASS=$((PASS+1))
else
  FAIL=$((FAIL+1))
fi

# --- Test 38: correction corpus — weak token suppressed without negation context ---
echo "Test 38: bare 'actually' without negation does NOT emit correction"
reset_state
echo '{"hook_event_name":"UserPromptSubmit","prompt":"actually, I think we should add caching","session_id":"sW1","cwd":"/tmp/x"}' \
  | HOOK_RUN >/dev/null 2>&1 || true
if grep -qE '"type":"correction"' "$ROOT/journal.jsonl"; then
  echo "  FAIL: weak 'actually' fired without negation context"; FAIL=$((FAIL+1))
else
  echo "  PASS: weak 'actually' correctly suppressed"; PASS=$((PASS+1))
fi

# --- Test 39: correction corpus — weak token fires WITH negation in window ---
echo "Test 39: 'actually ... not' within 8 tokens DOES emit correction"
reset_state
echo "{\"hook_event_name\":\"UserPromptSubmit\",\"prompt\":\"actually, that's not right\",\"session_id\":\"sW2\",\"cwd\":\"/tmp/x\"}" \
  | HOOK_RUN >/dev/null 2>&1 || true
if grep -qE '"type":"correction"' "$ROOT/journal.jsonl"; then
  echo "  PASS: weak 'actually' + nearby 'not' fired correction"; PASS=$((PASS+1))
else
  echo "  FAIL: weak co-occurrence did not fire"; FAIL=$((FAIL+1))
fi

# --- Test 40: correction corpus — bare 'no' suppressed but 'no, that's wrong' fires ---
echo "Test 40: bare 'no rush' suppressed; 'no, that's wrong' fires"
reset_state
echo '{"hook_event_name":"UserPromptSubmit","prompt":"no rush on this","session_id":"sW3","cwd":"/tmp/x"}' \
  | HOOK_RUN >/dev/null 2>&1 || true
if grep -qE '"type":"correction"' "$ROOT/journal.jsonl"; then
  echo "  FAIL: bare 'no' (no rush) fired correction"; FAIL=$((FAIL+1))
  bare_no_ok=0
else
  bare_no_ok=1
fi
reset_state
echo "{\"hook_event_name\":\"UserPromptSubmit\",\"prompt\":\"no, that's wrong\",\"session_id\":\"sW3b\",\"cwd\":\"/tmp/x\"}" \
  | HOOK_RUN >/dev/null 2>&1 || true
if grep -qE '"type":"correction"' "$ROOT/journal.jsonl"; then
  with_wrong_ok=1
else
  echo "  FAIL: 'no, that's wrong' did not fire correction"; FAIL=$((FAIL+1))
  with_wrong_ok=0
fi
if [ "$bare_no_ok" = "1" ] && [ "$with_wrong_ok" = "1" ]; then
  echo "  PASS: bare 'no' suppressed, 'no ... wrong' fires"; PASS=$((PASS+1))
fi

# --- Test 41: adam-explain parse + summary (4-cluster trace) ---
echo "Test 41: adam-explain --mode summary on 4-cluster trace"
TRACE_FILE="$TMP_HOME/.claude/adam/last-trace.txt"
cat > "$TRACE_FILE" <<'EOF'
```trace
c1 | signal=correction count=5 sessions=3 | gates: threshold=pass, cross_session=pass, window=in:5/out:0, contradiction=none | decision: proposal_emitted:memory
c2 | signal=dead_end count=1 sessions=1 | gates: threshold=pass, cross_session=fail, window=in:1/out:0, contradiction=none | decision: proposal_emitted:skill_new
c3 | signal=retry_loop count=2 sessions=1 | gates: threshold=fail:count_below_3, cross_session=fail, window=in:2/out:0, contradiction=none | decision: skipped:threshold
c4 | signal=tool_error_loop count=4 sessions=2 | gates: threshold=pass, cross_session=pass, window=in:4/out:6, contradiction=none | decision: skipped:window
SUMMARY: considered=4 emitted=2 skipped=2 reasons={threshold:1, contradiction:0, window:1, other:0}
```
EOF
out=$(EXPLAIN_RUN --mode summary 2>/dev/null)
if echo "$out" | grep -q "considered=4 emitted=2 skipped=2" && echo "$out" | grep -q "threshold:1" && echo "$out" | grep -q "window:1"; then
  echo "  PASS: summary shows considered=4 emitted=2 skipped=2 and reason breakdown"; PASS=$((PASS+1))
else
  echo "  FAIL: summary missing fields (got: $out)"; FAIL=$((FAIL+1))
fi

# --- Test 42: adam-explain --mode full prints histogram footer ---
echo "Test 42: adam-explain --mode full ends with rejection histogram"
out=$(EXPLAIN_RUN --mode full 2>/dev/null)
last=$(echo "$out" | tail -n 1)
if echo "$last" | grep -qE 'Rejection reasons: .*threshold 1.*window 1|Rejection reasons: .*window 1.*threshold 1'; then
  echo "  PASS: full mode footer reports threshold 1 + window 1"; PASS=$((PASS+1))
else
  echo "  FAIL: footer wrong (last line: $last)"; FAIL=$((FAIL+1))
fi

# --- Test 43: adam-explain --mode json shape ---
echo "Test 43: adam-explain --mode json parses and exposes summary + clusters"
out=$(EXPLAIN_RUN --mode json 2>/dev/null)
check=$(echo "$out" | node -e '
let buf = ""; process.stdin.on("data", d => buf += d).on("end", () => {
  try {
    const p = JSON.parse(buf);
    const okSummary = p.summary && p.summary.considered === 4 && p.summary.emitted === 2;
    const okFirst = p.clusters && p.clusters[0] && p.clusters[0].decision === "proposal_emitted:memory";
    console.log(okSummary && okFirst ? "ok" : "bad");
  } catch (e) { console.log("parse-error:" + e.message); }
});')
if [ "$check" = "ok" ]; then
  echo "  PASS: json has summary.considered=4 and clusters[0].decision correct"; PASS=$((PASS+1))
else
  echo "  FAIL: json shape wrong ($check)"; FAIL=$((FAIL+1))
fi

# --- Test 44: adam-explain tolerant input (no ```trace fence) ---
echo "Test 44: adam-explain accepts raw trace lines without fence"
cat > "$TRACE_FILE" <<'EOF'
c1 | signal=correction count=4 sessions=2 | gates: threshold=pass, cross_session=pass, window=in:4/out:0, contradiction=none | decision: proposal_emitted:memory
c2 | signal=dead_end count=1 sessions=1 | gates: threshold=pass, cross_session=fail, window=in:1/out:0, contradiction=none | decision: skipped:threshold
SUMMARY: considered=2 emitted=1 skipped=1 reasons={threshold:1, contradiction:0, window:0, other:0}
EOF
out=$(EXPLAIN_RUN --mode summary 2>/dev/null)
if echo "$out" | grep -q "considered=2 emitted=1 skipped=1"; then
  echo "  PASS: raw-input (no fence) parses correctly"; PASS=$((PASS+1))
else
  echo "  FAIL: tolerant parse failed (got: $out)"; FAIL=$((FAIL+1))
fi

# --- Test 45: adam-explain malformed line warns to stderr, exit 0 ---
echo "Test 45: adam-explain tolerates a garbage line interleaved with valid ones"
cat > "$TRACE_FILE" <<'EOF'
```trace
c1 | signal=correction count=5 sessions=3 | gates: threshold=pass, cross_session=pass, window=in:5/out:0, contradiction=none | decision: proposal_emitted:memory
this line is total garbage with no structure
c2 | signal=dead_end count=1 sessions=1 | gates: threshold=pass, cross_session=fail, window=in:1/out:0, contradiction=none | decision: skipped:threshold
SUMMARY: considered=2 emitted=1 skipped=1 reasons={threshold:1, contradiction:0, window:0, other:0}
```
EOF
stdout_file="$TMP_HOME/explain.stdout"
stderr_file="$TMP_HOME/explain.stderr"
if EXPLAIN_RUN --mode summary >"$stdout_file" 2>"$stderr_file"; then
  rc=0
else
  rc=$?
fi
if [ "$rc" = "0" ] && grep -q "malformed cluster line" "$stderr_file" && grep -q "considered=2 emitted=1" "$stdout_file"; then
  echo "  PASS: warning on stderr, valid lines parsed, exit 0"; PASS=$((PASS+1))
else
  echo "  FAIL: malformed handling wrong (rc=$rc stderr=$(cat "$stderr_file") stdout=$(cat "$stdout_file"))"; FAIL=$((FAIL+1))
fi

# Sub-assertion: fully unparseable input exits 1.
echo "garbage with no structure at all" > "$TRACE_FILE"
if EXPLAIN_RUN --mode summary >/dev/null 2>/dev/null; then
  echo "  FAIL: fully garbage input did not exit non-zero"; FAIL=$((FAIL+1))
else
  echo "  PASS: fully garbage input exits 1"; PASS=$((PASS+1))
fi

# --- Test 46: adam-explain empty trace (SUMMARY-only) ---
echo "Test 46: adam-explain handles empty trace block (SUMMARY only)"
cat > "$TRACE_FILE" <<'EOF'
```trace
SUMMARY: considered=0 emitted=0 skipped=0 reasons={threshold:0, contradiction:0, window:0, other:0}
```
EOF
if out=$(EXPLAIN_RUN --mode summary 2>/dev/null); then
  if echo "$out" | grep -q "considered=0 emitted=0 skipped=0"; then
    echo "  PASS: empty trace prints zeroed summary, exit 0"; PASS=$((PASS+1))
  else
    echo "  FAIL: empty trace summary wrong (got: $out)"; FAIL=$((FAIL+1))
  fi
else
  echo "  FAIL: empty trace produced non-zero exit"; FAIL=$((FAIL+1))
fi

# --- Test 47: adam-nudge-eligibility — 3 dead_ends in same session → eligible ---
echo "Test 47: nudge eligibility — 3 dead_ends in single session"
reset_state
ts1=$(node -e 'console.log(new Date(Date.now() - 60000).toISOString())')
ts2=$(node -e 'console.log(new Date(Date.now() - 40000).toISOString())')
ts3=$(node -e 'console.log(new Date(Date.now() - 20000).toISOString())')
cat > "$ROOT/journal.jsonl" <<EOF
{"ts":"$ts1","session":"sNE1","type":"dead_end","count":8}
{"ts":"$ts2","session":"sNE1","type":"dead_end","count":8}
{"ts":"$ts3","session":"sNE1","type":"dead_end","count":8}
EOF
out=$(ELIG_RUN --session sNE1 2>/dev/null)
if echo "$out" | grep -q '"eligible":true' && echo "$out" | grep -q '"dead_end_count":3'; then
  echo "  PASS: eligibility=true with dead_end_count=3"; PASS=$((PASS+1))
else
  echo "  FAIL: expected eligible:true count:3 (got: $out)"; FAIL=$((FAIL+1))
fi

# --- Test 48: adam-nudge-eligibility — below threshold ---
echo "Test 48: nudge eligibility — 2 dead_ends OR 3 across two sessions → not eligible"
reset_state
cat > "$ROOT/journal.jsonl" <<EOF
{"ts":"$ts1","session":"sNE2","type":"dead_end","count":8}
{"ts":"$ts2","session":"sNE2","type":"dead_end","count":8}
EOF
out=$(ELIG_RUN --session sNE2 2>/dev/null)
if echo "$out" | grep -q '"eligible":false' && echo "$out" | grep -q '"dead_end_count":2'; then
  sub_a=1
else
  sub_a=0
fi
cat > "$ROOT/journal.jsonl" <<EOF
{"ts":"$ts1","session":"sNE3a","type":"dead_end","count":8}
{"ts":"$ts2","session":"sNE3b","type":"dead_end","count":8}
{"ts":"$ts3","session":"sNE3c","type":"dead_end","count":8}
EOF
out=$(ELIG_RUN --session sNE3a 2>/dev/null)
if echo "$out" | grep -q '"eligible":false' && echo "$out" | grep -q '"dead_end_count":1'; then
  sub_b=1
else
  sub_b=0
fi
if [ "$sub_a" = "1" ] && [ "$sub_b" = "1" ]; then
  echo "  PASS: below-threshold cases correctly report eligible:false"; PASS=$((PASS+1))
else
  echo "  FAIL: below-threshold (a=$sub_a b=$sub_b)"; FAIL=$((FAIL+1))
fi

# --- Test 49: nudge display — cross-session entry surfaces, displays_used increments ---
echo "Test 49: nudge hook prints active nudge from different session"
reset_state
now_ms=$(node -e 'console.log(Date.now())')
future_ms=$(node -e 'console.log(Date.now() + 7*86400000)')
cat > "$ROOT/active-nudges.json" <<EOF
[{"kind":"dead_end_reminder","message":"adam: 3 dead_ends last session — checkpoint","created_at":$now_ms,"expires_at_ts":$future_ms,"max_displays":3,"displays_used":0,"source_session":"sOLD"}]
EOF
out=$(echo '{"hook_event_name":"SessionStart","session_id":"sNEW"}' | NUDGE_RUN 2>&1 || true)
if echo "$out" | grep -q "3 dead_ends last session"; then
  printed_ok=1
else
  printed_ok=0
fi
inc=$(node -e 'const j=require("'"$ROOT"'/active-nudges.json"); console.log(j[0].displays_used)')
if [ "$printed_ok" = "1" ] && [ "$inc" = "1" ]; then
  echo "  PASS: nudge printed and displays_used incremented to 1"; PASS=$((PASS+1))
else
  echo "  FAIL: printed=$printed_ok displays_used=$inc out=$out"; FAIL=$((FAIL+1))
fi
rm -f "$ROOT/active-nudges.json"

# --- Test 50: nudge expiry — past expires_at_ts → no print + removed ---
echo "Test 50: expired nudge is dropped silently"
reset_state
past_ms=$(node -e 'console.log(Date.now() - 86400000)')
cat > "$ROOT/active-nudges.json" <<EOF
[{"kind":"dead_end_reminder","message":"adam: stale should not print","created_at":1,"expires_at_ts":$past_ms,"max_displays":3,"displays_used":0,"source_session":"sOLD"}]
EOF
out=$(echo '{"hook_event_name":"SessionStart","session_id":"sNEW2"}' | NUDGE_RUN 2>&1 || true)
remaining=$(node -e 'const j=require("'"$ROOT"'/active-nudges.json"); console.log(j.length)')
if ! echo "$out" | grep -q "stale should not print" && [ "$remaining" = "0" ]; then
  echo "  PASS: expired nudge suppressed and removed from file"; PASS=$((PASS+1))
else
  echo "  FAIL: out=$out remaining=$remaining"; FAIL=$((FAIL+1))
fi
rm -f "$ROOT/active-nudges.json"

# --- Test 51: cooldown active — same skill+fingerprint within 7d → cooldown ---
echo "Test 51: cooldown — same (skill, fingerprint) within 7d"
reset_state
applied_ts=$(node -e 'console.log(Date.now() - 2*86400000)')
cat > "$ROOT/applied/2026-05-10-test.md" <<EOF
---
id: cd-test-001
type: skill_edit
target_skill: foo
proposal_fingerprint: abc123
applied_at: $applied_ts
---
body
EOF
out=$(COOLDOWN_RUN --skill foo --fingerprint abc123 2>/dev/null)
if echo "$out" | grep -q '"status":"cooldown"' && echo "$out" | grep -q '"days_remaining":5'; then
  echo "  PASS: cooldown active with days_remaining=5"; PASS=$((PASS+1))
else
  echo "  FAIL: expected cooldown / days_remaining=5 (got: $out)"; FAIL=$((FAIL+1))
fi

# --- Test 52: different fingerprint, same skill → cool ---
echo "Test 52: cooldown — different fingerprint releases gate"
out=$(COOLDOWN_RUN --skill foo --fingerprint def456 2>/dev/null)
if echo "$out" | grep -q '"status":"cool"'; then
  echo "  PASS: different fingerprint returns cool"; PASS=$((PASS+1))
else
  echo "  FAIL: expected cool (got: $out)"; FAIL=$((FAIL+1))
fi

# --- Test 53: different skill, same fingerprint → cool ---
echo "Test 53: cooldown — different skill same fingerprint returns cool"
out=$(COOLDOWN_RUN --skill bar --fingerprint abc123 2>/dev/null)
if echo "$out" | grep -q '"status":"cool"'; then
  echo "  PASS: different skill returns cool"; PASS=$((PASS+1))
else
  echo "  FAIL: expected cool (got: $out)"; FAIL=$((FAIL+1))
fi
rm -f "$ROOT/applied/2026-05-10-test.md"

# --- Test 54: blacklist — rejected with auto_apply_blacklist within 30d ---
echo "Test 54: blacklist — rejected with auto_apply_blacklist:true 10d ago"
reset_state
rej_ts=$(node -e 'console.log(Date.now() - 10*86400000)')
cat > "$ROOT/rejected/2026-05-03-rej.md" <<EOF
---
id: rej-test-001
type: skill_edit
target_skill: baz
proposal_fingerprint: xyz789
auto_apply_blacklist: true
applied_at: $rej_ts
---
body
EOF
out=$(COOLDOWN_RUN --skill baz --fingerprint xyz789 2>/dev/null)
if echo "$out" | grep -q '"status":"blacklisted"'; then
  echo "  PASS: blacklisted status returned"; PASS=$((PASS+1))
else
  echo "  FAIL: expected blacklisted (got: $out)"; FAIL=$((FAIL+1))
fi
rm -f "$ROOT/rejected/2026-05-03-rej.md"

# --- Test 55: legacy proposal (no proposal_fingerprint field) → coarse cooldown ---
echo "Test 55: legacy applied without proposal_fingerprint → still produces cooldown"
reset_state
applied_ts=$(node -e 'console.log(Date.now() - 1*86400000)')
cat > "$ROOT/applied/2026-05-11-legacy.md" <<EOF
---
id: legacy-001
type: skill_edit
target_skill: legacyfoo
applied_at: $applied_ts
---
body
EOF
out=$(COOLDOWN_RUN --skill legacyfoo --fingerprint anything-here 2>/dev/null)
if echo "$out" | grep -q '"status":"cooldown"'; then
  echo "  PASS: legacy record without fingerprint produces coarse-grained cooldown"; PASS=$((PASS+1))
else
  echo "  FAIL: expected cooldown for legacy (got: $out)"; FAIL=$((FAIL+1))
fi
rm -f "$ROOT/applied/2026-05-11-legacy.md"

# --- Test 56: dampener — 1 correction + 3 task_completed → 0.5 ---
echo "Test 56: score dampener — 3 task_completed → 0.5"
reset_state
ts0=$(node -e 'console.log(new Date(Date.now() - 5000).toISOString())')
ts1=$(node -e 'console.log(new Date(Date.now() - 4000).toISOString())')
ts2=$(node -e 'console.log(new Date(Date.now() - 3000).toISOString())')
ts3=$(node -e 'console.log(new Date(Date.now() - 2000).toISOString())')
ts4=$(node -e 'console.log(new Date(Date.now() - 1000).toISOString())')
cat > "$ROOT/journal.jsonl" <<EOF
{"ts":"$ts0","session":"sX","type":"correction","phrase":"no"}
{"ts":"$ts1","session":"sX","type":"task_completed","tool_kinds":["A","B","C"]}
{"ts":"$ts2","session":"sX","type":"task_completed","tool_kinds":["A","B","C"]}
{"ts":"$ts3","session":"sX","type":"task_completed","tool_kinds":["A","B","C"]}
EOF
out=$(SCORE_RUN 2>/dev/null)
if echo "$out" | node -e 'let b="";process.stdin.on("data",d=>b+=d).on("end",()=>{const j=JSON.parse(b);const s=j.sessions.find(x=>x.session_id==="sX");process.exit(s&&s.dampener===0.5?0:1)})'; then
  echo "  PASS: dampener 0.5 for 3 task_completed"; PASS=$((PASS+1))
else
  echo "  FAIL: dampener wrong (got: $out)"; FAIL=$((FAIL+1))
fi

# --- Test 57: dampener — 1 correction + 1 task_completed → 0.75 ---
echo "Test 57: score dampener — 1 task_completed → 0.75"
reset_state
cat > "$ROOT/journal.jsonl" <<EOF
{"ts":"$ts0","session":"sY","type":"correction","phrase":"no"}
{"ts":"$ts1","session":"sY","type":"task_completed","tool_kinds":["A","B","C"]}
EOF
out=$(SCORE_RUN 2>/dev/null)
if echo "$out" | node -e 'let b="";process.stdin.on("data",d=>b+=d).on("end",()=>{const j=JSON.parse(b);const s=j.sessions.find(x=>x.session_id==="sY");process.exit(s&&s.dampener===0.75?0:1)})'; then
  echo "  PASS: dampener 0.75 for 1 task_completed"; PASS=$((PASS+1))
else
  echo "  FAIL: dampener wrong (got: $out)"; FAIL=$((FAIL+1))
fi

# --- Test 58: dampener — 1 correction + 0 task_completed → 1.0 ---
echo "Test 58: score dampener — 0 task_completed → 1.0"
reset_state
cat > "$ROOT/journal.jsonl" <<EOF
{"ts":"$ts0","session":"sZ","type":"correction","phrase":"no"}
EOF
out=$(SCORE_RUN 2>/dev/null)
if echo "$out" | node -e 'let b="";process.stdin.on("data",d=>b+=d).on("end",()=>{const j=JSON.parse(b);const s=j.sessions.find(x=>x.session_id==="sZ");process.exit(s&&s.dampener===1.0?0:1)})'; then
  echo "  PASS: dampener 1.0 for 0 task_completed"; PASS=$((PASS+1))
else
  echo "  FAIL: dampener wrong (got: $out)"; FAIL=$((FAIL+1))
fi

# --- Test 59: reinforcement_candidates — 3 task_completed citing tdd-loop ---
echo "Test 59: reinforcement_candidates — 3 citations of tdd-loop"
reset_state
cat > "$ROOT/journal.jsonl" <<EOF
{"ts":"$ts1","session":"sR1","type":"task_completed","active_skills":["tdd-loop"]}
{"ts":"$ts2","session":"sR2","type":"task_completed","active_skills":["tdd-loop"]}
{"ts":"$ts3","session":"sR3","type":"task_completed","active_skills":["tdd-loop"]}
EOF
out=$(SCORE_RUN 2>/dev/null)
if echo "$out" | node -e 'let b="";process.stdin.on("data",d=>b+=d).on("end",()=>{const j=JSON.parse(b);const r=(j.reinforcement_candidates||[]).find(x=>x.skill_slug==="tdd-loop");process.exit(r&&r.count===3?0:1)})'; then
  echo "  PASS: tdd-loop reinforcement candidate with count=3"; PASS=$((PASS+1))
else
  echo "  FAIL: reinforcement candidate missing (got: $out)"; FAIL=$((FAIL+1))
fi

# --- Test 60: reinforcement below threshold — 2 citations not surfaced ---
echo "Test 60: reinforcement below threshold (2 citations) not in candidates"
reset_state
cat > "$ROOT/journal.jsonl" <<EOF
{"ts":"$ts1","session":"sR1","type":"task_completed","active_skills":["below-thresh"]}
{"ts":"$ts2","session":"sR2","type":"task_completed","active_skills":["below-thresh"]}
EOF
out=$(SCORE_RUN 2>/dev/null)
if echo "$out" | node -e 'let b="";process.stdin.on("data",d=>b+=d).on("end",()=>{const j=JSON.parse(b);const r=(j.reinforcement_candidates||[]).find(x=>x.skill_slug==="below-thresh");process.exit(r?1:0)})'; then
  echo "  PASS: below-threshold skill suppressed from candidates"; PASS=$((PASS+1))
else
  echo "  FAIL: below-threshold skill leaked (got: $out)"; FAIL=$((FAIL+1))
fi

# --- Test 61: A/B improved — 6 pre / 1 post → improved ---
echo "Test 61: A/B improved (6 pre / 1 post → status:improved)"
reset_state
applied_at_ms=$(node -e 'console.log(Date.now() - 14*86400000)')
cat > "$ROOT/ab-tracking.jsonl" <<EOF
{"applied_at":$applied_at_ms,"proposal_id":"ab-imp-001","proposal_type":"memory","target_skill":"foo","proposal_fingerprint":"fpA","originating_signals":[{"type":"correction","count":6,"session_ids":["sIMP"]}],"pre_window_days":7}
EOF
# applied_at = now - 14d. Pre window: [applied_at-7d, applied_at) = [now-21d, now-14d).
# Post window: [applied_at, applied_at+7d) = [now-14d, now-7d).
> "$ROOT/journal.jsonl"
for i in 1 2 3 4 5 6; do
  # 15d-20d ago (within pre window)
  pre_ts=$(node -e "console.log(new Date(Date.now() - (15 + $i*0.5) * 86400000).toISOString())")
  echo "{\"ts\":\"$pre_ts\",\"session\":\"sIMP\",\"type\":\"correction\",\"phrase\":\"x\"}" >> "$ROOT/journal.jsonl"
done
# Post: 1 entry 9d ago (within [now-14d, now-7d))
post_ts=$(node -e 'console.log(new Date(Date.now() - 9 * 86400000).toISOString())')
echo "{\"ts\":\"$post_ts\",\"session\":\"sIMP\",\"type\":\"correction\",\"phrase\":\"y\"}" >> "$ROOT/journal.jsonl"
out=$(ABMEASURE_RUN --format json 2>/dev/null)
if echo "$out" | node -e 'let b="";process.stdin.on("data",d=>b+=d).on("end",()=>{const a=JSON.parse(b);const e=a.find(x=>x.proposal_id==="ab-imp-001");process.exit(e&&e.pre_count===6&&e.post_count===1&&e.status==="improved"&&e.delta_pct<=-25?0:1)})'; then
  echo "  PASS: improved 6→1 → status:improved"; PASS=$((PASS+1))
else
  echo "  FAIL: ab-improved wrong (got: $out)"; FAIL=$((FAIL+1))
fi
rm -f "$ROOT/ab-tracking.jsonl"

# --- Test 62: A/B regressed — 2 pre / 6 post → regressed (delta=200) ---
echo "Test 62: A/B regressed (2 pre / 6 post → status:regressed delta_pct:200)"
reset_state
applied_at_ms=$(node -e 'console.log(Date.now() - 14*86400000)')
cat > "$ROOT/ab-tracking.jsonl" <<EOF
{"applied_at":$applied_at_ms,"proposal_id":"ab-reg-001","proposal_type":"skill_edit","target_skill":"bar","proposal_fingerprint":"fpB","originating_signals":[{"type":"correction","count":2,"session_ids":["sREG"]}],"pre_window_days":7}
EOF
> "$ROOT/journal.jsonl"
for i in 1 2; do
  pre_ts=$(node -e "console.log(new Date(Date.now() - (15 + $i*0.4) * 86400000).toISOString())")
  echo "{\"ts\":\"$pre_ts\",\"session\":\"sREG\",\"type\":\"correction\",\"phrase\":\"x\"}" >> "$ROOT/journal.jsonl"
done
for i in 1 2 3 4 5 6; do
  post_ts=$(node -e "console.log(new Date(Date.now() - (8 + $i*0.4) * 86400000).toISOString())")
  echo "{\"ts\":\"$post_ts\",\"session\":\"sREG\",\"type\":\"correction\",\"phrase\":\"y\"}" >> "$ROOT/journal.jsonl"
done
out=$(ABMEASURE_RUN --format json 2>/dev/null)
if echo "$out" | node -e 'let b="";process.stdin.on("data",d=>b+=d).on("end",()=>{const a=JSON.parse(b);const e=a.find(x=>x.proposal_id==="ab-reg-001");process.exit(e&&e.pre_count===2&&e.post_count===6&&e.delta_pct===200&&e.status==="regressed"?0:1)})'; then
  echo "  PASS: regressed 2→6 delta_pct=200 status=regressed"; PASS=$((PASS+1))
else
  echo "  FAIL: ab-regressed wrong (got: $out)"; FAIL=$((FAIL+1))
fi
rm -f "$ROOT/ab-tracking.jsonl"

# --- Test 63: A/B neutral — 4 pre / 4 post → neutral ---
echo "Test 63: A/B neutral (4 pre / 4 post → status:neutral)"
reset_state
applied_at_ms=$(node -e 'console.log(Date.now() - 14*86400000)')
cat > "$ROOT/ab-tracking.jsonl" <<EOF
{"applied_at":$applied_at_ms,"proposal_id":"ab-neu-001","proposal_type":"memory","target_skill":"baz","proposal_fingerprint":"fpC","originating_signals":[{"type":"correction","count":4,"session_ids":["sNEU"]}],"pre_window_days":7}
EOF
> "$ROOT/journal.jsonl"
for i in 1 2 3 4; do
  pre_ts=$(node -e "console.log(new Date(Date.now() - (15 + $i*0.4) * 86400000).toISOString())")
  echo "{\"ts\":\"$pre_ts\",\"session\":\"sNEU\",\"type\":\"correction\",\"phrase\":\"x\"}" >> "$ROOT/journal.jsonl"
done
for i in 1 2 3 4; do
  post_ts=$(node -e "console.log(new Date(Date.now() - (8 + $i*0.4) * 86400000).toISOString())")
  echo "{\"ts\":\"$post_ts\",\"session\":\"sNEU\",\"type\":\"correction\",\"phrase\":\"y\"}" >> "$ROOT/journal.jsonl"
done
out=$(ABMEASURE_RUN --format json 2>/dev/null)
if echo "$out" | node -e 'let b="";process.stdin.on("data",d=>b+=d).on("end",()=>{const a=JSON.parse(b);const e=a.find(x=>x.proposal_id==="ab-neu-001");process.exit(e&&e.pre_count===4&&e.post_count===4&&e.status==="neutral"?0:1)})'; then
  echo "  PASS: neutral 4→4 → status:neutral"; PASS=$((PASS+1))
else
  echo "  FAIL: ab-neutral wrong (got: $out)"; FAIL=$((FAIL+1))
fi
rm -f "$ROOT/ab-tracking.jsonl"

# --- Test 64: A/B no_baseline — 0 pre / N post → no_baseline ---
echo "Test 64: A/B no_baseline (0 pre / 3 post → status:no_baseline)"
reset_state
applied_at_ms=$(node -e 'console.log(Date.now() - 14*86400000)')
cat > "$ROOT/ab-tracking.jsonl" <<EOF
{"applied_at":$applied_at_ms,"proposal_id":"ab-nb-001","proposal_type":"memory","target_skill":"qux","proposal_fingerprint":"fpD","originating_signals":[{"type":"correction","count":0,"session_ids":["sNB"]}],"pre_window_days":7}
EOF
> "$ROOT/journal.jsonl"
for i in 1 2 3; do
  post_ts=$(node -e "console.log(new Date(Date.now() - (8 + $i*0.4) * 86400000).toISOString())")
  echo "{\"ts\":\"$post_ts\",\"session\":\"sNB\",\"type\":\"correction\",\"phrase\":\"y\"}" >> "$ROOT/journal.jsonl"
done
out=$(ABMEASURE_RUN --format json 2>/dev/null)
if echo "$out" | node -e 'let b="";process.stdin.on("data",d=>b+=d).on("end",()=>{const a=JSON.parse(b);const e=a.find(x=>x.proposal_id==="ab-nb-001");process.exit(e&&e.pre_count===0&&e.status==="no_baseline"&&e.delta_pct===null?0:1)})'; then
  echo "  PASS: no_baseline status when pre=0"; PASS=$((PASS+1))
else
  echo "  FAIL: ab-no_baseline wrong (got: $out)"; FAIL=$((FAIL+1))
fi
rm -f "$ROOT/ab-tracking.jsonl"

# --- Test 65: A/B pending — applied 3d ago, age < 7d ---
echo "Test 65: A/B pending (applied_at = now-3d → status:pending)"
reset_state
applied_at_ms=$(node -e 'console.log(Date.now() - 3*86400000)')
cat > "$ROOT/ab-tracking.jsonl" <<EOF
{"applied_at":$applied_at_ms,"proposal_id":"ab-pen-001","proposal_type":"memory","target_skill":"young","proposal_fingerprint":"fpE","originating_signals":[{"type":"correction","count":5,"session_ids":["sPEN"]}],"pre_window_days":7}
EOF
> "$ROOT/journal.jsonl"
out=$(ABMEASURE_RUN --format json 2>/dev/null)
if echo "$out" | node -e 'let b="";process.stdin.on("data",d=>b+=d).on("end",()=>{const a=JSON.parse(b);const e=a.find(x=>x.proposal_id==="ab-pen-001");process.exit(e&&e.status==="pending"&&e.pre_count===null?0:1)})'; then
  echo "  PASS: pending status when age < 7d"; PASS=$((PASS+1))
else
  echo "  FAIL: ab-pending wrong (got: $out)"; FAIL=$((FAIL+1))
fi
rm -f "$ROOT/ab-tracking.jsonl"

# --- Test 66: A/B multiple signal types — correction + dead_end counted additively ---
echo "Test 66: A/B multi-signal (correction + dead_end counted additively)"
reset_state
applied_at_ms=$(node -e 'console.log(Date.now() - 14*86400000)')
cat > "$ROOT/ab-tracking.jsonl" <<EOF
{"applied_at":$applied_at_ms,"proposal_id":"ab-multi-001","proposal_type":"skill_new","target_skill":"multi","proposal_fingerprint":"fpF","originating_signals":[{"type":"correction","count":2,"session_ids":["sM"]},{"type":"dead_end","count":1,"session_ids":["sM"]}],"pre_window_days":7}
EOF
> "$ROOT/journal.jsonl"
# Pre: 2 correction + 1 dead_end (total 3)
for i in 1 2; do
  pre_ts=$(node -e "console.log(new Date(Date.now() - (15 + $i*0.4) * 86400000).toISOString())")
  echo "{\"ts\":\"$pre_ts\",\"session\":\"sM\",\"type\":\"correction\",\"phrase\":\"x\"}" >> "$ROOT/journal.jsonl"
done
pre_de_ts=$(node -e 'console.log(new Date(Date.now() - 16 * 86400000).toISOString())')
echo "{\"ts\":\"$pre_de_ts\",\"session\":\"sM\",\"type\":\"dead_end\",\"count\":8}" >> "$ROOT/journal.jsonl"
# Post: 1 correction + 1 dead_end (total 2)
post_co=$(node -e 'console.log(new Date(Date.now() - 8 * 86400000).toISOString())')
echo "{\"ts\":\"$post_co\",\"session\":\"sM\",\"type\":\"correction\",\"phrase\":\"y\"}" >> "$ROOT/journal.jsonl"
post_de=$(node -e 'console.log(new Date(Date.now() - 9 * 86400000).toISOString())')
echo "{\"ts\":\"$post_de\",\"session\":\"sM\",\"type\":\"dead_end\",\"count\":8}" >> "$ROOT/journal.jsonl"
# Add an unrelated signal that MUST be ignored:
unrelated_ts=$(node -e 'console.log(new Date(Date.now() - 10 * 86400000).toISOString())')
echo "{\"ts\":\"$unrelated_ts\",\"session\":\"sM\",\"type\":\"retry_loop\"}" >> "$ROOT/journal.jsonl"
out=$(ABMEASURE_RUN --format json 2>/dev/null)
if echo "$out" | node -e 'let b="";process.stdin.on("data",d=>b+=d).on("end",()=>{const a=JSON.parse(b);const e=a.find(x=>x.proposal_id==="ab-multi-001");process.exit(e&&e.pre_count===3&&e.post_count===2?0:1)})'; then
  echo "  PASS: multi-signal counted additively (pre=3 post=2)"; PASS=$((PASS+1))
else
  echo "  FAIL: ab-multi wrong (got: $out)"; FAIL=$((FAIL+1))
fi
rm -f "$ROOT/ab-tracking.jsonl"

# --- Test 67: reinforcement apply — conf=4 + low → appended to reinforcements.jsonl ---
echo "Test 67: reinforcement apply path (conf=4, blast=low → appended)"
reset_state
rm -f "$ROOT/reinforcements.jsonl"
mkdir -p /tmp/adam-test-67
cat > /tmp/adam-test-67/prop.md <<EOF
---
id: rein-apply-001
type: reinforcement
skill_slug: tdd-loop
count: 3
source_session: foo
confidence: 4
blast_radius: low
---
# Why
test
EOF
out=$(APPLYREIN_RUN /tmp/adam-test-67/prop.md 2>/dev/null)
if echo "$out" | grep -q '"status":"applied"' && grep -q '"skill_slug":"tdd-loop"' "$ROOT/reinforcements.jsonl"; then
  echo "  PASS: reinforcement appended with skill_slug=tdd-loop"; PASS=$((PASS+1))
else
  echo "  FAIL: reinforcement apply failed (out=$out file=$(cat "$ROOT/reinforcements.jsonl" 2>/dev/null))"; FAIL=$((FAIL+1))
fi
rm -rf /tmp/adam-test-67

# --- Test 68: reinforcement gate — conf=3 → not applied, file unchanged ---
echo "Test 68: reinforcement gate (conf=3 → status:gated, file unchanged)"
reset_state
rm -f "$ROOT/reinforcements.jsonl"
mkdir -p /tmp/adam-test-68
cat > /tmp/adam-test-68/prop.md <<EOF
---
id: rein-gate-001
type: reinforcement
skill_slug: tdd-loop
count: 3
source_session: foo
confidence: 3
blast_radius: low
---
# Why
gated
EOF
out=$(APPLYREIN_RUN /tmp/adam-test-68/prop.md 2>/dev/null)
if echo "$out" | grep -q '"status":"gated"' && [ ! -f "$ROOT/reinforcements.jsonl" ]; then
  echo "  PASS: reinforcement gated at conf=3, file not created"; PASS=$((PASS+1))
else
  echo "  FAIL: gate did not fire (out=$out file_exists=$([ -f "$ROOT/reinforcements.jsonl" ] && echo yes || echo no))"; FAIL=$((FAIL+1))
fi
rm -rf /tmp/adam-test-68

# --- Test 69: adam-upgrade --list finds pending files ---
echo "Test 69: adam-upgrade --list finds pending files"
UP_HOME="$(mktemp -d -t adam-upgrade-69.XXXXXX)"
mkdir -p "$UP_HOME/agents"
echo "orig content" > "$UP_HOME/agents/adam.md"
echo "new content"  > "$UP_HOME/agents/adam.md.adam-new"
out=$(UPGRADE_RUN --list --home "$UP_HOME" 2>/tmp/adam-up-69.err)
err=$(cat /tmp/adam-up-69.err)
if echo "$out" | grep -q "adam.md.adam-new" && echo "$err" | grep -q "1 pending"; then
  echo "  PASS: --list found pending file"; PASS=$((PASS+1))
else
  echo "  FAIL: --list output=$out err=$err"; FAIL=$((FAIL+1))
fi
rm -rf "$UP_HOME" /tmp/adam-up-69.err

# --- Test 70: adam-upgrade --list empty ---
echo "Test 70: adam-upgrade --list empty"
UP_HOME="$(mktemp -d -t adam-upgrade-70.XXXXXX)"
mkdir -p "$UP_HOME/agents"
echo "x" > "$UP_HOME/agents/adam.md"
out=$(UPGRADE_RUN --list --home "$UP_HOME" 2>/tmp/adam-up-70.err)
err=$(cat /tmp/adam-up-70.err)
if [ -z "$out" ] && echo "$err" | grep -q "0 pending"; then
  echo "  PASS: --list empty (stdout blank, stderr 0 pending)"; PASS=$((PASS+1))
else
  echo "  FAIL: --list empty wrong (out=[$out] err=[$err])"; FAIL=$((FAIL+1))
fi
rm -rf "$UP_HOME" /tmp/adam-up-70.err

# --- Test 71: adam-upgrade --accept happy path ---
echo "Test 71: adam-upgrade --accept swaps files and backs up"
UP_HOME="$(mktemp -d -t adam-upgrade-71.XXXXXX)"
mkdir -p "$UP_HOME/agents"
echo "old version" > "$UP_HOME/agents/adam.md"
echo "new version" > "$UP_HOME/agents/adam.md.adam-new"
out=$(UPGRADE_RUN --accept "$UP_HOME/agents/adam.md" --home "$UP_HOME" 2>&1)
swapped=$(cat "$UP_HOME/agents/adam.md")
prev=$(cat "$UP_HOME/agents/adam.md.adam-prev" 2>/dev/null)
if [ "$swapped" = "new version" ] && [ "$prev" = "old version" ] && [ ! -f "$UP_HOME/agents/adam.md.adam-new" ]; then
  echo "  PASS: --accept atomic swap (new in place, prev backed up, .adam-new gone)"; PASS=$((PASS+1))
else
  echo "  FAIL: --accept wrong (out=$out swapped=$swapped prev=$prev)"; FAIL=$((FAIL+1))
fi
rm -rf "$UP_HOME"

# --- Test 72: adam-upgrade --accept missing .adam-new fails ---
echo "Test 72: adam-upgrade --accept on missing .adam-new returns exit 1"
UP_HOME="$(mktemp -d -t adam-upgrade-72.XXXXXX)"
mkdir -p "$UP_HOME/agents"
echo "only orig" > "$UP_HOME/agents/adam.md"
if UPGRADE_RUN --accept "$UP_HOME/agents/adam.md" --home "$UP_HOME" >/dev/null 2>/tmp/adam-up-72.err; then
  echo "  FAIL: --accept on missing .adam-new should exit 1"; FAIL=$((FAIL+1))
else
  if grep -qi "error" /tmp/adam-up-72.err; then
    echo "  PASS: --accept missing .adam-new exit 1 with stderr error"; PASS=$((PASS+1))
  else
    echo "  FAIL: --accept exit non-zero but no stderr error message"; FAIL=$((FAIL+1))
  fi
fi
rm -rf "$UP_HOME" /tmp/adam-up-72.err

# --- Test 73: adam-upgrade --accept-all sweeps all pending ---
echo "Test 73: adam-upgrade --accept-all sweeps pairs across subdirs"
UP_HOME="$(mktemp -d -t adam-upgrade-73.XXXXXX)"
mkdir -p "$UP_HOME/agents" "$UP_HOME/hooks" "$UP_HOME/skills/adam-self-improvement"
echo "old-a" > "$UP_HOME/agents/adam.md"
echo "new-a" > "$UP_HOME/agents/adam.md.adam-new"
echo "old-h" > "$UP_HOME/hooks/adam-nudge.mjs"
echo "new-h" > "$UP_HOME/hooks/adam-nudge.mjs.adam-new"
echo "old-s" > "$UP_HOME/skills/adam-self-improvement/SKILL.md"
echo "new-s" > "$UP_HOME/skills/adam-self-improvement/SKILL.md.adam-new"
UPGRADE_RUN --accept-all --home "$UP_HOME" >/dev/null 2>&1
after=$(UPGRADE_RUN --list --home "$UP_HOME" 2>/dev/null)
a=$(cat "$UP_HOME/agents/adam.md")
h=$(cat "$UP_HOME/hooks/adam-nudge.mjs")
s=$(cat "$UP_HOME/skills/adam-self-improvement/SKILL.md")
if [ "$a" = "new-a" ] && [ "$h" = "new-h" ] && [ "$s" = "new-s" ] && [ -z "$after" ]; then
  echo "  PASS: --accept-all swept 3 pairs and --list now empty"; PASS=$((PASS+1))
else
  echo "  FAIL: --accept-all wrong (a=$a h=$h s=$s after=$after)"; FAIL=$((FAIL+1))
fi
rm -rf "$UP_HOME"

# --- Test 74: adam-upgrade --diff shows both sides ---
echo "Test 74: adam-upgrade --diff prints header and content from both versions"
UP_HOME="$(mktemp -d -t adam-upgrade-74.XXXXXX)"
mkdir -p "$UP_HOME/agents"
printf 'alpha\nbeta\n' > "$UP_HOME/agents/adam.md"
printf 'alpha\ngamma\n' > "$UP_HOME/agents/adam.md.adam-new"
out=$(UPGRADE_RUN --diff "$UP_HOME/agents/adam.md" --home "$UP_HOME" 2>/dev/null)
# Accept either `diff -u` output (contains `-beta` and `+gamma`) or the
# MISSING:/NEW: fallback markers.
if echo "$out" | grep -q "=== $UP_HOME/agents/adam.md ===" && \
   ( ( echo "$out" | grep -q "beta" && echo "$out" | grep -q "gamma" ) ); then
  echo "  PASS: --diff header + both-side content"; PASS=$((PASS+1))
else
  echo "  FAIL: --diff output=$out"; FAIL=$((FAIL+1))
fi
rm -rf "$UP_HOME"

# --- Test 75: nudge prints pending-upgrade warning ---
echo "Test 75: adam-nudge prints pending upgrade warning when .adam-new exists"
reset_state
mkdir -p "$TMP_HOME/.claude/agents"
echo "x" > "$TMP_HOME/.claude/agents/adam.md.adam-new"
out=$(echo '{"hook_event_name":"SessionStart","session_id":"sUp"}' | NUDGE_RUN 2>/dev/null)
if echo "$out" | grep -q "pending upgrade"; then
  echo "  PASS: nudge surfaced pending upgrade warning"; PASS=$((PASS+1))
else
  echo "  FAIL: nudge missed pending upgrade warning (out=$out)"; FAIL=$((FAIL+1))
fi
rm -f "$TMP_HOME/.claude/agents/adam.md.adam-new"

# --- Test 76: cooldown resolves legacy `target:` field (v0.2.x compat) ---
echo "Test 76: legacy applied with only target: <path> still gates cooldown"
reset_state
applied_ts=$(node -e 'console.log(Date.now() - 1*86400000)')
cat > "$ROOT/applied/2026-05-11-legacy-target.md" <<EOF
---
id: legacy-002
type: skill_edit
target: skills/myskill/SKILL.md
applied_at: $applied_ts
---
body
EOF
out=$(COOLDOWN_RUN --skill myskill --fingerprint anything 2>/dev/null)
if echo "$out" | grep -q '"status":"cooldown"'; then
  echo "  PASS: legacy target: <path> resolves to skill slug, cooldown fires"; PASS=$((PASS+1))
else
  echo "  FAIL: target: <path> fallback missed (got: $out)"; FAIL=$((FAIL+1))
fi
out2=$(COOLDOWN_RUN --skill other --fingerprint anything 2>/dev/null)
if echo "$out2" | grep -q '"status":"cool"'; then
  echo "  PASS: target: <path> does not gate unrelated skills"; PASS=$((PASS+1))
else
  echo "  FAIL: target: <path> false-positive on unrelated skill (got: $out2)"; FAIL=$((FAIL+1))
fi
rm -f "$ROOT/applied/2026-05-11-legacy-target.md"

# --- Test 77: install.sh covers every adam-*.mjs script in scripts/ ---
echo "Test 77: install.sh references every adam-*.mjs file"
SCRIPTS_DIR="$REAL_HOME/.claude/adam/scripts"
INSTALL_SH=""
for cand in "$REAL_HOME/Documents/projects/private/claude-adam/install.sh" \
            "$REAL_HOME/Documents/projects/private/adam/install.sh"; do
  [ -f "$cand" ] && INSTALL_SH="$cand" && break
done
if [ -z "$INSTALL_SH" ]; then
  echo "  SKIP: install.sh not found in expected paths"
else
  missing=""
  for f in "$SCRIPTS_DIR"/adam-*.mjs; do
    [ -f "$f" ] || continue
    name=$(basename "$f" .mjs)
    if ! grep -q "$name" "$INSTALL_SH"; then
      missing="$missing $name"
    fi
  done
  if [ -z "$missing" ]; then
    echo "  PASS: every adam-*.mjs script is referenced in install.sh"; PASS=$((PASS+1))
  else
    echo "  FAIL: install.sh missing:$missing"; FAIL=$((FAIL+1))
  fi
fi

echo
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" = "0" ]
