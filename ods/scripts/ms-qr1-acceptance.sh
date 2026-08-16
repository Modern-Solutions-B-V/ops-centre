#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

require() {
  command -v "$1" >/dev/null || { echo "ERROR: $1 is required" >&2; exit 1; }
}

require curl
require python3

ENV_FILE="${ENV_FILE:-.env}"
QDRANT_URL="${QDRANT_URL:-http://127.0.0.1:6333}"
HERMES_URL="${HERMES_URL:-http://127.0.0.1:9120}"
OLLAMA_URL="${OLLAMA_URL:-http://127.0.0.1:11434}"
EXPECTED_MODEL="${EXPECTED_MODEL:-}"

failures=0

check() {
  local name="$1"
  shift
  printf '== %s\n' "$name"
  if "$@"; then
    printf 'PASS %s\n\n' "$name"
  else
    printf 'FAIL %s\n\n' "$name"
    failures=$((failures + 1))
  fi
}

compose_json() {
  docker compose $(scripts/ms-qr1-compose-flags.sh) config --format json
}

check_no_fallbacks() {
  ! grep -RIn -- 'fallbacks:' config/litellm/ms-qr1.yaml
}

check_one_external_model() {
  local external_count
  external_count="$(grep -Ec 'model:[[:space:]]*anthropic/' config/litellm/ms-qr1.yaml)"
  [[ "$external_count" == "1" ]] || {
    echo "expected one anthropic model, found $external_count" >&2
    return 1
  }
  grep -Eq 'model:[[:space:]]*anthropic/claude-sonnet-5$' config/litellm/ms-qr1.yaml
}

check_local_model_matches_env() {
  [[ -f "$ENV_FILE" ]] || { echo "$ENV_FILE not found" >&2; return 1; }
  local env_model config_model
  env_model="$(awk -F= '$1 == "EXTERNAL_LLM_MODEL" {print $2}' "$ENV_FILE" | tail -1)"
  config_model="$(sed -n 's/.*model:[[:space:]]*openai\///p' config/litellm/ms-qr1.yaml | head -1)"
  [[ -n "$env_model" && "$env_model" == "$config_model" ]] || {
    echo "EXTERNAL_LLM_MODEL=$env_model does not match LiteLLM local model $config_model" >&2
    return 1
  }
}

check_rendered_services_policy() {
  local rendered
  rendered="$(compose_json)"
  COMPOSE_JSON="$rendered" python3 - <<'PY'
import json
import os
import sys
allowed = {
    "ape", "comfyui", "dashboard", "dashboard-api", "embeddings",
    "hermes", "hermes-proxy", "langfuse", "langfuse-clickhouse",
    "langfuse-minio", "langfuse-minio-init", "langfuse-postgres",
    "langfuse-redis", "langfuse-worker", "litellm", "model-router",
    "n8n", "open-webui", "perplexica", "privacy-shield", "qdrant",
    "searxng", "token-spy", "tts", "whisper",
}
excluded = {
    "llama-server", "openclaw", "tailscale", "ods-proxy", "brave-search",
    "opencode", "remote-provider-egress", "remote-provider-ssh-tunnel",
}
services = set(json.loads(os.environ["COMPOSE_JSON"]).get("services", {}))
unexpected = sorted(services - allowed)
missing = sorted(allowed - services)
present_excluded = sorted(services & excluded)
if unexpected or missing or present_excluded:
    print(f"unexpected={unexpected} missing={missing} excluded_present={present_excluded}", file=sys.stderr)
    sys.exit(1)
PY
}

check_rendered_published_ports_loopback() {
  local rendered
  rendered="$(compose_json)"
  COMPOSE_JSON="$rendered" python3 - <<'PY'
import json
import os
import sys
data = json.loads(os.environ["COMPOSE_JSON"])
published = []
bad = []
for svc_name, svc in data.get("services", {}).items():
    for port in svc.get("ports", []) or []:
        host_ip = str(port.get("host_ip") or "")
        published_port = str(port.get("published") or "")
        if not published_port:
            continue
        published.append((svc_name, published_port, host_ip))
        if host_ip not in {"127.0.0.1", "::1"}:
            bad.append((svc_name, published_port, host_ip))
if not published:
    print("no published ports found", file=sys.stderr)
    sys.exit(1)
if bad:
    print(f"non-loopback published ports: {bad}", file=sys.stderr)
    sys.exit(1)
print("published QR1 ports:", ",".join(f"{svc}:{port}" for svc, port, _ in sorted(published)))
PY
}

check_live_listeners_no_wildcards() {
  require ss
  ss -tlnp | awk '
    /:(11434|7710|3000|3001|3002|3004|3005|3006|4000|5678|6333|6334|7890|8085|8090|8188|8880|8888|9000|9120) / {
      if ($4 ~ /^0\.0\.0\.0:/ || $4 ~ /^\[::\]:/) {
        print "wildcard bind: " $0
        bad=1
      }
    }
    END { exit bad ? 1 : 0 }
  '
}

