# QR1 Deploy Runbook

Audience: Modi operating EVO-X3 later. Codex must not run these steps on EVO-X3.

All commands assume the operator is on EVO-X3 and uses the fork only:

```bash
cd ~/ops-centre/ods
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

Expected: host tailscaled is active, UFW is deny-by-default with approved tailscale0 rules only, Ollama is reachable on loopback, and no ODS Docker stack is already publishing QR1 ports.

Evidence: save all output.

Rollback: none; inspection only.

## 2. Docker Engine Host Change

Install Docker Engine only if absent.

```bash
docker version
```

If missing, follow Docker's official Ubuntu/Debian Engine install procedure for the EVO-X3 OS release, then run:

```bash
sudo systemctl enable --now docker
docker version
docker network ls
sudo ufw status numbered
```

Expected: Docker client/server both report versions; UFW policy is unchanged except Docker's own chains.

Evidence: package install transcript, `docker version`, `docker network ls`, and `ufw status numbered`.

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

Generate values and replace every `GENERATE_ME` placeholder:

```bash
openssl rand -hex 32
openssl rand -base64 32 | tr '+/' '-_' | tr -d '='
printf 'sk-ods-%s\n' "$(openssl rand -hex 16)"
ollama list
```

Rules:

- `BIND_ADDRESS=127.0.0.1`.
- `EXTERNAL_LLM_MODEL` must remain `qwen3.8:27b` unless Modi explicitly approves a different QR1 model and updates `config/litellm/ms-qr1.yaml` in the same reviewed change.
- `DASHBOARD_API_KEY` and `ODS_AGENT_KEY` must be distinct.
- `QDRANT_API_KEY`, `SEARXNG_SECRET`, Langfuse secrets, and Token Spy key must be non-empty.
- `LANGFUSE_DB_PASSWORD` must use hex or URL-safe base64 because it is interpolated into a PostgreSQL URL.
- `ANTHROPIC_API_KEY` is present only in `.env` for the LiteLLM container; no email, Jira, client-system, production, Brave, MiniMax, OpenAI, or Tailscale container keys are configured.
- Mirror generated secrets to Bitwarden; never paste real values into docs, commits, issue comments, or screenshots.

Validate:

```bash
grep -nE 'CHANGEME|GENERATE_ME' .env
grep -nE '^(BIND_ADDRESS|HERMES_DASHBOARD_TUI|QDRANT_API_KEY|SEARXNG_SECRET|ANTHROPIC_API_KEY)=' .env
```

Expected: first command prints nothing; second command shows QR1 values without displaying screenshots publicly.

Evidence: redacted notes confirming no placeholders and file mode `600`.

Rollback:

```bash
shred -u .env
cp profiles/ms-qr1.env.example .env
chmod 600 .env
```

## 5. Render Stack

```bash
cd ~/ms-ops/ops-centre/ods
scripts/ms-qr1-compose-flags.sh
docker compose $(scripts/ms-qr1-compose-flags.sh) config > /tmp/qr1-compose.rendered.yml
grep -n 'ms-qr1.yaml' /tmp/qr1-compose.rendered.yml
grep -n 'HERMES_DASHBOARD_TUI.*0' /tmp/qr1-compose.rendered.yml
grep -nE 'openclaw|tailscale|ods-proxy|brave-search|opencode' /tmp/qr1-compose.rendered.yml || true
grep -n 'fallbacks:' config/litellm/ms-qr1.yaml || true
```

Expected: QR1 config is mounted; Hermes TUI is `0`; `llama-server` is profile-gated as `ms-qr1-excluded`; OpenClaw, ODS Tailscale, ods-proxy, Brave Search and ODS OpenCode are absent from the QR1 compose file set; the fallback grep prints nothing.

Evidence: save `/tmp/qr1-compose.rendered.yml` and grep output.

Rollback: no host mutation.

## 6. Pre-Start Provisioning

```bash
mkdir -p data/langfuse/postgres data/langfuse/clickhouse
bash extensions/services/langfuse/hooks/post_install.sh "$PWD" "${GPU_BACKEND:-amd}"

