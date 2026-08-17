#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

tmpdir="$(mktemp -d "${TMPDIR:-/tmp}/ms-qr1-readiness.XXXXXX")"
trap 'rm -rf "$tmpdir"' EXIT

PYTHON_BIN="$(command -v python3)"

write_ps() {
  local file="$1"
  local n8n_state="${2:-running}"
  local n8n_health="${3:-healthy}"
  local litellm_health="${4:-healthy}"
  cat > "$file" <<JSON
{"Service":"dashboard","State":"running","Health":"healthy"}
{"Service":"dashboard-api","State":"running","Health":"healthy"}
{"Service":"open-webui","State":"running","Health":"healthy"}
{"Service":"hermes","State":"running","Health":"healthy"}
{"Service":"hermes-proxy","State":"running","Health":"healthy"}
{"Service":"n8n","State":"${n8n_state}","Health":"${n8n_health}"}
{"Service":"langfuse","State":"running","Health":"healthy"}
{"Service":"langfuse-worker","State":"running","Health":"healthy"}
{"Service":"langfuse-postgres","State":"running","Health":"healthy"}
{"Service":"langfuse-clickhouse","State":"running","Health":"healthy"}
{"Service":"langfuse-redis","State":"running","Health":"healthy"}
{"Service":"langfuse-minio","State":"running","Health":"healthy"}
{"Service":"perplexica","State":"running","Health":"healthy"}
{"Service":"comfyui","State":"running","Health":"healthy"}
{"Service":"litellm","State":"running","Health":"${litellm_health}"}
{"Service":"model-router","State":"running","Health":""}
{"Service":"qdrant","State":"running","Health":"healthy"}
{"Service":"embeddings","State":"running","Health":"healthy"}
{"Service":"searxng","State":"running","Health":"healthy"}
{"Service":"privacy-shield","State":"running","Health":"healthy"}
{"Service":"token-spy","State":"running","Health":"healthy"}
{"Service":"ape","State":"running","Health":"healthy"}
{"Service":"whisper","State":"running","Health":"healthy"}
{"Service":"tts","State":"running","Health":"healthy"}
JSON
}

write_env() {
  local file="$1"
  cat > "$file" <<'ENV'
MS_QR1_HOST_GATEWAY=172.19.0.1
MS_QR1_TAILSCALE_HOSTNAME=qr1-alt.tailtest.ts.net
WEBUI_AUTH=true
WEBUI_ENABLE_SIGNUP=false
OPEN_WEBUI_ADMIN_EMAIL=operator@example.test
N8N_USER=operator@example.test
N8N_PASS=fixture-only
LANGFUSE_INIT_USER_EMAIL=operator@example.test
LITELLM_KEY=fixture-only
ENV
  printf '%s%s\n' 'OPEN_WEBUI_ADMIN_PASSWORD' '=fixture-only' >> "$file"
  printf '%s%s\n' 'LANGFUSE_INIT_USER_PASSWORD' '=fixture-only' >> "$file"
  printf '%s%s%s\n' 'SHIELD_' 'API_KEY' '=fixture-only' >> "$file"
  printf '%s%s%s\n' 'TOKEN_SPY_' 'API_KEY' '=fixture-only' >> "$file"
  printf '%s%s%s\n' 'DASHBOARD_' 'API_KEY' '=fixture-only' >> "$file"
  printf '%s%s%s\n' 'QDRANT_' 'API_KEY' '=fixture-only' >> "$file"
  printf '%s%s%s\n' 'ODS_SESSION_' 'SECRET' '=fixture-only' >> "$file"
}

make_webui_db() {
  local dir="$1"
  local role="${2:-admin}"
  mkdir -p "$dir/open-webui"
  "$PYTHON_BIN" - "$dir/open-webui/webui.db" "$role" <<'PY'
import sqlite3
import sys
db, role = sys.argv[1], sys.argv[2]
with sqlite3.connect(db) as conn:
    conn.execute("create table user (id text, role text)")
    if role != "none":
        conn.execute("insert into user (id, role) values ('fixture-user', ?)", (role,))
PY
}

