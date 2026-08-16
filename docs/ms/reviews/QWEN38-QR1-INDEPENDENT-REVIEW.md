# QWEN38 — QR1 Independent Review

Role: independent local engineering reviewer, Modern Solutions ops-centre fork.
Baseline: ODS v2.6.0 (upstream SHA `f461b3e5`), fork working branch `ms/main`.
Scope: QR1 deliberately installs the broad ODS capability set. This review does
not modify runtime code; it ranks the 20 highest-risk technical assumptions and
changes in turning ODS into MS Ops Centre, classifies each, and states controls,
tests, and upstream-merge exposure.

Method: read-only inspection of `AGENTS.md`, `CLAUDE.md`, `docs/ms/`, the ODS
installer/phase/lib tree, base + extension compose, dashboard-api (auth, routers,
host-agent client), host-agent (`bin/ods-host-agent.py`), systemd units,
`remote_provider` egress/policy, and the validation harness
(`scripts/validate-*.py`, `scripts/audit-extensions.py`,
`docs/FORKABILITY.md`, `docs/HIGH_RISK_CHANGE_MAP.md`).

Classification scale (AGENTS.md rule 5): prefer
`CONFIGURE` > `EXTEND` > `CORE CHANGE`; `REJECT` where MS should not adopt.

MS operating constraints applied throughout (AGENTS.md rules 10, 8, 9;
`DOWNSTREAM.md`): single AMD Strix Halo host, external-LLM mode against
host-native Ollama, Tailscale-only exposure, `BIND_ADDRESS=127.0.0.1`; no email
send, Jira write, client-system write, root/sudo, production secrets, or
unrestricted egress unless the human owner approves them.

---

## A. The 20 highest-risk technical assumptions / changes

Risk severity (S1 = highest). Fields per item:
1. ODS file/component
2. risk
3. likely failure mode
4. classification
5. machine-enforced control (if relevant)
6. one exact validation test
7. upstream-merge risk

### A1. (S1) Host-Agent is the host-mutation control plane
1. `bin/ods-host-agent.py`, `scripts/systemd/ods-host-agent.service`,
   dashboard-api `routers/extensions.py` / `main.py` `request_json`.
2. The host agent executes `subprocess` on the host under the docker group and is
   the surface for container lifecycle (up/stop/recreate), model download, pip
   `install`, and remote-provider/egress operations. It is the single point that
   can mutate the host while remaining reachable through the dashboard-api
   control plane.
3. A buggy or compromised dashboard-api route (or a magic-link/owner-card bypass)
   can become arbitrary host command execution / container escape; a key leakage
   (`ODS_AGENT_KEY`/`DASHBOARD_API_KEY`) is total host compromise.
4. `CORE CHANGE` (if MS re-binds auth or adds commands) / `REJECT` for any plan
   to widen the exec surface; treat extension as `EXTEND` only.
5. `SupplementaryGroups=docker` + API-key auth is the only gate; `verify_api_key`
   (constant-time) and `ODS_AGENT_KEY` fall-back. No per-route allowlist beyond
   auth.
6. `pytest extensions/services/dashboard-api/tests/test_host_agent.py` plus a
   negative test asserting a forged/missing `ODS_AGENT_KEY` returns 401 before any
   `subprocess` is dispatched.
7. HIGH — host-agent is on the HIGH_RISK map; every change collides with the
   pinned upstream file on merge.

### A2. (S1) Hermes agent PTY + self-improving skills + shared persona mount
1. `extensions/services/hermes/compose.yaml` (`HERMES_DASHBOARD_TUI=1`),
   `hermes/manifest.yaml`, `routers/oauth_passthrough.py`, `data/persona/`,
   memory-shepherd baseline reset.
2. Hermes is a "self-improving generalist agent … 70+ built-in tools … autonomous
   skill creation." ODS flips on the PTY-backed chat REPL, and the agent reads/writes
   operator files under `data/persona/` (SOUL.md, memory, callbacks).
3. A malformed/malicious skill or prompt can drive host-side effects via the
   mounted persona dir or through host-agent; the PTY REPL is effectively a shell
   for a model. Memory-shepherd cron can wipe/reset agent memory (data-loss).
4. `CORE CHANGE` if MS exposes more tools/egress to Hermes; `REJECT` autonomous
   skill creation + unrestricted tooling for QR1.
