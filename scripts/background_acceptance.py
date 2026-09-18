#!/usr/bin/env python3
"""Bounded HTTPS-over-HTTP-proxy acceptance check for PhoneLanProxy.

This checks newly established HTTPS connections only.  It does not prove that
the app stayed alive while the phone was locked, or test SSH/long connections.
"""

from __future__ import annotations

import argparse
import json
import re
import socket
import ssl
import sys
import time
from datetime import datetime, timezone
from pathlib import Path
from urllib.parse import urlsplit


TIMEOUT = 10.0
HEADER_LIMIT = 64 * 1024
STATUS_RE = re.compile(rb"^HTTP/\d(?:\.\d)?\s+(\d{3})(?:\s|$)")


class CheckError(RuntimeError):
    def __init__(self, category: str, socket_new: bool = False) -> None:
        super().__init__(category)
        self.category = category
        self.socket_new = socket_new


def positive(value: str) -> float:
    try:
        number = float(value)
    except ValueError as exc:
        raise argparse.ArgumentTypeError("must be a positive number") from exc
    if number <= 0:
        raise argparse.ArgumentTypeError("must be a positive number")
    return number


def endpoint(value: str) -> tuple[str, int]:
    if value.startswith("["):
        host, separator, port = value[1:].partition("]:")
    else:
        host, separator, port = value.rpartition(":")
    if not separator or not host:
        raise argparse.ArgumentTypeError("proxy must be HOST:PORT or [IPv6]:PORT")
    try:
        number = int(port)
    except ValueError as exc:
        raise argparse.ArgumentTypeError("proxy port must be an integer") from exc
    if not 1 <= number <= 65535:
        raise argparse.ArgumentTypeError("proxy port must be 1..65535")
    return host, number


def read_headers(connection: socket.socket) -> bytes:
    data = bytearray()
    while len(data) < HEADER_LIMIT:
        chunk = connection.recv(min(8192, HEADER_LIMIT - len(data)))
        if not chunk:
            raise CheckError("response_read")
        data.extend(chunk)
        if b"\r\n\r\n" in data:
            return bytes(data)
    raise CheckError("response_read")


def status(headers: bytes) -> int:
    match = STATUS_RE.match(headers.split(b"\r\n", 1)[0])
    if match is None:
        raise CheckError("response_read")
    return int(match.group(1))


def https_request(proxy: tuple[str, int], target: str) -> int:
    parsed = urlsplit(target)
    if parsed.scheme.lower() != "https" or not parsed.hostname:
        raise CheckError("invalid_url")
    if parsed.username is not None or parsed.password is not None:
        raise CheckError("invalid_url")
    try:
        port = parsed.port or 443
    except ValueError as exc:
        raise CheckError("invalid_url") from exc
    host = parsed.hostname
    try:
        server_name = host.encode("idna").decode("ascii")
    except UnicodeError as exc:
        raise CheckError("invalid_url") from exc
    authority_host = f"[{server_name}]" if ":" in server_name else server_name
    authority = f"{authority_host}:{port}"
    path = parsed.path or "/"
    if parsed.query:
        path += "?" + parsed.query

    connection: socket.socket | None = None
    socket_new = False
    try:
        try:
            connection = socket.create_connection(proxy, timeout=TIMEOUT)
            socket_new = True
            connection.settimeout(TIMEOUT)
        except socket.timeout as exc:
            raise CheckError("proxy_connect_timeout") from exc
        except OSError as exc:
            raise CheckError("proxy_connect") from exc
        connect_request = (
            f"CONNECT {authority} HTTP/1.1\r\nHost: {authority}\r\n"
            "Proxy-Connection: close\r\n\r\n"
        ).encode("ascii")
        try:
            connection.sendall(connect_request)
            connect_status = status(read_headers(connection))
        except socket.timeout as exc:
            raise CheckError("connect_timeout", socket_new) from exc
        except (OSError, CheckError) as exc:
            if isinstance(exc, CheckError):
                exc.socket_new = socket_new
                raise
            raise CheckError("connect_request", socket_new) from exc
        if not 200 <= connect_status < 300:
            raise CheckError("connect_rejected", socket_new)
        try:
            context = ssl.create_default_context()
            secure = context.wrap_socket(connection, server_hostname=server_name)
            connection = secure
            request = (
                f"GET {path} HTTP/1.1\r\nHost: {authority}\r\n"
                "Connection: close\r\n\r\n"
            ).encode("ascii")
            secure.sendall(request)
            return status(read_headers(secure))
        except socket.timeout as exc:
            raise CheckError("request_timeout", socket_new) from exc
        except ssl.SSLError as exc:
            raise CheckError("tls", socket_new) from exc
        except (OSError, CheckError) as exc:
            if isinstance(exc, CheckError):
                exc.socket_new = socket_new
                raise
            raise CheckError("request", socket_new) from exc
    finally:
        if connection is not None:
            try:
                connection.close()
            except OSError:
                pass


def wait_until(deadline: float) -> None:
    while True:
        remaining = deadline - time.monotonic()
        if remaining <= 0:
            return
        time.sleep(min(remaining, 1.0))


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--proxy", required=True, type=endpoint, metavar="HOST:PORT")
    parser.add_argument("--url", required=True, help="HTTPS URL to GET")
    parser.add_argument("--duration-seconds", type=positive, default=900.0)
    parser.add_argument("--idle-seconds", type=positive, default=300.0)
    parser.add_argument("--interval-seconds", type=positive, default=60.0)
    parser.add_argument("--output", required=True, type=Path, help="JSONL output path")
    args = parser.parse_args()

    args.output.parent.mkdir(parents=True, exist_ok=True)
    start = time.monotonic()
    count = 0
    with args.output.open("w", encoding="utf-8", buffering=1) as output:
        def emit(phase: str, code: int | None = None, error: str | None = None,
                 socket_new: bool = False) -> None:
            nonlocal count
            record = {"timestamp": datetime.now(timezone.utc).isoformat(),
                      "phase": phase, "http_status": code, "error": error,
                      "socket_new": socket_new}
            output.write(json.dumps(record, ensure_ascii=False) + "\n")
            output.flush()
            count += 1

        def check(phase: str) -> bool:
            try:
                code = https_request(args.proxy, args.url)
            except CheckError as exc:
                emit(phase, error=exc.category, socket_new=exc.socket_new)
                return False
            emit(phase, code=code, socket_new=True)
            return True

        if not check("baseline"):
            print("baseline failed; stopped", file=sys.stderr)
            return 1

        target_end = start + args.duration_seconds
        active_end = target_end - args.idle_seconds
        next_test = start + args.interval_seconds
        while next_test <= active_end:
            wait_until(next_test)
            if not check("test"):
                print("test failed; stopped", file=sys.stderr)
                return 1
            next_test += args.interval_seconds

        idle_start = time.monotonic()
        emit("idle_start")
        final_at = max(target_end, idle_start + args.idle_seconds)
        wait_until(final_at)
        if not check("final"):
            print("final test failed; stopped", file=sys.stderr)
            return 1
        wait_until(target_end)
        emit("complete")

    print(f"accepted HTTPS new-connection checks: {count}; JSONL: {args.output}")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except KeyboardInterrupt:
        print("interrupted; stopped", file=sys.stderr)
        raise SystemExit(130)
