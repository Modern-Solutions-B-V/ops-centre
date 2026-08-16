# ODS -> MS Ops Centre Change History

This file is the canonical continuous history of Modern Solutions changes
to the upstream ODS-based platform.

Any behavioral, runtime, deployment, policy, security, routing or integration
change must be recorded here in the same commit/PR that makes the change.

---

## 2026-08-16 — Close QR1 final re-review gaps

### Change ID
`MSODS-0007`

### Agent / Author
Codex

### Branch / PR
`feature/qr1-stack` / PR #6

### ODS baseline
`v2.6.0`

### Classification
`CONFIGURE` + `EXTEND`

### Files changed
- `ods/docker-compose.ms-qr1.yml`
- `ods/scripts/ms-qr1-ufw-docker-rules.sh`
- `ods/scripts/ms-qr1-ollama-bridge.sh`
- `ods/scripts/ms-qr1-acceptance.sh`
- `ods/tests/test-ms-qr1-helpers.sh`
- `docs/ms/deploy/QR1-DEPLOY-RUNBOOK.md`
- `docs/ms/handovers/2026-08-16-qr1-stack-implementation.md`
- `docs/ms/ODS-MS-CHANGELOG.md`

### Reason
Resolve final re-review findings against commit `74c1f8c9` before QR1 approval.

### MS requirement / ADR
QR1 C3/H2 closure; host-native Ollama through the actual ODS Docker gateway;
machine-manageable UFW lifecycle; Ubuntu 24.04 deploy gates.

### Behavior before
Only three services had the `ms-qr1-host` alias, while `perplexica`,
`privacy-shield`, and `token-spy` inherited environment values pointing at
`ms-qr1-host`. UFW `remove` depended on currently discoverable Docker
networks, so stale rules could remain after network teardown or subnet drift.
The runbook hand-created `ods-network`, used `python` in gate commands, did
not install `python3-yaml`, and did not restart host-agent after gateway
recreation. The bridge plan emitted the first sorted gateway instead of the
gateway for the rendered network named `ods-network`.

### Behavior after
Every rendered service whose environment references `ms-qr1-host` must also
render an `extra_hosts` alias for it. UFW `remove` first deletes current
discovered rules and then sweeps `MS QR1 docker-to-host` commented rules from
`ufw status numbered` in descending numeric order, so cleanup still works
after Docker network loss or CIDR drift. The runbook creates networks through
Compose with `up --no-start`, force-recreates containers after the real
gateway is set, removes UFW rules before Compose teardown, installs/verifies
`python3-yaml`, uses `python3` for gates, and restarts host-agent after
network recreation. The bridge helper publishes `MS_QR1_HOST_GATEWAY` from
`ods-network` specifically and fails the systemd unit if its address list is
empty. `model-router` remains explicitly allowed as an inert/internal core
service; remote-provider egress and SSH tunnel remain excluded.

### Security / privacy impact
Positive. QR1 Docker-to-host access is more deterministic and has a safer
rollback path. The change does not bind Ollama or `socat` to `0.0.0.0`, does
not widen LAN/tailnet exposure, and adds no secrets.

### Upgrade / upstream impact
Low. Changes are QR1-owned compose override, helper scripts, tests and docs.
No upstream ODS core runtime change is made.

### Validation performed
- `make lint`
- `make test`
- `bash tests/test-ms-qr1-helpers.sh`
- individual `bash -n` on every new QR1 shell script
- full QR1 Compose render
- `python3 scripts/audit-extensions.py`
- `bash tests/test-safe-env.sh`
- `bash tests/test-secret-security.sh`
- `python3 tests/contracts/test-network-exposure-contracts.py`
- `git diff --check`
- changed-file secret scan

### Rollback
Repository rollback: revert the MSODS-0007 correction commit.

Host rollback if already deployed: run `sudo scripts/ms-qr1-ufw-docker-rules.sh
remove` before `docker compose ... down`, then remove Tailscale serve mappings,
the Ollama bridge, host-agent unit, and the filled `.env` per the latest
runbook.

### Notes
The ComfyUI corrupt-checkpoint regression keeps static assertions for the
pinned revision, SHA256, and `sha256sum -c -`, plus a fixture proving a corrupt
`.part` file is not promoted. It does not execute the runbook's copied
operator shell block directly because that block is documentation, not a
reusable provisioning script.

---

## 2026-08-16 — Harden QR1 final-review deployment boundary

### Change ID
`MSODS-0006`

### Agent / Author
Codex

### Branch / PR
`feature/qr1-stack` / PR #6

### ODS baseline
`v2.6.0`

### Classification
`CONFIGURE` + `EXTEND`