5. hermes-proxy forward_auth (`ODS_SESSION_SECRET` HMAC) gates reachability;
   tool allowlisting is not machine-enforced by ODS (trust is assumed).
6. Stand up hermes, call the PTY `/api/pty` with a scripted prompt, assert the
   persona dir has no new executable and no outbound connector fires; then run
   `memory-shepherd.sh` in a dry-mode and assert baselines are snapshotted before
   reset (rollback path exists).
7. HIGH — hermes pinning, cli-config, and compose are frequently touched upstream.

### A3. (S1) Tailscale host-network + `0.0.0.0`/LAN exposure for QR1
1. `extensions/services/tailscale/manifest.yaml` + `compose.yaml`,
   `docker-compose.base.yml` (`BIND_ADDRESS`), `ods-proxy` Caddyfile (port 80).
2. QR1 exposes ODS over Tailscale; that requires the proxy + `BIND_ADDRESS`
   handling. Tailscale uses `network_mode: host` with `NET_ADMIN`/`NET_RAW`, and
   reachability is only correct if backends bind to a real interface, not
   loopback.
3. Operator sets `BIND_ADDRESS=0.0.0.0` to make tailnet reachability work and
   inadvertently publishes all services to the LAN with only per-service tokens;
   or keeps `127.0.0.1` and "remote access" silently does nothing (silent no-op).
4. `CONFIGURE` (env/manifest). Any code change to binding is `CORE CHANGE`.
5. Compose security scan in `resolve-compose-stack.sh` (dangerous caps, loopback
   default regex); `test-bind-address-sweep.sh`.
6. `bash tests/test-bind-address-sweep.sh` asserting that with
   `BIND_ADDRESS=127.0.0.1` no service exposes a non-loopback port, and that a
   `0.0.0.0` selection is explicit and logged.
7. MEDIUM — manifests/schema are stable but `BIND_ADDRESS` semantics evolve.

### A4. (S1) External-LLM (host Ollama) mode is the QR1 primary path
1. `installers/phases/02b-external-services.sh`,
   `installers/lib/external-services.sh` (`external_llm_container_url`),
   `resolve-compose-stack.sh` (external-llm overlay wiring).
2. QR1 assumes inference comes from host-native Ollama/LM Studio. Containers
   reach it via `host.docker.internal` normalization; model matching relies on
   string normalization of GGUF names.
3. On Docker Desktop the `host.docker.internal` rewrite works, but on the AMD
   host (production target) the container URL, model-name mismatch, or a running
   Ollama whose model differs silently produces "LLM up, answers wrong model" or
   a hard install failure. Silent reuse of a host model contradicts AGENTS rule 10
   if a local-only route is intended.
4. `CONFIGURE`. If MS must guarantee a pinned model regardless of host state,
   `EXTEND` (probe/verify gate). A fallback to bundled GGUF when host is down is
   `CORE CHANGE` and must be REJECTed if local-only was promised.
5. `external_llm_validate_url`, model-match checks; the resolve step errors if
   `EXTERNAL_LLM_URL` is set but `docker-compose.external-llm.yml` is missing
   (fail-loud, per rule 10).
6. With a live Ollama on `127.0.0.1:11434`, run the installer in non-interactive
   `--reuse-external-llm` and assert `EXTERNAL_LLM_CONTAINER_URL` =
   `http://host.docker.internal:11434/v1` (or the host-route equivalent) and the
   resolved model equals the host model (normalized).
7. MEDIUM/HIGH — external-services lib is shared and version-bumps often.

### A5. (S1) Dashboard-API temp self-generated key + broad router surface
1. `extensions/services/dashboard-api/security.py`, `routers/*`
   (setup runs `bash` scripts via `create_subprocess_exec`, oauth, magic-link,
   node, usage, updates, voice, workflows).
2. The API key is generated in-process and written to
   `/data/dashboard-api-key.txt` when unset; several routers shell out or read
   the filesystem. This is the administrative control plane.
3. If `DASHBOARD_API_KEY` stays unset in a service-restart scenario the key is
   regenerated (existing tokens invalidated or, worse, a key on disk with loose
   perms); a router that shells out (setup.py) is a command surface. Info can be
   leaked via error pages / `__ODS_RESULT__` streams.
4. `CONFIGURE` for pinning the key from MS secrets; any router change is
   `EXTEND`/`CORE CHANGE`.
5. `secrets.compare_digest`, `chmod 0600`, narrow exception catches per CLAUDE
   error rules.
