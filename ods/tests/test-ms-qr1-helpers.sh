#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

tmpdir="$(mktemp -d "${TMPDIR:-/tmp}/ms-qr1-helpers.XXXXXX")"
trap 'rm -rf "$tmpdir"' EXIT

assert_contains() {
  local needle="$1" file="$2"
  grep -F "$needle" "$file" >/dev/null || {
    echo "missing expected text: $needle" >&2
    echo "--- $file ---" >&2
    cat "$file" >&2
    exit 1
  }
}

assert_not_contains() {
  local needle="$1" file="$2"
  if grep -F "$needle" "$file" >/dev/null; then
    echo "unexpected text present: $needle" >&2
    echo "--- $file ---" >&2
    cat "$file" >&2
    exit 1
  fi
}

cat > "$tmpdir/docker" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
if [[ "${1:-}" == "compose" && " $* " == *" config "* ]]; then
  cat "$FIXTURE_DIR/compose-config.json"
  exit 0
fi
if [[ "${1:-}" == "network" && "${2:-}" == "inspect" ]]; then
  if [[ "${DOCKER_NETWORK_MODE:-normal}" == "missing" ]]; then
    exit 1
  fi
  case "${3:-}" in
    ods-network) cat "$FIXTURE_DIR/network-ods-network.json" ;;
    ods-public-extra) cat "$FIXTURE_DIR/network-ods-public-extra.json" ;;
    ods_langfuse-internal)
      echo "internal network must not be inspected: ${3:-}" >&2
      exit 44
      ;;
    default|langfuse-internal)
      echo "inspected Compose key instead of rendered network name: ${3:-}" >&2
      exit 45
      ;;
    *)
      echo "unexpected network inspect target: ${3:-}" >&2
      exit 46
      ;;
  esac
  exit 0
fi
echo "unexpected docker command: $*" >&2
exit 47
SH

cat > "$tmpdir/sudo" <<'SH'
#!/usr/bin/env bash
exec "$@"
SH

cat > "$tmpdir/ufw" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
state="$FIXTURE_DIR/ufw-state.txt"
touch "$state"
if [[ "${1:-}" == "status" ]]; then
  line_no=1
  while IFS= read -r line; do
    if [[ "$line" =~ ^from[[:space:]]+([^[:space:]]+)[[:space:]]+to[[:space:]]+([^[:space:]]+)[[:space:]]+port[[:space:]]+([^[:space:]]+).*comment[[:space:]]+(.*)$ ]]; then
      printf '[%2d] %s %s/tcp ALLOW IN %s # %s\n' "$line_no" "${BASH_REMATCH[2]}" "${BASH_REMATCH[3]}" "${BASH_REMATCH[1]}" "${BASH_REMATCH[4]}"
    else
      printf '[%2d] %s\n' "$line_no" "$line"
    fi
    line_no=$((line_no + 1))
  done < "$state"
  exit 0
fi
if [[ "${1:-}" == "allow" ]]; then
  printf '%s\n' "${*:2}" >> "$state"
  exit 0
fi
if [[ "${1:-}" == "delete" && "${2:-}" == "allow" ]]; then
  needle="${*:3}"
  tmp="$state.tmp"
  awk -v needle="$needle" 'index($0, needle) != 1 {print}' "$state" > "$tmp"
  mv "$tmp" "$state"
  exit 0
fi
if [[ "${1:-}" == "--force" && "${2:-}" == "delete" ]]; then
  rule_number="${3:-}"
  tmp="$state.tmp"
  awk -v target="$rule_number" 'NR != target {print}' "$state" > "$tmp"
  mv "$tmp" "$state"
  exit 0
fi
echo "unexpected ufw command: $*" >&2
exit 48
SH

cat > "$tmpdir/ip" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
if [[ "$*" == "-o -4 addr show" ]]; then
  cat "$FIXTURE_DIR/ip-addr.txt"
  exit 0
fi
echo "unexpected ip command: $*" >&2
exit 49
SH

chmod +x "$tmpdir/docker" "$tmpdir/sudo" "$tmpdir/ufw" "$tmpdir/ip"

