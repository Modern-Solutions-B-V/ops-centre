# ODS QR1 Threat Model — Modern Solutions Ops Centre Fork

- **Document ID:** `MSODS-SEC-QR1-TM`
- **Status:** DRAFT — independent security review, **not approved, not merged** (author is the reviewer; per `AGENTS.md` rules 13–14 a second party must approve).
- **Reviewer role:** Independent security reviewer, MS Ops Centre fork.
- **Date:** 2026-08-16
- **ODS baseline:** `v2.6.0` (fork substrate per `docs/ms/decisions/ODS-ADOPTION.md`).
- **Scope:** QR1 broad-capability install set. The objective is **not** to remove capabilities but to define *how each is installed/enabled while remaining restricted until trusted*, and the **machine-enforced** controls that gate each trust increase.
- **Method:** Static inspection of the fork tree (compose, manifests, Dockerfiles, service source, installer, configs, docs). No live infrastructure was touched. Evidence is cited as `path:line`.

> This document does **not** implement fixes. It classifies each surface and records the machine-enforced restriction and the evidence required before trust is raised. Remediation is separate, per-task work.

---

## 1. Governing MS requirements

Authority precedence: **MS requirements, security policy and qualification criteria remain authoritative** (`docs/ms/decisions/ODS-ADOPTION.md:20`). Trust is *progressively enabled through machine-enforced policy* (id. line 24). The concrete deny obligations (`AGENTS.md`):

- **R8** — Secrets must never appear in prompts, logs, commits, or screenshots.
- **R9** — Do **not** enable: email send, Jira write, client-system writes, root/sudo, production secrets, or unrestricted egress *unless the human owner explicitly approved that permission*.
- **R10** — Local-only / confidential routes **must never silently fall back externally**.
- **R6** — Prefer CONFIGURE > EXTEND > CORE CHANGE.
- **R13/R14** — Do not approve or merge your own work.

These map to the deny-policy review in §10.

---

## 2. Permission-level ladder (used by every entry)

A component's *initial permission level* is the lowest rung that still lets it be installed and evaluated. Trust rises one rung at a time, each rung gated by machine-enforced controls **and** the evidence in that entry.

| Level | Name | Meaning | Machine gate |
|-------|------|---------|--------------|
| **P0** | Denied / not installed | Capability absent from the resolved stack | Not in compose resolution; extension audit blocks re-add |
| **P1** | Installed, disabled | Image present, service off, **no host port** | `expose:`-only or `category: optional`, disabled by default |
| **P2** | Loopback + authed | Bound `127.0.0.1`, auth required, **no autonomy, no egress** | `BIND_ADDRESS=127.0.0.1`, auth secret enforced, egress policy denies |
| **P3** | Operator-gated LAN/proxy | Reachable off-loopback **only** behind an authenticated proxy, with owner approval recorded | `forward_auth`/gateway + owner-approval flag; per-service auth mandatory |
| **P4** | Autonomous / egress-enabled | Tool execution *or* external egress permitted | Mandatory policy interception (APE-style) + egress allowlist + owner approval + audit |

**QR1 default posture:** every capability installs at **P1/P2**. No surface is born at P3/P4.

---

## 3. Classification taxonomy

Per `AGENTS.md` rule 5, extended with `ACCEPT` for "current ODS behavior already meets MS bar; adopt as-is":

- **ACCEPT** — current ODS control satisfies the MS requirement; adopt unchanged.
- **CONFIGURE** — meet the requirement by data/config/env only (no code). *Preferred.*
- **EXTEND** — add an MS-owned artifact (policy file, contract test, gate) without modifying upstream runtime code. Preserves mergeability.
- **CORE CHANGE** — modify upstream ODS runtime code. Requires explicit justification; last resort.
- **REJECT** — do not enable in QR1 as currently shipped; block until re-scoped.

---

## 4. Cross-cutting trust boundaries

1. **Host ↔ container.** The host agent (`bin/ods-host-agent.py`) runs on the host, out of Docker, precisely so **no container mounts the Docker socket** (verified: zero `docker.sock` mounts in production compose; user-extension mounts of it are rejected — `routers/extensions.py:568`, `scripts/resolve-compose-stack.sh:348`). This is the strongest boundary in the stack and must be preserved.
2. **Loopback ↔ LAN/tailnet.** A single env var, `BIND_ADDRESS`, flips **every** host-published service from `127.0.0.1` to `0.0.0.0` simultaneously. It is the master exposure lever.
3. **Local inference ↔ external provider.** The LiteLLM layer (and Hermes provider config) can route or *fall back* to Anthropic/OpenAI/MiniMax. This is the R10 boundary.
4. **Authenticated user ↔ autonomous agent.** Hermes/OpenClaw/n8n/OpenCode can execute code, write files, and reach the network. Nothing today forces these through a policy engine.
5. **Operator ↔ owner-card holder.** Magic-link / owner cards are reusable, non-device-bound keys (`docs/AP-MODE.md:149`).

---

## 5. Inference & gateway services

### 5.1 llama-server (core, local inference)

- **Assets:** Local model weights, all prompt/response content, GPU.
- **Trust boundary:** Container ↔ any client that can reach the inference port; host GPU device passthrough on AMD (`docker-compose.amd.yml:48-50` `/dev/dri`,`/dev/kfd`).
- **Threat / failure mode:** **No authentication at all** (`config/litellm/local.yaml:6` `api_key: not-needed`). Any peer that reaches the port has full model access; if `BIND_ADDRESS=0.0.0.0`, that is the whole LAN. Server listens `0.0.0.0:8080` inside the container (`docker-compose.base.yml:36`).
- **Current ODS mitigation:** Default host bind `127.0.0.1:11434` (`docker-compose.base.yml:32`); `no-new-privileges:true`; intended to sit behind LiteLLM as the authenticated gateway (`ods/SECURITY.md:280`).
- **Gap vs MS:** Unauthenticated inference API becomes LAN-open the instant `BIND_ADDRESS` is widened; no per-service auth compensates. Not digest-pinned; AMD variant is floating `latest` (`docker-compose.amd.yml:17`).
- **Initial permission level:** **P2** (loopback only).
- **Machine-enforced restriction required:** Contract test asserting llama-server has **no host `ports:`** when `BIND_ADDRESS≠127.0.0.1` unless LiteLLM auth is confirmed in front; keep loopback-only in resolved stack.
- **Evidence before increasing trust:** Proof that every non-loopback path terminates at an authenticated gateway (LiteLLM master key) with a passing exposure contract.
- **Classification:** **CONFIGURE** (bind + front with LiteLLM) + **EXTEND** (contract test).
- **Verification test:** `python ods/tests/contracts/test-network-exposure-contracts.py`; add assertion that `llama-server` is absent from any 0.0.0.0 port map without an auth proxy.

### 5.2 LiteLLM (LLM API gateway)