6. `pytest extensions/services/dashboard-api/tests/ -k "auth or key or setup"`
   and a security test asserting a wrong Bearer token yields 401/403 (never 500)
   and the on-disk key file is `0600`.
7. HIGH — dashboard-api routes are a frequent upstream change area.

### A6. (S2) Remote-provider egress policy: "fail-closed" assumption vs dormant default
1. `config/remote-provider-egress-policy.json`,
   `remote_provider/{egress,policy,lifecycle,ssh_supervisor}.py`,
   `bin/ods-host-agent.py` (imports), `routers/remote_provider_status.py`.
2. Policy declares `forbid_local_hostnames`, IP-class bans, `public_receipts_must_redact`,
   `fail_closed_before_commit`, single-use SSH identity. This is MS's main
   "do-not-leak" boundary if ever a remote provider is approved.
3. Policy is a data document; enforcement depends on the `remote_provider`
   package being present and wired. If MS trusts the JSON alone, a mis-set
   `bind_policy` or an unpinned package falls back silently (imports are
   `except Exception: pass` fail-open) — a *local-only* route could quietly go
   external, violating AGENTS rule 10.
4. `REJECT` enabling remote providers in QR1 without owner approval; the policy
   wiring itself is `EXTEND` to make enforcement machine-enforced.
5. `config/remote-provider-egress-policy.json` +
   `tests/contracts/test-remote-provider-egress-policy.py`; redaction in
   `remote_provider_status.py`.
6. `pytest tests/contracts/test-remote-provider-egress-policy.py` and add a test
   asserting that with the `remote_provider` package import-failed (missing), the
   host-agent refuses (fail-closed) rather than opening a direct egress path.
7. HIGH — `remote_provider` is new-ish and upstream is iterating on it.

### A7. (S2) `resolve-compose-stack.sh` is the single runtime-assembly choke point
1. `scripts/resolve-compose-stack.sh` (+ `installers/lib/compose-select.sh`).
2. Decides the actual merged compose stack incl. external-llm overlays, GPU
   overlays, user extensions; it enforces the compose security scan and
   `_CORE_SERVICE_IDS` collision guard.
3. Any MS manifest/overlay mistake (port, cap, service-name collision, missing
   PyYAML) either breaks all installs or (worst case) the security scan is
   bypassed when a dependency is absent, letting an unscanned user extension in.
4. `CORE CHANGE` if MS alters resolution/ordering; `EXTEND` only to add overlays.
5. PyYAML hard-fail, `_DANGEROUS_CAPS` scan, `test-compose-*` / resolver tests.
6. `python scripts/validate-compose-stack.py` plus
   `python scripts/audit-extensions.py --project-dir .` in a tree containing a
   deliberately malicious user extension with `SYS_ADMIN` (assert it is rejected).
7. HIGH — explicitly on the HIGH_RISK map; high merge churn.

### A8. (S2) Model hot-swap / bootstrap-upgrade on a single host
1. `scripts/bootstrap-upgrade.sh`, `installers/lib/bootstrap-model.sh`,
   `installers/lib/model-lifecycle-lock.sh`, `upgrade-model.sh`.
2. Background download + hot-swap of `llama-server` with resume/`.part` handling,
   a lifecycle lock, and swap-back on failure.
3. On a 64 GB UMA Strix Halo host a failed swap or a stuck lock can leave
   `llama-server` on the wrong model, a corrupt `.part` treated as valid, or a
   deadlocked lifecycle that blocks every later `ods restart`. No `set -e` in the
   script means a silent partial state is plausible.
4. `CONFIGURE` (pin the chosen GGUF + tier). Any swap logic change is
   `CORE CHANGE`.
5. `ods_model_lifecycle_lock_*`, `status` sentinels;
   `test-bootstrap-upgrade-hotswap-contract.sh`,
   `-close-inherited-fds.sh`, `-docker-rollback.sh`, `-resume-status.sh`.
6. `bash tests/test-bootstrap-upgrade-hotswap-contract.sh` and
   `bash tests/test-bootstrap-upgrade-docker-rollback.sh`.
7. MEDIUM/HIGH — model lifecycle is a hot upstream area (many `fix/` branches).

### A9. (S2) `no-new-privileges` / capability posture is inconsistent across services
1. `docker-compose.base.yml` (llama, webui set `no-new-privileges:true`), but
   `tailscale` grants `NET_ADMIN`+`NET_RAW`+TUN and `hermes` runs a PTY.
