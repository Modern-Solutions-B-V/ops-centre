#!/usr/bin/env python3
"""Read-only MS QR1 operator readiness sweep."""

from __future__ import annotations

import argparse
import json
import os
import re
import sqlite3
import subprocess
import sys
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any, Optional
from urllib.error import HTTPError, URLError
from urllib.parse import urlparse
from urllib.request import HTTPRedirectHandler, ProxyHandler, Request, build_opener


ROOT = Path(__file__).resolve().parent.parent
REGISTRY = ROOT / "config" / "ms-qr1" / "operator-access.json"
ENV_FILE = Path(os.environ.get("ENV_FILE", ROOT / ".env"))
DATA_DIR = Path(os.environ.get("MS_QR1_READINESS_DATA_DIR", ROOT / "data"))
TIMEOUT = float(os.environ.get("MS_QR1_READINESS_TIMEOUT", "5"))
class NoRedirectHandler(HTTPRedirectHandler):
    """Observe QR1 auth redirects directly; readiness must not follow them."""

    def redirect_request(self, req, fp, code, msg, headers, newurl):  # type: ignore[override]
        return None


NO_PROXY_OPENER = build_opener(ProxyHandler({}), NoRedirectHandler)
READY_HEALTH = {"healthy", "running_without_healthcheck", "external"}
SAFE_HTTP_2XX = tuple(range(200, 300))
HERMES_DENIAL_STATUSES = (401, 403, 404)


@dataclass(frozen=True)
class Capability:
    capability: str
    services: tuple[str, ...]
    role: str
    local_url: str
    auth: str
    dependencies: tuple[str, ...] = ()
    probe_auth: str = "none"
    expected_statuses: tuple[int, ...] = SAFE_HTTP_2XX
    required_env: tuple[str, ...] = ()
    allow_empty_probe: bool = False

    @property
    def key(self) -> str:
        return re.sub(r"[^A-Z0-9]+", "_", self.capability.upper()).strip("_")


