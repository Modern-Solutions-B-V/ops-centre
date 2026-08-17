#!/usr/bin/env python3
"""HTTP-aware QR1 Ollama bridge.

The bridge listens only on addresses supplied by ms-qr1-ollama-bridge.sh and
forwards every request to host-native Ollama on loopback. It rewrites Host so
Ollama sees an accepted local host value while preserving streaming responses.
"""

from __future__ import annotations

import argparse
import http.client
import http.server
import json
import socket
import socketserver
import sys
import threading
import time
import urllib.request
from contextlib import contextmanager
from http import HTTPStatus
from typing import ClassVar

DEFAULT_MAX_BODY_BYTES = 256 * 1024 * 1024
DEFAULT_UPSTREAM_TIMEOUT_SECONDS = 300
STREAM_READ_SIZE = 65536
REQUEST_READ_SIZE = 8192

HOP_BY_HOP_HEADERS = {
    "connection",
    "keep-alive",
    "proxy-authenticate",
    "proxy-authorization",
    "te",
    "trailer",
    "transfer-encoding",
    "upgrade",
}

SUPPRESSED_UPSTREAM_RESPONSE_HEADERS = HOP_BY_HOP_HEADERS | {"server", "date"}


class BadRequestError(Exception):
    pass


class PayloadTooLargeError(Exception):
    pass


class ClientDisconnected(Exception):
    pass


def parse_host_port(value: str) -> tuple[str, int]:
    host, sep, port = value.rpartition(":")
    if not sep or not host or not port:
        raise argparse.ArgumentTypeError(f"expected host:port, got {value!r}")
    return host, int(port)


def parse_content_length(value: str) -> int:
    try:
        body_length = int(value)
    except ValueError as exc:
        raise BadRequestError("malformed Content-Length") from exc
    if body_length < 0:
        raise BadRequestError("negative Content-Length")
    return body_length


def stream_fixed_request_body(rfile, conn: http.client.HTTPConnection, body_length: int, max_body_bytes: int) -> None:
    if body_length > max_body_bytes:
        raise PayloadTooLargeError("request body exceeds configured limit")
    remaining = body_length
    while remaining:
        chunk = rfile.read(min(REQUEST_READ_SIZE, remaining))
        if not chunk:
            raise BadRequestError("unexpected EOF in request body")
        conn.send(chunk)
        remaining -= len(chunk)


def stream_chunked_request_body(rfile, conn: http.client.HTTPConnection, max_body_bytes: int) -> None:
    total = 0
    while True:
        size_line = rfile.readline(65536)
        if not size_line:
            raise BadRequestError("unexpected EOF in chunked request")
        try:
            size = int(size_line.split(b";", 1)[0].strip(), 16)
        except ValueError as exc:
            raise BadRequestError("malformed chunk size") from exc
        if size < 0:
            raise BadRequestError("negative chunk size")
        if size == 0:
            conn.send(b"0\r\n")
            while True:
                trailer = rfile.readline(65536)
                if trailer in {b"\r\n", b"\n", b""}:
                    conn.send(b"\r\n")
                    return
                conn.send(trailer)
        if total + size > max_body_bytes:
            raise PayloadTooLargeError("request body exceeds configured limit")
        conn.send(size_line)
        remaining = size
        while remaining:
            chunk = rfile.read(min(REQUEST_READ_SIZE, remaining))
            if not chunk:
                raise BadRequestError("unexpected EOF in chunked request")
            conn.send(chunk)
            remaining -= len(chunk)
        total += size
        terminator = rfile.read(2)
        if terminator != b"\r\n":
            raise BadRequestError("malformed chunk terminator")
        conn.send(terminator)


class ThreadingHTTPServer(socketserver.ThreadingMixIn, http.server.HTTPServer):
    daemon_threads = True
    allow_reuse_address = True


