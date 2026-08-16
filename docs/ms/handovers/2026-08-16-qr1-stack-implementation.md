# QR1 Stack Implementation Handover

Date: 2026-08-16

Branch: `feature/qr1-stack`

Classification: CONFIGURE with EXTEND helper scripts. No CORE CHANGE.

## Delivered

- Placeholder-only QR1 env profile: `ods/profiles/ms-qr1.env.example`.
- QR1 LiteLLM config: `ods/config/litellm/ms-qr1.yaml`.
- QR1 compose override: `ods/docker-compose.ms-qr1.yml`.
- QR1 compose file selector: `ods/scripts/ms-qr1-compose-flags.sh`.
- Langfuse enabled from the shipped dormant template: `ods/extensions/services/langfuse/compose.yaml`.
- UFW Docker-subnet discovery helper: `ods/scripts/ms-qr1-ufw-docker-rules.sh`.
- Narrow host Ollama bridge helper: `ods/scripts/ms-qr1-ollama-bridge.sh`.
- QR1 acceptance helper: `ods/scripts/ms-qr1-acceptance.sh`.
- QR1 helper regression tests: `ods/tests/test-ms-qr1-helpers.sh`.
- Operator runbook: `docs/ms/deploy/QR1-DEPLOY-RUNBOOK.md`.
- Changelog entries: `MSODS-0004`, `MSODS-0005`.

## Boundaries

- Native host Ollama remains the inference path.
- QR1 does not bind Ollama to `0.0.0.0`; containers reach it through a host-side `socat` bridge bound only to discovered Docker gateway address(es), with UFW scoped to Docker CIDR(s).
- No AMD tuning, UMA/GTT/IOMMU, Lemonade, email, Jira, client-system credentials, production secrets, ODS Tailscale extension, ods-proxy, Brave Search, OpenClaw, or ODS OpenCode extension are enabled.
- Hermes dashboard TUI is forced off with `HERMES_DASHBOARD_TUI=0`.
- Qdrant and SearXNG require non-empty generated secrets.
- Host-agent nmcli routes have no supported disable switch in upstream config; QR1 documents and tests unauthenticated denial instead of editing core host-agent code.

## Validation To Repeat On Deploy Host

```bash
cd ods
docker compose $(scripts/ms-qr1-compose-flags.sh) config
EXPECTED_MODEL=<qr1-ollama-model> scripts/ms-qr1-acceptance.sh
python scripts/audit-extensions.py
bash tests/test-safe-env.sh
bash tests/test-secret-security.sh
bash tests/test-ms-qr1-helpers.sh
python tests/contracts/test-network-exposure-contracts.py
git diff --check
```

`bash tests/test-network-security.sh || true` remains diagnostic evidence only. It is not a blocking QR1 deploy gate because it does not model the explicit QR1 compose file set.

## Rollback

Follow `docs/ms/deploy/QR1-DEPLOY-RUNBOOK.md`: stop the compose stack, remove Tailscale serve mappings, remove the MS QR1 Ollama bridge, delete every MS QR1 UFW rule by number in descending order, and shred the filled `.env`.
