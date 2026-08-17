#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

tmpdir="$(mktemp -d "${TMPDIR:-/tmp}/ms-qr1-helpers.XXXXXX")"
bridge_script="scripts/ms-qr1-ollama-bridge.sh"
bridge_script_original="$tmpdir/ms-qr1-ollama-bridge.sh.original"
restore_bridge_script() {
  if [[ -f "$bridge_script_original" ]]; then
    cp "$bridge_script_original" "$bridge_script"
    chmod +x "$bridge_script"
  fi
}
cleanup() {
  restore_bridge_script
  rm -rf "$tmpdir"
}
trap cleanup EXIT
cp "$bridge_script" "$bridge_script_original"

assert_contains() {
  local needle="$1" file="$2"
  grep -F -- "$needle" "$file" >/dev/null || {
    echo "missing expected text: $needle" >&2
    echo "--- $file ---" >&2
    cat "$file" >&2
    exit 1
  }
}

assert_not_contains() {
  local needle="$1" file="$2"
  if grep -F -- "$needle" "$file" >/dev/null; then
    echo "unexpected text present: $needle" >&2
    echo "--- $file ---" >&2
    cat "$file" >&2
    exit 1
  fi
}

snapshot_path() {
  python3 - "$1" <<'PY'
import hashlib
import os
import stat
import sys
from pathlib import Path

path = Path(sys.argv[1])
if path.is_dir() and not path.is_symlink():
    paths = [path, *sorted(path.rglob("*"))]
else:
    paths = [path]
entries = []
for item in paths:
    st = os.lstat(item)
    digest = "-"
    if stat.S_ISREG(st.st_mode):
        digest = hashlib.sha256(item.read_bytes()).hexdigest()
    entries.append(f"{item.relative_to(path.parent)} {st.st_uid}:{st.st_gid}:{stat.S_IMODE(st.st_mode):04o}:{digest}")
print("\n".join(entries))
PY
}

cat > "$tmpdir/docker" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
if [[ "${1:-}" == "compose" && " $* " == *" config "* ]]; then
  python3 - "${FIXTURE_COMPOSE_CONFIG:-$FIXTURE_DIR/compose-config.json}" "${FIXTURE_N8N_USER:-1000:1000}" <<'PY'
from pathlib import Path
import sys

print(Path(sys.argv[1]).read_text().replace("__N8N_USER__", sys.argv[2]), end="")
PY
  exit 0
fi
if [[ "${1:-}" == "image" && "${2:-}" == "inspect" ]]; then
  exit 0
fi
if [[ "${1:-}" == "container" && "${2:-}" == "ls" ]]; then
  if [[ "${DOCKER_CONTAINER_LS_FAIL:-0}" == "1" ]]; then
    echo "fixture docker container ls failure" >&2
    exit 56
  fi
  if [[ -n "${DOCKER_CONTAINER_STATES:-}" ]]; then
    printf '%s\n' $DOCKER_CONTAINER_STATES
  fi
  exit 0
fi
if [[ "${1:-}" == "run" ]]; then
  printf '%s\n' "$*" >> "$FIXTURE_DIR/docker-run.log"
  case "$*" in
    *" stat -c "*)
      printf '%s\n' "${ROOTLESS_STAT_METADATA:-1000:1000:755}"
      ;;
  esac
  exit 0
fi
if [[ "${1:-}" == "compose" && " $* " == *" up "* ]]; then
  printf '%s\n' "$*" >> "$FIXTURE_DIR/docker-compose-up.log"
  printf 'compose-up %s\n' "$*" >> "$FIXTURE_DIR/docker-sequence.log"
  exit 0
fi
if [[ "${1:-}" == "compose" && " $* " == *" stop "* ]]; then
  printf '%s\n' "$*" >> "$FIXTURE_DIR/docker-compose-stop.log"
  if [[ "${DOCKER_COMPOSE_STOP_FAIL:-0}" == "1" ]]; then
    echo "fixture docker compose stop failure" >&2
    exit 55
  fi
  exit 0
fi
if [[ "${1:-}" == "compose" && " $* " == *" restart "* ]]; then
  printf '%s\n' "$*" >> "$FIXTURE_DIR/docker-compose-restart.log"
  printf 'compose-restart %s\n' "$*" >> "$FIXTURE_DIR/docker-sequence.log"
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
if [[ "${1:-}" == "ps" ]]; then
  if [[ "${DOCKER_PS_FAIL:-0}" == "1" ]]; then
    echo "fixture docker ps failure" >&2
    exit 51
  fi
  if [[ " $* " == *" --quiet "* && " $* " == *" --filter name="* ]]; then
    filter="${*#*--filter name=^}"
    filter="${filter%%\$*}"
    for name in ${DOCKER_PS_NAMES:-}; do
      if [[ "$name" == "$filter" ]]; then
        echo "$name"
      fi
    done
    exit 0
  fi
  if [[ "${DOCKER_PS_STOPPED_HERMES:-0}" == "1" ]]; then
    exit 0
  fi
  if [[ "${DOCKER_PS_HAS_HERMES:-0}" == "1" ]]; then
    echo "ods-hermes"
  fi
  if [[ -n "${DOCKER_PS_NAMES:-}" ]]; then
    printf '%s\n' $DOCKER_PS_NAMES
  fi
  exit 0
fi
if [[ "${1:-}" == "exec" && "${2:-}" == "ods-hermes" ]]; then
  if [[ "${DOCKER_EXEC_FAIL:-0}" == "1" ]]; then
    echo "fixture docker exec failure" >&2
    exit 52
  fi
  printf '%s\n' "$*" >> "$FIXTURE_DIR/docker-exec.log"
  printf 'exec %s\n' "$*" >> "$FIXTURE_DIR/docker-sequence.log"
  exit 0
fi
if [[ "${1:-}" == "inspect" && "${2:-}" == "--format" && "${4:-}" == "ods-hermes" ]]; then
  case "${DOCKER_INSPECT_HERMES:-healthy}" in
    healthy) echo "running healthy" ;;
    unhealthy) echo "running unhealthy" ;;
    exited) echo "exited none" ;;
    starting) echo "running starting" ;;
    fail) echo "fixture docker inspect failure" >&2; exit 54 ;;
    *) echo "${DOCKER_INSPECT_HERMES}" ;;
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

cat > "$tmpdir/systemctl" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >> "$FIXTURE_DIR/systemctl.log"
if [[ "${1:-}" == "status" ]]; then
  echo "fixture status for ${2:-}"
fi
SH

cat > "$tmpdir/chown" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >> "$FIXTURE_DIR/chown.log"
exit 0
SH

cat > "$tmpdir/uname" <<'SH'
#!/usr/bin/env bash
if [[ "${1:-}" == "-s" || "$#" -eq 0 ]]; then
  echo "Linux"
else
  echo "unexpected uname command: $*" >&2
  exit 57
fi
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
if [[ "$*" == "-o addr show dev tailscale0" ]]; then
  if [[ "${TAILSCALE_ADDR_FAIL:-0}" == "1" ]]; then
    echo "fixture tailscale0 addr failure" >&2
    exit 58
  fi
  cat "$FIXTURE_DIR/tailscale0-addr.txt"
  exit 0
fi
echo "unexpected ip command: $*" >&2
exit 49
SH

cat > "$tmpdir/tailscale" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
if [[ "$*" == "serve status" ]]; then
  if [[ "${TAILSCALE_SERVE_FAIL:-0}" == "1" ]]; then
    echo "fixture tailscale serve failure" >&2
    exit 59
  fi
  cat "$FIXTURE_DIR/tailscale-serve-status.txt"
  exit 0
fi
echo "unexpected tailscale command: $*" >&2
exit 60
SH

cat > "$tmpdir/ss" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
if [[ "${SS_FAIL:-0}" == "1" ]]; then
  echo "fixture ss failure" >&2
  exit 53
fi
if [[ "$*" == "-tlnp" || "$*" == "-tln" ]]; then
  cat "$FIXTURE_DIR/ss-state.txt"
  exit 0
fi
echo "unexpected ss command: $*" >&2
exit 50
SH

cat > "$tmpdir/curl" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
emit_response() {
  case "${CURL_MODE:-401}" in
    303-auth) printf 'HTTP/1.1 303 See Other\r\nLocation: /auth/required\r\n\r\nHTTP_STATUS:303' ;;
    303-auth-lower) printf 'HTTP/1.1 303 See Other\r\nlocation: /auth/required\r\n\r\nHTTP_STATUS:303' ;;
    303-auth-mixed) printf 'HTTP/1.1 303 See Other\r\nLoCaTiOn: /auth/required\r\n\r\nHTTP_STATUS:303' ;;
    103-location-303-missing) printf 'HTTP/1.1 103 Early Hints\r\nLocation: /auth/required\r\n\r\nHTTP/1.1 303 See Other\r\n\r\nHTTP_STATUS:303' ;;
    103-303-auth) printf 'HTTP/1.1 103 Early Hints\r\nLink: </auth/required>; rel=preload\r\n\r\nHTTP/1.1 303 See Other\r\nLocation: /auth/required\r\n\r\nHTTP_STATUS:303' ;;
    303-duplicate-identical) printf 'HTTP/1.1 303 See Other\r\nLocation: /auth/required\r\nLocation: /auth/required\r\n\r\nHTTP_STATUS:303' ;;
    303-duplicate-identical-case) printf 'HTTP/1.1 303 See Other\r\nLocation: /auth/required\r\nlocation: /auth/required\r\n\r\nHTTP_STATUS:303' ;;
    303-duplicate-conflicting) printf 'HTTP/1.1 303 See Other\r\nLocation: /auth/required\r\nLocation: /anything-else\r\n\r\nHTTP_STATUS:303' ;;
    303-duplicate-conflicting-case) printf 'HTTP/1.1 303 See Other\r\nLocation: /auth/required\r\nlocation: /evil\r\n\r\nHTTP_STATUS:303' ;;
    303-other) printf 'HTTP/1.1 303 See Other\r\nLocation: /anything-else\r\n\r\nHTTP_STATUS:303' ;;
    303-missing) printf 'HTTP/1.1 303 See Other\r\n\r\nHTTP_STATUS:303' ;;
    303-query) printf 'HTTP/1.1 303 See Other\r\nLocation: /auth/required?x=1\r\n\r\nHTTP_STATUS:303' ;;
    303-absolute) printf 'HTTP/1.1 303 See Other\r\nLocation: https://example.invalid/auth/required\r\n\r\nHTTP_STATUS:303' ;;
    401) printf 'HTTP/1.1 401 Unauthorized\r\n\r\nHTTP_STATUS:401' ;;
    403) printf 'HTTP/1.1 403 Forbidden\r\n\r\nHTTP_STATUS:403' ;;
    404) printf 'HTTP/1.1 404 Not Found\r\n\r\nHTTP_STATUS:404' ;;
    200) printf 'HTTP/1.1 200 OK\r\n\r\nHTTP_STATUS:200' ;;
    transport) exit 7 ;;
    *) printf 'HTTP/1.1 %s Fixture\r\n\r\nHTTP_STATUS:%s' "$CURL_MODE" "$CURL_MODE" ;;
  esac
}
if [[ "$*" == *"127.0.0.1:9119/api/status"* ]]; then
  if [[ "${CURL_MODE:-401}" == "transport" ]]; then
    exit 7
  fi
  printf '{"ok":true}\n'
  exit 0
fi
if [[ "${CURL_REQUIRE_Q:-0}" == "1" && "$*" != *"-q"* ]]; then
  echo "curl fixture expected -q" >&2
  exit 61
fi
if [[ "$*" == *" -D - "* || "$*" == *"-D -"* ]]; then
  emit_response
  exit 0
fi
case "${CURL_MODE:-401}" in
  401) printf '401' ;;
  403) printf '403' ;;
  404) printf '404' ;;
  transport) exit 7 ;;
  *) printf '%s' "$CURL_MODE" ;;
esac
SH

