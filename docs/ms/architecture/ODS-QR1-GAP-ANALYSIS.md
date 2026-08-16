# ODS QR1 Gap Analysis

Date: 2026-08-16

Baseline: ODS v2.6.0

Branch: `analysis/ods-gap`

Classification: analysis only. This document does not change platform behavior.

## Purpose

This analysis determines how ODS v2.6.0 should be adopted as the substrate for
MS Ops Centre QR1 while preserving the full ODS capability set. QR1 should not
remove services to reduce scope. Instead, QR1 should install and exercise the
broad stack, then use explicit trust, policy, routing and qualification gates to
decide which capabilities are safe for each MS operating mode.

The adoption strategy is:

1. Keep ODS v2.6.0 as the upstream substrate baseline.
2. Prefer configuration and documented extension points over upstream core
   modification.
3. Treat local inference, local chat, dashboard control, RAG, search, voice,
   image generation, workflow automation, agents, privacy tooling and
   observability as QR1-installed capabilities.
4. Make trust progressive. Installed does not mean trusted for autonomous
   action, external egress, write operations, client-system access or sensitive
   data handling.

## Source Material Reviewed

- `AGENTS.md`
- `CLAUDE.md`
- `docs/ms/ODS-MS-CHANGELOG.md`
- `docs/ms/decisions/ODS-ADOPTION.md`
- `ARCHITECTURE.md`
- `ods/docs/INSTALLER-ARCHITECTURE.md`
- `ods/docs/EXTENSIONS.md`
- `ods/docs/NETWORK.md`
- `ods/docs/INTEGRATION-GUIDE.md`
- `ods/docs/HERMES.md`
- `ods/docs/HERMES-SSO.md`
- `ods/docs/ODS-PROXY.md`
- `ods/docs/INSTALLER_TRUST.md`
- `ods/docs/AI_WORKFLOW_GUARDRAILS.md`
- `ods/docs/SUPPORT-MATRIX.md`
- `ods/docs/TESTING.md`
- `ods/docs/FORKABILITY.md`
- `ods/docs/OFFLINE_AND_MIRRORING.md`
- `ods/config/network-exposure-policy.json`
- `ods/config/remote-provider-egress-policy.json`
- `ods/.env.schema.json`
- `ods/docker-compose.base.yml`
- `ods/extensions/services/*/manifest.yaml`

## 1. ODS Component And Dependency Map

ODS has a layered shape:

- Installer orchestration: `install.sh` / `install.ps1` call `ods/install-core.sh`
  or platform-specific install paths.
- Installer functional core: `ods/installers/lib/*` detects platform,
  hardware, tiers, compose overlays, package managers, images and service
  metadata.
- Installer imperative shell: `ods/installers/phases/*` performs preflight,
  feature selection, Docker setup, config generation, image pulls, service
  launch and health checks.
- Runtime orchestration: `ods/ods-cli` and
  `ods/scripts/resolve-compose-stack.sh` merge base compose, GPU overlay and
  enabled extension compose fragments.
- Runtime service catalog: `ods/extensions/services/*/manifest.yaml` declares
  service identity, category, ports, dependencies, health and LLM routing.
- Local control plane: dashboard, dashboard-api, host-agent, service registry,
  model router, switchboard state and generated `.env`.
- Trust policy inputs: network exposure policy, remote-provider egress policy,
  generated secrets, dashboard API auth, Hermes magic-link proxy, APE policy
  engine, and extension audit.

### Runtime Dependencies

