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

http_status() {
  local url="$1"
  curl -sS -o /dev/null -w '%{http_code}' "$url"
}

http_status_and_location() {
  local url="$1"
  curl -sS -o /dev/null -D - -w 'HTTP_STATUS:%{http_code}' "$url"
}

expect_http_status() {
  local url="$1"
  shift
  local status
  if ! status="$(http_status "$url")"; then
    echo "transport failure for $url" >&2
    return 1
  fi
  local expected
  for expected in "$@"; do
    [[ "$status" == "$expected" ]] && return 0
  done
  echo "unexpected HTTP status for $url: $status; expected one of: $*" >&2
  return 1
}

expect_http_status_or_auth_redirect() {
  local url="$1" response status location
  if ! response="$(http_status_and_location "$url")"; then
    echo "transport failure for $url" >&2
    return 1
  fi
  status="$(printf '%s\n' "$response" | awk -F: '/^HTTP_STATUS:/ {print $2}' | tail -1 | tr -d '\r')"
  case "$status" in
    401|403|404)
      return 0
      ;;
    303)
      location="$(printf '%s\n' "$response" | awk 'BEGIN{IGNORECASE=1} /^Location:/ {sub(/^[^:]*:[[:space:]]*/, ""); gsub(/\r/, ""); print; exit}')"
      if [[ "$location" == "/auth/required" ]]; then
        return 0
      fi
      echo "unexpected HTTP redirect for $url: 303 Location: ${location:-<missing>}; expected /auth/required" >&2
      return 1
      ;;
    *)
      echo "unexpected HTTP status for $url: ${status:-<missing>}; expected 401, 403, 404, or 303 Location: /auth/required" >&2
      return 1
      ;;
  esac
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

check_ms_qr1_host_aliases() {
  local rendered
  rendered="$(compose_json)"
  COMPOSE_JSON="$rendered" python3 - <<'PY'
import json
import os
import sys
data = json.loads(os.environ["COMPOSE_JSON"])
bad = []
for svc_name, svc in data.get("services", {}).items():
    env = svc.get("environment") or {}
    values = []
    if isinstance(env, dict):
        values.extend(str(value) for value in env.values())
    elif isinstance(env, list):
        values.extend(str(value) for value in env)
    if not any("ms-qr1-host" in value for value in values):
        continue
    aliases = [str(item).split("=", 1)[0] for item in svc.get("extra_hosts") or []]
    if "ms-qr1-host" not in aliases:
        bad.append(svc_name)
if bad:
    print(f"services reference ms-qr1-host without extra_hosts alias: {bad}", file=sys.stderr)
    sys.exit(1)
PY
}

check_live_listeners_loopback_and_bridge_no_wildcard() {
  require ss
  local expected_bridge_addrs listener_snapshot approved_tailscale_serve_addrs
  expected_bridge_addrs="$(scripts/ms-qr1-ollama-bridge.sh expected-listeners)"
  listener_snapshot="$(ss -tlnp)" || {
    echo "ss listener snapshot failed" >&2
    return 1
  }
  approved_tailscale_serve_addrs="$(approved_tailscale_serve_11434_addrs || true)"
  EXPECTED_BRIDGE_ADDRS="$expected_bridge_addrs" APPROVED_TAILSCALE_SERVE_ADDRS="$approved_tailscale_serve_addrs" LISTENER_SNAPSHOT="$listener_snapshot" python3 - <<'PY'
import os
import re
import sys

expected_bridge = set(filter(None, os.environ["EXPECTED_BRIDGE_ADDRS"].splitlines()))
approved_tail = set(filter(None, os.environ["APPROVED_TAILSCALE_SERVE_ADDRS"].splitlines()))
service_ports = {
    "3000", "3001", "3002", "3004", "3005", "3006", "4000", "5678",
    "6333", "6334", "7890", "8085", "8090", "8188", "8880", "8888",
    "9000", "9120",
}
bad = False

def split_addr_port(local):
    if local.startswith("["):
        match = re.match(r"^\[([^\]]+)\]:(\d+)$", local)
        if match:
            return match.group(1), match.group(2)
    if ":" in local:
        addr, port = local.rsplit(":", 1)
        return addr, port
    return local, ""

for line in os.environ["LISTENER_SNAPSHOT"].splitlines():
    fields = line.split()
    if len(fields) < 4 or fields[0] == "State":
        continue
    addr, port = split_addr_port(fields[3])
    if port in service_ports and addr not in {"127.0.0.1", "::1"}:
        print(f"non-loopback QR1 service bind: {line}")
        bad = True
    if port in {"11434", "7710"} and addr in {"0.0.0.0", "::"}:
        print(f"wildcard QR1 bridge bind: {line}")
        bad = True
    if port == "11434" and addr != "127.0.0.1" and addr not in expected_bridge and addr not in approved_tail:
        print(f"non-gateway QR1 Ollama bridge bind: {line}")
        bad = True

sys.exit(1 if bad else 0)
PY
}