- **Assets:** Master key `LITELLM_KEY`, external-provider API keys (`ANTHROPIC/OPENAI/MINIMAX/TOGETHER`), routing config, all transiting prompts.
- **Trust boundary:** Loopback/LAN client ↔ gateway ↔ (internal llama-server **or** external providers). This is the primary R10 boundary.
- **Threat / failure mode:**
  1. **Silent local→cloud fallback** in hybrid mode: `config/litellm/hybrid.yaml:31-36` sets `num_retries: 2` then `fallbacks: [local: [cloud]]` — a local request that errors/times out is **silently re-sent to Anthropic** with no per-request consent (generated by `scripts/render-runtime-configs.py:330-334`). **Direct R10 violation.**
  2. **External model names remain routable** even under the local switchboard (`switchboard.yaml:20-35`, `cloud.yaml`).
  3. **lemonade config has no `master_key`** block (`config/litellm/lemonade.yaml`) — gateway may run unauthenticated in that mode.
  4. LiteLLM is host-published (`extensions/services/litellm/compose.yaml:27`); LAN-reachable if `BIND_ADDRESS=0.0.0.0`.
- **Current ODS mitigation:** `LITELLM_MASTER_KEY` enforced in local/cloud/hybrid/switchboard configs and by contract test (`test-network-exposure-contracts.py:222`); default loopback; provider keys via `os.environ`, not committed.
- **Gap vs MS:** Fallback + external-model routing let confidential/local-only workloads egress; lemonade mode auth gap; no machine guard binding `ODS_MODE`/confidential-classification to "no external route."
- **Initial permission level:** **P2** in `local` mode only; **P4** for any config that can reach an external provider (hybrid/cloud/switchboard).
- **Machine-enforced restriction required:**
  - Ship an MS `confidential`/`local-only` mode with **no external `model_list` entries and no `fallbacks`** — enforced by a contract test that rejects any `fallbacks:` or non-`llama-server`/`model-router` `api_base` in the active config.
  - Require `master_key` present in **every** LiteLLM config including lemonade.
  - Egress from LiteLLM to external hosts allowed only when an `owner-approved` env flag is set.
- **Evidence before increasing trust:** Recorded owner approval for cloud/hybrid; passing "no-silent-fallback" contract; DLP/redaction posture for prompts leaving the boundary.
- **Classification:** **CONFIGURE** (default to `local`, strip fallback) + **EXTEND** (no-fallback contract test, lemonade master-key test). Enabling any external route is a **REJECT-until-owner-approved** gate.
- **Verification test:** New `tests/contracts/test-litellm-no-silent-fallback.py`: assert active `${ODS_MODE}.yaml` contains no `fallbacks:` and no external `api_base` unless `OWNER_APPROVED_EXTERNAL_LLM=true`; extend existing auth test to cover `lemonade.yaml`.

### 5.3 model-router (core)

- **Assets:** Internal routing key `ODS_ROUTER_INTERNAL_KEY`, endpoint allowlist (`config/model-router/endpoints.json` — local-only endpoints).
- **Trust boundary:** Internal Docker network only — **no host port** (`expose: 9099`, `docker-compose.base.yml:305`).
- **Threat / failure mode:** Data-plane `/v1` proxy is called with `api_key: no-key` (`switchboard.yaml:6`); control endpoints require the internal bearer key (`app/main.py:850`). Endpoints file governs destinations.
- **Current ODS mitigation:** **Best-hardened service in the stack** — `read_only: true`, `cap_drop: ALL`, non-root uid 10777, internal-only, read-only state mounts (`docker-compose.base.yml:307-328`).
- **Gap vs MS:** Minimal. Endpoints allowlist must remain local-only under a confidential profile.
- **Initial permission level:** **P2** (internal-only).
- **Machine-enforced restriction required:** Contract test that `endpoints.json` contains only internal/local hosts under the confidential profile.
- **Evidence before increasing trust:** N/A for QR1 (keep internal).
- **Classification:** **ACCEPT** (adopt hardening as the reference pattern) + **EXTEND** (endpoints allowlist test).
- **Verification test:** Assert no external hostnames in `config/model-router/endpoints.json`.

### 5.4 Open WebUI (chat UI, core)

- **Assets:** Chat history, user accounts, session-signing secret `WEBUI_SECRET` (`data/open-webui/` — flagged sensitive, `ods/SECURITY.md:175`).
- **Trust boundary:** Browser ↔ UI ↔ internal services (llama-server/litellm/searxng/embeddings/whisper/tts).
- **Threat / failure mode:** If `WEBUI_AUTH` is disabled or `BIND_ADDRESS` widened while auth is weak, chat + history are LAN-exposed. Behind `ods-proxy` (which does no auth of its own) a mis-set `WEBUI_AUTH` is directly reachable.
- **Current ODS mitigation:** `WEBUI_AUTH: true` default and **fail-closed** signing secret `WEBUI_SECRET_KEY: ${WEBUI_SECRET:?}` (`docker-compose.base.yml:113-114`); loopback default; tag-pinned `v0.7.2`.
- **Gap vs MS:** Runs as image-default user (not pinned non-root); no digest pin; CSP present (`nginx.conf`).
- **Initial permission level:** **P2**, → **P3** behind `ods-proxy` with owner approval.
- **Machine-enforced restriction required:** Keep `WEBUI_AUTH` non-overridable to `false` in resolved config; contract that `ods-proxy` never fronts Open WebUI with `WEBUI_AUTH=false`.
- **Evidence before increasing trust:** Signups disabled, admin password rotated, exposure contract green.
- **Classification:** **ACCEPT** + **CONFIGURE** (disable signups).
- **Verification test:** Extend exposure contract to assert `WEBUI_AUTH` default true and secret fail-closed.

### 5.5 embeddings (TEI), Whisper (STT), Kokoro/TTS

- **Assets:** Model caches; **audio/text content in flight** (Whisper audio can be sensitive; `network-exposure-policy.json:155`).
- **Trust boundary:** Container ↔ any client on the bound port. All three are **unauthenticated** model APIs (`policy` marks `auth_required: false`).
- **Threat / failure mode:** LAN-open transcription/embedding/synthesis if `BIND_ADDRESS` widened; embeddings/whisper fetch models from Hugging Face at startup (egress at install/first-run).
- **Current ODS mitigation:** Loopback default; `no-new-privileges:true`; tag-pinned images; HF download host allowlist available (`ODS_MODEL_DOWNLOAD_ALLOWED_HOSTS`, `.env.example:163`).
- **Gap vs MS:** No auth; no digest pin; run as image-default user; HF egress not enforced by a firewall.
- **Initial permission level:** **P2** (loopback only).
- **Machine-enforced restriction required:** Never expose off-loopback without an auth proxy; enforce `ODS_MODEL_DOWNLOAD_ALLOWED_HOSTS` as the only model-fetch egress.
- **Evidence before increasing trust:** Auth proxy in front for any LAN use; offline pre-seed of models for confidential installs.
- **Classification:** **CONFIGURE** (loopback + allowlist) + **EXTEND** (exposure contract for the three).
- **Verification test:** Exposure contract: these three must not appear in any 0.0.0.0 port map without a fronting authenticated proxy.

---

## 6. Autonomous agents & code execution (highest risk)

### 6.1 Hermes (autonomous agent — Nous Research)

