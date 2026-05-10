#!/usr/bin/env node
import { readFileSync, writeFileSync, appendFileSync, existsSync, statSync, renameSync, mkdirSync } from "node:fs";
import { join } from "node:path";
import { homedir } from "node:os";

function djb2(str) {
  let h = 5381;
  for (let i = 0; i < str.length; i++) h = ((h << 5) + h) ^ str.charCodeAt(i);
  return (h >>> 0).toString(36);
}

const ROOT = join(homedir(), ".claude", "adam");
const JOURNAL = join(ROOT, "journal.jsonl");
const STATE = join(ROOT, "state.json");
const USAGE = join(ROOT, "usage.json");
const JOURNAL_DIR = join(ROOT, "journal");

const CORRECTION_RE = /\b(no|stop|don't|don\'t|wrong|actually|nope|undo|revert)\b/i;
const ERROR_RE = /\b(error|failed|exception|traceback|denied|cannot|unable to|not found|undefined|nullpointer|typeerror|syntaxerror|panic|fatal|enoent|econnrefused|etimedout|eaccess|segfault|crashed|uncaught)\b/i;
const BUILD_RE = /\b(build|compile|make|gradle|cargo|tsc|webpack|vite|rollup|pytest|jest|mocha|vitest|go\s+test|npm\s+test|yarn\s+test|npm\s+run\s+build|yarn\s+build|ctest|ninja|bazel)\b/i;
const EDIT_TOOLS = new Set(["Edit", "Write", "MultiEdit", "NotebookEdit"]);
const WINDOW_SIZE = 10;
const RETRY_THRESHOLD = 3;
const AGENT_RESPAWN_THRESHOLD = 2;
const ERROR_RING_SIZE = 5;
const ERROR_LOOP_THRESHOLD = 3;
const DEAD_END_THRESHOLD = 8;
const EDIT_CHURN_THRESHOLD = 4;
const BUILD_LOOP_THRESHOLD = 2;
const SUBAGENT_DISPATCH_THRESHOLD = 3;
const CORRECTION_FREE_THRESHOLD = 5;
const CLEAN_RECOVERY_WINDOW = 3;
const STRUGGLE_TYPES = new Set(["tool_error_loop", "dead_end", "retry_loop"]);
const ACTIVE_SKILLS_LOOKBACK = 10;
const STATE_MAX_BYTES = 1_000_000;

function safeRead(path, fallback) {
  try { return JSON.parse(readFileSync(path, "utf8")); } catch { return fallback; }
}

function safeWrite(path, obj) {
  try { writeFileSync(path, JSON.stringify(obj)); } catch {}
}

function rotateIfLarge(path, max) {
  try {
    if (existsSync(path) && statSync(path).size > max) {
      mkdirSync(JOURNAL_DIR, { recursive: true });
      const today = new Date().toISOString().slice(0, 10);
      const dest = join(JOURNAL_DIR, `${today}-${Date.now()}.jsonl`);
      renameSync(path, dest);
    }
  } catch {}
}

function readStdin() {
  if (process.stdin.isTTY) return null;
  let buf = "";
  try {
    buf = readFileSync(0, "utf8");
  } catch {}
  try { return JSON.parse(buf); } catch { return null; }
}

function appendJournal(entry) {
  rotateIfLarge(JOURNAL, STATE_MAX_BYTES * 5);
  try {
    appendFileSync(JOURNAL, JSON.stringify(entry) + "\n");
  } catch {}
}

function bumpUsage(name) {
  const usage = safeRead(USAGE, {});
  usage[name] = (usage[name] || 0) + 1;
  safeWrite(USAGE, usage);
  return usage[name];
}

function readUsage(name) {
  const usage = safeRead(USAGE, {});
  return usage[name] || 0;
}

function pushActivity(state, kind, name, ts) {
  state.activity_ring.push({ kind, name, ts });
  if (state.activity_ring.length > ACTIVE_SKILLS_LOOKBACK) state.activity_ring.shift();
}

function activeNames(state, kind) {
  const seen = new Set();
  for (const e of state.activity_ring) if (e.kind === kind) seen.add(e.name);
  return [...seen];
}

function errorFingerprint(toolResponse) {
  if (!toolResponse) return null;
  let text = "";
  if (typeof toolResponse === "string") text = toolResponse;
  else if (toolResponse.content !== undefined) {
    text = typeof toolResponse.content === "string"
      ? toolResponse.content
      : JSON.stringify(toolResponse.content);
  } else {
    try { text = JSON.stringify(toolResponse); } catch { return null; }
  }
  if (!text) return null;
  text = text.slice(0, 4000);
  const isError = toolResponse.is_error === true ||
    (toolResponse.is_error === undefined && ERROR_RE.test(text));
  if (!isError) return null;
  const m = text.match(ERROR_RE);
  const idx = m && typeof m.index === "number" ? m.index : 0;
  const start = Math.max(0, idx - 20);
  const slice = text.slice(start, start + 80).toLowerCase().replace(/\s+/g, " ").trim();
  if (!slice) return null;
  return djb2(slice);
}

function resetFrictionCounters(state) {
  state.tools_since_user = 0;
  state.dead_end_emitted = false;
  state.last_errors = [];
  state.edit_counts = {};
  state.edit_churn_emitted = {};
  state.build_failure_count = 0;
  state.build_loop_emitted = false;
}

function resetSessionLocal(state) {
  resetFrictionCounters(state);
  state.session_subagents = {};
  state.subagent_dispatch_emitted = {};
  state.correctionFreeCounter = 0;
  state.recoveryWatch = null;
  state.tool_window = [];
}

function ensureStateDefaults(state) {
  if (!Array.isArray(state.tool_window)) state.tool_window = [];
  if (typeof state.tools_since_user !== "number") state.tools_since_user = 0;
  if (typeof state.dead_end_emitted !== "boolean") state.dead_end_emitted = false;
  if (!Array.isArray(state.last_errors)) state.last_errors = [];
  if (!state.edit_counts || typeof state.edit_counts !== "object") state.edit_counts = {};
  if (!state.edit_churn_emitted || typeof state.edit_churn_emitted !== "object") state.edit_churn_emitted = {};
  if (typeof state.build_failure_count !== "number") state.build_failure_count = 0;
  if (typeof state.build_loop_emitted !== "boolean") state.build_loop_emitted = false;
  if (!state.session_subagents || typeof state.session_subagents !== "object") state.session_subagents = {};
  if (!state.subagent_dispatch_emitted || typeof state.subagent_dispatch_emitted !== "object") state.subagent_dispatch_emitted = {};
  if (typeof state.correctionFreeCounter !== "number") state.correctionFreeCounter = 0;
  if (state.recoveryWatch === undefined) state.recoveryWatch = null;
  if (!Array.isArray(state.activity_ring)) state.activity_ring = [];
}

function main() {
  const input = readStdin();
  if (!input || typeof input !== "object") return;

  const event = input.hook_event_name;
  const session = input.session_id || "unknown";
  const cwd = input.cwd || process.cwd();
  const ts = new Date().toISOString();
  const state = safeRead(STATE, { cursor: 0, tool_window: [] });
  ensureStateDefaults(state);

  if (state.session_id && state.session_id !== session) {
    resetSessionLocal(state);
  }
  state.session_id = session;

  if (event === "UserPromptSubmit") {
    const prompt = (input.prompt || "").slice(0, 200);
    if (CORRECTION_RE.test(prompt)) {
      const last = state.tool_window[state.tool_window.length - 1] || {};
      appendJournal({
        ts, session, cwd, type: "correction",
        phrase: prompt.slice(0, 80),
        prev_tool: last.tool || null,
        prev_file: last.file || null,
      });
      state.correctionFreeCounter = 0;
    } else {
      state.correctionFreeCounter += 1;
      if (state.correctionFreeCounter >= CORRECTION_FREE_THRESHOLD) {
        appendJournal({
          ts, session, cwd, type: "correction_free_streak",
          streak: state.correctionFreeCounter,
          active_skills: activeNames(state, "skill"),
          active_agents: activeNames(state, "agent"),
        });
        state.correctionFreeCounter = 0;
      }
    }
    resetFrictionCounters(state);
  } else if (event === "PreToolUse") {
    const tool = input.tool_name;
    if (tool === "Skill") {
      const name = (input.tool_input && (input.tool_input.skill || input.tool_input.skill_name)) || "unknown";
      bumpUsage(`skill:${name}`);
      pushActivity(state, "skill", name, ts);
    } else if (tool === "Agent") {
      const name = (input.tool_input && (input.tool_input.subagent_type || input.tool_input.agent)) || "unknown";
      bumpUsage(`agent:${name}`);
      pushActivity(state, "agent", name, ts);
      state.session_subagents[name] = (state.session_subagents[name] || 0) + 1;
      const cumulative = readUsage(`agent:${name}`);
      const sessionCount = state.session_subagents[name];
      const total = Math.max(cumulative, sessionCount);
      if (total >= SUBAGENT_DISPATCH_THRESHOLD && !state.subagent_dispatch_emitted[name]) {
        appendJournal({
          ts, session, cwd, type: "subagent_dispatch_pattern",
          subagent_type: name, session_count: sessionCount, cumulative
        });
        state.subagent_dispatch_emitted[name] = true;
      }
    }
  } else if (event === "PostToolUse") {
    const tool = input.tool_name || "unknown";
    const argsHash = djb2(JSON.stringify(input.tool_input || {}));
    const file = (input.tool_input && (input.tool_input.file_path || input.tool_input.path)) || null;

    let struggleEmittedThisTurn = null;
    const emit = (entry) => {
      if (STRUGGLE_TYPES.has(entry.type)) struggleEmittedThisTurn = entry.type;
      appendJournal(entry);
    };

    const windowEntry = { tool, argsHash, file };
    if (tool === "Agent") {
      const sub = (input.tool_input && (input.tool_input.subagent_type || input.tool_input.agent)) || "unknown";
      windowEntry.subagent = sub;
    }
    state.tool_window.push(windowEntry);
    if (state.tool_window.length > WINDOW_SIZE) state.tool_window.shift();

    const sameToolArgs = state.tool_window.filter(e => e.tool === tool && e.argsHash === argsHash).length;
    if (sameToolArgs >= RETRY_THRESHOLD) {
      emit({ ts, session, cwd, type: "retry_loop", tool, count: sameToolArgs });
    }

    if (tool === "Agent") {
      const subagent = (input.tool_input && (input.tool_input.subagent_type || input.tool_input.agent)) || "unknown";
      const recent = state.tool_window.slice(-5).filter(e => e.tool === "Agent" && e.subagent === subagent).length;
      if (recent >= AGENT_RESPAWN_THRESHOLD) {
        emit({ ts, session, cwd, type: "weak_agent", subagent_type: subagent, count: recent });
      }
    }

    if (input.tool_response && typeof input.tool_response === "object") {
      bumpUsage("payload:tool_response_seen");
    }

    const fp = errorFingerprint(input.tool_response);
    if (fp) {
      bumpUsage("payload:tool_response_error_seen");
      state.last_errors.push({ tool, fp });
      if (state.last_errors.length > ERROR_RING_SIZE) state.last_errors.shift();
      const sameError = state.last_errors.filter(e => e.fp === fp).length;
      if (sameError >= ERROR_LOOP_THRESHOLD) {
        emit({ ts, session, cwd, type: "tool_error_loop", tool, count: sameError, fp });
      }
    }

    if (file && EDIT_TOOLS.has(tool)) {
      state.edit_counts[file] = (state.edit_counts[file] || 0) + 1;
      if (state.edit_counts[file] >= EDIT_CHURN_THRESHOLD && !state.edit_churn_emitted[file]) {
        emit({ ts, session, cwd, type: "edit_churn", file, count: state.edit_counts[file] });
        state.edit_churn_emitted[file] = true;
      }
      const keys = Object.keys(state.edit_counts);
      if (keys.length > 20) {
        const oldest = keys[0];
        delete state.edit_counts[oldest];
        delete state.edit_churn_emitted[oldest];
      }
    }

    if (tool === "Bash") {
      const cmd = (input.tool_input && input.tool_input.command) || "";
      const isBuildCmd = BUILD_RE.test(cmd);
      const hasError = (input.tool_response && input.tool_response.is_error === true) || fp !== null;
      if (isBuildCmd && hasError) {
        state.build_failure_count += 1;
        if (state.build_failure_count >= BUILD_LOOP_THRESHOLD && !state.build_loop_emitted) {
          emit({ ts, session, cwd, type: "build_loop", count: state.build_failure_count, command: cmd.slice(0, 80) });
          state.build_loop_emitted = true;
        }
      }
    }

    state.tools_since_user += 1;
    if (state.tools_since_user >= DEAD_END_THRESHOLD && !state.dead_end_emitted) {
      emit({ ts, session, cwd, type: "dead_end", count: state.tools_since_user });
      state.dead_end_emitted = true;
    }

    if (struggleEmittedThisTurn) {
      state.recoveryWatch = { recovered_from: struggleEmittedThisTurn, since_ts: ts, clean_count: 0, window_tools: [] };
    } else if (state.recoveryWatch) {
      const turnHadError = fp !== null;
      if (turnHadError) {
        state.recoveryWatch = null;
      } else {
        state.recoveryWatch.clean_count += 1;
        state.recoveryWatch.window_tools.push(tool);
        if (state.recoveryWatch.window_tools.length > CLEAN_RECOVERY_WINDOW) state.recoveryWatch.window_tools.shift();
        if (state.recoveryWatch.clean_count >= CLEAN_RECOVERY_WINDOW) {
          appendJournal({
            ts, session, cwd, type: "clean_recovery",
            recovered_from: state.recoveryWatch.recovered_from,
            recovery_window_tools: state.recoveryWatch.window_tools.slice(),
            active_skills: activeNames(state, "skill"),
            active_agents: activeNames(state, "agent"),
          });
          state.recoveryWatch = null;
        }
      }
    }
  }

  safeWrite(STATE, state);
}

try { main(); } catch {}
process.exit(0);