class OllamaProxyHandler(http.server.BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    server_version = "MSQR1OllamaProxy/1.0"

    def handle(self) -> None:
        try:
            super().handle()
        except (BrokenPipeError, ConnectionResetError):
            self.close_connection = True

    def log_message(self, fmt: str, *args) -> None:
        sys.stderr.write(f"{self.client_address[0]} - - [{self.log_date_time_string()}] {fmt % args}\n")

    def do_DELETE(self) -> None:
        self.proxy()

    def do_GET(self) -> None:
        self.proxy()

    def do_HEAD(self) -> None:
        self.proxy()

    def do_OPTIONS(self) -> None:
        self.proxy()

    def do_PATCH(self) -> None:
        self.proxy()

    def do_POST(self) -> None:
        self.proxy()

    def do_PUT(self) -> None:
        self.proxy()

    def request_body_mode(self) -> tuple[str, int | None]:
        transfer_encoding = self.headers.get("Transfer-Encoding", "")
        content_lengths = self.headers.get_all("Content-Length", [])
        if len(content_lengths) > 1:
            raise BadRequestError("duplicate Content-Length")
        if "chunked" in transfer_encoding.lower():
            return "chunked", None
        length = content_lengths[0] if content_lengths else None
        if length is None:
            return "none", None
        body_length = parse_content_length(length)
        if body_length > self.server.max_body_bytes:
            raise PayloadTooLargeError("request body exceeds configured limit")
        return "fixed", body_length

    def body_forbidden(self, status: int) -> bool:
        return self.command == "HEAD" or 100 <= status <= 199 or status in {204, 304}

    def read_response_chunk(self, response: http.client.HTTPResponse) -> bytes:
        return response.read1(STREAM_READ_SIZE)

    def write_bytes(self, payload: bytes) -> None:
        try:
            self.wfile.write(payload)
            self.wfile.flush()
        except (BrokenPipeError, ConnectionResetError) as exc:
            raise ClientDisconnected from exc

    def fail_before_response(self, status: HTTPStatus, message: str) -> None:
        try:
            self.send_error(status.value, message)
        except (BrokenPipeError, ConnectionResetError):
            self.close_connection = True

    def proxy(self) -> None:
        upstream_host, upstream_port = self.server.upstream
        upstream_host_header = self.server.upstream_host_header
        response_started = False
        conn = http.client.HTTPConnection(upstream_host, upstream_port, timeout=self.server.upstream_timeout)
        try:
            body_mode, body_length = self.request_body_mode()
            headers = [
                (key, value)
                for key, value in self.headers.items()
                if key.lower() not in HOP_BY_HOP_HEADERS
                and key.lower() not in {"host", "content-length"}
            ]
            headers.append(("Host", upstream_host_header))

            conn.putrequest(self.command, self.path, skip_host=True, skip_accept_encoding=True)
            for key, value in headers:
                conn.putheader(key, value)
            if body_mode == "fixed":
                conn.putheader("Content-Length", str(body_length))
            elif body_mode == "chunked":
                conn.putheader("Transfer-Encoding", "chunked")
            conn.endheaders()
            if body_mode == "fixed":
                stream_fixed_request_body(self.rfile, conn, int(body_length or 0), self.server.max_body_bytes)
            elif body_mode == "chunked":
                stream_chunked_request_body(self.rfile, conn, self.server.max_body_bytes)
            response = conn.getresponse()

            response_headers = [
                (key, value)
                for key, value in response.getheaders()
                if key.lower() not in SUPPRESSED_UPSTREAM_RESPONSE_HEADERS
            ]
            upstream_chunked = response.getheader("Transfer-Encoding", "").lower() == "chunked"
            has_length = any(key.lower() == "content-length" for key, _ in response_headers)
            body_forbidden = self.body_forbidden(response.status)
            stream_to_client = not body_forbidden and (upstream_chunked or not has_length)
            fixed_response_length: int | None = None
            if not body_forbidden and has_length and not upstream_chunked:
                try:
                    fixed_response_length = int(response.getheader("Content-Length", ""))
                except ValueError:
                    fixed_response_length = None

            self.send_response(response.status, response.reason)
            for key, value in response_headers:
                self.send_header(key, value)
            if body_forbidden:
                self.send_header("Connection", "close")
            elif stream_to_client:
                self.send_header("Transfer-Encoding", "chunked")
            self.end_headers()
            response_started = True

            if body_forbidden:
                return

            forwarded_bytes = 0
            while True:
                chunk = self.read_response_chunk(response)
                if not chunk:
                    break
                forwarded_bytes += len(chunk)
                if stream_to_client:
                    self.write_bytes(f"{len(chunk):x}\r\n".encode("ascii"))
                    self.write_bytes(chunk)
                    self.write_bytes(b"\r\n")
                else:
                    self.write_bytes(chunk)
            if stream_to_client:
                self.write_bytes(b"0\r\n\r\n")
            elif fixed_response_length is not None and forwarded_bytes < fixed_response_length:
                self.close_connection = True
        except BadRequestError as exc:
            if not response_started:
                self.fail_before_response(HTTPStatus.BAD_REQUEST, str(exc))
            self.close_connection = True
        except PayloadTooLargeError as exc:
            if not response_started:
                self.fail_before_response(HTTPStatus.REQUEST_ENTITY_TOO_LARGE, str(exc))
            self.close_connection = True
        except ClientDisconnected:
            self.close_connection = True
        except (http.client.HTTPException, OSError, TimeoutError) as exc:
            if not response_started:
                self.fail_before_response(HTTPStatus.BAD_GATEWAY, f"upstream Ollama proxy error: {exc}")
            self.close_connection = True
        finally:
            conn.close()


def make_server(
    listen_addr: str,
    listen_port: int,
    upstream: tuple[str, int],
    upstream_host_header: str,
    max_body_bytes: int = DEFAULT_MAX_BODY_BYTES,
    upstream_timeout: int = DEFAULT_UPSTREAM_TIMEOUT_SECONDS,
):
    server = ThreadingHTTPServer((listen_addr, listen_port), OllamaProxyHandler)
    server.upstream = upstream
    server.upstream_host_header = upstream_host_header
    server.max_body_bytes = max_body_bytes
    server.upstream_timeout = upstream_timeout
    return server


def serve(args: argparse.Namespace) -> None:
    upstream = parse_host_port(args.upstream)
    servers = [
        make_server(
            addr,
            args.listen_port,
            upstream,
            args.upstream_host_header,
            args.max_body_bytes,
            args.upstream_timeout,
        )
        for addr in args.listen_addr
    ]
    for server in servers:
        thread = threading.Thread(target=server.serve_forever, daemon=True)
        thread.start()
        host, port = server.server_address[:2]
        print(f"listening on {host}:{port} -> {args.upstream} Host:{args.upstream_host_header}", flush=True)
    try:
        while True:
            time.sleep(3600)
    except KeyboardInterrupt:
        pass
    finally:
        for server in servers:
            server.shutdown()
            server.server_close()


class RecordingOllamaHandler(http.server.BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    seen_hosts: ClassVar[list[str]] = []
    request_stream_start: ClassVar[float | None] = None

    def handle(self) -> None:
        try:
            super().handle()
        except (BrokenPipeError, ConnectionResetError):
            return

    def log_message(self, fmt: str, *args) -> None:
        return

    def do_GET(self) -> None:
        self.__class__.seen_hosts.append(self.headers.get("Host", ""))
        if self.path == "/no-content":
            self.send_response(204)
            self.send_header("Server", "upstream-server")
            self.send_header("Date", "Mon, 01 Jan 2024 00:00:00 GMT")
            self.end_headers()
            return
        if self.path == "/not-modified":
            self.send_response(304)
            self.end_headers()
            return
        if self.path == "/short-fixed":
            payload = b"short"
            self.send_response(200)
            self.send_header("Content-Type", "application/octet-stream")
            self.send_header("Content-Length", "64")
            self.end_headers()
            self.wfile.write(payload)
            self.wfile.flush()
            self.close_connection = True
            return
        payload = json.dumps({"models": [{"name": "qwen3.8:27b"}]}).encode()
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Set-Cookie", "a=1")
        self.send_header("Set-Cookie", "b=2")
        self.send_header("Server", "upstream-server")
        self.send_header("Content-Length", str(len(payload)))
        self.end_headers()
        self.wfile.write(payload)

    def do_HEAD(self) -> None:
        self.__class__.seen_hosts.append(self.headers.get("Host", ""))
        self.send_response(200)
        self.send_header("Content-Length", "123")
        self.end_headers()

    def do_POST(self) -> None:
        self.__class__.seen_hosts.append(self.headers.get("Host", ""))
        if self.path == "/timed-request-body":
            length = int(self.headers.get("Content-Length", "0"))
            first = self.rfile.read(1)
            self.__class__.request_stream_start = time.monotonic()
            remaining = max(length - len(first), 0)
            while remaining:
                chunk = self.rfile.read(min(STREAM_READ_SIZE, remaining))
                if not chunk:
                    break
                remaining -= len(chunk)
            payload = b'{"ok":true}'
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(payload)))
            self.end_headers()
            self.wfile.write(payload)
            return
        self.send_response(200)
        self.send_header("Content-Type", "application/x-ndjson")
        self.send_header("Transfer-Encoding", "chunked")
        self.end_headers()
        if self.path == "/disconnect":
            payload = b'{"response":"partial"}\n'
            self.wfile.write(f"{len(payload):x}\r\n".encode("ascii"))
            self.wfile.write(payload)
            self.wfile.write(b"\r\n")
            self.wfile.flush()
            self.close_connection = True
            return
        for payload in [b'{"response":"one"}\n', b'{"response":"two","done":true}\n']:
            self.wfile.write(f"{len(payload):x}\r\n".encode("ascii"))
            self.wfile.write(payload)
            self.wfile.write(b"\r\n")
            self.wfile.flush()
            if self.path in {"/api/generate", "/v1/chat/completions"}:
                time.sleep(1.1)
        self.wfile.write(b"0\r\n\r\n")
        self.wfile.flush()


