---
name: adam-self-improvement
description: Use when the user types /reflect, asks "what has adam learned", asks to "review proposals", or wants to inspect the self-improvement queue. Dispatches the adam subagent to analyse the observation journal and presents proposals for approve/reject/edit.
---

# adam-self-improvement

## When to invoke

- User types `/reflect`
- User types `/reflect --explain` (same flow, but the analyst's clustering trace is shown to the user — see §2b below)
- User asks: "what has adam learned", "any proposals", "review the queue"
- SessionStart nudge said proposals are pending and user wants to act on it

## Protocol

### 0. Parse flags

Check the slash-command argument string for the literal token `--explain`. Set `explain=true` when present; otherwise `explain=false`. Unknown flags: print one-line warning, continue with `explain=false`. This single flag is the only argument `/reflect` currently accepts.

### 1. Pre-filter the journal (window + exclusion) + score

Before dispatching the analyst, run the windowed-journal filter:

```bash
node ~/.claude/adam/scripts/adam-window.mjs --home ~/.claude > /tmp/adam-windowed-journal.jsonl 2> /tmp/adam-windowed-journal.log
```

The script reads the active journal plus all rotated journal files (new
`journal/YYYY-Www.jsonl` weekly format AND legacy
`journal/YYYY-MM-DD-<ts>.jsonl` size-rotated format are both supported), applies
per-signal-type sliding windows (see `SIGNAL_WINDOWS_DAYS` in
`adam-window.mjs`), and drops entries already actioned via
`applied/*.md` / `rejected/*.md` frontmatter `source_entries`.

If `adam-window.mjs` exits non-zero: log the stderr file to the user, fall
through to passing the raw `~/.claude/adam/journal.jsonl` path to the agent
(graceful degradation — the agent's manual excluded-timestamps logic still
filters actioned entries; only the freshness window is lost).

Then run the scoring pre-step on the same windowed journal:

```bash
node ~/.claude/adam/scripts/adam-score.mjs --input /tmp/adam-windowed-journal.jsonl > /tmp/adam-scores.json 2> /tmp/adam-scores.log
```

This produces a per-session `dampener` (0.5 / 0.75 / 1.0 based on
`task_completed_count`) and a `reinforcement_candidates` list (skills cited by
≥3 clean `task_completed` events). The analyst uses both — see
`agents/adam.md` §"Scoring: task_completed dampener". If the score step fails,
log stderr to the user and pass an empty `{"sessions":[],"reinforcement_candidates":[]}`
to the analyst (dampener defaults to 1.0).

Finally, run the A/B measurement pre-step on any previously auto-applied
proposals (see §3 ab-tracking write):

```bash
node ~/.claude/adam/scripts/adam-ab-measure.mjs --home ~/.claude --format json > /tmp/adam-ab-regressions.json 2> /tmp/adam-ab-regressions.log
```

The JSON output is an array of A/B delta objects (`pre_count`, `post_count`,
`delta_pct`, `status` ∈ {`improved`,`neutral`,`regressed`,`no_baseline`,`pending`}).
Filter to `status == "regressed"` before passing to the analyst as
`ab_regressions`. The analyst is required (see `agents/adam.md` §"A/B
effectiveness") to surface a `## Regressions` section at the top of its output
when this list is non-empty. If the script fails: log stderr, pass `[]`.

### 2. Dispatch the analyst

Use the Agent tool with `subagent_type: "adam"` and prompt:

```
Run a single analysis pass.

Inputs:
- windowed_journal_path: /tmp/adam-windowed-journal.jsonl  # pre-filtered by adam-window.mjs
- scores_path: /tmp/adam-scores.json                       # per-session dampeners + reinforcement candidates
- ab_regressions_path: /tmp/adam-ab-regressions.json       # A/B deltas for prior auto-applied proposals
- journal_path: ~/.claude/adam/journal.jsonl               # raw — fallback only
- state_path: ~/.claude/adam/state.json
- usage_path: ~/.claude/adam/usage.json
- proposals_dir: ~/.claude/adam/proposals/
- applied_dir: ~/.claude/adam/applied/
- rejected_dir: ~/.claude/adam/rejected/
- transcripts_root: ~/.claude/projects/
- skills_root: ~/.claude/skills/

The windowed_journal is already filtered by per-signal age (see
SIGNAL_WINDOWS_DAYS in adam-window.mjs) AND by actioned-exclusion. Read it as
your primary input — do not re-apply window math. Fall back to journal_path
only if windowed_journal_path is missing or empty.

Follow your system prompt exactly. Emit a single JSON punch list as your final message.
```

Wait for return.

### 2b. Persist and render the clustering trace

The analyst's final message always contains a fenced ` ```trace ` block (per `agents/adam.md` §"Clustering trace (always emit)") immediately before its punch-list JSON line.

1. Extract the trace block. If it is missing, print a one-line warning to the user (`adam: trace block missing from agent output — proceeding without observability`) and continue; do not block on this.
2. ALWAYS write the trace verbatim (without the surrounding fences) to `~/.claude/adam/last-trace.txt` (overwrite each run). This persists for retrospection via `node ~/.claude/adam/scripts/adam-explain.mjs`.
3. Extract the `SUMMARY:` line from the trace. ALWAYS display it as a one-line status to the user BEFORE the proposals are listed, e.g. `clustering: <SUMMARY line>`. This single-line status is shown in both `--explain` and default modes.
4. If `explain=true` (from §0): ALSO render the full trace block back to the user as a fenced code block (` ```text ` … ` ``` `) under a header `Clustering trace:`. If `explain=false`: SUPPRESS the cluster-line body from the user-visible output (the SUMMARY line is already shown in step 3).

The user can re-render any past trace at any time via:

```bash
node ~/.claude/adam/scripts/adam-explain.mjs --mode summary    # SUMMARY + per-decision counts
node ~/.claude/adam/scripts/adam-explain.mjs --mode full       # verbatim trace + rejection histogram
node ~/.claude/adam/scripts/adam-explain.mjs --mode json       # machine-readable
```

### 3. Auto-apply high-confidence items

For each id in `high_confidence`:
- Read the proposal file from `~/.claude/adam/proposals/<id>-*.md`.
- Verify in front of the user: print `id`, `target`, `confidence`, `blast_radius`, `cross_session_evidence`, `auto_apply_eligible`.
- Apply the change:
  - **For `skill_new`**: `mkdir -p ~/.claude/skills/<slug>/`, then `Write` the proposal's `# Proposed change` body to `~/.claude/skills/<slug>/SKILL.md`. After write, print: "skill `<slug>` written to `~/.claude/skills/<slug>/SKILL.md` — activates immediately — Claude Code v2.1.0+ auto-hot-reloads user-level skills, no restart needed."
  - **For `memory`**: `Write` the proposal's `# Proposed change` body (which MUST include the auto-memory frontmatter — see "Memory drafting protocol" in `agents/adam.md`) to the path in `target`. Then update `MEMORY.md` index with a one-line pointer.
  - **For `nudge`**: low-blast auto-apply path. Single-session evidence is sufficient — skip the cross-session gate. Append a new entry to `~/.claude/adam/active-nudges.json` (create the file with `[]` if absent) with shape `{kind, message, created_at: <now_ms>, expires_at_ts: <now_ms + 7*86400000>, max_displays: 3, displays_used: 0, source_session: <session_id from proposal>}`. Do NOT modify any skill, memory, agent, or CLAUDE.md. Tell user: "nudge queued — surfaces on next SessionStart in a different session (expires in 7 days)."
  - **For `reinforcement`**: gated by `confidence >= 4 AND blast_radius == low` (same as memory). Apply by invoking the helper:

    ```bash
    node ~/.claude/adam/scripts/adam-apply-reinforcement.mjs ~/.claude/adam/proposals/<id>-*.md --home ~/.claude
    ```

    The helper reads the proposal frontmatter (`skill_slug`, `count`, `source_session`) and appends one JSON line to `~/.claude/adam/reinforcements.jsonl`. No code/memory/skill modifications. Output: `{"status":"applied"|"gated", ...}` — on `gated` leave proposal in `proposals/` (helper failed its own re-check), on `applied` continue to the archive step. Tell user: "reinforcement logged for `<skill_slug>` (count=<N>) — appended to reinforcements.jsonl."
  - **For `skill_edit`**: enforce the apply-time gate before writing.
    1. Verify proposal frontmatter has `auto_apply_eligible: true`. If not, abort and queue for review.
    2. Read `target` SKILL.md, capture `current_bytes` from a fresh stat — do NOT trust frontmatter `bytes_before`.
    3. Verify diff in `# Proposed change`:
       - Unified-diff format.
       - Zero `-` lines on existing SKILL.md content (additions only).
       - Total `+` lines ≤ 30.
       If any check fails, print one-line refusal reason, leave proposal in `proposals/`, continue.
    4. Cooldown re-check: run `node ~/.claude/adam/scripts/adam-cooldown.mjs --skill <target_skill> --fingerprint <proposal_fingerprint>` (both fields come from proposal frontmatter; missing fingerprint → "legacy"). Refuse if the script returns `status: cooldown` OR `status: blacklisted`. This per-(skill, fingerprint) gate replaces the previous coarse per-skill scan — proposals for the same skill with a different fingerprint are NOT blocked by an older entry.
    5. (covered by step 4 — blacklisted status is returned by `adam-cooldown.mjs` when `auto_apply_blacklist: true` is found in `rejected/` within 30 days for the same (skill, fingerprint))
    6. Apply via `Edit` tool (append the new section per the diff). Never use `Write` on existing SKILL.md.
    7. Re-stat target. If new size exceeds `2 * current_bytes` (captured in step 2), revert via `Edit` (remove the just-appended section) and refuse — print refusal reason.
    8. Add `last_auto_edit: <iso8601 utc now>` to the proposal frontmatter before moving it.
    9. Tell user: "skill `<slug>` extended (added <N> lines) — auto-applied via win-evidence gate."
- Move proposal to `~/.claude/adam/applied/<UTC-ts>-<id>.md`.
- **A/B tracking append**: as a separate atomic step right after the move, append one JSON line to `~/.claude/adam/ab-tracking.jsonl` (create with empty contents if absent). Read fields from the proposal's frontmatter (`proposal_fingerprint`, `originating_signals` — both populated per `agents/adam.md`; `originating_signals` is a list of `{type, count, session_ids}` objects). Schema:

  ```json
  {
    "applied_at": <unix_ms now>,
    "proposal_id": "<id>",
    "proposal_type": "skill_edit|skill_new|memory|nudge|reinforcement",
    "target_skill": "<slug or target basename>",
    "proposal_fingerprint": "<hash>",
    "originating_signals": [{"type":"<signal>","count":<N>,"session_ids":[...]}],
    "pre_window_days": 7
  }
  ```

  This entry is consumed by `adam-ab-measure.mjs` on subsequent `/reflect` runs to compute pre/post signal-count deltas. See `agents/adam.md` §"A/B effectiveness". If the append fails (disk-full etc.) log a warning but do NOT abort the apply path — A/B is observability, not a gate.
- **Archive consumed journal entries**: `node ~/.claude/adam/scripts/adam-archive.mjs ~/.claude/adam/applied/<UTC-ts>-<id>.md` — moves entries listed in proposal's `source_entries` from `journal.jsonl` to `journal/actioned-<id>.jsonl` so subsequent `/reflect` runs do not re-cluster them.

Print: `auto-applied N proposals: [ids]`.

### 4. Walk the queue

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
e. On **edit**: ask the user for the change, edit the proposal in place, then loop back to step 4a for that same id.

### 5. Handle failures

If apply fails (file write error, target missing): leave proposal in `proposals/`, append `# Apply error\n<error>` to its body. Tell the user. Do not move it.

### 6. Summary

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
- For `skill_edit`: confirm the diff is append-only (no `-` lines that remove existing content) and that target SKILL.md exists. When auto-applying, ALSO re-verify the eligibility gate steps in §3 (cooldown, blacklist, byte cap) before any `Edit` call — never trust frontmatter alone.
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