status_env() {
  cat <<'ENV'
MS_QR1_READINESS_STATUS_ODS_DASHBOARD_CONTROL_CENTRE=200
MS_QR1_READINESS_STATUS_OPEN_WEBUI=200
MS_QR1_READINESS_STATUS_HERMES_OPERATOR_SURFACE=401
MS_QR1_READINESS_STATUS_N8N_WORKFLOWS=200
MS_QR1_READINESS_STATUS_LANGFUSE_OBSERVABILITY=200
MS_QR1_READINESS_STATUS_PERPLEXICA_RESEARCH=200
MS_QR1_READINESS_STATUS_COMFYUI_IMAGE_GENERATION=200
MS_QR1_READINESS_STATUS_LITELLM_GATEWAY=200
MS_QR1_READINESS_STATUS_QDRANT_VECTOR_STORE=200
MS_QR1_READINESS_STATUS_TEI_EMBEDDINGS=200
MS_QR1_READINESS_STATUS_SEARXNG_SEARCH=200
MS_QR1_READINESS_STATUS_PRIVACY_SHIELD=200
MS_QR1_READINESS_STATUS_TOKEN_SPY=200
MS_QR1_READINESS_STATUS_APE_POLICY_ENGINE=200
MS_QR1_READINESS_STATUS_WHISPER_STT=200
MS_QR1_READINESS_STATUS_KOKORO_TTS=200
MS_QR1_READINESS_STATUS_DASHBOARD_API=200
ENV
}

run_json() {
  local ps_file="$1"
  local env_file="$2"
  local data_dir="$3"
  shift 3
  env \
    MS_QR1_READINESS_COMPOSE_PS="$ps_file" \
    ENV_FILE="$env_file" \
    MS_QR1_READINESS_DATA_DIR="$data_dir" \
    "$@" \
    "$PYTHON_BIN" scripts/ms-qr1-operator-readiness.py --json
}

assert_cap() {
  local json_file="$1"
  local cap="$2"
  local expected="$3"
  local reason_substring="${4:-}"
  "$PYTHON_BIN" - "$json_file" "$cap" "$expected" "$reason_substring" <<'PY'
import json
import sys
data = json.load(open(sys.argv[1], encoding="utf-8"))
cap, expected, needle = sys.argv[2], sys.argv[3], sys.argv[4]
row = {item["capability"]: item for item in data["capabilities"]}[cap]
assert row["result"] == expected, row
if needle:
    assert needle in row["reason_next_action"], row
PY
}

ps_ok="$tmpdir/ps-ok.jsonl"
env_ok="$tmpdir/qr1.env"
data_ok="$tmpdir/data-ok"
serve_ok="$tmpdir/tailscale-serve-ok.txt"
write_ps "$ps_ok"
write_env "$env_ok"
make_webui_db "$data_ok" admin
cat > "$serve_ok" <<'SERVE'
|-- https://qr1-alt.tailtest.ts.net:443
|--> http://127.0.0.1:3001
|-- https://qr1-alt.tailtest.ts.net:8443
|--> http://127.0.0.1:3000
SERVE

env_bad_hostname="$tmpdir/bad-hostname.env"
cp "$env_ok" "$env_bad_hostname"
perl -0pi -e 's/^MS_QR1_TAILSCALE_HOSTNAME=.*/MS_QR1_TAILSCALE_HOSTNAME=_bad-hostname/m' "$env_bad_hostname"
if bash scripts/validate-env.sh "$env_bad_hostname" > "$tmpdir/bad-hostname.out" 2>&1; then
  echo "malformed QR1 Tailscale hostname should fail env validation" >&2
  exit 1
fi

status_file="$tmpdir/status.env"
status_env > "$status_file"

