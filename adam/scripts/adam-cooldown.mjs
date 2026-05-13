#!/usr/bin/env node
// adam-cooldown.mjs — per-(skill, proposal_fingerprint) cooldown / blacklist
// gate. Replaces the previous coarse per-skill cooldown.
//
// CLI:
//   adam-cooldown.mjs --skill <slug> --fingerprint <hash> [--home <path>]
//
// Output: JSON one-liner with shape
//   { "status": "cool"|"cooldown"|"blacklisted",
//     "reason": "<human-readable reason>",
//     "blocked_by": { "file": "<basename>", "days_remaining": <int> } | null }
//
// Rules:
//   - applied/*.md with target_skill == <skill> AND
//     (proposal_fingerprint == <fingerprint> OR missing/legacy)
//     within 7 days of `applied_at` → "cooldown"
//   - rejected/*.md with same skill match AND
//     auto_apply_blacklist: true within 30 days of applied_at → "blacklisted"
//   - else "cool"
//
// Backward compat: proposals without `proposal_fingerprint` field are treated
// as fingerprint == "legacy" so historical applied/rejected records still
// produce coarse-grained gating until they age out of their windows.

import { readFileSync, readdirSync, existsSync, statSync } from "node:fs";
import { join } from "node:path";
import { homedir } from "node:os";
import { parseFrontmatter } from "./adam-utils.mjs";

export const COOLDOWN_DAYS = 7;
export const BLACKLIST_DAYS = 30;
const DAY_MS = 86400000;
export const LEGACY_FINGERPRINT = "legacy";

function parseArgs(argv) {
  const args = { home: null, skill: null, fingerprint: null, help: false };
  for (let i = 0; i < argv.length; i++) {
    const a = argv[i];
    if (a === "--home" && i + 1 < argv.length) args.home = argv[++i];
    else if (a === "--skill" && i + 1 < argv.length) args.skill = argv[++i];
    else if (a === "--fingerprint" && i + 1 < argv.length) args.fingerprint = argv[++i];
    else if (a === "--help" || a === "-h") args.help = true;
  }
  return args;
}

// Pull applied_at as epoch ms. Accept ms-number, ISO string, or fall back to
// the file's mtime so we never crash on legacy records.
function frontmatterTimestampMs(fm, filePath) {
  const raw = fm.applied_at;
  if (raw) {
    const asNum = Number(raw);
    if (!Number.isNaN(asNum) && asNum > 0) return asNum;
    const asIso = Date.parse(raw);
    if (!Number.isNaN(asIso)) return asIso;
  }
  try { return statSync(filePath).mtimeMs; } catch { return 0; }
}

function fingerprintMatches(recordFp, queryFp) {
  // Missing / empty field on legacy records → coarse fallback: any fingerprint
  // query matches (so the historical applied/rejected record still gates).
  if (!recordFp || recordFp === LEGACY_FINGERPRINT) return true;
  return recordFp === queryFp;
}
// Resolve a frontmatter record to its skill slug. Modern records use
// `target_skill`; legacy v0.2.x records used `target` with a full path
// (e.g. `skills/foo/SKILL.md`). Falls back through both before giving up.
function resolveSkill(fm) {
  if (fm.target_skill) return fm.target_skill;
  if (fm.skill) return fm.skill;
  if (fm.target) {
    const base = fm.target.split("/").filter(Boolean);
    // skills/<slug>/SKILL.md → <slug>; <slug>.md → <slug>; else last segment
    if (base.length >= 2 && base[base.length - 1] === "SKILL.md") {
      return base[base.length - 2];
    }
    return base[base.length - 1].replace(/\.md$/, "");
  }
  return "";
}

function scanDir(dir, predicate) {
  if (!existsSync(dir)) return [];
  let names;
  try { names = readdirSync(dir); } catch { return []; }
  const out = [];
  for (const name of names) {
    if (!name.endsWith(".md")) continue;
    const p = join(dir, name);
    let content;
    try { content = readFileSync(p, "utf8"); } catch { continue; }
    const fm = parseFrontmatter(content);
    const hit = predicate(fm, p, name);
    if (hit) out.push(hit);
  }
  return out;
}

