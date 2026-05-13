#!/usr/bin/env node
// adam-explain.mjs — render the analyst's clustering trace in summary / full / json modes.
//
// The adam agent ALWAYS emits a fenced ```trace block after its proposals. The
// adam-self-improvement skill persists the most recent trace to
// ~/.claude/adam/last-trace.txt. This tool parses and presents it.
//
// Trace line grammar (per agents/adam.md "Clustering trace (always emit)"):
//   <cluster_id> | signal=<type> count=<N> sessions=<M> | gates: threshold=<pass|fail:<reason>>, cross_session=<pass|fail>, window=<in:<N>/out:<M>>, contradiction=<none|vetoed:[[memory-name]]> | decision: <proposal_emitted:<type>|skipped:<reason>>
// Trailing summary line:
//   SUMMARY: considered=<N> emitted=<M> skipped=<N-M> reasons={threshold:X, contradiction:Y, window:Z, other:W}
//
// Usage: adam-explain.mjs [--input <path>] [--mode summary|full|json] [--home <path>]

import { readFileSync, existsSync } from "node:fs";
import { join } from "node:path";
import { homedir } from "node:os";

function parseArgs(argv) {
  const args = { input: null, mode: "summary", home: null };
  for (let i = 0; i < argv.length; i++) {
    const a = argv[i];
    if (a === "--input" && i + 1 < argv.length) args.input = argv[++i];
    else if (a === "--mode" && i + 1 < argv.length) args.mode = argv[++i];
    else if (a === "--home" && i + 1 < argv.length) args.home = argv[++i];
  }
  return args;
}

// Extract the inside of a ```trace ... ``` fenced block, or return the input
// verbatim if no fence is present (tolerant mode).
function extractFenced(text) {
  const m = text.match(/```trace\s*\n([\s\S]*?)\n```/);
  return m ? m[1] : text;
}

// Parse a single cluster line. Returns null when no recognisable structure.
function parseClusterLine(line) {
  // Three pipe-separated chunks: id | signal=… count=… sessions=… | gates: … | decision: …
  const parts = line.split("|").map((s) => s.trim());
  if (parts.length < 4) return null;
  const id = parts[0];
  if (!id) return null;
  const sigChunk = parts[1];
  const gatesChunk = parts[2];
  const decisionChunk = parts.slice(3).join("|").trim();

  const sigM = sigChunk.match(/signal=(\S+)\s+count=(\d+)\s+sessions=(\d+)/);
  if (!sigM) return null;
  const signal = sigM[1];
  const count = Number(sigM[2]);
  const sessions = Number(sigM[3]);

  if (!gatesChunk.startsWith("gates:")) return null;
  const gatesBody = gatesChunk.slice("gates:".length).trim();
  const gates = {};
  // gates body is a comma-separated list of key=value with possible commas inside values
  // we accept simple key=token,key=token,… — split on commas not inside [[ ]]
  const tokens = [];
  let depth = 0;
  let buf = "";
  for (const ch of gatesBody) {
    if (ch === "[") depth++;
    else if (ch === "]") depth--;
    if (ch === "," && depth === 0) { tokens.push(buf.trim()); buf = ""; }
    else buf += ch;
  }
  if (buf.trim()) tokens.push(buf.trim());
  for (const t of tokens) {
    const idx = t.indexOf("=");
    if (idx === -1) continue;
    gates[t.slice(0, idx).trim()] = t.slice(idx + 1).trim();
  }

  if (!decisionChunk.startsWith("decision:")) return null;
  const decision = decisionChunk.slice("decision:".length).trim();

  return { id, signal, count, sessions, gates, decision };
}

function parseSummaryLine(line) {
  // SUMMARY: considered=N emitted=M skipped=K [regressions=R] reasons={...}
  // `regressions` is optional (added in #5 — A/B measurement). Pre-existing
  // traces lacking the token still parse.
  const m = line.match(
    /^SUMMARY:\s*considered=(\d+)\s+emitted=(\d+)\s+skipped=(\d+)(?:\s+regressions=(\d+))?\s+reasons=\{([^}]*)\}\s*$/
  );
  if (!m) return null;
  const reasons = {};
  for (const piece of m[5].split(",")) {
    const kv = piece.trim();
    if (!kv) continue;
    const idx = kv.indexOf(":");
    if (idx === -1) continue;
    reasons[kv.slice(0, idx).trim()] = Number(kv.slice(idx + 1).trim()) || 0;
  }
  return {
    considered: Number(m[1]),
    emitted: Number(m[2]),
    skipped: Number(m[3]),
    regressions: m[4] != null ? Number(m[4]) : 0,
    reasons,
  };
}