chmod +x "$tmpdir/docker" "$tmpdir/sudo" "$tmpdir/systemctl" "$tmpdir/chown" "$tmpdir/uname" "$tmpdir/ufw" "$tmpdir/ip" "$tmpdir/tailscale" "$tmpdir/ss" "$tmpdir/curl"

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
      "container_name": "ods-dashboard-api",
      "extra_hosts": ["ms-qr1-host=172.31.0.1"],
      "environment": {"OLLAMA_URL": "http://ms-qr1-host:11434"},
      "ports": [{"host_ip": "127.0.0.1", "published": "3002"}],
      "volumes": [{"type": "bind", "source": "./data", "target": "/data"}]
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
    },
    "n8n": {
      "container_name": "ods-n8n",
      "user": "__N8N_USER__",
      "volumes": ["./data/n8n:/home/node/.n8n:z"]
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
cat > "$tmpdir/tailscale0-addr.txt" <<'EOF'
10: tailscale0    inet 100.116.5.69/32 scope global tailscale0
10: tailscale0    inet6 fd7a:115c:a1e0::a801:5c2/128 scope global
EOF
cat > "$tmpdir/tailscale-serve-status.txt" <<'EOF'
|-- tcp://evox3.tailfc79e6.ts.net:11434 (tailnet only)
|-- tcp://100.116.5.69:11434
|-- tcp://[fd7a:115c:a1e0::a801:5c2]:11434
|--> tcp://127.0.0.1:11434
EOF

bridge_libexec="$tmpdir/libexec/ms-qr1"
env_prefix=(env FIXTURE_DIR="$tmpdir" MS_QR1_OLLAMA_LIBEXEC_DIR="$bridge_libexec" PATH="$tmpdir:$PATH")
mkdir -p "$bridge_libexec"
cat > "$bridge_libexec/ms-qr1-ollama-bridge.sh" <<'SH'
#!/usr/bin/env bash
exit 0
SH
chmod +x "$bridge_libexec/ms-qr1-ollama-bridge.sh"

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
        {"Subnet": "172.30.0.0/16", "Gateway": "172.30.0.1"}
      ]
    }
  }
]
JSON
cat > "$tmpdir/ip-addr.txt" <<'EOF'
7: br-a inet 172.30.0.1/16 brd 172.30.255.255 scope global br-a
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
assert_contains 'Description=MS QR1 Ollama Docker HTTP bridge' "$tmpdir/bridge.unit"
assert_contains "WorkingDirectory=$PWD" "$tmpdir/bridge.unit"
assert_not_contains "WorkingDirectory=\"$PWD\"" "$tmpdir/bridge.unit"
assert_contains "ExecStart=\"$bridge_libexec/ms-qr1-ollama-bridge.sh\" serve" "$tmpdir/bridge.unit"
assert_not_contains "ExecStart=\"$PWD/scripts/ms-qr1-ollama-bridge.sh\" serve" "$tmpdir/bridge.unit"
assert_contains 'Environment="MS_QR1_OLLAMA_MAX_BODY_BYTES=268435456"' "$tmpdir/bridge.unit"
assert_contains 'Environment="MS_QR1_OLLAMA_UPSTREAM_TIMEOUT=300"' "$tmpdir/bridge.unit"
assert_contains 'NoNewPrivileges=true' "$tmpdir/bridge.unit"
assert_contains 'PrivateTmp=true' "$tmpdir/bridge.unit"
assert_contains 'ProtectSystem=strict' "$tmpdir/bridge.unit"
assert_not_contains 'MS_QR1_OLLAMA_BRIDGE_ADDRS=' "$tmpdir/bridge.unit"
assert_not_contains 'socat' "$tmpdir/bridge.unit"
assert_not_contains '0.0.0.0' "$tmpdir/bridge.unit"
assert_not_contains '172.29.0.1' "$tmpdir/bridge.unit"
python3 - "$tmpdir/bridge.unit" <<'PY'
from pathlib import Path
import sys

unit = Path(sys.argv[1]).read_text(encoding="utf-8")
line = next(item for item in unit.splitlines() if item.startswith("WorkingDirectory="))
value = line.split("=", 1)[1]
if not value.startswith("/"):
    raise SystemExit(f"WorkingDirectory is not absolute: {line}")
if value.startswith('"') or value.endswith('"'):
    raise SystemExit(f"WorkingDirectory has literal wrapping quotes: {line}")
PY
if [[ "$(uname -s)" == "Linux" ]] && command -v systemd-analyze >/dev/null 2>&1; then
  cp "$tmpdir/bridge.unit" "$tmpdir/ms-qr1-ollama-bridge.rendered.service"
  systemd-analyze verify "$tmpdir/ms-qr1-ollama-bridge.rendered.service"
fi

"${env_prefix[@]}" scripts/ms-qr1-ollama-bridge.sh expected-listeners > "$tmpdir/bridge.listeners"
assert_contains '172.20.0.1' "$tmpdir/bridge.listeners"
assert_contains '172.31.0.1' "$tmpdir/bridge.listeners"
assert_not_contains '172.29.0.1' "$tmpdir/bridge.listeners"

"${env_prefix[@]}" scripts/ms-qr1-ollama-bridge.sh plan > "$tmpdir/bridge.plan"
assert_contains 'MS_QR1_HOST_GATEWAY=172.31.0.1' "$tmpdir/bridge.plan"
assert_contains 'QR1 HTTP proxy' "$tmpdir/bridge.plan"
assert_contains 'Host to localhost:11434' "$tmpdir/bridge.plan"
assert_contains 'systemctl daemon-reload' scripts/ms-qr1-ollama-bridge.sh
assert_contains 'systemctl restart "$SERVICE_NAME"' scripts/ms-qr1-ollama-bridge.sh
python3 - <<'PY'
from pathlib import Path
text = Path("scripts/ms-qr1-ollama-bridge.sh").read_text()
copy_bridge = text.index('run_privileged install -m 0755 "$INSTALL_DIR/scripts/ms-qr1-ollama-bridge.sh" "$INSTALLED_BRIDGE"')
copy_proxy = text.index('run_privileged install -m 0755 "$SOURCE_PROXY_SCRIPT" "$INSTALLED_PROXY"', copy_bridge)
copy_compose = text.index('run_privileged install -m 0755 "$SOURCE_COMPOSE_FLAGS" "$INSTALLED_COMPOSE_FLAGS"', copy_proxy)
install = text.index('run_privileged install -m 0644 "$unit_tmp" "$UNIT_PATH"', copy_compose)
reload = text.index('run_privileged systemctl daemon-reload', install)
restart = text.index('run_privileged systemctl restart "$SERVICE_NAME"', reload)
if not copy_bridge < copy_proxy < copy_compose < install < reload < restart:
    raise SystemExit("Ollama bridge install path must copy root-owned executables before unit reload/restart")
if "--upstream 127.0.0.1:11434" not in text or "--upstream-host-header localhost:11434" not in text:
    raise SystemExit("Ollama bridge must pin loopback upstream and rewritten Host header")
if "--max-body-bytes" not in text or "--upstream-timeout" not in text:
    raise SystemExit("Ollama bridge must expose bounded body and upstream timeout settings")
PY

MS_QR1_OLLAMA_UNIT_PATH="$tmpdir/ms-qr1-ollama-bridge.service" "${env_prefix[@]}" scripts/ms-qr1-ollama-bridge.sh install > "$tmpdir/bridge.install"
assert_contains "WorkingDirectory=$PWD" "$tmpdir/ms-qr1-ollama-bridge.service"
assert_not_contains "WorkingDirectory=\"$PWD\"" "$tmpdir/ms-qr1-ollama-bridge.service"
assert_contains "ExecStart=\"$bridge_libexec/ms-qr1-ollama-bridge.sh\" serve" "$tmpdir/ms-qr1-ollama-bridge.service"
assert_not_contains "ExecStart=\"$PWD/scripts/ms-qr1-ollama-bridge.sh\" serve" "$tmpdir/ms-qr1-ollama-bridge.service"
[[ -x "$bridge_libexec/ms-qr1-ollama-bridge.sh" ]] || {
  echo "bridge install did not copy executable bridge script" >&2
  exit 1
}
[[ -x "$bridge_libexec/ms-qr1-ollama-http-proxy.py" ]] || {
  echo "bridge install did not copy executable proxy script" >&2
  exit 1
}
[[ -x "$bridge_libexec/ms-qr1-compose-flags.sh" ]] || {
  echo "bridge install did not copy executable compose flags helper" >&2
  exit 1
}
python3 - "$bridge_libexec/ms-qr1-ollama-bridge.sh" "$bridge_libexec/ms-qr1-ollama-http-proxy.py" "$bridge_libexec/ms-qr1-compose-flags.sh" <<'PY'
import os
import stat
import sys

for path in sys.argv[1:]:
    mode = stat.S_IMODE(os.stat(path).st_mode)
    if mode & (stat.S_IWGRP | stat.S_IWOTH):
        raise SystemExit(f"{path} is group/world writable: {mode:o}")
PY
assert_contains 'enable ms-qr1-ollama-bridge.service' "$tmpdir/systemctl.log"
assert_contains 'restart ms-qr1-ollama-bridge.service' "$tmpdir/systemctl.log"
printf '\n# checkout mutation after install\n' >> "$bridge_script"
assert_contains "ExecStart=\"$bridge_libexec/ms-qr1-ollama-bridge.sh\" serve" "$tmpdir/ms-qr1-ollama-bridge.service"
restore_bridge_script
cmp -s "$bridge_script_original" "$bridge_script" || {
  echo "bridge script was not restored byte-for-byte after mutation fixture" >&2
  exit 1
}
cat > "$tmpdir/network-ods-network.json" <<'JSON'
[
  {
    "Name": "ods-network",
    "IPAM": {
      "Config": [
        {"Subnet": "172.30.0.0/16", "Gateway": "172.30.0.1"}
      ]
    }
  }
]
JSON
cat > "$tmpdir/ip-addr.txt" <<'EOF'
7: br-a inet 172.30.0.1/16 brd 172.30.255.255 scope global br-a
8: br-b inet 172.20.0.1/16 brd 172.20.255.255 scope global br-b
EOF
"${env_prefix[@]}" scripts/ms-qr1-ollama-bridge.sh expected-listeners > "$tmpdir/bridge.listeners.drift"
assert_contains '172.30.0.1' "$tmpdir/bridge.listeners.drift"
assert_contains "ExecStart=\"$bridge_libexec/ms-qr1-ollama-bridge.sh\" serve" "$tmpdir/ms-qr1-ollama-bridge.service"
MS_QR1_OLLAMA_UNIT_PATH="$tmpdir/ms-qr1-ollama-bridge.service" "${env_prefix[@]}" scripts/ms-qr1-ollama-bridge.sh remove > "$tmpdir/bridge.remove"
[[ ! -e "$tmpdir/ms-qr1-ollama-bridge.service" ]] || {
  echo "bridge remove left unit residue" >&2
  exit 1
}
[[ ! -e "$bridge_libexec/ms-qr1-ollama-bridge.sh" && ! -e "$bridge_libexec/ms-qr1-ollama-http-proxy.py" && ! -e "$bridge_libexec/ms-qr1-compose-flags.sh" ]] || {
  echo "bridge remove left installed executable residue" >&2
  exit 1
}
assert_contains 'disable --now ms-qr1-ollama-bridge.service' "$tmpdir/systemctl.log"
assert_contains 'daemon-reload' "$tmpdir/systemctl.log"
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
cat > "$tmpdir/ip-addr.txt" <<'EOF'
7: br-a inet 172.31.0.1/16 brd 172.31.255.255 scope global br-a
8: br-b inet 172.20.0.1/16 brd 172.20.255.255 scope global br-b
9: br-internal inet 172.29.0.1/16 brd 172.29.255.255 scope global br-internal
EOF

python3 scripts/ms-qr1-ollama-http-proxy.py --self-test

fixture_uid="$(id -u)"
fixture_gid="$(id -g)"
fixture_data="$tmpdir/qr1-data"
mkdir -p "$fixture_data/qdrant"
printf 'keep me\n' > "$fixture_data/qdrant/sentinel"
if FIXTURE_N8N_USER="$fixture_uid:$fixture_gid" MS_QR1_DATA_DIR="$fixture_data" "${env_prefix[@]}" scripts/ms-qr1-prestart-provision.sh check > "$tmpdir/prestart-missing.out" 2> "$tmpdir/prestart-missing.err"; then
  echo "pre-start check should fail before SOUL.md exists" >&2
  exit 1
