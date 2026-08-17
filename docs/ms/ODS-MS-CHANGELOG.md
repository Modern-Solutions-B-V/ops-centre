# ODS -> MS Ops Centre Change History

This file is the canonical continuous history of Modern Solutions changes
to the upstream ODS-based platform.

Any behavioral, runtime, deployment, policy, security, routing or integration
change must be recorded here in the same commit/PR that makes the change.

---

## 2026-08-17 — Correct QR1 acceptance false positives for Tailscale Serve and Hermes auth redirect

### Change ID
`MSODS-0013`

### Agent / Author
Codex

### Branch / PR
`fix/qr1-acceptance-tailscale-hermes` / PR #9

### ODS baseline
`v2.6.0`

### Classification
`EXTEND`

### Files changed
- `ods/scripts/ms-qr1-acceptance.sh`
- `ods/tests/test-ms-qr1-helpers.sh`
- `docs/ms/deploy/QR1-DEPLOY-RUNBOOK.md`
- `docs/ms/handovers/2026-08-16-qr1-stack-implementation.md`
- `docs/ms/ODS-MS-CHANGELOG.md`

### Reason
Live EVO-X3 qualification reached the blocking QR1 acceptance gate after:

- HTTP Ollama bridge replacement passed.
- Container default-Host Ollama routing through `ms-qr1-host:11434` passed for
  `litellm`, `perplexica`, `privacy-shield` and `token-spy`.
- UFW and listener architecture passed by direct inspection.
- Full QR1 stack was healthy.
- Hermes post-start refresh passed.
- Hermes was healthy and host port `9119` remained unbound.

The first acceptance execution reported 13 checks passing and 2 blocking
false-positive assumptions:

1. Approved host Tailscale Serve listeners on tailnet IPv4/IPv6 port `11434`
   were classified as non-gateway QR1 Ollama bridge binds even though
   `tailscale serve status` showed they forward to `tcp://127.0.0.1:11434`.
2. Hermes proxy unauthenticated `/api/pty` returned the documented Caddy auth
   redirect `303 Location: /auth/required`, while acceptance only allowed
   direct `401`, `403` or `404`.

### Behavior before
`check_live_listeners_loopback_and_bridge_no_wildcard` treated every `:11434`
listener other than loopback or discovered Docker gateway address(es) as a QR1
bridge violation. `check_hermes_tui` rejected any unauthenticated Hermes proxy
response outside `401`, `403` or `404`.

### Behavior after
The listener check still rejects wildcard `0.0.0.0:11434` / `[::]:11434` and
arbitrary LAN or non-gateway listeners. It now exempts an extra `:11434`
listener only when its exact address is assigned to `tailscale0` and
`tailscale serve status` shows that same logical TCP `11434` Serve mapping
forwards to `tcp://127.0.0.1:11434`. Malformed, duplicate or ambiguous Serve
output is fail-closed. If Tailscale Serve is absent or cannot prove the mapping,
no extra listener is exempted.

The Hermes check still requires host port `9119` to be unbound and still fails
unauthenticated `200`. It now accepts `303` only with exact
`Location: /auth/required`, matching the reviewed Caddy auth contract, and does
not follow redirects. A `303` must contain exactly one `Location` header; zero,
duplicate or absolute/query redirects fail.

### Security / privacy impact
Neutral to positive. This is an acceptance-contract correction only. It does
not modify the Ollama HTTP proxy, Ollama binding, Tailscale Serve state,
Caddyfile, Hermes configuration, Compose architecture, UFW or persistent-state
lifecycle. The Tailscale exemption is fail-closed and cannot become a generic
process-name or arbitrary `11434` listener bypass.

### Qualification status
Local/static validation passed for this corrective branch. EVO-X3 hardware
qualification remains **PENDING** until the corrected blocking acceptance gate
itself returns zero. EVO-X3 was not modified by this PR.

