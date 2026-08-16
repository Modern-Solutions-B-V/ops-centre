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
  cat "$state"
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
    "litellm": {"ports": [{"host_ip": "127.0.0.1", "published": "4000"}]},
    "dashboard-api": {"ports": [{"host_ip": "127.0.0.1", "published": "3002"}]}
  }
}
JSON

cat > "$tmpdir/network-ods-network.json" <<'JSON'
[
  {
    "Name": "ods-network",
    "IPAM": {
      "Config": [
        {"Subnet": "172.28.0.0/16", "Gateway": "172.28.0.1"}
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
        {"Subnet": "172.30.0.0/16", "Gateway": "172.30.0.1"}
      ]
    }
  }
]
JSON

cat > "$tmpdir/ip-addr.txt" <<'EOF'
7: br-a inet 172.28.0.1/16 brd 172.28.255.255 scope global br-a
8: br-b inet 172.30.0.1/16 brd 172.30.255.255 scope global br-b
9: br-internal inet 172.29.0.1/16 brd 172.29.255.255 scope global br-internal
EOF

env_prefix=(env FIXTURE_DIR="$tmpdir" PATH="$tmpdir:$PATH")

"${env_prefix[@]}" scripts/ms-qr1-ufw-docker-rules.sh plan > "$tmpdir/ufw-plan.out"
assert_contains "172.28.0.0/16 -> 172.28.0.1:11434/tcp" "$tmpdir/ufw-plan.out"
assert_contains "172.30.0.0/16 -> 172.30.0.1:7710/tcp" "$tmpdir/ufw-plan.out"
assert_not_contains "172.29.0.0/16" "$tmpdir/ufw-plan.out"

"${env_prefix[@]}" scripts/ms-qr1-ufw-docker-rules.sh apply > "$tmpdir/ufw-apply.out"
[[ "$(wc -l < "$tmpdir/ufw-state.txt" | tr -d ' ')" == "4" ]] || {
  echo "expected four QR1 UFW rules after apply" >&2
  cat "$tmpdir/ufw-state.txt" >&2
  exit 1
}
"${env_prefix[@]}" scripts/ms-qr1-ufw-docker-rules.sh remove > "$tmpdir/ufw-remove.out"
[[ ! -s "$tmpdir/ufw-state.txt" ]] || {
  echo "expected zero QR1 UFW rules after remove" >&2
  cat "$tmpdir/ufw-state.txt" >&2
  exit 1
}

"${env_prefix[@]}" scripts/ms-qr1-ollama-bridge.sh render-unit > "$tmpdir/bridge.unit"
assert_contains 'Environment="MS_QR1_OLLAMA_BRIDGE_ADDRS=172.28.0.1 172.30.0.1"' "$tmpdir/bridge.unit"
assert_contains 'for addr in $$MS_QR1_OLLAMA_BRIDGE_ADDRS' "$tmpdir/bridge.unit"
assert_contains 'bind=$$addr' "$tmpdir/bridge.unit"
assert_not_contains 'bind=,' "$tmpdir/bridge.unit"
assert_not_contains '0.0.0.0' "$tmpdir/bridge.unit"
assert_not_contains '172.29.0.1' "$tmpdir/bridge.unit"

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
assert_contains 'SDXL_REVISION=c6c10e8716de60c7ef4eed6b89a06f67e772b374' ../docs/ms/deploy/QR1-DEPLOY-RUNBOOK.md
assert_contains 'SDXL_SHA256=e0d996ee0013e79d9d3561f50fcafb9a17e3ff07b780358e3b66d67932c4d490' ../docs/ms/deploy/QR1-DEPLOY-RUNBOOK.md
assert_contains 'sha256sum -c -' ../docs/ms/deploy/QR1-DEPLOY-RUNBOOK.md

env_model="$(awk -F= '$1 == "EXTERNAL_LLM_MODEL" {print $2}' profiles/ms-qr1.env.example | tail -1)"
config_model="$(sed -n 's/.*model:[[:space:]]*openai\///p' config/litellm/ms-qr1.yaml | head -1)"
[[ "$env_model" == "$config_model" ]] || {
  echo "profile EXTERNAL_LLM_MODEL does not match LiteLLM local model" >&2
  exit 1
}

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