fi
assert_contains 'missing' "$tmpdir/prestart-missing.err"
active_n8n_data="$tmpdir/active-n8n-data"
if DOCKER_PS_NAMES="ods-n8n" FIXTURE_N8N_USER="$fixture_uid:$fixture_gid" MS_QR1_DATA_DIR="$active_n8n_data" "${env_prefix[@]}" scripts/ms-qr1-prestart-provision.sh prestart-init > "$tmpdir/prestart-active-n8n.out" 2> "$tmpdir/prestart-active-n8n.err"; then
  echo "prestart-init should fail when n8n writer is running" >&2
  exit 1
fi
assert_contains 'requires quiescent container-writable state' "$tmpdir/prestart-active-n8n.err"
assert_contains 'ods-n8n' "$tmpdir/prestart-active-n8n.err"
[[ ! -e "$active_n8n_data" ]] || {
  echo "prestart-init mutated data while n8n writer was running" >&2
  exit 1
}
active_dashboard_data="$tmpdir/active-dashboard-data"
if DOCKER_PS_NAMES="ods-dashboard-api" FIXTURE_N8N_USER="$fixture_uid:$fixture_gid" MS_QR1_DATA_DIR="$active_dashboard_data" "${env_prefix[@]}" scripts/ms-qr1-prestart-provision.sh prestart-init > "$tmpdir/prestart-active-dashboard.out" 2> "$tmpdir/prestart-active-dashboard.err"; then
  echo "prestart-init should fail when another data writer is running" >&2
  exit 1
fi
assert_contains 'requires quiescent container-writable state' "$tmpdir/prestart-active-dashboard.err"
assert_contains 'ods-dashboard-api' "$tmpdir/prestart-active-dashboard.err"
[[ ! -e "$active_dashboard_data" ]] || {
  echo "prestart-init mutated data while dashboard-api writer was running" >&2
  exit 1
}
override_scope_data="$tmpdir/override-scope-data"
if DOCKER_PS_NAMES="ods-dashboard-api" MS_QR1_QUIESCENCE_TARGETS="/tmp/not-a-qr1-target" FIXTURE_N8N_USER="$fixture_uid:$fixture_gid" MS_QR1_DATA_DIR="$override_scope_data" "${env_prefix[@]}" scripts/ms-qr1-prestart-provision.sh prestart-init > "$tmpdir/prestart-override-scope.out" 2> "$tmpdir/prestart-override-scope.err"; then
  echo "prestart-init should ignore target-scope overrides and fail when a real writer is running" >&2
  exit 1
fi
assert_contains 'requires quiescent container-writable state' "$tmpdir/prestart-override-scope.err"
assert_contains 'ods-dashboard-api' "$tmpdir/prestart-override-scope.err"
[[ ! -e "$override_scope_data" ]] || {
  echo "prestart-init mutated data after target-scope override weakened the gate" >&2
  exit 1
}
override_compose_data="$tmpdir/override-compose-data"
if DOCKER_PS_NAMES="ods-dashboard-api" ODS_QUIESCENCE_COMPOSE_FLAGS="-f extensions/services/n8n/compose.yaml" FIXTURE_N8N_USER="$fixture_uid:$fixture_gid" MS_QR1_DATA_DIR="$override_compose_data" "${env_prefix[@]}" scripts/ms-qr1-prestart-provision.sh prestart-init > "$tmpdir/prestart-override-compose.out" 2> "$tmpdir/prestart-override-compose.err"; then
  echo "prestart-init should use complete QR1 compose flags, not caller-supplied incomplete quiescence flags" >&2
  exit 1
fi
assert_contains 'requires quiescent container-writable state' "$tmpdir/prestart-override-compose.err"
assert_contains 'ods-dashboard-api' "$tmpdir/prestart-override-compose.err"
[[ ! -e "$override_compose_data" ]] || {
  echo "prestart-init mutated data after incomplete compose override weakened the gate" >&2
  exit 1
}
FIXTURE_N8N_USER="$fixture_uid:$fixture_gid" MS_QR1_DATA_DIR="$tmpdir/writer-list-data" "${env_prefix[@]}" scripts/ms-qr1-prestart-provision.sh writer-services > "$tmpdir/writer-services.out"
assert_contains 'n8n' "$tmpdir/writer-services.out"
assert_contains 'dashboard-api' "$tmpdir/writer-services.out"
python3 - <<'PY'
import ast
from pathlib import Path

source = Path("scripts/ods-verify-quiescent-data-writers.sh").read_text(encoding="utf-8")
embedded = source.split("python3 - <<'PY'\n", 1)[1].split("\nPY\n", 1)[0]
ast.parse(embedded, feature_version=(3, 9))
PY
ODS_QUIESCENCE_COMPOSE_FLAGS="-f docker-compose.base.yml -f extensions/services/langfuse/compose.yaml" "${env_prefix[@]}" scripts/ods-verify-quiescent-data-writers.sh writer-services --install-dir "$PWD" --target data/langfuse > "$tmpdir/shared-writers-generic-langfuse.out"
assert_contains 'dashboard-api' "$tmpdir/shared-writers-generic-langfuse.out"
if grep -F 'compose.yaml.disabled' "$tmpdir/shared-writers-generic-langfuse.out" >/dev/null; then
  echo "shared quiescence verifier should not depend on QR1 disabled compose filename" >&2
  exit 1
fi
if DOCKER_PS_NAMES="ods-dashboard-api" ODS_QUIESCENCE_COMPOSE_FLAGS="-f docker-compose.base.yml -f extensions/services/langfuse/compose.yaml" "${env_prefix[@]}" scripts/ods-verify-quiescent-data-writers.sh verify --install-dir "$PWD" --target data/langfuse > "$tmpdir/shared-verify-active.out" 2> "$tmpdir/shared-verify-active.err"; then
  echo "shared quiescence verifier should fail when a broad data writer is active" >&2
  exit 1
fi
assert_contains 'ods-dashboard-api' "$tmpdir/shared-verify-active.err"
ODS_QUIESCENCE_COMPOSE_FLAGS="-f docker-compose.base.yml -f extensions/services/langfuse/compose.yaml" "${env_prefix[@]}" scripts/ods-verify-quiescent-data-writers.sh verify --install-dir "$PWD" --target data/langfuse > "$tmpdir/shared-verify-quiescent.out"
if DOCKER_COMPOSE_STOP_FAIL=1 FIXTURE_N8N_USER="$fixture_uid:$fixture_gid" MS_QR1_DATA_DIR="$tmpdir/stop-gate-data" "${env_prefix[@]}" bash -c '
  set -euo pipefail
  writers="$(scripts/ms-qr1-prestart-provision.sh writer-services | tr "\n" " ")"
  docker compose $(scripts/ms-qr1-compose-flags.sh) stop $writers
  touch "$FIXTURE_DIR/privileged-hook-reached"
' > "$tmpdir/stop-gate-fail.out" 2> "$tmpdir/stop-gate-fail.err"; then
  echo "runbook stop gate should fail when Compose stop fails" >&2
  exit 1
fi
[[ ! -e "$tmpdir/privileged-hook-reached" ]] || {
  echo "privileged hook marker was reached after failed Compose stop" >&2
  exit 1
}
if DOCKER_PS_NAMES="ods-dashboard-api" FIXTURE_N8N_USER="$fixture_uid:$fixture_gid" MS_QR1_DATA_DIR="$tmpdir/verify-gate-data" "${env_prefix[@]}" scripts/ms-qr1-prestart-provision.sh verify-quiescent > "$tmpdir/verify-gate.out" 2> "$tmpdir/verify-gate.err"; then
  echo "verify-quiescent should fail when a writer remains running" >&2
  exit 1
fi
assert_contains 'ods-dashboard-api' "$tmpdir/verify-gate.err"
rm -f "$tmpdir/chown.log"
if DOCKER_PS_NAMES="ods-dashboard-api" ODS_ASSUME_ROOTLESS=0 "${env_prefix[@]}" bash extensions/services/langfuse/hooks/post_install.sh "$PWD" amd > "$tmpdir/langfuse-hook-generic-active-dashboard.out" 2> "$tmpdir/langfuse-hook-generic-active-dashboard.err"; then
  :
else
  echo "generic Langfuse post_install hook should not be blocked by QR1-specific broad-writer enforcement" >&2
  cat "$tmpdir/langfuse-hook-generic-active-dashboard.err" >&2
  exit 1
fi
assert_contains '70:70' "$tmpdir/chown.log"
assert_contains '101:101' "$tmpdir/chown.log"
FIXTURE_N8N_USER="$fixture_uid:$fixture_gid" MS_QR1_DATA_DIR="$fixture_data" "${env_prefix[@]}" scripts/ms-qr1-prestart-provision.sh > "$tmpdir/prestart-provision.out"
assert_contains 'QR1 pre-start provisioning complete' "$tmpdir/prestart-provision.out"
[[ -f "$fixture_data/persona/SOUL.md" ]] || {
  echo "pre-start provisioning did not create regular SOUL.md" >&2
  exit 1
}
python3 - "$fixture_data/persona/SOUL.md" <<'PY'
from pathlib import Path
import sys

text = Path(sys.argv[1]).read_text(encoding="utf-8")
if "About this ODS install" not in text:
    raise SystemExit("generated SOUL.md missing installation context")
PY
[[ "$(cat "$fixture_data/qdrant/sentinel")" == "keep me" ]] || {
  echo "pre-start provisioning touched unrelated data directory" >&2
  exit 1
}
mkdir -p "$fixture_data/n8n/nested"
printf 'persistent n8n data\n' > "$fixture_data/n8n/config"
printf 'nested n8n data\n' > "$fixture_data/n8n/nested/blob"
printf 'n8n executable\n' > "$fixture_data/n8n/nested/run.sh"
chmod 777 "$fixture_data/n8n/nested"
chmod 666 "$fixture_data/n8n/nested/blob"
chmod 755 "$fixture_data/n8n/nested/run.sh"
soul_hash_before="$(sha256sum "$fixture_data/persona/SOUL.md" | awk '{print $1}')"
FIXTURE_N8N_USER="$fixture_uid:$fixture_gid" MS_QR1_DATA_DIR="$fixture_data" "${env_prefix[@]}" scripts/ms-qr1-prestart-provision.sh > "$tmpdir/prestart-rerun.out"
[[ "$(cat "$fixture_data/n8n/config")" == "persistent n8n data" ]] || {
  echo "pre-start provisioning destroyed existing n8n data" >&2
  exit 1
}
python3 - "$fixture_data/n8n/nested" "$fixture_data/n8n/nested/blob" "$fixture_data/n8n/nested/run.sh" <<'PY'
import os
import stat
import sys

expected = {
    sys.argv[1]: 0o700,
    sys.argv[2]: 0o600,
    sys.argv[3]: 0o700,
}
for path, mode in expected.items():
    actual = stat.S_IMODE(os.stat(path).st_mode)
    if actual != mode:
        raise SystemExit(f"{path} mode {actual:o}, expected {mode:o}")
