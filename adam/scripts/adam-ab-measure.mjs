#!/usr/bin/env node
// adam-ab-measure.mjs — A/B effectiveness measurement on auto-applied edits.
//
// Reads ~/.claude/adam/ab-tracking.jsonl (one line per auto-apply event,
// written by adam-self-improvement/SKILL.md), then for each entry old enough
// (>= --min-age-days; default 7) compares signal counts in the 7-day window
// BEFORE applied_at against the 7-day window AFTER applied_at across the
// full journal corpus (active + rotated). Surfaces regressions so /reflect
// can flag proposals that made things worse.
//
// CLI:
//   adam-ab-measure.mjs [--home <path>] [--format json|table] [--min-age-days N]
//
// Output (default `table`): aligned columns sorted regressed-first.
// Output (`json`): array of deltas.
// Empty / missing tracking file → empty output, exit 0.
// Exit 1 only on I/O failure.

import { join } from "node:path";
import { homedir } from "node:os";
import { readJsonlSafe, listJsonlFiles } from "./adam-utils.mjs";

const DAY_MS = 86400000;
export const DEFAULT_PRE_WINDOW_DAYS = 7;
export const DEFAULT_MIN_AGE_DAYS = 7;

const REGRESSED_PCT = 25;
const IMPROVED_PCT = -25;

function parseArgs(argv) {
  const args = { home: null, format: "table", minAgeDays: DEFAULT_MIN_AGE_DAYS, help: false };
  for (let i = 0; i < argv.length; i++) {
    const a = argv[i];
    if (a === "--home" && i + 1 < argv.length) args.home = argv[++i];
    else if (a === "--format" && i + 1 < argv.length) args.format = argv[++i];
    else if (a === "--min-age-days" && i + 1 < argv.length) {
      const n = Number(argv[++i]);
      if (!Number.isNaN(n) && n >= 0) args.minAgeDays = n;
    }
    else if (a === "--help" || a === "-h") args.help = true;
  }
  return args;
}

function loadJournalAll(claudeHome) {
  const adamRoot = join(claudeHome, "adam");
  const sources = [join(adamRoot, "journal.jsonl"), ...listJsonlFiles(join(adamRoot, "journal"))];
  const all = [];
  for (const p of sources) for (const e of readJsonlSafe(p)) all.push(e);
  return all;
}

function tsMs(e) {
  if (!e || typeof e.ts !== "string") return NaN;
  return Date.parse(e.ts);
}

// computeDeltas: pure function — entries = ab-tracking objects, journal = list
// of journal entries (any source). opts.now is unix ms; opts.minAgeDays is the
// floor for non-pending.
export function computeDeltas(entries, journal, opts = {}) {
  const now = typeof opts.now === "number" ? opts.now : Date.now();
  const minAgeDays = typeof opts.minAgeDays === "number" ? opts.minAgeDays : DEFAULT_MIN_AGE_DAYS;
  const out = [];
  for (const e of entries || []) {
    if (!e || typeof e !== "object") continue;
    const appliedAt = Number(e.applied_at);
    if (!appliedAt || Number.isNaN(appliedAt)) continue;
    const ageDays = (now - appliedAt) / DAY_MS;
    // Symmetric window: same span applied to pre AND post sides. JSONL schema
    // field stays `pre_window_days` for backward compat with existing
    // ab-tracking.jsonl entries — local name reflects symmetry.
    const windowDays = typeof e.pre_window_days === "number" ? e.pre_window_days : DEFAULT_PRE_WINDOW_DAYS;
    const signals = Array.isArray(e.originating_signals)
      ? e.originating_signals.map((s) => (s && typeof s === "object" ? s.type : null)).filter(Boolean)
      : [];
    const sigSet = new Set(signals);

    const base = {
      proposal_id: e.proposal_id || "",
      proposal_type: e.proposal_type || "",
      target_skill: e.target_skill || "",
      applied_at: appliedAt,
      applied_at_iso: new Date(appliedAt).toISOString(),
      signal_types: [...sigSet],
    };

    if (ageDays < minAgeDays) {
      out.push({ ...base, pre_count: null, post_count: null, delta_pct: null, status: "pending" });
      continue;
    }

    const preStart = appliedAt - windowDays * DAY_MS;
    const postEnd = appliedAt + windowDays * DAY_MS;
    let preCount = 0;
    let postCount = 0;
    for (const je of journal || []) {
      if (!je || typeof je !== "object") continue;
      if (!sigSet.has(je.type)) continue;
      const t = tsMs(je);
      if (Number.isNaN(t)) continue;
      if (t >= preStart && t < appliedAt) preCount++;
      else if (t >= appliedAt && t < postEnd) postCount++;
    }

    let status;
    let deltaPct;
    if (preCount === 0) {
      status = "no_baseline";
      deltaPct = null;
    } else {
      deltaPct = ((postCount - preCount) / preCount) * 100;
      // Round to 2 dp for stable comparison + presentation.
      deltaPct = Math.round(deltaPct * 100) / 100;
      if (deltaPct <= IMPROVED_PCT) status = "improved";
      else if (deltaPct >= REGRESSED_PCT) status = "regressed";
      else status = "neutral";
    }
    out.push({ ...base, pre_count: preCount, post_count: postCount, delta_pct: deltaPct, status });
  }
  return out;
}

