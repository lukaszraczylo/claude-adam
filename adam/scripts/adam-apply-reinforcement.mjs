#!/usr/bin/env node
// adam-apply-reinforcement.mjs — apply-path for `reinforcement` proposals.
//
// Reads a proposal markdown file, validates the apply gate
// (confidence >= 4 AND blast_radius == "low" AND type == "reinforcement"),
// and on success appends one JSON line to ~/.claude/adam/reinforcements.jsonl
// of shape `{ts, skill_slug, count, source_session}`.
//
// CLI: adam-apply-reinforcement.mjs <proposal-path> [--home <path>]
// Output: JSON one-liner on stdout: {"status":"applied"|"gated", "reason":"..."}
// Exit: 0 on apply, 0 on gated, 1 on I/O or parse error.
//
// SKILL.md invokes this in the auto-apply path when the proposal type is
// `reinforcement`. No code/memory/skill modifications.

import { readFileSync, appendFileSync, existsSync, mkdirSync } from "node:fs";
import { join, dirname } from "node:path";
import { homedir } from "node:os";
import { parseFrontmatter } from "./adam-utils.mjs";

// Re-exported for backward compat — callers historically imported it from here.
export { parseFrontmatter };

function parseArgs(argv) {
  const args = { home: null, path: null, help: false };
  for (let i = 0; i < argv.length; i++) {
    const a = argv[i];
    if (a === "--home" && i + 1 < argv.length) args.home = argv[++i];
    else if (a === "--help" || a === "-h") args.help = true;
    else if (!args.path && !a.startsWith("--")) args.path = a;
  }
  return args;
}

export function checkGate(fm) {
  if ((fm.type || "") !== "reinforcement") {
    return { ok: false, reason: `type != reinforcement (got: ${fm.type || "<none>"})` };
  }
  const conf = Number(fm.confidence);
  if (Number.isNaN(conf) || conf < 4) {
    return { ok: false, reason: `confidence < 4 (got: ${fm.confidence ?? "<none>"})` };
  }
  if ((fm.blast_radius || "").toLowerCase() !== "low") {
    return { ok: false, reason: `blast_radius != low (got: ${fm.blast_radius || "<none>"})` };
  }
  if (!fm.skill_slug) {
    return { ok: false, reason: "skill_slug missing in frontmatter" };
  }
  return { ok: true };
}

export function buildEntry(fm, now = Date.now()) {
  return {
    ts: now,
    skill_slug: String(fm.skill_slug),
    count: Number(fm.count) || 0,
    source_session: fm.source_session || "",
  };
}

function main() {
  const args = parseArgs(process.argv.slice(2));
  if (args.help || !args.path) {
    process.stdout.write("usage: adam-apply-reinforcement.mjs <proposal-path> [--home <path>]\n");
    process.exit(args.help ? 0 : 1);
  }
  const claudeHome = args.home || join(homedir(), ".claude");
  const outPath = join(claudeHome, "adam", "reinforcements.jsonl");
  try {
    const content = readFileSync(args.path, "utf8");
    const fm = parseFrontmatter(content);
    const gate = checkGate(fm);
    if (!gate.ok) {
      process.stdout.write(JSON.stringify({ status: "gated", reason: gate.reason }) + "\n");
      process.exit(0);
    }
    const entry = buildEntry(fm);
    const dir = dirname(outPath);
    if (!existsSync(dir)) mkdirSync(dir, { recursive: true });
    appendFileSync(outPath, JSON.stringify(entry) + "\n");
    process.stdout.write(JSON.stringify({ status: "applied", path: outPath }) + "\n");
    process.exit(0);
  } catch (e) {
    process.stderr.write(`adam-apply-reinforcement error: ${e.message}\n`);
    process.exit(1);
  }
}

if (import.meta.url === `file://${process.argv[1]}`) {
  main();
}