CAPABILITIES = (
    Capability(
        "ODS Dashboard / Control Centre",
        ("dashboard", "dashboard-api"),
        "operator-facing",
        "http://127.0.0.1:${DASHBOARD_PORT:-3001}/",
        "DASHBOARD_API_KEY configured; dashboard UI reachable",
        ("dashboard-api",),
        required_env=("DASHBOARD_API_KEY",),
    ),
    Capability(
        "Open WebUI",
        ("open-webui",),
        "operator-facing",
        "http://127.0.0.1:${WEBUI_PORT:-3000}/health",
        "WEBUI_AUTH true, signup disabled, at least one admin exists",
        ("litellm",),
        required_env=("LITELLM_KEY",),
    ),
    Capability(
        "Hermes Operator Surface",
        ("hermes", "hermes-proxy"),
        "operator-facing",
        "http://127.0.0.1:${HERMES_PROXY_PORT:-9120}/api/pty",
        "unauthenticated access denied by reviewed Hermes proxy contract",
        ("dashboard-api", "litellm", "searxng"),
        expected_statuses=HERMES_DENIAL_STATUSES,
        required_env=("DASHBOARD_API_KEY", "LITELLM_KEY", "ODS_SESSION_SECRET"),
    ),
    Capability(
        "n8n Workflows",
        ("n8n",),
        "operator-facing",
        "http://127.0.0.1:${N8N_PORT:-5678}/healthz",
        "n8n credentials configured in .env",
        required_env=("N8N_USER", "N8N_PASS"),
    ),
    Capability(
        "Langfuse Observability",
        ("langfuse", "langfuse-worker", "langfuse-postgres", "langfuse-clickhouse", "langfuse-redis", "langfuse-minio"),
        "operator-facing",
        "http://127.0.0.1:${LANGFUSE_PORT:-3006}/api/public/health",
        "Langfuse init credentials configured in .env",
        ("litellm",),
        required_env=("LANGFUSE_INIT_USER_EMAIL", "LANGFUSE_INIT_USER_PASSWORD", "LITELLM_KEY"),
    ),
    Capability(
        "Perplexica Research",
        ("perplexica",),
        "operator-facing",
        "http://127.0.0.1:${PERPLEXICA_PORT:-3004}/",
        "loopback-only UI",
        ("searxng", "litellm"),
        required_env=("LITELLM_KEY",),
    ),
    Capability(
        "ComfyUI Image Generation",
        ("comfyui",),
        "operator-facing",
        "http://127.0.0.1:${COMFYUI_PORT:-8188}/",
        "loopback-only UI",
    ),
    Capability(
        "LiteLLM Gateway",
        ("litellm",),
        "internal-platform",
        "http://127.0.0.1:${LITELLM_PORT:-4000}/health/readiness",
        "LITELLM_KEY configured for API clients",
        ("ollama-host",),
        required_env=("LITELLM_KEY",),
    ),
    Capability(
        "Ollama Host Route",
        ("ms-qr1-ollama-bridge",),
        "internal-platform",
        "http://127.0.0.1:11434/api/tags",
        "loopback Ollama plus active gateway-only QR1 HTTP bridge",
    ),
    Capability(
        "Model Router",
        ("model-router",),
        "internal-platform",
        "",
        "internal service, no QR1 operator route",
        allow_empty_probe=True,
    ),
    Capability(
        "Qdrant Vector Store",
        ("qdrant",),
        "internal-platform",
        "http://127.0.0.1:${QDRANT_PORT:-6333}/collections",
        "QDRANT_API_KEY configured and used only for loopback probe",
        ("embeddings",),
        probe_auth="qdrant",
        required_env=("QDRANT_API_KEY",),
    ),
    Capability("TEI Embeddings", ("embeddings",), "internal-platform", "http://127.0.0.1:${EMBEDDINGS_PORT:-8090}/health", "internal embedding endpoint"),
    Capability("SearXNG Search", ("searxng",), "internal-platform", "http://127.0.0.1:${SEARXNG_PORT:-8888}/healthz", "internal search backend"),
    Capability(
        "Privacy Shield",
        ("privacy-shield",),
        "internal-platform",
        "http://127.0.0.1:${SHIELD_PORT:-8085}/health",
        "SHIELD_API_KEY configured for protected routes",
        ("litellm",),
        required_env=("SHIELD_API_KEY", "LITELLM_KEY"),
    ),
    Capability(
        "Token Spy",
        ("token-spy",),
        "internal-platform",
        "http://127.0.0.1:${TOKEN_SPY_PORT:-3005}/health",
        "TOKEN_SPY_API_KEY configured for telemetry routes",
        required_env=("TOKEN_SPY_API_KEY",),
    ),
    Capability("APE Policy Engine", ("ape",), "internal-platform", "http://127.0.0.1:${APE_PORT:-7890}/health", "internal policy endpoint"),
    Capability("Whisper STT", ("whisper",), "internal-platform", "http://127.0.0.1:${WHISPER_PORT:-9000}/health", "internal OpenAI-compatible audio endpoint", ("open-webui",)),
    Capability("Kokoro TTS", ("tts",), "internal-platform", "http://127.0.0.1:${TTS_PORT:-8880}/health", "internal OpenAI-compatible speech endpoint", ("open-webui",)),
    Capability(
        "Dashboard API",
        ("dashboard-api",),
        "internal-platform",
        "http://127.0.0.1:${DASHBOARD_API_PORT:-3002}/health",
        "DASHBOARD_API_KEY configured",
        required_env=("DASHBOARD_API_KEY",),
    ),
)


@dataclass
class ProbeResult:
    ok: bool
    reason: str
    status: Optional[int] = None
    headers: dict[str, list[str]] = field(default_factory=dict)


def read_env(path: Path = ENV_FILE) -> dict[str, str]:
    values: dict[str, str] = {}
    try:
        lines = path.read_text(encoding="utf-8").splitlines()
    except OSError:
        lines = []
    for raw in lines:
        line = raw.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        key, value = line.split("=", 1)
        values[key.strip()] = value.strip().strip("\"'")
    prefixes = (
        "MS_QR1_", "OPEN_WEBUI_", "WEBUI_", "LITELLM_", "QDRANT_", "ODS_",
        "SHIELD_", "TOKEN_SPY_", "DASHBOARD_", "N8N_", "LANGFUSE_",
        "APE_", "COMFYUI_", "PERPLEXICA_", "SEARXNG_", "WHISPER_", "TTS_",
    )
    values.update({key: value for key, value in os.environ.items() if key.startswith(prefixes)})
    return values


