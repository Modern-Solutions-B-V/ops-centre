# QR2 Backlog

## MSODS-QR2-0001 — Scoped LiteLLM Consumer Keys

Classification: CONFIGURE preferred; EXTEND acceptable if LiteLLM requires a small provisioning helper. CORE CHANGE is not approved.

QR1 shares `LITELLM_MASTER_KEY` with Open WebUI and Hermes because the current ODS LiteLLM profile does not provide a clean CONFIGURE-only path to mint and distribute scoped virtual keys during deploy. QR2 should add scoped consumer keys for each LiteLLM client, keep the master key limited to the LiteLLM proxy/admin boundary, and document rotation plus rollback.

Acceptance:

- Open WebUI and Hermes use non-admin LiteLLM virtual keys.
- LiteLLM admin/master key is not exposed to consumer containers.
- Key creation is reproducible from documented operator commands.
- No upstream ODS core change is introduced without explicit approval.

## MSODS-QR2-0002 — QR1 Operator Surface Route Review

Classification: CONFIGURE preferred.

QR1 operator readiness classifies Hermes, n8n, Langfuse, Perplexica and ComfyUI as
operator-facing capabilities but does not approve new Tailscale Serve routes
for them by default. Dashboard and the temporary Open WebUI private route are
the only canonical MacBook launch URLs introduced during the QR1 readiness
work. QR2 should decide which additional operator surfaces need private
Tailscale Serve routes, what authentication contract each must satisfy, and
how Dashboard Quick Links should advertise them without exposing internal
platform services.

Acceptance:

- Every approved operator route has an explicit Tailscale Serve mapping,
  authentication contract and rollback.
- Internal services remain internal by default.
- Dashboard Quick Links use the canonical QR1 operator access registry or a
  reviewed successor data source.
- No public Funnel route is introduced without a separate security review.

## MSODS-QR2-0003 — Phase 2 Functional Use-Case Testing

Classification: CONFIGURE / EXTEND depending on test harness needs.

After QR1 operator readiness is green, run functional/use-case testing for
local Qwen prompts, Hermes agent behavior, n8n workflows, GitHub/Calendar/Gmail
tool connectivity, RAG, voice, research, privacy routing, external-model
escalation and observability. QR1 readiness is intentionally broad and shallow;
it proves the scoped capabilities are installed, healthy, reachable where
approved and bootstrapped, not that every workflow behaves correctly.

Acceptance:

- Each use case has non-confidential fixtures.
- No default test path uses paid external model APIs.
- External service/tool credentials are injected through approved secret
  handling only.

## MSODS-QR2-0004 — Open WebUI SQLite WAL Readiness Hardening

Classification: HARDENING.

QR1/pinned Open WebUI does not enable `DATABASE_ENABLE_SQLITE_WAL`; the QR1
readiness check uses immutable read-only SQLite inspection and fails closed if
that assumption changes. If WAL mode is enabled or observed live, add a
WAL-aware, still read-only admin-state proof before treating Open WebUI
bootstrap as ready.

Acceptance:

- Readiness does not create, modify or require chown/chmod of SQLite sidecar
  files.
- WAL-enabled Open WebUI admin state can be proven without mutating
  `data/open-webui`.
- Missing or unreadable admin state remains NOT READY.

## MSODS-QR2-0005 — DNS Hostname Schema Hardening

Classification: HARDENING.

The current EVO-X3 Tailscale hostname is valid and accepted by the QR1 schema.
Future schema hardening should reject edge-case DNS labels such as trailing
hyphens without changing the QR1 operator route architecture.

Acceptance:

- `MS_QR1_TAILSCALE_HOSTNAME` rejects malformed DNS label edge cases.
- Existing valid Tailscale hostnames continue to validate.
- No hard-coded hostnames are introduced.