approved_tailscale_serve_11434_addrs() {
  command -v ip >/dev/null || return 0
  command -v tailscale >/dev/null || return 0
  local tailscale_addrs serve_status
  tailscale_addrs="$(ip -o addr show dev tailscale0 2>/dev/null)" || return 1
  serve_status="$(tailscale serve status 2>/dev/null)" || return 1
  TAILSCALE_ADDRS="$tailscale_addrs" TAILSCALE_SERVE_STATUS="$serve_status" python3 - <<'PY'
import ipaddress
import os
import re

assigned = set()
for line in os.environ["TAILSCALE_ADDRS"].splitlines():
    parts = line.split()
    for idx, part in enumerate(parts):
        if part in {"inet", "inet6"} and idx + 1 < len(parts):
            assigned.add(str(ipaddress.ip_interface(parts[idx + 1]).ip))

lines = os.environ["TAILSCALE_SERVE_STATUS"].splitlines()
approved = set()
for idx, line in enumerate(lines):
    match = re.search(r"tcp://(?:\[([^\]]+)\]|([^:\s]+)):11434(?:\s|$)", line)
    if not match:
        continue
    addr = match.group(1) or match.group(2)
    if addr not in assigned:
        continue
    block = "\n".join(lines[idx:idx + 4])
    if "tcp://127.0.0.1:11434" in block:
        approved.add(addr)

for addr in sorted(approved):
    print(addr)
PY
}

check_hermes_tui() {
  require ss
  if ss -tln | grep -E '(^|[[:space:]])[^ ]*:9119[[:space:]]' >/dev/null; then
    echo "host port 9119 is bound" >&2
    return 1
  fi
  expect_http_status_or_auth_redirect "$HERMES_URL/api/pty"
}

check_qdrant_auth() {
  expect_http_status "$QDRANT_URL/collections" 401 403
}

check_no_placeholders() {
  [[ -f "$ENV_FILE" ]] || { echo "$ENV_FILE not found" >&2; return 1; }
  ! grep -nE '^[A-Za-z_][A-Za-z0-9_]*=.*(CHANGEME|GENERATE_ME)' "$ENV_FILE"
}

check_prestart_provisioning() {
  scripts/ms-qr1-prestart-provision.sh check
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
  local rendered services service rc output
  rendered="$(compose_json)"
  mapfile -t services < <(COMPOSE_JSON="$rendered" python3 - <<'PY'
import json
import os
data = json.loads(os.environ["COMPOSE_JSON"])
for svc_name, svc in sorted(data.get("services", {}).items()):
    env = svc.get("environment") or {}
    values = []
    if isinstance(env, dict):
        values.extend(str(value) for value in env.values())
    elif isinstance(env, list):
        values.extend(str(value) for value in env)
    if any("ms-qr1-host" in value for value in values):
        print(svc_name)
PY
)
  services=("litellm" "${services[@]}")
  mapfile -t services < <(printf '%s\n' "${services[@]}" | awk 'NF && !seen[$0]++')
  for service in "${services[@]}"; do
    set +e
    output="$(docker compose $(scripts/ms-qr1-compose-flags.sh) exec -T "$service" sh -c '
      url=http://ms-qr1-host:11434/api/tags
      if command -v python3 >/dev/null; then
        python3 -c "import urllib.request; print(urllib.request.urlopen(\"$url\", timeout=5).status)"
      elif command -v python >/dev/null; then
        python -c "import urllib.request; print(urllib.request.urlopen(\"$url\", timeout=5).status)"
      elif command -v curl >/dev/null; then
        curl -fsS -o /dev/null -w "%{http_code}\n" "$url"
      elif command -v wget >/dev/null; then
        wget -q -O /dev/null "$url" && echo 200
      else
        echo "SKIP no supported HTTP probe tool in container"
        exit 77
      fi
    ')"
    rc="$?"
    set -e
    if [[ "$rc" == "77" ]]; then
      printf '%s: %s\n' "$service" "$output"
      continue
    fi
    if [[ "$rc" != "0" ]]; then
      printf '%s: route probe failed: %s\n' "$service" "$output" >&2
      return 1
    fi
    printf '%s\n' "$output" | grep -Fx '200' >/dev/null || {
      printf '%s: expected HTTP 200, got: %s\n' "$service" "$output" >&2
      return 1
    }
  done
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
  local url
  url="$(discover_host_agent_url)"
  expect_http_status "$url/v1/network/wifi-scan" 401 403
}

