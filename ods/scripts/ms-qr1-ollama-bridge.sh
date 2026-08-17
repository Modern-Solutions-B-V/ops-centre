#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'USAGE'
Usage:
  scripts/ms-qr1-ollama-bridge.sh plan
  scripts/ms-qr1-ollama-bridge.sh expected-listeners
  scripts/ms-qr1-ollama-bridge.sh render-unit
  scripts/ms-qr1-ollama-bridge.sh install
  scripts/ms-qr1-ollama-bridge.sh remove
  scripts/ms-qr1-ollama-bridge.sh serve
  scripts/ms-qr1-ollama-bridge.sh status

Installs a narrow host-side bridge for QR1 containers:
  non-internal ODS Docker gateway IP(s):11434 -> 127.0.0.1:11434

It does not change Ollama's listener, never binds to 0.0.0.0, and rewrites the
upstream HTTP Host header to localhost:11434. Run from the ods/ directory after
QR1 Docker networks exist.
USAGE
}

ACTION="${1:-plan}"
case "$ACTION" in
  plan|expected-listeners|render-unit|install|remove|serve|status) ;;
  *) usage >&2; exit 2 ;;
esac

SERVICE_NAME="ms-qr1-ollama-bridge.service"
UNIT_PATH="${MS_QR1_OLLAMA_UNIT_PATH:-/etc/systemd/system/$SERVICE_NAME}"
INSTALL_DIR="$(pwd)"
LIBEXEC_DIR="${MS_QR1_OLLAMA_LIBEXEC_DIR:-/usr/local/libexec/ms-qr1}"
INSTALLED_BRIDGE="$LIBEXEC_DIR/ms-qr1-ollama-bridge.sh"
INSTALLED_PROXY="$LIBEXEC_DIR/ms-qr1-ollama-http-proxy.py"
INSTALLED_COMPOSE_FLAGS="$LIBEXEC_DIR/ms-qr1-compose-flags.sh"
SOURCE_PROXY_SCRIPT="$INSTALL_DIR/scripts/ms-qr1-ollama-http-proxy.py"
SOURCE_COMPOSE_FLAGS="$INSTALL_DIR/scripts/ms-qr1-compose-flags.sh"

require() {
  command -v "$1" >/dev/null || { echo "ERROR: $1 is required" >&2; exit 1; }
}

run_privileged() {
  if [[ "$(id -u)" -eq 0 ]]; then
    "$@"
  else
    sudo "$@"
  fi
}

systemd_quote() {
  python3 - "$1" <<'PY'
import sys
value = sys.argv[1].replace("\\", "\\\\").replace('"', '\\"')
print(f'"{value}"')
PY
}

if [[ "$ACTION" == "remove" ]]; then
  require systemctl
  if ! run_privileged systemctl disable --now "$SERVICE_NAME"; then
    echo "WARNING: $SERVICE_NAME was not active or could not be disabled" >&2
  fi
  run_privileged rm -f "$UNIT_PATH"
  run_privileged rm -f "$INSTALLED_BRIDGE" "$INSTALLED_PROXY" "$INSTALLED_COMPOSE_FLAGS"
  run_privileged rmdir "$LIBEXEC_DIR" 2>/dev/null || true
  run_privileged systemctl daemon-reload
  echo "Removed $SERVICE_NAME"
  exit 0
fi

if [[ "$ACTION" == "status" ]]; then
  require systemctl
  systemctl status "$SERVICE_NAME" --no-pager
  exit 0
fi

require docker
require python3
require ip

if [[ -x "$INSTALLED_COMPOSE_FLAGS" ]]; then
  COMPOSE_FLAGS_SCRIPT="$INSTALLED_COMPOSE_FLAGS"
else
  COMPOSE_FLAGS_SCRIPT="$SOURCE_COMPOSE_FLAGS"
fi

if [[ ! -x "$COMPOSE_FLAGS_SCRIPT" ]]; then
  echo "ERROR: run from the ods/ directory" >&2
  exit 1
fi

mapfile -t network_names < <(
  docker compose $("$COMPOSE_FLAGS_SCRIPT") config --format json \
    | python3 -c '
import json, sys
data = json.load(sys.stdin)
for key, network in data.get("networks", {}).items():
    if isinstance(network, dict) and network.get("internal") is True:
        continue
    if isinstance(network, dict):
        print(network.get("name") or key)
    else:
        print(key)
'
)