cat > "$tmpdir/compose-config.json" <<'JSON'
{
  "networks": {
    "default": {"name": "ods-network"},
    "extra": {"name": "ods-public-extra"},
    "langfuse-internal": {"name": "ods_langfuse-internal", "internal": true}
  },
  "services": {
    "litellm": {
      "extra_hosts": ["ms-qr1-host=172.31.0.1"],
      "environment": {"OPENAI_BASE_URL": "http://ms-qr1-host:11434/v1"},
      "ports": [{"host_ip": "127.0.0.1", "published": "4000"}]
    },
    "dashboard-api": {
      "extra_hosts": ["ms-qr1-host=172.31.0.1"],
      "environment": {"OLLAMA_URL": "http://ms-qr1-host:11434"},
      "ports": [{"host_ip": "127.0.0.1", "published": "3002"}]
    },
    "perplexica": {
      "extra_hosts": ["ms-qr1-host=172.31.0.1"],
      "environment": {"OPENAI_BASE_URL": "http://ms-qr1-host:11434/v1"}
    },
    "privacy-shield": {
      "extra_hosts": ["ms-qr1-host=172.31.0.1"],
      "environment": {"TARGET_API_URL": "http://ms-qr1-host:11434/v1"}
    },
    "token-spy": {
      "extra_hosts": ["ms-qr1-host=172.31.0.1"],
      "environment": {"OLLAMA_URL": "http://ms-qr1-host:11434"}
    }
  }
}
JSON

cat > "$tmpdir/network-ods-network.json" <<'JSON'
[
  {
    "Name": "ods-network",
    "IPAM": {
      "Config": [
        {"Subnet": "172.31.0.0/16", "Gateway": "172.31.0.1"}
      ]
    }
  }
]
JSON

cat > "$tmpdir/network-ods-public-extra.json" <<'JSON'
[
  {
    "Name": "ods-public-extra",
    "IPAM": {
      "Config": [
        {"Subnet": "172.20.0.0/16", "Gateway": "172.20.0.1"}
      ]
    }
  }
]
JSON

cat > "$tmpdir/ip-addr.txt" <<'EOF'
7: br-a inet 172.31.0.1/16 brd 172.31.255.255 scope global br-a
8: br-b inet 172.20.0.1/16 brd 172.20.255.255 scope global br-b
9: br-internal inet 172.29.0.1/16 brd 172.29.255.255 scope global br-internal
EOF

env_prefix=(env FIXTURE_DIR="$tmpdir" PATH="$tmpdir:$PATH")

"${env_prefix[@]}" scripts/ms-qr1-ufw-docker-rules.sh plan > "$tmpdir/ufw-plan.out"
assert_contains "172.31.0.0/16 -> 172.31.0.1:11434/tcp" "$tmpdir/ufw-plan.out"
assert_contains "172.20.0.0/16 -> 172.20.0.1:7710/tcp" "$tmpdir/ufw-plan.out"
assert_not_contains "172.29.0.0/16" "$tmpdir/ufw-plan.out"

"${env_prefix[@]}" scripts/ms-qr1-ufw-docker-rules.sh expected-rules > "$tmpdir/ufw-expected.out"
assert_contains "172.31.0.0/16|172.31.0.1|11434" "$tmpdir/ufw-expected.out"
assert_contains "172.31.0.0/16|172.31.0.1|7710" "$tmpdir/ufw-expected.out"
assert_contains "172.20.0.0/16|172.20.0.1|11434" "$tmpdir/ufw-expected.out"
assert_contains "172.20.0.0/16|172.20.0.1|7710" "$tmpdir/ufw-expected.out"

"${env_prefix[@]}" scripts/ms-qr1-ufw-docker-rules.sh apply > "$tmpdir/ufw-apply.out"
[[ "$(wc -l < "$tmpdir/ufw-state.txt" | tr -d ' ')" == "4" ]] || {
  echo "expected four QR1 UFW rules after apply" >&2
  cat "$tmpdir/ufw-state.txt" >&2
  exit 1
}
"${env_prefix[@]}" bash -c 'source scripts/ms-qr1-acceptance.sh; check_ufw_rules' > "$tmpdir/ufw-acceptance.out"
cp "$tmpdir/ufw-state.txt" "$tmpdir/ufw-state.complete"
awk 'index($0, "port 7710") == 0 {print}' "$tmpdir/ufw-state.complete" > "$tmpdir/ufw-state.txt"
if "${env_prefix[@]}" bash -c 'source scripts/ms-qr1-acceptance.sh; check_ufw_rules' > "$tmpdir/ufw-missing.out" 2> "$tmpdir/ufw-missing.err"; then
  echo "UFW acceptance should fail when a required QR1 rule is missing" >&2
  exit 1
