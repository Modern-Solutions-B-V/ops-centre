#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

require() {
  command -v "$1" >/dev/null 2>&1 || { echo "ERROR: $1 is required" >&2; exit 1; }
}

require curl
require python3

ENV_FILE="${ENV_FILE:-.env}"
LITELLM_URL="${LITELLM_URL:-http://127.0.0.1:4000}"
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

check_no_fallbacks() {
  ! grep -RIn -- 'fallbacks:' config/litellm/ms-qr1.yaml
}

check_one_external_model() {
  python3 - <<'PY'
import sys, yaml
cfg = yaml.safe_load(open("config/litellm/ms-qr1.yaml", encoding="utf-8"))
external = []
for item in cfg.get("model_list", []):
    params = item.get("litellm_params", {})
    model = str(params.get("model", ""))
    api_base = str(params.get("api_base", ""))
    if model.startswith("anthropic/") or api_base.startswith("https://"):
        external.append(model)
if external != ["anthropic/claude-sonnet-5"]:
    print(f"unexpected external models: {external}", file=sys.stderr)
    sys.exit(1)
PY
}

check_loopback_binds() {
  if ! command -v ss >/dev/null 2>&1; then
    echo "ss not available; skipping with failure so operator captures manually" >&2
    return 1
  fi
  ss -tlnp | awk '
    /:(3000|3001|3002|3004|3005|3006|4000|5678|6333|6334|8188|8880|8888|9000) / {
      if ($4 !~ /^127\.0\.0\.1:/ && $4 !~ /^\[::1\]:/) {
        print "non-loopback bind: " $0
        bad=1
      }
    }
    END { exit bad ? 1 : 0 }
  '
}

check_hermes_tui() {
  if ss -tln 2>/dev/null | grep -E '(^|[[:space:]])[^ ]*:9119[[:space:]]' >/dev/null; then
    echo "host port 9119 is bound" >&2
    return 1
  fi
  status="$(curl -fsS -o /dev/null -w '%{http_code}' "$HERMES_URL/api/pty" || true)"
  [[ "$status" == "401" || "$status" == "403" || "$status" == "404" ]]
}

check_qdrant_auth() {
  status="$(curl -fsS -o /dev/null -w '%{http_code}' "$QDRANT_URL/collections" || true)"
  [[ "$status" == "401" || "$status" == "403" ]]
}

check_no_changeme() {
  if [[ ! -f "$ENV_FILE" ]]; then
    echo "$ENV_FILE not found" >&2
    return 1
  fi
  ! grep -RInE 'CHANGEME|GENERATE_ME' "$ENV_FILE" config/litellm/ms-qr1.yaml docker-compose.ms-qr1.yml
}

check_model_identity() {
  [[ -n "$EXPECTED_MODEL" ]] || { echo "set EXPECTED_MODEL to run identity check" >&2; return 1; }
  response="$(curl -fsS "$OLLAMA_URL/api/tags")"
  OLLAMA_TAGS_JSON="$response" python3 - "$EXPECTED_MODEL" <<'PY'
import os
import json, sys
expected = sys.argv[1]
data = json.loads(os.environ["OLLAMA_TAGS_JSON"])
models = {m.get("name") for m in data.get("models", [])}
if expected not in models:
    print(f"{expected} not present in Ollama models: {sorted(models)}", file=sys.stderr)
    sys.exit(1)
PY
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
  if [[ -z "$bind" && command -v docker >/dev/null 2>&1 ]]; then
    bind="$(docker network inspect ods-network --format '{{range .IPAM.Config}}{{println .Gateway}}{{end}}' 2>/dev/null | awk 'NF {print; exit}')"
  fi
  if [[ -z "$bind" && command -v docker >/dev/null 2>&1 ]]; then
    bind="$(docker network inspect bridge --format '{{range .IPAM.Config}}{{println .Gateway}}{{end}}' 2>/dev/null | awk 'NF {print; exit}')"
  fi
  bind="${bind:-127.0.0.1}"
  printf 'http://%s:%s\n' "$bind" "${ODS_AGENT_PORT:-7710}"
}

check_host_agent_nmcli_boundary() {
  local url status
  url="$(discover_host_agent_url)"
  status="$(curl -fsS -o /dev/null -w '%{http_code}' "$url/v1/network/wifi-scan" || true)"
  [[ "$status" == "401" || "$status" == "403" ]]
}

check_ufw_rules() {
  command -v ufw >/dev/null 2>&1 || return 1
  ufw status numbered | grep -E '11434|7710' >/dev/null
}

check "LiteLLM QR1 config has no fallbacks" check_no_fallbacks
check "LiteLLM QR1 has exactly one external model" check_one_external_model
check "approved service ports bind loopback only" check_loopback_binds
check "Hermes TUI/9119 disabled" check_hermes_tui
check "Qdrant rejects unauthenticated requests" check_qdrant_auth
check "rendered env/config contains no placeholders" check_no_changeme
check "Ollama model identity matches EXPECTED_MODEL" check_model_identity
check "Host-agent nmcli endpoints reject unauthenticated requests" check_host_agent_nmcli_boundary
check "UFW contains QR1 Docker-to-host rules" check_ufw_rules

if [[ "$failures" -gt 0 ]]; then
  echo "$failures QR1 acceptance check(s) failed" >&2
  exit 1
fi

echo "All QR1 acceptance checks passed"
