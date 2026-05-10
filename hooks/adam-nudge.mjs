#!/usr/bin/env node
import { readdirSync } from "node:fs";
import { join } from "node:path";
import { homedir } from "node:os";

const PROPOSALS = join(homedir(), ".claude", "adam", "proposals");
const THRESHOLD = 3;

try {
  const files = readdirSync(PROPOSALS).filter(f => f.endsWith(".md"));
  if (files.length >= THRESHOLD) {
    process.stdout.write(`adam: ${files.length} proposals queued. Run /reflect to review.\n`);
  }
} catch {}
process.exit(0);