fi
cp "$tmpdir/ufw-state.complete" "$tmpdir/ufw-state.txt"
printf '%s\n' 'from 172.99.0.0/16 to 172.99.0.1 port 11434 proto tcp comment MS QR1 docker-to-host 11434' >> "$tmpdir/ufw-state.txt"
if "${env_prefix[@]}" bash -c 'source scripts/ms-qr1-acceptance.sh; check_ufw_rules' > "$tmpdir/ufw-stale.out" 2> "$tmpdir/ufw-stale.err"; then
  echo "UFW acceptance should fail when a stale QR1 rule is present" >&2
  exit 1
fi
cp "$tmpdir/ufw-state.complete" "$tmpdir/ufw-state.txt"
"${env_prefix[@]}" scripts/ms-qr1-ufw-docker-rules.sh remove > "$tmpdir/ufw-remove.out"
[[ ! -s "$tmpdir/ufw-state.txt" ]] || {
  echo "expected zero QR1 UFW rules after remove" >&2
  cat "$tmpdir/ufw-state.txt" >&2
  exit 1
}

"${env_prefix[@]}" scripts/ms-qr1-ufw-docker-rules.sh apply > "$tmpdir/ufw-apply-missing.out"
DOCKER_NETWORK_MODE=missing "${env_prefix[@]}" scripts/ms-qr1-ufw-docker-rules.sh remove > "$tmpdir/ufw-remove-missing.out"
[[ ! -s "$tmpdir/ufw-state.txt" ]] || {
  echo "expected zero QR1 UFW rules after remove with missing Docker networks" >&2
  cat "$tmpdir/ufw-state.txt" >&2
  exit 1
}

"${env_prefix[@]}" scripts/ms-qr1-ufw-docker-rules.sh apply > "$tmpdir/ufw-apply-drift.out"
cp "$tmpdir/network-ods-network.json" "$tmpdir/network-ods-network.original.json"
cat > "$tmpdir/network-ods-network.json" <<'JSON'
[
  {
    "Name": "ods-network",
    "IPAM": {
      "Config": [
        {"Subnet": "172.32.0.0/16", "Gateway": "172.32.0.1"}
      ]
    }
  }
]
JSON
cat > "$tmpdir/ip-addr.txt" <<'EOF'
7: br-a inet 172.32.0.1/16 brd 172.32.255.255 scope global br-a
8: br-b inet 172.20.0.1/16 brd 172.20.255.255 scope global br-b
9: br-internal inet 172.29.0.1/16 brd 172.29.255.255 scope global br-internal
EOF
"${env_prefix[@]}" scripts/ms-qr1-ufw-docker-rules.sh remove > "$tmpdir/ufw-remove-drift.out"
[[ ! -s "$tmpdir/ufw-state.txt" ]] || {
  echo "expected zero QR1 UFW rules after remove with Docker subnet drift" >&2
  cat "$tmpdir/ufw-state.txt" >&2
  exit 1
}
mv "$tmpdir/network-ods-network.original.json" "$tmpdir/network-ods-network.json"
cat > "$tmpdir/ip-addr.txt" <<'EOF'
7: br-a inet 172.31.0.1/16 brd 172.31.255.255 scope global br-a
8: br-b inet 172.20.0.1/16 brd 172.20.255.255 scope global br-b
9: br-internal inet 172.29.0.1/16 brd 172.29.255.255 scope global br-internal
EOF

"${env_prefix[@]}" scripts/ms-qr1-ollama-bridge.sh render-unit > "$tmpdir/bridge.unit"
assert_contains 'Environment="MS_QR1_OLLAMA_BRIDGE_ADDRS=172.20.0.1 172.31.0.1"' "$tmpdir/bridge.unit"
assert_contains 'if [ -z "$$MS_QR1_OLLAMA_BRIDGE_ADDRS" ]; then exit 64; fi' "$tmpdir/bridge.unit"
assert_contains 'for addr in $$MS_QR1_OLLAMA_BRIDGE_ADDRS' "$tmpdir/bridge.unit"
assert_contains 'bind=$$addr' "$tmpdir/bridge.unit"
assert_not_contains 'bind=,' "$tmpdir/bridge.unit"
assert_not_contains '0.0.0.0' "$tmpdir/bridge.unit"
assert_not_contains '172.29.0.1' "$tmpdir/bridge.unit"