| Area | Components | Dependencies / route |
|---|---|---|
| Local inference | `llama-server`, `model-router`, GPU overlays | Hardware tier selects model, context, image and compose overlay. Consumers should prefer stable gateway routing where supported. |
| API gateway | `LiteLLM` | Depends on `llama-server`; provides authenticated OpenAI-compatible gateway and `ods/current` routing. |
| Chat | `Open WebUI` | Depends on `llama-server`; can route directly by default or through LiteLLM when switchboard is enabled. Integrates SearXNG, ComfyUI, Whisper, Kokoro and embeddings. |
| Operator control | `dashboard`, `dashboard-api`, host-agent | Dashboard depends on dashboard-api. Dashboard-api uses generated API key, reads manifests, checks Docker/service health, manages setup and selected lifecycle actions. |
| Agent runtime | `Hermes`, `hermes-proxy`, `APE`, `OpenClaw` | Hermes depends on LLM and SearXNG; Hermes is internal-only and fronted by `hermes-proxy`. APE is available for policy/audit but Hermes tool enforcement is not fully wired. OpenClaw is deprecated but installable. |
| Workflow automation | `n8n` | Optional workflow UI with local and external call capability. Requires credentials and strict workflow qualification before trusted use. |
| RAG | `Qdrant`, `embeddings` | Open WebUI and external apps can use embeddings on TEI and store/retrieve vectors in Qdrant. |
| Search and research | `SearXNG`, `Perplexica`, `brave-search` | SearXNG is local metasearch. Perplexica depends on SearXNG and LLM. Brave Search is optional and requires paid API credentials. |
| Voice | `Whisper`, `Kokoro` / `tts` | Open WebUI consumes STT and TTS endpoints; ODS Talk can use Kokoro when enabled. |
| Image generation | `ComfyUI` | GPU-capable optional service, integrated with Open WebUI on supported GPU backends. |
| Privacy and observability | `Privacy Shield`, `Token Spy`, `Langfuse` | Privacy Shield is an inline PII proxy. Token Spy and Langfuse can expose prompts, usage and traces and must be treated as sensitive data stores. |
| Access | `ods-proxy`, `tailscale`, mDNS docs | Proxy provides explicit LAN entry; Tailscale provides remote access. Both are trust boundary changes. |
| Remote providers | `remote-provider-egress`, `remote-provider-ssh-tunnel` | Internal-only scaffolding for optional remote LLM provider routes; must remain fail-closed and policy-bound. |

## 2. QR1 Full-Stack Capability And Trust Matrix

QR1 target: install and evaluate the full broad ODS capability set. Trust is not
binary: a service can be installed and enabled for qualification while remaining
restricted for production-like MS workflows.