check_ufw_rules() {
  require ufw
  local expected status
  expected="$(scripts/ms-qr1-ufw-docker-rules.sh expected-rules)"
  status="$(ufw status numbered)"
  EXPECTED_RULES="$expected" UFW_STATUS="$status" python3 - <<'PY'
import os
import re
import sys

expected = set()
for line in os.environ["EXPECTED_RULES"].splitlines():
    if not line.strip():
        continue
    subnet, gateway, port = line.split("|")
    expected.add((subnet, gateway, port))

actual = set()
stale = []
for line in os.environ["UFW_STATUS"].splitlines():
    if "MS QR1 docker-to-host" not in line:
        continue
    from_match = re.search(r"\bfrom\s+([0-9./]+)\b", line)
    to_match = re.search(r"\bto\s+([0-9.]+)\b", line)
    command_style = re.search(r"\bport\s+(11434|7710)\b", line)
    status_style = re.search(r"\]\s+([0-9.]+)\s+(11434|7710)(?:/tcp)?\s+ALLOW\s+IN\s+([0-9./]+)\b", line)
    if from_match and to_match and command_style:
        actual.add((from_match.group(1), to_match.group(1), command_style.group(1)))
    elif status_style:
        actual.add((status_style.group(3), status_style.group(1), status_style.group(2)))
    else:
        stale.append(line)

missing = sorted(expected - actual)
unexpected = sorted(actual - expected)
if missing or unexpected or stale:
    print(f"missing={missing} unexpected={unexpected} unparsable_stale={stale}", file=sys.stderr)
    sys.exit(1)
PY
}

main() {
  check "LiteLLM QR1 config has no fallbacks" check_no_fallbacks
  check "LiteLLM QR1 has exactly one external model" check_one_external_model
  check "LiteLLM local model matches EXTERNAL_LLM_MODEL" check_local_model_matches_env
  check "rendered QR1 service allow-list and exclusions" check_rendered_services_policy
  check "rendered QR1 published ports are loopback" check_rendered_published_ports_loopback
  check "ms-qr1-host env references have host aliases" check_ms_qr1_host_aliases
  check "live QR1 service listeners are loopback and bridge listeners are not wildcard" check_live_listeners_loopback_and_bridge_no_wildcard
  check "Hermes TUI/9119 disabled" check_hermes_tui
  check "Qdrant rejects unauthenticated requests" check_qdrant_auth
  check "rendered env/config contains no placeholders" check_no_placeholders
  check "QR1 pre-start bind mounts are provisioned" check_prestart_provisioning
  check "Ollama model identity matches EXPECTED_MODEL" check_model_identity
  check "containers reach host Ollama through ms-qr1-host" check_container_ollama_route
  check "Host-agent nmcli endpoints reject unauthenticated requests" check_host_agent_nmcli_boundary
  check "UFW contains complete QR1 Docker-to-host rule set" check_ufw_rules

  if [[ "$failures" -gt 0 ]]; then
    echo "$failures QR1 acceptance check(s) failed" >&2
    exit 1
  fi

  echo "All QR1 acceptance checks passed"
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  main "$@"
fi