mkdir -p data/comfyui/ComfyUI/models/checkpoints data/comfyui/miopen logs
curl -fSL -C - --connect-timeout 30 --max-time 3600 \
  --retry 5 --retry-delay 10 --retry-all-errors \
  -o data/comfyui/ComfyUI/models/checkpoints/sdxl_lightning_4step.safetensors.part \
  https://huggingface.co/ByteDance/SDXL-Lightning/resolve/main/sdxl_lightning_4step.safetensors
mv data/comfyui/ComfyUI/models/checkpoints/sdxl_lightning_4step.safetensors.part \
  data/comfyui/ComfyUI/models/checkpoints/sdxl_lightning_4step.safetensors
```

Expected: Langfuse PostgreSQL and ClickHouse bind-mount directories are owned for their container users; SDXL Lightning checkpoint exists at `data/comfyui/ComfyUI/models/checkpoints/sdxl_lightning_4step.safetensors`.

Evidence:

```bash
stat -c '%U:%G %n' data/langfuse/postgres data/langfuse/clickhouse
ls -lh data/comfyui/ComfyUI/models/checkpoints/sdxl_lightning_4step.safetensors
```

Rollback:

```bash
sudo rm -rf data/langfuse/postgres data/langfuse/clickhouse
rm -f data/comfyui/ComfyUI/models/checkpoints/sdxl_lightning_4step.safetensors*
```

## 7. Create QR1 Docker Networks

Create/build the QR1 containers without starting them. This creates the Docker networks needed for the Ollama bridge and UFW discovery while still letting host prerequisites be installed before any service starts.

```bash
docker compose $(scripts/ms-qr1-compose-flags.sh) up -d --build --no-start
docker compose $(scripts/ms-qr1-compose-flags.sh) ps -a
docker network ls | grep -E 'ods|langfuse'
```

Expected: QR1 containers exist but are not running; QR1 Docker networks exist.

Evidence: `docker compose ps -a` and `docker network ls`.

Rollback:

```bash
docker compose $(scripts/ms-qr1-compose-flags.sh) down
```

## 8. Narrow Ollama Docker Bridge

Do not set `OLLAMA_HOST=0.0.0.0`. QR1 keeps host-native Ollama loopback-only and installs a narrow host-side `socat` bridge that listens only on discovered Docker gateway IP addresses and forwards to `127.0.0.1:11434`.

Plan first:

```bash
scripts/ms-qr1-ollama-bridge.sh plan
```

Install `socat` if absent, then install the bridge:

```bash
command -v socat || sudo apt-get install -y socat
sudo scripts/ms-qr1-ollama-bridge.sh install
curl -fsS http://127.0.0.1:11434/api/tags
systemctl status ms-qr1-ollama-bridge.service --no-pager
ss -tlnp | grep ':11434'
```

Expected: Ollama still answers on `127.0.0.1:11434`; `ms-qr1-ollama-bridge.service` listens on Docker gateway IP address(es), not `0.0.0.0`.

Evidence: bridge plan output, `systemctl status`, and `ss -tlnp` showing listener addresses.

Rollback:

```bash
sudo scripts/ms-qr1-ollama-bridge.sh remove
sudo apt-get purge socat
```

Only purge `socat` if QR1 installed it and no other local service needs it.

## 9. Docker Subnet UFW Rules

Plan first:

```bash
scripts/ms-qr1-ufw-docker-rules.sh plan
```

Apply only after verifying the discovered CIDR is a private Docker network:

```bash
sudo scripts/ms-qr1-ufw-docker-rules.sh apply
sudo ufw status numbered
```

Expected: narrowly scoped allow rules exist from discovered Docker CIDR(s) to host TCP ports `11434` and `7710` only.

Evidence: plan output, apply output, CIDR(s), `ufw status numbered` before/after, and every generated rule number.

Rollback:

```bash
sudo ufw status numbered
sudo ufw delete <highest-ms-qr1-rule-number>
sudo ufw delete <next-ms-qr1-rule-number>
sudo ufw delete <remaining-ms-qr1-rule-number>
sudo ufw status numbered
```

Delete every generated MS QR1 rule in descending rule-number order. A single Docker subnet normally creates two rules: one for `11434/tcp` and one for `7710/tcp`.

## 10. Start QR1 Stack

```bash
docker compose $(scripts/ms-qr1-compose-flags.sh) start
docker compose $(scripts/ms-qr1-compose-flags.sh) ps
```

Expected: approved QR1 services start. Native Ollama remains the inference path; no AMD tuning, UMA/GTT/IOMMU, Lemonade, ODS Tailscale, OpenClaw, Brave Search, ods-proxy, or ODS OpenCode extension starts.

Evidence: `docker compose ps`.

Rollback:

```bash
docker compose $(scripts/ms-qr1-compose-flags.sh) down
```

## 11. Container-To-Host Inference Boundary

```bash
docker compose $(scripts/ms-qr1-compose-flags.sh) exec litellm \
  python3 -c 'import urllib.request; print(urllib.request.urlopen("http://host.docker.internal:11434/api/tags", timeout=5).status)'
