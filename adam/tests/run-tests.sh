#!/usr/bin/env bash
# Test harness: ALWAYS runs against an isolated $HOME under mktemp.
# The hook/nudge/archive scripts being tested are sourced from the real $HOME
# but invoked with HOME="$TMP_HOME" so journal/state/usage write to the sandbox.
set -euo pipefail

REAL_HOME="$HOME"
HOOK="$REAL_HOME/.claude/hooks/adam-observe.mjs"
NUDGE="$REAL_HOME/.claude/hooks/adam-nudge.mjs"
ARCHIVE="$REAL_HOME/.claude/adam/scripts/adam-archive.mjs"

TMP_HOME="$(mktemp -d -t adam-test.XXXXXX)"
trap 'rm -rf "$TMP_HOME"' EXIT INT TERM
mkdir -p "$TMP_HOME/.claude/adam/proposals" "$TMP_HOME/.claude/adam/applied" "$TMP_HOME/.claude/adam/rejected" "$TMP_HOME/.claude/adam/journal"

ROOT="$TMP_HOME/.claude/adam"
HOOK_RUN()    { HOME="$TMP_HOME" node "$HOOK" "$@"; }
NUDGE_RUN()   { HOME="$TMP_HOME" node "$NUDGE" "$@"; }
ARCHIVE_RUN() { HOME="$TMP_HOME" node "$ARCHIVE" "$@"; }

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

# --- Test 6: journal rotation when file exceeds threshold ---
echo "Test 6: journal rotation"
reset_state
# Seed journal with > 5 MB to trigger rotation on next write
head -c 5500000 /dev/urandom | base64 > "$ROOT/journal.jsonl"
echo '{"hook_event_name":"UserPromptSubmit","prompt":"no, that is wrong","session_id":"s1","cwd":"/tmp/x"}' \
  | HOOK_RUN >/dev/null 2>&1 || true
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

echo
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" = "0" ]
