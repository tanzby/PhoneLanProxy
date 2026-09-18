#!/usr/bin/env python3
"""Black-box SOCKS5, HTTP, and HTTPS proxy checks for PhoneLanProxy.

The script starts temporary TCP echo servers and talks to an already-running
SOCKS5 proxy.  It uses only the Python standard library and never changes
proxy-related environment variables or system settings.
"""

from __future__ import annotations

import argparse
import ipaddress
import socket
import sys
import threading
import time
from typing import Callable, Optional


SOCKS_VERSION = 5
NO_AUTH = 0x00
NO_ACCEPTABLE_METHODS = 0xFF

SERVER_BANNER = b"PhoneLanProxy acceptance server ready\n"
EOF_RESPONSE = b"PhoneLanProxy acceptance server saw EOF\n"
HTTP_MARKER = b"PhoneLanProxy HTTP acceptance marker\n"


class AcceptanceError(RuntimeError):
    """A protocol or end-to-end assertion failed."""


def recv_until_headers(connection: socket.socket, maximum_length: int = 64 * 1024) -> bytes:
    headers, _ = recv_headers_and_remainder(connection, maximum_length)
    return headers


def recv_headers_and_remainder(
    connection: socket.socket, maximum_length: int = 64 * 1024
) -> tuple[bytes, bytes]:
    result = bytearray()
    while len(result) < maximum_length:
        chunk = connection.recv(min(64 * 1024, maximum_length - len(result)))
        if not chunk:
            break
        result.extend(chunk)
        delimiter = result.find(b"\r\n\r\n")
        if delimiter >= 0:
            header_end = delimiter + 4
            return bytes(result[:header_end]), bytes(result[header_end:])
    raise AcceptanceError("HTTP headers were not received before EOF or the size limit")


def recv_until_eof(connection: socket.socket) -> bytes:
    result = bytearray()
    while True:
        chunk = connection.recv(64 * 1024)
        if not chunk:
            return bytes(result)
        result.extend(chunk)


class TargetServer:
    """Small TCP echo server used as a SOCKS target.

    The server sends a fixed banner after accepting a connection, echoes all
    bytes from the client, and sends ``EOF_RESPONSE`` only after it observes
    EOF from the client.  It deliberately never logs received bytes.
    """

    def __init__(
        self,
        *,
        bind_host: str,
        advertised_host: str,
        family: socket.AddressFamily,
        timeout: float,
        listen_port: int = 0,
    ) -> None:
        self.bind_host = bind_host
        self.advertised_host = advertised_host
        self.family = family
        self.timeout = timeout
        self.listen_port = listen_port
        self._stop = threading.Event()
        self._lock = threading.Lock()
        self._connections: set[socket.socket] = set()
        self._listener: Optional[socket.socket] = None
        self._thread: Optional[threading.Thread] = None
        self.port: Optional[int] = None

    @property
    def endpoint(self) -> tuple[str, int]:
        if self.port is None:
            raise AcceptanceError("target server is not listening")
        return self.advertised_host, self.port

    def start(self) -> None:
        listener = socket.socket(self.family, socket.SOCK_STREAM)
        listener.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        if self.family == socket.AF_INET6:
            listener.setsockopt(socket.IPPROTO_IPV6, socket.IPV6_V6ONLY, 1)
            address: tuple[object, ...] = (self.bind_host, self.listen_port, 0, 0)
        else:
            address = (self.bind_host, self.listen_port)
        try:
            listener.bind(address)
            listener.listen(32)
            listener.settimeout(0.2)
        except BaseException:
            listener.close()
            raise

        self._listener = listener
        self.port = int(listener.getsockname()[1])
        self._thread = threading.Thread(
            target=self._accept_loop,
            name=f"PhoneLanProxy-target-{self.family}",
            daemon=True,
        )
        self._thread.start()

    def _accept_loop(self) -> None:
        listener = self._listener
        if listener is None:
            return
        while not self._stop.is_set():
            try:
                connection, _ = listener.accept()
            except socket.timeout:
                continue
            except OSError:
                if self._stop.is_set():
                    return
                return

            connection.settimeout(self.timeout)
            with self._lock:
                self._connections.add(connection)
            threading.Thread(
                target=self._handle_connection,
                args=(connection,),
                name=f"PhoneLanProxy-target-client-{self.family}",
                daemon=True,
            ).start()

    def _handle_connection(self, connection: socket.socket) -> None:
        try:
            connection.sendall(SERVER_BANNER)
            while True:
                data = connection.recv(64 * 1024)
                if not data:
                    connection.sendall(EOF_RESPONSE)
                    try:
                        connection.shutdown(socket.SHUT_WR)
                    except OSError:
                        pass
                    return
                connection.sendall(data)
        except (OSError, socket.timeout):
            return
        finally:
            with self._lock:
                self._connections.discard(connection)
            try:
                connection.close()
            except OSError:
                pass

    def close(self) -> None:
        self._stop.set()
        listener = self._listener
        if listener is not None:
            try:
                listener.close()
            except OSError:
                pass

        with self._lock:
            connections = list(self._connections)
        for connection in connections:
            try:
                connection.shutdown(socket.SHUT_RDWR)
            except OSError:
                pass
            try:
                connection.close()
            except OSError:
                pass

        if self._thread is not None:
            self._thread.join(timeout=max(0.2, self.timeout))


