---
name: adam-self-improvement
description: Use when the user types /reflect, asks "what has adam learned", asks to "review proposals", or wants to inspect the self-improvement queue. Dispatches the adam subagent to analyse the observation journal and presents proposals for approve/reject/edit.
---

# adam-self-improvement

You are about to drive a review session for ADAM, the self-improvement layer. You operate in the **main thread** with the user present. The `adam` subagent does the heavy analysis; you orchestrate.

## When to invoke

- User types `/reflect`
- User asks: "what has adam learned", "any proposals", "review the queue"
- SessionStart nudge said proposals are pending and user wants to act on it

## Protocol

### 1. Dispatch the analyst

Use the Agent tool with `subagent_type: "adam"` and prompt:

```
Run a single analysis pass.

Inputs:
- journal_path: ~/.claude/adam/journal.jsonl
- state_path: ~/.claude/adam/state.json
- usage_path: ~/.claude/adam/usage.json
- proposals_dir: ~/.claude/adam/proposals/
- applied_dir: ~/.claude/adam/applied/
- rejected_dir: ~/.claude/adam/rejected/
- transcripts_root: ~/.claude/projects/
- skills_root: ~/.claude/skills/

Follow your system prompt exactly. Emit a single JSON punch list as your final message.
```

Wait for return.

### 2. Auto-apply high-confidence items

For each id in `high_confidence`:
- Read the proposal file from `~/.claude/adam/proposals/<id>-*.md`.
- Verify in front of the user: print `id`, `target`, `confidence`, `blast_radius`, `cross_session_evidence`, `auto_apply_eligible`.
- Apply the change:
  - **For `skill_new`**: `mkdir -p ~/.claude/skills/<slug>/`, then `Write` the proposal's `# Proposed change` body to `~/.claude/skills/<slug>/SKILL.md`. After write, print: "skill `<slug>` written to `~/.claude/skills/<slug>/SKILL.md` — activates immediately — Claude Code v2.1.0+ auto-hot-reloads user-level skills, no restart needed."
  - **For `memory`**: `Write` the proposal's `# Proposed change` body to the path in `target` (under `~/.claude/projects/<encoded-home>/memory/`, where `<encoded-home>` is the user's home dir with `/` replaced by `-`, e.g. `-Users-alice` on macOS). Then update `MEMORY.md` index with a one-line pointer.
  - **For other types under auto-apply**: apply via Write/Edit per `# Proposed change`. (Note: only `memory` and `skill_new` qualify for auto-apply per the rubric.)
- Move proposal to `~/.claude/adam/applied/<UTC-ts>-<id>.md`.

Print: `auto-applied N proposals: [ids]`.

### 3. Walk the queue

For each id in `queued`:

a. Read and display the proposal in full (frontmatter + body).
b. Ask the user: **approve** / **reject** / **edit**.
c. On **approve**:
   - For `claude_md_edit`: backup `cp ~/.claude/CLAUDE.md ~/.claude/adam/applied/<ts>-claude-md-backup.md` first.
   - For `deletion`: `mkdir -p ~/.claude/adam/trash/<ts>` then `mv` the artifact into it. Print restoration command.
   - For `skill_new`: `mkdir -p ~/.claude/skills/<slug>/`, then write `# Proposed change` body to `<slug>/SKILL.md`. Tell user: "skill `<slug>` written — activates immediately (CC v2.1.0+ auto-hot-reload)."
   - For `skill_edit`: apply the unified diff in `# Proposed change` to the existing SKILL.md at `target` (append-only — never replace existing content).
   - For `memory`: write to `target` and update `MEMORY.md` index.
   - For all others: apply via Write/Edit per the proposal's `# Proposed change`.
   - Move proposal to `~/.claude/adam/applied/<ts>-<id>.md`.
d. On **reject**: ask for reason in one line. Append `# Reason\n<reason>` to proposal body. Move to `~/.claude/adam/rejected/<id>.md`.
e. On **edit**: ask the user for the change, edit the proposal in place, then loop back to step 3a for that same id.

### 4. Handle failures

If apply fails (file write error, target missing): leave proposal in `proposals/`, append `# Apply error\n<error>` to its body. Tell the user. Do not move it.

### 5. Summary

End with one block:

```
adam reflect summary:
  observations processed: <new>
  auto-applied: <N>
  approved: <N>
  rejected: <N>
  edited+approved: <N>
  failed: <N>
```

## Karpathy constraints (you must enforce on each apply)

Before writing any proposal:
- Confirm `# Assumptions` section is non-empty.
- Confirm `# Success criterion` section is non-empty and runnable.
- Confirm change is ≤50 LOC for non-`skill_new`, or ≤80 LOC for `skill_new` body. If larger, ask the user once: "this proposal is N LOC — proceed?"
- For `claude_md_edit`: confirm 3+ distinct cwds in the `# Why` section.
- For `deletion`: confirm both criteria (a) and (b) from the agent's special handling are documented in the proposal.
- For `skill_new`: confirm the slug doesn't collide with any existing skill in `~/.claude/skills/`. If it does, refuse and ask user to rename.
- For `skill_edit`: confirm the diff is append-only (no `-` lines that remove existing content) and that target SKILL.md exists.

If any check fails, refuse to apply and ask the user how to proceed.

## Things you MUST NOT do

- Do not auto-apply anything not in `high_confidence`.
- Do not invoke other skills during a `/reflect` run.
- Do not modify `settings.json` without explicit user yes.
- Do not hard-delete anything. Use `mv` to `~/.claude/adam/trash/<ts>/`.
- Do not bypass the rubric (`auto_apply_eligible: false` means queue, full stop).