ss -tlnp | grep ':11434'
sudo ufw status numbered
```

Expected: the LiteLLM container receives HTTP `200` from host-native Ollama through `host.docker.internal`; host `ss` shows no `0.0.0.0:11434` listener; UFW permits only Docker CIDR(s) to port `11434`.

Evidence: command outputs.

Rollback: remove the Ollama bridge in section 8 and UFW rules in section 9.

## 12. Tailscale Serve

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

## 13. Acceptance Checks

Blocking QR1 gate:

```bash
EXPECTED_MODEL=qwen3.8:27b scripts/ms-qr1-acceptance.sh
python scripts/audit-extensions.py
bash tests/test-safe-env.sh
bash tests/test-secret-security.sh
bash tests/test-ms-qr1-helpers.sh
python tests/contracts/test-network-exposure-contracts.py
```

Expected: acceptance checks pass. Qdrant unauthenticated requests must be rejected. Hermes host port `9119` must be unbound. Local-only LiteLLM routes must have no fallback. Host-agent nmcli endpoints must reject unauthenticated requests on the resolved host-agent bind address.

Diagnostic, not a QR1 blocking gate:

```bash
bash tests/test-network-security.sh || true
```

Expected diagnostic result as of PR #6: the static script reports broad findings against optional compose files and the ODS Tailscale host-network extension while also reporting zero insecure port bindings. Record the output, but do not treat it as the QR1 deploy gate because it does not model the explicit QR1 compose file set.

Evidence: command outputs.

Rollback for failed blocking acceptance: capture logs, then run the stack rollback in section 10, UFW rollback in section 9, and Ollama bridge rollback in section 8.

## 14. Host-Agent nmcli Boundary

No supported QR1 config switch exists to remove the host-agent nmcli/Wi-Fi routes. QR1 keeps stock host-agent behavior and relies on API-key authentication plus Docker-gateway/UFW scoping.

Derive the actual Linux bind address and test unauthenticated access:

```bash
AGENT_BIND="$(awk -F= '$1 == "ODS_AGENT_BIND" {print $2}' .env | tail -1)"
if [ -z "$AGENT_BIND" ]; then
  AGENT_BIND="$(docker network inspect ods-network --format '{{range .IPAM.Config}}{{println .Gateway}}{{end}}' 2>/dev/null | awk 'NF {print; exit}')"
fi
if [ -z "$AGENT_BIND" ]; then
  AGENT_BIND="$(docker network inspect bridge --format '{{range .IPAM.Config}}{{println .Gateway}}{{end}}' 2>/dev/null | awk 'NF {print; exit}')"
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

## 15. Full Rollback

```bash
cd ~/ms-ops/ops-centre/ods
docker compose $(scripts/ms-qr1-compose-flags.sh) down
sudo tailscale serve reset
sudo scripts/ms-qr1-ollama-bridge.sh remove
sudo ufw status numbered
sudo ufw delete <highest-ms-qr1-rule-number>
sudo ufw delete <next-ms-qr1-rule-number>
sudo ufw delete <remaining-ms-qr1-rule-number>
shred -u .env
```

Expected: QR1 containers stopped, Tailscale serve mappings removed, Ollama bridge removed, every QR1 UFW rule removed, and secrets removed from disk.