@contextmanager
def background_server(server):
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    try:
        yield server
    finally:
        server.shutdown()
        server.server_close()


def self_test() -> None:
    RecordingOllamaHandler.seen_hosts = []
    RecordingOllamaHandler.request_stream_start = None
    upstream = ThreadingHTTPServer(("127.0.0.1", 0), RecordingOllamaHandler)
    upstream_port = upstream.server_address[1]
    proxy = make_server(
        "127.0.0.1",
        0,
        ("127.0.0.1", upstream_port),
        "localhost:11434",
    )
    proxy_port = proxy.server_address[1]

    with background_server(upstream), background_server(proxy):
        request = urllib.request.Request(
            f"http://127.0.0.1:{proxy_port}/api/tags",
            headers={"Host": "ms-qr1-host:11434"},
        )
        with urllib.request.urlopen(request, timeout=5) as response:
            assert response.status == 200
            assert response.headers.get_all("Set-Cookie") == ["a=1", "b=2"]
            assert response.headers.get_all("Server") == ["MSQR1OllamaProxy/1.0 Python/" + sys.version.split()[0]]
            assert json.loads(response.read())["models"][0]["name"] == "qwen3.8:27b"

        for path, marker in [("/api/generate", b'"response":"one"'), ("/v1/chat/completions", b'"response":"one"')]:
            first_elapsed, final_elapsed, body = read_timed_stream(
                proxy_port,
                path,
                b'{"model":"qwen3.8:27b","prompt":"x","stream":true}',
            )
            assert marker in body
            assert first_elapsed < 0.5, first_elapsed
            assert final_elapsed >= 1.0, final_elapsed

        assert_no_body_response(proxy_port, "GET", "/no-content", 204)
        assert_no_body_response(proxy_port, "GET", "/not-modified", 304)
        assert_no_body_response(proxy_port, "HEAD", "/api/tags", 200)
        assert_malformed_content_length(proxy_port)
        assert_duplicate_content_length(proxy_port)
        assert_malformed_chunk(proxy_port)
        assert_body_too_large(upstream_port)
        assert_request_body_streaming(proxy_port)
        assert_client_disconnect(proxy_port)
        assert_upstream_disconnect_no_second_status(proxy_port)
        assert_truncated_fixed_response_closes(proxy_port)

    assert RecordingOllamaHandler.seen_hosts[:3] == [
        "localhost:11434",
        "localhost:11434",
        "localhost:11434",
    ], RecordingOllamaHandler.seen_hosts


