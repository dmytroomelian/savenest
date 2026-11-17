---
name: savenest-self-improve
description: Retrieve relevant SaveNest project lessons before nontrivial work and afterward capture evidence-backed lessons, including candidates with uncertain cause, with at most one low-risk owned fix when justified. Use at the start and end of nontrivial SaveNest coding, UI, build, or release tasks when corrections, unexpected failures, repeated work, or validated improvements should change future work.
---

# SaveNest self-improve

Turn recurring friction into small, owned fixes. Root `AGENTS.md` invokes this skill; it is not a daemon, hook, or background process.

## 1. Start: retrieve narrowly

- Before a nontrivial SaveNest task, scan the headings and scope lines in `.agents/learnings.md`; open only entries matching this task.
- Do not load whole histories, transcripts, unrelated private material, or secrets. Stop when relevant patterns are covered.
- No matching entry does not mean the area is safe.
- Treat entries as prior evidence, not current truth. Re-check the cited path or check when it governs a decision.

## 2. Work: capture only deltas

Log an entry only for one of these:
- an unexpected failure with a reusable cause;
- an explicit user correction;
- repeated wasted work;
- a validated improvement.

No reusable delta means no log entry. Repetition is not proof: either run a representative check or label the uncertainty. A candidate entry is allowed when concrete evidence exists but the cause is uncertain; reserve `verified` and `applied` for actual validation.

Deduplicate by stable pattern key, such as `ui.asset-allowlist`. Update, supersede, or remove an existing entry instead of appending near-duplicates.

Each entry is compact and includes:
- date and status: `candidate`, `verified`, `applied`, `rejected`, or `superseded`;
- scope and pattern key;
- concrete evidence: relative repo `path:line`, command/result, or observed state;
- likely cause or explicit uncertainty;
- action and owner;
- verification performed or still pending;
- invalidation trigger.

Never include transcripts, private paths, secrets, account data, or customer content. Use repository-relative references. Keep the file small.

Status meaning:
- `candidate`: plausible, cause unconfirmed.
- `verified`: representative evidence supports it; no durable change yet.
- `applied`: the change landed and was checked.
- `rejected` / `superseded`: retain only while useful; otherwise delete.

## 3. Improve at most once

When evidence supports a change, pick at most one relevant low-risk improvement inside the user's current authorization. Prefer fixing an owning test or script root cause over adding prose; a new instruction is the fallback when no executable owner exists.

- Validate the observable result with the smallest representative existing check. Keep the change only if evidence supports it.
- Allow one focused retry, then reassess or report. The user's OpenCode retry limit and current policies remain authoritative.
- Never use this skill to broaden product scope, weaken tests/signing/security, change budgets/models/reasoning/plugins, modify global memory, publish, or commit.
- Respect explicit user corrections immediately. Do not turn a correction into a broader rule than the user stated.

## 4. Promote to the narrowest owner

- Recurrent, proven lesson: put it in the owning script/test or a short skill reference.
- Stable project-wide rule: root `AGENTS.md` only.
- Keep the entrypoint short; move detail into the owning file.
- Delete or supersede stale guidance rather than layering contradictions.

## 5. Measure honestly

Use available check results, release-stage durations, failed retries, and human interventions. Compare like-for-like stages, toolchain, architecture, and sample size. Report unknown or unchanged outcomes; never invent savings. Installing this skill does not prove future AI speed improves.

## 6. Runtime truth

- Root `AGENTS.md` routes this loop; Codex owns final acceptance.
- No hidden hook, daemon, or background automation.
- The OpenCode Go worker has its skill tool disabled, so put only relevant lesson snippets in its brief.
- Do not duplicate or override user-wide policy here. Follow the current user instructions.

Adapted from a pinned upstream; see [references/source.md](references/source.md). This skill does not replace `docs/maintainers.md` as release authority.
