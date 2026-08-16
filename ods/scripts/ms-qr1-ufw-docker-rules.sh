#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'USAGE'
Usage:
  scripts/ms-qr1-ufw-docker-rules.sh plan
  scripts/ms-qr1-ufw-docker-rules.sh apply

Discovers Docker network subnets for the resolved ODS stack and prints or
applies UFW allow rules from those subnets to host ports 11434 and 7710.
Run from the ods/ directory after Docker networks exist.
USAGE
}

ACTION="${1:-plan}"
if [[ "$ACTION" != "plan" && "$ACTION" != "apply" ]]; then
  usage >&2
  exit 2
fi

command -v docker >/dev/null 2>&1 || { echo "ERROR: docker is required" >&2; exit 1; }
command -v ufw >/dev/null 2>&1 || { echo "ERROR: ufw is required" >&2; exit 1; }
command -v python3 >/dev/null 2>&1 || { echo "ERROR: python3 is required" >&2; exit 1; }
command -v ip >/dev/null 2>&1 || { echo "ERROR: iproute2 'ip' is required" >&2; exit 1; }

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
    if isinstance(network, dict):
        print(network.get("name") or key)
    else:
        print(key)
'
)

if [[ "${#networks[@]}" -eq 0 ]]; then
  echo "ERROR: no compose networks found; run docker compose config/up first" >&2
  exit 1
fi

cidrs=()
for network in "${networks[@]}"; do
  [[ -n "$network" ]] || continue
  inspect_json="$(docker network inspect "$network" 2>/dev/null || true)"
  [[ -n "$inspect_json" ]] || continue
  while IFS= read -r cidr; do
    [[ -n "$cidr" ]] && cidrs+=("$cidr")
  done < <(printf '%s' "$inspect_json" | python3 -c '
import ipaddress, json, sys
data = json.load(sys.stdin)
for network in data:
    for cfg in network.get("IPAM", {}).get("Config", []):
        subnet = cfg.get("Subnet", "")
        if not subnet:
            continue
        net = ipaddress.ip_network(subnet, strict=False)
        if net.version == 4 and net.is_private:
            print(str(net))
')
done

if [[ "${#cidrs[@]}" -eq 0 ]]; then
  echo "ERROR: no private IPv4 Docker subnets discovered" >&2
  exit 1
fi

mapfile -t unique_cidrs < <(printf '%s\n' "${cidrs[@]}" | sort -u)

interface_addrs="$(ip -o -4 addr show)"
for cidr in "${unique_cidrs[@]}"; do
  if ! INTERFACE_ADDRS="$interface_addrs" python3 - "$cidr" <<'PY'
import os
import ipaddress, sys
network = ipaddress.ip_network(sys.argv[1], strict=False)
for line in os.environ.get("INTERFACE_ADDRS", "").splitlines():
    parts = line.split()
    for part in parts:
        if "/" not in part:
            continue
        try:
            iface = ipaddress.ip_interface(part)
        except ValueError:
            continue
        if iface.ip in network:
            sys.exit(0)
sys.exit(1)
PY
  then
    echo "ERROR: discovered CIDR $cidr does not match any host interface address" >&2
    exit 1
  fi
done

echo "Discovered Docker subnet(s):"
printf '  %s\n' "${unique_cidrs[@]}"
echo
echo "Current UFW status:"
ufw status numbered
echo

for cidr in "${unique_cidrs[@]}"; do
  for port in 11434 7710; do
    rule=(ufw allow from "$cidr" to any port "$port" proto tcp comment "MS QR1 docker-to-host $port")
    if [[ "$ACTION" == "apply" ]]; then
      echo "Applying: ${rule[*]}"
      "${rule[@]}"
    else
      echo "Would apply: sudo ${rule[*]}"
    fi
  done
done

echo
echo "UFW status after ${ACTION}:"
ufw status numbered
echo
echo "Rollback: delete the numbered MS QR1 rules in descending order, for example: sudo ufw delete <rule-number>"