export function checkCooldown(home, skill, fingerprint, now = Date.now()) {
  const adamRoot = join(home, "adam");
  const appliedDir = join(adamRoot, "applied");
  const rejectedDir = join(adamRoot, "rejected");

  // Applied → cooldown
  const appliedHits = scanDir(appliedDir, (fm, p, name) => {
    if (resolveSkill(fm) !== skill) return null;
    if (!fingerprintMatches(fm.proposal_fingerprint, fingerprint)) return null;
    const tsMs = frontmatterTimestampMs(fm, p);
    if (!tsMs) return null;
    const ageDays = (now - tsMs) / DAY_MS;
    if (ageDays > COOLDOWN_DAYS) return null;
    return { name, daysRemaining: Math.max(0, Math.ceil(COOLDOWN_DAYS - ageDays)) };
  });

  // Rejected → blacklisted (requires auto_apply_blacklist: true)
  const blacklistHits = scanDir(rejectedDir, (fm, p, name) => {
    if (resolveSkill(fm) !== skill) return null;
    if (!fingerprintMatches(fm.proposal_fingerprint, fingerprint)) return null;
    const flag = (fm.auto_apply_blacklist || "").toLowerCase();
    if (flag !== "true") return null;
    const tsMs = frontmatterTimestampMs(fm, p);
    if (!tsMs) return null;
    const ageDays = (now - tsMs) / DAY_MS;
    if (ageDays > BLACKLIST_DAYS) return null;
    return { name, daysRemaining: Math.max(0, Math.ceil(BLACKLIST_DAYS - ageDays)) };
  });

  if (blacklistHits.length) {
    const h = blacklistHits[0];
    return {
      status: "blacklisted",
      reason: `auto_apply_blacklist active on rejected/${h.name}`,
      blocked_by: { file: h.name, days_remaining: h.daysRemaining },
    };
  }
  if (appliedHits.length) {
    const h = appliedHits[0];
    return {
      status: "cooldown",
      reason: `applied within ${COOLDOWN_DAYS}d (applied/${h.name})`,
      blocked_by: { file: h.name, days_remaining: h.daysRemaining },
    };
  }
  return { status: "cool", reason: "no recent applied/rejected match", blocked_by: null };
}

// djb2 hash returned as base36 — deterministic, no deps.
function djb2(s) {
  let h = 5381;
  for (let i = 0; i < s.length; i++) {
    h = (((h << 5) + h) ^ s.charCodeAt(i)) >>> 0; // xor variant, force u32
  }
  return h.toString(36);
}

export function computeProposalFingerprint(proposal) {
  if (!proposal || typeof proposal !== "object") return LEGACY_FINGERPRINT;
  const skill = proposal.skill_slug || proposal.target_skill || proposal.skill || "";
  const cluster = proposal.signal_cluster_id || proposal.cluster_id || "";
  const diff = String(proposal.diff_body || proposal.proposed_change || "")
    .replace(/\s+/g, " ")
    .replace(/\n+$/g, "")
    .trim();
  return djb2(`${skill}\n${cluster}\n${diff}`);
}

function main() {
  const args = parseArgs(process.argv.slice(2));
  if (args.help) {
    process.stdout.write("usage: adam-cooldown.mjs --skill <slug> --fingerprint <hash> [--home <path>]\n");
    process.exit(0);
  }
  if (!args.skill || !args.fingerprint) {
    process.stderr.write("adam-cooldown: --skill and --fingerprint required\n");
    process.exit(1);
  }
  const home = args.home || join(homedir(), ".claude");
  try {
    const result = checkCooldown(home, args.skill, args.fingerprint);
    process.stdout.write(JSON.stringify(result) + "\n");
    process.exit(0);
  } catch (e) {
    process.stderr.write(`adam-cooldown error: ${e.message}\n`);
    process.exit(1);
  }
}

if (import.meta.url === `file://${process.argv[1]}`) {
  main();
}
