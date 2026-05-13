#!/usr/bin/env node
// adam-nudge.mjs — SessionStart hook. Prints two kinds of reminders:
//   1. Pending proposals (≥3 queued in adam/proposals/).
//   2. Cross-session nudges (entries in adam/active-nudges.json whose
//      source_session differs from the current session and that haven't
//      expired or exhausted their max_displays).
import { readdirSync, readFileSync, writeFileSync, existsSync } from "node:fs";
import { join } from "node:path";
import { homedir } from "node:os";

const HOME = process.env.HOME || homedir();
const CLAUDE_ROOT = join(HOME, ".claude");
const ADAM_ROOT = join(CLAUDE_ROOT, "adam");
const PROPOSALS = join(ADAM_ROOT, "proposals");
const NUDGES_FILE = join(ADAM_ROOT, "active-nudges.json");
const STATE_FILE = join(ADAM_ROOT, "state.json");
const THRESHOLD = 3;

// Known installable paths (mirrors install.sh copy_file list). Checking a
// fixed shortlist keeps SessionStart latency under control vs full FS walk.
const PENDING_CHECK_PATHS = [
  "hooks/adam-observe.mjs",
  "hooks/adam-nudge.mjs",
  "agents/adam.md",
  "skills/adam-self-improvement/SKILL.md",
  "commands/reflect.md",
  "adam/scripts/adam-archive.mjs",
  "adam/scripts/adam-upgrade.mjs",
  "adam/scripts/adam-window.mjs",
  "adam/scripts/adam-explain.mjs",
  "adam/scripts/adam-nudge-eligibility.mjs",
  "adam/scripts/adam-cooldown.mjs",
  "adam/scripts/adam-score.mjs",
  "adam/scripts/adam-ab-measure.mjs",
  "adam/scripts/adam-apply-reinforcement.mjs",
  "adam/tests/run-tests.sh",
];

function readJson(path, fallback) {
  if (!existsSync(path)) return fallback;
  try { return JSON.parse(readFileSync(path, "utf8")); } catch { return fallback; }
}

function readSessionInput() {
  // SessionStart payload arrives on stdin; capture session_id if present.
  // We don't block on stdin — best-effort, non-blocking.
  try {
    const buf = readFileSync(0, "utf8");
    if (!buf) return null;
    const parsed = JSON.parse(buf);
    return parsed && typeof parsed.session_id === "string" ? parsed.session_id : null;
  } catch { return null; }
}

function emitProposalReminder() {
  try {
    const PROPOSAL_RE = /^\d{4}-\d{2}-\d{2}-\d{3}-/;
    const files = readdirSync(PROPOSALS).filter((f) => PROPOSAL_RE.test(f) && f.endsWith(".md"));
    if (files.length >= THRESHOLD) {
      process.stdout.write(`adam: ${files.length} proposals queued. Run /reflect to review.\n`);
    }
  } catch { /* proposals dir absent → silent */ }
}

function emitActiveNudges(currentSession) {
  if (!existsSync(NUDGES_FILE)) return;
  const raw = readJson(NUDGES_FILE, null);
  if (!Array.isArray(raw)) return;
  const now = Date.now();
  const kept = [];
  let mutated = false;
  for (const entry of raw) {
    if (!entry || typeof entry !== "object") { mutated = true; continue; }
    const expires = Number(entry.expires_at_ts || 0);
    if (!expires || expires <= now) { mutated = true; continue; }
    const sourceSession = entry.source_session || "";
    const max = Number(entry.max_displays || 0);
    const used = Number(entry.displays_used || 0);
    if (max > 0 && used >= max) { mutated = true; continue; }
    // Cross-session gate: only print when current session differs.
    if (sourceSession && currentSession && sourceSession === currentSession) {
      kept.push(entry);
      continue;
    }
    if (typeof entry.message === "string" && entry.message) {
      process.stdout.write(entry.message + "\n");
      const nextUsed = used + 1;
      mutated = true;
      if (max > 0 && nextUsed >= max) continue; // drop after exhaustion
      kept.push({ ...entry, displays_used: nextUsed });
    } else {
      kept.push(entry);
    }
  }
  if (mutated) {
    try { writeFileSync(NUDGES_FILE, JSON.stringify(kept, null, 2)); } catch { /* swallow */ }
  }
}

function emitPendingUpgrades() {
  // Cheap: stat a fixed shortlist of `.adam-new` candidates. Non-fatal.
  try {
    let count = 0;
    for (const rel of PENDING_CHECK_PATHS) {
      const p = join(CLAUDE_ROOT, `${rel}.adam-new`);
      try {
        if (existsSync(p)) count++;
      } catch { /* per-path swallow */ }
    }
    if (count > 0) {
      process.stdout.write(
        `[adam] ${count} pending upgrade(s). Review: node ~/.claude/adam/scripts/adam-upgrade.mjs --list\n`
      );
    }
  } catch { /* never break SessionStart */ }
}

function main() {
  const stdinSession = readSessionInput();
  const stateSession = (() => {
    const st = readJson(STATE_FILE, null);
    return st && typeof st.session_id === "string" ? st.session_id : null;
  })();
  const currentSession = stdinSession || stateSession || "";
  emitProposalReminder();
  emitActiveNudges(currentSession);
  emitPendingUpgrades();
}

try { main(); } catch { /* never block SessionStart */ }
process.exit(0);