def read_chunk_from_response(response: http.client.HTTPResponse) -> bytes:
    size_line = response.fp.readline()
    size = int(size_line.split(b";", 1)[0], 16)
    if size == 0:
        response.fp.readline()
        return b""
    data = response.fp.read(size)
    response.fp.read(2)
    return data


def read_timed_stream(proxy_port: int, path: str, body: bytes) -> tuple[float, float, bytes]:
    conn = http.client.HTTPConnection("127.0.0.1", proxy_port, timeout=5)
    start = time.monotonic()
    conn.request(
        "POST",
        path,
        body=body,
        headers={"Host": "ms-qr1-host:11434", "Content-Type": "application/json"},
    )
    response = conn.getresponse()
    assert response.status == 200
    assert response.getheader("Transfer-Encoding") == "chunked"
    first = read_chunk_from_response(response)
    first_elapsed = time.monotonic() - start
    second = read_chunk_from_response(response)
    final_elapsed = time.monotonic() - start
    conn.close()
    return first_elapsed, final_elapsed, first + second


def assert_no_body_response(proxy_port: int, method: str, path: str, status: int) -> None:
    conn = http.client.HTTPConnection("127.0.0.1", proxy_port, timeout=5)
    conn.request(method, path, headers={"Host": "ms-qr1-host:11434"})
    response = conn.getresponse()
    assert response.status == status
    assert response.getheader("Transfer-Encoding") is None
    assert response.read() == b""
    conn.close()


