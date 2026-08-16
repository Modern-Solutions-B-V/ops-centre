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

## 2026-08-16 — QR1 security threat model (independent review)

### Change ID
`MSODS-0003`

### Agent / Author
Claude Opus 4.8 (1M context) — acting as independent security reviewer

### Branch / PR
`analysis/security` / PR pending (not self-approved, not self-merged)

### ODS baseline
`v2.6.0`

### Classification
`EXTEND` (additive MS security documentation; no ODS runtime files changed)

### Files changed
- `docs/ms/security/ODS-QR1-THREAT-MODEL.md` (new)
- `docs/ms/ODS-MS-CHANGELOG.md`

### Reason
Provide the independent QR1 threat model required before the broad ODS
capability set is progressively trusted. Classifies every capability
(inference, agents, code execution, research/data, privacy/observability,
control plane, egress, secrets, persistence, updates, supply chain) with a
permission level, the machine-enforced restriction required, and the evidence
needed before trust is raised. Reviews the initial deny policy (PR merge, email
send, Jira write, client-system writes, production secret access, sudo/root,
unrestricted shell, arbitrary egress, external fallback for confidential/
local-only workloads).

### MS requirement / ADR
`docs/ms/decisions/ODS-ADOPTION.md` (progressive machine-enforced trust);
`AGENTS.md` R6/R8/R9/R10/R13/R14.

### Behavior before
No consolidated MS threat model for the QR1 capability set; no per-component
permission-level ladder or machine-enforcement gap register.

### Behavior after
`docs/ms/security/ODS-QR1-THREAT-MODEL.md` records assets, trust boundaries,
threats, current ODS mitigations, MS gaps, initial permission level, required
machine-enforced restriction, evidence-to-trust, ACCEPT/CONFIGURE/EXTEND/
CORE CHANGE/REJECT classification, and a verification test per component, plus
the deny-policy review and a prioritized gap register. Documentation only — no
runtime behavior changes.

### Security / privacy impact
Positive (analysis). Surfaces the highest-priority machine-enforcement gaps:
G1 APE not wired in / not deny-by-default; G2 silent local→cloud fallback and
advisory-only offline mode (R10 violation); G3 no default-deny egress. No
secrets, hostnames, or credential values are included in the document (R8).

### Upgrade / upstream impact
Low. Additive MS docs under `docs/ms/`; no ODS runtime files touched; upstream
mergeability preserved.

### Validation performed
- Static inspection of compose, manifests, Dockerfiles, service source,
  installer, and configs across all 27 bundled services (evidence cited as
  `path:line` in the document).
- `git diff --check` (whitespace) — to run before commit.
- No runtime tests executed; this is a documentation/analysis change. The
  document's §12 lists the existing contract/security tests it relies on as the
  machine baseline and the new tests each remediation task must add.

### Rollback
Remove `docs/ms/security/ODS-QR1-THREAT-MODEL.md` and this `MSODS-0003` entry
(`git revert` the doc commit).

### Notes
Analysis only — no fixes implemented. Each gap in §11 becomes its own
one-task/one-branch change per `AGENTS.md`. Author is the reviewer and does not
approve or merge this work (R13–R14).

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
