# QR1 Deploy Runbook

Audience: Modi operating EVO-X3 later. Codex must not run these steps on EVO-X3.

All commands assume the operator is on EVO-X3 and uses the fork only:

```bash
cd ~/ms-ops/ops-centre/ods
git remote -v
git status --short --branch
```

Expected: remote points at `Modern-Solutions-B-V/ops-centre`, branch is the reviewed QR1 branch or merged `ms/main`, and the tree is clean.

Evidence: save command output.

Rollback: stop and return to the previous known-good clone; do not continue from a dirty or public-upstream checkout.

## 1. Host Baseline

```bash
date -Is
hostnamectl
tailscale status
sudo ufw status numbered
ss -tlnp
ollama list
curl -fsS http://127.0.0.1:11434/api/tags
```

Expected: host tailscaled is active, UFW is deny-by-default with approved `tailscale0` rules only, Ollama is reachable on loopback, and no ODS Docker stack is already publishing QR1 ports.

Evidence: save all output.

Rollback: none; inspection only.

## 2. Docker Engine Host Change

Install Docker Engine only if absent.

```bash
docker version
python3 --version
python3 -c 'import yaml; print("python3-yaml available")'
jq --version
```

If missing, follow Docker's official Ubuntu/Debian Engine install procedure for the EVO-X3 OS release, then run:

```bash
sudo systemctl enable --now docker
docker version
docker network ls
sudo ufw status numbered
```

On a clean Ubuntu 24.04 host, install the Python YAML package and `jq` before QR1 gates:

```bash
sudo apt-get update
sudo apt-get install -y python3-yaml jq
python3 -c 'import yaml; print("python3-yaml available")'
jq --version
```

Expected: Docker client/server both report versions; `python3` exists; `import yaml` succeeds; `jq --version` reports the installed jq version; UFW policy is unchanged except Docker's own chains.

Evidence: package install transcript, `docker version`, `python3 --version`, Python YAML import output, `jq --version`, `docker network ls`, and `ufw status numbered`.

Rollback:

```bash
sudo systemctl disable --now docker
sudo apt-get purge docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
sudo rm -rf /var/lib/docker /var/lib/containerd
sudo ufw reload
```

## 3. Clone From Fork

```bash
mkdir -p ~/ms-ops
cd ~/ms-ops
git clone git@github.com:Modern-Solutions-B-V/ops-centre.git
cd ops-centre
git switch ms/main
git pull --ff-only origin ms/main
git log -1 --oneline
cd ods
```

Expected: clone succeeds from the fork, not `install.osmantic.com` and not `Osmantic/ODS`.

Evidence: remote URL and commit SHA.

Rollback:

```bash
cd ~
rm -rf ~/ms-ops/ops-centre
```

## 4. Generate QR1 Profile

```bash
cd ~/ms-ops/ops-centre/ods
cp profiles/ms-qr1.env.example .env
chmod 600 .env
```

Generate values and replace every `GENERATE_ME` placeholder except `MS_QR1_HOST_GATEWAY`, which is filled after Docker network discovery in section 7:

```bash
openssl rand -hex 32
openssl rand -base64 32 | tr '+/' '-_' | tr -d '='
printf 'sk-ods-%s\n' "$(openssl rand -hex 16)"
ollama list
```

Rules:

- `BIND_ADDRESS=127.0.0.1`.
- `HERMES_DASHBOARD_TUI=0`.
- `ODS_AGENT_HOST=` remains empty on native Linux so dashboard-api uses the resolved Docker gateway path instead of `host.docker.internal`.
- `EXTERNAL_LLM_MODEL` must remain `qwen3.8:27b` unless Modi explicitly approves a different QR1 model and updates `config/litellm/ms-qr1.yaml` in the same reviewed change.
- `DASHBOARD_API_KEY` and `ODS_AGENT_KEY` must be distinct.
- `QDRANT_API_KEY`, `SEARXNG_SECRET`, Langfuse secrets, and Token Spy key must be non-empty.
- `LANGFUSE_DB_PASSWORD` must use hex or URL-safe base64 because it is interpolated into a PostgreSQL URL.
- `ANTHROPIC_API_KEY` is present only in `.env` for the LiteLLM container; no email, Jira, client-system, production, Brave, MiniMax, OpenAI, or Tailscale container keys are configured.
- QR1 shares the LiteLLM master key with Open WebUI and Hermes because this ODS/LiteLLM profile has no clean CONFIGURE-only scoped virtual-key provisioning path. This is a QR1 limitation and is tracked for QR2.
- Mirror generated secrets to Bitwarden; never paste real values into docs, commits, issue comments, or screenshots.