def raw_request(proxy_port: int, payload: bytes, read_size: int = 4096) -> bytes:
    with socket.create_connection(("127.0.0.1", proxy_port), timeout=5) as sock:
        sock.sendall(payload)
        sock.shutdown(socket.SHUT_WR)
        return sock.recv(read_size)


def assert_malformed_content_length(proxy_port: int) -> None:
    response = raw_request(
        proxy_port,
        b"POST /api/generate HTTP/1.1\r\nHost: ms-qr1-host:11434\r\nContent-Length: nope\r\n\r\nx",
    )
    assert b" 400 " in response.split(b"\r\n", 1)[0], response


def assert_duplicate_content_length(proxy_port: int) -> None:
    response = raw_request(
        proxy_port,
        b"POST /api/generate HTTP/1.1\r\n"
        b"Host: ms-qr1-host:11434\r\n"
        b"Content-Length: 2\r\n"
        b"Content-Length: 4\r\n\r\n"
        b"{}{}",
    )
    assert b" 400 " in response.split(b"\r\n", 1)[0], response


def assert_malformed_chunk(proxy_port: int) -> None:
    response = raw_request(
        proxy_port,
        b"POST /api/generate HTTP/1.1\r\nHost: ms-qr1-host:11434\r\nTransfer-Encoding: chunked\r\n\r\nzz\r\nx\r\n0\r\n\r\n",
    )
    assert b" 400 " in response.split(b"\r\n", 1)[0], response