### Validation performed
- `bash ods/tests/test-ms-qr1-helpers.sh`
- `for f in ods/scripts/ms-qr1-acceptance.sh ods/tests/test-ms-qr1-helpers.sh; do bash -n "$f"; done`
- `(cd ods && PYTHONPYCACHEPREFIX=/tmp/ms-qr1-lint-pycache make lint)`
- `(cd ods && MS_QR1_HOST_GATEWAY=127.0.0.1 docker compose --env-file profiles/ms-qr1.env.example $(scripts/ms-qr1-compose-flags.sh) config >/tmp/qr1-compose.rendered.yml)`
- `(cd ods && python3 tests/contracts/test-network-exposure-contracts.py)`
- `git diff --check`
- `rg -n "(sk-[A-Za-z0-9]{16,}|AKIA[0-9A-Z]{16}|BEGIN (RSA|OPENSSH|PRIVATE)|[A-Za-z0-9_]*(PASSWORD|SECRET|TOKEN|API_KEY)[A-Za-z0-9_]*=[^<[:space:]]+)" docs/ms/ODS-MS-CHANGELOG.md docs/ms/deploy/QR1-DEPLOY-RUNBOOK.md docs/ms/handovers/2026-08-16-qr1-stack-implementation.md ods/scripts/ms-qr1-acceptance.sh ods/tests/test-ms-qr1-helpers.sh`

### Rollback
Repository rollback: revert the MSODS-0013 commit. Host rollback is not
required because this change only adjusts acceptance checks and documentation.

---

## 2026-08-17 — Fix QR1 Ollama bridge systemd WorkingDirectory rendering

### Change ID
`MSODS-0012`

### Agent / Author
Codex

### Branch / PR
`fix/qr1-systemd-workingdirectory` / PR pending

### ODS baseline
`v2.6.0`

### Classification
`EXTEND`

### Files changed
- `ods/scripts/ms-qr1-ollama-bridge.sh`
- `ods/tests/test-ms-qr1-helpers.sh`
- `docs/ms/deploy/QR1-DEPLOY-RUNBOOK.md`
- `docs/ms/handovers/2026-08-16-qr1-stack-implementation.md`
- `docs/ms/ODS-MS-CHANGELOG.md`

### Reason
Live EVO-X3 Ubuntu 24.04 qualification of merged `ms/main` commit `c8cc43fb`
reached the QR1 Ollama bridge replacement step and stopped because the rendered
systemd unit was invalid on the target host:

```ini
WorkingDirectory="/home/modi/ms-ops/ops-centre/ods"
ExecStart="/usr/local/libexec/ms-qr1/ms-qr1-ollama-bridge.sh" serve
```

`systemd-analyze verify` reported `WorkingDirectory= path is not absolute`
because Ubuntu systemd treated the literal quotes as part of the path. A
temporary copy changed only `WorkingDirectory=` to the unquoted absolute path,
and `sudo systemd-analyze verify /tmp/ms-qr1-ollama-bridge.fixed.service`
returned `VERIFY_RC=0`. `ExecStart="..." serve` was accepted and is preserved.

### Behavior before
`scripts/ms-qr1-ollama-bridge.sh render-unit` applied the systemd ExecStart
quoting helper to `WorkingDirectory=`, producing literal wrapping quotes around
the checkout path.

### Behavior after
`render-unit` renders `WorkingDirectory=` as the plain absolute checkout path
accepted by Ubuntu 24.04 systemd, while keeping the existing quoted
`ExecStart="/usr/local/libexec/ms-qr1/ms-qr1-ollama-bridge.sh" serve`.

### Security / privacy impact
Neutral. The fix changes only systemd unit rendering for `WorkingDirectory=`.
It does not change root-owned immutable files under `/usr/local/libexec/ms-qr1`,
HTTP proxy behavior, gateway discovery, listener scope, systemd hardening,
UFW behavior, Ollama loopback binding, or Tailscale Serve behavior.

### Qualification status
Local/static validation passed for this corrective branch. EVO-X3 hardware
qualification remains **PENDING** and stopped before replacing the running
legacy socat bridge.

### Validation performed
- `bash ods/tests/test-ms-qr1-helpers.sh`
- Linux-only helper regression:
  `systemd-analyze verify "$tmpdir/ms-qr1-ollama-bridge.rendered.service"`
  when `systemd-analyze` is available
