#!/usr/bin/env bash
set -euo pipefail

ROOT="$HOME/.claude/adam"
HOOK="$HOME/.claude/hooks/adam-observe.mjs"
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
  | node "$HOOK" >/dev/null 2>&1 || true
assert_lines "$ROOT/journal.jsonl" 1 "correction creates journal entry"
assert_grep  "$ROOT/journal.jsonl" '"type":"correction"' "entry has correct type"

# --- Test 2: retry loop ---
echo "Test 2: retry loop"
reset_state
for i in 1 2 3; do
  echo '{"hook_event_name":"PostToolUse","tool_name":"Bash","tool_input":{"command":"ls"},"session_id":"s1","cwd":"/tmp/x"}' \
    | node "$HOOK" >/dev/null 2>&1 || true
done
assert_grep "$ROOT/journal.jsonl" '"type":"retry_loop"' "3x same Bash logs retry_loop"

# --- Test 3: usage counter ---
echo "Test 3: usage counter"
reset_state
echo '{"hook_event_name":"PreToolUse","tool_name":"Skill","tool_input":{"skill":"foo"},"session_id":"s1","cwd":"/tmp/x"}' \
  | node "$HOOK" >/dev/null 2>&1 || true
assert_grep "$ROOT/usage.json" '"skill:foo"' "Skill invocation increments usage counter"

# --- Test 3b: agent prefix in usage counter ---
echo "Test 3b: agent prefix"
reset_state
echo '{"hook_event_name":"PreToolUse","tool_name":"Agent","tool_input":{"subagent_type":"bar"},"session_id":"s1","cwd":"/tmp/x"}' \
  | node "$HOOK" >/dev/null 2>&1 || true
assert_grep "$ROOT/usage.json" '"agent:bar"' "Agent invocation increments prefixed counter"

# --- Test 4: weak agent ---
echo "Test 4: weak agent"
reset_state
echo '{"hook_event_name":"PostToolUse","tool_name":"Agent","tool_input":{"subagent_type":"x"},"session_id":"s1","cwd":"/tmp/x"}' \
  | node "$HOOK" >/dev/null 2>&1 || true
echo '{"hook_event_name":"PostToolUse","tool_name":"Agent","tool_input":{"subagent_type":"x"},"session_id":"s1","cwd":"/tmp/x"}' \
  | node "$HOOK" >/dev/null 2>&1 || true
assert_grep "$ROOT/journal.jsonl" '"type":"weak_agent"' "2x same agent logs weak_agent"

# --- Test 5: hook never blocks (exit 0) ---
echo "Test 5: hook always exit 0 even on garbage input"
reset_state
if echo 'not json' | node "$HOOK" >/dev/null 2>&1; then
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
  | node "$HOOK" >/dev/null 2>&1 || true
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
NUDGE="$HOME/.claude/hooks/adam-nudge.mjs"
rm -f "$ROOT/proposals/"*.md 2>/dev/null
touch "$ROOT/proposals/a.md" "$ROOT/proposals/b.md" "$ROOT/proposals/c.md"
out=$(echo '{"hook_event_name":"SessionStart"}' | node "$NUDGE" 2>&1 || true)
if echo "$out" | grep -q "3 proposals queued"; then
  echo "  PASS: nudge prints reminder"; PASS=$((PASS+1))
else
  echo "  FAIL: nudge missing reminder (got: $out)"; FAIL=$((FAIL+1))
fi
rm -f "$ROOT/proposals/"*.md

echo "Test 8: nudge silent when 0 proposals"
out=$(echo '{"hook_event_name":"SessionStart"}' | node "$NUDGE" 2>&1 || true)
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
    | node "$HOOK" >/dev/null 2>&1 || true
done
assert_grep "$ROOT/journal.jsonl" '"type":"tool_error_loop"' "3x same error logs tool_error_loop"

# --- Test 10: dead_end on long autonomous run ---
echo "Test 10: dead_end after 8 tools without UserPromptSubmit"
reset_state
for i in 1 2 3 4 5 6 7 8; do
  echo "{\"hook_event_name\":\"PostToolUse\",\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"step$i\"},\"session_id\":\"s10\",\"cwd\":\"/tmp/x\"}" \
    | node "$HOOK" >/dev/null 2>&1 || true