PATH="$tmpdir" "$PYTHON_BIN" scripts/ms-qr1-operator-readiness.py --self-test > "$tmpdir/self-test.out"
grep -F "QR1 operator readiness self-test passed" "$tmpdir/self-test.out" >/dev/null

set -a
# shellcheck disable=SC1090
source "$status_file"
set +a
export MS_QR1_READINESS_TAILSCALE_SERVE_STATUS="$serve_ok"
export MS_QR1_READINESS_OLLAMA_NATIVE_STATUS=200
export MS_QR1_READINESS_OLLAMA_BRIDGE_STATE=ready
run_json "$ps_ok" "$env_ok" "$data_ok" > "$tmpdir/pass.json"
assert_cap "$tmpdir/pass.json" "Open WebUI" PASS
assert_cap "$tmpdir/pass.json" "n8n Workflows" PASS
assert_cap "$tmpdir/pass.json" "Ollama Host Route" PASS
"$PYTHON_BIN" - "$tmpdir/pass.json" <<'PY'
import json
import sys
data = json.load(open(sys.argv[1], encoding="utf-8"))
rows = {row["capability"]: row for row in data["capabilities"]}
assert rows["ODS Dashboard / Control Centre"]["canonical_operator_url"] == "https://qr1-alt.tailtest.ts.net"
assert rows["Open WebUI"]["canonical_operator_url"] == "https://qr1-alt.tailtest.ts.net:8443"
assert rows["Hermes Operator Surface"]["canonical_operator_url"] == ""
assert rows["Hermes Operator Surface"]["operator_reachable"] == "loopback-only"
assert "fixture-only" not in json.dumps(data)
PY

if run_json "$ps_ok" "$env_ok" "$data_ok" MS_QR1_TAILSCALE_HOSTNAME= > "$tmpdir/empty-hostname.json"; then
  echo "missing QR1 Tailscale hostname should fail remote operator readiness" >&2
  exit 1
fi
assert_cap "$tmpdir/empty-hostname.json" "ODS Dashboard / Control Centre" FAIL "required QR1 remote operator route"
assert_cap "$tmpdir/empty-hostname.json" "Open WebUI" FAIL "required QR1 remote operator route"
assert_cap "$tmpdir/empty-hostname.json" "Hermes Operator Surface" PASS

serve_wrong="$tmpdir/tailscale-serve-wrong.txt"
cat > "$serve_wrong" <<'SERVE'
|-- https://qr1-alt.tailtest.ts.net:443
|--> http://127.0.0.1:3999
|-- https://qr1-alt.tailtest.ts.net:8443
|--> http://127.0.0.1:3000
SERVE
if run_json "$ps_ok" "$env_ok" "$data_ok" MS_QR1_READINESS_TAILSCALE_SERVE_STATUS="$serve_wrong" > "$tmpdir/wrong-route-map.json"; then
  echo "wrong Dashboard Tailscale Serve mapping should fail readiness" >&2
  exit 1
fi
assert_cap "$tmpdir/wrong-route-map.json" "ODS Dashboard / Control Centre" FAIL "missing approved Tailscale Serve mapping"

serve_missing="$tmpdir/tailscale-serve-missing.txt"
: > "$serve_missing"
if run_json "$ps_ok" "$env_ok" "$data_ok" MS_QR1_READINESS_TAILSCALE_SERVE_STATUS="$serve_missing" > "$tmpdir/missing-route-map.json"; then
  echo "missing operator Tailscale Serve mappings should fail readiness" >&2
  exit 1
fi
assert_cap "$tmpdir/missing-route-map.json" "Open WebUI" FAIL "missing approved Tailscale Serve mapping"

if run_json "$ps_ok" "$env_ok" "$data_ok" MS_QR1_READINESS_OLLAMA_BRIDGE_STATE=native-only > "$tmpdir/ollama-bridge-stopped.json"; then
  echo "stopped QR1 Ollama bridge should fail readiness" >&2
  exit 1