const STATUS_ORDER = { regressed: 0, neutral: 1, no_baseline: 2, improved: 3, pending: 4 };

function sortForTable(deltas) {
  return [...deltas].sort((a, b) => {
    const sa = STATUS_ORDER[a.status] ?? 99;
    const sb = STATUS_ORDER[b.status] ?? 99;
    if (sa !== sb) return sa - sb;
    return a.applied_at - b.applied_at;
  });
}

function padRight(s, n) { s = String(s); return s.length >= n ? s : s + " ".repeat(n - s.length); }

export function formatTable(deltas) {
  if (!deltas || !deltas.length) return "";
  const rows = sortForTable(deltas);
  const headers = ["proposal_id", "target", "type", "applied_at(iso)", "pre/post", "delta%", "status"];
  const data = rows.map((d) => [
    d.proposal_id || "-",
    d.target_skill || "-",
    d.proposal_type || "-",
    d.applied_at_iso || "-",
    d.pre_count == null ? "-" : `${d.pre_count}/${d.post_count}`,
    d.delta_pct == null ? "-" : `${d.delta_pct.toFixed(2)}`,
    d.status || "-",
  ]);
  const widths = headers.map((h, i) => Math.max(h.length, ...data.map((r) => String(r[i]).length)));
  const lines = [];
  lines.push(headers.map((h, i) => padRight(h, widths[i])).join(" | "));
  lines.push(widths.map((w) => "-".repeat(w)).join("-+-"));
  for (const r of data) lines.push(r.map((c, i) => padRight(c, widths[i])).join(" | "));
  return lines.join("\n");
}

export function formatJson(deltas) {
  return JSON.stringify(deltas || []);
}

function main() {
  const args = parseArgs(process.argv.slice(2));
  if (args.help) {
    process.stdout.write("usage: adam-ab-measure.mjs [--home <path>] [--format json|table] [--min-age-days N]\n");
    process.exit(0);
  }
  const claudeHome = args.home || join(homedir(), ".claude");
  const trackingPath = join(claudeHome, "adam", "ab-tracking.jsonl");
  try {
    const entries = readJsonlSafe(trackingPath);
    if (!entries.length) {
      if (args.format === "json") process.stdout.write("[]\n");
      // table mode prints nothing on empty input — exit 0.
      process.exit(0);
    }
    const journal = loadJournalAll(claudeHome);
    const deltas = computeDeltas(entries, journal, { minAgeDays: args.minAgeDays });
    const out = args.format === "json" ? formatJson(deltas) : formatTable(deltas);
    if (out) process.stdout.write(out + "\n");
    process.exit(0);
  } catch (e) {
    process.stderr.write(`adam-ab-measure error: ${e.message}\n`);
    process.exit(1);
  }
}

if (import.meta.url === `file://${process.argv[1]}`) {
  main();
}