def expand(value: str, env: dict[str, str]) -> str:
    pattern = re.compile(r"\$\{([A-Za-z_][A-Za-z0-9_]*)(?::-([^}]*))?\}")

    def repl(match: re.Match[str]) -> str:
        key, default = match.group(1), match.group(2) or ""
        return env.get(key) or default

    return pattern.sub(repl, value)


def valid_url_or_empty(value: str) -> str:
    candidate = value.strip()
    if not candidate:
        return ""
    parsed = urlparse(candidate)
    if parsed.scheme not in {"http", "https"} or not parsed.netloc or "${" in candidate:
        return ""
    if parsed.hostname in {"", None}:
        return ""
    return candidate


def load_registry() -> dict[str, Any]:
    return json.loads(REGISTRY.read_text(encoding="utf-8"))


def load_operator_urls(env: dict[str, str]) -> dict[str, str]:
    data = load_registry()
    urls: dict[str, str] = {}
    for item in data.get("operator_surfaces", []):
        urls[str(item["capability"])] = valid_url_or_empty(expand(str(item.get("canonical_url", "")), env))
    return urls


def run(cmd: list[str]) -> subprocess.CompletedProcess[str]:
    return subprocess.run(cmd, cwd=ROOT, text=True, capture_output=True, check=False)


def split_host_port(value: str) -> tuple[str, str]:
    parsed = urlparse(value)
    if not parsed.scheme or not parsed.netloc:
        return "", ""
    port = parsed.port
    if port is None:
        port = 443 if parsed.scheme == "https" else 80
    return parsed.hostname or "", str(port)


def normalize_health(item: dict[str, Any]) -> str:
    raw_service = str(item.get("Service") or item.get("Name") or item.get("service") or "")
    state = str(item.get("State") or item.get("state") or "").strip().lower()
    health = str(item.get("Health") or item.get("health") or "").strip().lower()
    status = str(item.get("Status") or item.get("status") or "").strip().lower()

    if state in {"exited", "dead", "created", "removing", "paused"}:
        return "exited/stopped"
    if any(token in status for token in ("exited", "dead", "created")):
        return "exited/stopped"
    if health == "healthy":
        return "healthy"
    if health == "starting":
        return "starting"
    if health == "unhealthy":
        return "unhealthy"
    if state == "running" or status.startswith("up"):
        if health in {"", "none", "null"}:
            return "running_without_healthcheck"
        return health or "running_without_healthcheck"
    if raw_service:
        return state or status or "unknown"
    return "unknown"


def compose_ps() -> dict[str, str]:
    fixture = os.environ.get("MS_QR1_READINESS_COMPOSE_PS")
    if fixture:
        text = Path(fixture).read_text(encoding="utf-8")
    else:
        flags = run(["bash", "scripts/ms-qr1-compose-flags.sh"])
        if flags.returncode != 0:
            return {}
        cmd = ["docker", "compose", *flags.stdout.split(), "ps", "-a", "--format", "json"]
        result = run(cmd)
        if result.returncode != 0:
            return {}
        text = result.stdout

    stripped = text.strip()
    if not stripped:
        return {}
    try:
        parsed = json.loads(stripped)
        entries = parsed if isinstance(parsed, list) else [parsed]
    except json.JSONDecodeError:
        entries = [json.loads(line) for line in stripped.splitlines() if line.strip()]

    services: dict[str, str] = {}
    for item in entries:
        service = str(item.get("Service") or item.get("Name") or item.get("service") or "")
        if service:
            services[service] = normalize_health(item)
    return services


def fixture_status_for(capability: Capability) -> Optional[int]:
    value = os.environ.get(f"MS_QR1_READINESS_STATUS_{capability.key}")
    if not value:
        return None
    return int(value)


def headers_by_lower_name(headers: Any) -> dict[str, list[str]]:
    values: dict[str, list[str]] = {}
    for key in headers.keys():
        values.setdefault(str(key).lower(), []).extend(headers.get_all(key) or [])
    return values