class HTTPTargetServer(TargetServer):
    """Small HTTP target that records the forwarded request headers."""

    def __init__(self, **kwargs: object) -> None:
        super().__init__(**kwargs)
        self.last_request: Optional[bytes] = None

    def _handle_connection(self, connection: socket.socket) -> None:
        try:
            request = recv_until_headers(connection)
            with self._lock:
                self.last_request = request
            response = (
                b"HTTP/1.1 200 OK\r\n"
                + b"Content-Length: "
                + str(len(HTTP_MARKER)).encode("ascii")
                + b"\r\nConnection: close\r\n\r\n"
                + HTTP_MARKER
            )
            connection.sendall(response)
            try:
                connection.shutdown(socket.SHUT_WR)
            except OSError:
                pass
        except (OSError, socket.timeout, AcceptanceError):
            return
        finally:
            with self._lock:
                self._connections.discard(connection)
            try:
                connection.close()
            except OSError:
                pass


def parse_ipv4(value: str, option: str) -> str:
    try:
        address = ipaddress.IPv4Address(value)
    except ipaddress.AddressValueError as exc:
        raise argparse.ArgumentTypeError(
            f"{option} must be an IPv4 literal (for example 192.168.1.20)"
        ) from exc
    return str(address)


def parse_ipv6(value: str, option: str) -> str:
    try:
        address = ipaddress.IPv6Address(value)
    except ipaddress.AddressValueError as exc:
        raise argparse.ArgumentTypeError(
            f"{option} must be an IPv6 literal (for example ::1)"
        ) from exc
    return str(address)


def request_bytes(
    *,
    command: int,
    address_type: int,
    host: str,
    port: int,
) -> bytes:
    if not 0 <= command <= 255:
        raise AcceptanceError("invalid SOCKS command in test")
    if not 1 <= port <= 65535:
        raise AcceptanceError("invalid target port")

    if address_type == 1:
        address = ipaddress.IPv4Address(host).packed
    elif address_type == 4:
        address = ipaddress.IPv6Address(host).packed
    elif address_type == 3:
        try:
            address = host.encode("idna")
        except UnicodeError as exc:
            raise AcceptanceError("target domain cannot be encoded") from exc
        if not 1 <= len(address) <= 255:
            raise AcceptanceError("target domain length is outside SOCKS5 limits")
        address = bytes([len(address)]) + address
    else:
        # Unknown ATYP requests intentionally contain no address bytes.  This
        # lets the proxy reject the command without waiting for an invented
        # address layout.
        address = b""

    return bytes([SOCKS_VERSION, command, 0, address_type]) + address + port.to_bytes(
        2, "big"
    )