- **Assets:** Persistent memories, agent-authored skills, cron jobs, session history, workspace files (`data/hermes/`), the LLM route, outbound network.
- **Trust boundary:** Authenticated user ↔ agent that can **execute code, write files, browse the web, and be re-pointed at any external LLM provider**.
- **Threat / failure mode:**
  - **70+ tools including shell + file write; "No APE policy enforcement yet"** (`docs/HERMES.md:134`). Trust model is "the authenticated user is trusted to use the local container."
  - A **live PTY/shell surface** is enabled (`HERMES_DASHBOARD_TUI=1`, `compose.yaml:84`) piped to the browser via WebSocket, *separate* from the disabled `terminal` toolset (`cli-config.yaml.template:102`).
  - **Full outbound network** on the bridge net (`docs/HERMES.md:133`); `web_search` reaches the internet.
  - **Provider is operator-reconfigurable to Anthropic/OpenAI/OpenRouter/etc.** via `data/hermes/config.yaml` (`docs/HERMES.md:125`) — a confidential-data egress path with no consent gate.
  - `--insecure` enabled inside the container (`docs/HERMES.md:131`).
  - Cron scheduler fires autonomously every 60s (`compose.yaml:150`).
- **Current ODS mitigation:** Internal-only (`external_port_default: 0`, `expose: 9119`, no host port); entered **only** via `hermes-proxy` `forward_auth` against a signed `ods-session` cookie (`test-network-exposure-contracts.py:82`, `hermes-proxy/Caddyfile`); non-root (gosu drop to uid 10000); messaging gateways all disabled by default; resource-capped; body cap 50MB.
- **Gap vs MS:** No mandatory policy interception on tool calls (R9/R-shell); autonomous cron; unrestricted egress (R10 via provider swap and web tools); tag-not-digest pin; single shared instance for all authed users (no per-user isolation).
- **Initial permission level:** **P1 (installed, disabled)** for QR1. When enabled: **P3** for chat via proxy, but **P4** the moment shell/file-write/web tools or an external provider are active.
- **Machine-enforced restriction required:**
  - **Route every Hermes tool call through APE with `STRICT_MODE=true`** (the deferred integration in `docs/HERMES.md:175`) before shell/file-write tools are permitted.
  - **Disable the TUI PTY surface** (`HERMES_DASHBOARD_TUI=0`) until policy interception exists.
  - **Pin the LLM provider to the internal route**; block `config.yaml` provider changes to external hosts unless `OWNER_APPROVED_EXTERNAL_LLM=true`.
  - **Egress allowlist / forward proxy** for web tools; deny by default under confidential profile.
  - Keep port 9119 unbound; keep proxy `forward_auth` mandatory.
- **Evidence before increasing trust:** APE-in-front integration test passing; audit log of tool calls; owner approval for any external provider; per-user isolation design if multi-user.
- **Classification:** **REJECT for autonomous tool execution in QR1 as shipped** (enable chat-only via proxy = **CONFIGURE**; full agency requires **EXTEND** = APE wrapper + egress gate). Provider-to-external is **REJECT-until-owner-approved**.
- **Verification test:** New contract: assert `HERMES_DASHBOARD_TUI` defaults `0`; assert an APE `/verify` pre-hook is wired for `ExecuteCommand`/`WriteFile`; extend `test-network-exposure-contracts.py` to assert Hermes stays port-less and proxy-gated.

### 6.2 hermes-proxy (auth gateway)

- **Assets:** Session verification (`ODS_SESSION_SECRET`), the LAN entry to Hermes.
- **Trust boundary:** LAN client ↔ proxy ↔ internal Hermes.
- **Threat / failure mode:** Loopback default; LAN only if `BIND_ADDRESS=0.0.0.0`. An earlier draft only checked header *presence* (bypassable) — now does real HMAC signature verification (`Caddyfile` comment).
- **Current ODS mitigation:** Caddy `forward_auth` → `/api/auth/verify-session`; non-2xx → redirect; admin API off; `auto_https off`; 50MB body cap; contract-enforced (`test-network-exposure-contracts.py:82-94`).
- **Gap vs MS:** Auth is *gating*, not *identity* — all authed users share one Hermes. Tag-not-digest pin.
- **Initial permission level:** **P3** (this is the intended controlled entry).
- **Machine-enforced restriction required:** Keep `forward_auth` + signature verify mandatory (existing contract); owner-approval flag for LAN bind.
- **Classification:** **ACCEPT** (adopt as the Hermes gate) + **CONFIGURE** (owner-gated LAN bind).
- **Verification test:** Existing `test_hermes_is_internal_only_and_proxy_gated`.

### 6.3 APE — Agent Policy Engine

- **Assets:** The stack's only deny-by-default governance primitive; audit log; circuit-breaker state.
- **Trust boundary:** Advisory HTTP decision service (`POST /verify`).
- **Threat / failure mode (critical):**
  - **Not wired in.** Grep found **no service that calls `ape:7890`/`/verify`** — not Hermes, OpenClaw, or OpenCode. It provides **zero runtime enforcement** as shipped.
  - **Not deny-by-default at the engine level:** unknown intents default to `allow` (`main.py:661,695`); `ReadFile`/`NetworkFetch`/`SpawnAgent`/`Other` default `allow` (`policy.yaml:67`).
  - **`STRICT_MODE` defaults `false`** (`compose.yaml:14`) — denials are advisory body text, not 403.
  - **Audit log not actually tamper-evident** despite docstrings — plain `json.dumps` append, no hash-chain/HMAC (`main.py:700`).
  - Weak default: auto-generated `APE_API_KEY` only partially logged (`main.py:102`).
- **Current ODS mitigation:** Real per-intent controls *when consulted*: `ExecuteCommand` allowlist + deny regexes (`rm -rf`, `curl|sh`, reverse shells), `WriteFile` path-guard with `realpath` anti-traversal, per-session rate limits, sliding-window caps, persisted circuit breaker; non-root `USER ape`; loopback default.
- **Gap vs MS:** The one component that could satisfy R9/shell/egress governance is **inert**. This is the single most important gap.
- **Initial permission level:** **P2** (service), but its *policy role* is **P0 until wired**.
- **Machine-enforced restriction required:**
  - Make APE the **mandatory in-path interceptor** for Hermes/OpenClaw/n8n/OpenCode (not an optional sidecar).
  - Flip engine to **deny-by-default** (unknown intent → deny), `STRICT_MODE=true`.
  - Implement **hash-chained / HMAC audit** to make the log genuinely tamper-evident.
  - Require `APE_API_KEY` explicitly (fail-closed if unset, not auto-gen).
- **Evidence before increasing trust:** Integration test proving an agent's `ExecuteCommand` is blocked when APE denies; tamper-evidence test on the audit chain.
- **Classification:** **CORE CHANGE / EXTEND** — wiring agents to APE and flipping defaults is behavioral; justify explicitly. Until done, agent tool execution is **REJECT**.
- **Verification test:** New `tests/test-ape-enforcement.py`: (a) deny-by-default on unknown intent; (b) an agent request with a denied command returns 403 under `STRICT_MODE`; (c) audit entries chain-verify.

### 6.4 OpenClaw (deprecated agent)