export function parseTrace(text) {
  const body = extractFenced(text || "");
  const lines = body.split("\n").map((l) => l.replace(/\s+$/, "")).filter((l) => l.trim().length);
  const clusters = [];
  let summary = null;
  const warnings = [];
  for (const line of lines) {
    if (line.startsWith("SUMMARY:")) {
      const s = parseSummaryLine(line);
      if (s) summary = s;
      else warnings.push(`malformed summary line: ${line}`);
      continue;
    }
    const c = parseClusterLine(line);
    if (c) clusters.push(c);
    else warnings.push(`malformed cluster line: ${line}`);
  }
  // Synthesize a summary from clusters when none provided AND clusters parsed.
  if (!summary && clusters.length) {
    const reasons = { threshold: 0, contradiction: 0, window: 0, other: 0 };
    let emitted = 0;
    for (const c of clusters) {
      if (c.decision.startsWith("proposal_emitted")) emitted++;
      else {
        const r = (c.decision.match(/^skipped:(\S+)/) || [])[1] || "other";
        reasons[r in reasons ? r : "other"]++;
      }
    }
    summary = {
      considered: clusters.length,
      emitted,
      skipped: clusters.length - emitted,
      reasons,
    };
  }
  return { clusters, summary, warnings };
}

function countByDecision(clusters) {
  const counts = {};
  for (const c of clusters) {
    const key = c.decision.startsWith("proposal_emitted")
      ? "proposal_emitted"
      : (c.decision.match(/^skipped:(\S+)/)?.[1] || "other");
    counts[key] = (counts[key] || 0) + 1;
  }
  return counts;
}

export function formatSummary(parsed) {
  const s = parsed.summary;
  if (!s) return "no trace data";
  const reasonStr = Object.entries(s.reasons)
    .map(([k, v]) => `${k}:${v}`)
    .join(", ");
  const counts = countByDecision(parsed.clusters);
  const breakdown = Object.entries(counts)
    .map(([k, v]) => `${k}=${v}`)
    .join(" ");
  const head = `considered=${s.considered} emitted=${s.emitted} skipped=${s.skipped} reasons={${reasonStr}}`;
  return breakdown ? `${head}\nclusters by decision: ${breakdown}` : head;
}

export function formatFull(parsed) {
  const lines = [];
  for (const c of parsed.clusters) {
    const gatesStr = Object.entries(c.gates).map(([k, v]) => `${k}=${v}`).join(", ");
    lines.push(`${c.id} | signal=${c.signal} count=${c.count} sessions=${c.sessions} | gates: ${gatesStr} | decision: ${c.decision}`);
  }
  if (parsed.summary) {
    const s = parsed.summary;
    const reasonStr = Object.entries(s.reasons).map(([k, v]) => `${k}:${v}`).join(", ");
    lines.push(`SUMMARY: considered=${s.considered} emitted=${s.emitted} skipped=${s.skipped} regressions=${s.regressions ?? 0} reasons={${reasonStr}}`);
  }
  // Histogram footer: only count actual rejection reasons from clusters.
  const hist = {};
  for (const c of parsed.clusters) {
    const m = c.decision.match(/^skipped:(\S+)/);
    if (m) hist[m[1]] = (hist[m[1]] || 0) + 1;
  }
  const histStr = Object.entries(hist).map(([k, v]) => `${k} ${v}`).join(", ");
  lines.push(`Rejection reasons: ${histStr || "none"}`);
  return lines.join("\n");
}

export function formatJson(parsed) {
  return JSON.stringify({
    clusters: parsed.clusters,
    summary: parsed.summary,
  }, null, 2);
}

function main() {
  const args = parseArgs(process.argv.slice(2));
  const claudeHome = args.home || join(homedir(), ".claude");
  const defaultInput = join(claudeHome, "adam", "last-trace.txt");
  const inputPath = args.input || defaultInput;

  let raw;
  try {
    if (!existsSync(inputPath)) {
      process.stderr.write(`adam-explain: input not found: ${inputPath}\n`);
      process.exit(1);
    }
    raw = readFileSync(inputPath, "utf8");
  } catch (e) {
    process.stderr.write(`adam-explain: read failed: ${e.message}\n`);
    process.exit(1);
  }

  const parsed = parseTrace(raw);
  if (!parsed.clusters.length && !parsed.summary) {
    process.stderr.write(`adam-explain: no parseable trace lines in ${inputPath}\n`);
    process.exit(1);
  }
  for (const w of parsed.warnings) {
    process.stderr.write(`adam-explain: warn: ${w}\n`);
  }

  const mode = args.mode || "summary";
  let out;
  if (mode === "full") out = formatFull(parsed);
  else if (mode === "json") out = formatJson(parsed);
  else out = formatSummary(parsed);
  process.stdout.write(out + "\n");
}

if (import.meta.url === `file://${process.argv[1]}`) {
  try { main(); } catch (e) {
    process.stderr.write(`adam-explain error: ${e.message}\n`);
    process.exit(1);
  }
}
