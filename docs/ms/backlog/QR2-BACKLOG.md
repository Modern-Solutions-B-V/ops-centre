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