- **Assets:** Agent workspace, canvas, cron; gateway token.
- **Trust boundary:** Authenticated user ↔ autonomous agent (code/tool exec in container).
- **Threat / failure mode:** **Container starts as root** (`user: "0:0"`) then self-demotes via `setpriv` (`compose.yaml:28,35`); autonomous agency; outbound egress; optional OpenAI-compat write API (`OPENCLAW_HTTP_API`, off) and a `DANGEROUSLY_DISABLE_DEVICE_AUTH` escape hatch.
- **Current ODS mitigation:** **Deprecated & optional** (`manifest.yaml`), token-gated (`OPENCLAW_TOKEN` fail-closed), device auth on by default, `no-new-privileges:true`, opt-in-only exposure — all contract-enforced (`test-network-exposure-contracts.py:210`).
- **Gap vs MS:** Root-start; deprecated code path; same no-APE gap as Hermes.
- **Initial permission level:** **P0 (do not install in QR1)** — superseded by Hermes.
- **Machine-enforced restriction required:** Keep deprecated/optional/token-gated contract; if ever enabled, same APE-in-path requirement as Hermes; drop root start.
- **Classification:** **REJECT** for QR1 (use Hermes). Keep the existing deprecation contract as the machine guard.
- **Verification test:** Existing `test_openclaw_stays_deprecated_optional_and_token_gated`.

### 6.5 OpenCode (browser IDE / coding assistant)

- **Assets:** Source code, the **host user account and its filesystem**.
- **Trust boundary:** **Runs on the host, not in Docker** (`type: host-systemd`, `manifest.yaml:16`). No container isolation; blast radius is the host user, not a container.
- **Threat / failure mode:** AI code editor with host FS access; **server password appears unset by default** — `render-runtime-configs.py` only renders the LLM key, and `opencode_key()` returns `NO_KEY` in default mode. No `BIND_ADDRESS` gating in the manifest. Structurally the **highest-isolation-risk surface** in the set.
- **Current ODS mitigation:** Documented `OPENCODE_SERVER_PASSWORD` probe env (`manifest.yaml:29`), auto-generated by the installer secret set — but not proven wired into the running server.
- **Gap vs MS:** Uncontained host process; unverified auth; no sandbox; no APE.
- **Initial permission level:** **P0 (do not install in QR1)** until sandboxed and auth-verified.
- **Machine-enforced restriction required:** Containerize or sandbox with a restricted workspace; **enforce `OPENCODE_SERVER_PASSWORD` fail-closed**; loopback-only bind; APE in path before any exec/write tool.
- **Evidence before increasing trust:** Proof the server refuses to start without a password; sandbox boundary defined; workspace path-guarded.
- **Classification:** **REJECT** for QR1 as shipped (host-systemd, unverified auth). Re-scope as **EXTEND** (sandbox + auth gate) before enabling.
- **Verification test:** New test asserting the OpenCode unit refuses to bind without `OPENCODE_SERVER_PASSWORD` and binds loopback by default.

### 6.6 n8n (workflow automation)

- **Assets:** Workflows, stored credentials (`data/n8n/` — flagged sensitive), admin password `N8N_PASS`.
- **Trust boundary:** Authenticated user ↔ workflow engine that runs **Code nodes (JS/Python) and arbitrary HTTP/webhooks** — a code-execution + arbitrary-egress surface.
- **Threat / failure mode:** Code/Execute nodes = RCE-in-container; workflows can reach any external host; webhooks accept inbound. No Docker socket mounted (so no container spawning).
- **Current ODS mitigation:** Admin login fail-closed (`N8N_USER`/`N8N_PASS` `:?`); loopback default; non-root; tag-pinned `2.6.4`; contract-listed.
- **Gap vs MS:** Arbitrary code + egress with no APE interception; stored third-party credentials at rest unencrypted in the data dir.
- **Initial permission level:** **P2** (loopback, authed), **P4** for any workflow with external egress or Code nodes.
- **Machine-enforced restriction required:** Route n8n outbound through the egress allowlist/forward proxy; disable Code/Execute nodes under confidential profile unless owner-approved; APE interception for command execution.
- **Evidence before increasing trust:** Owner approval per external integration (R9 covers email/Jira nodes specifically — see §10); egress logging.
- **Classification:** **CONFIGURE** (loopback, disable risky nodes) + **EXTEND** (egress gate). External-write nodes (email/Jira) are **REJECT-until-owner-approved**.
- **Verification test:** New test asserting Code/Execute-Command nodes disabled and outbound restricted under the confidential profile.

---

## 7. Research & data services

### 7.1 Qdrant (vector DB)

- **Assets:** Private embeddings + metadata (`data/qdrant/`).
- **Trust boundary:** Container ↔ client on port 6333/6334.
- **Threat / failure mode:** **API key defaults empty** (`compose.yaml:9` `${QDRANT_API_KEY:-}`) — **open if run without the installer**; LAN-open embeddings if `BIND_ADDRESS` widened.
- **Current ODS mitigation:** Installer auto-generates `QDRANT_API_KEY` (`installers/phases/06-directories.sh:465`); loopback default; `no-new-privileges`; tag-pinned `v1.16.3`; policy `auth_required: true`.
- **Gap vs MS:** Empty-key fail-open when installer not used; not digest-pinned; image-default user.
- **Initial permission level:** **P2**.
- **Machine-enforced restriction required:** Fail-closed — refuse to start without `QDRANT_API_KEY`; contract asserting non-empty key in resolved stack.
- **Evidence before increasing trust:** Key enforced; loopback confirmed.
- **Classification:** **CONFIGURE** (require key) + **EXTEND** (fail-closed contract).
- **Verification test:** Assert compose has no `${QDRANT_API_KEY:-}` fail-open default under the MS profile.

### 7.2 SearXNG (metasearch)

- **Assets:** Search query history (leaves the host to external engines).
- **Trust boundary:** UI ↔ external search engines (duckduckgo/google/brave/wikipedia/github/stackoverflow).
- **Threat / failure mode:** **No auth**, rate-limiter off (`settings.yml:6`), JSON API on — anyone reaching the port gets a search API; **checked-in placeholder `secret_key: "CHANGEME..."`** (`settings.yml:3`) is a weak known secret if the installer isn't run; **outbound egress to search providers leaks queries** (R10-adjacent for confidential installs).
- **Current ODS mitigation:** `SEARXNG_SECRET` fail-closed in compose (`:?`); installer rewrites the placeholder; loopback default; tag-pinned; offline mode disables web search.
- **Gap vs MS:** Query egress not gated for confidential workloads; no auth; CHANGEME in tree.
- **Initial permission level:** **P2** (loopback); **P4** because of external egress under confidential profile.
- **Machine-enforced restriction required:** Under confidential/offline profile, **disable external engines** (local-RAG only) and enforce via contract; remove/neutralize the CHANGEME placeholder.
- **Evidence before increasing trust:** Owner approval for external search; egress allowlist.
- **Classification:** **CONFIGURE** (offline/local-RAG default) + **EXTEND** (engine-egress contract).
- **Verification test:** Assert enabled engines empty (or local-only) under confidential profile; assert no `CHANGEME` secret in a resolved config.

### 7.3 Perplexica (deep research)