2. The security baseline is not uniform; some services are hardened, others
   deliberately privileged.
3. MS assumes "ODS is local + sandboxed," but the privileged services expand the
   blast radius of any container compromise on a host that also holds client
   data.
4. `REJECT` blanket hardening (would break TUN/PTY functionality); `EXTEND` a
   per-service MS hardening policy.
5. `_DANGEROUS_CAPS` scan in resolver; per-service `security_opt` in compose.
6. `python scripts/audit-extensions.py` to enumerate every service exposing a
   dangerous cap and assert each has a documented MS justification in a policy file.
7. MEDIUM — caps are per-manifest, low churn but security-relevant.

### A10. (S2) Auth model: magic-link / owner-card / guest tokens over a public-ish surface
1. `routers/magic_link.py`, `hermes-proxy` (`verify-auth`), `auth.py`,
   `data/auth/magic-links.json`.
2. QR1 grants human access via magic links and reusable owner cards; hermes-proxy
   validates the `ods-session` HMAC via dashboard-api.
3. A cookie domain / session-secret misconfiguration (`ODS_SESSION_SECRET` empty
   or shared) could let a holder forge/redirect to a protected surface; rate-limit
   is per remote-IP and can be bypassed behind a proxy without `N8N_PROXY_HOPS`-like
   trust set correctly.
4. `CONFIGURE` (set `ODS_SESSION_SECRET`, cookie domain, TLS). Code change to
   auth = `CORE CHANGE`.
5. SHA-256-hashed token store, single-use consumption, SameSite/HttpOnly cookie
   policy.
6. `pytest extensions/services/dashboard-api` magic-link tests: assert a replayed
   token is rejected and a forged `ods-session` cookie is bounced by
   hermes-proxy (`/api/auth/verify-session` 401).
7. HIGH — auth routes are frequent upstream touchpoints.

### A11. (S2) LiteLLM / model-router gateway (`ods/current` alias) as the stable route
1. `extensions/services/litellm/`, `extensions/services/model-router/`,
   `routers/model_routes.py`, `model_state.py`, hermes/openclaw/opencode
   `llm.route: gateway`.
2. Agents point at the `ods/current` gateway alias rather than llama directly;
   MS relies on the router/switchboard to keep that alias bound to the right
   backend.
3. A router/alias mis-bind silently routes agent traffic to the wrong model or to
   an external endpoint; a `switchboard_exempt` service (privacy-shield,
   token-spy) bypasses the switchboard and could hit a direct URL that is later
   changed upstream.
4. `CONFIGURE` (which backend backs `ods/current`); `EXTEND` a routing pin.
5. Switchboard state (`model_state.py`), probe contracts per manifest `llm.probe`.
6. `pytest extensions/services/dashboard-api/tests/ -k "model_route or switch"`
   plus `scripts/validate-generated-configs.py` asserting `ods/current` resolves
   to the intended local backend only.
7. HIGH — model routing is flagged High in the HIGH_RISK map.

### A12. (S2) Support-bundle / diagnostic redaction vs. real PII in client data
1. `scripts/ods-support-bundle.sh`, `routers/remote_provider_status.py`
   (`[REDACTED]`), `build-installation-context.py`, `test-support-bundle.sh`.
2. QR1 may collect bundles/diagnostics that contain client data in
   `data/persona/`, logs, and model transcripts.