def recv_exact(connection: socket.socket, length: int) -> bytes:
    if length < 0:
        raise AcceptanceError("invalid receive length")
    result = bytearray()
    while len(result) < length:
        chunk = connection.recv(min(64 * 1024, length - len(result)))
        if not chunk:
            raise AcceptanceError(
                f"connection closed after {len(result)} of {length} expected bytes"
            )
        result.extend(chunk)
    return bytes(result)


def read_socks_reply(connection: socket.socket) -> int:
    header = recv_exact(connection, 4)
    if header[0] != SOCKS_VERSION:
        raise AcceptanceError("SOCKS reply has an unexpected version")

    address_type = header[3]
    if address_type == 1:
        address_length = 4
    elif address_type == 4:
        address_length = 16
    elif address_type == 3:
        address_length = recv_exact(connection, 1)[0]
    else:
        raise AcceptanceError("SOCKS reply has an unsupported address type")
    recv_exact(connection, address_length + 2)
    return header[1]


def send_fragments(
    connection: socket.socket, pieces: list[bytes], timeout: float
) -> None:
    for index, piece in enumerate(pieces):
        if piece:
            connection.sendall(piece)
        if index + 1 < len(pieces):
            # A short gap makes separate writes observable to the proxy's
            # parser while keeping every wait bounded.
            time.sleep(min(0.02, max(0.001, timeout / 20)))


def assert_bytes(label: str, actual: bytes, expected: bytes) -> None:
    if actual != expected:
        raise AcceptanceError(
            f"{label} mismatch (expected {len(expected)} bytes, got {len(actual)})"
        )


def open_proxy(args: argparse.Namespace) -> socket.socket:
    connection = socket.create_connection(
        (args.proxy_host, args.proxy_port), timeout=args.timeout
    )
    connection.settimeout(args.timeout)
    return connection


def test_noauth_rejection(args: argparse.Namespace) -> None:
    with open_proxy(args) as connection:
        connection.sendall(bytes([SOCKS_VERSION, 1, 0x02]))
        response = recv_exact(connection, 2)
        assert_bytes(
            "no-auth rejection", response, bytes([SOCKS_VERSION, NO_ACCEPTABLE_METHODS])
        )


def establish_noauth(
    args: argparse.Namespace, connection: socket.socket, *, fragmented: bool = False
) -> None:
    greeting = bytes([SOCKS_VERSION, 1, NO_AUTH])
    if fragmented:
        send_fragments(connection, [greeting[:1], greeting[1:]], args.timeout)
    else:
        connection.sendall(greeting)
    response = recv_exact(connection, 2)
    assert_bytes("no-auth negotiation", response, bytes([SOCKS_VERSION, NO_AUTH]))


def expect_connect_success(connection: socket.socket) -> None:
    reply = read_socks_reply(connection)
    if reply != 0:
        raise AcceptanceError(f"CONNECT failed with REP 0x{reply:02x}")


def test_unsupported_command(
    args: argparse.Namespace, target: TargetServer, target_ipv4: str
) -> None:
    with open_proxy(args) as connection:
        establish_noauth(args, connection)
        request = request_bytes(
            command=2,
            address_type=1,
            host=target_ipv4,
            port=target.endpoint[1],
        )
        connection.sendall(request)
        reply = read_socks_reply(connection)
        if reply != 0x07:
            raise AcceptanceError(
                f"BIND request returned REP 0x{reply:02x}, expected 0x07"
            )