- **Assets:** Persistent research/query history + user uploads (named volumes).
- **Trust boundary:** UI ↔ SearXNG ↔ external engines **and** direct scraping of arbitrary result URLs.
- **Threat / failure mode:** **No auth** (`manifest.yaml:38`); **fetches arbitrary external web pages** (`PERPLEXICA_SCRAPE_URL_MAX_CHARS`) — SSRF-adjacent + egress; persists history + uploads.
- **Current ODS mitigation:** Loopback default; **digest-pinned** (`slim-latest@sha256:...`, the only digest-pinned image in the set); Brave key explicitly kept out of Perplexica (`tests/test-perplexica-entrypoint.py:548`).
- **Gap vs MS:** No auth; arbitrary-URL fetch is an egress/SSRF surface; query history persisted.
- **Initial permission level:** **P2** (loopback); **P4** for external scraping under confidential profile.
- **Machine-enforced restriction required:** Route scraping/search through the egress allowlist; disable under confidential/offline profile; add auth if exposed.
- **Classification:** **CONFIGURE** (offline default) + **EXTEND** (egress gate). Adopt its digest pin as the reference (**ACCEPT**).
- **Verification test:** Assert Perplexica disabled/local-only under confidential profile.

### 7.4 brave-search (paid API proxy)

- **Assets:** Paid `BRAVE_SEARCH_API_KEY`; query content.
- **Trust boundary:** Internal proxy ↔ `api.search.brave.com`.
- **Threat / failure mode:** No inbound auth on the proxy; key abuse/quota drain if exposed; egress of queries.
- **Current ODS mitigation:** Fail-closed on missing key; loopback default; non-root `USER node`; single external host.
- **Gap vs MS:** Key-bearing egress; installer scrub logic references a mismatched var name (`BRAVE_API_KEY` vs consumed `BRAVE_SEARCH_API_KEY` — `installers/phases/09-offline.sh:29`), a potential dead scrub.
- **Initial permission level:** **P1 (disabled)** — paid + egress; enable only on owner approval.
- **Machine-enforced restriction required:** Off under confidential/offline profile; fix the offline scrub var mismatch; egress allowlist to Brave only.
- **Classification:** **CONFIGURE** (disabled default) + **EXTEND** (fix scrub contract).
- **Verification test:** Assert `BRAVE_SEARCH_API_KEY` cleared by offline mode (correct var name).

### 7.5 ComfyUI (image generation)

- **Assets:** GPU; models; prompts/outputs; on AMD, direct GPU devices (`/dev/dri`,`/dev/kfd`).
- **Trust boundary:** UI ↔ workflow engine that can **install arbitrary custom nodes/packages** (ComfyUI-Manager) — an RCE-adjacent surface — and fetch models at runtime.
- **Threat / failure mode:** **No auth**; ComfyUI-Manager installs arbitrary code; AMD variant likely runs root with device access; build-time clones from moving branches.
- **Current ODS mitigation:** Loopback default; `no-new-privileges`; NVIDIA image non-root; GPU nodes pinned to commits; not privileged (explicit `devices`).
- **Gap vs MS:** No auth; arbitrary node install = supply-chain/RCE; AMD user posture unknown; third-party AMD image tag.
- **Initial permission level:** **P1 (disabled)**; if enabled, **P2** loopback with Manager disabled.
- **Machine-enforced restriction required:** **Disable ComfyUI-Manager / custom-node install** under MS profile; pin AMD image + run non-root; loopback-only.
- **Evidence before increasing trust:** Manager disabled; node set frozen; auth in front for any LAN use.
- **Classification:** **CONFIGURE** (disable Manager, loopback) + **EXTEND** (node-install lockdown). 
- **Verification test:** Assert Manager install path disabled and no floating node clones under the MS build.

---

## 8. Privacy & observability

### 8.1 Privacy Shield (PII scrubbing proxy)

- **Assets:** **Plaintext PII ↔ token re-identification map** — the crown-jewel asset.
- **Trust boundary:** Client ↔ scrubbing proxy ↔ internal LLM target.
- **Threat / failure mode:** The `pii_map` and sessions live **in-process RAM only** (`TTLCache`, 1h) — **not persisted, not encrypted**; plaintext PII resides in memory for up to an hour. Anyone with the API key + session can restore PII.
- **Current ODS mitigation:** Bearer auth (`SHIELD_API_KEY`, constant-time), key file 0600; deterministic tokenization; log sanitization strips PII; forwards **only to the internal target** (`llama-server`) — no third-party egress; non-root; loopback default.
- **Gap vs MS:** RAM-resident plaintext PII (acceptable-by-design but must be visible); no `cap_drop`/`read_only`; base image floating tag.
- **Initial permission level:** **P2** (loopback, authed).
- **Machine-enforced restriction required:** Ensure Privacy Shield's target is a **local-only** route (never a fallback-enabled LiteLLM config) so scrubbed-but-sensitive prompts cannot egress; add `cap_drop`/`read_only`.
- **Evidence before increasing trust:** Proof target is `local` mode with no fallback; memory-only map documented in DPIA.
- **Classification:** **ACCEPT** (design) + **CONFIGURE** (pin target to local-only route).
- **Verification test:** Assert `TARGET_API_URL` resolves to a no-fallback local route.

### 8.2 Langfuse (observability)

- **Assets:** **Full prompts/traces/evaluations** across Postgres/ClickHouse/MinIO/Redis.
- **Trust boundary:** Web UI ↔ internal DB backends (all on an `internal: true` network).
- **Threat / failure mode:** Holds complete prompt content; DB files plaintext on host; a full trace store is a high-value target.
- **Current ODS mitigation:** **Disabled by default** (ships as `compose.yaml.disabled`); backends have **no host ports** and sit on an internal network; NextAuth; `SALT`+`ENCRYPTION_KEY` for field encryption; telemetry disabled; all images tag-pinned.
- **Gap vs MS:** DB volumes unencrypted at rest; secrets in env; no non-root/cap_drop on backends.
- **Initial permission level:** **P1 (disabled)** — adopt as-is; enable only with owner approval.
- **Machine-enforced restriction required:** Keep backends port-less/internal; disk encryption for `data/langfuse/` under confidential profile; retention limits on prompt data.
- **Classification:** **ACCEPT** (disabled + internal-only default) + **CONFIGURE** (retention + at-rest encryption).
- **Verification test:** Assert no host port on any Langfuse backend; assert web UI loopback-only.

### 8.3 Token Spy (usage observability)

- **Assets:** Usage metrics DB; it also **proxies prompt traffic to external providers**.
- **Trust boundary:** Client ↔ token-spy ↔ **`api.anthropic.com` / `api.openai.com` / `api.moonshot.ai`** (by `API_PROVIDER`).
- **Threat / failure mode:** Real third-party egress carrying prompt bodies + `UPSTREAM_API_KEY`; the one observability service with external reach.
- **Current ODS mitigation:** Bearer auth (constant-time), key 0600; SQLite stores usage metrics (not prompt text); M1 SQL-identifier allowlist intact (`db.py:86-104`); non-root; loopback default; `/dashboard` HTML public but data fetches key-gated.
- **Gap vs MS:** Prompt egress in proxy mode; unencrypted usage DB; base image floating tag.
- **Initial permission level:** **P2** for local-backend telemetry; **P4** in external-proxy mode.
- **Machine-enforced restriction required:** Pin `API_PROVIDER` to the local backend under confidential profile; block external upstreams unless owner-approved.
- **Classification:** **CONFIGURE** (local backend default) + **EXTEND** (external-upstream gate).
- **Verification test:** Assert `API_PROVIDER` resolves to local backend under the MS profile.

---

## 9. Control plane, host mutation & cross-cutting infrastructure

### 9.1 Dashboard + Dashboard API