3. Redaction is list/pattern based ("raw `.env` is never included; only
   `config/env.redacted`"); novel secret shapes or client PII in log tails can
   leak into bundles that are then shared, violating rule 8.
4. `CONFIGURE` (what to include) / `EXTEND` a MS redaction rule set.
5. `REDACTION_VERSION`, max log-tail caps (`MAX_LOG_CONTAINERS`, `DEFAULT_LOG_TAIL`).
6. `bash tests/test-support-bundle.sh` with a planted secret and a planted PII
   string; assert neither appears in the produced archive (byte grep = 0 hits).
7. MEDIUM — redaction logic is MS-sensitive but low upstream churn.

### A13. (S2) RAG/persistence: Qdrant + embeddings + Open WebUI store client content
1. `qdrant/`, `embeddings/` (TEI), `docker-compose.base.yml` RAG env,
   `RAG_EMBEDDING_ENGINE=...openai` (routes to local `embeddings:80`).
2. RAG indexes and chat history persist client text into local stores (Qdrant,
   Open WebUI DB).
3. If `RAG_OPENAI_API_BASE_URL` is ever repointed to a remote endpoint (upstream
   default pattern is an OpenAI-compatible URL), client text silently leaves the
   host — a rule-10 violation; local-only is only guaranteed by the env default.
4. `CONFIGURE` (lock `RAG_OPENAI_API_BASE_URL` to local). `REJECT` RAG enablement
   for QR1 until data-classification policy exists.
5. Compose binding + `config.core-service-ids.json` prevents a shadow `qdrant`.
6. `docker compose config` (resolved) grepping for `RAG_OPENAI_API_BASE_URL` must
   resolve only to `http://embeddings:80/v1` (no external host).
7. MEDIUM — RAG contracts change as embedding models are updated.

### A14. (S3) Web-search egress (searxng / brave) and browser egress in agents
1. `searxng/`, `brave-search/`, open-webui `ENABLE_WEB_SEARCH` +
   `SEARXNG_QUERY_URL`, hermes/opencode web tools.
2. QR1 ships search that phones out to the internet (searxng public instances,
   brave API).
3. Unrestricted egress and prompt-injection via search results reaching the
   self-improving agent (A2); also a confidentiality leak of queries.
4. `REJECT` default-on web search for QR1; `CONFIGURE` an allowlist if allowed.
5. `BRAVE_SEARCH_API_KEY` secret; searxng instance list is data, not enforced.
6. Stand up searxng with no allowed upstreams and assert queries produce no
   external HTTP (egress probe) and agent surfaces do not render external
   results in QR1.
7. MEDIUM — search integration is frequently re-pinned upstream.

### A15. (S3) n8n workflows = client-system write boundary
1. `extensions/services/n8n/manifest.yaml`.
2. n8n is a workflow engine with arbitrary credential nodes and HTTP/webhook
   nodes — functionally a client-system write channel.
3. An n8n workflow can POST to client systems / email / Jira, which AGENTS rule 9
   forbids without owner approval. Its presence even disabled is an assumption
   that a human won't enable an exfiltration node.
4. `REJECT` enabling n8n in QR1. If kept installed-but-disabled, that is
   `CONFIGURE` off; any integration is `CORE CHANGE` + human sign-off.
5. None built in — n8n has its own auth (N8N_USER/N8N_PASS), egress is open.
6. `python scripts/audit-extensions.py` + a policy test asserting n8n is not in
   any QR1 "enabled" golden path and has no outbound connector in the resolved
   compose.
7. LOW/MEDIUM — manifest stable; the risk is operational, not merge.

### A16. (S3) Memory-shepherd cron mutating agent files on schedule
1. `memory-shepherd/*.service` + `memory-shepherd.sh`, systemd timers.
2. A timer resets agent MEMORY / workspace baselines on a schedule.
3. If scheduled during a live session it wipes agent memory / SOUL / AGENTS files
   (data-loss + surprising behavior); cross-OS `stat`/locking has known
   Darwin/GNU divergence (already patched in-script).
4. `CONFIGURE` (when/what is reset). Enabling the timers in QR1 is `EXTEND`; a
   change to the reset contract is `CORE CHANGE`.
5. Lock file + mtime/size snapshot (rollback), BSD/GNU `stat` helpers.
6. Run `memory-shepherd.sh <agent>` with a tampered baseline and assert a
   pre-reset snapshot exists so the state can be restored; run under `set -x` and
   assert no non-baseline file is deleted.
7. LOW — self-contained; low upstream churn.

### A17. (S3) GPU/tier mapping on a single UMA Strix Halo host
1. `installers/lib/detection.sh`, `tier-map.sh`, `config/backends/{amd,apple}.json`,
   `docker-compose.amd.yml`, `--n-gpu-layers 999`.
2. MS assumes one AMD Strix Halo UMA 64 GB host; the tier system is built for
   discrete-GPU/VRAM budgeting.
3. `--n-gpu-layers 999` and VRAM-based tier selection are wrong assumptions for a
   unified-memory UMA SoC; a model selected by a "VRAM" heuristic may OOM or
   mis-schedule, and tier detection may mis-classify the host.
4. `CONFIGURE` (pin tier + model + layers for the Strix Halo). Detection code
   change = `CORE CHANGE`.
5. `test-tier-map.sh`, `test-amd-topo.sh`, `test-assign-gpus.py`.
6. `bash tests/test-amd-topo.sh` on a Strix Halo target (or its fixture) and
   assert the resolved tier, `--n-gpu-layers`, and chosen GGUF match the MS pin
   (no VRAM heuristic override).
7. MEDIUM — AMD/lemonade branches are heavily iterated upstream.

### A18. (S3) Installer phase ordering + `install-core.sh` (QR1 must install cleanly once)
1. `install-core.sh`, `installers/phases/01..13`, `installers/lib/sudo.sh`,
   `logging.sh`, `constants.sh`.
2. The 13-phase orchestrator mutates the host (docker, dirs, devtools, images,
   services, health). `set -euo pipefail` + trap is the error model.
3. A phase order assumption (e.g., health before services, or devtools before
   images) that differs on the MS host, or a `sudo`/non-root assumption, breaks a
   clean install; DOWNSTREAM.md says never use the public bootstrap installer, so
   the custom path is the only path.
4. `CONFIGURE` (env/pins). Any phase/order change is `CORE CHANGE` and must be
   REJECTed as a fork-local hack.
5. `INSTALL_PHASE` set per phase for error reporting; preflight + doctor.
6. `bash scripts/simulate-installers.sh` on the MS profile and
   `bash tests/test-bootstrap-mode.sh` asserting clean exit 0 and a correct
   13/13 phase receipt.
7. HIGH — installer is the highest-churn, highest-blast-radius area upstream.

### A19. (S3) `ods-cli` lifecycle commands are the day-2 control surface
1. `ods-cli`, `scripts/migrate-config.sh`, `mode-switch.sh`, `session-cleanup.sh`,
   `repair/`.
2. `ods start/restart/doctor/update/backup/restore` is how MS operates the host.
3. A `mode-switch` or `migrate-config` that rewrites `.env`/compose can silently
   flip the QR1 pinning (e.g., external-LLM off, bind address up), breaking the
   "local-only/loopback" guarantee; `upgrade` can pull an unvetted upstream.
4. `CONFIGURE`. Any CLI behavior change is `CORE CHANGE`.
5. `test-cli-*` contracts (bootstrap compose wait, preset restore, user-extension
   deps, update verification).
6. `bash tests/test-cli-preset-restore-user-extensions.sh` and
   `bash tests/test-cli-update-verification.sh` asserting the QR1
   `.env` pins survive an `ods restart`/`migrate` cycle.
7. HIGH — ods-cli is explicitly High and under active decomposition upstream.

### A20. (S3) Upstream-mergeability of the fork layer itself
1. `AGENTS.md`, `CLAUDE.md`, `DOWNSTREAM.md`, `docs/ms/`, and every MS runtime
   touch across the files above.
2. The fork promise is "preserve upstream mergeability" (rule 15) while also
   pinning v2.6.0 and keeping the broad capability set.
3. High-risk areas A1, A2, A6, A7, A11, A18, A19 all land in files the upstream
   actively rewrites (per `git branch` there are dozens of `fix/…`, `feat/…`,
   `codex/…` branches touching host-agent, remote-provider, model routing, amd,
   cli). QR1 drift in these files makes a future v2.6.x/v2.7 merge a
   re-conflict/ re-validation burden, or worse, a silent behavior change.
4. `CONFIGURE`-only where possible; any persistent `EXTEND`/`CORE CHANGE` in the
   listed files must carry a changelog entry + test (rule 11/12).
5. `docs/FORKABILITY.md` fork-and-pin guidance + `DOWNSTREAM.md` change record.
6. `git diff --stat upstream/main...ms/main` scoped to the A1/A7/A11/A18/A19 file
   set, and for each non-empty region a matching entry in
   `docs/ms/ODS-MS-CHANGELOG.md` (assert 1:1 with `git log --name-only`).
7. HIGH — structural; this is the cost of fork-and-pin at v2.6.0.

---

## B. Capabilities ODS already solves well — do NOT rebuild

- **Installer / phase orchestration with `set -euo pipefail`, INSTALL_PHASE error
  reporting, and a 13-phase model** (`install-core.sh`, `installers/phases`).
  Reuse, don't fork.
- **GPU/tier detection + backend tier maps** (`detection.sh`, `tier-map.sh`,
  `config/backends/*`) — reuse the mechanism; only configure the Strix Halo pin.
- **Compose stack resolution + a working compose security scanner**
  (`resolve-compose-stack.sh` `_DANGEROUS_CAPS`, core-id collision guard).
- **API-key auth with constant-time compare + temp-key generation**
  (`dashboard-api/security.py`).
- **Support-bundle redaction harness** (`ods-support-bundle.sh`) — tighten the
  ruleset, don't rewrite the pipeline.
- **Model lifecycle lock + bootstrap hot-swap + resume** (`bootstrap-upgrade.sh`,
  `model-lifecycle-lock.sh`) — well-factored; use it.
- **Extension manifest contract + audit** (`manifest.yaml` schema,
  `audit-extensions.py`) — the recommended extension point per FORKABILITY.md.
- **Fail-loud / no-silent-fallback philosophy** in core paths (CLAUDE error rules
  are already machine-visible; e.g., PyYAML hard-fail).
- **Forkability discipline** (`FORKABILITY.md`, `HIGH_RISK_CHANGE_MAP.md`) — ODS
  already prescribes the fork-and-pin + extension-first strategy MS is adopting.

## C. Capabilities where MS-specific governance is likely required

- **Who may enable egress** (A6, A14, A15): owner-approved allowlist for remote
  providers, web search, and n8n workflow targets; otherwise fail-closed.
- **Client data classification** for RAG stores, chat history, memory/persona,
  and support bundles (A12, A13, A16); MS must define what may be persisted,
  indexed, reset, or shared.
- **Agent tooling authorization** (A2): an explicit, machine-enforced Hermes tool
  allow/deny list and a ban on autonomous skill creation until policy exists.
- **Host mutation policy** (A1): which dashboard-api routes may trigger host-agent
  `subprocess`, under which key, with an audit trail.
- **Exposure policy** (A3, A10): Tailscale ACLs, cookie domain, session secret,
  and the exact rule-9 permission grants (email/Jira/client writes) — each
  recorded as an explicit owner approval in the changelog.
- **Model supply chain** (A17, A4): which GGUFs / host Ollama models are
  approved, pinned, and SHA-verified on the Strix Halo host.
- **Change governance itself**: every A-class item that becomes a persistent MS
  change must carry a `docs/ms/ODS-MS-CHANGELOG.md` entry with tests + rollback
  (rules 11, 12).

## D. Capabilities to install/enable but NOT yet trust (QR1)

- **Hermes Agent** — install to observe; do not trust autonomous skill creation,
  PTY shell, or external connectors.
- **External-LLM (host Ollama) inference** — use as primary, but treat model
  identity as unverified until a QR1 probe gate proves the pinned model.
- **Tailscale remote access** — configure; do not trust until ACL + bind +
  session-secret are set; verify loopback-only by default.
- **RAG (Qdrant + embeddings)** — install disabled; do not ingest client text
  until data classification exists.
- **Web search (searxng/brave)** — install disabled in QR1; trust nothing.
- **n8n workflows** — install disabled; REJECT enabling (client-system write).
- **LiteLLM / model-router `ods/current`** — use as the stable route but pin and
  probe before trusting agent traffic.
- **Memory-shepherd timers** — keep uninstalled/unenabled in QR1 until reset +
  retention policy is defined.
- **Dashboard-API admin routers / magic-link** — enable for owner access; trust
  only after a QR1 auth-forgery test pass (A5, A10).

---

## Validation command summary (run these to confirm the assumptions above)

```bash
# Extension/manifest/contract truth (FORKABILITY.md minimum)
git diff --check
python scripts/audit-extensions.py --project-dir .
python scripts/validate-generated-configs.py
python scripts/validate-golden-paths.py

# High-risk map focus for QR1
bash tests/test-host-agent... 2>/dev/null || pytest extensions/services/dashboard-api/tests/test_host_agent.py
pytest extensions/services/dashboard-api/tests/ -k "auth or key or magic or model_route or switch"
pytest tests/contracts/test-remote-provider-egress-policy.py
bash tests/test-bind-address-sweep.sh
bash tests/test-amd-topo.sh
bash tests/test-bootstrap-upgrade-hotswap-contract.sh
bash tests/test-bootstrap-upgrade-docker-rollback.sh
bash tests/test-cli-preset-restore-user-extensions.sh
bash tests/test-cli-update-verification.sh
bash tests/test-support-bundle.sh
bash scripts/simulate-installers.sh
```

## Rollback note

This review is documentation-only. Rollback = remove
`docs/ms/reviews/QWEN38-QR1-INDEPENDENT-REVIEW.md` and its branch merge. It
changes no runtime behavior and has no security/privacy impact.
