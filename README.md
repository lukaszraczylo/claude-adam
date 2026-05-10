# claude-adam

Self-improvement layer for [Claude Code](https://claude.com/claude-code) that observes friction signals during your sessions and proposes targeted improvements (new skills, memory entries, agent edits) which you can review and apply.

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
    ├── journal.jsonl         # append-only signal log
    ├── journal/              # rotated daily logs (>5 MB threshold)
    ├── state.json            # cursor + per-session counters
    ├── usage.json            # skill/agent invocation tallies
    ├── proposals/            # queued, awaiting review
    ├── applied/              # approved + auto-applied archive
    ├── rejected/             # rejected (with reason)
    ├── trash/                # soft-deleted artifacts (recoverable)
    └── tests/run-tests.sh    # 18 verification tests
```

## Install

```sh
./install.sh
```

The script copies files into `~/.claude/`. **It does NOT modify your `settings.json`** — wire the hook entries manually using `settings.json.example` as reference. Merging into existing settings prevents accidental clobber of your other hooks.

After install:
1. Run the test suite: `bash ~/.claude/adam/tests/run-tests.sh` — must show `18 passed, 0 failed`.
2. Add the hook entries from `settings.json.example` to `~/.claude/settings.json` (preserve your existing hooks; ADAM's are additive).
3. Restart Claude Code, or just run `/reflect` to trigger the skill — Claude Code v2.1.0+ auto-hot-reloads user-level skills, no restart needed.

## Requirements

- Claude Code v2.1.0+ (for auto skill hot-reload; older versions need session restart after `skill_new` proposals are applied)
- Node.js 18+ (for the hook; tested on v22)
- Bash (for the test harness)

## Confidence rubric

```
Sum:
+2  Signal repeated ≥3× across ≥2 sessions
+2  Struggle signal repeated ≥3× within a single session (does not stack with above)
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
  type ∈ {memory, skill_new}
  cross_session_evidence == true (single-session-only proposals always queue)
```

## What it will not do

- No background LLM spend. The analyst runs only when you invoke `/reflect`.
- No retroactive transcript mining beyond the journal cursor.
- No hard `rm` of any artifact. Deletions are soft (`mv` to `trash/<ts>/`).
- No autonomous edits to `CLAUDE.md`, agents, hooks, or `settings.json` — these always queue for review regardless of confidence.
- No proposal that matches a previously-rejected idea (≥2 token overlap with rejection's `# Why`).
- No invented trigger phrases for new skills — every trigger comes from observed user input.

## Uninstall

```sh
rm -rf ~/.claude/{hooks/adam-*.mjs,agents/adam.md,skills/adam-self-improvement,commands/reflect.md,adam}
```
Then remove the four `adam-*` hook entries from `~/.claude/settings.json`.

## License

(add your preferred license)