fi
assert_cap "$tmpdir/ollama-bridge-stopped.json" "Ollama Host Route" FAIL "native-only"

if run_json "$ps_ok" "$env_ok" "$data_ok" MS_QR1_READINESS_OLLAMA_NATIVE_STATUS=500 > "$tmpdir/ollama-native-500.json"; then
  echo "native Ollama HTTP 500 should fail readiness" >&2
  exit 1
fi
assert_cap "$tmpdir/ollama-native-500.json" "Ollama Host Route" FAIL "HTTP 500"

if run_json "$ps_ok" "$env_ok" "$data_ok" MS_QR1_READINESS_OLLAMA_NATIVE_STATUS=404 > "$tmpdir/ollama-native-404.json"; then
  echo "native Ollama HTTP 404 should fail readiness" >&2
  exit 1
fi
assert_cap "$tmpdir/ollama-native-404.json" "Ollama Host Route" FAIL "HTTP 404"

if run_json "$ps_ok" "$env_ok" "$data_ok" MS_QR1_READINESS_OLLAMA_NATIVE_FAILURE=connection-refused > "$tmpdir/ollama-native-failure.json"; then
  echo "native Ollama connection failure should fail readiness" >&2
  exit 1
fi
assert_cap "$tmpdir/ollama-native-failure.json" "Ollama Host Route" FAIL "connection-refused"

if ! env MS_QR1_READINESS_COMPOSE_PS="$ps_ok" ENV_FILE="$env_ok" MS_QR1_READINESS_DATA_DIR="$data_ok" "$PYTHON_BIN" scripts/ms-qr1-operator-readiness.py > "$tmpdir/pass.table"; then
  echo "table mode should pass when JSON mode passes" >&2
  exit 1
fi
grep -F "Ops Centre readiness: 19/19 ready" "$tmpdir/pass.table" >/dev/null

write_ps "$tmpdir/ps-n8n-unhealthy.jsonl" running unhealthy
if run_json "$tmpdir/ps-n8n-unhealthy.jsonl" "$env_ok" "$data_ok" > "$tmpdir/n8n-unhealthy.json"; then
  echo "unhealthy n8n should fail readiness" >&2
  exit 1
fi
assert_cap "$tmpdir/n8n-unhealthy.json" "n8n Workflows" FAIL "unhealthy"

write_ps "$tmpdir/ps-n8n-exited.jsonl" exited unhealthy
if run_json "$tmpdir/ps-n8n-exited.jsonl" "$env_ok" "$data_ok" > "$tmpdir/n8n-exited.json"; then
  echo "exited n8n should fail readiness" >&2
  exit 1
fi
assert_cap "$tmpdir/n8n-exited.json" "n8n Workflows" FAIL "exited/stopped"

write_ps "$tmpdir/ps-litellm-unhealthy.jsonl" running healthy unhealthy
if run_json "$tmpdir/ps-litellm-unhealthy.jsonl" "$env_ok" "$data_ok" > "$tmpdir/litellm-unhealthy.json"; then
  echo "unhealthy LiteLLM should fail dependent readiness" >&2
  exit 1
fi
assert_cap "$tmpdir/litellm-unhealthy.json" "Open WebUI" FAIL "dependencies="

write_ps "$tmpdir/ps-litellm-starting.jsonl" running healthy starting
if run_json "$tmpdir/ps-litellm-starting.jsonl" "$env_ok" "$data_ok" > "$tmpdir/litellm-starting.json"; then
  echo "starting LiteLLM should not be ready" >&2
  exit 1
fi
assert_cap "$tmpdir/litellm-starting.json" "Open WebUI" FAIL "starting"

if run_json "$ps_ok" "$env_ok" "$data_ok" MS_QR1_READINESS_STATUS_N8N_WORKFLOWS=404 > "$tmpdir/wrong-route.json"; then
  echo "wrong non-Hermes route should fail" >&2
  exit 1
fi
assert_cap "$tmpdir/wrong-route.json" "n8n Workflows" FAIL "HTTP 404"