- **Assets:** The primary control plane; holds `DASHBOARD_API_KEY`/`ODS_AGENT_KEY`; mounts `.env` (all secrets) read-only.
- **Trust boundary:** Browser (session/magic-link auth) ↔ dashboard-api (API-key auth) ↔ host agent.
- **Threat / failure mode:** dashboard-api can **read every secret** via the read-only `.env` mount (`docker-compose.base.yml:276`); possession of the key = extension-scoped host-container control; magic-link/owner cards are reusable non-device-bound keys.
- **Current ODS mitigation:** Constant-time Bearer auth, fail-safe key generation 0600 (`security.py`); **every functional route `Depends(verify_api_key)`**; key injected server-side by nginx (never in the SPA); `.env` mounted **read-only** (writes delegated to the authenticated host agent); non-root `USER odser`; CSP + pre-staged HSTS; H2C-smuggling fix.
- **Gap vs MS:** Secret-blast-radius if dashboard-api is RCE'd (mitigated: routes key-gated, non-root); owner cards not device-bound; base image floating tags.
- **Initial permission level:** **P2** (loopback) → **P3** via `ods-proxy` with owner approval.
- **Machine-enforced restriction required:** Keep `.env` mount read-only; keep all mutation routes key-gated; owner-card revocation + expiry.
- **Classification:** **ACCEPT** (adopt auth model) + **CONFIGURE** (owner-card expiry).
- **Verification test:** `pytest extensions/services/dashboard-api/tests/test_security.py`; exposure contracts.

### 9.2 Host agent & Docker permissions/mounts

- **Assets:** Host Docker control; runs on the host outside Docker.
- **Trust boundary:** **The critical host↔container boundary.** Avoids mounting the Docker socket by design.
- **Threat / failure mode:** A valid `ODS_AGENT_KEY` grants extension-scoped container control and `docker exec` (including `--user 0:0 ods-hermes`); host agent runs `docker compose` on the host.
- **Current ODS mitigation:** Constant-time auth on all non-`/health` routes; **no `shell=True`/`os.system` anywhere**; fixed-argv subprocess; `service_id` regex + **must resolve to an installed extension manifest**; core-service protection (two allowlists, fail-closed fallback); request-size caps (16KB/64KB); subprocess timeouts; atomic 0600 `.env` writes with key/value validation; loopback/gateway-only bind (never 0.0.0.0 unless explicitly set); **no container mounts the Docker socket**; **no `privileged: true` anywhere**; user-extension installs with `privileged`/`docker.sock` are **rejected**.
- **Gap vs MS:** Trust rests on key secrecy + bind scope; `docker exec --user 0:0` into Hermes is a powerful primitive; base Dockerfile images (`python:3.11-slim`, `nginx:alpine`) not digest-pinned.
- **Initial permission level:** **P2** (loopback/gateway, authed) — this is core and stays.
- **Machine-enforced restriction required:** Preserve the no-socket/no-privileged/allowlist model as **non-negotiable contracts**; digest-pin base images for control-plane services.
- **Classification:** **ACCEPT** (reference boundary) + **EXTEND** (add a "no docker.sock / no privileged / no shell=True" regression contract to lock it).
- **Verification test:** Grep-contract asserting zero `docker.sock` mounts, zero `privileged: true`, zero `shell=True`; existing extension-rejection tests (`test_extensions.py:658,1594,2160`).

### 9.3 Remote-provider-egress + SSH tunnel (the intended external-LLM boundary)

- **Assets:** Private provider API key (file custody), SSH identity/known_hosts.
- **Trust boundary:** Internal-only egress boundary that injects credentials at the final hop.
- **Threat / failure mode:** Purpose-built to reach external LLM providers — but **strongly fail-closed**: read-only state, route disabled if state file missing, credential from private file (never public env), inbound `authorization` stripped, **SSRF guard rejecting loopback/private/link-local resolved IPs**, `trust_env=False`, `follow_redirects=False`, DNS-pin against rebinding; SSH argv hardened (`-F /dev/null`, `StrictHostKeyChecking=yes`, `BatchMode`, `IdentitiesOnly`, no agent forwarding).
- **Current ODS mitigation:** `read_only`, `cap_drop: ALL`, non-root uid 10778, `expose`-only (no host port), egress policy (`config/remote-provider-egress-policy.json`) forbidding credentials/query in URL, `public_env_forbidden` for the key.
- **Gap vs MS:** This service is the *correct* egress model — but it is bypassed by the LiteLLM-layer fallback (§5.2). Base image not digest-pinned on the exact service holding egress credentials.
- **Initial permission level:** **P1 (dormant)** — enabled only when remote routing is owner-approved (`REMOTE_LLM_ENABLED=true` + `ODS_MODE=cloud`).
- **Machine-enforced restriction required:** Make this the **only** sanctioned external-LLM path (route LiteLLM external traffic through it; forbid direct provider `api_base` in LiteLLM configs); digest-pin its image.
- **Evidence before increasing trust:** Owner approval recorded; egress policy test green.
- **Classification:** **ACCEPT** (adopt as the egress reference) + **EXTEND** (force all external LLM traffic through it).
- **Verification test:** Assert LiteLLM external routes point only at `remote-provider-egress`; assert egress SSRF guard rejects private IPs.

### 9.4 LAN / Tailscale / public bindings

- **Assets:** Every host-published service's reachability.
- **Trust boundary:** Loopback ↔ LAN ↔ tailnet.
- **Threat / failure mode:** `BIND_ADDRESS=0.0.0.0` exposes **all** services at once, including unauthenticated ones (llama-server, embeddings, tts, whisper, searxng, qdrant-if-unkeyed, comfyui). `ods-proxy` **defaults to `0.0.0.0:80`** by design (`compose.yaml:31`) and does **no auth itself** — it delegates, so a backend with auth off is LAN-reachable. Tailscale uses `network_mode: host` + `NET_ADMIN`/`NET_RAW`.
- **Current ODS mitigation:** Loopback default for services; exposure policy labels every host-facing service; contracts enforce Hermes internal-only + proxy auth + LiteLLM auth; Tailscale/ods-proxy opt-in; ADR notes host-net is intentional and explicit.
- **Gap vs MS:** One env var widens everything; `ods-proxy` fronting an auth-off backend is a foot-gun; no per-service compensating auth when widened.
- **Initial permission level:** LAN/tailnet exposure = **P3**, owner-approved only.
- **Machine-enforced restriction required:** Gate `BIND_ADDRESS≠127.0.0.1` behind an `OWNER_APPROVED_LAN=true` flag; contract that **no unauthenticated service** is reachable through `ods-proxy` when bound to 0.0.0.0.
- **Classification:** **CONFIGURE** (owner-gated bind) + **EXTEND** (auth-coverage contract behind the proxy).
- **Verification test:** New contract: every host block in `ods-proxy/Caddyfile` maps to a backend with auth (or `forward_auth`).

### 9.5 Secrets & environment variables

