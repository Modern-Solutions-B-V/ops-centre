# QR1 Stack Implementation Handover

Date: 2026-08-16

Branch: `feature/qr1-stack`

Classification: CONFIGURE with EXTEND helper scripts. No CORE CHANGE.

## Delivered

- Placeholder-only QR1 env profile: `ods/profiles/ms-qr1.env.example`.
- QR1 LiteLLM config: `ods/config/litellm/ms-qr1.yaml`.
- QR1 compose override: `ods/docker-compose.ms-qr1.yml`.
- QR1 compose file selector: `ods/scripts/ms-qr1-compose-flags.sh`.
- Langfuse enabled by directly referencing the shipped dormant template: `ods/extensions/services/langfuse/compose.yaml.disabled`.
- UFW Docker-subnet discovery helper: `ods/scripts/ms-qr1-ufw-docker-rules.sh`.
- Narrow host Ollama bridge helper: `ods/scripts/ms-qr1-ollama-bridge.sh`.
- QR1 acceptance helper: `ods/scripts/ms-qr1-acceptance.sh`.
- QR1 helper regression tests: `ods/tests/test-ms-qr1-helpers.sh`.
- Operator runbook: `docs/ms/deploy/QR1-DEPLOY-RUNBOOK.md`.
- Changelog entries: `MSODS-0004`, `MSODS-0005`, `MSODS-0006`, `MSODS-0007`, `MSODS-0008`, `MSODS-0009`.

## Boundaries

- Native host Ollama remains the inference path.
- QR1 does not bind Ollama to `0.0.0.0`; containers reach it through `ms-qr1-host:<MS_QR1_HOST_GATEWAY>`, which points at the actual non-internal ODS Docker gateway where the host-side `socat` bridge listens.
- UFW rules are scoped from non-internal Docker CIDR(s) to their matching Docker gateway on TCP `11434` and `7710`; the internal Langfuse network is excluded.
- The host-agent systemd service is a required QR1 host prerequisite because the approved trust matrix includes dashboard-api host-agent access on `7710`.
- No AMD tuning, UMA/GTT/IOMMU, Lemonade, email, Jira, client-system credentials, production secrets, ODS Tailscale extension, ods-proxy, Brave Search, OpenClaw, ODS OpenCode extension, remote-provider egress service, or remote-provider SSH tunnel are enabled.
- `model-router` remains present in the rendered QR1 stack as an inert/internal core service: it publishes no port and its configured endpoint points only at excluded `llama-server:8080`, so it is not a QR1 egress path.
- Hermes dashboard TUI is forced off with `HERMES_DASHBOARD_TUI=0`.
- Qdrant and SearXNG require non-empty generated secrets.
- Host-agent nmcli routes have no supported disable switch in upstream config; QR1 documents and tests unauthenticated denial instead of editing core host-agent code.
- LiteLLM scoped virtual consumer keys are deferred to QR2. QR1 shares the LiteLLM master key with Open WebUI and Hermes because there is no clean CONFIGURE-only virtual-key provisioning path in this ODS profile without adding deployment complexity or touching core code.
- Clean Ubuntu 24.04 deploy hosts must have `python3-yaml` and `jq` before QR1 validation; `jq` is required by `scripts/validate-env.sh`.

## Validation To Repeat On Deploy Host

```bash
cd ods
docker compose $(scripts/ms-qr1-compose-flags.sh) config
sudo EXPECTED_MODEL=<qr1-ollama-model> ENV_FILE="$PWD/.env" scripts/ms-qr1-acceptance.sh
bash scripts/validate-env.sh .env
python3 scripts/audit-extensions.py
bash tests/test-safe-env.sh
bash tests/test-secret-security.sh
bash tests/test-ms-qr1-helpers.sh
python3 tests/contracts/test-network-exposure-contracts.py
git diff --check
```

`tests/test-network-security.sh` remains diagnostic evidence only. It is not a blocking QR1 deploy gate because it does not model the explicit QR1 compose file set.

## Rollback

Follow `docs/ms/deploy/QR1-DEPLOY-RUNBOOK.md`: run `sudo scripts/ms-qr1-ufw-docker-rules.sh remove` before Compose teardown, stop the compose stack, remove Tailscale serve mappings, remove the MS QR1 Ollama bridge, remove the host-agent unit, and shred the filled `.env`.
