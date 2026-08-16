#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'USAGE'
Usage:
  scripts/ms-qr1-ollama-bridge.sh plan
  scripts/ms-qr1-ollama-bridge.sh render-unit
  scripts/ms-qr1-ollama-bridge.sh install
  scripts/ms-qr1-ollama-bridge.sh remove
  scripts/ms-qr1-ollama-bridge.sh status

Installs a narrow host-side bridge for QR1 containers:
  non-internal ODS Docker gateway IP(s):11434 -> 127.0.0.1:11434

It does not change Ollama's listener and never binds Ollama or socat to
0.0.0.0. Run from the ods/ directory after QR1 Docker networks exist.
USAGE
}

ACTION="${1:-plan}"
case "$ACTION" in
  plan|render-unit|install|remove|status) ;;
  *) usage >&2; exit 2 ;;
esac

SERVICE_NAME="ms-qr1-ollama-bridge.service"
UNIT_PATH="${MS_QR1_OLLAMA_UNIT_PATH:-/etc/systemd/system/$SERVICE_NAME}"

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

if [[ "$ACTION" == "remove" ]]; then
  require systemctl
  if ! run_privileged systemctl disable --now "$SERVICE_NAME"; then
    echo "WARNING: $SERVICE_NAME was not active or could not be disabled" >&2
  fi
  run_privileged rm -f "$UNIT_PATH"
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

if [[ ! -x scripts/ms-qr1-compose-flags.sh ]]; then
  echo "ERROR: run from the ods/ directory" >&2
  exit 1
fi

mapfile -t network_names < <(
  docker compose $(scripts/ms-qr1-compose-flags.sh) config --format json \
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

render_unit() {
  cat <<UNIT
[Unit]
Description=MS QR1 Ollama Docker bridge
After=docker.service ollama.service
Wants=docker.service

[Service]
Type=simple
Environment="MS_QR1_OLLAMA_BRIDGE_ADDRS=$addr_list"
ExecStart=/bin/sh -c 'if [ -z "\$\$MS_QR1_OLLAMA_BRIDGE_ADDRS" ]; then exit 64; fi; for addr in \$\$MS_QR1_OLLAMA_BRIDGE_ADDRS; do if [ -z "\$\$addr" ]; then exit 64; fi; socat TCP-LISTEN:11434,bind=\$\$addr,reuseaddr,fork TCP:127.0.0.1:11434 & done; wait'
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
UNIT
}

echo "QR1 Ollama bridge target: 127.0.0.1:11434" >&2
echo "QR1 non-internal Docker gateway listener(s):" >&2
printf '  %s:11434\n' "${valid_gateways[@]}" >&2

if [[ "$ACTION" == "plan" ]]; then
  echo "Set in .env before final compose render:"
  printf 'MS_QR1_HOST_GATEWAY=%s\n' "$ods_network_gateway"
  echo
  echo "Would install $SERVICE_NAME using socat. No Ollama bind change is required."
  exit 0
fi

if [[ "$ACTION" == "render-unit" ]]; then
  render_unit
  exit 0
fi

require socat
require systemctl

unit_tmp="$(mktemp "${TMPDIR:-/tmp}/ms-qr1-ollama-bridge.XXXXXX")"
render_unit > "$unit_tmp"
run_privileged install -m 0644 "$unit_tmp" "$UNIT_PATH"
rm -f "$unit_tmp"
run_privileged systemctl daemon-reload
run_privileged systemctl enable "$SERVICE_NAME"
run_privileged systemctl restart "$SERVICE_NAME"
systemctl status "$SERVICE_NAME" --no-pager