def assert_body_too_large(upstream_port: int) -> None:
    small_proxy = make_server(
        "127.0.0.1",
        0,
        ("127.0.0.1", upstream_port),
        "localhost:11434",
        max_body_bytes=4,
    )
    with background_server(small_proxy):
        response = raw_request(
            small_proxy.server_address[1],
            b"POST /api/generate HTTP/1.1\r\nHost: ms-qr1-host:11434\r\nContent-Length: 5\r\n\r\n12345",
        )
        assert b" 413 " in response.split(b"\r\n", 1)[0], response


def assert_request_body_streaming(proxy_port: int) -> None:
    first = b"x" * 8192
    second = b"y" * 8192
    body_length = len(first) + len(second)
    start = time.monotonic()
    with socket.create_connection(("127.0.0.1", proxy_port), timeout=5) as sock:
        sock.sendall(
            b"POST /timed-request-body HTTP/1.1\r\n"
            b"Host: ms-qr1-host:11434\r\n"
            + f"Content-Length: {body_length}\r\n".encode("ascii")
            + b"Content-Type: application/octet-stream\r\n\r\n"
        )
        sock.sendall(first)
        time.sleep(1.1)
        sock.sendall(second)
        response = sock.recv(4096)
    assert b" 200 " in response.split(b"\r\n", 1)[0], response
    assert RecordingOllamaHandler.request_stream_start is not None
    assert RecordingOllamaHandler.request_stream_start - start < 0.5


def assert_client_disconnect(proxy_port: int) -> None:
    with socket.create_connection(("127.0.0.1", proxy_port), timeout=5) as sock:
        sock.sendall(
            b"POST /api/generate HTTP/1.1\r\n"
            b"Host: ms-qr1-host:11434\r\n"
            b"Content-Length: 46\r\n"
            b"Content-Type: application/json\r\n\r\n"
            b'{"model":"qwen3.8:27b","prompt":"x","stream":true}'
        )
        sock.recv(128)
    time.sleep(0.2)


def assert_upstream_disconnect_no_second_status(proxy_port: int) -> None:
    with socket.create_connection(("127.0.0.1", proxy_port), timeout=5) as sock:
        sock.sendall(
            b"POST /disconnect HTTP/1.1\r\n"
            b"Host: ms-qr1-host:11434\r\n"
            b"Content-Length: 2\r\n\r\n{}"
        )
        sock.settimeout(5)
        data = bytearray()
        while True:
            try:
                chunk = sock.recv(4096)
            except TimeoutError:
                break
            if not chunk:
                break
            data.extend(chunk)
    assert data.count(b"HTTP/1.1 ") == 1, data


def assert_truncated_fixed_response_closes(proxy_port: int) -> None:
    start = time.monotonic()
    with socket.create_connection(("127.0.0.1", proxy_port), timeout=5) as sock:
        sock.sendall(b"GET /short-fixed HTTP/1.1\r\nHost: ms-qr1-host:11434\r\n\r\n")
        sock.settimeout(1.0)
        data = bytearray()
        while True:
            chunk = sock.recv(4096)
            if not chunk:
                break
            data.extend(chunk)
    elapsed = time.monotonic() - start
    assert elapsed < 1.0, elapsed
    assert data.count(b"HTTP/1.1 ") == 1, data
    assert b"Content-Length: 64" in data, data
    assert data.endswith(b"short"), data


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--listen-addr", action="append", default=[])
    parser.add_argument("--listen-port", type=int, default=11434)
    parser.add_argument("--upstream", default="127.0.0.1:11434")
    parser.add_argument("--upstream-host-header", default="localhost:11434")
    parser.add_argument("--max-body-bytes", type=int, default=DEFAULT_MAX_BODY_BYTES)
    parser.add_argument("--upstream-timeout", type=int, default=DEFAULT_UPSTREAM_TIMEOUT_SECONDS)
    parser.add_argument("--self-test", action="store_true")
    args = parser.parse_args()

    if args.self_test:
        self_test()
        return 0
    if not args.listen_addr:
        parser.error("--listen-addr is required unless --self-test is used")
    serve(args)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
