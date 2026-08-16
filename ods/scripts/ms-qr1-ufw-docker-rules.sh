#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'USAGE'
Usage:
  scripts/ms-qr1-ufw-docker-rules.sh plan
  scripts/ms-qr1-ufw-docker-rules.sh apply
  scripts/ms-qr1-ufw-docker-rules.sh remove

Discovers non-internal Docker network subnets for the QR1 stack and manages
UFW allow rules from those subnets to the matching host gateway on ports 11434
and 7710. Run from the ods/ directory after Docker networks exist.
USAGE
}

ACTION="${1:-plan}"
case "$ACTION" in
  plan|apply|remove) ;;
  *) usage >&2; exit 2 ;;
esac

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

require docker
require ufw
require python3
require ip

if [[ ! -x scripts/ms-qr1-compose-flags.sh ]]; then
  echo "ERROR: run from the ods/ directory" >&2
  exit 1
fi

mapfile -t networks < <(
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

if [[ "${#networks[@]}" -eq 0 ]]; then
  echo "ERROR: no non-internal compose networks found" >&2
  exit 1
fi

rules=()
interface_addrs="$(ip -o -4 addr show)"
for network in "${networks[@]}"; do
  [[ -n "$network" ]] || continue
  inspect_json="$(docker network inspect "$network")"
  while IFS=$'\t' read -r subnet gateway; do
    [[ -n "$subnet" && -n "$gateway" ]] || continue
    if ! INTERFACE_ADDRS="$interface_addrs" python3 - "$subnet" "$gateway" <<'PY'
import os
import ipaddress
import sys
network = ipaddress.ip_network(sys.argv[1], strict=False)
gateway = ipaddress.ip_address(sys.argv[2])
if gateway not in network:
    sys.exit(1)
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
      echo "ERROR: $network subnet/gateway validation failed: $subnet -> $gateway" >&2
      exit 1
    fi
    for port in 11434 7710; do
      rules+=("$subnet|$gateway|$port")
    done
  done < <(printf '%s' "$inspect_json" | python3 -c '
import ipaddress, json, sys
for network in json.load(sys.stdin):
    for cfg in network.get("IPAM", {}).get("Config", []):
        subnet = cfg.get("Subnet", "")
        gateway = cfg.get("Gateway", "")
        if not subnet or not gateway:
            continue
        net = ipaddress.ip_network(subnet, strict=False)
        gw = ipaddress.ip_address(gateway)
        if net.version == 4 and net.is_private and gw.version == 4 and gw.is_private:
            print(f"{net}\t{gw}")
')
done

if [[ "${#rules[@]}" -eq 0 ]]; then
  echo "ERROR: no private IPv4 non-internal Docker rules discovered" >&2
  exit 1
fi

mapfile -t unique_rules < <(printf '%s\n' "${rules[@]}" | sort -u)

echo "MS QR1 UFW rule set:"
for rule in "${unique_rules[@]}"; do
  IFS='|' read -r subnet gateway port <<<"$rule"
  printf '  %s -> %s:%s/tcp\n' "$subnet" "$gateway" "$port"
done
echo
echo "Current UFW status:"
if ! ufw status numbered; then
  echo "UFW status requires elevated privileges; rerun with sudo if needed." >&2
fi
echo

for rule in "${unique_rules[@]}"; do
  IFS='|' read -r subnet gateway port <<<"$rule"
  if [[ "$ACTION" == "apply" ]]; then
    echo "Applying: ufw allow from $subnet to $gateway port $port proto tcp comment MS QR1 docker-to-host $port"
    run_privileged ufw allow from "$subnet" to "$gateway" port "$port" proto tcp comment "MS QR1 docker-to-host $port"
  elif [[ "$ACTION" == "remove" ]]; then
    echo "Removing: ufw delete allow from $subnet to $gateway port $port proto tcp"
    if ! run_privileged ufw delete allow from "$subnet" to "$gateway" port "$port" proto tcp; then
      echo "WARNING: UFW rule was already absent or could not be removed: $subnet -> $gateway:$port" >&2
    fi
  else
    echo "Would apply: ufw allow from $subnet to $gateway port $port proto tcp comment 'MS QR1 docker-to-host $port'"
    echo "Would remove: ufw delete allow from $subnet to $gateway port $port proto tcp"
  fi
done

echo
echo "UFW status after $ACTION:"
if ! ufw status numbered; then
  echo "UFW status requires elevated privileges; rerun with sudo if needed." >&2
fi
