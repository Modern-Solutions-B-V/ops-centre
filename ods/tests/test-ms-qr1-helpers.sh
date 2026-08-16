#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

tmpdir="$(mktemp -d "${TMPDIR:-/tmp}/ms-qr1-helpers.XXXXXX")"
trap 'rm -rf "$tmpdir"' EXIT

cat > "$tmpdir/docker" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
case "$1 $2" in
  "network inspect")
    case "$3" in
      ods_default) cat "$FIXTURE_DIR/network-ods_default.json" ;;
      ods_langfuse-internal) cat "$FIXTURE_DIR/network-ods_langfuse-internal.json" ;;
      default|langfuse-internal)
        echo "inspected Compose key instead of rendered network name: $3" >&2
        exit 44
        ;;
      *)
        echo "unexpected network inspect target: $3" >&2
        exit 45
        ;;
    esac
    ;;
  *)
    if [[ "${1:-}" == "compose" && " $* " == *" config "* ]]; then
      cat "$FIXTURE_DIR/compose-config.json"
      exit 0
    fi
    echo "unexpected docker command: $*" >&2
    exit 46
    ;;
esac
SH

cat > "$tmpdir/ufw" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
if [[ "${1:-}" == "status" ]]; then
  echo "Status: active"
  exit 0
fi
echo "ufw $*"
SH

cat > "$tmpdir/ip" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
if [[ "$*" == "-o -4 addr show" ]]; then
  cat "$FIXTURE_DIR/ip-addr.txt"
  exit 0
fi
echo "unexpected ip command: $*" >&2
exit 47
SH

chmod +x "$tmpdir/docker" "$tmpdir/ufw" "$tmpdir/ip"

cat > "$tmpdir/compose-config.json" <<'JSON'
{
  "networks": {
    "default": {"name": "ods_default"},
    "langfuse-internal": {"name": "ods_langfuse-internal"}
  }
}
JSON

cat > "$tmpdir/network-ods_default.json" <<'JSON'
[
  {
    "Name": "ods_default",
    "IPAM": {
      "Config": [
        {"Subnet": "172.28.0.0/16", "Gateway": "172.28.0.1"}
      ]
    }
  }
]
JSON

cat > "$tmpdir/network-ods_langfuse-internal.json" <<'JSON'
[
  {
    "Name": "ods_langfuse-internal",
    "IPAM": {
      "Config": [
        {"Subnet": "172.29.0.0/16", "Gateway": "172.29.0.1"}
      ]
    }
  }
]
JSON

cat > "$tmpdir/ip-addr.txt" <<'EOF'
7: br-a inet 172.28.0.1/16 brd 172.28.255.255 scope global br-a
8: br-b inet 172.29.0.1/16 brd 172.29.255.255 scope global br-b
EOF

output="$(FIXTURE_DIR="$tmpdir" PATH="$tmpdir:$PATH" scripts/ms-qr1-ufw-docker-rules.sh plan)"

grep -F "172.28.0.0/16" <<<"$output" >/dev/null
grep -F "172.29.0.0/16" <<<"$output" >/dev/null
grep -F "Would apply: sudo ufw allow from 172.28.0.0/16 to any port 11434 proto tcp" <<<"$output" >/dev/null
grep -F "Would apply: sudo ufw allow from 172.29.0.0/16 to any port 7710 proto tcp" <<<"$output" >/dev/null

if grep -nE 'curl .*OLLAMA_URL.*/api/tags.*\|' scripts/ms-qr1-acceptance.sh >/dev/null; then
  echo "acceptance helper must not pipe Ollama JSON into a heredoc-backed python stdin" >&2
  exit 1
fi

if grep -nE 'printf .*INTERFACE_ADDRS.*\|[[:space:]]*python3 - "\$cidr" <<' scripts/ms-qr1-ufw-docker-rules.sh >/dev/null; then
  echo "UFW helper must not pipe interface data into a heredoc-backed python stdin" >&2
  exit 1
fi

bash -n scripts/ms-qr1-compose-flags.sh scripts/ms-qr1-ufw-docker-rules.sh \
  scripts/ms-qr1-ollama-bridge.sh scripts/ms-qr1-acceptance.sh

echo "MS QR1 helper tests passed"