PY
printf 'runtime sqlite\n' > "$fixture_data/n8n/database.sqlite"
mkdir -p "$fixture_data/n8n/binaryData"
chmod 644 "$fixture_data/n8n/database.sqlite"
chmod 755 "$fixture_data/n8n/binaryData"
readonly_before="$(snapshot_path "$fixture_data")"
FIXTURE_N8N_USER="$fixture_uid:$fixture_gid" MS_QR1_DATA_DIR="$fixture_data" "${env_prefix[@]}" scripts/ms-qr1-prestart-provision.sh check > "$tmpdir/check-runtime-modes.out"
readonly_after="$(snapshot_path "$fixture_data")"
[[ "$readonly_before" == "$readonly_after" ]] || {
  echo "check action mutated data" >&2
  echo "before: $readonly_before" >&2
  echo "after:  $readonly_after" >&2
  exit 1
}
check_bad_n8n_tree() {
  local label="$1" data_dir="$2" expected="$3"
  if FIXTURE_N8N_USER="$fixture_uid:$fixture_gid" MS_QR1_DATA_DIR="$data_dir" "${env_prefix[@]}" scripts/ms-qr1-prestart-provision.sh check > "$tmpdir/check-${label}.out" 2> "$tmpdir/check-${label}.err"; then
    echo "pre-start check should fail for $label" >&2
    exit 1
  fi
  assert_contains "$expected" "$tmpdir/check-${label}.err"
}
chmod 400 "$fixture_data/n8n/nested/blob"
check_bad_n8n_tree "nested-unwritable" "$fixture_data" 'not owner-writable'
chmod 666 "$fixture_data/n8n/nested/blob"
check_bad_n8n_tree "nested-group-world-writable" "$fixture_data" 'group-writable'
chmod 600 "$fixture_data/n8n/nested/blob"
chmod 777 "$fixture_data/n8n/binaryData"
check_bad_n8n_tree "nested-world-writable-dir" "$fixture_data" 'group-writable'
chmod 755 "$fixture_data/n8n/binaryData"
chmod 600 "$fixture_data/n8n/binaryData"
check_bad_n8n_tree "runtime-dir-0600" "$fixture_data" 'not owner-searchable'
chmod 200 "$fixture_data/n8n/binaryData"
check_bad_n8n_tree "runtime-dir-0200" "$fixture_data" 'not owner-searchable'
chmod 400 "$fixture_data/n8n/binaryData"
check_bad_n8n_tree "runtime-dir-0400" "$fixture_data" 'not owner-writable'
chmod 700 "$fixture_data/n8n/binaryData"
FIXTURE_N8N_USER="$fixture_uid:$fixture_gid" MS_QR1_DATA_DIR="$fixture_data" "${env_prefix[@]}" scripts/ms-qr1-prestart-provision.sh check > "$tmpdir/check-runtime-dir-0700.out"
chmod 755 "$fixture_data/n8n/binaryData"
FIXTURE_N8N_USER="$fixture_uid:$fixture_gid" MS_QR1_DATA_DIR="$fixture_data" "${env_prefix[@]}" scripts/ms-qr1-prestart-provision.sh check > "$tmpdir/check-runtime-dir-0755.out"
if FIXTURE_N8N_USER="1234:2345" MS_QR1_DATA_DIR="$fixture_data" "${env_prefix[@]}" scripts/ms-qr1-prestart-provision.sh check > "$tmpdir/check-nested-wrong-owner.out" 2> "$tmpdir/check-nested-wrong-owner.err"; then
  echo "pre-start check should fail for nested wrong owner" >&2
  exit 1
fi
assert_contains 'expected 1234:2345' "$tmpdir/check-nested-wrong-owner.err"
ln -s "$tmpdir/outside-check-target" "$fixture_data/n8n/nested/bad-link"
printf 'outside check target\n' > "$tmpdir/outside-check-target"
check_bad_n8n_tree "nested-symlink" "$fixture_data" 'is a symlink'
rm -f "$fixture_data/n8n/nested/bad-link"
mkfifo "$fixture_data/n8n/nested/bad-fifo"
check_bad_n8n_tree "nested-fifo" "$fixture_data" 'neither a directory nor a regular file'
rm -f "$fixture_data/n8n/nested/bad-fifo"
chmod_test_data="$tmpdir/chmod-notimplemented-data"
mkdir -p "$chmod_test_data/n8n"
printf 'chmod fixture\n' > "$chmod_test_data/n8n/config"
chmod 666 "$chmod_test_data/n8n/config"
if MS_QR1_TEST_CHMOD_NO_FOLLOW_UNSUPPORTED=1 FIXTURE_N8N_USER="$fixture_uid:$fixture_gid" MS_QR1_DATA_DIR="$chmod_test_data" "${env_prefix[@]}" scripts/ms-qr1-prestart-provision.sh > "$tmpdir/prestart-chmod-notimplemented.out" 2> "$tmpdir/prestart-chmod-notimplemented.err"; then
  echo "pre-start provisioning should fail clearly when follow_symlinks chmod is unsupported" >&2
  exit 1
fi
assert_contains 'cannot chmod' "$tmpdir/prestart-chmod-notimplemented.err"
assert_contains 'without following symlinks' "$tmpdir/prestart-chmod-notimplemented.err"
persona_check_external_dir="$tmpdir/persona-check-external-dir"
mkdir -p "$persona_check_external_dir"
printf 'persona check dir target\n' > "$persona_check_external_dir/sentinel"
persona_dir_before="$(snapshot_path "$persona_check_external_dir")"
mv "$fixture_data/persona" "$fixture_data/persona.real"
ln -s "$persona_check_external_dir" "$fixture_data/persona"
if FIXTURE_N8N_USER="$fixture_uid:$fixture_gid" MS_QR1_DATA_DIR="$fixture_data" "${env_prefix[@]}" scripts/ms-qr1-prestart-provision.sh check > "$tmpdir/check-persona-dir-symlink.out" 2> "$tmpdir/check-persona-dir-symlink.err"; then
  echo "pre-start check should fail when data/persona is a symlink" >&2
  exit 1
fi
assert_contains 'data/persona is a symlink' "$tmpdir/check-persona-dir-symlink.err"
[[ "$persona_dir_before" == "$(snapshot_path "$persona_check_external_dir")" ]] || {
  echo "external persona directory target changed during check" >&2
  exit 1
}
rm -f "$fixture_data/persona"
mv "$fixture_data/persona.real" "$fixture_data/persona"
persona_check_external_file="$tmpdir/persona-check-external-soul"
printf 'persona check soul target\n' > "$persona_check_external_file"
persona_file_before="$(snapshot_path "$persona_check_external_file")"
mv "$fixture_data/persona/SOUL.md" "$fixture_data/persona/SOUL.md.real"
ln -s "$persona_check_external_file" "$fixture_data/persona/SOUL.md"
if FIXTURE_N8N_USER="$fixture_uid:$fixture_gid" MS_QR1_DATA_DIR="$fixture_data" "${env_prefix[@]}" scripts/ms-qr1-prestart-provision.sh check > "$tmpdir/check-soul-symlink.out" 2> "$tmpdir/check-soul-symlink.err"; then
  echo "pre-start check should fail when SOUL.md is a symlink" >&2
  exit 1
fi
assert_contains 'SOUL.md is a symlink' "$tmpdir/check-soul-symlink.err"
[[ "$persona_file_before" == "$(snapshot_path "$persona_check_external_file")" ]] || {
  echo "external SOUL.md target changed during check" >&2
  exit 1
}
rm -f "$fixture_data/persona/SOUL.md"
mv "$fixture_data/persona/SOUL.md.real" "$fixture_data/persona/SOUL.md"
soul_hash_after="$(sha256sum "$fixture_data/persona/SOUL.md" | awk '{print $1}')"
[[ "$soul_hash_before" == "$soul_hash_after" ]] || {
  echo "pre-start provisioning was not idempotent for unchanged SOUL.md" >&2
  exit 1
}
assert_symlink_provision_fails_closed() {
  local label="$1" target="$2" link_rel="$3"
  local data_dir="$tmpdir/symlink-${label}-data"
  mkdir -p "$data_dir/n8n/$(dirname "$link_rel")"
  local before after
  before="$(snapshot_path "$target")"
  ln -s "$target" "$data_dir/n8n/$link_rel"
  if FIXTURE_N8N_USER="$fixture_uid:$fixture_gid" MS_QR1_DATA_DIR="$data_dir" "${env_prefix[@]}" scripts/ms-qr1-prestart-provision.sh > "$tmpdir/symlink-${label}.out" 2> "$tmpdir/symlink-${label}.err"; then
    echo "pre-start provisioning should fail closed for $label symlink" >&2
    exit 1
  fi
  assert_contains 'is a symlink' "$tmpdir/symlink-${label}.err"
  after="$(snapshot_path "$target")"
  [[ "$before" == "$after" ]] || {
    echo "external symlink target changed for $label" >&2
    echo "before: $before" >&2
    echo "after:  $after" >&2
    exit 1
  }
}
external_file="$tmpdir/external-file-target"
printf 'external file target\n' > "$external_file"
chmod 666 "$external_file"
assert_symlink_provision_fails_closed "external-file" "$external_file" "file-link"
external_dir="$tmpdir/external-dir-target"
mkdir -p "$external_dir"
printf 'external dir target\n' > "$external_dir/sentinel"
chmod 777 "$external_dir"
chmod 666 "$external_dir/sentinel"
assert_symlink_provision_fails_closed "external-dir" "$external_dir" "dir-link"
host_like_target="$tmpdir/root-owned-host-like-target"
printf 'host-like target\n' > "$host_like_target"
chmod 444 "$host_like_target"
if [[ "$(id -u)" -eq 0 ]]; then
  chown 0:0 "$host_like_target"
fi
assert_symlink_provision_fails_closed "host-like" "$host_like_target" "host-like-link"
nested_target="$tmpdir/nested-external-target"
printf 'nested external target\n' > "$nested_target"
chmod 666 "$nested_target"
assert_symlink_provision_fails_closed "nested" "$nested_target" "nested/link"
assert_persona_symlink_fails_closed() {
  local label="$1" target="$2" link_kind="$3"
  local data_dir="$tmpdir/persona-symlink-${label}-data"
  mkdir -p "$data_dir"
  if [[ "$link_kind" == "persona-dir" ]]; then
    ln -s "$target" "$data_dir/persona"
  else
    mkdir -p "$data_dir/persona"
    ln -s "$target" "$data_dir/persona/SOUL.md"
  fi
  local before after
  before="$(snapshot_path "$target")"
  if FIXTURE_N8N_USER="$fixture_uid:$fixture_gid" MS_QR1_DATA_DIR="$data_dir" "${env_prefix[@]}" scripts/ms-qr1-prestart-provision.sh > "$tmpdir/persona-symlink-${label}.out" 2> "$tmpdir/persona-symlink-${label}.err"; then
    echo "pre-start provisioning should fail closed for persona symlink $label" >&2
    exit 1
  fi
  assert_contains 'is a symlink' "$tmpdir/persona-symlink-${label}.err"
  after="$(snapshot_path "$target")"
  [[ "$before" == "$after" ]] || {
    echo "external persona symlink target changed for $label" >&2
    echo "before: $before" >&2
    echo "after:  $after" >&2
    exit 1
  }
}
persona_external_dir="$tmpdir/persona-external-dir-target"
mkdir -p "$persona_external_dir"
printf 'persona dir target\n' > "$persona_external_dir/sentinel"
chmod 777 "$persona_external_dir"
chmod 666 "$persona_external_dir/sentinel"
assert_persona_symlink_fails_closed "persona-dir" "$persona_external_dir" "persona-dir"
persona_external_file="$tmpdir/persona-soul-external-file"
printf 'persona soul target\n' > "$persona_external_file"
chmod 666 "$persona_external_file"
assert_persona_symlink_fails_closed "soul-file" "$persona_external_file" "soul-file"
persona_host_like="$tmpdir/persona-host-like-target"
printf 'persona host-like target\n' > "$persona_host_like"
chmod 444 "$persona_host_like"
if [[ "$(id -u)" -eq 0 ]]; then
  chown 0:0 "$persona_host_like"
fi
assert_persona_symlink_fails_closed "host-like" "$persona_host_like" "soul-file"
persona_nested_dir="$tmpdir/persona-nested-host-like-dir"
mkdir -p "$persona_nested_dir/nested"
printf 'nested persona target\n' > "$persona_nested_dir/nested/SOUL.md"
chmod 755 "$persona_nested_dir" "$persona_nested_dir/nested"
chmod 444 "$persona_nested_dir/nested/SOUL.md"
assert_persona_symlink_fails_closed "nested-host-like" "$persona_nested_dir/nested/SOUL.md" "soul-file"
persona_atomic_data="$tmpdir/persona-atomic-data"
FIXTURE_N8N_USER="$fixture_uid:$fixture_gid" MS_QR1_DATA_DIR="$persona_atomic_data" "${env_prefix[@]}" scripts/ms-qr1-prestart-provision.sh prestart-init > "$tmpdir/persona-atomic.out"
[[ -f "$persona_atomic_data/persona/SOUL.md" && ! -L "$persona_atomic_data/persona/SOUL.md" ]] || {
  echo "persona atomic replacement did not leave a regular SOUL.md" >&2
  exit 1
}
if find "$persona_atomic_data/persona" -maxdepth 1 -name '.SOUL.md.tmp.*' | grep . >/dev/null; then
  echo "persona atomic replacement left temporary files behind" >&2
  exit 1