"${env_prefix[@]}" scripts/ms-qr1-ollama-bridge.sh plan > "$tmpdir/bridge.plan"
assert_contains 'MS_QR1_HOST_GATEWAY=172.31.0.1' "$tmpdir/bridge.plan"
assert_contains 'systemctl daemon-reload' scripts/ms-qr1-ollama-bridge.sh
assert_contains 'systemctl restart "$SERVICE_NAME"' scripts/ms-qr1-ollama-bridge.sh
python3 - <<'PY'
from pathlib import Path
text = Path("scripts/ms-qr1-ollama-bridge.sh").read_text()
install = text.index('run_privileged install -m 0644 "$unit_tmp" "$UNIT_PATH"')
reload = text.index('run_privileged systemctl daemon-reload', install)
restart = text.index('run_privileged systemctl restart "$SERVICE_NAME"', reload)
if not install < reload < restart:
    raise SystemExit("Ollama bridge install path must reload and restart after unit replacement")
PY

cat > "$tmpdir/curl" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
case "${CURL_MODE:-401}" in
  401) printf '401' ;;
  403) printf '403' ;;
  404) printf '404' ;;
  transport) exit 7 ;;
  *) printf '%s' "$CURL_MODE" ;;
esac
SH
chmod +x "$tmpdir/curl"
CURL_MODE=401 "${env_prefix[@]}" bash -c 'source scripts/ms-qr1-acceptance.sh; expect_http_status http://example.invalid 401 403'
CURL_MODE=403 "${env_prefix[@]}" bash -c 'source scripts/ms-qr1-acceptance.sh; expect_http_status http://example.invalid 401 403'
CURL_MODE=404 "${env_prefix[@]}" bash -c 'source scripts/ms-qr1-acceptance.sh; expect_http_status http://example.invalid 401 403 404'
if CURL_MODE=transport "${env_prefix[@]}" bash -c 'source scripts/ms-qr1-acceptance.sh; expect_http_status http://example.invalid 401 403' > "$tmpdir/http-transport.out" 2> "$tmpdir/http-transport.err"; then
  echo "HTTP status helper should fail on transport errors" >&2
  exit 1
fi

for f in \
  scripts/ms-qr1-compose-flags.sh \
  scripts/ms-qr1-ufw-docker-rules.sh \
  scripts/ms-qr1-ollama-bridge.sh \
  scripts/ms-qr1-acceptance.sh; do
  bash -n "$f"
done

cat > "$tmpdir/bad.sh" <<'SH'
if [[ -z "$x" && command -v docker ]]; then
  :
fi
SH
if bash -n "$tmpdir/bad.sh" > "$tmpdir/bad.out" 2> "$tmpdir/bad.err"; then
  echo "bash -n regression fixture should fail for invalid conditional syntax" >&2
  exit 1
fi

if grep -nE 'curl .*OLLAMA_URL.*/api/tags.*\|' scripts/ms-qr1-acceptance.sh >/dev/null; then
  echo "acceptance helper must not pipe Ollama JSON into heredoc-backed python stdin" >&2
  exit 1
fi
if grep -nF 'compose_json | python3 - <<' scripts/ms-qr1-acceptance.sh >/dev/null; then
  echo "acceptance helper must not pipe Compose JSON into heredoc-backed python stdin" >&2
  exit 1
fi
assert_contains 'json.loads(os.environ["OLLAMA_TAGS_JSON"])' scripts/ms-qr1-acceptance.sh
assert_contains 'json.loads(os.environ["COMPOSE_JSON"])' scripts/ms-qr1-acceptance.sh
assert_contains 'check_rendered_published_ports_loopback' scripts/ms-qr1-acceptance.sh
assert_contains 'check_rendered_services_policy' scripts/ms-qr1-acceptance.sh
assert_contains 'check_ms_qr1_host_aliases' scripts/ms-qr1-acceptance.sh
assert_contains 'check_live_listeners_loopback_and_bridge_no_wildcard' scripts/ms-qr1-acceptance.sh
assert_contains 'services=("litellm" "${services[@]}")' scripts/ms-qr1-acceptance.sh
assert_contains 'SDXL_REVISION=c6c10e8716de60c7ef4eed6b89a06f67e772b374' ../docs/ms/deploy/QR1-DEPLOY-RUNBOOK.md
assert_contains 'SDXL_SHA256=e0d996ee0013e79d9d3561f50fcafb9a17e3ff07b780358e3b66d67932c4d490' ../docs/ms/deploy/QR1-DEPLOY-RUNBOOK.md
assert_contains 'sha256sum -c -' ../docs/ms/deploy/QR1-DEPLOY-RUNBOOK.md
assert_contains 'docker compose $(scripts/ms-qr1-compose-flags.sh) up -d --build --no-start' ../docs/ms/deploy/QR1-DEPLOY-RUNBOOK.md
assert_contains 'docker compose $(scripts/ms-qr1-compose-flags.sh) up -d --build --force-recreate' ../docs/ms/deploy/QR1-DEPLOY-RUNBOOK.md
assert_not_contains 'docker network create ods-network' ../docs/ms/deploy/QR1-DEPLOY-RUNBOOK.md
assert_contains 'sudo systemctl restart ods-host-agent.service' ../docs/ms/deploy/QR1-DEPLOY-RUNBOOK.md
assert_contains 'sudo apt-get install -y python3-yaml jq' ../docs/ms/deploy/QR1-DEPLOY-RUNBOOK.md
assert_contains 'jq --version' ../docs/ms/deploy/QR1-DEPLOY-RUNBOOK.md
assert_contains 'jq is required for schema validation' scripts/validate-env.sh