def listener_addrs_for_port(snapshot: str, port: str) -> set[str]:
    found: set[str] = set()
    for line in snapshot.splitlines():
        fields = line.split()
        if len(fields) < 4 or fields[0] == "State":
            continue
        local = fields[3]
        if local.startswith("["):
            match = re.match(r"^\[([^\]]+)\]:(\d+)$", local)
            if match and match.group(2) == port:
                found.add(match.group(1))
            continue
        if ":" not in local:
            continue
        addr, actual_port = local.rsplit(":", 1)
        if actual_port == port:
            found.add(addr)
    return found


def command_or_fixture(name: str, cmd: list[str]) -> tuple[bool, str]:
    value = os.environ.get(name)
    if value is not None:
        path = Path(value)
        if path.exists():
            return True, path.read_text(encoding="utf-8")
        return True, value
    result = run(cmd)
    return result.returncode == 0, result.stdout


def ollama_native_probe(url: str) -> ProbeResult:
    failure = os.environ.get("MS_QR1_READINESS_OLLAMA_NATIVE_FAILURE")
    if failure:
        return ProbeResult(False, f"probe failed: {failure}")
    fixture_status = os.environ.get("MS_QR1_READINESS_OLLAMA_NATIVE_STATUS")
    if fixture_status:
        code = int(fixture_status)
        return ProbeResult(code in SAFE_HTTP_2XX, f"HTTP {code}", code)

    native = http_probe_basic(url)
    if not native.ok:
        return native
    code = native.status or 0
    if code not in SAFE_HTTP_2XX:
        return ProbeResult(False, f"HTTP {code}", code, native.headers)
    return native


def ollama_bridge_probe(url: str) -> ProbeResult:
    native = ollama_native_probe(url)
    if not native.ok:
        return native

    fixture = os.environ.get("MS_QR1_READINESS_OLLAMA_BRIDGE_STATE")
    if fixture:
        if fixture == "ready":
            return ProbeResult(True, "native Ollama and QR1 bridge listener present")
        return ProbeResult(False, f"QR1 Ollama bridge not ready: {fixture}")

    active = run(["systemctl", "is-active", "ms-qr1-ollama-bridge.service"])
    if active.returncode != 0 or active.stdout.strip() != "active":
        return ProbeResult(False, "ms-qr1-ollama-bridge.service is not active")

    expected_ok, expected_out = command_or_fixture(
        "MS_QR1_READINESS_BRIDGE_EXPECTED_LISTENERS",
        ["bash", "scripts/ms-qr1-ollama-bridge.sh", "expected-listeners"],
    )
    if not expected_ok:
        return ProbeResult(False, "cannot determine expected QR1 bridge listener(s)")
    expected = set(filter(None, (line.strip() for line in expected_out.splitlines())))
    if not expected:
        return ProbeResult(False, "no expected QR1 bridge listener(s)")

    ss_ok, ss_out = command_or_fixture("MS_QR1_READINESS_SS", ["ss", "-tlnp"])
    if not ss_ok:
        return ProbeResult(False, "cannot capture listener snapshot with ss")
    addrs = listener_addrs_for_port(ss_out, "11434")
    if "127.0.0.1" not in addrs:
        return ProbeResult(False, "native loopback Ollama listener is absent")
    missing = sorted(expected - addrs)
    if missing:
        return ProbeResult(False, f"missing QR1 bridge listener(s): {', '.join(missing)}")
    return ProbeResult(True, "native Ollama and QR1 bridge listener present")


def http_probe_basic(url: str, headers: Optional[dict[str, str]] = None) -> ProbeResult:
    request = Request(url, headers=headers or {})
    try:
        with NO_PROXY_OPENER.open(request, timeout=TIMEOUT) as response:
            code = response.getcode()
            response_headers = headers_by_lower_name(response.headers)
    except HTTPError as exc:
        code = exc.code
        response_headers = headers_by_lower_name(exc.headers)
    except (OSError, URLError) as exc:
        return ProbeResult(False, f"probe failed: {exc}")
    return ProbeResult(True, f"HTTP {code}", code, response_headers)