fi
FIXTURE_N8N_USER="1234:2345" "${env_prefix[@]}" scripts/ms-qr1-prestart-provision.sh n8n-user > "$tmpdir/prestart-n8n-user.out"
assert_contains '1234:2345' "$tmpdir/prestart-n8n-user.out"
nonroot_mismatch_data="$tmpdir/nonroot-mismatch-data"
mkdir -p "$nonroot_mismatch_data/persona" "$nonroot_mismatch_data/n8n"
if [[ "$(id -u)" -eq 0 ]]; then
  echo "Skipping non-root escalation assertion because test runner EUID is 0" > "$tmpdir/prestart-nonroot-mismatch.skip"
else
  if FIXTURE_N8N_USER="1234:2345" MS_QR1_DATA_DIR="$nonroot_mismatch_data" "${env_prefix[@]}" scripts/ms-qr1-prestart-provision.sh > "$tmpdir/prestart-nonroot-mismatch.out" 2> "$tmpdir/prestart-nonroot-mismatch.err"; then
    echo "pre-start provisioning should not silently escalate for non-default n8n ownership" >&2
    exit 1
  fi
  assert_contains 'Rerun this specific QR1 provisioning step with sudo' "$tmpdir/prestart-nonroot-mismatch.err"
fi
python3 - "$tmpdir/compose-config.json" "$tmpdir/compose-without-n8n.json" <<'PY'
import json
import sys
from pathlib import Path

data = json.loads(Path(sys.argv[1]).read_text().replace("__N8N_USER__", "1000:1000"))
data["services"].pop("n8n", None)
Path(sys.argv[2]).write_text(json.dumps(data))
PY
FIXTURE_COMPOSE_CONFIG="$tmpdir/compose-without-n8n.json" "${env_prefix[@]}" scripts/ms-qr1-prestart-provision.sh n8n-user > "$tmpdir/prestart-no-n8n-user.out"
[[ ! -s "$tmpdir/prestart-no-n8n-user.out" ]] || {
  echo "n8n-user should print nothing when n8n is absent" >&2
  cat "$tmpdir/prestart-no-n8n-user.out" >&2
  exit 1
}
FIXTURE_COMPOSE_CONFIG="$tmpdir/compose-without-n8n.json" MS_QR1_DATA_DIR="$tmpdir/no-n8n-data" "${env_prefix[@]}" scripts/ms-qr1-prestart-provision.sh > "$tmpdir/prestart-no-n8n.out"
assert_contains 'skipping data/n8n provisioning' "$tmpdir/prestart-no-n8n.out"
[[ ! -e "$tmpdir/no-n8n-data/n8n" ]] || {
  echo "pre-start provisioning should not create data/n8n when n8n is absent" >&2
  exit 1
}
DOCKER_PS_HAS_HERMES=1 FIXTURE_N8N_USER="$fixture_uid:$fixture_gid" MS_QR1_DATA_DIR="$fixture_data" "${env_prefix[@]}" scripts/ms-qr1-prestart-provision.sh poststart-refresh > "$tmpdir/poststart-refresh.out"
assert_contains 'up -d --no-deps --force-recreate hermes' "$tmpdir/docker-compose-up.log"
assert_contains 'up -d --no-deps --force-recreate hermes-proxy' "$tmpdir/docker-compose-up.log"
assert_contains 'exec ods-hermes cp /opt/hermes/docker/SOUL.md /opt/data/SOUL.md' "$tmpdir/docker-exec.log"
assert_contains 'restart hermes' "$tmpdir/docker-compose-restart.log"
python3 - "$tmpdir/docker-sequence.log" <<'PY'
from pathlib import Path
import sys

text = Path(sys.argv[1]).read_text()
recreate = text.index("force-recreate hermes")
sync = text.index("cp /opt/hermes/docker/SOUL.md /opt/data/SOUL.md")
restart = text.index("restart hermes")
if not recreate < sync < restart:
    raise SystemExit("Hermes refresh order must be recreate -> sync persistent persona -> restart")
PY
if DOCKER_PS_FAIL=1 FIXTURE_N8N_USER="$fixture_uid:$fixture_gid" MS_QR1_DATA_DIR="$fixture_data" "${env_prefix[@]}" scripts/ms-qr1-prestart-provision.sh poststart-refresh > "$tmpdir/poststart-docker-fail.out" 2> "$tmpdir/poststart-docker-fail.err"; then
  echo "poststart-refresh should fail when docker ps fails" >&2
  exit 1
fi
assert_contains 'fixture docker ps failure' "$tmpdir/poststart-docker-fail.err"
if FIXTURE_N8N_USER="$fixture_uid:$fixture_gid" MS_QR1_DATA_DIR="$fixture_data" "${env_prefix[@]}" scripts/ms-qr1-prestart-provision.sh poststart-refresh > "$tmpdir/poststart-hermes-absent.out" 2> "$tmpdir/poststart-hermes-absent.err"; then
  echo "poststart-refresh should fail when ods-hermes is absent" >&2
  exit 1
fi
assert_contains 'ods-hermes is not running' "$tmpdir/poststart-hermes-absent.err"
if DOCKER_PS_STOPPED_HERMES=1 FIXTURE_N8N_USER="$fixture_uid:$fixture_gid" MS_QR1_DATA_DIR="$fixture_data" "${env_prefix[@]}" scripts/ms-qr1-prestart-provision.sh poststart-refresh > "$tmpdir/poststart-hermes-stopped.out" 2> "$tmpdir/poststart-hermes-stopped.err"; then
  echo "poststart-refresh should fail when ods-hermes is stopped" >&2
  exit 1
fi
assert_contains 'ods-hermes is not running' "$tmpdir/poststart-hermes-stopped.err"
if DOCKER_PS_HAS_HERMES=1 DOCKER_INSPECT_HERMES=unhealthy FIXTURE_N8N_USER="$fixture_uid:$fixture_gid" MS_QR1_DATA_DIR="$fixture_data" "${env_prefix[@]}" scripts/ms-qr1-prestart-provision.sh poststart-refresh > "$tmpdir/poststart-health-unhealthy.out" 2> "$tmpdir/poststart-health-unhealthy.err"; then
  echo "poststart-refresh should fail when Hermes is unhealthy" >&2
  exit 1
fi
assert_contains 'non-healthy state' "$tmpdir/poststart-health-unhealthy.err"
if DOCKER_PS_HAS_HERMES=1 DOCKER_INSPECT_HERMES=exited FIXTURE_N8N_USER="$fixture_uid:$fixture_gid" MS_QR1_DATA_DIR="$fixture_data" "${env_prefix[@]}" scripts/ms-qr1-prestart-provision.sh poststart-refresh > "$tmpdir/poststart-health-exited.out" 2> "$tmpdir/poststart-health-exited.err"; then
  echo "poststart-refresh should fail when Hermes exits" >&2
  exit 1
fi
assert_contains 'non-healthy state' "$tmpdir/poststart-health-exited.err"
if DOCKER_PS_HAS_HERMES=1 DOCKER_INSPECT_HERMES=starting MS_QR1_HERMES_HEALTH_TIMEOUT=0 MS_QR1_HERMES_HEALTH_INTERVAL=0 FIXTURE_N8N_USER="$fixture_uid:$fixture_gid" MS_QR1_DATA_DIR="$fixture_data" "${env_prefix[@]}" scripts/ms-qr1-prestart-provision.sh poststart-refresh > "$tmpdir/poststart-health-timeout.out" 2> "$tmpdir/poststart-health-timeout.err"; then
  echo "poststart-refresh should fail when Hermes health times out" >&2
  exit 1
fi
assert_contains 'timed out waiting for ods-hermes health=healthy' "$tmpdir/poststart-health-timeout.err"
bad_soul_data="$tmpdir/bad-soul-data"
mkdir -p "$bad_soul_data/persona/SOUL.md"
FIXTURE_N8N_USER="$fixture_uid:$fixture_gid" MS_QR1_DATA_DIR="$bad_soul_data" "${env_prefix[@]}" scripts/ms-qr1-prestart-provision.sh prestart-init > "$tmpdir/prestart-bad-soul.out"
[[ -f "$bad_soul_data/persona/SOUL.md" && ! -d "$bad_soul_data/persona/SOUL.md" ]] || {
  echo "prestart-init should repair an empty Docker-created SOUL.md directory behind quiescence" >&2
  exit 1
}
nonempty_soul_data="$tmpdir/nonempty-soul-data"
mkdir -p "$nonempty_soul_data/persona/SOUL.md"
printf 'unexpected nested file\n' > "$nonempty_soul_data/persona/SOUL.md/nested"
if FIXTURE_N8N_USER="$fixture_uid:$fixture_gid" MS_QR1_DATA_DIR="$nonempty_soul_data" "${env_prefix[@]}" scripts/ms-qr1-prestart-provision.sh prestart-init > "$tmpdir/prestart-nonempty-soul.out" 2> "$tmpdir/prestart-nonempty-soul.err"; then
  echo "prestart-init should refuse non-empty SOUL.md directories" >&2
  exit 1
fi
assert_contains 'non-empty directory' "$tmpdir/prestart-nonempty-soul.err"

cat > "$tmpdir/ss-state.txt" <<'EOF'
State  Recv-Q Send-Q Local Address:Port  Peer Address:Port Process
LISTEN 0      4096   127.0.0.1:11434     0.0.0.0:*         users:(("ollama",pid=10,fd=3))
LISTEN 0      4096   172.31.0.1:11434    0.0.0.0:*         users:(("python3",pid=11,fd=3))
LISTEN 0      4096   172.20.0.1:11434    0.0.0.0:*         users:(("python3",pid=12,fd=3))
LISTEN 0      4096   172.31.0.1:7710     0.0.0.0:*         users:(("python3",pid=13,fd=3))
LISTEN 0      4096   127.0.0.1:4000      0.0.0.0:*         users:(("docker-proxy",pid=14,fd=3))
EOF
"${env_prefix[@]}" bash -c 'source scripts/ms-qr1-acceptance.sh; check_live_listeners_loopback_and_bridge_no_wildcard'
expected_tail_addrs="$tmpdir/expected-tail-addrs.txt"
cat > "$expected_tail_addrs" <<'EOF'
100.116.5.69
fd7a:115c:a1e0::a801:5c2
EOF
"${env_prefix[@]}" bash -c 'source scripts/ms-qr1-acceptance.sh; approved_tailscale_serve_11434_addrs' > "$tmpdir/approved-tail-addrs.out"
if ! diff -u "$expected_tail_addrs" "$tmpdir/approved-tail-addrs.out"; then
  echo "Tailscale Serve parser should approve only assigned EVO-X3 tailnet IPs from the live tree output" >&2
  exit 1