### Files changed
- `.github/workflows/lint-shell.yml`
- `.github/workflows/lint-python.yml`
- `.github/workflows/validate-compose.yml`
- `.github/workflows/secret-scan.yml`
- `.gitignore`
- `ods/Makefile`
- `ods/config/litellm/ms-qr1.yaml`
- `ods/docker-compose.ms-qr1.yml`
- `ods/profiles/ms-qr1.env.example`
- `ods/scripts/ms-qr1-compose-flags.sh`
- `ods/scripts/ms-qr1-ufw-docker-rules.sh`
- `ods/scripts/ms-qr1-ollama-bridge.sh`
- `ods/scripts/ms-qr1-acceptance.sh`
- `ods/tests/test-ms-qr1-helpers.sh`
- `docs/ms/backlog/QR2-BACKLOG.md`
- `docs/ms/deploy/QR1-DEPLOY-RUNBOOK.md`
- `docs/ms/handovers/2026-08-16-qr1-stack-implementation.md`
- `docs/ms/ODS-MS-CHANGELOG.md`

### Reason
Resolve independent final-review findings against commit `0718641c` before QR1
merge without touching EVO-X3, widening network exposure, or changing upstream
ODS core runtime code.

### MS requirement / ADR
QR1 cross-review D-6; local-only routes must not silently fall back externally;
Docker-to-host access must be scoped to the approved QR1 trust matrix.

### Behavior before
The QR1 acceptance helper still had parse-time and heredoc/stdin hazards. The
Ollama bridge listened on custom-network gateway IPs, but QR1 containers still
targeted `host.docker.internal`, which can resolve to the isolated default
Docker bridge. The generated systemd bridge unit did not escape runtime shell
variables for systemd and could render an empty `bind=`. UFW rollback depended
on manual rule-number deletion. UFW and bridge discovery included the internal
Langfuse network. The runbook tested a host-agent that it did not install,
used a moving ComfyUI checkpoint artifact without integrity verification, and
kept incomplete hard-coded acceptance port coverage. CI filters did not cover
PRs targeting `ms/main`.

### Behavior after
Containers use `ms-qr1-host:<MS_QR1_HOST_GATEWAY>` to reach the actual
non-internal ODS Docker gateway where the host-side Ollama bridge listens.
`ms-qr1-ollama-bridge.sh` renders quoted `Environment=` and literal `$$`
runtime variables, never wildcard listeners. UFW and bridge helpers select
rendered non-internal network names only, validate gateway/interface data, and
UFW has a machine-manageable `remove` action. The runbook installs the
host-agent before testing `7710`, pins and SHA256-verifies the SDXL Lightning
checkpoint before atomic promotion, and requires helper re-run after Docker
network recreation. Acceptance derives rendered published service ports,
checks the rendered service allow-list/exclusion policy, verifies the local
model tag matches `EXTERNAL_LLM_MODEL`, parses Ollama model JSON from an
environment variable, and probes container-to-host Ollama through
`ms-qr1-host`. PR CI now includes `ms/main`, and `make test` runs the QR1
helper regression suite.

### Security / privacy impact
Positive. QR1 host exposure remains limited to loopback-published services and
approved Docker-to-host paths on non-internal Docker networks. Internal
Langfuse containers do not receive host Ollama or host-agent access. Filled
profile files under `ods/profiles/*.env` are ignored by Git. The LiteLLM
master key is still shared with Open WebUI and Hermes in QR1; this limitation
is documented and tracked in the QR2 backlog for scoped consumer keys.

### Upgrade / upstream impact
Low. Changes are MS-owned configuration, docs, helper scripts, tests and CI
filters. The duplicate Langfuse compose copy was removed; QR1 now references
the upstream dormant Langfuse compose template directly. No ODS core change is
made.

### Validation performed
- `make lint`
- `bash tests/test-ms-qr1-helpers.sh`
- individual `bash -n` on every new QR1 shell script
- `docker compose --env-file profiles/ms-qr1.env.example $(./scripts/ms-qr1-compose-flags.sh) config`
- `python3 scripts/audit-extensions.py`
- `bash tests/test-safe-env.sh`
- `bash tests/test-secret-security.sh`
- `python3 tests/contracts/test-network-exposure-contracts.py`
- `git diff --check`
- changed-file secret scan

`bash tests/test-network-security.sh` remains diagnostic-only for QR1; it is
not a blocking deploy gate because it scans broad optional compose content
instead of the explicit QR1 rendered stack.

### Rollback
Repository rollback: revert the MSODS-0006 correction commit.

Host rollback if already deployed: run the latest runbook full rollback:
stop the compose stack, reset Tailscale serve, run
`sudo scripts/ms-qr1-ufw-docker-rules.sh remove`, run
`sudo scripts/ms-qr1-ollama-bridge.sh remove`, remove the host-agent systemd
unit, and shred the filled `.env`.

### Notes
No EVO-X3 deployment actions were performed. ComfyUI checkpoint metadata was
checked against Hugging Face for pinned revision
`c6c10e8716de60c7ef4eed6b89a06f67e772b374` and SHA256
`e0d996ee0013e79d9d3561f50fcafb9a17e3ff07b780358e3b66d67932c4d490`.

