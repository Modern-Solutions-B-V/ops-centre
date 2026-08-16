# ODS -> MS Ops Centre Change History

This file is the canonical continuous history of Modern Solutions changes
to the upstream ODS-based platform.

Any behavioral, runtime, deployment, policy, security, routing or integration
change must be recorded here in the same commit/PR that makes the change.

---

## 2026-08-16 — Add QR1 deployment profile

### Change ID
`MSODS-0004`

### Agent / Author
Codex

### Branch / PR
`feature/qr1-stack` / pending

### ODS baseline
`v2.6.0`

### Classification
`CONFIGURE` + `EXTEND`

### Files changed
- `ods/config/litellm/ms-qr1.yaml`
- `ods/docker-compose.ms-qr1.yml`
- `ods/extensions/services/langfuse/compose.yaml`
- `ods/profiles/ms-qr1.env.example`
- `ods/scripts/ms-qr1-compose-flags.sh`
- `ods/scripts/ms-qr1-ufw-docker-rules.sh`
- `ods/scripts/ms-qr1-acceptance.sh`
- `docs/ms/deploy/QR1-DEPLOY-RUNBOOK.md`
- `docs/ms/handovers/2026-08-16-qr1-stack-implementation.md`
- `docs/ms/ODS-MS-CHANGELOG.md`

### Reason
Prepare all repository artifacts required for Modi to deploy QR1 safely on
EVO-X3 later, without Codex touching or deploying on the host.

### MS requirement / ADR
QR1 cross-review decisions D-1, D-2, D-6 and D-7; QR1 backlog BLK-1..4;
ODS adoption decision.

### Behavior before
The fork inherited upstream deploy defaults: hybrid LiteLLM could silently
fallback local requests to cloud, Hermes dashboard TUI defaulted on, Qdrant
could run with an empty API key, and the repo had no QR1-specific profile,
UFW helper, acceptance helper or operator runbook.

### Behavior after
QR1 has a placeholder-only env profile, a LiteLLM config with fail-closed local
routes and exactly one external model (`anthropic/claude-sonnet-5`), a final
compose override that forces `HERMES_DASHBOARD_TUI=0`, requires non-empty
Qdrant/SearXNG secrets, routes apps to host-native Ollama, enables the shipped
Langfuse compose template, and profile-gates OpenClaw, ODS Tailscale,
ods-proxy and Brave Search. The ODS OpenCode host-systemd extension remains
excluded by not installing/enabling it. MS helper scripts discover Docker
subnets for UFW rules and run QR1 acceptance checks.

### Security / privacy impact
Positive. Local-only routes no longer have external fallbacks, dangerous QR1
components are excluded, Hermes PTY endpoints are disabled, Qdrant auth is
required, generated secrets are required for deploy, and Docker-to-host UFW
rules are limited to discovered private Docker CIDRs and ports 11434/7710.
No real secrets, client data, email/Jira/client-system credentials, production
secrets or unrestricted egress are added.

### Upgrade / upstream impact
Low. Changes are additive MS-owned profile/config/docs/scripts plus a QR1
compose override; no ODS core code or installer behavior is changed.

### Validation performed
Before PR:
- `python scripts/audit-extensions.py`
- `docker compose $(scripts/ms-qr1-compose-flags.sh) config`
- `bash tests/test-safe-env.sh`
- `bash tests/test-secret-security.sh`
- `python tests/contracts/test-network-exposure-contracts.py`
- `git diff --check`
- secret scan of changed files for real keys/tokens

Also run:
- `bash tests/test-network-security.sh`

That static script failed with 19 findings against broad optional compose files
and the ODS Tailscale host-network extension, while reporting 23 secure and 0
insecure port bindings. QR1 uses the explicit rendered QR1 compose file set
and `tests/contracts/test-network-exposure-contracts.py` for the deploy gate
because the static script does not model QR1 exclusions.

On EVO-X3 later:
- `EXPECTED_MODEL=<qr1-ollama-model> scripts/ms-qr1-acceptance.sh`
- UFW before/after and rollback evidence per `docs/ms/deploy/QR1-DEPLOY-RUNBOOK.md`

### Rollback
Repository rollback: revert the QR1 deployment-profile commit.

Host rollback after deployment: run `docker compose ... down`, `sudo tailscale
serve reset`, delete MS QR1 UFW rules by number in descending order, and shred
the filled `.env`, as documented in `docs/ms/deploy/QR1-DEPLOY-RUNBOOK.md`.

### Notes
Host-agent nmcli/Wi-Fi routes have no supported CONFIGURE switch in upstream
ODS. QR1 therefore documents and tests the unauthenticated 401/403 boundary
instead of making a core host-agent change.

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