- **Assets:** ~30 generated secrets (`WEBUI_SECRET`, `DASHBOARD_API_KEY`, `ODS_AGENT_KEY`, `ODS_SESSION_SECRET`, `SHIELD_API_KEY`, `N8N_PASS`, `LITELLM_KEY`, `QDRANT_API_KEY`, `OPENCLAW_TOKEN`, `SEARXNG_SECRET`, `OPENCODE_SERVER_PASSWORD`, Langfuse set, …) plus user-supplied cloud keys.
- **Threat / failure mode:** `.env.example` ships `CHANGEME` placeholders (docs only); `config/searxng/settings.yml` ships a real `CHANGEME` `secret_key`; schema enforces only `minLength: 10` (no entropy/charset); secrets pass via env + a few files; **backups store `.env` unencrypted** (see §9.7).
- **Current ODS mitigation:** Installer generates secrets with `openssl rand` (no `$RANDOM`), writes `.env` 0600, gitignored; `validate-env.sh` rejects `CHANGEME` via minLength; fail-closed `:?` on critical secrets; file-custody for the remote-provider key; no docker `secrets:` blocks but read-only mounts.
- **Gap vs MS (R8):** Weak-default fail-open if the installer is skipped; no entropy validation; secrets readable by dashboard-api; CHANGEME in a checked-in config.
- **Initial permission level:** **P2** (generated, 0600) — acceptable baseline.
- **Machine-enforced restriction required:** Fail-closed everywhere a secret is unset (extend `:?` to qdrant); remove committed CHANGEME secret; add entropy check to `validate-env.sh`; keep secret-scan CI (gitleaks) mandatory.
- **Classification:** **CONFIGURE** (fail-closed + remove CHANGEME) + **EXTEND** (entropy check).
- **Verification test:** `bash ods/tests/test-secret-security.sh`; `bash ods/tests/test-safe-env.sh`; new assertion: no `CHANGEME` in any tracked config consumed at runtime.

### 9.6 Outbound Internet & external fallback (R10 focus)

- **Threat / failure mode (the headline R10 gaps):**
  1. **Silent `local→cloud` fallback** in hybrid mode (§5.2) — confidential prompts to Anthropic on any local error, no consent.
  2. **External model names routable** in cloud/switchboard configs.
  3. **Hermes provider re-pointable** to external hosts via config.
  4. **Offline mode is advisory** — `.offline-mode` marker is referenced only in docs; **no runtime reads it to block egress**; air-gap depends on physically unplugging the network. `ods mode` freely switches local→cloud/hybrid with no confidential guard.
  5. SearXNG/Perplexica/brave/token-spy carry query/prompt content to external hosts.
- **Current ODS mitigation:** Loopback defaults; the *remote-provider-egress* path is fail-closed and well-guarded; offline install clears cloud keys; local mode routes only to llama-server.
- **Gap vs MS:** **There is no machine-enforced local-only/confidential egress control.** This is the most important cross-cutting gap.
- **Machine-enforced restriction required:**
  - A `CONFIDENTIAL=true` (or `ODS_EGRESS=deny`) profile that: strips LiteLLM `fallbacks` and external `model_list` entries; pins Hermes/Privacy-Shield/token-spy/model-router to local routes; disables external search engines; and is enforced by contract tests + (ideally) an egress firewall/forward-proxy default-deny.
  - Runtime enforcement of the `.offline-mode` marker (a startup guard that refuses external `api_base`).
- **Classification:** **EXTEND** (confidential profile + no-fallback contracts) — the highest-priority follow-up task. Enabling any external route without owner approval is a **REJECT**.
- **Verification test:** New `test-confidential-egress-deny.py` asserting no external `api_base`/`fallbacks` and no external search engines when `CONFIDENTIAL=true`.

### 9.7 Persistence & backups

- **Assets:** All `data/` (chat, workflows+creds, embeddings, traces, PII-adjacent), `.env`.
- **Threat / failure mode:** **Backups are unencrypted** — `ods-backup.sh` produces plain `tar.gz` (mode 600 + sha256 integrity only); `.env` with all secrets is captured in plaintext. Snapshots also include `.env` (`ods-update.sh` pre-update snapshot).
- **Current ODS mitigation:** Archives 0600; checksums for integrity; `ods/SECURITY.md:189` recommends `gpg -c` manually; update path auto-rolls-back from snapshots.
- **Gap vs MS (R8):** At-rest secret material in unencrypted archives.
- **Initial permission level:** **P2**.
- **Machine-enforced restriction required:** Default backup encryption (age/gpg) with a key held outside `data/`; exclude or encrypt `.env` in archives.
- **Classification:** **EXTEND** (encrypted-backup wrapper) — no upstream code change needed if implemented as an MS backup profile.
- **Verification test:** New test asserting a produced backup is encrypted / `.env` is not present in plaintext.

### 9.8 Update mechanism

- **Threat / failure mode:** Updates are `git pull origin main` over HTTPS; **no gpg/cosign/sigstore/tag-signature verification** anywhere in `ods-update.sh`; `docker compose up` implicitly pulls whatever mutable tags resolve. Trust = GitHub TLS + repo integrity only.
- **Current ODS mitigation:** Requires a real git checkout; **pre-update snapshot + auto-rollback** on failed pull/migration/health; update-check via GitHub releases API; model downloads SHA256-verified (though skippable if hash unset / no tool).
- **Gap vs MS (supply chain):** No signature verification; mutable image tags; model-hash verification skippable.
- **Initial permission level:** **P2** (operator-invoked, snapshotted).
- **Machine-enforced restriction required:** Pin the fork to a **reviewed tag/SHA** and require signature/commit verification before applying; make model-hash verification **mandatory** (fail-closed).
- **Classification:** **CONFIGURE** (pin ref) + **EXTEND** (signature/commit verification gate).
- **Verification test:** New test asserting the update path refuses an unsigned/unpinned ref under the MS profile; assert model verify is non-skippable.

### 9.9 Supply-chain paths

- **Threat / failure mode:** **No image is digest-pinned** except Perplexica; most are mutable version tags; AMD llama-server is floating `latest`; control-plane Dockerfiles use floating base tags (`python:3.11-slim`, `nginx:alpine`). The image-pinning ADR (2026-03-04) **formally rejected digest pinning** as too high-maintenance. **`audit-extensions.py` does NOT scan compose for unsafe patterns** (`privileged`, `docker.sock`, `cap_add`, host-net) — it is a metadata/consistency validator only, contradicting the SECURITY_AUDIT.md claim that it "rejects unsafe compose patterns." (Note: the *runtime* extension-install path in `routers/extensions.py:545-568` **does** reject `privileged` and `docker.sock` — so the guard exists at install time, just not in the audit tool.)
- **Current ODS mitigation:** Tag pins (mostly), model SHA256, runtime rejection of privileged/socket user extensions, no auto-image-swap, gitleaks/private-key pre-commit hooks.
- **Gap vs MS:** No digests/SBOM/signature chain (ODS roadmap item, not a guarantee — `INSTALLER_TRUST.md:198`); audit tool doesn't lint compose security.
- **Initial permission level:** **P2**.
- **Machine-enforced restriction required:** Digest-pin the MS image set; add a compose security-lint (privileged/socket/host-net/cap_add) to CI as an MS `EXTEND`; keep runtime extension rejection.
- **Classification:** **EXTEND** (digest-pin manifest + compose-lint) — MS may override the upstream ADR for high-assurance installs via `.env`/override files.
- **Verification test:** New `test-image-digest-pins.py` (MS profile) + a compose security-lint over `extensions/services/*`.

---

