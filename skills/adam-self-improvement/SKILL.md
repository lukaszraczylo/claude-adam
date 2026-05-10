---
name: adam-self-improvement
description: Use when the user types /reflect, asks "what has adam learned", asks to "review proposals", or wants to inspect the self-improvement queue. Dispatches the adam subagent to analyse the observation journal and presents proposals for approve/reject/edit.
---

# adam-self-improvement

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
  - **For `memory`**: `Write` the proposal's `# Proposed change` body (which MUST include the auto-memory frontmatter — see "Memory drafting protocol" in `agents/adam.md`) to the path in `target`. Then update `MEMORY.md` index with a one-line pointer.
  - **For `skill_edit`**: enforce the apply-time gate before writing.
    1. Verify proposal frontmatter has `auto_apply_eligible: true`. If not, abort and queue for review.
    2. Read `target` SKILL.md, capture `current_bytes` from a fresh stat — do NOT trust frontmatter `bytes_before`.
    3. Verify diff in `# Proposed change`:
       - Unified-diff format.
       - Zero `-` lines on existing SKILL.md content (additions only).
       - Total `+` lines ≤ 30.
       If any check fails, print one-line refusal reason, leave proposal in `proposals/`, continue.
    4. Cooldown re-check: scan `applied/` frontmatter for `target` matching this and `last_auto_edit` newer than 7 days ago. Refuse if found.
    5. Blacklist re-check: scan `rejected/` frontmatter for `target` matching this and `auto_apply_blacklist: true` newer than 30 days ago. Refuse if found.
    6. Apply via `Edit` tool (append the new section per the diff). Never use `Write` on existing SKILL.md.
    7. Re-stat target. If new size exceeds `2 * current_bytes` (captured in step 2), revert via `Edit` (remove the just-appended section) and refuse — print refusal reason.
    8. Add `last_auto_edit: <iso8601 utc now>` to the proposal frontmatter before moving it.
    9. Tell user: "skill `<slug>` extended (added <N> lines) — auto-applied via win-evidence gate."
- Move proposal to `~/.claude/adam/applied/<UTC-ts>-<id>.md`.
- **Archive consumed journal entries**: `node ~/.claude/adam/scripts/adam-archive.mjs ~/.claude/adam/applied/<UTC-ts>-<id>.md` — moves entries listed in proposal's `source_entries` from `journal.jsonl` to `journal/actioned-<id>.jsonl` so subsequent `/reflect` runs do not re-cluster them.

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
   - For `memory`: write `# Proposed change` body (must include auto-memory frontmatter) to `target` and update `MEMORY.md` index with a one-line pointer.
   - For all others: apply via Write/Edit per the proposal's `# Proposed change`.
   - Move proposal to `~/.claude/adam/applied/<ts>-<id>.md`.
   - Archive: `node ~/.claude/adam/scripts/adam-archive.mjs ~/.claude/adam/applied/<ts>-<id>.md`.
d. On **reject**: ask for reason in one line. Append `# Reason\n<reason>` to proposal body. If the proposal `type` is `skill_edit`, ALSO add `auto_apply_blacklist: true` to its frontmatter (so future reflects skip auto-apply on this target for 30 days). Move to `~/.claude/adam/rejected/<id>.md`. Archive: `node ~/.claude/adam/scripts/adam-archive.mjs ~/.claude/adam/rejected/<id>.md`.
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
- Confirm `# Diagnosis` section exists and contains all four labelled lines (`Trigger:`, `Action:`, `Mismatch:`, `Outcome:`) AND at least one backtick-wrapped quote ≤80 chars in the Outcome line. Refuse if missing or malformed — agent must redraft per the "Diagnosis drafting protocol" in `agents/adam.md`.
- Confirm `# Success criterion` section is non-empty and runnable.
- Confirm change is ≤50 LOC for non-`skill_new`, or ≤80 LOC for `skill_new` body. If larger, ask the user once: "this proposal is N LOC — proceed?"
- For `claude_md_edit`: confirm 3+ distinct cwds in the `# Why` section.
- For `deletion`: confirm both criteria (a) and (b) from the agent's special handling are documented in the proposal.
- For `skill_new`: confirm the slug doesn't collide with any existing skill in `~/.claude/skills/`. If it does, refuse and ask user to rename.
- For `skill_edit`: confirm the diff is append-only (no `-` lines that remove existing content) and that target SKILL.md exists. When auto-applying, ALSO re-verify the eligibility gate steps in §2 (cooldown, blacklist, byte cap) before any `Edit` call — never trust frontmatter alone.
- For `skill_edit` with `auto_apply_eligible: true`: confirm `contradiction_flag` is absent or null in frontmatter. Refuse auto-apply if `contradiction_flag` is set with any non-empty value (treat the agent's flag as a hard veto on auto-apply; user can still manually approve in walk-the-queue if they disagree with the heuristic).
- For `memory`: confirm `# Proposed change` body starts with `---` frontmatter containing required fields `name`, `description`, `type`, `originSessionId`. Refuse if frontmatter missing — agent must redraft per the Memory drafting protocol.
- Confirm `source_entries` is present in proposal frontmatter as a non-empty list (used for archive). Warn (do not refuse) if missing — legacy proposals from before v0.2.0 won't have it.

If any check fails, refuse to apply and ask the user how to proceed.

## Things you MUST NOT do

- Do not auto-apply anything not in `high_confidence`.
- Do not invoke other skills during a `/reflect` run.
- Do not modify `settings.json` without explicit user yes.
- Do not hard-delete anything. Use `mv` to `~/.claude/adam/trash/<ts>/`.
- Do not bypass the rubric (`auto_apply_eligible: false` means queue, full stop).
