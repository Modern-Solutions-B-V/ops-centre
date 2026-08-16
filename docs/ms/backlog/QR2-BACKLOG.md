# QR2 Backlog

## MSODS-QR2-0001 — Scoped LiteLLM Consumer Keys

Classification: CONFIGURE preferred; EXTEND acceptable if LiteLLM requires a small provisioning helper. CORE CHANGE is not approved.

QR1 shares `LITELLM_MASTER_KEY` with Open WebUI and Hermes because the current ODS LiteLLM profile does not provide a clean CONFIGURE-only path to mint and distribute scoped virtual keys during deploy. QR2 should add scoped consumer keys for each LiteLLM client, keep the master key limited to the LiteLLM proxy/admin boundary, and document rotation plus rollback.

Acceptance:

- Open WebUI and Hermes use non-admin LiteLLM virtual keys.
- LiteLLM admin/master key is not exposed to consumer containers.
- Key creation is reproducible from documented operator commands.
- No upstream ODS core change is introduced without explicit approval.