COMPOSE_JSON="$(cat "$tmpdir/compose-config.json")" python3 - <<'PY'
import json
import os
import sys
data = json.loads(os.environ["COMPOSE_JSON"])
bad = []
for svc_name, svc in data.get("services", {}).items():
    env = svc.get("environment") or {}
    values = list(env.values()) if isinstance(env, dict) else env
    if not any("ms-qr1-host" in str(value) for value in values):
        continue
    aliases = [str(item).split("=", 1)[0] for item in svc.get("extra_hosts") or []]
    if "ms-qr1-host" not in aliases:
        bad.append(svc_name)
if bad:
    print(f"fixture services missing ms-qr1-host aliases: {bad}", file=sys.stderr)
    sys.exit(1)
PY

env_model="$(awk -F= '$1 == "EXTERNAL_LLM_MODEL" {print $2}' profiles/ms-qr1.env.example | tail -1)"
config_model="$(sed -n 's/.*model:[[:space:]]*openai\///p' config/litellm/ms-qr1.yaml | head -1)"
[[ "$env_model" == "$config_model" ]] || {
  echo "profile EXTERNAL_LLM_MODEL does not match LiteLLM local model" >&2
  exit 1
}

qr1_env="$tmpdir/ms-qr1.env"
cp profiles/ms-qr1.env.example "$qr1_env"
python3 - "$qr1_env" <<'PY'
from pathlib import Path
import sys
path = Path(sys.argv[1])
replacements = {
    "GENERATE_ME_DOCKER_GATEWAY": "172.31.0.1",
    "GENERATE_ME_HEX_16": "1111111111111111",
    "GENERATE_ME_HEX_32": "11111111111111111111111111111111",
    "GENERATE_ME_HEX_64": "1111111111111111111111111111111111111111111111111111111111111111",
    "GENERATE_ME_BASE64URL_32": "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA",
    "GENERATE_ME_LANGFUSE_INIT_ORG_ID": "qr1-org",
    "GENERATE_ME_LANGFUSE_INIT_PROJECT_ID": "qr1-project",
}
text = path.read_text()
for old, new in replacements.items():
    text = text.replace(old, new)
path.write_text(text)
PY
bash scripts/validate-env.sh "$qr1_env" > "$tmpdir/validate-env.out"

OLLAMA_TAGS_JSON='{"models":[{"name":"qwen3.8:27b"}]}' python3 - qwen3.8:27b <<'PY'
import os
import json
import sys
expected = sys.argv[1]
data = json.loads(os.environ["OLLAMA_TAGS_JSON"])
models = {m.get("name") for m in data.get("models", [])}
if expected not in models:
    sys.exit(1)
PY

checkpoint_part="$tmpdir/sdxl_lightning_4step.safetensors.part"
checkpoint_final="$tmpdir/sdxl_lightning_4step.safetensors"
printf 'corrupt checkpoint' > "$checkpoint_part"
if CHECKPOINT_PART="$checkpoint_part" python3 - <<'PY'
import hashlib
import os
import sys
expected = "e0d996ee0013e79d9d3561f50fcafb9a17e3ff07b780358e3b66d67932c4d490"
with open(os.environ["CHECKPOINT_PART"], "rb") as handle:
    actual = hashlib.sha256(handle.read()).hexdigest()
sys.exit(0 if actual == expected else 1)
PY
then
  mv -f "$checkpoint_part" "$checkpoint_final"
fi
[[ ! -e "$checkpoint_final" ]] || {
  echo "corrupt ComfyUI checkpoint fixture was promoted" >&2
  exit 1
}

echo "MS QR1 helper tests passed"
