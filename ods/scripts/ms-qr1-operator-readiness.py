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
from dataclasses import dataclass
from pathlib import Path
from typing import Any
from urllib.error import HTTPError, URLError
from urllib.request import Request, urlopen


ROOT = Path(__file__).resolve().parent.parent
REGISTRY = ROOT / "config" / "ms-qr1" / "operator-access.json"
ENV_FILE = Path(os.environ.get("ENV_FILE", ROOT / ".env"))
TIMEOUT = float(os.environ.get("MS_QR1_READINESS_TIMEOUT", "5"))


@dataclass(frozen=True)
class Capability:
    capability: str
    services: tuple[str, ...]
    role: str
    local_url: str
    canonical_url: str
    auth: str
    dependencies: tuple[str, ...] = ()
    probe_path: str = ""
    probe_auth: str = "none"


CAPABILITIES = (
    Capability("ODS Dashboard / Control Centre", ("dashboard", "dashboard-api"), "operator-facing", "http://127.0.0.1:${DASHBOARD_PORT:-3001}/", "", "setup sentinel and API auth configured", ("dashboard-api",), "/"),
    Capability("Open WebUI", ("open-webui",), "operator-facing", "http://127.0.0.1:${WEBUI_PORT:-3000}/", "", "WEBUI_AUTH true, signup disabled, initial admin present or configured", ("litellm",), "/health"),
    Capability("Hermes Operator Surface", ("hermes", "hermes-proxy"), "operator-facing", "http://127.0.0.1:${HERMES_PROXY_PORT:-9120}/", "", "unauthenticated requests denied or redirected to /auth/required", ("dashboard-api", "litellm", "searxng"), "/api/pty"),
    Capability("n8n Workflows", ("n8n",), "operator-facing", "http://127.0.0.1:${N8N_PORT:-5678}/healthz", "", "credentials configured in .env", (), ""),
    Capability("Langfuse Observability", ("langfuse", "langfuse-worker", "langfuse-postgres", "langfuse-clickhouse", "langfuse-redis", "langfuse-minio"), "operator-facing", "http://127.0.0.1:${LANGFUSE_PORT:-3006}/api/public/health", "", "init credentials configured in .env", ("litellm",), ""),
    Capability("Perplexica Research", ("perplexica",), "operator-facing", "http://127.0.0.1:${PERPLEXICA_PORT:-3004}/", "", "loopback-only UI", ("searxng", "litellm"), ""),
    Capability("ComfyUI Image Generation", ("comfyui",), "operator-facing", "http://127.0.0.1:${COMFYUI_PORT:-8188}/", "", "loopback-only UI", (), ""),
    Capability("LiteLLM Gateway", ("litellm",), "internal-platform", "http://127.0.0.1:${LITELLM_PORT:-4000}/health/readiness", "", "Bearer LITELLM_KEY for API clients", ("ollama-host",), ""),
    Capability("Ollama Host Route", ("ms-qr1-ollama-bridge",), "internal-platform", "http://127.0.0.1:11434/api/tags", "", "loopback Ollama plus gateway-only HTTP bridge", (), ""),
    Capability("Model Router", ("model-router",), "internal-platform", "", "", "internal service, no QR1 operator route", (), ""),
    Capability("Qdrant Vector Store", ("qdrant",), "internal-platform", "http://127.0.0.1:${QDRANT_PORT:-6333}/collections", "", "QDRANT_API_KEY required", ("embeddings",), "", "qdrant"),
    Capability("TEI Embeddings", ("embeddings",), "internal-platform", "http://127.0.0.1:${EMBEDDINGS_PORT:-8090}/health", "", "internal embedding endpoint", (), ""),
    Capability("SearXNG Search", ("searxng",), "internal-platform", "http://127.0.0.1:${SEARXNG_PORT:-8888}/healthz", "", "internal search backend", (), ""),
    Capability("Privacy Shield", ("privacy-shield",), "internal-platform", "http://127.0.0.1:${SHIELD_PORT:-8085}/health", "", "SHIELD_API_KEY for protected routes", ("litellm",), ""),
    Capability("Token Spy", ("token-spy",), "internal-platform", "http://127.0.0.1:${TOKEN_SPY_PORT:-3005}/health", "", "TOKEN_SPY_API_KEY for telemetry routes", (), ""),
    Capability("APE Policy Engine", ("ape",), "internal-platform", "http://127.0.0.1:${APE_PORT:-7890}/health", "", "internal policy endpoint", (), ""),
    Capability("Whisper STT", ("whisper",), "internal-platform", "http://127.0.0.1:${WHISPER_PORT:-9000}/health", "", "internal OpenAI-compatible audio endpoint", ("open-webui",), ""),
    Capability("Kokoro TTS", ("tts",), "internal-platform", "http://127.0.0.1:${TTS_PORT:-8880}/health", "", "internal OpenAI-compatible speech endpoint", ("open-webui",), ""),
    Capability("Dashboard API", ("dashboard-api",), "internal-platform", "http://127.0.0.1:${DASHBOARD_API_PORT:-3002}/health", "", "DASHBOARD_API_KEY protected API", (), ""),
)


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
    values.update({key: value for key, value in os.environ.items() if key.startswith(("MS_QR1_", "OPEN_WEBUI_", "WEBUI_", "LITELLM_", "QDRANT_", "SHIELD_", "TOKEN_SPY_", "DASHBOARD_", "N8N_", "LANGFUSE_", "APE_"))})
    return values


