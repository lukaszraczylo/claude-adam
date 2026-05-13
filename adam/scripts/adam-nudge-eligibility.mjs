#!/usr/bin/env node
// adam-nudge-eligibility.mjs — checks whether the current session has accrued
// enough `dead_end` entries to warrant emitting a cross-session nudge.
//
// CLI: adam-nudge-eligibility.mjs [--home <path>] [--session <id>]
//   --home    defaults to $HOME/.claude
//   --session if absent, reads state.json `session_id` field
//
// Output (stdout): JSON one-liner
//   eligible: {"eligible": true, "session_id": "...", "dead_end_count": N, "last_ts": "..."}
//   not:      {"eligible": false, "session_id": "...", "dead_end_count": N, "last_ts": "..."|null}
// Exit codes:
//   0 — read succeeded (eligible OR not)
//   1 — read failure / unable to resolve session
//
// Threshold: ≥3 dead_end entries within a single session_id across the active
// journal + all rotated journal/*.jsonl files. Threshold matches the
// "dead-end checkpoint" feedback rule.

import { readFileSync, existsSync } from "node:fs";
import { join } from "node:path";
import { homedir } from "node:os";
import { readJsonlSafe, listJsonlFiles } from "./adam-utils.mjs";

export const DEAD_END_THRESHOLD = 3;

function parseArgs(argv) {
  const args = { home: null, session: null, help: false };
  for (let i = 0; i < argv.length; i++) {
    const a = argv[i];
    if (a === "--home" && i + 1 < argv.length) args.home = argv[++i];
    else if (a === "--session" && i + 1 < argv.length) args.session = argv[++i];
    else if (a === "--help" || a === "-h") args.help = true;
  }
  return args;
}

function resolveSession(home, fallback) {
  if (fallback) return fallback;
  const statePath = join(home, "adam", "state.json");
  if (!existsSync(statePath)) return null;
  try {
    const st = JSON.parse(readFileSync(statePath, "utf8"));
    return st && typeof st.session_id === "string" ? st.session_id : null;
  } catch { return null; }
}

export function checkEligibility(home, sessionId) {
  const adamRoot = join(home, "adam");
  const sources = [
    join(adamRoot, "journal.jsonl"),
    ...listJsonlFiles(join(adamRoot, "journal")),
  ];
  let count = 0;
  let lastTs = null;
  for (const p of sources) {
    for (const e of readJsonlSafe(p)) {
      if (!e || e.type !== "dead_end") continue;
      if (e.session !== sessionId && e.session_id !== sessionId) continue;
      count++;
      const ts = typeof e.ts === "string" ? e.ts : null;
      if (ts && (!lastTs || ts > lastTs)) lastTs = ts;
    }
  }
  return {
    eligible: count >= DEAD_END_THRESHOLD,
    session_id: sessionId,
    dead_end_count: count,
    last_ts: lastTs,
  };
}

function main() {
  const args = parseArgs(process.argv.slice(2));
  if (args.help) {
    process.stdout.write("usage: adam-nudge-eligibility.mjs [--home <path>] [--session <id>]\n");
    process.exit(0);
  }
  const home = args.home || join(homedir(), ".claude");
  const sessionId = resolveSession(home, args.session);
  if (!sessionId) {
    process.stderr.write("adam-nudge-eligibility: no session_id (pass --session or seed state.json)\n");
    process.exit(1);
  }
  try {
    const result = checkEligibility(home, sessionId);
    process.stdout.write(JSON.stringify(result) + "\n");
    process.exit(0);
  } catch (e) {
    process.stderr.write(`adam-nudge-eligibility error: ${e.message}\n`);
    process.exit(1);
  }
}

if (import.meta.url === `file://${process.argv[1]}`) {
  main();
}
