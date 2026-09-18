#!/usr/bin/env python3
"""Maintained-connection acceptance check for PhoneLanProxy.

Holds one CONNECT tunnel open across the whole run and reuses it for every
request.  A pass therefore proves an already-established connection survived,
which background_acceptance.py deliberately does not test: that script opens a
fresh connection for every check.

The recorded connect_count is the number of CONNECT tunnels the client has
opened.  connect_count == 1 at the end means the Mac-to-phone TCP connection
and the phone-to-origin TCP connection were both held for the entire run.  A
value that grows means a hop was torn down and rebuilt; the run can still pass
(the proxy stayed reachable), but it is weaker evidence and must be reported as
such rather than counted as a held connection.
"""

from __future__ import annotations

import argparse
import http.client
import json
import ssl
import sys
import time
from datetime import datetime, timezone
from pathlib import Path
from urllib.parse import urlsplit


TIMEOUT = 10.0


class CheckError(RuntimeError):
    def __init__(self, category: str) -> None:
        super().__init__(category)
        self.category = category


class CountingHTTPSConnection(http.client.HTTPSConnection):
    """HTTPS connection that records how many tunnels it has opened.

    _tunnel is overridden because http.client hardcodes an HTTP/1.0 CONNECT
    request and PhoneLanProxy answers those with 505.  Sending HTTP/1.1 keeps
    the check measuring the proxy's background behaviour rather than its
    version handling.  Over-reading is not a risk here: the proxy sends only
    the CONNECT response and waits, because no TLS bytes are sent until this
    method returns.
    """

    def __init__(self, *args, **kwargs) -> None:
        super().__init__(*args, **kwargs)
        self.connect_count = 0

    def connect(self) -> None:
        self.connect_count += 1
        super().connect()

    def _tunnel(self) -> None:
        host = self._tunnel_host
        port = self._tunnel_port
        authority = f"{host}:{port}"
        self.sock.sendall(
            f"CONNECT {authority} HTTP/1.1\r\nHost: {authority}\r\n\r\n".encode("ascii")
        )
        received = bytearray()
        while b"\r\n\r\n" not in received:
            chunk = self.sock.recv(4096)
            if not chunk:
                self.close()
                raise OSError("tunnel closed before CONNECT response")
            received.extend(chunk)
        status_line = bytes(received).split(b"\r\n", 1)[0]
        parts = status_line.split(b" ", 2)
        if len(parts) < 2 or not parts[1].isdigit() or int(parts[1]) != 200:
            self.close()
            raise OSError(f"Tunnel connection failed: {status_line.decode('latin-1')}")


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


def target_parts(url: str) -> tuple[str, int, str, str]:
    parsed = urlsplit(url)
    if parsed.scheme.lower() != "https" or not parsed.hostname:
        raise CheckError("invalid_url")
    if parsed.username is not None or parsed.password is not None:
        raise CheckError("invalid_url")
    try:
        port = parsed.port or 443
    except ValueError as exc:
        raise CheckError("invalid_url") from exc
    host = parsed.hostname
    path = parsed.path or "/"
    if parsed.query:
        path += "?" + parsed.query
    return host, port, path, url


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
    parser.add_argument("--interval-seconds", type=positive, default=30.0)
    parser.add_argument("--output", required=True, type=Path, help="JSONL output path")
    args = parser.parse_args()

    try:
        host, port, path, _ = target_parts(args.url)
    except CheckError as exc:
        print(f"invalid --url: {exc.category}", file=sys.stderr)
        return 2

    args.output.parent.mkdir(parents=True, exist_ok=True)
    start = time.monotonic()
    connection = CountingHTTPSConnection(
        args.proxy[0],
        args.proxy[1],
        timeout=TIMEOUT,
        context=ssl.create_default_context(),
    )
    connection.set_tunnel(host, port)

    count = 0
    with args.output.open("w", encoding="utf-8", buffering=1) as output:
        def emit(phase: str, code: int | None = None, error: str | None = None) -> None:
            nonlocal count
            record = {
                "timestamp": datetime.now(timezone.utc).isoformat(),
                "phase": phase,
                "http_status": code,
                "error": error,
                "connect_count": connection.connect_count,
            }
            output.write(json.dumps(record, ensure_ascii=False) + "\n")
            output.flush()
            count += 1

        def check(phase: str) -> bool:
            try:
                connection.request(
                    "GET", path, headers={"Connection": "keep-alive"}
                )
                response = connection.getresponse()
                response.read()
                code = response.status
            except ssl.SSLError as exc:
                emit(phase, error=f"tls: {exc}")
                return False
            except (http.client.HTTPException, OSError) as exc:
                emit(phase, error=type(exc).__name__)
                return False
            emit(phase, code=code)
            return True

        if not check("baseline"):
            print("baseline failed; stopped", file=sys.stderr)
            return 1

        target_end = start + args.duration_seconds
        next_test = start + args.interval_seconds
        while next_test <= target_end:
            wait_until(next_test)
            if not check("test"):
                print("test failed; stopped", file=sys.stderr)
                return 1
            next_test += args.interval_seconds

    tunnels = connection.connect_count
    connection.close()
    held = "held for the whole run" if tunnels == 1 else f"rebuilt {tunnels - 1}x"
    print(f"maintained-connection checks: {count}; tunnels: {tunnels} ({held}); "
          f"JSONL: {args.output}")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except KeyboardInterrupt:
        print("interrupted; stopped", file=sys.stderr)
        raise SystemExit(130)