if run_json "$ps_ok" "$env_ok" "$data_ok" MS_QR1_READINESS_STATUS_PRIVACY_SHIELD=403 > "$tmpdir/auth-blocked.json"; then
  echo "auth-blocked non-Hermes route should fail" >&2
  exit 1
fi
assert_cap "$tmpdir/auth-blocked.json" "Privacy Shield" FAIL "HTTP 403"

run_json "$ps_ok" "$env_ok" "$data_ok" MS_QR1_READINESS_STATUS_HERMES_OPERATOR_SURFACE=403 > "$tmpdir/hermes-403.json"
assert_cap "$tmpdir/hermes-403.json" "Hermes Operator Surface" PASS

env_missing_session="$tmpdir/missing-session.env"
write_env "$env_missing_session"
awk -F= '($1 != "ODS_SESSION_" "SECRET") { print }' "$env_missing_session" > "$tmpdir/missing-session.tmp"
mv "$tmpdir/missing-session.tmp" "$env_missing_session"
if run_json "$ps_ok" "$env_missing_session" "$data_ok" > "$tmpdir/missing-session.json"; then
  echo "missing ODS session secret should fail Hermes readiness" >&2
  exit 1
fi
assert_cap "$tmpdir/missing-session.json" "Hermes Operator Surface" FAIL "ODS_SESSION_SECRET"

"$PYTHON_BIN" - "$env_ok" <<'PY'
import email.message
import importlib.util
import os
import pathlib
import sys
from urllib.error import HTTPError

os.environ.pop("MS_QR1_READINESS_STATUS_HERMES_OPERATOR_SURFACE", None)
spec = importlib.util.spec_from_file_location(
    "readiness_redirect", pathlib.Path("scripts/ms-qr1-operator-readiness.py")
)
module = importlib.util.module_from_spec(spec)
sys.modules[spec.name] = module
spec.loader.exec_module(module)
hermes = next(cap for cap in module.CAPABILITIES if cap.capability == "Hermes Operator Surface")
env = module.read_env(pathlib.Path(sys.argv[1]))

class RedirectingOpener:
    def __init__(self, location):
        self.location = location
        self.seen_headers = None
    def open(self, request, timeout):
        self.seen_headers = dict(request.header_items())
        msg = email.message.Message()
        msg.add_header("Location", self.location)
        raise HTTPError(request.full_url, 303, "See Other", msg, None)

opener = RedirectingOpener("/auth/required")
module.NO_PROXY_OPENER = opener
ok = module.http_probe("http://127.0.0.1:9120/api/pty", env, hermes)
assert ok.ok, ok
assert opener.seen_headers == {}, opener.seen_headers

module.NO_PROXY_OPENER = RedirectingOpener("https://example.test/auth/required")
bad = module.http_probe("http://127.0.0.1:9120/api/pty", env, hermes)
assert not bad.ok, bad
PY

env_missing="$tmpdir/missing.env"
write_env "$env_missing"
awk -F= '($1 != "QDRANT_" "API_KEY") { print }' "$env_missing" > "$tmpdir/missing.tmp"
mv "$tmpdir/missing.tmp" "$env_missing"
if run_json "$ps_ok" "$env_missing" "$data_ok" > "$tmpdir/missing-qdrant.json"; then
  echo "missing qdrant key should fail" >&2
  exit 1
fi
assert_cap "$tmpdir/missing-qdrant.json" "Qdrant Vector Store" FAIL "QDRANT_API_KEY"

env_missing_litellm="$tmpdir/missing-litellm.env"
write_env "$env_missing_litellm"
grep -v '^LITELLM_KEY=' "$env_missing_litellm" > "$tmpdir/missing-litellm.tmp" || true
mv "$tmpdir/missing-litellm.tmp" "$env_missing_litellm"
if run_json "$ps_ok" "$env_missing_litellm" "$data_ok" > "$tmpdir/missing-litellm.json"; then
  echo "missing LiteLLM key should fail" >&2
  exit 1