## 10. Initial deny-policy review (R9/R10)

Default posture for QR1 is **DENY** on each of the following. "Enforced today?" reflects what the *current tree* mechanically guarantees; "Machine gate required" is the MS control to add.

| # | Denied action | Enforced today? | Where it could leak | Machine gate required | Classification |
|---|---------------|-----------------|---------------------|-----------------------|----------------|
| 1 | **PR merge** | Partly — AI workflows are advisory/label-gated, human-merge only (`AI_WORKFLOW_GUARDRAILS.md`); branch protection assumed | An over-privileged CI token, or an agent with repo write | Keep code-writing jobs label-gated; no automation on branch protection; assert no `contents:write` on advisory jobs | **ACCEPT** + **EXTEND** (CI guard test) |
| 2 | **Email send** | Partly — Hermes messaging gateways off by default; n8n *can* send email via nodes | n8n email node; Hermes messaging adapter; any tool with SMTP | APE deny on `email.send` intent; n8n email nodes disabled unless owner-approved | **REJECT-until-approved** |
| 3 | **Jira write** | Not mechanically — n8n/agents could call Jira APIs | n8n Jira node; agent `NetworkFetch`; MCP tools | APE deny on external-write intents; egress allowlist excludes Jira write unless owner-approved | **REJECT-until-approved** |
| 4 | **Client-system writes** | Not mechanically | Agent file/network tools; n8n; OpenCode host FS | APE `WriteFile` path-guard (workspace-only) enforced *in-path*; OpenCode sandbox | **REJECT-until-approved** |
| 5 | **Production secret access** | Partly — secrets 0600, dashboard-api reads `.env` RO | Backups (plaintext), dashboard-api RCE, prompt logs | Encrypted backups; least-privilege secret scoping; R8 log/prompt redaction | **CONFIGURE** + **EXTEND** |
| 6 | **sudo / root** | Mostly — no `privileged`; containers non-root or self-demoting; AP-mode `hostapd`/`dnsmasq` run root but **opt-in/disabled** | OpenClaw root-start; AP-mode; host agent runs as host user | Keep no-privileged contract; drop OpenClaw root-start; keep AP-mode opt-in | **ACCEPT** + **CONFIGURE** |
| 7 | **Unrestricted shell** | **No** — Hermes PTY + shell tools, OpenClaw, n8n Code nodes, ComfyUI-Manager exist with **no mandatory policy** | Hermes TUI/tools; n8n; OpenCode; ComfyUI | **APE in-path with `STRICT_MODE`**, `ExecuteCommand` allowlist; disable Hermes TUI PTY | **REJECT-until-APE-enforced** |
| 8 | **Arbitrary egress** | **No** — no egress firewall; many services reach the internet | LiteLLM providers, SearXNG/Perplexica/brave/token-spy, Hermes web tools, n8n | Default-deny egress (forward proxy/firewall) + allowlist; confidential profile | **EXTEND** (egress default-deny) |
| 9 | **External fallback for confidential/local-only** | **No** — hybrid `local→cloud` fallback is silent; offline is advisory | `hybrid.yaml` fallback; external model names; Hermes provider swap; `ods mode` switch | No-fallback contract; confidential profile pinning local routes; runtime `.offline-mode` guard | **EXTEND** (highest priority) |

**Headline:** items **7, 8, 9** are the ones **not mechanically enforced today**. All three converge on two missing machine controls: (a) **mandatory APE interception** for autonomous execution, and (b) a **default-deny egress / confidential profile** that strips fallback and external routes. These are the two follow-up tasks that unlock safe progressive trust for the rest of QR1.

---

## 11. Machine-enforcement gap register (priority order)

| # | Gap | Requirement | Class | Priority |
|---|-----|-------------|-------|----------|
| G1 | APE not wired in; not deny-by-default; STRICT_MODE off; audit not tamper-evident | Mandatory in-path policy for all agents; deny-by-default; hash-chained audit | CORE CHANGE / EXTEND | **P0** |
| G2 | Silent `local→cloud` fallback + external model routing + advisory offline | Confidential profile: no fallback, no external `api_base`, runtime offline guard | EXTEND | **P0** |
| G3 | No default-deny egress; many services reach the internet | Forward-proxy/firewall default-deny + allowlist | EXTEND | **P0** |
| G4 | Hermes live PTY shell + full tools, re-pointable provider | TUI off; APE gate; provider pinned local | CONFIGURE/EXTEND | **P1** |
| G5 | OpenCode uncontained host process, auth likely unset | Sandbox + fail-closed password | REJECT→EXTEND | **P1** |
| G6 | Unauthenticated inference/search services LAN-open when bound wide | Owner-gated `BIND_ADDRESS`; auth-coverage contract behind proxy | CONFIGURE/EXTEND | **P1** |
| G7 | Qdrant fail-open empty key; SearXNG CHANGEME in tree | Fail-closed keys; remove committed secret | CONFIGURE | **P1** |
| G8 | Backups store `.env`/secrets unencrypted | Encrypted-backup default | EXTEND | **P2** |
| G9 | No image digests/signatures; update unsigned; model-hash skippable | Digest pins + signature/commit verify + mandatory model hash | CONFIGURE/EXTEND | **P2** |
| G10 | `audit-extensions.py` doesn't lint compose security | Add compose security-lint to CI | EXTEND | **P2** |
| G11 | OpenClaw root-start; deprecated | Keep disabled in QR1; drop root-start if enabled | REJECT | **P2** |

None of these are implemented in this task (analysis only). Each becomes its own one-task/one-branch change per `AGENTS.md`.

---

## 12. Verification test inventory (existing + to-add)

**Existing (adopt as the machine baseline):**
- `python ods/tests/contracts/test-network-exposure-contracts.py` — Hermes internal-only + proxy auth, OpenClaw deprecation/token gate, LiteLLM auth, exposure-policy labeling.
- `bash ods/tests/test-safe-env.sh`, `ods/tests/test-secret-security.sh`, `ods/tests/test-network-security.sh`, `ods/tests/test-issue-to-pr-security.sh`.
- `pytest extensions/services/dashboard-api/tests/test_security.py`.
- `python ods/scripts/audit-extensions.py --project-dir ods` (metadata consistency).

**To add (MS `EXTEND`, one per gap):** `test-litellm-no-silent-fallback.py`, `test-confidential-egress-deny.py`, `test-ape-enforcement.py`, `test-image-digest-pins.py`, compose security-lint, encrypted-backup test, Qdrant fail-closed test, OpenCode auth/bind test, `ods-proxy` auth-coverage test.

---

## 13. Reviewer sign-off

- This is an **independent security review**. Per `AGENTS.md` R13–R14, the author **does not approve or merge** this work; a separate MS reviewer/owner must.
- **No runtime code was modified.** Only this document (and its mandatory `docs/ms/ODS-MS-CHANGELOG.md` entry per R11) is committed.
- **Remediation is out of scope here.** The gap register (§11) enumerates follow-up tasks, each to be executed as its own branch/worktree with its own changelog entry and tests.
- Standing MS constraints reaffirmed: **local-only/confidential must never silently fall back externally** (R10 — currently violated by hybrid fallback, see G2); email send / Jira write / client writes / prod secrets / root / unrestricted egress remain **owner-approval-gated** (R9).