def expand(value: str, env: dict[str, str]) -> str:
    pattern = re.compile(r"\$\{([A-Za-z_][A-Za-z0-9_]*)(?::-([^}]*))?\}")

    def repl(match: re.Match[str]) -> str:
        key, default = match.group(1), match.group(2) or ""
        return env.get(key) or default

    return pattern.sub(repl, value)


def load_operator_urls(env: dict[str, str]) -> dict[str, str]:
    data = json.loads(REGISTRY.read_text(encoding="utf-8"))
    return {
        item["capability"]: expand(str(item.get("canonical_url", "")), env)
        for item in data.get("operator_surfaces", [])
    }


def run(cmd: list[str]) -> subprocess.CompletedProcess[str]:
    return subprocess.run(cmd, cwd=ROOT, text=True, capture_output=True, check=False)


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

    services: dict[str, str] = {}
    stripped = text.strip()
    if not stripped:
        return services
    try:
        parsed = json.loads(stripped)
        entries = parsed if isinstance(parsed, list) else [parsed]
    except json.JSONDecodeError:
        entries = [json.loads(line) for line in stripped.splitlines() if line.strip()]
    for item in entries:
        service = str(item.get("Service") or item.get("Name") or item.get("service") or "")
        state = str(item.get("State") or item.get("Status") or item.get("Health") or "").lower()
        health = str(item.get("Health") or "").lower()
        status = "healthy" if "healthy" in (health or state) else ("running" if "running" in state or "up" in state else state or "unknown")
        if service:
            services[service] = status
    return services


def http_probe(url: str, env: dict[str, str], auth: str = "none") -> tuple[bool, str]:
    if not url:
        return True, "no external probe required"
    headers = {}
    if auth == "qdrant" and env.get("QDRANT_API_KEY"):
        headers["api-key"] = env["QDRANT_API_KEY"]
    req = Request(url, headers=headers)
    try:
        with urlopen(req, timeout=TIMEOUT) as response:
            code = response.getcode()
    except HTTPError as exc:
        code = exc.code
    except (OSError, URLError) as exc:
        return False, f"probe failed: {exc}"
    if 200 <= code < 500:
        return True, f"HTTP {code}"
    return False, f"HTTP {code}"


def open_webui_bootstrap(env: dict[str, str]) -> tuple[bool, str]:
    db_path = ROOT / "data" / "open-webui" / "webui.db"
    if db_path.exists():
        try:
            with sqlite3.connect(f"file:{db_path}?mode=ro", uri=True) as conn:
                count = conn.execute("select count(*) from user").fetchone()[0]
        except sqlite3.Error as exc:
            return False, f"cannot inspect Open WebUI users: {exc}"
        if count > 0:
            return True, f"{count} Open WebUI user(s) present"
    if env.get("OPEN_WEBUI_ADMIN_EMAIL") and env.get("OPEN_WEBUI_ADMIN_PASSWORD"):
        return True, "first-admin bootstrap configured; recreate open-webui if DB is empty"
    return False, "set Open WebUI first-admin env values before recreating open-webui"