- `for f in ods/scripts/ms-qr1-ollama-bridge.sh ods/tests/test-ms-qr1-helpers.sh; do bash -n "$f"; done`
- `(cd ods && PYTHONPYCACHEPREFIX=/tmp/ms-qr1-make-pycache make lint)`
- `python3 ods/scripts/ms-qr1-ollama-http-proxy.py --self-test`
- `(cd ods && MS_QR1_HOST_GATEWAY=127.0.0.1 docker compose --env-file profiles/ms-qr1.env.example $(scripts/ms-qr1-compose-flags.sh) config)`
- `git diff --check`
- `rg -n "(sk-[A-Za-z0-9]{16,}|AKIA[0-9A-Z]{16}|BEGIN (RSA|OPENSSH|PRIVATE)|[A-Za-z0-9_]*(PASSWORD|SECRET|TOKEN|API_KEY)[A-Za-z0-9_]*=[^<[:space:]]+)" docs/ms/ODS-MS-CHANGELOG.md docs/ms/deploy/QR1-DEPLOY-RUNBOOK.md docs/ms/handovers/2026-08-16-qr1-stack-implementation.md ods/scripts/ms-qr1-ollama-bridge.sh ods/tests/test-ms-qr1-helpers.sh`

### Rollback
Repository rollback: revert the MSODS-0012 commit. Host rollback is not
required unless the bridge was installed from this branch; if installed, run
`sudo scripts/ms-qr1-ollama-bridge.sh remove` to remove the service and
installed bridge files.

---

## 2026-08-17 — Fix live QR1 clean-host deployment defects

### Change ID
`MSODS-0011`

### Agent / Author
Codex

### Branch / PR
`fix/qr1-ollama-http-proxy` / PR pending

### ODS baseline
`v2.6.0`

### Classification
`EXTEND`

### Files changed
- `ods/scripts/ms-qr1-ollama-bridge.sh`
- `ods/scripts/ms-qr1-ollama-http-proxy.py`
- `ods/scripts/ods-verify-quiescent-data-writers.sh`
- `ods/scripts/ms-qr1-prestart-provision.sh`
- `ods/scripts/ms-qr1-acceptance.sh`
- `ods/lib/rootless-ownership.sh`
- `ods/extensions/services/langfuse/hooks/post_install.sh`
- `ods/extensions/services/langfuse/README.md`
- `ods/extensions/services/n8n/README.md`
- `ods/tests/test-ms-qr1-helpers.sh`
- `docs/ms/decisions/QR1-QUIESCENT-PRIVILEGED-PROVISIONING.md`
- `docs/ms/deploy/QR1-DEPLOY-RUNBOOK.md`
- `docs/ms/handovers/2026-08-16-qr1-stack-implementation.md`
- `docs/ms/backlog/GENERIC-ODS-LIFECYCLE-HARDENING.md`
- `AGENTS.md`
- `docs/ms/ODS-MS-CHANGELOG.md`

### Reason
Live QR1 CP-12 qualification and the first clean EVO-X3 deployment exposed
three deployment blockers:

1. The raw TCP Ollama bridge kept `Host: ms-qr1-host:11434`, which
   host-native Ollama rejected with HTTP `403`. The same request succeeded
   when the Host header was `localhost:11434` or `127.0.0.1:11434`.
2. The first Compose start evaluated the Hermes file bind mount before
   `data/persona/SOUL.md` existed, so Docker created that source path as a
   directory and Hermes failed with a not-a-directory mount error.
3. Clean-host `data/n8n` was root-owned while rendered QR1 n8n ran as the
   configured non-root UID/GID, causing `EACCES` while n8n opened
   `/home/node/.n8n/config`.

### Behavior before
`ms-qr1-ollama-bridge.service` used `socat` TCP forwarding from discovered
Docker gateway IP address(es) to `127.0.0.1:11434`. TCP forwarding preserved
the client Host header and the rendered systemd unit captured listener
addresses at install time. The QR1 runbook reached `docker compose up
--no-start` before generating `data/persona/SOUL.md` or correcting
`data/n8n` ownership, even though `up --no-start` still creates containers and
evaluates bind mounts.

### Behavior after
`ms-qr1-ollama-bridge.service` starts the QR1 HTTP proxy through an installed
root-owned copy of `ms-qr1-ollama-bridge.sh` under
`/usr/local/libexec/ms-qr1/`; install/update refreshes both the bridge and
proxy executable copies plus the compose-flags helper it invokes, and remove
deletes them. The unit no longer executes mutable deploy-user checkout code.
Each service start rediscovers approved
non-internal Docker gateway IP address(es), binds only those addresses on TCP
`11434`, forwards only to `127.0.0.1:11434`, rewrites upstream Host to
`localhost:11434`, and relays streaming/chunked Ollama responses incrementally
with `HTTPResponse.read1(...)`. It rejects malformed request framing, streams
request bodies upstream in bounded 8192 byte reads, caps request bodies at
`268435456` bytes by default, closes downstream promptly when a fixed-length
upstream response is truncated, and uses a configurable `300` second upstream
timeout. `OLLAMA_HOST=127.0.0.1:11434`, UFW Docker-to-host rules, and host
Tailscale Serve behavior are unchanged.

