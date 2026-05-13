# claude-adam

Self-improvement layer for [Claude Code](https://claude.com/claude-code) that observes friction signals during your sessions and proposes targeted improvements (new skills, memory entries, agent edits) which you can review and apply.

## What's new

- **v0.3.3** — analyst observability, A/B measurement, journal hygiene. Storage/window/exclusion split: ISO-week journal rotation with safety fuse (replaces size-based, fixes silent under-counting); per-signal sliding windows via new `adam-window.mjs` (`dead_end` 7d, `correction` 30d, reinforcement signals 60d). Error fingerprint normalization — `ECONNREFUSED` and `"Connection refused"` cluster identically. Correction corpus expanded (`wait`, `hold on`, `try again`, `different approach`); weak tokens (`no`, `actually`, `wait`) require negation co-occurrence within 8 tokens to fire — kills the `"actually, I think..."` false positive. Mandatory clustering trace + new `adam-explain.mjs --mode summary|full|json`. New `nudge` proposal type (single-session auto-apply, low blast) for repeated `dead_end`. Per-(skill, fingerprint) cooldown via `adam-cooldown.mjs` (replaces coarse per-skill gate). `task_completed` scoring: urgency dampener + reinforcement candidates. A/B effectiveness measurement on auto-applied edits (`adam-ab-measure.mjs`, 7d pre/post window). Upgrade UX overhaul: `adam-upgrade.mjs --list/--diff/--accept` + SessionStart pending-merge warning. Shared helper module `adam-utils.mjs` deduplicates journal-reading and frontmatter parsing across scripts. 87 tests (up from 30).
- **v0.3.2** — `task_completed` signal: post-task skill capture for downstream reinforcement scoring (consumed in v0.3.3).
- **v0.3.1** — code review pass: bug fixes (`errorFingerprint` no longer false-positives on `is_error: false`, archive script handles same-millisecond duplicates correctly, `tool_window` now clears on session change, nudge filters proposal filenames by pattern), prose conciseness cuts, hardened `install.sh` with curl one-liner + settings.json merge, `adam-uninstall.sh`, isolated test harness (no longer pollutes live `~/.claude/adam/` state).
- **v0.3.0** — causal diagnosis: every proposal carries a `# Diagnosis` block (Trigger/Action/Mismatch/Outcome with verbatim transcript quote) before drafting, plus optional `contradiction_flag` heuristic that vetoes auto-apply on obviously-conflicting `skill_edit` additions.
- **v0.2.1** — win signals (`correction_free_streak`, `clean_recovery`) feed `skill_edit` auto-apply under a strict gate (≤30 LOC, ≤2× byte cap, 7d cooldown, 30d blacklist on rejection).
- **v0.2.0** — actioned-entry archival via `adam-archive.mjs`; `cursor` field deprecated.

## What it does

A lightweight Node.js hook (`adam-observe.mjs`) runs on `UserPromptSubmit`, `PreToolUse`, and `PostToolUse` events. It detects:

| Signal | Trigger |
|---|---|
| `correction` | User prompt contains "no", "stop", "wrong", "actually", etc. after a tool call |
| `retry_loop` | Same tool + same args called 3× in a 10-event window |
| `weak_agent` | Same subagent dispatched 2× in last 5 tool calls |
| `tool_error_loop` | Same error fingerprint appears 3× in a 5-event ring |
| `dead_end` | 8 PostToolUse events without a UserPromptSubmit between them |
| `edit_churn` | Same file edited 4× in a window |
| `build_loop` | 2× build/test/compile commands fail in same session |
| `subagent_dispatch_pattern` | Same subagent dispatched ≥3× cumulatively |
| `correction_free_streak` | 5 clean UserPromptSubmits in a row (no correction phrase) — feeds `skill_edit` reinforcement |
| `clean_recovery` | 3 clean PostToolUse events after a struggle signal — feeds `skill_edit` reinforcement |

Detection is local, regex-based, zero LLM cost. Signals append to `~/.claude/adam/journal.jsonl`.

When you run `/reflect`, the `adam` subagent reads the journal, clusters signals, scores them against a deterministic rubric, and emits proposal files to `~/.claude/adam/proposals/`. Auto-applied proposals only ship for low-blast types (memory, new skills) backed by cross-session evidence; everything else queues for your manual approve/reject/edit walk.

## Why

LLM coding sessions reveal repeated friction the moment you stop and look. ADAM looks so you don't have to.

## Layout

```
~/.claude/
├── hooks/
│   ├── adam-observe.mjs      # signal collector
│   └── adam-nudge.mjs        # SessionStart reminder when ≥3 proposals queued
├── agents/adam.md            # analyst subagent (system prompt + rubric)
├── skills/adam-self-improvement/SKILL.md  # /reflect protocol
├── commands/reflect.md       # /reflect slash command
└── adam/
    ├── journal.jsonl         # append-only signal log (active observations)
    ├── journal/              # rotated daily logs + actioned-<id>.jsonl per applied/rejected proposal
    ├── state.json            # per-session counters
    ├── usage.json            # skill/agent invocation tallies + payload visibility counters
    ├── proposals/            # queued, awaiting review
    ├── applied/              # approved + auto-applied archive
    ├── rejected/             # rejected (with reason)
    ├── trash/                # soft-deleted artifacts (recoverable)
    ├── scripts/              # adam-archive.mjs (called by skill on apply/reject)
    └── tests/run-tests.sh    # 27 verification tests (isolated tmpdir; never touches live state)
```

## Install

### One-liner (recommended)

```sh
curl -fsSL https://raw.githubusercontent.com/lukaszraczylo/claude-adam/main/install.sh | bash
```

Pin a release for reproducibility:

```sh
curl -fsSL https://raw.githubusercontent.com/lukaszraczylo/claude-adam/v0.3.1/install.sh \
  | VERSION=v0.3.1 bash
```

The installer clones the repo to `/tmp`, copies files into `~/.claude/`, and offers to merge ADAM's hook entries into your `~/.claude/settings.json` (with a diff preview and `[y/N]` confirmation — your existing hooks are preserved). Pass `--yes` to skip the prompt; `--dry-run` to preview without writing.

Requires `git`, `curl`, `jq`, and `node` 18+.

### From a clone

```sh
git clone https://github.com/lukaszraczylo/claude-adam
cd claude-adam
./install.sh
```

### Upgrade-safe

These files are **never overwritten** if they already exist:

- `~/.claude/adam/journal.jsonl` — your observation log
- `~/.claude/adam/state.json` — session counters
- `~/.claude/adam/usage.json` — invocation tallies

If you've locally edited any installed file (e.g. `agents/adam.md`), the installer writes the new version to `<file>.adam-new` and warns you instead of clobbering.

After install: run `bash ~/.claude/adam/tests/run-tests.sh` to verify (expect `27 passed, 0 failed`), start a fresh Claude Code session, then run `/reflect`.

## Requirements

- Claude Code v2.1.0+ (for auto skill hot-reload; older versions need session restart after `skill_new` proposals are applied)
- Node.js 18+ (for the hook; tested on v22)
- Bash 4+, `git`, `curl`, `jq` (for installer + test harness)

### Platform support

Tested on **macOS** (Darwin / BSD coreutils) and **Linux** (Alpine, glibc + musl). The install / uninstall / test scripts are written to be portable: `stat` uses BSD `-f` with GNU `-c` fallback, `mktemp -d -t prefix.XXXXXX` works on both, no GNU-only flags. CI smoke verified `27 passed, 0 failed` under `alpine:latest`.

## Confidence rubric

```
Sum:
+2  Signal repeated ≥3× across ≥2 sessions
+2  Struggle signal appearing ≥1× within a single session (does not stack)
+2  Transcript contains positive endorsement near related action
+1  Multi-axis cluster (≥2 distinct struggle types in same session)
-1  Type-bias penalty (≥3 rejections, applied:rejected <1:2)
+1  Blast radius low (memory or new isolated skill)
 0  Blast radius medium (new agent, new hook, edit existing skill)
-1  Blast radius high (CLAUDE.md, settings hooks, edit agent, deletion)
+1  Surgical (one file, ≤50 LOC for non-skill_new; ≤80 LOC for skill_new)
-3  Touches deny-list (settings.json hooks/permissions, CLAUDE.md, deletions)

auto_apply_eligible requires ALL:
  confidence ≥ 4
  blast_radius == low
  type ∈ {memory, skill_new, skill_edit}     # skill_edit also passes the win-driven gate
  cross_session_evidence == true (single-session-only proposals always queue)

skill_edit additionally requires (v0.2.1+):
  win-signal evidence (correction_free_streak / clean_recovery cites target skill)
  diff is append-only, ≤30 LOC, resulting size ≤2× original
  no auto-edit to same target in past 7 days (cooldown)
  no rejection-blacklist on target in past 30 days
  contradiction heuristic does not flag (v0.3.0+)
  # Diagnosis section present + structurally valid (v0.3.0+)
```

## Lifecycle: how proposals become permanent

Every proposal records the journal entry timestamps that fed its cluster (`source_entries` in frontmatter). When you apply or reject a proposal, the skill calls `adam/scripts/adam-archive.mjs` which moves matching entries from `journal.jsonl` to `journal/actioned-<id>.jsonl`. Effects:

- The `journal.jsonl` stays bounded by **active** observations only.
- The next `/reflect` reads applied/ + rejected/ frontmatter, builds an excluded-timestamps set, and skips any leftover journal entries that were already actioned.
- Rule changes (e.g. lowering a threshold) immediately re-evaluate the remaining active observations — no manual cursor rewind needed.

## What it will not do

- No background LLM spend. The analyst runs only when you invoke `/reflect`.
- No retroactive transcript mining beyond the journal cursor.
- No hard `rm` of any artifact. Deletions are soft (`mv` to `trash/<ts>/`).
- No autonomous edits to `CLAUDE.md`, agents, hooks, or `settings.json` — these always queue for review regardless of confidence.
- No proposal that matches a previously-rejected idea (≥2 token overlap with rejection's `# Why`).
- No invented trigger phrases for new skills — every trigger comes from observed user input.

## Uninstall

One-shot:

```sh
curl -fsSL https://raw.githubusercontent.com/lukaszraczylo/claude-adam/main/adam-uninstall.sh | bash
```

The uninstaller archives `~/.claude/adam/` to `~/.claude/adam.bak.<ts>/` (preserving your journal/proposals data), removes ADAM files, and offers to strip ADAM hook entries from `~/.claude/settings.json` with a diff prompt. Pass `--yes` to skip the prompt; `--purge` to delete the data archive instead of preserving it.

Manual:

```sh
mv ~/.claude/adam ~/.claude/adam.bak.$(date +%s)
rm -f ~/.claude/hooks/adam-*.mjs ~/.claude/agents/adam.md ~/.claude/commands/reflect.md
rm -rf ~/.claude/skills/adam-self-improvement
```

Then remove the four `adam-*` hook entries from `~/.claude/settings.json`.

## License

[MIT](LICENSE) — © 2026 Lukasz Raczylo