def test_unsupported_address_type(args: argparse.Namespace) -> None:
    with open_proxy(args) as connection:
        establish_noauth(args, connection)
        connection.sendall(request_bytes(command=1, address_type=9, host="", port=1))
        reply = read_socks_reply(connection)
        if reply != 0x08:
            raise AcceptanceError(
                f"unknown ATYP returned REP 0x{reply:02x}, expected 0x08"
            )


def test_failure_rep(args: argparse.Namespace, target_ipv4: str, port: int) -> None:
    with open_proxy(args) as connection:
        establish_noauth(args, connection)
        request = request_bytes(
            command=1, address_type=1, host=target_ipv4, port=port
        )
        connection.sendall(request)
        # The proxy answers as soon as Network.framework reports the refused
        # port (as `.waiting` or `.failed`); allow a little slack over
        # --timeout for slower simulator/device paths.
        connection.settimeout(max(args.timeout, 5.0))
        reply = read_socks_reply(connection)
        if reply == 0:
            raise AcceptanceError("closed target unexpectedly returned success REP")


def test_ipv4_fragmented(
    args: argparse.Namespace, target: TargetServer, target_ipv4: str
) -> None:
    payload = b"PhoneLanProxy IPv4 fragmented payload"
    with open_proxy(args) as connection:
        establish_noauth(args, connection, fragmented=True)
        request = request_bytes(
            command=1,
            address_type=1,
            host=target_ipv4,
            port=target.endpoint[1],
        )
        send_fragments(connection, [request[:4], request[4:]], args.timeout)
        expect_connect_success(connection)
        assert_bytes(
            "IPv4 target banner",
            recv_exact(connection, len(SERVER_BANNER)),
            SERVER_BANNER,
        )
        connection.sendall(payload)
        assert_bytes("IPv4 echo", recv_exact(connection, len(payload)), payload)


def test_domain_merged(
    args: argparse.Namespace, target: TargetServer
) -> None:
    payload = b"PhoneLanProxy merged handshake payload"
    request = request_bytes(
        command=1,
        address_type=3,
        host=args.target_domain,
        port=target.endpoint[1],
    )
    with open_proxy(args) as connection:
        # One write intentionally contains greeting, request, and first data.
        connection.sendall(bytes([SOCKS_VERSION, 1, NO_AUTH]) + request + payload)
        method_response = recv_exact(connection, 2)
        assert_bytes(
            "merged no-auth negotiation",
            method_response,
            bytes([SOCKS_VERSION, NO_AUTH]),
        )
        expect_connect_success(connection)
        response = recv_exact(connection, len(SERVER_BANNER) + len(payload))
        assert_bytes(
            "domain merged response",
            response,
            SERVER_BANNER + payload,
        )


def test_ipv6(
    args: argparse.Namespace,
    target: Optional[TargetServer],
    target_ipv6: str,
) -> None:
    if target is None:
        raise AcceptanceError("IPv6 target server could not be started")
    payload = b"PhoneLanProxy IPv6 payload"
    with open_proxy(args) as connection:
        establish_noauth(args, connection)
        request = request_bytes(
            command=1,
            address_type=4,
            host=target_ipv6,
            port=target.endpoint[1],
        )
        connection.sendall(request)
        expect_connect_success(connection)
        assert_bytes(
            "IPv6 target banner",
            recv_exact(connection, len(SERVER_BANNER)),
            SERVER_BANNER,
        )
        connection.sendall(payload)
        assert_bytes("IPv6 echo", recv_exact(connection, len(payload)), payload)


def make_large_payload(length: int) -> bytes:
    # Deterministic, non-repeating enough data catches truncation and ordering
    # errors without printing or persisting any received payload.
    return bytes((index * 31 + 17) % 251 for index in range(length))


