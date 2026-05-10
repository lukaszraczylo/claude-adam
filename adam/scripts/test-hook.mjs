#!/usr/bin/env node
// Test driver for ~/.claude/hooks/adam-observe.mjs.
// Usage: node test-hook.mjs (runs all tests in this file).
// Spawns the hook with synthesized stdin in a tmp HOME, asserts journal contents.
import { spawnSync } from "node:child_process";
import { mkdtempSync, mkdirSync, readFileSync, existsSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { fileURLToPath } from "node:url";

const HOOK = join(fileURLToPath(new URL("../../hooks/adam-observe.mjs", import.meta.url)));

export function newTmpHome() {
  const home = mkdtempSync(join(tmpdir(), "adam-test-"));
  mkdirSync(join(home, ".claude/adam"), { recursive: true });
  return home;
}

export function feed(home, input) {
  const r = spawnSync("node", [HOOK], {
    input: JSON.stringify(input),
    env: { ...process.env, HOME: home },
    encoding: "utf8",
    timeout: 5000,
  });
  if (r.status !== 0) throw new Error(`hook exit ${r.status}: ${r.stderr}`);
  return r;
}

export function readJournal(home) {
  const p = join(home, ".claude/adam/journal.jsonl");
  if (!existsSync(p)) return [];
  return readFileSync(p, "utf8")
    .trim().split("\n").filter(Boolean).map((l) => JSON.parse(l));
}

export function assert(cond, msg) {
  if (!cond) { console.error(`FAIL: ${msg}`); process.exit(1); }
  console.log(`ok: ${msg}`);
}

export function cleanup(home) { try { rmSync(home, { recursive: true, force: true }); } catch {} }

// Tests below this line — added by subsequent tasks.

function testCorrectionFreeStreak() {
  const home = newTmpHome();
  try {
    for (let i = 0; i < 5; i++) {
      feed(home, {
        hook_event_name: "UserPromptSubmit",
        session_id: "s1",
        cwd: "/x",
        prompt: `please continue with the work item ${i}`,
      });
    }
    const j = readJournal(home);
    const streaks = j.filter(e => e.type === "correction_free_streak");
    assert(streaks.length === 1, "exactly one correction_free_streak after 5 clean prompts");
    assert(streaks[0].streak === 5, "streak field is 5");
    assert(streaks[0].session === "s1", "session id captured");
  } finally { cleanup(home); }
}

function testStreakResetsOnSessionChange() {
  const home = newTmpHome();
  try {
    // 4 in s1 (counter=4, no streak yet), then 1 in s2 (counter must reset → 1, no streak)
    for (let i = 0; i < 4; i++) feed(home, { hook_event_name: "UserPromptSubmit", session_id: "s1", cwd: "/x", prompt: "ok" });
    feed(home, { hook_event_name: "UserPromptSubmit", session_id: "s2", cwd: "/x", prompt: "ok" });
    const j = readJournal(home);
    assert(j.filter(e => e.type === "correction_free_streak").length === 0, "no streak when session changes mid-streak");
  } finally { cleanup(home); }
}

function testCleanRecovery() {
  const home = newTmpHome();
  try {
    // Trigger tool_error_loop: 3 PostToolUse with same error fingerprint.
    for (let i = 0; i < 3; i++) {
      feed(home, {
        hook_event_name: "PostToolUse",
        session_id: "s1", cwd: "/x",
        tool_name: "Bash",
        tool_input: { command: `echo ${i}` },
        tool_response: { is_error: true, content: "error: command not found" },
      });
    }
    // Then 3 clean PostToolUse events.
    for (let i = 0; i < 3; i++) {
      feed(home, {
        hook_event_name: "PostToolUse",
        session_id: "s1", cwd: "/x",
        tool_name: "Read",
        tool_input: { file_path: `/tmp/ok-${i}` },
        tool_response: { content: "fine" },
      });
    }
    const j = readJournal(home);
    const recs = j.filter(e => e.type === "clean_recovery");
    assert(recs.length === 1, "one clean_recovery emitted after 3 clean tools post-struggle");
    assert(recs[0].recovered_from === "tool_error_loop", "recovered_from set");
  } finally { cleanup(home); }
}

function testRecoveryResetsOnError() {
  const home = newTmpHome();
  try {
    for (let i = 0; i < 3; i++) {
      feed(home, {
        hook_event_name: "PostToolUse", session_id: "s1", cwd: "/x",
        tool_name: "Bash",
        tool_input: { command: `cmd ${i}` },
        tool_response: { is_error: true, content: "error: failed" },
      });
    }
    feed(home, { hook_event_name: "PostToolUse", session_id: "s1", cwd: "/x",
      tool_name: "Read", tool_input: { file_path: "/tmp/a" }, tool_response: { content: "ok" } });
    feed(home, { hook_event_name: "PostToolUse", session_id: "s1", cwd: "/x",
      tool_name: "Read", tool_input: { file_path: "/tmp/b" }, tool_response: { content: "ok" } });
    feed(home, { hook_event_name: "PostToolUse", session_id: "s1", cwd: "/x",
      tool_name: "Bash", tool_input: { command: "x" }, tool_response: { is_error: true, content: "error: again" } });
    feed(home, { hook_event_name: "PostToolUse", session_id: "s1", cwd: "/x",
      tool_name: "Read", tool_input: { file_path: "/tmp/c" }, tool_response: { content: "ok" } });
    const j = readJournal(home);
    assert(j.filter(e => e.type === "clean_recovery").length === 0, "no clean_recovery when error breaks the streak");
  } finally { cleanup(home); }
}

function testActiveSkillsPayload() {
  const home = newTmpHome();
  try {
    feed(home, { hook_event_name: "PreToolUse", session_id: "s1", cwd: "/x",
      tool_name: "Skill", tool_input: { skill: "my-skill" } });
    for (let i = 0; i < 5; i++) {
      feed(home, { hook_event_name: "UserPromptSubmit", session_id: "s1", cwd: "/x", prompt: "ok" });
    }
    const j = readJournal(home);
    const s = j.find(e => e.type === "correction_free_streak");
    assert(s && Array.isArray(s.active_skills) && s.active_skills.includes("my-skill"),
      "correction_free_streak payload includes active skill");
  } finally { cleanup(home); }
}

async function main() {
  testCorrectionFreeStreak();
  testStreakResetsOnSessionChange();
  testCleanRecovery();
  testRecoveryResetsOnError();
  testActiveSkillsPayload();
  console.log("all tests passed");
}

if (import.meta.url === `file://${process.argv[1]}`) main();