`docs/ms/decisions/QR1-QUIESCENT-PRIVILEGED-PROVISIONING.md` records the
architectural decision that privileged filesystem mutation must not operate
against container-writable persistent state while a writer container is
running. The previous incremental hardening approach was abandoned because
pre-scan and mutation happen at different moments in time, container-writable
paths can change between them, root pathname resolution creates recurring
TOCTOU variants, and the growing mitigation framework became harder to audit
than the lifecycle boundary it was trying to replace.

`scripts/ms-qr1-prestart-provision.sh prestart-init` is now the explicit
idempotent QR1 initialization/repair gate. It runs before any Compose `up`,
including `up --no-start`; derives the relevant writer containers from the
rendered Compose writable bind mounts intersecting `data/n8n`,
`data/persona`, or `data/langfuse`; fails closed before mutation if any writer
of the affected data paths is running; ensures `data/persona` exists and is
operator-owned; fails closed if `data/persona` or `data/persona/SOUL.md` is a
symlink; repairs an empty Docker-created `data/persona/SOUL.md` directory only
behind verified quiescence; refuses non-empty directories; generates the
persona through the existing `scripts/build-installation-context.py` into a
same-directory temporary file; and atomically replaces `SOUL.md`. It resolves
n8n's effective numeric UID/GID from the rendered Compose configuration,
creates only `data/n8n`, and corrects only that directory tree to strict
owner-only pre-start modes.

The `check` action is intentionally read-only and suitable for the blocking
acceptance gate. It validates the runtime invariant recursively instead of
exact pre-start modes, so n8n-created `0644` files and `0755` directories pass
while wrong owners, missing owner-write, missing owner-search on directories,
group/world write bits, symlinks, and unexpected file types fail. It performs
no chown, chmod, file replacement or repair.

After Compose startup, `scripts/ms-qr1-prestart-provision.sh poststart-refresh`
must run as the deployment user, reruns the existing builder, atomically
replaces `data/persona/SOUL.md`, recreates `hermes` and `hermes-proxy` through
`docker compose $(scripts/ms-qr1-compose-flags.sh) up -d --no-deps
--force-recreate ...`, waits for Docker health on `ods-hermes`, syncs the
repository-supported persistent persona path with
`docker exec ods-hermes cp /opt/hermes/docker/SOUL.md /opt/data/SOUL.md`,
restarts Hermes so it reloads persistent persona state, waits for Docker
health again, and then recreates `hermes-proxy`. It no longer probes
`127.0.0.1:9119` because QR1 intentionally keeps Hermes host port `9119`
unbound.

The QR1 runbook now has one authoritative repair path for container-writable
MS data: derive writer services, stop them through Compose, verify quiescence,
then run privileged hooks/helpers. The previous manual `rm`/`chown` persona
recovery path and best-effort `|| true` writer stop were removed.

Scope correction: the QR1 quiescence ADR is binding for MS Ops Centre QR1
deployment, repair and acceptance paths only. `scripts/ods-verify-quiescent-data-writers.sh`
is retained as the read-only writer-derivation helper used by QR1; QR1 invokes
it with the canonical complete QR1 Compose model from
`scripts/ms-qr1-compose-flags.sh`, so caller-supplied
`ODS_QUIESCENCE_COMPOSE_FLAGS` or target overrides cannot remove base writers
from QR1 mutation-boundary checks. The previous attempt to enforce this QR1
decision unconditionally in generic Langfuse and Docker-rootless lifecycle
paths was removed from this PR. Generic ODS lifecycle issues discovered during
review are documented in
`docs/ms/backlog/GENERIC-ODS-LIFECYCLE-HARDENING.md` and are not claimed fixed
here.

### Security / privacy impact
Positive. The fix does not widen listener scope or add external fallback
paths. It removes a raw TCP bridge in favor of a QR1-scoped HTTP proxy with a
fixed loopback upstream and explicit Host rewrite. The n8n ownership repair is
scoped to the `data/n8n` tree only, is allowed only while rendered writer
containers are stopped, and does not recursively chown unrelated data paths or
use world-writable permissions. Runtime acceptance checks are read-only.
Acceptance now captures `ss -tlnp` before listener parsing and fails if the
listener snapshot cannot be collected.