def test_large_half_close(
    args: argparse.Namespace, target: TargetServer, target_ipv4: str
) -> None:
    payload = make_large_payload(args.large_bytes)
    request = request_bytes(
        command=1,
        address_type=1,
        host=target_ipv4,
        port=target.endpoint[1],
    )
    with open_proxy(args) as connection:
        establish_noauth(args, connection)
        connection.sendall(request)
        expect_connect_success(connection)
        assert_bytes(
            "large-data target banner",
            recv_exact(connection, len(SERVER_BANNER)),
            SERVER_BANNER,
        )
        connection.sendall(payload)
        connection.shutdown(socket.SHUT_WR)
        response = recv_exact(
            connection, len(payload) + len(EOF_RESPONSE)
        )
        assert_bytes(
            "large-data and half-close response",
            response,
            payload + EOF_RESPONSE,
        )
        if connection.recv(1) != b"":
            raise AcceptanceError("connection had bytes after the target EOF response")


def test_https_connect(
    args: argparse.Namespace, target: TargetServer, target_ipv4: str
) -> None:
    payload = b"PhoneLanProxy HTTPS tunnel payload"
    request = (
        f"CONNECT {target_ipv4}:{target.endpoint[1]} HTTP/1.1\r\n"
        f"Host: {target_ipv4}:{target.endpoint[1]}\r\n\r\n"
    ).encode("ascii")
    with open_proxy(args) as connection:
        send_fragments(
            connection,
            [request[:7], request[7:-4], request[-4:] + payload],
            args.timeout,
        )
        response, remainder = recv_headers_and_remainder(connection)
        if not response.startswith(b"HTTP/1.1 200 Connection Established\r\n"):
            raise AcceptanceError("CONNECT did not return 200 Connection Established")
        tunneled = bytearray(remainder)
        expected_length = len(SERVER_BANNER) + len(payload)
        while len(tunneled) < expected_length:
            chunk = connection.recv(expected_length - len(tunneled))
            if not chunk:
                raise AcceptanceError("HTTPS tunnel closed before the target data arrived")
            tunneled.extend(chunk)
        assert_bytes(
            "HTTPS tunnel response",
            bytes(tunneled[:expected_length]),
            SERVER_BANNER + payload,
        )


def test_http_absolute_form(
    args: argparse.Namespace, target: HTTPTargetServer
) -> None:
    request = (
        f"GET http://{args.target_domain}:{target.endpoint[1]}/marker?via=proxy HTTP/1.1\r\n"
        "Host: wrong.example\r\n"
        "Proxy-Connection: keep-alive\r\n\r\n"
    ).encode("ascii")
    with open_proxy(args) as connection:
        send_fragments(connection, [request[:13], request[13:]], args.timeout)
        response = recv_until_eof(connection)
    if not response.startswith(b"HTTP/1.1 200 OK\r\n") or HTTP_MARKER not in response:
        raise AcceptanceError("absolute-form HTTP request did not return the marker")
    forwarded = target.last_request
    if forwarded is None:
        raise AcceptanceError("HTTP target did not record a request")
    if not forwarded.startswith(b"GET /marker?via=proxy HTTP/1.1\r\n"):
        raise AcceptanceError("absolute-form request was not converted to origin-form")
    if b"Proxy-Connection:" in forwarded:
        raise AcceptanceError("Proxy-Connection header was forwarded to the target")
    expected_host = f"Host: {args.target_domain}:{target.endpoint[1]}\r\n".encode("ascii")
    if expected_host not in forwarded or b"Host: wrong.example\r\n" in forwarded:
        raise AcceptanceError("Host header was not rebuilt from the absolute-form URI")


def test_http_malformed(args: argparse.Namespace) -> None:
    with open_proxy(args) as connection:
        connection.sendall(b"GET /origin-form HTTP/1.1\r\nHost: example.com\r\n\r\n")
        response = recv_until_headers(connection)
    if not response.startswith(b"HTTP/1.1 400 Bad Request\r\n"):
        raise AcceptanceError("origin-form request did not return HTTP 400")