fi
assert_not_contains 'evox3.tailfc79e6.ts.net' "$tmpdir/approved-tail-addrs.out"
cat > "$tmpdir/ss-state.txt" <<'EOF'
State  Recv-Q Send-Q Local Address:Port                   Peer Address:Port Process
LISTEN 0      4096   127.0.0.1:11434                      0.0.0.0:*         users:(("ollama",pid=10,fd=3))
LISTEN 0      4096   172.31.0.1:11434                     0.0.0.0:*         users:(("python3",pid=11,fd=3))
LISTEN 0      4096   172.20.0.1:11434                     0.0.0.0:*         users:(("python3",pid=12,fd=3))
LISTEN 0      4096   100.116.5.69:11434                   0.0.0.0:*         users:(("tailscaled",pid=15,fd=3))
LISTEN 0      4096   [fd7a:115c:a1e0::a801:5c2]:11434     [::]:*            users:(("tailscaled",pid=16,fd=3))
LISTEN 0      4096   127.0.0.1:4000                       0.0.0.0:*         users:(("docker-proxy",pid=14,fd=3))
EOF
"${env_prefix[@]}" bash -c 'source scripts/ms-qr1-acceptance.sh; check_live_listeners_loopback_and_bridge_no_wildcard'
cat > "$tmpdir/ss-state.txt" <<'EOF'
State  Recv-Q Send-Q Local Address:Port                   Peer Address:Port Process
LISTEN 0      4096   127.0.0.1:11434                      0.0.0.0:*         users:(("ollama",pid=10,fd=3))
LISTEN 0      4096   172.31.0.1:11434                     0.0.0.0:*         users:(("python3",pid=11,fd=3))
LISTEN 0      4096   172.20.0.1:11434                     0.0.0.0:*         users:(("python3",pid=12,fd=3))
LISTEN 0      4096   100.116.5.69:11434                   0.0.0.0:*         users:(("tailscaled",pid=15,fd=3))
EOF
cat > "$tmpdir/tailscale-serve-status.txt" <<'EOF'
|-- tcp://100.116.5.69:11434
|--> tcp://127.0.0.1:11434
EOF
"${env_prefix[@]}" bash -c 'source scripts/ms-qr1-acceptance.sh; check_live_listeners_loopback_and_bridge_no_wildcard'
cat > "$tmpdir/ss-state.txt" <<'EOF'
State  Recv-Q Send-Q Local Address:Port                   Peer Address:Port Process
LISTEN 0      4096   127.0.0.1:11434                      0.0.0.0:*         users:(("ollama",pid=10,fd=3))
LISTEN 0      4096   172.31.0.1:11434                     0.0.0.0:*         users:(("python3",pid=11,fd=3))
LISTEN 0      4096   172.20.0.1:11434                     0.0.0.0:*         users:(("python3",pid=12,fd=3))
LISTEN 0      4096   [fd7a:115c:a1e0::a801:5c2]:11434     [::]:*            users:(("tailscaled",pid=16,fd=3))
EOF
cat > "$tmpdir/tailscale-serve-status.txt" <<'EOF'
|-- tcp://[fd7a:115c:a1e0::a801:5c2]:11434
|--> tcp://127.0.0.1:11434
EOF
"${env_prefix[@]}" bash -c 'source scripts/ms-qr1-acceptance.sh; check_live_listeners_loopback_and_bridge_no_wildcard'
cat > "$tmpdir/ss-state.txt" <<'EOF'
State  Recv-Q Send-Q Local Address:Port                   Peer Address:Port Process
LISTEN 0      4096   127.0.0.1:11434                      0.0.0.0:*         users:(("ollama",pid=10,fd=3))
LISTEN 0      4096   172.31.0.1:11434                     0.0.0.0:*         users:(("python3",pid=11,fd=3))
LISTEN 0      4096   172.20.0.1:11434                     0.0.0.0:*         users:(("python3",pid=12,fd=3))
LISTEN 0      4096   100.116.5.69:11434                   0.0.0.0:*         users:(("tailscaled",pid=15,fd=3))
EOF
cat > "$tmpdir/tailscale-serve-status.txt" <<'EOF'
|-- https://evox3.tailfc79e6.ts.net:443
|--> http://127.0.0.1:3001
|-- tcp://evox3.tailfc79e6.ts.net:11434 (tailnet only)
|-- tcp://100.116.5.69:11434
|-- tcp://[fd7a:115c:a1e0::a801:5c2]:11434
|--> tcp://127.0.0.1:11434
EOF
"${env_prefix[@]}" bash -c 'source scripts/ms-qr1-acceptance.sh; check_live_listeners_loopback_and_bridge_no_wildcard'
cat > "$tmpdir/tailscale-serve-status.txt" <<'EOF'
tcp://evox3.tailfc79e6.ts.net:443 (tailnet only)
--> tcp://127.0.0.1:3001
EOF
if "${env_prefix[@]}" bash -c 'source scripts/ms-qr1-acceptance.sh; check_live_listeners_loopback_and_bridge_no_wildcard' > "$tmpdir/ss-tail-no-serve.out" 2> "$tmpdir/ss-tail-no-serve.err"; then
  echo "listener acceptance should fail when Tailscale IP lacks approved Serve 11434 mapping" >&2
  exit 1
fi
assert_contains 'non-gateway QR1 Ollama bridge bind' "$tmpdir/ss-tail-no-serve.out"
cat > "$tmpdir/tailscale-serve-status.txt" <<'EOF'
|-- https://evox3.tailfc79e6.ts.net:443
|--> http://127.0.0.1:3001
EOF
if "${env_prefix[@]}" bash -c 'source scripts/ms-qr1-acceptance.sh; check_live_listeners_loopback_and_bridge_no_wildcard' > "$tmpdir/ss-tail-https-only.out" 2> "$tmpdir/ss-tail-https-only.err"; then
  echo "listener acceptance should not exempt Ollama listeners for HTTPS-only Tailscale Serve output" >&2
  exit 1
fi
assert_contains 'non-gateway QR1 Ollama bridge bind' "$tmpdir/ss-tail-https-only.out"
cat > "$tmpdir/tailscale-serve-status.txt" <<'EOF'
tcp://100.116.5.69:11434
--> tcp://127.0.0.1:3001
tcp://[fd7a:115c:a1e0::a801:5c2]:11434
--> tcp://127.0.0.1:3001
EOF
if "${env_prefix[@]}" bash -c 'source scripts/ms-qr1-acceptance.sh; check_live_listeners_loopback_and_bridge_no_wildcard' > "$tmpdir/ss-tail-wrong-target.out" 2> "$tmpdir/ss-tail-wrong-target.err"; then
  echo "listener acceptance should fail when Tailscale Serve 11434 does not forward to Ollama loopback" >&2
  exit 1
fi
assert_contains 'non-gateway QR1 Ollama bridge bind' "$tmpdir/ss-tail-wrong-target.out"
cat > "$tmpdir/ss-state.txt" <<'EOF'
State  Recv-Q Send-Q Local Address:Port                   Peer Address:Port Process
LISTEN 0      4096   127.0.0.1:11434                      0.0.0.0:*         users:(("ollama",pid=10,fd=3))
LISTEN 0      4096   172.31.0.1:11434                     0.0.0.0:*         users:(("python3",pid=11,fd=3))
LISTEN 0      4096   172.20.0.1:11434                     0.0.0.0:*         users:(("python3",pid=12,fd=3))
LISTEN 0      4096   100.116.5.69:11434                   0.0.0.0:*         users:(("tailscaled",pid=15,fd=3))
EOF
cat > "$tmpdir/tailscale-serve-status.txt" <<'EOF'
tcp://100.116.5.69:11434
--> tcp://127.0.0.1:3001
tcp://100.116.5.69:443
--> tcp://127.0.0.1:11434
EOF
if "${env_prefix[@]}" bash -c 'source scripts/ms-qr1-acceptance.sh; check_live_listeners_loopback_and_bridge_no_wildcard' > "$tmpdir/ss-tail-nearby-target.out" 2> "$tmpdir/ss-tail-nearby-target.err"; then
  echo "listener acceptance should fail when only a nearby different Serve mapping targets Ollama loopback" >&2
  exit 1
fi
assert_contains 'non-gateway QR1 Ollama bridge bind' "$tmpdir/ss-tail-nearby-target.out"
cat > "$tmpdir/tailscale-serve-status.txt" <<'EOF'
https://evox3.tailfc79e6.ts.net:443
tcp://100.116.5.69:11434
--> tcp://127.0.0.1:11434
EOF
if "${env_prefix[@]}" bash -c 'source scripts/ms-qr1-acceptance.sh; check_live_listeners_loopback_and_bridge_no_wildcard' > "$tmpdir/ss-tail-incomplete-mixed.out" 2> "$tmpdir/ss-tail-incomplete-mixed.err"; then
  echo "listener acceptance should fail when an incomplete HTTPS source is mixed with a TCP Ollama source before a target" >&2
  exit 1
fi
assert_contains 'non-gateway QR1 Ollama bridge bind' "$tmpdir/ss-tail-incomplete-mixed.out"
cat > "$tmpdir/tailscale-serve-status.txt" <<'EOF'
tcp://100.116.5.69:11434
tcp://100.116.5.69:443
--> tcp://127.0.0.1:11434
EOF
if "${env_prefix[@]}" bash -c 'source scripts/ms-qr1-acceptance.sh; check_live_listeners_loopback_and_bridge_no_wildcard' > "$tmpdir/ss-tail-mixed-source-family.out" 2> "$tmpdir/ss-tail-mixed-source-family.err"; then
  echo "listener acceptance should fail when one source group mixes unrelated TCP ports" >&2
  exit 1
fi
assert_contains 'non-gateway QR1 Ollama bridge bind' "$tmpdir/ss-tail-mixed-source-family.out"
cat > "$tmpdir/tailscale-serve-status.txt" <<'EOF'
tcp://100.116.5.69:11434
--> tcp://127.0.0.1:11434
tcp://100.116.5.69:11434
--> tcp://127.0.0.1:11434
EOF
if "${env_prefix[@]}" bash -c 'source scripts/ms-qr1-acceptance.sh; check_live_listeners_loopback_and_bridge_no_wildcard' > "$tmpdir/ss-tail-duplicate.out" 2> "$tmpdir/ss-tail-duplicate.err"; then
  echo "listener acceptance should fail on duplicate ambiguous Tailscale Serve 11434 mappings" >&2
  exit 1
fi
assert_contains 'non-gateway QR1 Ollama bridge bind' "$tmpdir/ss-tail-duplicate.out"
cat > "$tmpdir/tailscale-serve-status.txt" <<'EOF'
tcp://100.116.5.69:11434
this is not a serve target line
EOF
if "${env_prefix[@]}" bash -c 'source scripts/ms-qr1-acceptance.sh; check_live_listeners_loopback_and_bridge_no_wildcard' > "$tmpdir/ss-tail-malformed.out" 2> "$tmpdir/ss-tail-malformed.err"; then
  echo "listener acceptance should fail closed on malformed Tailscale Serve output" >&2
  exit 1
fi
assert_contains 'non-gateway QR1 Ollama bridge bind' "$tmpdir/ss-tail-malformed.out"
cat > "$tmpdir/tailscale-serve-status.txt" <<'EOF'
ftp://100.116.5.69:11434
--> tcp://127.0.0.1:11434
tcp://100.116.5.69:11434
--> tcp://127.0.0.1:11434
EOF
if "${env_prefix[@]}" bash -c 'source scripts/ms-qr1-acceptance.sh; check_live_listeners_loopback_and_bridge_no_wildcard' > "$tmpdir/ss-tail-malformed-mixed.out" 2> "$tmpdir/ss-tail-malformed-mixed.err"; then
  echo "listener acceptance should fail closed on malformed Serve blocks even when a valid TCP mapping is also present" >&2
  exit 1
fi
assert_contains 'non-gateway QR1 Ollama bridge bind' "$tmpdir/ss-tail-malformed-mixed.out"
cat > "$tmpdir/tailscale-serve-status.txt" <<'EOF'
|-- tcp://evox3.tailfc79e6.ts.net:11434 (tailnet only)
|-- tcp://100.116.5.69:11434
|-- tcp://[fd7a:115c:a1e0::a801:5c2]:11434
|--> tcp://127.0.0.1:11434
EOF
cat > "$tmpdir/ss-state.txt" <<'EOF'
State  Recv-Q Send-Q Local Address:Port  Peer Address:Port Process
LISTEN 0      4096   0.0.0.0:11434      0.0.0.0:*         users:(("python3",pid=17,fd=3))
EOF
if "${env_prefix[@]}" bash -c 'source scripts/ms-qr1-acceptance.sh; check_live_listeners_loopback_and_bridge_no_wildcard' > "$tmpdir/ss-wildcard.out" 2> "$tmpdir/ss-wildcard.err"; then
  echo "listener acceptance should fail on wildcard Ollama bridge binds" >&2
  exit 1