### Privileged-operation audit
Bounded QR1 audit reviewed paths executed by the QR1 deployment runbook and QR1
acceptance flow. In QR1, container-writable MS data mutation happens only after
the runbook derives QR1 writer services from the complete QR1 Compose model,
stops them, and verifies no corresponding writer container is running. Runtime
`check` and QR1 acceptance remain read-only. Generic host-agent/rootless,
installer rerun, purge and uninstall mutation paths were reviewed only to
classify whether QR1 invokes them; they are deferred in the lifecycle-hardening
backlog rather than claimed remediated by this QR1 PR.

Call-path audit for QR1 privileged persistent-state mutation:

- `data/langfuse/postgres`, `data/langfuse/clickhouse`: ownership repair
  through `extensions/services/langfuse/hooks/post_install.sh`, invoked by the
  QR1 runbook only after QR1 `writer-services`, Compose stop and
  `verify-quiescent` have passed. Possible QR1 writers are rendered writable
  bind mounts intersecting `data/langfuse`, including broad `./data` writers
  such as `dashboard-api` and Langfuse state containers. Enforcement point for
  QR1 is the runbook-owned stop/verify gate immediately before the hook call.
- `data/persona`, `data/persona/SOUL.md`: owner repair, empty Docker-created
  directory repair, and atomic persona replacement happen through
  `scripts/ms-qr1-prestart-provision.sh prestart-init`; post-start refresh is
  unprivileged. Possible writers are rendered writable bind mounts
  intersecting `data/persona`, including broad `./data` writers. Enforcement
  point: `prestart-init` invokes its own writer-container gate before mutation.
- `data/n8n`: ownership/mode normalization happens only through
  `scripts/ms-qr1-prestart-provision.sh prestart-init`. Possible writers are
  rendered writable bind mounts intersecting `data/n8n`, including n8n and
  broad `./data` writers. Enforcement point: `prestart-init` invokes its own
  writer-container gate before mutation.

Generic findings classified but deferred:

- `MSODS-LIFE-0001`: host-agent Docker-rootless ownership repair. QR1
  invocation: no for EVO-X3 QR1/rootful Docker; deferred.
- `MSODS-LIFE-0002`: dashboard-driven Langfuse setup quiescence. QR1
  invocation: only through the QR1 runbook after QR1 stop/verify; generic
  dashboard orchestration deferred.
- `MSODS-LIFE-0003`: generic/rootful installer rerun ownership repair. QR1
  invocation: no; deferred.
- `MSODS-LIFE-0004`: `ods purge` quiescence. QR1 invocation: no; deferred.
- `MSODS-LIFE-0005`: `ods-uninstall.sh` writer termination. QR1 invocation:
  no; deferred.

### Upgrade / upstream impact
Low. The corrective behavior is QR1-scoped. Generic ODS Langfuse setup and
Docker-rootless lifecycle semantics are not redesigned by this PR; generic
findings are documented for later upstream/lifecycle hardening.

### Qualification status
Local/static/CI validation passed for this corrective branch. Hardware-backed
EVO-X3 validation of the corrective proxy/provisioner is **PENDING** and
deferred until after merge. The current EVO-X3 host remains on the previous
merged baseline, and operational readiness is not claimed for this corrective
branch.

Pending post-merge EVO-X3 live qualification steps:

1. Pull merged `ms/main`.
2. Stop relevant writer containers and run corrected `prestart-init`.
3. Replace/restart the old bridge with the reviewed HTTP proxy.
4. Verify the proxy systemd service actually starts under its sandbox, with
   `systemctl status ms-qr1-ollama-bridge.service --no-pager` and
   `journalctl -u ms-qr1-ollama-bridge.service -n 50 --no-pager`.
5. Verify listener scope remains gateway-only with no wildcard listener.
6. Verify LiteLLM -> Ollama default-Host `/api/tags` returns HTTP `200`.
7. Verify dashboard-api -> Ollama default-Host `/api/tags` returns HTTP `200`.
8. Verify live streaming first-token behavior through the proxy.
9. Verify n8n remains healthy after normalization.
10. Verify Hermes post-start persona refresh recreates Hermes, syncs
    `/opt/data/SOUL.md`, and Hermes reads the refreshed persona.
11. Verify UFW/default-deny posture is unchanged.
12. Run full QR1 acceptance.

These items are pending live qualification, not PASS evidence.

