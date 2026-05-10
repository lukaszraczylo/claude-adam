#!/usr/bin/env node
import { readdirSync } from "node:fs";
import { join } from "node:path";
import { homedir } from "node:os";

const PROPOSALS = join(homedir(), ".claude", "adam", "proposals");
const THRESHOLD = 3;

try {
  const PROPOSAL_RE = /^\d{4}-\d{2}-\d{2}-\d{3}-/;
  const files = readdirSync(PROPOSALS).filter(f => PROPOSAL_RE.test(f) && f.endsWith(".md"));
  if (files.length >= THRESHOLD) {
    process.stdout.write(`adam: ${files.length} proposals queued. Run /reflect to review.\n`);
  }
} catch {}
process.exit(0);