---

## 2026-08-16 — Correct QR1 deployment review findings

### Change ID
`MSODS-0005`

### Agent / Author
Codex

### Branch / PR
`feature/qr1-stack` / PR #6

### ODS baseline
`v2.6.0`

### Classification
`CONFIGURE` + `EXTEND`

### Files changed
- `ods/scripts/ms-qr1-ufw-docker-rules.sh`
- `ods/scripts/ms-qr1-ollama-bridge.sh`
- `ods/scripts/ms-qr1-acceptance.sh`
- `ods/tests/test-ms-qr1-helpers.sh`
- `ods/profiles/ms-qr1.env.example`
- `docs/ms/deploy/QR1-DEPLOY-RUNBOOK.md`
- `docs/ms/handovers/2026-08-16-qr1-stack-implementation.md`
- `docs/ms/ODS-MS-CHANGELOG.md`

### Reason
Resolve first-round review findings against QR1 PR #6 without touching EVO-X3
or widening network exposure.

### MS requirement / ADR
QR1 cross-review D-6; BLK-1..4; local-only routes must not silently fall back
or widen to LAN.

### Behavior before
QR1 containers were configured to use `host.docker.internal:11434`, but the
runbook did not make a loopback-only host Ollama listener reachable from
Docker. The UFW helper inspected Compose network keys rather than rendered
Docker network names and lost piped interface data to a Python heredoc. The
acceptance helper lost Ollama JSON the same way. The runbook started Compose
before the Langfuse ownership hook, did not provision the ComfyUI checkpoint,
kept a known-failing broad network-security script in the blocking gate,
probed host-agent nmcli endpoints on loopback instead of the resolved Linux
bind address, and documented rollback for only one UFW rule. The Langfuse DB
password placeholder used standard base64, which can contain URL-unsafe `/`.

### Behavior after
QR1 installs an explicit, removable `ms-qr1-ollama-bridge.service` that binds
only discovered Docker gateway IP address(es) on port 11434 and forwards to
`127.0.0.1:11434`; Ollama itself remains loopback-only and is never bound to
`0.0.0.0`. The UFW helper uses rendered Compose network names and validates
CIDRs against host interface data without stdin loss. The acceptance helper
feeds Ollama model JSON through an environment variable and probes host-agent
nmcli routes at the resolved bind address. The runbook provisions Langfuse
ownership and the SDXL checkpoint before service start, creates networks
without starting containers, installs the Ollama bridge and UFW rules before
starting containers, records every UFW rule for descending-order rollback, and
treats `test-network-security.sh` as diagnostic only. Langfuse DB passwords
now use hex placeholders.

### Security / privacy impact
Positive. The Ollama connectivity fix is limited to Docker gateway addresses
plus Docker-CIDR UFW rules; it does not expose Ollama on LAN, tailnet, or
`0.0.0.0`. Rollback now removes every QR1 firewall rule and the bridge service.

### Upgrade / upstream impact
Low. Changes are additive MS-owned scripts/tests/docs/profile updates. No ODS
core runtime or installer code is changed.

### Validation performed
- `bash tests/test-ms-qr1-helpers.sh`
- `docker compose --env-file profiles/ms-qr1.env.example $(./scripts/ms-qr1-compose-flags.sh) config`
- `python ods/scripts/audit-extensions.py`
- `bash tests/test-safe-env.sh`
- `bash tests/test-secret-security.sh`
- `python tests/contracts/test-network-exposure-contracts.py`
- `git diff --check`
- secret scan of changed files for real keys/tokens

Correction recorded by MSODS-0006: the prior multi-file `bash -n` invocation
was structurally inadequate because Bash syntax-checks only the first script
argument and treats the rest as positional parameters. It therefore did not
prove `ods/scripts/ms-qr1-acceptance.sh` parsed successfully. MSODS-0006
replaces this with per-file syntax checks and a regression fixture that proves
broken shell syntax fails the QR1 helper suite.

`bash tests/test-network-security.sh` remains diagnostic-only for QR1; it is
not a blocking gate until it can be scoped to the explicit QR1 compose file
set.

### Rollback
Repository rollback: revert the MSODS-0005 correction commit.

Host rollback if already deployed: follow the latest runbook. MSODS-0006
replaces manual UFW rule-number deletion with `sudo
scripts/ms-qr1-ufw-docker-rules.sh remove`.

### Notes
The host-agent nmcli surface still has no upstream CONFIGURE switch. QR1 keeps
stock behavior and tests unauthenticated denial at the resolved bind address.

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
ods-proxy, Brave Search, remote-provider egress and remote-provider SSH
tunnel. The ODS OpenCode host-systemd extension remains excluded by not
installing/enabling it. MS helper scripts discover Docker
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