| Component | Installed in QR1? | Enabled in QR1? | Trusted in QR1? | Restrictions | Qualification evidence needed |
|---|---:|---:|---|---|---|
| llama-server | Yes | Yes | Conditional | Bind localhost or approved proxy only; no silent cloud fallback for confidential/local-only routes; model/context selected by tier. | Health, `/v1/models`, chat completion, model identity, latency, memory, GPU utilization, no external egress in local mode. |
| LiteLLM | Yes | Yes | Conditional | Require `LITELLM_KEY`; use as primary gateway for swappable LLM consumers; remote routes only through approved egress policy. | Auth enforced, local route works, cloud/hybrid behavior fail-closed for local-only workloads, switchboard route stability. |
| Open WebUI | Yes | Yes | Conditional | `WEBUI_AUTH=true`; route through LiteLLM where switchboard is enabled; do not expose directly outside trusted LAN. | Login/admin bootstrap, chat, RAG, web search, voice, image hooks, route audit, session/security smoke. |
| Hermes | Yes | Yes | Restricted | No direct host port; enter through `hermes-proxy`; treat as shared-agent memory; no client-system writes; no messaging adapters; tool use restricted pending APE integration. | Proxy-gated access, chat, search, file/tool sandbox behavior, memory/session behavior, no direct `9119` host exposure. |
| Hermes proxy | Yes | Yes | Conditional | Requires `ODS_SESSION_SECRET`; magic-link gate is gating, not identity; no public internet exposure. | Cookie verification, expired/tampered cookie rejection, owner-card path, LAN proxy smoke. |
| APE | Yes | Yes | Restricted | Use for policy/audit qualification; do not claim full Hermes enforcement until adapter is proven. | Policy decision audit, allow/deny rules, path/command restrictions, restart persistence, integration coverage with agent surfaces. |
| n8n | Yes | Yes | Restricted | Credentials required; workflows disabled or approval-gated for email send, Jira write, client-system writes, unrestricted egress and production secrets. | Login, local LLM workflow, RAG workflow, webhook auth, outbound allowlist, secret storage, rollback of sample workflows. |
| Qdrant | Yes | Yes | Restricted | Treat vectors/metadata as confidential; bind localhost or approved proxy only; require backup/deletion policy. | Collection lifecycle, RAG retrieval, persistence, auth/exposure assessment, backup/restore. |
| embeddings | Yes | Yes | Conditional | Local-only endpoint unless a client explicitly needs access; no external model download after installation in offline mode. | Health, embedding generation, Open WebUI RAG integration, model cache/offline behavior. |
| Perplexica | Yes | Yes | Restricted | Search queries may be sensitive; no auth in manifest probe; expose only behind trusted access route; no external fallback for confidential routes. | Search-to-LLM flow, SearXNG route, request logging review, auth/proxy mitigation, local-only proof. |
| SearXNG | Yes | Yes | Conditional | Search traffic leaves the box by design; restrict for confidential/client data; no silent fallback to paid/external search. | Engine configuration, query privacy review, Perplexica/Hermes/Open WebUI integration, disabled-external-mode tests. |
| Whisper | Yes | Yes | Conditional | Audio may be sensitive; local-only; no external STT fallback for confidential use. | STT health, sample transcription, Open WebUI integration, model pre-download/offline behavior. |
| Kokoro / tts | Yes | Yes | Conditional | Local-only; voice output should not leak prompt content to external services. | TTS health, OpenAI-compatible route, Open WebUI/ODS Talk playback, model cache/offline behavior. |
| ComfyUI | Yes | Yes on supported GPUs | Conditional | GPU workload isolation; content/output retention review; unavailable GPU classes should degrade visibly. | Health, sample image generation, Open WebUI hook, GPU backend matrix, no blank/error UI on unsupported backends. |
| OpenCode | Yes | Yes for QR1 dev qualification | Restricted | Host-systemd code execution surface; require password; do not grant client-system write access by default; trusted developer use only. | Auth, local LLM route, host service lifecycle, workspace containment, no production secrets exposure. |
| Privacy Shield | Yes | Yes | Conditional | Route sensitive workflows through it; protect re-identification/restoration endpoints with `SHIELD_API_KEY`; binary/streaming behavior must be verified. | PII scrub/restore tests, streaming and large body behavior, auth checks, fail-closed routing tests. |
| Langfuse | Yes | Yes | Restricted | Traces/prompts may contain confidential data; localhost/trusted operator access only; retention policy required. | Login/secrets, trace ingestion from LiteLLM or clients, prompt redaction policy, backup/retention controls. |
| Token Spy | Yes | Yes | Restricted | Usage data can reveal prompt behavior; require API key; expose only to operators. | API auth, dashboard health, LiteLLM/dashboard-api integration, persistence, redaction review. |
| Dashboard | Yes | Yes | Conditional | Operator UI; no unauthenticated admin operations; public URLs must be explicit and valid. | UI smoke, auth/API failure handling, feature discovery, model and extension flows. |
| Dashboard API | Yes | Yes | Conditional | Requires `DASHBOARD_API_KEY`; host-agent operations must remain narrow and authenticated. | Auth tests, setup endpoints, host-agent reachability failure behavior, extension/service discovery. |

Additional QR1-installed helpers should be classified as follows:

| Helper | QR1 posture |
|---|---|
| `model-router` | Installed/enabled core helper; trusted only as internal route manager. Evidence: health, route rendering and no host exposure beyond intended internal path. |
| `remote-provider-egress` | Installed/enabled core scaffold but not trusted for active remote provider use without explicit owner approval and policy evidence. |
| `remote-provider-ssh-tunnel` | Installed/enabled core scaffold but inactive unless remote SSH transport is explicitly configured. |
| `ods-proxy` | Installable/enabled for QR1 LAN tests; trust-restricted because it intentionally changes exposure. |
| `tailscale` | Installable/enabled only in a specific QR1 remote-access qualification lane; not default-trusted. |
| `brave-search` | Installable but not enabled/trusted unless owner provides API key and approves paid external search. |
| `openclaw` | Installable but deprecated and restricted; use only for compatibility qualification, not as preferred MS agent substrate. |

## 3. MS Requirement Classification

The current MS requirements are inferred from `AGENTS.md` and
`docs/ms/decisions/ODS-ADOPTION.md`. Further historical MS requirements should
be imported from `Modern-Solutions-B-V/ms-ops-centre` as reference-only inputs,
then classified through this table.