fi
assert_contains 'wildcard QR1 bridge bind' "$tmpdir/ss-wildcard.out"
if SS_FAIL=1 "${env_prefix[@]}" bash -c 'source scripts/ms-qr1-acceptance.sh; check_live_listeners_loopback_and_bridge_no_wildcard' > "$tmpdir/ss-fail.out" 2> "$tmpdir/ss-fail.err"; then
  echo "listener acceptance should fail when ss fails" >&2
  exit 1
fi
assert_contains 'ss listener snapshot failed' "$tmpdir/ss-fail.err"
cat > "$tmpdir/ss-state.txt" <<'EOF'
State  Recv-Q Send-Q Local Address:Port  Peer Address:Port Process
LISTEN 0      4096   127.0.0.1:11434     0.0.0.0:*         users:(("ollama",pid=10,fd=3))
LISTEN 0      4096   192.168.50.1:11434  0.0.0.0:*         users:(("python3",pid=11,fd=3))
EOF
if "${env_prefix[@]}" bash -c 'source scripts/ms-qr1-acceptance.sh; check_live_listeners_loopback_and_bridge_no_wildcard' > "$tmpdir/ss-bad.out" 2> "$tmpdir/ss-bad.err"; then
  echo "listener acceptance should fail on non-gateway Ollama bridge binds" >&2
  exit 1
fi
assert_contains 'non-gateway QR1 Ollama bridge bind' "$tmpdir/ss-bad.out"

cat > "$tmpdir/curl" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
if [[ "$*" == *" -D - "* || "$*" == *"-D -"* ]]; then
  if [[ "${CURL_REQUIRE_Q:-0}" == "1" && "$*" != *"-q"* ]]; then
    echo "curl fixture expected -q" >&2
    exit 61
  fi
  case "${CURL_MODE:-401}" in
    303-auth) printf 'HTTP/1.1 303 See Other\r\nLocation: /auth/required\r\n\r\nHTTP_STATUS:303' ;;
    303-auth-lower) printf 'HTTP/1.1 303 See Other\r\nlocation: /auth/required\r\n\r\nHTTP_STATUS:303' ;;
    303-auth-mixed) printf 'HTTP/1.1 303 See Other\r\nLoCaTiOn: /auth/required\r\n\r\nHTTP_STATUS:303' ;;
    103-location-303-missing) printf 'HTTP/1.1 103 Early Hints\r\nLocation: /auth/required\r\n\r\nHTTP/1.1 303 See Other\r\n\r\nHTTP_STATUS:303' ;;
    103-303-auth) printf 'HTTP/1.1 103 Early Hints\r\nLink: </auth/required>; rel=preload\r\n\r\nHTTP/1.1 303 See Other\r\nLocation: /auth/required\r\n\r\nHTTP_STATUS:303' ;;
    303-duplicate-identical) printf 'HTTP/1.1 303 See Other\r\nLocation: /auth/required\r\nLocation: /auth/required\r\n\r\nHTTP_STATUS:303' ;;
    303-duplicate-identical-case) printf 'HTTP/1.1 303 See Other\r\nLocation: /auth/required\r\nlocation: /auth/required\r\n\r\nHTTP_STATUS:303' ;;
    303-duplicate-conflicting) printf 'HTTP/1.1 303 See Other\r\nLocation: /auth/required\r\nLocation: /anything-else\r\n\r\nHTTP_STATUS:303' ;;
    303-duplicate-conflicting-case) printf 'HTTP/1.1 303 See Other\r\nLocation: /auth/required\r\nlocation: /evil\r\n\r\nHTTP_STATUS:303' ;;
    303-other) printf 'HTTP/1.1 303 See Other\r\nLocation: /anything-else\r\n\r\nHTTP_STATUS:303' ;;
    303-missing) printf 'HTTP/1.1 303 See Other\r\n\r\nHTTP_STATUS:303' ;;
    303-query) printf 'HTTP/1.1 303 See Other\r\nLocation: /auth/required?x=1\r\n\r\nHTTP_STATUS:303' ;;
    303-absolute) printf 'HTTP/1.1 303 See Other\r\nLocation: https://example.invalid/auth/required\r\n\r\nHTTP_STATUS:303' ;;
    401) printf 'HTTP/1.1 401 Unauthorized\r\n\r\nHTTP_STATUS:401' ;;
    403) printf 'HTTP/1.1 403 Forbidden\r\n\r\nHTTP_STATUS:403' ;;
    404) printf 'HTTP/1.1 404 Not Found\r\n\r\nHTTP_STATUS:404' ;;
    200) printf 'HTTP/1.1 200 OK\r\n\r\nHTTP_STATUS:200' ;;
    transport) exit 7 ;;
    *) printf 'HTTP/1.1 %s Fixture\r\n\r\nHTTP_STATUS:%s' "$CURL_MODE" "$CURL_MODE" ;;
  esac
  exit 0
fi
case "${CURL_MODE:-401}" in
  401) printf '401' ;;
  403) printf '403' ;;
  404) printf '404' ;;
  transport) exit 7 ;;
  *) printf '%s' "$CURL_MODE" ;;
esac
SH
chmod +x "$tmpdir/curl"
cat > "$tmpdir/ss-state.txt" <<'EOF'
State  Recv-Q Send-Q Local Address:Port  Peer Address:Port Process
LISTEN 0      4096   127.0.0.1:9120      0.0.0.0:*         users:(("docker-proxy",pid=18,fd=3))
EOF
CURL_MODE=303-auth "${env_prefix[@]}" bash -c 'source scripts/ms-qr1-acceptance.sh; check_hermes_tui'
CURL_MODE=303-auth-lower "${env_prefix[@]}" bash -c 'source scripts/ms-qr1-acceptance.sh; check_hermes_tui'
CURL_MODE=303-auth-mixed "${env_prefix[@]}" bash -c 'source scripts/ms-qr1-acceptance.sh; check_hermes_tui'
CURL_MODE=103-303-auth "${env_prefix[@]}" bash -c 'source scripts/ms-qr1-acceptance.sh; check_hermes_tui'
CURL_MODE=303-auth CURL_REQUIRE_Q=1 "${env_prefix[@]}" bash -c 'mkdir -p "$FIXTURE_DIR/home-with-curlrc"; printf "location\n" > "$FIXTURE_DIR/home-with-curlrc/.curlrc"; export HOME="$FIXTURE_DIR/home-with-curlrc"; source scripts/ms-qr1-acceptance.sh; check_hermes_tui'
CURL_MODE=401 "${env_prefix[@]}" bash -c 'source scripts/ms-qr1-acceptance.sh; check_hermes_tui'
CURL_MODE=403 "${env_prefix[@]}" bash -c 'source scripts/ms-qr1-acceptance.sh; check_hermes_tui'
CURL_MODE=404 "${env_prefix[@]}" bash -c 'source scripts/ms-qr1-acceptance.sh; check_hermes_tui'
if CURL_MODE=303-other "${env_prefix[@]}" bash -c 'source scripts/ms-qr1-acceptance.sh; check_hermes_tui' > "$tmpdir/hermes-redirect-bad.out" 2> "$tmpdir/hermes-redirect-bad.err"; then
  echo "Hermes TUI acceptance should fail on arbitrary 303 redirects" >&2
  exit 1
fi
assert_contains 'unexpected HTTP redirect' "$tmpdir/hermes-redirect-bad.err"
if CURL_MODE=303-duplicate-identical "${env_prefix[@]}" bash -c 'source scripts/ms-qr1-acceptance.sh; check_hermes_tui' > "$tmpdir/hermes-redirect-duplicate-identical.out" 2> "$tmpdir/hermes-redirect-duplicate-identical.err"; then
  echo "Hermes TUI acceptance should fail on duplicate identical Location headers" >&2
  exit 1
fi
assert_contains 'unexpected HTTP redirect' "$tmpdir/hermes-redirect-duplicate-identical.err"
if CURL_MODE=303-duplicate-identical-case "${env_prefix[@]}" bash -c 'source scripts/ms-qr1-acceptance.sh; check_hermes_tui' > "$tmpdir/hermes-redirect-duplicate-identical-case.out" 2> "$tmpdir/hermes-redirect-duplicate-identical-case.err"; then
  echo "Hermes TUI acceptance should fail on duplicate same-value Location headers with different casing" >&2
  exit 1
fi
assert_contains 'unexpected HTTP redirect' "$tmpdir/hermes-redirect-duplicate-identical-case.err"
if CURL_MODE=303-duplicate-conflicting "${env_prefix[@]}" bash -c 'source scripts/ms-qr1-acceptance.sh; check_hermes_tui' > "$tmpdir/hermes-redirect-duplicate-conflicting.out" 2> "$tmpdir/hermes-redirect-duplicate-conflicting.err"; then
  echo "Hermes TUI acceptance should fail on duplicate conflicting Location headers" >&2
  exit 1
fi
assert_contains 'unexpected HTTP redirect' "$tmpdir/hermes-redirect-duplicate-conflicting.err"
if CURL_MODE=303-duplicate-conflicting-case "${env_prefix[@]}" bash -c 'source scripts/ms-qr1-acceptance.sh; check_hermes_tui' > "$tmpdir/hermes-redirect-duplicate-conflicting-case.out" 2> "$tmpdir/hermes-redirect-duplicate-conflicting-case.err"; then
  echo "Hermes TUI acceptance should fail on conflicting Location headers with different casing" >&2
  exit 1
fi
assert_contains 'unexpected HTTP redirect' "$tmpdir/hermes-redirect-duplicate-conflicting-case.err"
if CURL_MODE=303-missing "${env_prefix[@]}" bash -c 'source scripts/ms-qr1-acceptance.sh; check_hermes_tui' > "$tmpdir/hermes-redirect-missing.out" 2> "$tmpdir/hermes-redirect-missing.err"; then
  echo "Hermes TUI acceptance should fail when 303 has no Location header" >&2
  exit 1
fi
assert_contains 'unexpected HTTP redirect' "$tmpdir/hermes-redirect-missing.err"
if CURL_MODE=103-location-303-missing "${env_prefix[@]}" bash -c 'source scripts/ms-qr1-acceptance.sh; check_hermes_tui' > "$tmpdir/hermes-103-location-final-missing.out" 2> "$tmpdir/hermes-103-location-final-missing.err"; then
  echo "Hermes TUI acceptance should fail when Location appears only in an interim 103 response" >&2
  exit 1
fi
assert_contains 'unexpected HTTP redirect' "$tmpdir/hermes-103-location-final-missing.err"
if CURL_MODE=303-query "${env_prefix[@]}" bash -c 'source scripts/ms-qr1-acceptance.sh; check_hermes_tui' > "$tmpdir/hermes-redirect-query.out" 2> "$tmpdir/hermes-redirect-query.err"; then
  echo "Hermes TUI acceptance should fail when auth redirect includes a query string" >&2
  exit 1
fi
assert_contains 'unexpected HTTP redirect' "$tmpdir/hermes-redirect-query.err"
if CURL_MODE=303-absolute "${env_prefix[@]}" bash -c 'source scripts/ms-qr1-acceptance.sh; check_hermes_tui' > "$tmpdir/hermes-redirect-absolute.out" 2> "$tmpdir/hermes-redirect-absolute.err"; then
  echo "Hermes TUI acceptance should fail on absolute URL redirects" >&2
  exit 1
fi
assert_contains 'unexpected HTTP redirect' "$tmpdir/hermes-redirect-absolute.err"
if CURL_MODE=200 "${env_prefix[@]}" bash -c 'source scripts/ms-qr1-acceptance.sh; check_hermes_tui' > "$tmpdir/hermes-200.out" 2> "$tmpdir/hermes-200.err"; then
  echo "Hermes TUI acceptance should fail when unauthenticated PTY returns 200" >&2
  exit 1
fi
assert_contains 'unexpected HTTP status' "$tmpdir/hermes-200.err"
cat > "$tmpdir/ss-state.txt" <<'EOF'
State  Recv-Q Send-Q Local Address:Port  Peer Address:Port Process
LISTEN 0      4096   127.0.0.1:9119      0.0.0.0:*         users:(("docker-proxy",pid=19,fd=3))
EOF
if CURL_MODE=303-auth "${env_prefix[@]}" bash -c 'source scripts/ms-qr1-acceptance.sh; check_hermes_tui' > "$tmpdir/hermes-9119.out" 2> "$tmpdir/hermes-9119.err"; then
  echo "Hermes TUI acceptance should fail when host 9119 is bound" >&2
  exit 1