def http_probe(url: str, env: dict[str, str], capability: Capability) -> ProbeResult:
    if not url:
        if capability.allow_empty_probe:
            return ProbeResult(True, "no live probe required")
        return ProbeResult(False, "probe URL is not configured")

    fixture_status = fixture_status_for(capability)
    if fixture_status is not None:
        ok = fixture_status in capability.expected_statuses
        return ProbeResult(ok, f"HTTP {fixture_status}", fixture_status)

    if capability.capability == "Ollama Host Route":
        return ollama_bridge_probe(url)

    headers = {}
    if capability.probe_auth == "qdrant":
        token = env.get("QDRANT_API_KEY", "")
        if token:
            headers["api-key"] = token
    basic = http_probe_basic(url, headers)
    if not basic.ok:
        return basic
    code = basic.status or 0
    headers_by_name = basic.headers
    if capability.capability == "Hermes Operator Surface" and code == 303:
        locations = headers_by_name.get("location", [])
        ok = len(locations) == 1 and locations[0].strip() == "/auth/required"
        if ok:
            return ProbeResult(True, "HTTP 303 Location /auth/required", code, headers_by_name)
        return ProbeResult(False, "HTTP 303 without exactly one Location: /auth/required", code, headers_by_name)

    ok = code in capability.expected_statuses
    return ProbeResult(ok, f"HTTP {code}", code, headers_by_name)


def env_config_state(capability: Capability, env: dict[str, str]) -> tuple[bool, str]:
    missing = [key for key in capability.required_env if not env.get(key)]
    if missing:
        return False, f"missing required config: {', '.join(missing)}"
    return True, "required configuration present" if capability.required_env else capability.auth


def open_webui_admin_state(env: dict[str, str]) -> tuple[bool, str]:
    if env.get("WEBUI_AUTH", "true").lower() != "true":
        return False, "WEBUI_AUTH must remain true"
    if env.get("WEBUI_ENABLE_SIGNUP", "false").lower() != "false":
        return False, "WEBUI_ENABLE_SIGNUP must remain false"

    db_path = DATA_DIR / "open-webui" / "webui.db"
    if not db_path.exists():
        return False, "Open WebUI database absent; bootstrap not completed"
    before = snapshot_dir(db_path.parent)
    try:
        with sqlite3.connect(f"file:{db_path}?mode=ro&immutable=1", uri=True) as conn:
            count = conn.execute("select count(*) from user where role = 'admin'").fetchone()[0]
    except (sqlite3.Error, OSError) as exc:
        return False, f"cannot inspect Open WebUI admin state read-only: {exc}"
    after = snapshot_dir(db_path.parent)
    if before != after:
        return False, "Open WebUI admin inspection would mutate persistent state"
    if count > 0:
        return True, f"{count} Open WebUI admin user(s) present"
    if env.get("OPEN_WEBUI_ADMIN_EMAIL") and env.get("OPEN_WEBUI_ADMIN_PASSWORD"):
        return False, "first-admin bootstrap configured but admin user is not present"
    return False, "Open WebUI admin user is not present"


def snapshot_dir(path: Path) -> list[tuple[str, int, int, int]]:
    try:
        entries = sorted(path.iterdir())
    except OSError:
        return []
    snapshot = []
    for item in entries:
        try:
            stat = item.lstat()
        except OSError:
            continue
        snapshot.append((item.name, stat.st_mode, stat.st_size, stat.st_mtime_ns))
    return snapshot


def auth_state(capability: Capability, env: dict[str, str]) -> tuple[bool, str]:
    config_ok, config_reason = env_config_state(capability, env)
    if capability.capability == "Open WebUI":
        webui_ok, webui_reason = open_webui_admin_state(env)
        if not config_ok:
            return False, f"{config_reason}; {webui_reason}"
        return webui_ok, webui_reason
    return config_ok, config_reason


def normalize_serve_line(raw_line: str) -> str:
    line = raw_line.strip()
    if line.startswith("|--> "):
        return "--> " + line[5:]
    if line.startswith("|-- "):
        return line[4:]
    return line


