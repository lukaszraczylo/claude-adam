// adam-utils.mjs — shared helpers used across adam-* scripts.
//
// Pure library: no shebang, not a CLI. Imported by adam-window.mjs,
// adam-score.mjs, adam-ab-measure.mjs, adam-nudge-eligibility.mjs (jsonl
// helpers) and adam-apply-reinforcement.mjs, adam-archive.mjs,
// adam-cooldown.mjs (parseFrontmatter).
//
// All helpers swallow read/parse failures by design — callers expect to keep
// going on a corrupt line/file rather than abort the whole pipeline.

import { readFileSync, readdirSync, existsSync } from "node:fs";
import { join } from "node:path";

// listJsonlFiles: list *.jsonl files in `dir`. Missing dir or read failure
// returns []. Filenames are joined with `dir` so callers can read directly.
export function listJsonlFiles(dir) {
  if (!existsSync(dir)) return [];
  try {
    return readdirSync(dir)
      .filter((n) => n.endsWith(".jsonl"))
      .map((n) => join(dir, n));
  } catch { return []; }
}

// readJsonlSafe: read a .jsonl file and return an array of parsed objects.
// Missing file, unreadable file, or any malformed line are silently skipped.
export function readJsonlSafe(path) {
  if (!existsSync(path)) return [];
  let buf;
  try { buf = readFileSync(path, "utf8"); } catch { return []; }
  const out = [];
  for (const line of buf.split("\n")) {
    if (!line) continue;
    try { out.push(JSON.parse(line)); } catch { /* skip malformed */ }
  }
  return out;
}

// parseFrontmatter: parse a markdown YAML-ish frontmatter block into a flat
// object. Supports:
//   - inline scalars         key: value
//   - inline arrays          key: [a, b, c]
//   - block-form arrays      key:\n  - a\n  - b
// Quotes around scalar values are stripped. Comment-only lines (`# ...`) and
// keys with empty inline values that are NOT followed by a block array are
// skipped (preserves prior cooldown.mjs behavior). Missing frontmatter → {}.
export function parseFrontmatter(content) {
  const m = content.match(/^---\n([\s\S]*?)\n---/);
  if (!m) return {};
  const out = {};
  const lines = m[1].split("\n");
  let i = 0;
  while (i < lines.length) {
    const line = lines[i];
    const idx = line.indexOf(":");
    if (idx === -1) { i++; continue; }
    const key = line.slice(0, idx).trim();
    if (!key || key.startsWith("#")) { i++; continue; }
    const rawValue = line.slice(idx + 1).trim();
    if (rawValue.startsWith("[") && rawValue.endsWith("]")) {
      const inner = rawValue.slice(1, -1)
        .split(",")
        .map((s) => s.trim().replace(/^['"]|['"]$/g, ""))
        .filter(Boolean);
      out[key] = inner;
      i++;
      continue;
    }
    if (!rawValue) {
      // Possible block-form array: look ahead for `  - item` lines.
      const arr = [];
      let j = i + 1;
      while (j < lines.length && /^\s*-\s+/.test(lines[j])) {
        const item = lines[j].replace(/^\s*-\s+/, "").trim().replace(/^['"]|['"]$/g, "");
        if (item) arr.push(item);
        j++;
      }
      if (arr.length) {
        out[key] = arr;
        i = j;
        continue;
      }
      // Empty value, no block follow-up: skip (cooldown/apply-reinforcement
      // expectation — empty scalars are noise).
      i++;
      continue;
    }
    out[key] = rawValue.replace(/^['"]|['"]$/g, "");
    i++;
  }
  return out;
}