Validate the filled profile before continuing:

```bash
bash scripts/validate-env.sh .env
```

Expected: the QR1 `.env` validates against `.env.schema.json` with no unknown keys.

Evidence: validation output.

Rollback: remove `.env` and regenerate from `profiles/ms-qr1.env.example`.

Validate before Docker gateway discovery:

```bash
grep -nE 'CHANGEME|GENERATE_ME' .env | grep -v '^.*MS_QR1_HOST_GATEWAY=GENERATE_ME_DOCKER_GATEWAY$'
grep -nE '^(BIND_ADDRESS|HERMES_DASHBOARD_TUI|ODS_AGENT_HOST|QDRANT_API_KEY|SEARXNG_SECRET|ANTHROPIC_API_KEY)=' .env
```

Expected: first command prints nothing; second command shows QR1 values. Do not publish screenshots containing real values.

Evidence: redacted notes confirming no placeholders except `MS_QR1_HOST_GATEWAY` before section 7 and file mode `600`.

Rollback:

```bash
shred -u .env
cp profiles/ms-qr1.env.example .env
chmod 600 .env
```

## 5. Pre-Render Policy Check

Use a temporary gateway only to render the QR1 policy before host mutation. Replace it with the discovered gateway in section 7 before starting services.

```bash
cd ~/ms-ops/ops-centre/ods
scripts/ms-qr1-compose-flags.sh
MS_QR1_HOST_GATEWAY=127.0.0.1 docker compose $(scripts/ms-qr1-compose-flags.sh) config > /tmp/qr1-compose.preflight.yml
grep -n 'ms-qr1.yaml' /tmp/qr1-compose.preflight.yml
grep -n 'HERMES_DASHBOARD_TUI.*0' /tmp/qr1-compose.preflight.yml
grep -nE 'openclaw|tailscale|ods-proxy|brave-search|opencode|remote-provider-egress|remote-provider-ssh-tunnel' /tmp/qr1-compose.preflight.yml
if grep -n 'fallbacks:' config/litellm/ms-qr1.yaml; then
  echo "unexpected LiteLLM fallback configuration"
  exit 1
fi
```

Expected: QR1 config is mounted; Hermes TUI is `0`; excluded services are absent or profile-gated outside active QR1; the fallback grep prints nothing and exits non-zero.

Evidence: save `/tmp/qr1-compose.preflight.yml` and grep output.

Rollback: no host mutation.

## 6. Pre-Start Provisioning

```bash
mkdir -p data/langfuse/postgres data/langfuse/clickhouse
bash extensions/services/langfuse/hooks/post_install.sh "$PWD" "${GPU_BACKEND:-amd}"

mkdir -p data/comfyui/ComfyUI/models/checkpoints data/comfyui/miopen logs
SDXL_REVISION=c6c10e8716de60c7ef4eed6b89a06f67e772b374
SDXL_SHA256=e0d996ee0013e79d9d3561f50fcafb9a17e3ff07b780358e3b66d67932c4d490
SDXL_FILE=data/comfyui/ComfyUI/models/checkpoints/sdxl_lightning_4step.safetensors
curl -fSL --connect-timeout 30 --max-time 3600 \
  --retry 5 --retry-delay 10 --retry-all-errors \
  -o "${SDXL_FILE}.part" \
  "https://huggingface.co/ByteDance/SDXL-Lightning/resolve/${SDXL_REVISION}/sdxl_lightning_4step.safetensors"
printf '%s  %s\n' "$SDXL_SHA256" "${SDXL_FILE}.part" | sha256sum -c -
mv -f "${SDXL_FILE}.part" "$SDXL_FILE"
```

Expected: Langfuse PostgreSQL and ClickHouse bind-mount directories are owned for their container users; SDXL Lightning checkpoint exists only after SHA256 verification succeeds.

Evidence:

```bash
stat -c '%U:%G %n' data/langfuse/postgres data/langfuse/clickhouse
sha256sum data/comfyui/ComfyUI/models/checkpoints/sdxl_lightning_4step.safetensors
```

Rollback:

```bash
sudo rm -rf data/langfuse/postgres data/langfuse/clickhouse
rm -f data/comfyui/ComfyUI/models/checkpoints/sdxl_lightning_4step.safetensors*
```

## 7. Create QR1 Docker Network And Fill Gateway

Create QR1 Docker networks through Compose before final render. Use a temporary gateway only for this no-start network/container creation step; section 11 force-recreates containers after the real gateway is written to `.env`. The internal Langfuse network is intentionally not granted host access.

```bash
MS_QR1_HOST_GATEWAY=127.0.0.1 docker compose $(scripts/ms-qr1-compose-flags.sh) up -d --build --no-start
MS_QR1_HOST_GATEWAY=127.0.0.1 scripts/ms-qr1-ollama-bridge.sh plan | tee /tmp/qr1-ollama-bridge.plan.txt
MS_QR1_HOST_GATEWAY="$(awk -F= '$1 == "MS_QR1_HOST_GATEWAY" {print $2}' /tmp/qr1-ollama-bridge.plan.txt | tail -1)"
test -n "$MS_QR1_HOST_GATEWAY"
sed -i "s/^MS_QR1_HOST_GATEWAY=.*/MS_QR1_HOST_GATEWAY=${MS_QR1_HOST_GATEWAY}/" .env
grep -n '^MS_QR1_HOST_GATEWAY=' .env
docker compose $(scripts/ms-qr1-compose-flags.sh) config > /tmp/qr1-compose.rendered.yml
```

Expected: Compose creates and labels QR1 networks consistently; `MS_QR1_HOST_GATEWAY` is the private Docker gateway IP for the rendered network named `ods-network`; the rendered stack uses `ms-qr1-host:<gateway>` and does not use `host.docker.internal` for Ollama.

Evidence: `docker compose ps -a`, `docker network inspect ods-network`, `/tmp/qr1-ollama-bridge.plan.txt`, redacted `.env` line, and `/tmp/qr1-compose.rendered.yml`.

Rollback:

```bash
sed -i 's/^MS_QR1_HOST_GATEWAY=.*/MS_QR1_HOST_GATEWAY=GENERATE_ME_DOCKER_GATEWAY/' .env
MS_QR1_HOST_GATEWAY=127.0.0.1 docker compose $(scripts/ms-qr1-compose-flags.sh) down
```

## 8. Install Host-Agent Service

QR1 requires the host-agent on TCP `7710` for the approved dashboard-api host control boundary. The service must be installed before UFW and acceptance checks.

```bash
agent_tmp="$(mktemp)"
sed \
  -e "s|__INSTALL_USER__|$USER|g" \
  -e "s|__PYTHON3__|$(command -v python3)|g" \
  -e "s|__INSTALL_DIR__|$PWD|g" \
  -e "s|__HOME__|$HOME|g" \
  scripts/systemd/ods-host-agent.service > "$agent_tmp"
sudo install -m 0644 "$agent_tmp" /etc/systemd/system/ods-host-agent.service
rm -f "$agent_tmp"
sudo systemctl daemon-reload
sudo systemctl enable --now ods-host-agent.service
systemctl status ods-host-agent.service --no-pager
ss -tlnp | grep ':7710'
```

Expected: host-agent is running and listening on the resolved Docker gateway or loopback bind address, never a wildcard listener.

Evidence: rendered service file checksum, `systemctl status`, `journalctl -u ods-host-agent.service -n 30 --no-pager`, and `ss -tlnp`.

Rollback:

```bash
sudo systemctl disable --now ods-host-agent.service
sudo rm -f /etc/systemd/system/ods-host-agent.service
sudo systemctl daemon-reload
```

## 9. Narrow Ollama Docker Bridge

Do not set `OLLAMA_HOST=0.0.0.0`. QR1 keeps host-native Ollama loopback-only and installs a narrow host-side `socat` bridge that listens only on discovered non-internal Docker gateway IP addresses and forwards to `127.0.0.1:11434`.

Plan first:

```bash
scripts/ms-qr1-ollama-bridge.sh plan
scripts/ms-qr1-ollama-bridge.sh render-unit | tee /tmp/ms-qr1-ollama-bridge.service
grep 'bind=$$addr' /tmp/ms-qr1-ollama-bridge.service
grep 'Environment="MS_QR1_OLLAMA_BRIDGE_ADDRS=' /tmp/ms-qr1-ollama-bridge.service
```

Install `socat` if absent, then install the bridge:

```bash
if command -v socat; then
  echo "socat already installed"
else
  sudo apt-get install -y socat
fi
sudo scripts/ms-qr1-ollama-bridge.sh install
curl -fsS http://127.0.0.1:11434/api/tags
systemctl status ms-qr1-ollama-bridge.service --no-pager
ss -tlnp | grep ':11434'
```

Expected: Ollama still answers on `127.0.0.1:11434`; `ms-qr1-ollama-bridge.service` listens on non-internal Docker gateway IP address(es), not `0.0.0.0` or `::`.

Evidence: bridge plan output, rendered unit, `systemctl status`, and `ss -tlnp` showing listener addresses.

Rollback:

```bash
sudo scripts/ms-qr1-ollama-bridge.sh remove
sudo apt-get purge socat
```

Only purge `socat` if QR1 installed it and no other local service needs it.

## 10. Docker Subnet UFW Rules

Plan first:

```bash
scripts/ms-qr1-ufw-docker-rules.sh plan | tee /tmp/ms-qr1-ufw.plan.txt
```

Apply only after verifying every discovered CIDR is a private non-internal Docker network:

```bash
sudo scripts/ms-qr1-ufw-docker-rules.sh apply
sudo ufw status numbered
```

Expected: narrowly scoped allow rules exist from discovered non-internal Docker CIDR(s) to the matching host gateway TCP ports `11434` and `7710` only. No rule is created for `ods_langfuse-internal`.

Evidence: plan output, apply output, CIDR(s), `ufw status numbered` before/after, and generated rule comments.

Rollback:

```bash
sudo scripts/ms-qr1-ufw-docker-rules.sh remove
sudo ufw status numbered
```

Expected rollback: no `MS QR1 docker-to-host` rules remain. Use the helper rather than deleting numbered rules manually because UFW rule numbers renumber after each delete.

## 11. Start QR1 Stack

```bash
docker compose $(scripts/ms-qr1-compose-flags.sh) up -d --build --force-recreate
docker compose $(scripts/ms-qr1-compose-flags.sh) ps
```

Expected: approved QR1 services start. Native Ollama remains the inference path; no AMD tuning, UMA/GTT/IOMMU, Lemonade, ODS Tailscale, OpenClaw, Brave Search, ods-proxy, ODS OpenCode extension, remote-provider egress service, or remote-provider SSH tunnel starts.

Evidence: `docker compose ps`.

Rollback:

```bash
sudo scripts/ms-qr1-ufw-docker-rules.sh remove
docker compose $(scripts/ms-qr1-compose-flags.sh) down
```

If `docker compose down`, Docker network removal, or subnet reallocation occurs, rerun section 7, restart the host-agent, then rerun sections 9, 10, and 11:

```bash
sudo systemctl restart ods-host-agent.service
systemctl status ods-host-agent.service --no-pager
```

The helpers intentionally rediscover current network gateways and rules rather than assuming a fixed Docker CIDR. The host-agent must restart because its Linux bind address is resolved once at service start.

## 12. Container-To-Host Inference Boundary

```bash
for service in litellm dashboard-api perplexica privacy-shield token-spy; do
  docker compose $(scripts/ms-qr1-compose-flags.sh) exec -T "$service" sh -c '
    url=http://ms-qr1-host:11434/api/tags
    if command -v python3 >/dev/null; then
      python3 -c "import urllib.request; print(urllib.request.urlopen(\"$url\", timeout=5).status)"
    elif command -v curl >/dev/null; then
      curl -fsS -o /dev/null -w "%{http_code}\n" "$url"
    elif command -v wget >/dev/null; then
      wget -q -O /dev/null "$url" && echo 200
    else
      echo "no supported probe tool in $HOSTNAME"
    fi
  '
done
ss -tlnp | grep ':11434'
sudo ufw status numbered
```

