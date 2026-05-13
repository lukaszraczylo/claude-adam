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
// Safety fuse only — primary rotation is weekly (ISO Monday 00:00 UTC).
// If active journal exceeds this even mid-week, force-rotate to avoid runaway growth.
// Override via $ADAM_MAX_JOURNAL_BYTES (used by tests).
const MAX_JOURNAL_BYTES = Number(process.env.ADAM_MAX_JOURNAL_BYTES) || 50 * 1024 * 1024;

// Strong-correction tokens: any single occurrence in a prompt is a correction.
// Weak tokens (no/actually/wait) require co-occurrence with a negation/contrast
// token within an 8-token window — see isCorrection() below.
const CORRECTION_RE = /\b(stop|don't|don\'t|wrong|nope|undo|revert|incorrect|nevermind|never\s+mind|disregard|redo)\b|that's\s+wrong|hold\s+on|wait\s+wait|try\s+again|different\s+approach|that's\s+not\s+what\s+i\s+meant|not\s+what\s+i\s+wanted|start\s+over|go\s+back/i;
const WEAK_CORRECTION_TOKENS = new Set(["no", "actually", "wait"]);
const NEGATION_RE = /^(not|wrong|but|isn't|isn\'t|didn't|didn\'t|aren't|aren\'t|won't|won\'t|shouldn't|shouldn\'t|don't|don\'t|nope|bad|broken|fail|fails|failed|failing)$/i;
const WEAK_WINDOW = 8;

function isCorrection(text) {
  if (!text || typeof text !== "string") return false;
  if (CORRECTION_RE.test(text)) return true;
  // Weak-token path: token must co-occur with a negation/contrast within WEAK_WINDOW tokens.
  const tokens = text.toLowerCase().split(/\s+/).map(t => t.replace(/^[^\w']+|[^\w']+$/g, "")).filter(Boolean);
  for (let i = 0; i < tokens.length; i++) {
    if (!WEAK_CORRECTION_TOKENS.has(tokens[i])) continue;
    const lo = Math.max(0, i - WEAK_WINDOW);
    const hi = Math.min(tokens.length - 1, i + WEAK_WINDOW);
    for (let j = lo; j <= hi; j++) {
      if (j === i) continue;
      if (NEGATION_RE.test(tokens[j])) return true;
    }
  }
  return false;
}

// Canonical error codes. Surface text → code mapping below.
const ERROR_CODES = new Set([
  "ENOENT", "ECONNREFUSED", "ETIMEDOUT", "EACCES", "EPERM", "EADDRINUSE",
  "ENOTFOUND", "EISDIR", "ENOTDIR", "EEXIST", "EMFILE", "EPIPE", "ECONNRESET"
]);
const ERROR_CODE_RE = /\b(ENOENT|ECONNREFUSED|ETIMEDOUT|EACCES|EPERM|EADDRINUSE|ENOTFOUND|EISDIR|ENOTDIR|EEXIST|EMFILE|EPIPE|ECONNRESET)\b/;
// Phrase → code mapping. First match wins; order matters.
const ERROR_PHRASE_MAP = [
  [/no such file or directory/i,    "ENOENT"],
  [/connection refused/i,           "ECONNREFUSED"],
  [/permission denied/i,            "EACCES"],
  [/address already in use/i,       "EADDRINUSE"],
  [/connection reset/i,             "ECONNRESET"],
  [/operation timed out/i,          "ETIMEDOUT"],
  [/name resolution|getaddrinfo/i,  "ENOTFOUND"],
];

function normalizeErrorText(text) {
  if (!text || typeof text !== "string") return "";
  let s = text;
  // ISO timestamps first (contain digits we'd otherwise strip individually).
  s = s.replace(/\d{4}-\d{2}-\d{2}T[\d:.Z+-]+/g, " ");
  // Windows paths.
  s = s.replace(/[A-Z]:\\[^\s]+/g, " ");
  // Absolute POSIX paths.
  s = s.replace(/\/[^\s:]+/g, " ");
  // Hex addresses.
  s = s.replace(/0x[0-9a-f]+/gi, " ");
  // Unix epoch (seconds or ms): 10-13 digit runs.
  s = s.replace(/\b\d{10,13}\b/g, " ");
  // Line/col refs.
  s = s.replace(/:\d+(?::\d+)?/g, " ");
  // UUIDs.
  s = s.replace(/\b[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\b/gi, " ");
  // Large integers (>6 digits) that survived above.
  s = s.replace(/\b\d{7,}\b/g, " ");
  // Lowercase + collapse whitespace.
  s = s.toLowerCase().replace(/\s+/g, " ").trim();
  return s.slice(0, 80);
}
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
const TASK_TOOL_MIN = 5;
const TASK_DIVERSITY_MIN = 3;
const STATE_MAX_BYTES = 1_000_000;

function safeRead(path, fallback) {
  try { return JSON.parse(readFileSync(path, "utf8")); } catch { return fallback; }
}

function safeWrite(path, obj) {
  try { writeFileSync(path, JSON.stringify(obj)); } catch {}
}

// ISO-8601 week: returns { year, week } for a Date (UTC).
// Week 1 = the week containing the first Thursday of the year (Monday-based weeks).
function isoWeek(date) {
  const d = new Date(Date.UTC(date.getUTCFullYear(), date.getUTCMonth(), date.getUTCDate()));
  // Shift to Thursday in current week (ISO week-numbering year tracks the Thursday).
  const day = d.getUTCDay() || 7; // 1..7, Mon=1..Sun=7
  d.setUTCDate(d.getUTCDate() + 4 - day);
  const isoYear = d.getUTCFullYear();
  const yearStart = new Date(Date.UTC(isoYear, 0, 1));
  const week = Math.ceil((((d - yearStart) / 86400000) + 1) / 7);
  return { year: isoYear, week };
}

function isoWeekTag(date) {
  const { year, week } = isoWeek(date);
  return `${year}-W${String(week).padStart(2, "0")}`;
}

function firstEntryTs(path) {
  try {
    const buf = readFileSync(path, "utf8");
    const nl = buf.indexOf("\n");
    const firstLine = nl === -1 ? buf : buf.slice(0, nl);
    if (!firstLine.trim()) return null;
    const obj = JSON.parse(firstLine);
    return obj && typeof obj.ts === "string" ? obj.ts : null;
  } catch { return null; }
}

// Weekly ISO rotation + size safety fuse.
// - If active journal's first entry is in a different ISO week than now, rotate to
//   journal/<that-entry's-iso-week>.jsonl and start fresh.
// - If active journal exceeds MAX_JOURNAL_BYTES, force-rotate even mid-week
//   using the current ISO week tag (suffixed with timestamp to avoid clobber).
function rotateIfNeeded(path) {
  try {
    if (!existsSync(path)) return;
    const size = statSync(path).size;
    if (size === 0) return;
    const now = new Date();
    const currentTag = isoWeekTag(now);
    const firstTs = firstEntryTs(path);
    let rotate = false;
    let destTag = null;
    if (firstTs) {
      const firstTag = isoWeekTag(new Date(firstTs));
      if (firstTag !== currentTag) {
        rotate = true;
        destTag = firstTag;
      }
    }
    if (!rotate && size > MAX_JOURNAL_BYTES) {
      rotate = true;
      destTag = `${currentTag}-${Date.now()}`; // safety-fuse: keep mid-week rotations unique
    }
    if (!rotate) return;
    mkdirSync(JOURNAL_DIR, { recursive: true });
    let dest = join(JOURNAL_DIR, `${destTag}.jsonl`);
    if (existsSync(dest)) {
      // Append-merge collision (rare: two mid-week safety-fuse rotations in same ms).
      dest = join(JOURNAL_DIR, `${destTag}-${Date.now()}.jsonl`);
    }
    renameSync(path, dest);
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
  rotateIfNeeded(JOURNAL);
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
  // ERROR_RE fallback covers tools that omit `is_error` entirely (text-only
  // responses, third-party tools). Explicit `is_error: false` is honored as-is
  // — the regex is NOT used to second-guess a tool that already declared success.
  const isError = toolResponse.is_error === true ||
    (toolResponse.is_error === undefined && ERROR_RE.test(text));
  if (!isError) return null;

  // 1. Try canonical code (literal token first, then phrase mapping).
  let code = null;
  const codeMatch = text.match(ERROR_CODE_RE);
  if (codeMatch && ERROR_CODES.has(codeMatch[1])) {
    code = codeMatch[1];
  } else {
    for (const [re, mapped] of ERROR_PHRASE_MAP) {
      if (re.test(text)) { code = mapped; break; }
    }
  }

  // 2. When canonical code matched, the bucket key IS the code — residual
  //    surface text (ports, hostnames, syscall names) varies across instances
  //    of the same root cause, so we hash a fixed sentinel for stability.
  //    When no code matched, normalize residual and hash it for the raw bucket.
  if (code) {
    return `${code}:${djb2(code)}`;
  }
  const normalized = normalizeErrorText(text);
  if (!normalized) return null;
  return `raw:${djb2(normalized)}`;
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
  state.task_tool_kinds = {};
  state.task_tool_count = 0;
  state.task_corrections = 0;
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
  if (!state.task_tool_kinds || typeof state.task_tool_kinds !== "object") state.task_tool_kinds = {};
  if (typeof state.task_tool_count !== "number") state.task_tool_count = 0;
  if (typeof state.task_corrections !== "number") state.task_corrections = 0;
}

function main() {
  const input = readStdin();
  if (!input || typeof input !== "object") return;

  // Weekly rotation check at hook entry — ensures the active journal rolls over
  // even if this invocation appends nothing.
  rotateIfNeeded(JOURNAL);

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
    if (isCorrection(prompt)) {
      const last = state.tool_window[state.tool_window.length - 1] || {};
      appendJournal({
        ts, session, cwd, type: "correction",
        phrase: prompt.slice(0, 80),
        prev_tool: last.tool || null,
        prev_file: last.file || null,
      });
      state.correctionFreeCounter = 0;
      state.task_corrections += 1;
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
    // Evaluate prior task (work between previous UserPromptSubmit and this one).
    const taskKinds = Object.keys(state.task_tool_kinds);
    if (state.task_tool_count >= TASK_TOOL_MIN &&
        taskKinds.length >= TASK_DIVERSITY_MIN &&
        state.task_corrections === 0) {
      appendJournal({
        ts, session, cwd, type: "task_completed",
        tool_count: state.task_tool_count,
        tool_kinds: taskKinds,
        active_skills: activeNames(state, "skill"),
        active_agents: activeNames(state, "agent"),
      });
    }
    state.task_tool_kinds = {};
    state.task_tool_count = 0;
    state.task_corrections = 0;
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

    state.task_tool_count += 1;
    state.task_tool_kinds[tool] = (state.task_tool_kinds[tool] || 0) + 1;

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

// Run main only when executed as a script, not when imported for tests.
// import.meta.url comparison is the standard ESM idiom.
const isMain = (() => {
  try {
    return import.meta.url === `file://${process.argv[1]}`;
  } catch { return true; }
})();
if (isMain) {
  try { main(); } catch {}
  process.exit(0);
}

export { errorFingerprint, normalizeErrorText, isCorrection };
