#!/usr/bin/env node
// adam-window.mjs — per-signal sliding-window filter over the ADAM journal.
//
// Reads all journal sources (active journal.jsonl + rotated journal/*.jsonl,
// including both new YYYY-Www.jsonl format and legacy YYYY-MM-DD-<ts>.jsonl
// size-rotated files), applies a per-signal-type age cutoff based on each
// entry's `ts` field, and emits the filtered JSONL stream to stdout.
//
// Exclusion: entries whose `ts` appears in any applied/*.md or rejected/*.md
// proposal frontmatter `source_entries` array are dropped (same semantics the
// adam agent previously enforced manually). Keeps actioned signals out of the
// next /reflect even if they're inside the analysis window.
//
// Usage: adam-window.mjs [--home <path>]   default: $HOME/.claude
// Output: filtered JSONL on stdout. One-line summary on stderr.

import { readFileSync, readdirSync, existsSync, statSync } from "node:fs";
import { join } from "node:path";
import { homedir } from "node:os";
import { readJsonlSafe, listJsonlFiles } from "./adam-utils.mjs";

// Per-signal sliding window in days. Source of truth — referenced by agents/adam.md.
export const SIGNAL_WINDOWS_DAYS = {
  dead_end: 7,
  correction: 30,
  tool_error_loop: 30,
  edit_churn: 14,
  retry_loop: 14,
  build_loop: 30,
  weak_agent: 30,
  subagent_dispatch_pattern: 30,
  silent_drift: 14,
  error_after_recovery: 30,
  correction_free_streak: 60,
  clean_recovery: 60,
  task_completed: 60,
};

// Fallback window for unknown / future signal types.
export const DEFAULT_WINDOW_DAYS = 30;

const DAY_MS = 86400000;

function parseArgs(argv) {
  const args = { home: null };
  for (let i = 0; i < argv.length; i++) {
    if (argv[i] === "--home" && i + 1 < argv.length) {
      args.home = argv[++i];
    }
  }
  return args;
}

// Crude single-pass frontmatter source_entries extractor. Mirrors adam-archive.mjs
// parsing: handles both YAML block form and inline-array form. Only pulls the
// `source_entries` key — we don't need anything else for exclusion.
function extractSourceEntries(content) {
  const m = content.match(/^---\n([\s\S]*?)\n---/);
  if (!m) return [];
  const lines = m[1].split("\n");
  const out = [];
  for (let i = 0; i < lines.length; i++) {
    const line = lines[i];
    const idx = line.indexOf(":");
    if (idx === -1) continue;
    const key = line.slice(0, idx).trim();
    if (key !== "source_entries") continue;
    const value = line.slice(idx + 1).trim();
    if (value.startsWith("[") && value.endsWith("]")) {
      const inner = value.slice(1, -1).split(",")
        .map((s) => s.trim().replace(/^['"]|['"]$/g, ""))
        .filter(Boolean);
      out.push(...inner);
      continue;
    }
    let j = i + 1;
    while (j < lines.length && /^\s*-\s+/.test(lines[j])) {
      const item = lines[j].replace(/^\s*-\s+/, "").trim().replace(/^['"]|['"]$/g, "");
      if (item) out.push(item);
      j++;
    }
  }
  return out;
}

function buildExclusionSet(...dirs) {
  const set = new Set();
  for (const dir of dirs) {
    if (!existsSync(dir)) continue;
    let names;
    try { names = readdirSync(dir); } catch { continue; }
    for (const name of names) {
      if (!name.endsWith(".md")) continue;
      const p = join(dir, name);
      try {
        const content = readFileSync(p, "utf8");
        for (const ts of extractSourceEntries(content)) set.add(ts);
      } catch { /* skip */ }
    }
  }
  return set;
}

function windowDaysFor(type) {
  if (Object.prototype.hasOwnProperty.call(SIGNAL_WINDOWS_DAYS, type)) {
    return SIGNAL_WINDOWS_DAYS[type];
  }
  return DEFAULT_WINDOW_DAYS;
}

export function filterEntries(entries, exclusionSet, now = new Date()) {
  const nowMs = now.getTime();
  const dropped = { stale: {}, excluded: 0, no_ts: 0 };
  const kept = [];
  for (const e of entries) {
    if (!e || typeof e !== "object") continue;
    if (!e.ts || typeof e.ts !== "string") {
      dropped.no_ts++;
      continue;
    }
    if (exclusionSet.has(e.ts)) {
      dropped.excluded++;
      continue;
    }
    const type = e.type || "unknown";
    const days = windowDaysFor(type);
    const tsMs = Date.parse(e.ts);
    if (Number.isNaN(tsMs)) {
      dropped.no_ts++;
      continue;
    }
    if (nowMs - tsMs > days * DAY_MS) {
      dropped.stale[type] = (dropped.stale[type] || 0) + 1;
      continue;
    }
    kept.push(e);
  }
  return { kept, dropped };
}

function main() {
  const args = parseArgs(process.argv.slice(2));
  const claudeHome = args.home || join(homedir(), ".claude");
  const adamRoot = join(claudeHome, "adam");
  const activeJournal = join(adamRoot, "journal.jsonl");
  const journalDir = join(adamRoot, "journal");
  const appliedDir = join(adamRoot, "applied");
  const rejectedDir = join(adamRoot, "rejected");

  const sources = [activeJournal, ...listJsonlFiles(journalDir)];
  const all = [];
  for (const p of sources) {
    for (const e of readJsonlSafe(p)) all.push(e);
  }

  const exclusion = buildExclusionSet(appliedDir, rejectedDir);
  const { kept, dropped } = filterEntries(all, exclusion);

  // Stable output: sort by ts ascending so downstream clustering sees chronological order.
  kept.sort((a, b) => (a.ts < b.ts ? -1 : a.ts > b.ts ? 1 : 0));

  const out = kept.map((e) => JSON.stringify(e)).join("\n");
  if (out) process.stdout.write(out + "\n");

  const staleParts = Object.entries(dropped.stale).map(([t, n]) => `${t}=${n}`).join(",") || "none";
  process.stderr.write(
    `windowed: ${all.length} in, ${kept.length} out (stale: ${staleParts}; excluded: ${dropped.excluded}; no_ts: ${dropped.no_ts})\n`
  );
}

if (import.meta.url === `file://${process.argv[1]}`) {
  try { main(); } catch (e) {
    process.stderr.write(`adam-window error: ${e.message}\n`);
    process.exit(1);
  }
}