def auth_state(capability: Capability, env: dict[str, str]) -> tuple[bool, str]:
    if capability.capability == "Open WebUI":
        if env.get("WEBUI_AUTH", "true").lower() != "true":
            return False, "WEBUI_AUTH must remain true"
        if env.get("WEBUI_ENABLE_SIGNUP", "false").lower() != "false":
            return False, "WEBUI_ENABLE_SIGNUP must remain false"
        return open_webui_bootstrap(env)
    if capability.capability == "n8n Workflows":
        return bool(env.get("N8N_USER") and env.get("N8N_PASS")), "n8n credentials configured" if env.get("N8N_USER") and env.get("N8N_PASS") else "set n8n credentials"
    if capability.capability == "Langfuse Observability":
        ok = bool(env.get("LANGFUSE_INIT_USER_EMAIL") and env.get("LANGFUSE_INIT_USER_PASSWORD"))
        return ok, "Langfuse init credentials configured" if ok else "set Langfuse init credentials"
    return True, capability.auth


def evaluate(json_mode: bool = False) -> list[dict[str, Any]]:
    env = read_env()
    operator_urls = load_operator_urls(env)
    service_health = compose_ps()
    rows: list[dict[str, Any]] = []
    for cap in CAPABILITIES:
        health_values = [service_health.get(service, "unknown") for service in cap.services if not service.startswith("ms-qr1-")]
        container_ok = all(value == "healthy" for value in health_values) if health_values else True
        local_url = expand(cap.local_url, env)
        probe_ok, probe_reason = http_probe(local_url, env, cap.probe_auth)
        auth_ok, auth_reason = auth_state(cap, env)
        deps = {dep: service_health.get(dep, "external" if dep == "ollama-host" else "unknown") for dep in cap.dependencies}
        deps_ok = all(value in {"healthy", "external"} for value in deps.values())
        canonical_url = operator_urls.get(cap.capability, cap.canonical_url)
        reachable = "yes" if canonical_url else ("loopback-only" if cap.role == "operator-facing" else "internal-only")
        ok = container_ok and probe_ok and auth_ok and deps_ok
        reason_parts = []
        if not container_ok:
            reason_parts.append(f"container health={health_values}")
        if not probe_ok:
            reason_parts.append(probe_reason)
        if not auth_ok:
            reason_parts.append(auth_reason)
        if not deps_ok:
            reason_parts.append(f"dependencies={deps}")
        rows.append({
            "capability": cap.capability,
            "services": ",".join(cap.services),
            "role": cap.role,
            "container_health": ",".join(health_values) if health_values else "external/host",
            "functional_probe": probe_reason,
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
        ("Health", "container_health", 18),
        ("Probe", "functional_probe", 18),
        ("Auth/bootstrap", "auth_bootstrap_state", 32),
        ("Operator reachable", "operator_reachable", 18),
        ("Result", "result", 6),
        ("Reason / next action", "reason_next_action", 40),
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


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--json", action="store_true", help="emit machine-readable JSON")
    parser.add_argument("--self-test", action="store_true", help="validate static registry/classification")
    args = parser.parse_args()

    if args.self_test:
        rows = evaluate(json_mode=True)
        names = {row["capability"] for row in rows}
        required = {"Open WebUI", "LiteLLM Gateway", "Hermes Operator Surface", "Qdrant Vector Store"}
        missing = sorted(required - names)
        if missing:
            print(f"missing readiness capabilities: {missing}", file=sys.stderr)
            return 1
        print("QR1 operator readiness self-test passed")
        return 0

    rows = evaluate(json_mode=args.json)
    if args.json:
        print(json.dumps({"capabilities": rows}, indent=2, sort_keys=True))
    else:
        print_table(rows)
    return 0 if all(row["result"] == "PASS" for row in rows) else 1


if __name__ == "__main__":
    sys.exit(main())
