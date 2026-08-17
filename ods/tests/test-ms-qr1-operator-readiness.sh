#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

tmpdir="$(mktemp -d "${TMPDIR:-/tmp}/ms-qr1-readiness.XXXXXX")"
trap 'rm -rf "$tmpdir"' EXIT

cat > "$tmpdir/ps.jsonl" <<'JSON'
{"Service":"dashboard","State":"running","Health":"healthy"}
{"Service":"dashboard-api","State":"running","Health":"healthy"}
{"Service":"open-webui","State":"running","Health":"healthy"}
{"Service":"hermes","State":"running","Health":"healthy"}
{"Service":"hermes-proxy","State":"running","Health":"healthy"}
{"Service":"n8n","State":"running","Health":"healthy"}
{"Service":"langfuse","State":"running","Health":"healthy"}
{"Service":"langfuse-worker","State":"running","Health":"healthy"}
{"Service":"langfuse-postgres","State":"running","Health":"healthy"}
{"Service":"langfuse-clickhouse","State":"running","Health":"healthy"}
{"Service":"langfuse-redis","State":"running","Health":"healthy"}
{"Service":"langfuse-minio","State":"running","Health":"healthy"}
{"Service":"perplexica","State":"running","Health":"healthy"}
{"Service":"comfyui","State":"running","Health":"healthy"}
{"Service":"litellm","State":"running","Health":"healthy"}
{"Service":"model-router","State":"running","Health":"healthy"}
{"Service":"qdrant","State":"running","Health":"healthy"}
{"Service":"embeddings","State":"running","Health":"healthy"}
{"Service":"searxng","State":"running","Health":"healthy"}
{"Service":"privacy-shield","State":"running","Health":"healthy"}
{"Service":"token-spy","State":"running","Health":"healthy"}
{"Service":"ape","State":"running","Health":"healthy"}
{"Service":"whisper","State":"running","Health":"healthy"}
{"Service":"tts","State":"running","Health":"healthy"}
JSON

cat > "$tmpdir/qr1.env" <<'ENV'
MS_QR1_HOST_GATEWAY=172.19.0.1
MS_QR1_TAILSCALE_HOSTNAME=evox3.tailfc79e6.ts.net
WEBUI_AUTH=true
WEBUI_ENABLE_SIGNUP=false
OPEN_WEBUI_ADMIN_EMAIL=operator@example.test
N8N_USER=operator@example.test
N8N_PASS=fixture-only
LANGFUSE_INIT_USER_EMAIL=operator@example.test
ENV
printf '%s%s\n' 'OPEN_WEBUI_ADMIN_PASSWORD' '=fixture-only' >> "$tmpdir/qr1.env"
printf '%s%s\n' 'LANGFUSE_INIT_USER_PASSWORD' '=fixture-only' >> "$tmpdir/qr1.env"
printf '%s%s\n' 'QDRANT_API_KEY' '=fixture-only' >> "$tmpdir/qr1.env"

python3 scripts/ms-qr1-operator-readiness.py --self-test > "$tmpdir/self-test.out"
grep -F "QR1 operator readiness self-test passed" "$tmpdir/self-test.out" >/dev/null

MS_QR1_READINESS_COMPOSE_PS="$tmpdir/ps.jsonl" \
ENV_FILE="$tmpdir/qr1.env" \
MS_QR1_READINESS_TIMEOUT=0.01 \
python3 scripts/ms-qr1-operator-readiness.py --json > "$tmpdir/readiness.json" || true

python3 - "$tmpdir/readiness.json" <<'PY'
import json
import sys
data = json.load(open(sys.argv[1], encoding="utf-8"))
rows = data["capabilities"]
names = {row["capability"]: row for row in rows}
assert "Open WebUI" in names
assert names["Open WebUI"]["canonical_operator_url"] == "https://evox3.tailfc79e6.ts.net:8443"
assert names["Open WebUI"]["operator_reachable"] == "yes"
assert names["LiteLLM Gateway"]["operator_reachable"] == "internal-only"
assert names["n8n Workflows"]["operator_reachable"] == "loopback-only"
assert "fixture-only" not in json.dumps(data)
PY

before="$(git status --short)"
python3 scripts/ms-qr1-operator-readiness.py --help >/dev/null
after="$(git status --short)"
if [[ "$before" != "$after" ]]; then
  echo "readiness command mutated the worktree" >&2
  exit 1
fi

echo "QR1 operator readiness tests passed"
