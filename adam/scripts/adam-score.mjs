#!/usr/bin/env node
// adam-score.mjs — computes per-session urgency dampeners + reinforcement
// candidates from `task_completed` signals.
//
// Effects:
//   1. Dampener:
//        task_completed_count >= 3 → 0.5
//        task_completed_count >= 1 → 0.75
//        else                     → 1.0
//      Analyst multiplies a cluster's urgency by the dampener of the session
//      it originated from.
//   2. Reinforcement candidates: per skill, count of clean task_completed
//      events citing it (via `active_skills` payload). Skills with count >= 3
//      are surfaced as reinforcement proposal candidates (low blast,
//      confidence ≥ 4 required for auto-apply, same gate as memory).
//
// CLI:
//   adam-score.mjs [--home <path>] [--input <jsonl-path>]
//
//   --input  defaults to: stdout of adam-window.mjs (preferred) — if missing,
//            falls back to the raw active journal.
//
// Output: JSON object
//   {
//     "sessions": [
//       {"session_id": "...", "negative_count": N, "task_completed_count": M, "dampener": 1.0}
//     ],
//     "reinforcement_candidates": [
//       {"skill_slug": "tdd-loop", "count": 3, "recent_ts": "..."}
//     ]
//   }

import { readFileSync } from "node:fs";
import { join } from "node:path";
import { homedir } from "node:os";
import { readJsonlSafe, listJsonlFiles } from "./adam-utils.mjs";

export const NEGATIVE_SIGNAL_TYPES = new Set([
  "correction",
  "tool_error_loop",
  "dead_end",
  "edit_churn",
  "retry_loop",
  "build_loop",
  "weak_agent",
]);

export const REINFORCEMENT_THRESHOLD = 3;

function parseArgs(argv) {
  const args = { home: null, input: null, help: false };
  for (let i = 0; i < argv.length; i++) {
    const a = argv[i];
    if (a === "--home" && i + 1 < argv.length) args.home = argv[++i];
    else if (a === "--input" && i + 1 < argv.length) args.input = argv[++i];
    else if (a === "--help" || a === "-h") args.help = true;
  }
  return args;
}

function readAllStdin() {
  try { return readFileSync(0, "utf8"); } catch { return ""; }
}

function entriesFromText(text) {
  const out = [];
  for (const line of (text || "").split("\n")) {
    if (!line) continue;
    try { out.push(JSON.parse(line)); } catch { /* skip */ }
  }
  return out;
}

function computeDampener(taskCompletedCount) {
  if (taskCompletedCount >= 3) return 0.5;
  if (taskCompletedCount >= 1) return 0.75;
  return 1.0;
}

export function computeSessionScores(entries) {
  const bySession = new Map();
  for (const e of entries || []) {
    if (!e || typeof e !== "object") continue;
    const sid = e.session || e.session_id || "";
    if (!sid) continue;
    if (!bySession.has(sid)) {
      bySession.set(sid, { session_id: sid, negative_count: 0, task_completed_count: 0 });
    }
    const slot = bySession.get(sid);
    if (e.type === "task_completed") slot.task_completed_count++;
    else if (NEGATIVE_SIGNAL_TYPES.has(e.type)) slot.negative_count++;
  }
  const out = [];
  for (const slot of bySession.values()) {
    out.push({
      ...slot,
      dampener: computeDampener(slot.task_completed_count),
    });
  }
  // Stable ordering by session_id for deterministic output.
  out.sort((a, b) => (a.session_id < b.session_id ? -1 : a.session_id > b.session_id ? 1 : 0));
  return out;
}

export function computeReinforcementCandidates(entries) {
  const counts = new Map();
  for (const e of entries || []) {
    if (!e || e.type !== "task_completed") continue;
    const skills = Array.isArray(e.active_skills) ? e.active_skills : [];
    for (const slug of skills) {
      if (!slug || typeof slug !== "string") continue;
      if (!counts.has(slug)) counts.set(slug, { count: 0, recent_ts: null });
      const slot = counts.get(slug);
      slot.count++;
      const ts = typeof e.ts === "string" ? e.ts : null;
      if (ts && (!slot.recent_ts || ts > slot.recent_ts)) slot.recent_ts = ts;
    }
  }
  const out = [];
  for (const [slug, { count, recent_ts }] of counts.entries()) {
    if (count < REINFORCEMENT_THRESHOLD) continue;
    out.push({ skill_slug: slug, count, recent_ts });
  }
  out.sort((a, b) => b.count - a.count || (a.skill_slug < b.skill_slug ? -1 : 1));
  return out;
}

function gatherInputEntries(args) {
  if (args.input) return readJsonlSafe(args.input);
  // Honor piped stdin only when it is non-empty AND not a TTY.
  if (!process.stdin.isTTY) {
    const piped = readAllStdin();
    if (piped && piped.trim()) return entriesFromText(piped);
  }
  // Default fallback: active journal + rotated files.
  const home = args.home || join(homedir(), ".claude");
  const adamRoot = join(home, "adam");
  const sources = [
    join(adamRoot, "journal.jsonl"),
    ...listJsonlFiles(join(adamRoot, "journal")),
  ];
  const all = [];
  for (const p of sources) {
    for (const e of readJsonlSafe(p)) all.push(e);
  }
  return all;
}

function main() {
  const args = parseArgs(process.argv.slice(2));
  if (args.help) {
    process.stdout.write("usage: adam-score.mjs [--home <path>] [--input <jsonl-path>]\n");
    process.exit(0);
  }
  try {
    const entries = gatherInputEntries(args);
    const sessions = computeSessionScores(entries);
    const reinforcement_candidates = computeReinforcementCandidates(entries);
    process.stdout.write(JSON.stringify({ sessions, reinforcement_candidates }) + "\n");
    process.exit(0);
  } catch (e) {
    process.stderr.write(`adam-score error: ${e.message}\n`);
    process.exit(1);
  }
}

if (import.meta.url === `file://${process.argv[1]}`) {
  main();
}