def tailscale_serve_status() -> tuple[bool, str]:
    value = os.environ.get("MS_QR1_READINESS_TAILSCALE_SERVE_STATUS")
    if value is not None:
        path = Path(value)
        if path.exists():
            return True, path.read_text(encoding="utf-8")
        return True, value
    result = run(["tailscale", "serve", "status"])
    return result.returncode == 0, result.stdout


def approved_serve_mappings() -> dict[tuple[str, str, str], str]:
    ok, status = tailscale_serve_status()
    if not ok:
        return {}
    source_re = re.compile(r"^(tcp|https?)://(?:\[([^\]]+)\]|([^:\s]+)):(\d+)(?:\s+\(tailnet only\))?$")
    target_re = re.compile(r"^-->\s*((?:tcp|https?)://[^\s]+)$")
    mappings: dict[tuple[str, str, str], str] = {}
    pending: list[tuple[str, str, str]] = []
    pending_family: Optional[tuple[str, str]] = None

    for raw_line in status.splitlines():
        line = normalize_serve_line(raw_line)
        if not line:
            continue
        target_match = target_re.match(line)
        if target_match:
            if not pending:
                return {}
            target = target_match.group(1)
            for scheme, host, port in pending:
                key = (scheme, host, port)
                if key in mappings:
                    return {}
                mappings[key] = target
            pending = []
            pending_family = None
            continue

        source_match = source_re.match(line)
        if not source_match:
            return {}
        scheme = source_match.group(1)
        host = source_match.group(2) or source_match.group(3)
        port = source_match.group(4)
        family = (scheme, port)
        if pending_family is None:
            pending_family = family
        elif pending_family != family:
            return {}
        pending.append((scheme, host, port))

    if pending:
        return {}
    return mappings


def operator_route_state(capability: Capability, canonical_url: str, local_url: str, env: dict[str, str]) -> tuple[str, bool, str]:
    if not canonical_url:
        if capability.capability in {"ODS Dashboard / Control Centre", "Open WebUI"}:
            return "no", False, "required QR1 remote operator route is not configured"
        if capability.role == "operator-facing":
            return "loopback-only", True, "no QR1 remote route approved"
        return "internal-only", True, "internal capability"

    if capability.capability not in {"ODS Dashboard / Control Centre", "Open WebUI"}:
        return "no", False, "canonical URL configured for unapproved QR1 route"

    host, port = split_host_port(canonical_url)
    expected_host = env.get("MS_QR1_TAILSCALE_HOSTNAME", "")
    if not host or host != expected_host:
        return "no", False, "canonical URL does not match MS_QR1_TAILSCALE_HOSTNAME"

    parsed_local = urlparse(local_url)
    if parsed_local.hostname != "127.0.0.1" or parsed_local.port is None:
        return "no", False, "local operator target is not loopback"
    expected_target = f"http://127.0.0.1:{parsed_local.port}"
    actual_target = approved_serve_mappings().get(("https", host, port))
    if actual_target == expected_target:
        return "yes", True, "approved Tailscale Serve mapping present"
    return "no", False, f"missing approved Tailscale Serve mapping to {expected_target}"


def service_ready(value: str) -> bool:
    return value in READY_HEALTH


