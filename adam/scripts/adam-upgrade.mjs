#!/usr/bin/env node
// adam-upgrade.mjs — review/accept pending `.adam-new` files from install.sh.
//
// install.sh writes <file>.adam-new next to user-modified ADAM files instead
// of clobbering. This tool surfaces those pending merges and lets users
// review the diff + accept atomically.
//
// CLI:
//   adam-upgrade.mjs --list [--home <path>]
//   adam-upgrade.mjs --diff [<path>] [--home <path>]
//   adam-upgrade.mjs --accept <path> [--home <path>]
//   adam-upgrade.mjs --accept-all [--home <path>]
//   adam-upgrade.mjs --help

import {
  readdirSync,
  statSync,
  existsSync,
  renameSync,
  readFileSync,
  unlinkSync,
} from "node:fs";
import { join, dirname, basename } from "node:path";
import { homedir } from "node:os";
import { spawnSync } from "node:child_process";

const EXCLUDE_DIRS = new Set([
  ".git",
  "node_modules",
  "journal",
  "trash",
  "proposals",
  "applied",
  "rejected",
]);

// Walk a directory tree, collecting paths to files ending in `.adam-new`.
// Excludes the dirs above defensively (no point in surfacing journal entries).
export function findPending(home) {
  const root = home;
  const out = [];
  function walk(dir) {
    let entries;
    try {
      entries = readdirSync(dir, { withFileTypes: true });
    } catch {
      return;
    }
    for (const e of entries) {
      const full = join(dir, e.name);
      if (e.isDirectory()) {
        if (EXCLUDE_DIRS.has(e.name)) continue;
        walk(full);
      } else if (e.isFile() && e.name.endsWith(".adam-new")) {
        out.push(full);
      }
    }
  }
  walk(root);
  return out.sort();
}

function fileSize(p) {
  try { return statSync(p).size; } catch { return 0; }
}

function fileAgeDays(p) {
  try {
    const mtime = statSync(p).mtimeMs;
    return Math.floor((Date.now() - mtime) / 86400000);
  } catch { return 0; }
}

// Produce a unified diff between two files. Prefer the system `diff -u` binary
// (universally available, accurate). On systems without `diff`, fall back to a
// naive line-by-line diff prefixed with MISSING:/NEW: so the tool still works.
export function diffPaths(orig, neu) {
  const r = spawnSync("diff", ["-u", orig, neu], { encoding: "utf8" });
  if (r.error || r.status === null || r.status === 2) {
    // diff binary missing or fatal error — naive fallback
    let a = [], b = [];
    try { a = readFileSync(orig, "utf8").split("\n"); } catch {}
    try { b = readFileSync(neu, "utf8").split("\n"); } catch {}
    const max = Math.max(a.length, b.length);
    const lines = [];
    for (let i = 0; i < max; i++) {
      const la = a[i], lb = b[i];
      if (la === lb) continue;
      if (la !== undefined) lines.push(`MISSING: ${la}`);
      if (lb !== undefined) lines.push(`NEW: ${lb}`);
    }
    return lines.join("\n");
  }
  return r.stdout || "";
}

// Atomic swap: rename orig → orig.adam-prev, rename neu → orig. Overwrites any
// prior .adam-prev backup (safe: a previous accept already promoted it).
export function acceptOne(orig, neu) {
  if (!existsSync(neu)) {
    throw new Error(`missing pending file: ${neu}`);
  }
  const prev = `${orig}.adam-prev`;
  if (existsSync(orig)) {
    if (existsSync(prev)) {
      try { unlinkSync(prev); } catch {}
    }
    renameSync(orig, prev);
  }
  renameSync(neu, orig);
  return { orig, prev };
}

export function acceptAll(home) {
  const pending = findPending(home);
  const results = [];
  for (const neu of pending) {
    const orig = neu.replace(/\.adam-new$/, "");
    try {
      const r = acceptOne(orig, neu);
      results.push({ ok: true, ...r });
    } catch (err) {
      results.push({ ok: false, orig, error: String(err && err.message || err) });
    }
  }
  return results;
}