fi
assert_contains 'host port 9119 is bound' "$tmpdir/hermes-9119.err"
CURL_MODE=401 "${env_prefix[@]}" bash -c 'source scripts/ms-qr1-acceptance.sh; expect_http_status http://example.invalid 401 403'
CURL_MODE=403 "${env_prefix[@]}" bash -c 'source scripts/ms-qr1-acceptance.sh; expect_http_status http://example.invalid 401 403'
CURL_MODE=404 "${env_prefix[@]}" bash -c 'source scripts/ms-qr1-acceptance.sh; expect_http_status http://example.invalid 401 403 404'
if CURL_MODE=transport "${env_prefix[@]}" bash -c 'source scripts/ms-qr1-acceptance.sh; expect_http_status http://example.invalid 401 403' > "$tmpdir/http-transport.out" 2> "$tmpdir/http-transport.err"; then
  echo "HTTP status helper should fail on transport errors" >&2
  exit 1
fi

for f in \
  scripts/ods-verify-quiescent-data-writers.sh \
  scripts/ms-qr1-compose-flags.sh \
  scripts/ms-qr1-ufw-docker-rules.sh \
  scripts/ms-qr1-prestart-provision.sh \
  scripts/ms-qr1-ollama-bridge.sh \
  scripts/ms-qr1-acceptance.sh \
  extensions/services/langfuse/hooks/post_install.sh \
  lib/rootless-ownership.sh; do
  bash -n "$f"
done
PYTHONPYCACHEPREFIX="$tmpdir/pycache" python3 -m py_compile scripts/ms-qr1-ollama-http-proxy.py

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
assert_contains 'check_prestart_provisioning' scripts/ms-qr1-acceptance.sh
assert_contains 'check_live_listeners_loopback_and_bridge_no_wildcard' scripts/ms-qr1-acceptance.sh
assert_contains 'scripts/ms-qr1-ollama-bridge.sh expected-listeners' scripts/ms-qr1-acceptance.sh
assert_contains 'non-gateway QR1 Ollama bridge bind' scripts/ms-qr1-acceptance.sh
assert_contains 'services=("litellm" "${services[@]}")' scripts/ms-qr1-acceptance.sh
assert_contains 'SDXL_REVISION=c6c10e8716de60c7ef4eed6b89a06f67e772b374' ../docs/ms/deploy/QR1-DEPLOY-RUNBOOK.md
assert_contains 'SDXL_SHA256=e0d996ee0013e79d9d3561f50fcafb9a17e3ff07b780358e3b66d67932c4d490' ../docs/ms/deploy/QR1-DEPLOY-RUNBOOK.md
assert_contains 'sha256sum -c -' ../docs/ms/deploy/QR1-DEPLOY-RUNBOOK.md
assert_contains 'docker compose $(scripts/ms-qr1-compose-flags.sh) up -d --build --no-start' ../docs/ms/deploy/QR1-DEPLOY-RUNBOOK.md
assert_contains 'scripts/ms-qr1-prestart-provision.sh prestart-init' ../docs/ms/deploy/QR1-DEPLOY-RUNBOOK.md
assert_contains 'sudo scripts/ms-qr1-prestart-provision.sh prestart-init' ../docs/ms/deploy/QR1-DEPLOY-RUNBOOK.md
assert_contains 'scripts/ms-qr1-prestart-provision.sh writer-services' ../docs/ms/deploy/QR1-DEPLOY-RUNBOOK.md
assert_contains 'scripts/ms-qr1-prestart-provision.sh verify-quiescent' ../docs/ms/deploy/QR1-DEPLOY-RUNBOOK.md
assert_contains 'scripts/ms-qr1-prestart-provision.sh poststart-refresh' ../docs/ms/deploy/QR1-DEPLOY-RUNBOOK.md
assert_contains 'docs/ms/decisions/QR1-QUIESCENT-PRIVILEGED-PROVISIONING.md' ../docs/ms/deploy/QR1-DEPLOY-RUNBOOK.md
assert_contains 'ods-verify-quiescent-data-writers.sh verify' scripts/ms-qr1-prestart-provision.sh
assert_contains 'ODS_QUIESCENCE_DATA_DIR="$DATA_DIR"' scripts/ms-qr1-prestart-provision.sh
assert_not_contains 'ods-verify-quiescent-data-writers.sh' extensions/services/langfuse/hooks/post_install.sh
assert_not_contains 'ms-qr1-prestart-provision.sh' extensions/services/langfuse/hooks/post_install.sh
assert_not_contains 'Langfuse ownership repair requires quiescent data/langfuse writer containers' extensions/services/langfuse/hooks/post_install.sh
assert_not_contains 'ods-verify-quiescent-data-writers.sh' lib/rootless-ownership.sh
assert_contains 'Generic ODS Privileged Persistent-State Lifecycle Hardening' ../docs/ms/backlog/GENERIC-ODS-LIFECYCLE-HARDENING.md
assert_contains 'mktemp "$PERSONA_DIR/.SOUL.md.tmp.XXXXXX"' scripts/ms-qr1-prestart-provision.sh
assert_not_contains '127.0.0.1:9119/api/status' scripts/ms-qr1-prestart-provision.sh
assert_not_contains '127.0.0.1:9119/api/status' ../docs/ms/deploy/QR1-DEPLOY-RUNBOOK.md
assert_not_contains 'stop n8n hermes hermes-proxy dashboard-api || true' ../docs/ms/deploy/QR1-DEPLOY-RUNBOOK.md
assert_not_contains 'sudo rm -rf data/langfuse/postgres data/langfuse/clickhouse' ../docs/ms/deploy/QR1-DEPLOY-RUNBOOK.md
assert_not_contains 'remove that directory and rerun' ../docs/ms/ODS-MS-CHANGELOG.md
assert_not_contains 'chown -R 1000:1000 ods/data/n8n' extensions/services/n8n/README.md
assert_not_contains 'remove `data/langfuse/postgres/`' extensions/services/langfuse/README.md
assert_contains 'Runtime acceptance checks' ../AGENTS.md
assert_contains 'up -d --no-deps --force-recreate hermes' ../docs/ms/deploy/QR1-DEPLOY-RUNBOOK.md
assert_contains 'docker compose $(scripts/ms-qr1-compose-flags.sh) up -d --build --force-recreate' ../docs/ms/deploy/QR1-DEPLOY-RUNBOOK.md
assert_not_contains 'docker network create ods-network' ../docs/ms/deploy/QR1-DEPLOY-RUNBOOK.md
assert_contains 'sudo systemctl restart ods-host-agent.service' ../docs/ms/deploy/QR1-DEPLOY-RUNBOOK.md
assert_contains 'sudo apt-get install -y python3-yaml jq curl' ../docs/ms/deploy/QR1-DEPLOY-RUNBOOK.md
assert_contains 'jq --version' ../docs/ms/deploy/QR1-DEPLOY-RUNBOOK.md
assert_contains 'curl --version' ../docs/ms/deploy/QR1-DEPLOY-RUNBOOK.md
assert_contains 'jq is required for schema validation' scripts/validate-env.sh
assert_contains "^[A-Za-z_][A-Za-z0-9_]*=.*(CHANGEME|GENERATE_ME)" ../docs/ms/deploy/QR1-DEPLOY-RUNBOOK.md
assert_not_contains 'sudo "$@"' scripts/ms-qr1-prestart-provision.sh
assert_not_contains 'run_privileged' scripts/ms-qr1-prestart-provision.sh
python3 - <<'PY'
from pathlib import Path

text = Path("../docs/ms/deploy/QR1-DEPLOY-RUNBOOK.md").read_text()
prestart = text.index("scripts/ms-qr1-prestart-provision.sh")
network_create = text.index("up -d --build --no-start")
if not prestart < network_create:
    raise SystemExit("QR1 pre-start provisioning must be documented before Compose --no-start")
writer_services = text.index("writer-services")
compose_stop = text.index(" stop $QR1_WRITER_SERVICES")
verify = text.index("verify-quiescent")
langfuse_hook = text.index("extensions/services/langfuse/hooks/post_install.sh")
prestart_init = text.index("prestart-init")
if not writer_services < compose_stop < verify < langfuse_hook < prestart_init:
    raise SystemExit("QR1 runbook must stop and verify writers before privileged data hooks")
PY

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
python3 - profiles/ms-qr1.env.example "$qr1_env" "$tmpdir/restored-placeholder.env" <<'PY'
from pathlib import Path
import re
import sys
profile_path = Path(sys.argv[1])
filled_path = Path(sys.argv[2])
restored_path = Path(sys.argv[3])
token_re = re.compile(r"(?:CHANGEME|GENERATE_ME)[A-Za-z0-9_]*")
assign_re = re.compile(r"^[A-Za-z_][A-Za-z0-9_]*=.*$")

def fill_value(token: str) -> str:
    if token == "GENERATE_ME_DOCKER_GATEWAY":
        return "172.31.0.1"
    if token == "GENERATE_ME_HEX_32_DISTINCT_FROM_DASHBOARD_API_KEY":
        return "22222222222222222222222222222222"
    if token == "GENERATE_ME_SK_ODS_HEX_32":
        return "qr1-litellm-dummy-key"
    if token == "GENERATE_ME_FROM_BITWARDEN":
        return "from-bitwarden-dummy"
    if token == "GENERATE_ME_UNUSED_QR1":
        return "unused-qr1-dummy"
    if token.startswith("GENERATE_ME_HEX_"):
        return "1" * int(token.rsplit("_", 1)[1])
    if token.startswith("GENERATE_ME_BASE64_"):
        return "A" * int(token.rsplit("_", 1)[1])
    if token == "GENERATE_ME_BASE64URL_32":
        return "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA"
    if token == "GENERATE_ME_LANGFUSE_INIT_ORG_ID":
        return "qr1-org"
    if token == "GENERATE_ME_LANGFUSE_INIT_PROJECT_ID":
        return "qr1-project"
    raise SystemExit(f"unknown QR1 placeholder token in assignment value: {token}")

lines = profile_path.read_text().splitlines()
tokens = []
for line in lines:
    if assign_re.match(line):
        tokens.extend(token_re.findall(line.split("=", 1)[1]))
if not tokens:
    raise SystemExit("expected QR1 profile to contain assignment-value placeholders")

filled_lines = []
restored = False
for line in lines:
    if assign_re.match(line):
        key, value = line.split("=", 1)
        for token in token_re.findall(value):
            value = value.replace(token, fill_value(token))
        if not restored and token_re.search(line.split("=", 1)[1]):
            restored_value = value.replace(fill_value(token_re.search(line.split("=", 1)[1]).group(0)), token_re.search(line.split("=", 1)[1]).group(0), 1)
            restored_line = f"{key}={restored_value}"
            restored = True
        filled_lines.append(f"{key}={value}")
    else:
        filled_lines.append(line)
if not restored:
    raise SystemExit("failed to prepare restored-placeholder QR1 fixture")
filled_path.write_text("\n".join(filled_lines) + "\n")
restored_lines = list(filled_lines)
for index, line in enumerate(lines):
    if assign_re.match(line) and token_re.search(line.split("=", 1)[1]):
        restored_lines[index] = restored_line
        break
restored_path.write_text("\n".join(restored_lines) + "\n")
PY
bash scripts/validate-env.sh "$qr1_env" > "$tmpdir/validate-env.out"
ENV_FILE="$qr1_env" bash -c 'source scripts/ms-qr1-acceptance.sh; check_no_placeholders'
if ENV_FILE="$tmpdir/restored-placeholder.env" bash -c 'source scripts/ms-qr1-acceptance.sh; check_no_placeholders' > "$tmpdir/restored-placeholder.out" 2> "$tmpdir/restored-placeholder.err"; then
  echo "check_no_placeholders should fail when one assignment-value placeholder remains" >&2
  exit 1
fi

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

cmp -s "$bridge_script_original" "$bridge_script" || {
  echo "bridge script differs from its pre-test bytes" >&2
  exit 1
}

echo "MS QR1 helper tests passed"