| MS requirement | Classification | Rationale / adoption action |
|---|---|---|
| Develop MS Ops Centre as a true fork of ODS v2.6.0. | PASS | Repo already records ODS v2.6.0 as initial substrate baseline. Maintain `DOWNSTREAM.md` and upstream merge hygiene. |
| Keep MS requirements, security policy and qualification criteria authoritative. | CONFIGURE | Use MS docs, policy files and QR gates to constrain ODS defaults without forking core flows first. |
| Prefer CONFIGURE > EXTEND > CORE CHANGE. | PASS | ODS exposes manifests, `.env`, model catalog, extension library, ports and docs as safer extension points. |
| Install and evaluate the broad ODS capability set from QR1. | CONFIGURE | Use feature selection and extension enablement to install the full set; classify trust per service rather than removing services. |
| Progressive trust and permissions through machine-enforced policy. | EXTENSION | ODS has APE and exposure/egress policy files, but full service-to-policy enforcement for Hermes, n8n and OpenCode needs MS policy adapters and tests. |
| No unapproved email send, Jira write, client-system writes, root/sudo, production secrets or unrestricted egress. | CONFIGURE / EXTENSION | ODS can keep these disabled by config and workflow policy. Automated enforcement across n8n/Hermes/OpenCode likely requires extensions/adapters. |
| Local-only/confidential routes must never silently fall back externally. | CONFIGURE | Use `ODS_MODE=local`, LiteLLM/switchboard policy, remote-provider egress policy and explicit tests. Do not rely on default example clients that point directly to unauthenticated llama-server. |
| Do not expose secrets in prompts, logs, commits or screenshots. | CONFIGURE | Existing secret scan, generated secrets and support-bundle redaction help; QR1 needs service-specific log/screenshot handling rules. |
| Every behavioral/config/runtime/policy/security/integration change updates MS changelog. | PASS | Existing governance rule. This document is analysis-only, so no changelog entry is required. |
| Preserve upstream ODS mergeability. | PASS / CONFIGURE | Keep MS work in docs, config overlays and extensions first. Core edits must be justified and isolated. |
| Authenticated operator control plane. | CONFIGURE | Dashboard API, Open WebUI, n8n, LiteLLM, Hermes proxy and observability services have auth hooks; QR1 must prove they are generated/enforced in MS profile. |
| Auditable qualification evidence. | EXTENSION | ODS has CI, fleet, audit-extension and validation docs. MS needs an MS-specific QR evidence receipt format and required service evidence checklist. |
| Offline or low-connectivity operation where required. | CONFIGURE | ODS has offline/mirroring guidance. QR1 must pin git ref, images, model artifacts and validation receipts for MS. |
| Client/project isolation. | MISSING | ODS is primarily single-node/local stack. MS client isolation model, data partitioning and retention policy are not yet specified in this repo. |
| Role-based multi-user operation. | MISSING / CORE CHANGE | Hermes SSO explicitly gates access but does not identify users or isolate memories. True per-user agent isolation may require new orchestration and proxy routing. |
| Production-grade signed provenance / SBOM chain. | MISSING | ODS trust docs say full signed release/checksum/SBOM chain is roadmap, not current guarantee. |
| Public-internet deployment. | REJECT for QR1 | Upstream proxy docs explicitly say public internet exposure is not supported without extra auth/TLS. QR1 should remain localhost/trusted-LAN/Tailscale-only. |

## 4. ODS Defaults That Conflict With MS Requirements