def evaluate_rows() -> list[dict[str, Any]]:
    env = read_env()
    operator_urls = load_operator_urls(env)
    service_health = compose_ps()
    rows: list[dict[str, Any]] = []
    for cap in CAPABILITIES:
        health_values = [service_health.get(service, "unknown") for service in cap.services]
        if cap.capability == "Ollama Host Route":
            health_values = ["checked-by-readiness"]
        container_ok = all(service_ready(value) for value in health_values)
        local_url = expand(os.environ.get(f"MS_QR1_READINESS_URL_{cap.key}", cap.local_url), env)
        probe = http_probe(local_url, env, cap)
        if cap.capability == "Ollama Host Route":
            container_ok = probe.ok
        auth_ok, auth_reason = auth_state(cap, env)
        deps = {
            dep: service_health.get(dep, "external" if dep == "ollama-host" else "unknown")
            for dep in cap.dependencies
        }
        deps_ok = all(service_ready(value) for value in deps.values())
        canonical_url = operator_urls.get(cap.capability, "")
        reachable, route_ok, route_reason = operator_route_state(cap, canonical_url, local_url, env)
        ok = container_ok and probe.ok and auth_ok and deps_ok and route_ok
        reason_parts = []
        if not container_ok:
            reason_parts.append(f"container health={health_values}")
        if not probe.ok:
            reason_parts.append(probe.reason)
        if not auth_ok:
            reason_parts.append(auth_reason)
        if not deps_ok:
            reason_parts.append(f"dependencies={deps}")
        if not route_ok:
            reason_parts.append(route_reason)
        rows.append({
            "capability": cap.capability,
            "services": ",".join(cap.services),
            "role": cap.role,
            "container_health": ",".join(health_values),
            "functional_probe": probe.reason,
            "auth_bootstrap_state": auth_reason,
            "operator_reachable": reachable,
            "canonical_operator_url": canonical_url,
            "dependency_status": deps,
            "result": "PASS" if ok else "FAIL",
            "reason_next_action": "; ".join(reason_parts) if reason_parts else "ready",
        })
    return rows


def print_table(rows: list[dict[str, Any]]) -> None:
    columns = [
        ("Capability", "capability", 30),
        ("Role", "role", 17),
        ("Health", "container_health", 24),
        ("Probe", "functional_probe", 12),
        ("Auth/bootstrap", "auth_bootstrap_state", 36),
        ("Operator reachable", "operator_reachable", 18),
        ("Result", "result", 6),
        ("Reason / next action", "reason_next_action", 46),
    ]
    print(" | ".join(title.ljust(width) for title, _, width in columns))
    print("-+-".join("-" * width for _, _, width in columns))
    for row in rows:
        cells = []
        for _, key, width in columns:
            value = row[key]
            if isinstance(value, dict):
                value = ",".join(f"{k}:{v}" for k, v in value.items())
            text = str(value)
            cells.append((text[: width - 1] + "…") if len(text) > width else text.ljust(width))
        print(" | ".join(cells))
    passed = sum(1 for row in rows if row["result"] == "PASS")
    operator = [row for row in rows if row["role"] == "operator-facing"]
    operator_ready = sum(1 for row in operator if row["result"] == "PASS")
    print()
    print(f"Ops Centre readiness: {passed}/{len(rows)} ready")
    print(f"Operator surfaces: {operator_ready}/{len(operator)} ready")
    print(f"Bootstrap actions: {sum(1 for row in rows if row['result'] != 'PASS')}")


def static_self_test() -> int:
    data = load_registry()
    if data.get("schema_version") != "ms.qr1.operator_access.v1":
        print("invalid operator access registry schema", file=sys.stderr)
        return 1
    names = {cap.capability for cap in CAPABILITIES}
    required = {"Open WebUI", "LiteLLM Gateway", "Hermes Operator Surface", "Qdrant Vector Store"}
    missing = sorted(required - names)
    if missing:
        print(f"missing readiness capabilities: {missing}", file=sys.stderr)
        return 1
    registry_names = {str(item.get("capability", "")) for item in data.get("operator_surfaces", [])}
    unknown_registry = sorted(registry_names - names)
    if unknown_registry:
        print(f"operator registry references unknown capabilities: {unknown_registry}", file=sys.stderr)
        return 1
    hermes = next((item for item in data.get("operator_surfaces", []) if item.get("id") == "hermes"), None)
    if hermes and hermes.get("canonical_url"):
        print("Hermes must not advertise a QR1 remote canonical URL", file=sys.stderr)
        return 1
    print("QR1 operator readiness self-test passed")
    return 0


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--json", action="store_true", help="emit machine-readable JSON")
    parser.add_argument("--self-test", action="store_true", help="validate static registry/classification only")
    args = parser.parse_args()

    if args.self_test:
        return static_self_test()

    rows = evaluate_rows()
    if args.json:
        print(json.dumps({"capabilities": rows}, indent=2, sort_keys=True))
    else:
        print_table(rows)
    return 0 if all(row["result"] == "PASS" for row in rows) else 1


if __name__ == "__main__":
    sys.exit(main())