Expected: containers receive HTTP `200` from host-native Ollama through `ms-qr1-host`; host `ss` shows no `0.0.0.0:11434` or `[::]:11434` listener; UFW permits only non-internal Docker CIDR(s) to the Docker gateway on port `11434`.

Evidence: command outputs.

Rollback: remove the Ollama bridge in section 9 and UFW rules in section 10.

## 13. Tailscale Serve

Use host tailscaled only. Do not enable the ODS Tailscale extension or ods-proxy.

Example mapping pattern:

```bash
sudo tailscale serve --bg --https=443 http://127.0.0.1:3001
tailscale serve status
```

Map only approved QR1 operator surfaces. Keep internal/admin surfaces loopback unless explicitly approved for serve.

Expected: `tailscale serve status` lists only approved services; off-tailnet/LAN scans cannot reach QR1 ports.

Evidence: `tailscale serve status`, off-tailnet scan results.

Rollback:

```bash
sudo tailscale serve reset
tailscale serve status
```

## 14. Acceptance Checks

Blocking QR1 gate:

```bash
sudo EXPECTED_MODEL=qwen3.8:27b ENV_FILE="$PWD/.env" scripts/ms-qr1-acceptance.sh
bash scripts/validate-env.sh .env
python3 scripts/audit-extensions.py
bash tests/test-safe-env.sh
bash tests/test-secret-security.sh
bash tests/test-ms-qr1-helpers.sh
python3 tests/contracts/test-network-exposure-contracts.py
```

Expected: acceptance checks pass. Qdrant unauthenticated requests must be rejected. Hermes host port `9119` must be unbound. Local-only LiteLLM routes must have no fallback. Rendered QR1 services must match the allow-list/exclusion policy. Every rendered published QR1 service port must bind loopback. Host-agent nmcli endpoints must reject unauthenticated requests on the resolved host-agent bind address.

Diagnostic, not a QR1 blocking gate:

```bash
set +e
bash tests/test-network-security.sh
echo "diagnostic exit=$?"
set -e
```

Expected diagnostic result as of PR #6: the static script reports broad findings against optional compose files and the ODS Tailscale host-network extension while also reporting zero insecure port bindings. Record the output, but do not treat it as the QR1 deploy gate because it does not model the explicit QR1 compose file set.

Evidence: command outputs.

Rollback for failed blocking acceptance: capture logs, then run the stack rollback in section 11, UFW rollback in section 10, Ollama bridge rollback in section 9, and host-agent rollback in section 8.

## 15. Host-Agent nmcli Boundary

No supported QR1 config switch exists to remove the host-agent nmcli/Wi-Fi routes. QR1 keeps stock host-agent behavior and relies on API-key authentication plus Docker-gateway/UFW scoping.

Derive the actual Linux bind address and test unauthenticated access:

```bash
AGENT_BIND="$(awk -F= '$1 == "ODS_AGENT_BIND" {print $2}' .env | tail -1)"
if [ -z "$AGENT_BIND" ]; then
  AGENT_BIND="$(docker network inspect ods-network --format '{{range .IPAM.Config}}{{println .Gateway}}{{end}}' | awk 'NF {print; exit}')"
fi
curl -i "http://${AGENT_BIND:-127.0.0.1}:7710/v1/network/wifi-scan"
curl -i -X POST "http://${AGENT_BIND:-127.0.0.1}:7710/v1/network/wifi-connect" \
  -H 'Content-Type: application/json' \
  -d '{"ssid":"x","password":"x"}'
```

Expected: `401` or `403`; no nmcli action occurs.

Evidence: HTTP status and host-agent logs.

Rollback: stop host-agent if the boundary fails:

```bash
sudo systemctl stop ods-host-agent.service
```

## 16. Full Rollback

```bash
cd ~/ms-ops/ops-centre/ods
sudo scripts/ms-qr1-ufw-docker-rules.sh remove
docker compose $(scripts/ms-qr1-compose-flags.sh) down
sudo tailscale serve reset
sudo scripts/ms-qr1-ollama-bridge.sh remove
sudo systemctl disable --now ods-host-agent.service
sudo rm -f /etc/systemd/system/ods-host-agent.service
sudo systemctl daemon-reload
shred -u .env
```

Expected: QR1 containers stopped, Tailscale serve mappings removed, every QR1 UFW rule removed, Ollama bridge removed, host-agent removed, and secrets removed from disk.
