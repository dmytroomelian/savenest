# Issue label policy

Labels answer four questions: what kind of work is this, where does it belong, how urgent is it, and what prevents the next step? The canonical names, colors, and short descriptions live in [`.github/labels.json`](../.github/labels.json).

## Minimum labels

Every triaged open issue has exactly one primary type, one or two relevant `area:*` labels, and exactly one `priority:*` label. Choose the areas where the work happens, not every area it might affect. A cross-cutting epic can use its coordinating area, such as `area:release`.

New reports may carry `status:triage` before area and priority are known. Reporters do not need to choose labels. Bug and feature forms apply their provisional type and `status:triage`; maintainers also triage blank issues manually. Classification does not confirm a reported bug, approve a feature, authorize an external action, or promise delivery.

Use at most one `status:*` label. No status label means there is no recorded exception; it does not mean work is approved or in progress. Use assignees for ownership, milestones for release grouping, and GitHub's open/closed state for completion. Do not add labels for individual people, versions, or routine states such as `done`.

## Primary type: choose one

| Label | Use when |
| --- | --- |
| `bug` | Existing behavior fails to meet its expected contract. Record reproduction evidence. |
| `enhancement` | Adding or improving user-facing behavior. |
| `documentation` | The deliverable is documentation only, with no product behavior change. |
| `task` | Maintenance, infrastructure, release, or operational work. Use this for mixed implementation and policy work that fits no other type. |
| `research` | Discovery or design must establish evidence and a decision before implementation. |
| `epic` | One outcome coordinates several linked child issues. Track implementation in those issues. |
| `question` | The issue asks for usage or support guidance. Missing bug details belong under `status:needs-info`. |

Keep the familiar unprefixed type labels so existing GitHub filters continue to work. Do not add parallel aliases such as `type:bug` or `feature`.

## Area: choose one or two

| Label | Scope |
| --- | --- |
| `area:launcher` | Launcher UI, keyboard interaction, search presentation, navigation. |
| `area:capture` | Browser and share-sheet capture, tabs, history, capture permissions. |
| `area:library` | Local storage, indexing, organization, import/export, backup/restore. |
| `area:reading` | Reader, offline articles, highlights, Markdown notes, Obsidian. |
| `area:cloud` | Optional sync, hosted backup, trusted devices, shared libraries. |
| `area:website` | Public website, downloads page, hosted presentation. |
| `area:accounts` | Sign-in, access, billing, pricing, subscriber transitions. |
| `area:release` | Builds, CI, packaging, signing, updates, distribution. |
| `area:privacy` | Data handling, analytics, consent, privacy disclosures. |

## Priority: choose one after triage

| Label | Meaning |
| --- | --- |
| `priority:critical` | Immediate response to active data loss or a widespread unusable release. |
| `priority:high` | A confirmed release gate or major user impact. Address before normal backlog. |
| `priority:normal` | Default for accepted backlog without a stronger urgency decision. No delivery date is implied. |
| `priority:low` | Explicitly deferred work, later discovery, or optional polish. |

Maintainers set priority from impact, current dependencies, and recorded decisions. A requested feature or a suggested next-release candidate is normally `priority:normal` until selected. Research is not automatically low priority. Joining a launch milestone does not by itself make every issue high priority. An epic's priority does not automatically propagate to its children.

## Status: only when needed

| Label | Required evidence and exit condition |
| --- | --- |
| `status:triage` | Not yet assessed. Remove after reviewing scope, type, area, priority, and the next action. |
| `status:needs-info` | A specific question is recorded and its answer is needed to assess the issue. Remove when answered or no longer needed. |
| `status:blocked` | Name the dependency or external condition and why no useful next step can proceed. Remove when that condition clears. |
| `status:needs-validation` | Implementation or a preview exists, but named acceptance checks remain unverified. Remove when evidence satisfies them, or reclassify if a failure requires more work. |

Replace statuses rather than stacking them. If missing information prevents assessment, use `status:needs-info`. If a validation environment or another prerequisite prevents all progress, use `status:blocked` and keep the pending checks in the issue. A dependency alone does not imply a block: a design or prototype may still proceed.

Shipping a preview does not establish installed-app behavior. Keep migration, privacy, updater, and architecture-specific acceptance open until supported by the required evidence. Labeling an issue from its recorded status is not fresh verification of that behavior.

## Optional labels and closure

- `accessibility`: a concrete disability-related barrier. Combine with a primary type; ordinary keyboard support does not automatically qualify.
- `help wanted`: work has clear scope and verification steps and is ready for a contributor.
- `good first issue`: add alongside `help wanted` only for a small, unblocked task with clear guidance and available maintainer support. Do not use it for release signing, billing, migrations, or unresolved architecture.
- `duplicate`: close with a link to the canonical issue.
- `invalid`: close with a factual explanation of why the report is not applicable. Missing information alone is not invalidity.
- `wontfix`: close with the explicit decision and reason not to pursue the request.

Use at most one closure-reason label. Normal completion needs none. On closure, keep type and area for search history; remove status, priority, and contributor-availability labels. Keep `accessibility` when it remains relevant. Reopening requires fresh triage and removal of an obsolete closure reason.

Security reports follow [SECURITY.md](../SECURITY.md); labels do not replace private reporting.

## Triage and maintenance

1. Read the issue and latest updates. Check for an existing issue and distinguish observed behavior from proposals.
2. Assign one type and one or two areas. For an open issue, set a priority or leave `status:triage` until assessed.
3. Record a clear next action. Add a status only when its condition is met. Link dependencies; do not infer that related issues are blocked.
4. Reassess labels when evidence, scope, dependencies, or release plans change. During release planning, review high-priority work and unresolved acceptance checks together.
5. Before closing, verify the acceptance evidence or record the reason for not completing the work. Remove temporary labels as described above.

Pull requests may reuse type and area labels. The minimum-label rule applies to issues, not pull requests; PR draft state, reviews, and checks already describe the review process.

To change the taxonomy, update this policy and `.github/labels.json` together. Reuse an existing label when its meaning fits. Add a new area only when it represents recurring work. Renames and deletions require checking affected issues, pull requests, saved filters, and issue forms first; migrate usages before removing the old label.

Maintainers can reconcile names, colors, and descriptions using an authenticated GitHub CLI with label-management access. From the repository root, inspect the catalog and current labels first:

```sh
python3 -m json.tool .github/labels.json
gh label list --repo dmytroomelian/savenest --limit 200
```

Then apply the reviewed catalog:

```sh
python3 - <<'PY'
import json
import subprocess
from pathlib import Path

labels = json.loads(Path('.github/labels.json').read_text())
for label in labels:
    subprocess.run([
        'gh', 'label', 'create', label['name'],
        '--repo', 'dmytroomelian/savenest',
        '--color', label['color'],
        '--description', label['description'],
        '--force',
    ], check=True)
PY
```

This creates missing labels and updates the catalog's existing labels. It does not delete other labels, rename labels, assign issues, or close work. Read back the label list and audit the changed issues after applying a migration. Issue forms must reference labels that already exist in GitHub.

## Examples

- A release with published preview artifacts and unverified installed-app acceptance: `task`, `area:release`, `priority:high`, `status:needs-validation`.
- A proposed bookmark importer with clear scope but no committed release: `enhancement`, `area:library`, `priority:normal`.
- Later Pro discovery: `research`, `area:cloud`, `priority:low`. The label does not authorize implementation or outreach.
- A newly filed launcher bug: `bug`, `status:triage`; add area and priority after assessment.