done
assert_grep "$ROOT/journal.jsonl" '"type":"dead_end"' "8x PostToolUse without prompt logs dead_end"

# --- Test 11: dead_end resets on UserPromptSubmit ---
echo "Test 11: dead_end counter resets on UserPromptSubmit"
reset_state
for i in 1 2 3 4 5 6 7; do
  echo "{\"hook_event_name\":\"PostToolUse\",\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"step$i\"},\"session_id\":\"s11\",\"cwd\":\"/tmp/x\"}" \
    | node "$HOOK" >/dev/null 2>&1 || true
done
echo '{"hook_event_name":"UserPromptSubmit","prompt":"continue","session_id":"s11","cwd":"/tmp/x"}' \
  | node "$HOOK" >/dev/null 2>&1 || true
for i in 8 9 10 11 12; do
  echo "{\"hook_event_name\":\"PostToolUse\",\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"step$i\"},\"session_id\":\"s11\",\"cwd\":\"/tmp/x\"}" \
    | node "$HOOK" >/dev/null 2>&1 || true
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
    | node "$HOOK" >/dev/null 2>&1 || true
done
# Now switch to session sB. First post-tool in new session should NOT trigger dead_end.
echo '{"hook_event_name":"PostToolUse","tool_name":"Bash","tool_input":{"command":"b1"},"session_id":"sB","cwd":"/tmp/x"}' \
  | node "$HOOK" >/dev/null 2>&1 || true
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
    | node "$HOOK" >/dev/null 2>&1 || true
done
assert_grep "$ROOT/journal.jsonl" '"type":"edit_churn"' "4x edits to same file logs edit_churn"

# --- Test 14: build_loop ---
echo "Test 14: build_loop fires after 2 failed builds"
reset_state
for i in 1 2; do
  echo '{"hook_event_name":"PostToolUse","tool_name":"Bash","tool_input":{"command":"go test ./..."},"tool_response":{"is_error":true,"content":"FAIL: TestFoo"},"session_id":"sB","cwd":"/tmp/x"}' \
    | node "$HOOK" >/dev/null 2>&1 || true
done
assert_grep "$ROOT/journal.jsonl" '"type":"build_loop"' "2x failed test logs build_loop"

# --- Test 15: subagent_dispatch_pattern ---
echo "Test 15: subagent_dispatch_pattern fires after 3 same-type dispatches"
reset_state
for i in 1 2 3; do
  echo '{"hook_event_name":"PreToolUse","tool_name":"Agent","tool_input":{"subagent_type":"orchestrator"},"session_id":"sD","cwd":"/tmp/x"}' \
    | node "$HOOK" >/dev/null 2>&1 || true
done
assert_grep "$ROOT/journal.jsonl" '"type":"subagent_dispatch_pattern"' "3x same subagent logs subagent_dispatch_pattern"

# --- Test 16: build_loop ignores non-build Bash errors ---
echo "Test 16: build_loop ignores non-build commands"
reset_state
for i in 1 2 3; do
  echo '{"hook_event_name":"PostToolUse","tool_name":"Bash","tool_input":{"command":"ls /nope"},"tool_response":{"is_error":true,"content":"No such file"},"session_id":"sN","cwd":"/tmp/x"}' \
    | node "$HOOK" >/dev/null 2>&1 || true
done
if grep -qE '"type":"build_loop"' "$ROOT/journal.jsonl"; then
  echo "  FAIL: build_loop fired on non-build command"; FAIL=$((FAIL+1))
else
  echo "  PASS: build_loop correctly ignored non-build command"; PASS=$((PASS+1))
fi

# --- Test 17: adam-archive moves matching entries to actioned file ---
echo "Test 17: adam-archive moves matching journal entries"
ARCHIVE="$HOME/.claude/adam/scripts/adam-archive.mjs"
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
node "$ARCHIVE" /tmp/adam-test-17/proposal.md >/dev/null 2>&1 || true
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
node "$ARCHIVE" /tmp/adam-test-18/proposal.md >/dev/null 2>&1 || true
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

echo
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" = "0" ]