### Validation performed
- `python3 ods/scripts/ms-qr1-ollama-http-proxy.py --self-test`
- `bash ods/tests/test-ms-qr1-helpers.sh`
- `bash ods/scripts/ods-verify-quiescent-data-writers.sh --help`
- `(cd ods && PYTHONPYCACHEPREFIX=/tmp/ms-qr1-make-pycache make lint)`
- `RUFF_CACHE_DIR=/tmp/ms-qr1-ruff-cache /tmp/ms-qr1-ruff/bin/ruff check ods/ --select E,F,W --ignore E501,E701,E731,E741,E402`
- `for f in ods/scripts/ods-verify-quiescent-data-writers.sh ods/scripts/ms-qr1-ollama-bridge.sh ods/scripts/ms-qr1-prestart-provision.sh ods/scripts/ms-qr1-acceptance.sh ods/extensions/services/langfuse/hooks/post_install.sh ods/lib/rootless-ownership.sh ods/tests/test-ms-qr1-helpers.sh; do bash -n "$f"; done`
- `(cd ods && bash scripts/validate-env.sh profiles/ms-qr1.env.example)`
- `PYTHONPYCACHEPREFIX=/tmp/ms-qr1-pycache python3 -m py_compile ods/scripts/ms-qr1-ollama-http-proxy.py ods/bin/ods-host-agent.py`
- `(cd ods && MS_QR1_HOST_GATEWAY=127.0.0.1 docker compose --env-file profiles/ms-qr1.env.example $(scripts/ms-qr1-compose-flags.sh) config)`
- `(cd ods && tmpdir="$(mktemp -d /tmp/generic-langfuse-compose.XXXXXX)" && cp extensions/services/langfuse/compose.yaml.disabled "$tmpdir/compose.yaml" && docker compose --env-file profiles/ms-qr1.env.example -f docker-compose.base.yml -f docker-compose.amd.yml -f extensions/services/ape/compose.yaml -f extensions/services/comfyui/compose.yaml -f extensions/services/comfyui/compose.amd.yaml -f extensions/services/embeddings/compose.yaml -f extensions/services/hermes/compose.yaml -f extensions/services/hermes-proxy/compose.yaml -f "$tmpdir/compose.yaml" -f extensions/services/litellm/compose.yaml -f extensions/services/n8n/compose.yaml -f extensions/services/perplexica/compose.yaml -f extensions/services/privacy-shield/compose.yaml -f extensions/services/qdrant/compose.yaml -f extensions/services/searxng/compose.yaml -f extensions/services/token-spy/compose.yaml -f extensions/services/tts/compose.yaml -f extensions/services/whisper/compose.yaml -f docker-compose.ms-qr1.yml config >/tmp/generic-langfuse-compose.rendered.yml)`
- `(cd ods && python3 tests/contracts/test-network-exposure-contracts.py)`
- `git diff --check`
- `rg -n "(sk-[A-Za-z0-9]{16,}|AKIA[0-9A-Z]{16}|BEGIN (RSA|OPENSSH|PRIVATE)|[A-Za-z0-9_]*(PASSWORD|SECRET|TOKEN|API_KEY)[A-Za-z0-9_]*=[^<[:space:]]+)" AGENTS.md docs/ms/ODS-MS-CHANGELOG.md docs/ms/backlog/GENERIC-ODS-LIFECYCLE-HARDENING.md docs/ms/decisions/QR1-QUIESCENT-PRIVILEGED-PROVISIONING.md docs/ms/deploy/QR1-DEPLOY-RUNBOOK.md docs/ms/handovers/2026-08-16-qr1-stack-implementation.md ods/extensions/services/langfuse/README.md ods/extensions/services/langfuse/hooks/post_install.sh ods/extensions/services/n8n/README.md ods/lib/rootless-ownership.sh ods/scripts/ods-verify-quiescent-data-writers.sh ods/scripts/ms-qr1-acceptance.sh ods/scripts/ms-qr1-ollama-bridge.sh ods/scripts/ms-qr1-ollama-http-proxy.py ods/scripts/ms-qr1-prestart-provision.sh ods/tests/test-ms-qr1-helpers.sh`

### Rollback
Repository rollback: revert the MSODS-0011 commit.

Host rollback if already deployed:

```bash
cd ~/ms-ops/ops-centre/ods
sudo scripts/ms-qr1-ollama-bridge.sh remove
sudo systemctl daemon-reload
ss -tlnp | grep ':11434' || true
```