gateway_candidates=()
ods_network_gateway=""
for network in "${network_names[@]}"; do
  [[ -n "$network" ]] || continue
  inspect_json="$(docker network inspect "$network")"
  while IFS= read -r gateway; do
    if [[ -n "$gateway" ]]; then
      gateway_candidates+=("$gateway")
      if [[ "$network" == "ods-network" ]]; then
        ods_network_gateway="$gateway"
      fi
    fi
  done < <(printf '%s' "$inspect_json" | python3 -c '
import ipaddress, json, sys
for network in json.load(sys.stdin):
    for cfg in network.get("IPAM", {}).get("Config", []):
        gateway = cfg.get("Gateway", "")
        if not gateway:
            continue
        ip = ipaddress.ip_address(gateway)
        if ip.version == 4 and ip.is_private:
            print(str(ip))
')
done

if [[ "${#gateway_candidates[@]}" -eq 0 ]]; then
  echo "ERROR: no private IPv4 non-internal Docker gateway addresses discovered" >&2
  exit 1
fi

mapfile -t gateways < <(printf '%s\n' "${gateway_candidates[@]}" | sort -u)
interface_addrs="$(ip -o -4 addr show)"
valid_gateways=()
for gateway in "${gateways[@]}"; do
  if INTERFACE_ADDRS="$interface_addrs" python3 - "$gateway" <<'PY'
import os
import ipaddress
import sys
gateway = ipaddress.ip_address(sys.argv[1])
for line in os.environ.get("INTERFACE_ADDRS", "").splitlines():
    for part in line.split():
        if "/" not in part:
            continue
        try:
            iface = ipaddress.ip_interface(part)
        except ValueError:
            continue
        if iface.ip == gateway:
            sys.exit(0)
sys.exit(1)
PY
  then
    valid_gateways+=("$gateway")
  fi
done

if [[ "${#valid_gateways[@]}" -eq 0 ]]; then
  echo "ERROR: discovered Docker gateways do not match host interface addresses" >&2
  exit 1
fi

if [[ -z "$ods_network_gateway" ]]; then
  echo "ERROR: rendered QR1 stack must include non-internal Docker network named ods-network" >&2
  exit 1
fi

if ! printf '%s\n' "${valid_gateways[@]}" | grep -Fx "$ods_network_gateway" >/dev/null; then
  echo "ERROR: ods-network gateway $ods_network_gateway does not match a host interface address" >&2
  exit 1
fi

addr_list="$(printf '%s\n' "${valid_gateways[@]}" | paste -sd ' ' -)"
proxy_args=()
for gateway in "${valid_gateways[@]}"; do
  proxy_args+=(--listen-addr "$gateway")
done

if [[ "$ACTION" == "serve" ]]; then
  [[ -f "$INSTALLED_PROXY" ]] || { echo "ERROR: missing $INSTALLED_PROXY" >&2; exit 1; }
  exec python3 "$INSTALLED_PROXY" "${proxy_args[@]}" \
    --listen-port 11434 \
    --upstream 127.0.0.1:11434 \
    --upstream-host-header localhost:11434 \
    --max-body-bytes "${MS_QR1_OLLAMA_MAX_BODY_BYTES:-268435456}" \
    --upstream-timeout "${MS_QR1_OLLAMA_UPSTREAM_TIMEOUT:-300}"
fi

render_unit() {
  local quoted_exec
  quoted_exec="$(systemd_quote "$INSTALLED_BRIDGE")"
  cat <<UNIT
[Unit]
Description=MS QR1 Ollama Docker HTTP bridge
After=docker.service ollama.service
Wants=docker.service

[Service]
Type=simple
WorkingDirectory=$INSTALL_DIR
ExecStart=$quoted_exec serve
Environment="MS_QR1_OLLAMA_MAX_BODY_BYTES=268435456"
Environment="MS_QR1_OLLAMA_UPSTREAM_TIMEOUT=300"
NoNewPrivileges=true
PrivateTmp=true
ProtectSystem=strict
ReadWritePaths=/tmp /var/tmp
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
UNIT
}

echo "QR1 Ollama bridge target: 127.0.0.1:11434" >&2
echo "QR1 non-internal Docker gateway listener(s):" >&2
printf '  %s:11434\n' "${valid_gateways[@]}" >&2

if [[ "$ACTION" == "expected-listeners" ]]; then
  printf '%s\n' "${valid_gateways[@]}"
  exit 0
fi

if [[ "$ACTION" == "plan" ]]; then
  echo "Set in .env before final compose render:"
  printf 'MS_QR1_HOST_GATEWAY=%s\n' "$ods_network_gateway"
  echo
  echo "Would install $SERVICE_NAME using the QR1 HTTP proxy. No Ollama bind change is required."
  echo "Proxy rewrites upstream Host to localhost:11434 and forwards only to 127.0.0.1:11434."
  exit 0
fi

if [[ "$ACTION" == "render-unit" ]]; then
  render_unit
  exit 0
fi

require systemctl
[[ -f "$SOURCE_PROXY_SCRIPT" ]] || { echo "ERROR: missing $SOURCE_PROXY_SCRIPT" >&2; exit 1; }
[[ -f "$INSTALL_DIR/scripts/ms-qr1-ollama-bridge.sh" ]] || { echo "ERROR: missing $INSTALL_DIR/scripts/ms-qr1-ollama-bridge.sh" >&2; exit 1; }
[[ -f "$SOURCE_COMPOSE_FLAGS" ]] || { echo "ERROR: missing $SOURCE_COMPOSE_FLAGS" >&2; exit 1; }

unit_tmp="$(mktemp "${TMPDIR:-/tmp}/ms-qr1-ollama-bridge.XXXXXX")"
render_unit > "$unit_tmp"
run_privileged install -d -m 0755 "$LIBEXEC_DIR"
run_privileged install -m 0755 "$INSTALL_DIR/scripts/ms-qr1-ollama-bridge.sh" "$INSTALLED_BRIDGE"
run_privileged install -m 0755 "$SOURCE_PROXY_SCRIPT" "$INSTALLED_PROXY"
run_privileged install -m 0755 "$SOURCE_COMPOSE_FLAGS" "$INSTALLED_COMPOSE_FLAGS"
run_privileged install -m 0644 "$unit_tmp" "$UNIT_PATH"
rm -f "$unit_tmp"
run_privileged systemctl daemon-reload
run_privileged systemctl enable "$SERVICE_NAME"
run_privileged systemctl restart "$SERVICE_NAME"
systemctl status "$SERVICE_NAME" --no-pager