def allocate_closed_port(bind_host: str) -> int:
    family = socket.AF_INET6 if ":" in bind_host else socket.AF_INET
    listener = socket.socket(family, socket.SOCK_STREAM)
    listener.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    if family == socket.AF_INET6:
        listener.setsockopt(socket.IPPROTO_IPV6, socket.IPV6_V6ONLY, 1)
        listener.bind((bind_host, 0, 0, 0))
    else:
        listener.bind((bind_host, 0))
    port = int(listener.getsockname()[1])
    listener.close()
    return port


def run_case(name: str, case: Callable[[], None]) -> bool:
    print(f"[RUN ] {name}")
    try:
        case()
    except Exception as exc:  # Keep the remaining independent checks running.
        print(f"[FAIL] {name}: {type(exc).__name__}: {exc}")
        return False
    print(f"[PASS] {name}")
    return True


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        description="黑盒验收已运行的 PhoneLanProxy SOCKS5、HTTP 和 HTTPS 代理"
    )
    parser.add_argument(
        "--proxy-host",
        default="127.0.0.1",
        help="代理地址，默认 127.0.0.1",
    )
    parser.add_argument(
        "--proxy-port",
        type=int,
        default=10808,
        help="SOCKS5 代理端口，默认 10808",
    )
    parser.add_argument(
        "--target-host",
        type=lambda value: parse_ipv4(value, "--target-host"),
        default="127.0.0.1",
        help="IPv4 测试目标的 SOCKS 地址；默认 127.0.0.1",
    )
    parser.add_argument(
        "--target-ipv6",
        type=lambda value: parse_ipv6(value, "--target-ipv6"),
        default="::1",
        help="IPv6 测试目标的 SOCKS 地址；默认 ::1",
    )
    parser.add_argument(
        "--target-domain",
        default="localhost",
        help="域名测试写入 SOCKS 请求的名称；默认 localhost",
    )
    parser.add_argument(
        "--bind-host",
        type=lambda value: parse_ipv4(value, "--bind-host"),
        default=None,
        help="IPv4 测试 server 监听地址；默认与 --target-host 相同",
    )
    parser.add_argument(
        "--bind-ipv6",
        type=lambda value: parse_ipv6(value, "--bind-ipv6"),
        default=None,
        help="IPv6 测试 server 监听地址；默认与 --target-ipv6 相同",
    )
    parser.add_argument(
        "--timeout",
        type=float,
        default=5.0,
        help="每次 socket I/O 的超时秒数，默认 5",
    )
    parser.add_argument(
        "--large-bytes",
        type=int,
        default=512 * 1024,
        help="双向大数据测试的字节数，默认 524288",
    )
    return parser