Expected rollback: only host-native Ollama remains on `127.0.0.1:11434`; no
`ms-qr1-ollama-bridge.service` unit or Docker-gateway `11434` listener remains.
For the provisioning helper, repository rollback removes the new pre-start
gate. Host data rollback is normally not needed because `data/persona/SOUL.md`
is generated from repository templates and `data/n8n` ownership is the
required runtime owner for the rendered n8n service. If a failed pre-fix run
left `data/persona/SOUL.md` as a directory, use the canonical lifecycle:
derive writer services, stop them, run `scripts/ms-qr1-prestart-provision.sh
verify-quiescent`, run `sudo scripts/ms-qr1-prestart-provision.sh
prestart-init`, then restart/recreate the required services. Do not manually
remove, chown, or chmod container-writable MS data outside that lifecycle.

---

## 2026-08-16 — Fix QR1 placeholder acceptance gate

### Change ID
`MSODS-0010`

### Agent / Author
Codex

### Branch / PR
`feature/qr1-stack` / PR #6

### ODS baseline
`v2.6.0`

### Classification
`EXTEND`

### Files changed
- `ods/scripts/ms-qr1-acceptance.sh`
- `ods/tests/test-ms-qr1-helpers.sh`
- `docs/ms/deploy/QR1-DEPLOY-RUNBOOK.md`
- `docs/ms/handovers/2026-08-16-qr1-stack-implementation.md`
- `docs/ms/ODS-MS-CHANGELOG.md`

### Reason
Resolve the final QR1 acceptance-gate defect where placeholder detection also
matched comments copied from `profiles/ms-qr1.env.example` into `.env`.

### Behavior before
`check_no_placeholders` and the runbook placeholder command searched for
`CHANGEME` or `GENERATE_ME` anywhere in `.env`, so explanatory comments could
fail acceptance even after every assignment value had been replaced.

### Behavior after
QR1 placeholder detection only inspects assignment values with the anchored
pattern `^[A-Za-z_][A-Za-z0-9_]*=.*(CHANGEME|GENERATE_ME)`. The helper
regression suite enumerates placeholder tokens from actual profile assignment
values, fills every known token with safe dummy values, proves
`check_no_placeholders` passes, restores one placeholder value, and proves the
check fails.

### Security / privacy impact
Positive. The gate still blocks real placeholder values while avoiding false
failures from comments. No secrets are added.

### Upgrade / upstream impact
Low. QR1 acceptance helper, QR1 tests, and QR1 runbook only.

### Validation performed
- `make lint`
- `bash tests/test-ms-qr1-helpers.sh`
- individual `bash -n` on QR1 shell scripts and helper test
- `bash scripts/validate-env.sh profiles/ms-qr1.env.example`
- full QR1 Compose render
- `python3 tests/contracts/test-network-exposure-contracts.py`
- `git diff --check`
- changed-file secret scan

### Rollback
Repository rollback: revert the MSODS-0010 correction commit.

---

## 2026-08-16 — Document QR1 jq validation prerequisite

### Change ID
`MSODS-0009`

### Agent / Author
Codex

### Branch / PR
`feature/qr1-stack` / PR #6

### ODS baseline
`v2.6.0`

### Classification
`CONFIGURE` + `EXTEND`

### Files changed
- `docs/ms/deploy/QR1-DEPLOY-RUNBOOK.md`
- `docs/ms/handovers/2026-08-16-qr1-stack-implementation.md`
- `docs/ms/ODS-MS-CHANGELOG.md`
- `ods/tests/test-ms-qr1-helpers.sh`

### Reason
Resolve the remaining Codex-bot finding that QR1 deploy documentation added
`validate-env.sh` as a gate without documenting its `jq` host dependency.

### Behavior before
The QR1 runbook installed and verified `python3-yaml` on clean Ubuntu 24.04
hosts, but did not install or verify `jq`. `scripts/validate-env.sh` requires
`jq` and exits before schema validation if it is absent.

### Behavior after
The QR1 runbook installs `jq` alongside `python3-yaml`, verifies it with
`jq --version`, and records `jq` in expected evidence. The QR1 helper
regression suite asserts that the documented prerequisite set covers the
`validate-env.sh` dependency.

### Security / privacy impact
Positive. The QR1 gate is now reproducible on clean deploy hosts without
weakening validation or exposing secrets.

