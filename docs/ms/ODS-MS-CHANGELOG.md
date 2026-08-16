# ODS -> MS Ops Centre Change History

This file is the canonical continuous history of Modern Solutions changes
to the upstream ODS-based platform.

Any behavioral, runtime, deployment, policy, security, routing or integration
change must be recorded here in the same commit/PR that makes the change.

---

## Entry Template

## YYYY-MM-DD — `<short title>`

### Change ID
`MSODS-####`

### Agent / Author
`<name/model>`

### Branch / PR
`<branch / PR>`

### ODS baseline
`<tag / upstream SHA>`

### Classification
`CONFIGURE` | `EXTEND` | `CORE CHANGE` | `REJECT`

### Files changed
- `<path>`

### Reason
`<why>`

### MS requirement / ADR
`<reference>`

### Behavior before
`<before>`

### Behavior after
`<after>`

### Security / privacy impact
`<impact>`

### Upgrade / upstream impact
`<impact>`

### Validation performed
`<commands/tests/results>`

### Rollback
`<rollback>`

### Notes
`<notes>`

---

## 2026-08-16 — Add repository agent governance rules

### Change ID
`MSODS-0002`

### Agent / Author
Codex

### Branch / PR
`docs/agent-governance` / PR #3

### ODS baseline
`v2.6.0`

### Classification
`EXTEND`

### Files changed
- `AGENTS.md`
- `CLAUDE.md`
- `docs/ms/ODS-MS-CHANGELOG.md`

### Reason
Define repository-wide agent operating rules so future MS Ops Centre changes
preserve governance, security, review and upstream mergeability constraints.

### MS requirement / ADR
ODS adoption decision; MS fork governance requires every behavioral, config,
runtime, policy, security and integration change to be recorded in this file.

### Behavior before
Agents had no repository-root policy file describing MS-specific branch,
worktree, permission, changelog, approval and merge constraints.

### Behavior after
Agents must read `docs/ms/`, avoid direct work on `ms/main`, use isolated
branches and worktrees, classify behavioral changes, update the MS changelog
for governed changes, avoid unapproved sensitive permissions and preserve
upstream ODS mergeability.

### Security / privacy impact
Positive policy impact. The rules explicitly prohibit exposing secrets and
forbid enabling email send, Jira writes, client-system writes, root/sudo,
production secrets or unrestricted egress unless the human owner has approved
that permission.

### Upgrade / upstream impact
Low. Additive MS documentation only; no ODS runtime files are changed.

### Validation performed
- `sed -n '1,260p' docs/ms/ODS-MS-CHANGELOG.md`
- `sed -n '1,260p' docs/ms/decisions/ODS-ADOPTION.md`
- `sed -n '1,220p' AGENTS.md`
- `sed -n '1,220p' CLAUDE.md`
- `git diff --stat origin/ms/main...HEAD`
- `git diff --check`

### Rollback
To roll back the governance policy, run `git revert -m 1 b3377e9c` to revert
PR #3, then revert the follow-up changelog PR/commit that adds this entry.
Manual rollback is to remove `AGENTS.md`, remove the "Modern Solutions Fork
Rules" section from `CLAUDE.md`, and remove this `MSODS-0002` changelog entry.

### Notes
This entry records the repository-wide policy introduced by `AGENTS.md` and
the corresponding `CLAUDE.md` pointer.

---

## 2026-08-16 — Establish MS Ops Centre fork governance

### Change ID
`MSODS-0001`

### Agent / Author
Human

### Branch / PR
`docs/ms-foundation` / PR #1

### ODS baseline
`v2.6.0`

### Classification
`EXTEND`

### Files changed
- `docs/ms/ODS-MS-CHANGELOG.md`
- `docs/ms/decisions/ODS-ADOPTION.md`

### Reason
Establish the Modern Solutions governance and historical tracking layer without
changing ODS runtime behavior.

### MS requirement / ADR
ODS adoption decision.

### Behavior before
Upstream ODS repository had no Modern Solutions-specific governance or change history.

### Behavior after
The fork contains a canonical MS decision record and mandatory continuous change log.

### Security / privacy impact
None.

### Upgrade / upstream impact
Low. Additive MS documentation only.

### Validation performed
Verified files exist and are tracked by Git.

### Rollback
Remove `docs/ms/` additions.

### Notes
All future behavioral MS changes must update this file in the same PR.