def main(argv: Optional[list[str]] = None) -> int:
    parser = build_parser()
    args = parser.parse_args(argv)
    if not 1 <= args.proxy_port <= 65535:
        parser.error("--proxy-port must be between 1 and 65535")
    if args.timeout <= 0:
        parser.error("--timeout must be greater than zero")
    if args.large_bytes <= 0:
        parser.error("--large-bytes must be greater than zero")
    if not 1 <= len(args.target_domain.encode("idna")) <= 255:
        parser.error("--target-domain must encode to 1..255 bytes")

    target_ipv4 = args.target_host
    target_ipv6 = args.target_ipv6
    bind_host = args.bind_host or target_ipv4
    bind_ipv6 = args.bind_ipv6 or target_ipv6

    ipv4_server = TargetServer(
        bind_host=bind_host,
        advertised_host=target_ipv4,
        family=socket.AF_INET,
        timeout=args.timeout,
    )
    try:
        ipv4_server.start()
    except OSError as exc:
        print(f"无法启动 IPv4 测试 server: {type(exc).__name__}: {exc}", file=sys.stderr)
        return 2

    http_server = HTTPTargetServer(
        bind_host=bind_host,
        advertised_host=args.target_domain,
        family=socket.AF_INET,
        timeout=args.timeout,
    )
    try:
        http_server.start()
    except OSError as exc:
        ipv4_server.close()
        print(f"无法启动 HTTP 测试 server: {type(exc).__name__}: {exc}", file=sys.stderr)
        return 2

    ipv6_server: Optional[TargetServer] = TargetServer(
        bind_host=bind_ipv6,
        advertised_host=target_ipv6,
        family=socket.AF_INET6,
        timeout=args.timeout,
        # Keeping the same port makes the default `localhost` domain test
        # work whether the proxy resolver chooses ::1 or 127.0.0.1.
        listen_port=ipv4_server.port or 0,
    )
    ipv6_error: Optional[Exception] = None
    try:
        ipv6_server.start()
    except OSError as exc:
        # Some hosts reserve one shared port across address families.  Retry
        # an ephemeral IPv6 port so the explicit IPv6 case remains useful.
        ipv6_server = TargetServer(
            bind_host=bind_ipv6,
            advertised_host=target_ipv6,
            family=socket.AF_INET6,
            timeout=args.timeout,
        )
        try:
            ipv6_server.start()
        except OSError as fallback_exc:
            ipv6_error = fallback_exc
            ipv6_server = None

    print(
        f"IPv4 target server: {target_ipv4}:{ipv4_server.endpoint[1]} "
        f"(bind {bind_host})"
    )
    print(
        f"HTTP target server: {args.target_domain}:{http_server.endpoint[1]} "
        f"(bind {bind_host})"
    )
    if ipv6_server is None:
        print(f"IPv6 target server unavailable: {type(ipv6_error).__name__}: {ipv6_error}")
    else:
        print(
            f"IPv6 target server: [{target_ipv6}]:{ipv6_server.endpoint[1]} "
            f"(bind {bind_ipv6})"
        )
    print(
        f"Proxy under test: {args.proxy_host}:{args.proxy_port}; "
        f"timeout {args.timeout:g}s"
    )

    try:
        closed_port = allocate_closed_port(bind_host)
        cases: list[tuple[str, Callable[[], None]]] = [
            (
                "无认证拒绝其他认证方式",
                lambda: test_noauth_rejection(args),
            ),
            (
                "不支持的 CMD 返回 REP 0x07",
                lambda: test_unsupported_command(args, ipv4_server, target_ipv4),
            ),
            (
                "不支持的 ATYP 返回 REP 0x08",
                lambda: test_unsupported_address_type(args),
            ),
            (
                "目标连接失败返回非零 REP",
                lambda: test_failure_rep(args, target_ipv4, closed_port),
            ),
            (
                "IPv4 分片握手和请求",
                lambda: test_ipv4_fragmented(args, ipv4_server, target_ipv4),
            ),
            (
                "域名合并握手请求和首段数据",
                lambda: test_domain_merged(args, ipv4_server),
            ),
            (
                "IPv6 CONNECT",
                lambda: test_ipv6(args, ipv6_server, target_ipv6),
            ),
            (
                "双向大数据和 half-close",
                lambda: test_large_half_close(args, ipv4_server, target_ipv4),
            ),
            (
                "HTTPS CONNECT TCP 隧道",
                lambda: test_https_connect(args, ipv4_server, target_ipv4),
            ),
            (
                "HTTP absolute-form 转 origin-form",
                lambda: test_http_absolute_form(args, http_server),
            ),
            (
                "HTTP origin-form 返回 400",
                lambda: test_http_malformed(args),
            ),
        ]
        passed = sum(run_case(name, case) for name, case in cases)
        failed = len(cases) - passed
        print(f"结果: {passed} passed, {failed} failed")
        return 0 if failed == 0 else 1
    finally:
        ipv4_server.close()
        http_server.close()
        if ipv6_server is not None:
            ipv6_server.close()


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except KeyboardInterrupt:
        print("已中断", file=sys.stderr)
        raise SystemExit(130)