### Upgrade / upstream impact
Low. Documentation and QR1 regression coverage only.

### Validation performed
- `bash tests/test-ms-qr1-helpers.sh`
- `bash scripts/validate-env.sh profiles/ms-qr1.env.example`
- `docker compose --env-file profiles/ms-qr1.env.example $(scripts/ms-qr1-compose-flags.sh) config`
- `git diff --check`
- changed-file secret scan

### Rollback
Repository rollback: revert the MSODS-0009 correction commit. Host rollback:
none required; `jq` is a read-only validation prerequisite.

---

## 2026-08-16 — Close QR1 Codex final-review gaps

### Change ID
`MSODS-0008`

### Agent / Author
Codex

### Branch / PR
`feature/qr1-stack` / PR #6

### ODS baseline
`v2.6.0`

### Classification
`CONFIGURE` + `EXTEND`

### Files changed
- `ods/.env.schema.json`
- `ods/scripts/ms-qr1-acceptance.sh`
- `ods/scripts/ms-qr1-ufw-docker-rules.sh`
- `ods/scripts/ms-qr1-ollama-bridge.sh`
- `ods/tests/test-ms-qr1-helpers.sh`
- `docs/ms/deploy/QR1-DEPLOY-RUNBOOK.md`
- `docs/ms/handovers/2026-08-16-qr1-stack-implementation.md`
- `docs/ms/ODS-MS-CHANGELOG.md`

### Reason
Resolve GitHub Codex review findings against commit `1f9758be` before final
QR1 review.

### MS requirement / ADR
QR1 acceptance must distinguish HTTP authorization denials from transport
failures, restart the Ollama bridge after unit replacement, validate the
complete UFW Docker-to-host rule set, and keep the QR1 profile aligned with
the canonical environment schema.

### Behavior before
QR1 acceptance used `curl -f` for negative authorization checks, so expected
`401`, `403`, and `404` responses were reported as curl failures. The Ollama
bridge install path reloaded systemd and enabled the unit, but did not restart
an already-running service after a regenerated unit. UFW acceptance only
checked that at least one QR1-commented rule existed. The QR1 profile
contained legitimate QR1 keys that were absent from `.env.schema.json`, so
`validate-env.sh profiles/ms-qr1.env.example` rejected the profile.

### Behavior after
Authorization-boundary checks read and assert HTTP status codes without
`curl -f` while still failing on transport errors. The bridge helper restarts
`ms-qr1-ollama-bridge.service` after installing the rendered unit and running
`daemon-reload`. UFW acceptance compares the full expected rule set from the
QR1 UFW helper with `ufw status numbered`, including source CIDR, destination
gateway, and both ports `11434` and `7710`, and fails on missing, stale, or
unparseable QR1 rules. The QR1-specific environment variables consumed by the
profile and compose/runtime configuration are now represented in
`.env.schema.json`, and QR1 helper tests validate a safely filled throwaway
profile.

### Security / privacy impact
Positive. The QR1 deploy gate now catches incomplete firewall state and
schema drift, while authorization-negative checks no longer conflate expected
HTTP denial with network failure. No secrets are added and no network exposure
is widened.

### Upgrade / upstream impact
Low. The environment schema extension is additive. Runtime changes remain
scoped to QR1 helper scripts, tests, and deployment documentation.

### Validation performed
- `make lint`
- `make test` ran through the QR1 helper suite and later failed in
  `bootstrap-upgrade compose-flags recovery` because this macOS validation
  host does not provide `flock`; the failure is outside QR1 and was not
  introduced by this change.
- `bash tests/test-ms-qr1-helpers.sh`
- individual `bash -n` on every QR1 shell script
- full QR1 Compose render
- `bash scripts/validate-env.sh` against a safely filled QR1 env
- `python3 scripts/audit-extensions.py`
- `bash tests/test-safe-env.sh`
- `bash tests/test-secret-security.sh`
- `python3 tests/contracts/test-network-exposure-contracts.py`
- `git diff --check`
- changed-file secret scan

### Rollback
Repository rollback: revert the MSODS-0008 correction commit.

Host rollback if already deployed: run `sudo scripts/ms-qr1-ufw-docker-rules.sh
remove` before Compose teardown, then remove Tailscale serve mappings, stop
and disable `ms-qr1-ollama-bridge.service`, remove the host-agent unit if
installed for QR1, and shred the filled `.env` per the latest runbook.

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