| ODS default or documented behavior | MS conflict | QR1 resolution |
|---|---|---|
| Local llama-server examples use no auth and direct `localhost:8080/v1`. | MS wants governed routing and no silent external fallback. | Use direct route only for local qualification. Preferred MS app route is LiteLLM or Privacy Shield with explicit keys and mode policy. |
| Some local model APIs have `auth_required: false` in exposure policy (`llama-server`, embeddings, SearXNG, Perplexica, Whisper, TTS, ComfyUI). | A LAN-exposed service could leak prompts, documents, queries, audio or generated content. | Keep `BIND_ADDRESS=127.0.0.1` except approved proxy/Tailscale lanes. Add QR1 tests proving exposure is as expected. |
| `ods-proxy` defaults `ODS_PROXY_BIND` to `0.0.0.0` when enabled. | It intentionally opens a LAN entry point. | Enable only in the QR1 LAN access lane; require auth checks and document that public internet is rejected. |
| Hermes uses `--insecure` inside the container and has full in-bridge network access. | Agent can execute tools and outbound HTTP inside its sandbox. | Keep Hermes internal-only behind `hermes-proxy`; restrict trust until APE integration and outbound policy are proven. |
| Hermes SSO is gating, not user identity or isolation. | MS may need per-user/client isolation. | QR1 can pass only for shared trusted agent use. Per-user isolation belongs in QR2/QR3 unless required earlier. |
| APE exists but Hermes policy enforcement is documented as a follow-up. | Progressive machine-enforced agent policy is not complete. | Use APE for QR1 policy qualification and make Hermes/agent enforcement a QR2 governance backlog item. |
| n8n can call local and external services once workflows are configured. | Workflow automation can perform unapproved writes or egress. | Keep write/external workflows disabled unless explicitly approved; require workflow allowlist and secret handling evidence. |
| Perplexica probe auth is `none` and search queries leave the system through engines. | Confidential research must not leak query text. | Use only behind trusted access routes; require a confidential-search mode or explicit operator approval for external search. |
| Langfuse and Token Spy store prompts, usage and traces. | Observability can become sensitive data exfiltration or retention risk. | Operator-only access, retention/redaction policy, no public/LAN exposure unless explicitly approved. |
| Tailscale uses host networking. | Remote access expands trust boundary. | QR1 qualification lane only; require owner-approved tailnet ACLs and no unrestricted remote admin exposure. |
| Installer trust path allows mutable `main` bootstrap by default. | MS substrate must be reproducible. | Use pinned v2.6.0 or audited commit for MS builds; record validation receipt. |
| Full signed release, checksum and SBOM chain is roadmap. | MS may require stronger provenance for customer deployment. | QR1 can document gap; QR2 governance backlog should add MS artifact provenance. |

## 5. Services That Can Be Installed/Enabled But Must Remain Trust-Restricted

The following services should be enabled in QR1 qualification but restricted
from trusted MS operation until their evidence gates pass:

- Hermes: autonomous agent with shell/file tools, shared memory and no complete
  APE integration yet.
- APE: policy engine is trusted only after decision logs, persistence and
  enforced integration are verified.
- n8n: workflow automation must not send email, write Jira, write client
  systems, use production secrets or make unrestricted external calls without
  explicit owner approval.
- OpenCode: host-systemd coding surface with code execution and workspace write
  potential.
- Perplexica and SearXNG: search queries are sensitive and may leave the device.
- Qdrant and embeddings: vector data can encode confidential source material.
- Privacy Shield: re-identification paths must be API-key protected and tested.
- Langfuse and Token Spy: observability stores prompts, usage and traces.
- ods-proxy and Tailscale: both expand access beyond localhost.
- remote-provider-egress and remote-provider-ssh-tunnel: must remain inactive
  unless owner-approved remote provider mode is configured.
- Brave Search: paid external API and query disclosure risk.
- OpenClaw: deprecated agent, compatibility-only.

## 6. Recommended QR1 Implementation Sequence

1. Pin substrate and receipts.
   Record upstream ODS v2.6.0, downstream branch, image/model assumptions and
   hardware target classes.

2. Establish MS profile as configuration.
   Define QR1 `.env`/profile expectations for local mode, generated secrets,
   `BIND_ADDRESS=127.0.0.1`, `WEBUI_AUTH=true`, LiteLLM key, dashboard API key,
   Privacy Shield key, n8n credentials and observability credentials.

3. Install full broad service set.
   Enable the requested QR1 components and helper services required to exercise
   them. Do not remove optional components to shrink scope.

4. Prove local inference and gateway routing.
   Validate llama-server, LiteLLM, model-router/switchboard, model identity,
   context window and no external fallback for local-only routes.

5. Prove primary user surfaces.
   Validate Open WebUI, dashboard, dashboard-api, ODS Talk where applicable,
   RAG, search, voice, image generation and model switching.

6. Prove privacy and observability controls.
   Validate Privacy Shield, Token Spy and Langfuse with redaction, auth,
   retention and local-only routing expectations.

7. Prove agent and workflow surfaces as restricted capabilities.
   Validate Hermes behind `hermes-proxy`, APE standalone policy decisions,
   OpenCode auth and n8n workflow auth. Mark each trusted only for the subset
   with evidence.

