#!/usr/bin/env node
// Usage: adam-archive.mjs <proposal-path>
// Reads `source_entries` from proposal frontmatter, moves matching journal
// entries from journal.jsonl to journal/actioned-<id>.jsonl. Used by the
// adam-self-improvement skill after each apply/reject so subsequent /reflect
// runs do not re-cluster already-actioned signals.

import { readFileSync, writeFileSync, appendFileSync, mkdirSync, existsSync } from "node:fs";
import { join } from "node:path";
import { homedir } from "node:os";

const ROOT = join(homedir(), ".claude", "adam");
const JOURNAL = join(ROOT, "journal.jsonl");
const JOURNAL_DIR = join(ROOT, "journal");

function parseFrontmatter(content) {
  const m = content.match(/^---\n([\s\S]*?)\n---/);
  if (!m) return {};
  const fm = {};
  const lines = m[1].split("\n");
  let i = 0;
  while (i < lines.length) {
    const line = lines[i];
    const idx = line.indexOf(":");
    if (idx === -1) { i++; continue; }
    const key = line.slice(0, idx).trim();
    const value = line.slice(idx + 1).trim();
    if (key === "source_entries") {
      const arr = [];
      if (value.startsWith("[") && value.endsWith("]")) {
        const inner = value.slice(1, -1)
          .split(",")
          .map(s => s.trim().replace(/^['"]|['"]$/g, ""));
        arr.push(...inner.filter(Boolean));
        fm[key] = arr;
        i++;
        continue;
      }
      i++;
      while (i < lines.length && /^\s*-\s+/.test(lines[i])) {
        const item = lines[i].replace(/^\s*-\s+/, "").trim().replace(/^['"]|['"]$/g, "");
        if (item) arr.push(item);
        i++;
      }
      fm[key] = arr;
      continue;
    }
    fm[key] = value;
    i++;
  }
  return fm;
}

function main() {
  const proposalPath = process.argv[2];
  if (!proposalPath) {
    console.error("usage: adam-archive.mjs <proposal-path>");
    process.exit(2);
  }

  let proposal;
  try {
    proposal = readFileSync(proposalPath, "utf8");
  } catch (e) {
    console.error(`cannot read ${proposalPath}: ${e.message}`);
    process.exit(1);
  }

  const fm = parseFrontmatter(proposal);
  const id = fm.id || "unknown";
  const sourceEntries = Array.isArray(fm.source_entries) ? fm.source_entries : [];

  if (sourceEntries.length === 0) {
    console.log(`${id}: no source_entries in frontmatter — nothing to archive`);
    return;
  }

  if (!existsSync(JOURNAL)) {
    console.log(`${id}: journal does not exist at ${JOURNAL}`);
    return;
  }

  const lines = readFileSync(JOURNAL, "utf8").split("\n").filter(Boolean);
  const tsSet = new Set(sourceEntries);
  const matched = [];
  const remaining = [];

  for (const line of lines) {
    try {
      const e = JSON.parse(line);
      if (e.ts && tsSet.has(e.ts)) {
        matched.push(line);
      } else {
        remaining.push(line);
      }
    } catch {
      remaining.push(line);
    }
  }

  if (matched.length === 0) {
    console.log(`${id}: no matching entries in journal (already archived?)`);
    return;
  }

  mkdirSync(JOURNAL_DIR, { recursive: true });
  const archivePath = join(JOURNAL_DIR, `actioned-${id}.jsonl`);
  appendFileSync(archivePath, matched.join("\n") + "\n");
  writeFileSync(JOURNAL, remaining.length ? remaining.join("\n") + "\n" : "");

  console.log(`${id}: archived ${matched.length}/${lines.length} entries → ${archivePath}`);
}

try { main(); } catch (e) {
  console.error(`error: ${e.message}`);
  process.exit(1);
}