function parseArgs(argv) {
  const args = { cmd: null, target: null, home: null };
  for (let i = 0; i < argv.length; i++) {
    const a = argv[i];
    if (a === "--list") args.cmd = "list";
    else if (a === "--diff") args.cmd = "diff";
    else if (a === "--accept") args.cmd = "accept";
    else if (a === "--accept-all") args.cmd = "accept-all";
    else if (a === "--help" || a === "-h") args.cmd = "help";
    else if (a === "--home" && i + 1 < argv.length) args.home = argv[++i];
    else if (!a.startsWith("--") && args.target == null) args.target = a;
  }
  return args;
}

function usage() {
  process.stdout.write(
    "adam-upgrade — review pending `.adam-new` files from install.sh\n" +
    "\n" +
    "Usage:\n" +
    "  adam-upgrade.mjs --list [--home <path>]\n" +
    "  adam-upgrade.mjs --diff [<path>] [--home <path>]\n" +
    "  adam-upgrade.mjs --accept <path> [--home <path>]\n" +
    "  adam-upgrade.mjs --accept-all [--home <path>]\n" +
    "  adam-upgrade.mjs --help\n"
  );
}

function resolveHome(args) {
  if (args.home) return args.home;
  return join(process.env.HOME || homedir(), ".claude");
}

function cmdList(args) {
  const home = resolveHome(args);
  const pending = findPending(home);
  for (const neu of pending) {
    const orig = neu.replace(/\.adam-new$/, "");
    const origSize = fileSize(orig);
    const newSize = fileSize(neu);
    const age = fileAgeDays(neu);
    process.stdout.write(`${neu}  (orig: ${origSize}, new: ${newSize}, age: ${age}d)\n`);
  }
  process.stderr.write(`${pending.length} pending\n`);
  return 0;
}

function cmdDiff(args) {
  const home = resolveHome(args);
  let targets;
  if (args.target) {
    // Allow either passing the orig path or the .adam-new path.
    const t = args.target;
    const orig = t.endsWith(".adam-new") ? t.replace(/\.adam-new$/, "") : t;
    targets = [orig];
  } else {
    targets = findPending(home).map((n) => n.replace(/\.adam-new$/, ""));
  }
  for (const orig of targets) {
    const neu = `${orig}.adam-new`;
    process.stdout.write(`=== ${orig} ===\n`);
    if (!existsSync(neu)) {
      process.stderr.write(`no pending: ${neu}\n`);
      continue;
    }
    process.stdout.write(diffPaths(orig, neu));
    process.stdout.write("\n");
  }
  return 0;
}

function cmdAccept(args) {
  if (!args.target) {
    process.stderr.write("error: --accept requires a <path>\n");
    return 1;
  }
  const t = args.target;
  const orig = t.endsWith(".adam-new") ? t.replace(/\.adam-new$/, "") : t;
  const neu = `${orig}.adam-new`;
  try {
    const r = acceptOne(orig, neu);
    process.stdout.write(`accepted: ${r.orig} (backup: ${r.prev})\n`);
    return 0;
  } catch (err) {
    process.stderr.write(`error: ${err.message}\n`);
    return 1;
  }
}

function cmdAcceptAll(args) {
  const home = resolveHome(args);
  const results = acceptAll(home);
  for (const r of results) {
    if (r.ok) {
      process.stdout.write(`accepted: ${r.orig} (backup: ${r.prev})\n`);
    } else {
      process.stderr.write(`error: ${r.orig}: ${r.error}\n`);
    }
  }
  return 0;
}

function main() {
  const args = parseArgs(process.argv.slice(2));
  if (!args.cmd || args.cmd === "help") { usage(); return 0; }
  if (args.cmd === "list") return cmdList(args);
  if (args.cmd === "diff") return cmdDiff(args);
  if (args.cmd === "accept") return cmdAccept(args);
  if (args.cmd === "accept-all") return cmdAcceptAll(args);
  usage();
  return 1;
}

// Only run main() when invoked as a script (not when imported for tests).
const invokedAsScript = (() => {
  try {
    const argv1 = process.argv[1] || "";
    return argv1.endsWith("adam-upgrade.mjs");
  } catch { return true; }
})();
if (invokedAsScript) {
  process.exit(main());
}