8. Prove access boundary variants.
   Run separate localhost-only, LAN proxy and Tailscale lanes. Public internet
   remains rejected for QR1.

9. Capture QR1 evidence.
   Store test commands, results, hardware, enabled services, blocked/deferred
   items and rollback instructions in an MS qualification receipt.

## 7. Recommended QR2 Governance Backlog

- MS capability profile file that maps services to trust states, allowed
  routes, external egress permissions and required evidence.
- APE integration adapter for Hermes tool calls, with allow/deny audit and
  restart-safe policy state.
- n8n workflow governance: approved-template registry, disabled-by-default write
  integrations, outbound allowlist and secret classification.
- Per-service exposure audit that compares manifests, compose ports and
  `network-exposure-policy.json`.
- MS evidence receipt template covering install ref, hardware, service set,
  validation commands, skipped gates and rollback.
- Log/screenshot redaction rules for dashboard, Langfuse, Token Spy, n8n and
  agent traces.
- Data retention/deletion policy for Qdrant, Open WebUI uploads, Hermes memory,
  Langfuse traces and Token Spy usage data.
- Remote-provider governance for direct and SSH transports, including explicit
  owner approval and local-only route fail-closed tests.
- Artifact provenance plan: checksums, image digests, model checksums and SBOM
  inventory for MS releases.

## 8. Recommended QR3 Trusted Integration Backlog

- Trusted Jira integration, if approved by the human owner, with write scopes
  separated from read/search scopes.
- Trusted email integration, if approved, with send disabled until a workflow is
  explicitly reviewed and allowed.
- Client-system connectors with per-client environment isolation, secret
  custody, audit trail and revocation.
- Per-user or per-client Hermes isolation if shared-memory agent operation is
  insufficient.
- SSO/identity integration beyond magic-link gating, including revocation and
  attribution.
- Tailscale or private remote access profile with documented ACLs, device tags
  and no public internet exposure.
- Production support bundle workflow that redacts prompts, logs, secrets,
  private hostnames and client identifiers.
- Signed MS release channel with mirrored images/models and repeatable
  validation receipts.

## 9. Areas Where Modifying Upstream Core Is Avoidable

Most MS QR1 needs can avoid core changes:

- Service inclusion: use extension enable/disable state and manifests.
- Trust posture: use `.env`, network exposure policy, remote egress policy and
  MS docs before editing services.
- LLM routing: use LiteLLM, model-router/switchboard settings and service
  manifest `llm` metadata.
- LAN access: use `ods-proxy` and service public URL env vars instead of editing
  each service.
- Remote access: use Tailscale lane rather than public proxy changes.
- RAG/search/voice/image composition: use existing Open WebUI integrations and
  extension service manifests.
- Dashboard feature discovery: rely on manifests and existing `/api/features`
  behavior.
- Provenance: pin refs, images and model artifacts in MS docs/receipts first.
- MS documentation: keep analysis and operating rules under `docs/ms/`.

## 10. Areas Where A Core Change Might Genuinely Be Required

Core changes should remain exceptional and explicitly justified. The likely
cases are:

- End-to-end machine-enforced policy for Hermes tools if upstream Hermes cannot
  be constrained through an adapter, proxy or config-only wrapper.
- True per-user/per-client Hermes isolation, because current Hermes SSO is a
  shared gate and Hermes profile selection is process-bound.
- A first-class MS capability profile consumed by installer, dashboard-api,
  `ods-cli`, compose resolution and extension install flows, if config-only
  profile loading is not enough.
- Guaranteed local-only routing with formal fail-closed enforcement across all
  consumers if LiteLLM/switchboard config cannot prevent direct or external
  fallback paths.
- Service-level auth hardening for components whose upstream service has no
  usable auth hook and must become LAN-accessible in MS deployments.
- Signed release/SBOM/checksum generation if it must be integrated into ODS
  release tooling rather than maintained as an MS wrapper process.
- Host-agent permission separation if QR2/QR3 workflows require narrower
  authority than the current host-agent API boundaries can express.

Any core change should include:

- why configuration or extension was insufficient;
- exact changed runtime/policy behavior;
- affected upstream merge surfaces;
- tests and rollback steps;
- an `ODS-MS-CHANGELOG.md` entry in the same commit.