check_hermes_tui() {
  require ss
  if ss -tln | grep -E '(^|[[:space:]])[^ ]*:9119[[:space:]]' >/dev/null; then
    echo "host port 9119 is bound" >&2
    return 1
  fi
  local status
  status="$(curl -fsS -o /dev/null -w '%{http_code}' "$HERMES_URL/api/pty")" || status="curl-failed"
  [[ "$status" == "401" || "$status" == "403" || "$status" == "404" ]]
}

check_qdrant_auth() {
  local status
  status="$(curl -fsS -o /dev/null -w '%{http_code}' "$QDRANT_URL/collections")" || status="curl-failed"
  [[ "$status" == "401" || "$status" == "403" ]]
}

check_no_placeholders() {
  [[ -f "$ENV_FILE" ]] || { echo "$ENV_FILE not found" >&2; return 1; }
  ! grep -RInE 'CHANGEME|GENERATE_ME' "$ENV_FILE" config/litellm/ms-qr1.yaml docker-compose.ms-qr1.yml
}

check_model_identity() {
  [[ -n "$EXPECTED_MODEL" ]] || { echo "set EXPECTED_MODEL to run identity check" >&2; return 1; }
  local response
  response="$(curl -fsS "$OLLAMA_URL/api/tags")"
  OLLAMA_TAGS_JSON="$response" python3 - "$EXPECTED_MODEL" <<'PY'
import os
import json
import sys
expected = sys.argv[1]
data = json.loads(os.environ["OLLAMA_TAGS_JSON"])
models = {m.get("name") for m in data.get("models", [])}
if expected not in models:
    print(f"{expected} not present in Ollama models: {sorted(models)}", file=sys.stderr)
    sys.exit(1)
PY
}

check_container_ollama_route() {
  require docker
  docker compose $(scripts/ms-qr1-compose-flags.sh) exec -T litellm \
    python3 -c 'import urllib.request; print(urllib.request.urlopen("http://ms-qr1-host:11434/api/tags", timeout=5).status)' \
    | grep -Fx '200'
  docker compose $(scripts/ms-qr1-compose-flags.sh) exec -T dashboard-api \
    python3 -c 'import urllib.request; print(urllib.request.urlopen("http://ms-qr1-host:11434/api/tags", timeout=5).status)' \
    | grep -Fx '200'
}

discover_host_agent_url() {
  if [[ -n "${HOST_AGENT_URL:-}" ]]; then
    printf '%s\n' "$HOST_AGENT_URL"
    return 0
  fi
  local bind=""
  if [[ -f "$ENV_FILE" ]]; then
    bind="$(awk -F= '$1 == "ODS_AGENT_BIND" {print $2}' "$ENV_FILE" | tail -1)"
  fi
  if [[ -z "$bind" ]] && command -v docker >/dev/null; then
    bind="$(docker network inspect ods-network --format '{{range .IPAM.Config}}{{println .Gateway}}{{end}}' | awk 'NF {print; exit}')"
  fi
  if [[ -z "$bind" ]] && command -v docker >/dev/null; then
    bind="$(docker network inspect bridge --format '{{range .IPAM.Config}}{{println .Gateway}}{{end}}' | awk 'NF {print; exit}')"
  fi
  bind="${bind:-127.0.0.1}"
  printf 'http://%s:%s\n' "$bind" "${ODS_AGENT_PORT:-7710}"
}

check_host_agent_nmcli_boundary() {
  local url status
  url="$(discover_host_agent_url)"
  status="$(curl -fsS -o /dev/null -w '%{http_code}' "$url/v1/network/wifi-scan")" || status="curl-failed"
  [[ "$status" == "401" || "$status" == "403" ]]
}

check_ufw_rules() {
  require ufw
  ufw status numbered | grep -F "MS QR1 docker-to-host" >/dev/null
}

check "LiteLLM QR1 config has no fallbacks" check_no_fallbacks
check "LiteLLM QR1 has exactly one external model" check_one_external_model
check "LiteLLM local model matches EXTERNAL_LLM_MODEL" check_local_model_matches_env
check "rendered QR1 service allow-list and exclusions" check_rendered_services_policy
check "rendered QR1 published ports are loopback" check_rendered_published_ports_loopback
check "live QR1-relevant listeners have no wildcard binds" check_live_listeners_no_wildcards
check "Hermes TUI/9119 disabled" check_hermes_tui
check "Qdrant rejects unauthenticated requests" check_qdrant_auth
check "rendered env/config contains no placeholders" check_no_placeholders
check "Ollama model identity matches EXPECTED_MODEL" check_model_identity
check "containers reach host Ollama through ms-qr1-host" check_container_ollama_route
check "Host-agent nmcli endpoints reject unauthenticated requests" check_host_agent_nmcli_boundary
check "UFW contains QR1 Docker-to-host rules" check_ufw_rules

if [[ "$failures" -gt 0 ]]; then
  echo "$failures QR1 acceptance check(s) failed" >&2
  exit 1
fi

echo "All QR1 acceptance checks passed"