fi
assert_cap "$tmpdir/missing-litellm.json" "Open WebUI" FAIL "LITELLM_KEY"

data_absent="$tmpdir/data-absent"
mkdir -p "$data_absent"
if run_json "$ps_ok" "$env_ok" "$data_absent" > "$tmpdir/webui-absent.json"; then
  echo "absent Open WebUI DB should fail" >&2
  exit 1
fi
assert_cap "$tmpdir/webui-absent.json" "Open WebUI" FAIL "database absent"

data_empty="$tmpdir/data-empty"
make_webui_db "$data_empty" none
if run_json "$ps_ok" "$env_ok" "$data_empty" > "$tmpdir/webui-empty.json"; then
  echo "empty Open WebUI DB should fail" >&2
  exit 1
fi
assert_cap "$tmpdir/webui-empty.json" "Open WebUI" FAIL "admin user is not present"

data_user="$tmpdir/data-user"
make_webui_db "$data_user" user
if run_json "$ps_ok" "$env_ok" "$data_user" > "$tmpdir/webui-user.json"; then
  echo "non-admin Open WebUI user should fail" >&2
  exit 1
fi
assert_cap "$tmpdir/webui-user.json" "Open WebUI" FAIL "admin user is not present"

snapshot_before="$(find "$data_ok/open-webui" -maxdepth 1 -printf '%f %s %T@\n' 2>/dev/null || stat -f '%N %z %m' "$data_ok/open-webui"/*)"
run_json "$ps_ok" "$env_ok" "$data_ok" > "$tmpdir/no-mutate.json"
snapshot_after="$(find "$data_ok/open-webui" -maxdepth 1 -printf '%f %s %T@\n' 2>/dev/null || stat -f '%N %z %m' "$data_ok/open-webui"/*)"
if [[ "$snapshot_before" != "$snapshot_after" ]]; then
  echo "Open WebUI readiness inspection mutated persistent state" >&2
  exit 1
fi

"$PYTHON_BIN" - "$env_ok" <<'PY'
import importlib.util
import os
import pathlib
import sys

os.environ["HTTP_PROXY"] = "http://127.0.0.1:9"
os.environ["HTTPS_PROXY"] = "http://127.0.0.1:9"
os.environ.pop("MS_QR1_READINESS_STATUS_QDRANT_VECTOR_STORE", None)
spec = importlib.util.spec_from_file_location(
    "readiness", pathlib.Path("scripts/ms-qr1-operator-readiness.py")
)
module = importlib.util.module_from_spec(spec)
sys.modules[spec.name] = module
spec.loader.exec_module(module)
qdrant = next(cap for cap in module.CAPABILITIES if cap.capability == "Qdrant Vector Store")
env = module.read_env(pathlib.Path(sys.argv[1]))
seen = {}

class Headers:
    def keys(self):
        return []
    def get_all(self, _key):
        return []

class Response:
    headers = Headers()
    def __enter__(self):
        return self
    def __exit__(self, *_):
        return False
    def getcode(self):
        return 200

class FakeNoProxyOpener:
    def open(self, request, timeout):
        seen["url"] = request.full_url
        seen["headers"] = dict(request.header_items())
        return Response()

module.NO_PROXY_OPENER = FakeNoProxyOpener()
result = module.http_probe("http://127.0.0.1:6333/collections", env, qdrant)
assert result.ok, result
assert seen["url"].startswith("http://127.0.0.1:"), seen
assert any(key.lower() == "api-key" for key in seen["headers"]), seen
PY

before="$(git status --short)"
"$PYTHON_BIN" scripts/ms-qr1-operator-readiness.py --help >/dev/null
after="$(git status --short)"
if [[ "$before" != "$after" ]]; then
  echo "readiness command mutated the worktree" >&2
  exit 1
fi

echo "QR1 operator readiness tests passed"
