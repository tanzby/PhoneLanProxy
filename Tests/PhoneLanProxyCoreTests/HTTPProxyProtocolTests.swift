import XCTest
@testable import PhoneLanProxyCore

final class HTTPProxyProtocolTests: XCTestCase {
    func testConnectParsesAuthorityAndFragmentedHeaders() {
        let header = Data(
            "CONNECT [2001:db8::1]:443 HTTP/1.1\r\nHost: [2001:db8::1]:443\r\n\r\n".utf8
        )
        let bytes = Array(header) + Array("TLS bytes".utf8)

        for end in 0..<header.count {
            XCTAssertEqual(
                HTTPProxyWire.parse(Array(bytes[..<end])),
                .needMoreData,
                "prefix length \(end)"
            )
        }

        guard case let .parsed(request, headerLength) = HTTPProxyWire.parse(bytes) else {
            return XCTFail("expected CONNECT request")
        }
        XCTAssertEqual(request, .connect(host: "2001:db8::1", port: 443))
        XCTAssertEqual(headerLength, header.count)
    }

    func testAbsoluteFormBecomesOriginFormAndDropsProxyConnection() {
        let request = Data(
            "GET http://example.com:8080/path?q=1 HTTP/1.1\r\nHost: wrong.example\r\nProxy-Connection: keep-alive\r\nX-Test: value\r\n\r\nbody".utf8
        )

        guard case let .parsed(parsed, headerLength) = HTTPProxyWire.parse(Array(request)) else {
            return XCTFail("expected absolute-form request")
        }
        guard case let .forward(host, port, header) = parsed else {
            return XCTFail("expected forward request")
        }
        XCTAssertEqual(host, "example.com")
        XCTAssertEqual(port, 8080)
        XCTAssertEqual(
            String(data: header, encoding: .utf8),
            "GET /path?q=1 HTTP/1.1\r\nX-Test: value\r\nHost: example.com:8080\r\nConnection: close\r\n\r\n"
        )
        XCTAssertEqual(headerLength, request.count - 4)
    }

    func testAbsoluteFormNormalizesIPv6Authority() {
        let request = Array(
            "GET http://[2001:db8::1]:8080/path HTTP/1.1\r\nHost: ignored.example\r\n\r\n".utf8
        )
        guard case let .parsed(.forward(host, port, header), _) = HTTPProxyWire.parse(request) else {
            return XCTFail("expected IPv6 absolute-form request")
        }
        XCTAssertEqual(host, "2001:db8::1")
        XCTAssertEqual(port, 8080)
        XCTAssertEqual(
            String(data: header, encoding: .utf8),
            "GET /path HTTP/1.1\r\nHost: [2001:db8::1]:8080\r\nConnection: close\r\n\r\n"
        )
    }

    func testAbsoluteFormAddsHostAndRejectsHTTPSAbsoluteForm() {
        let request = Data("POST http://example.com/upload HTTP/1.1\r\nContent-Length: 3\r\n\r\nabc".utf8)
        guard case let .parsed(.forward(_, _, header), _) = HTTPProxyWire.parse(Array(request)) else {
            return XCTFail("expected forward request")
        }
        XCTAssertEqual(
            String(data: header, encoding: .utf8),
            "POST /upload HTTP/1.1\r\nContent-Length: 3\r\nHost: example.com\r\nConnection: close\r\n\r\n"
        )

        let https = Array("GET https://example.com/ HTTP/1.1\r\nHost: example.com\r\n\r\n".utf8)
        XCTAssertEqual(HTTPProxyWire.parse(https), .invalid(.unsupportedScheme))

        let fragment = Array("GET http://example.com/path#fragment HTTP/1.1\r\nHost: example.com\r\n\r\n".utf8)
        XCTAssertEqual(HTTPProxyWire.parse(fragment), .invalid(.malformedRequest))

        let invalidIPv6 = Array("CONNECT [example.com]:443 HTTP/1.1\r\nHost: example.com\r\n\r\n".utf8)
        XCTAssertEqual(HTTPProxyWire.parse(invalidIPv6), .invalid(.invalidAuthority))
    }

    func testMalformedAndOversizedHeadersAreRejected() {
        let malformed = Array("GET http://example.com/ HTTP/1.1\r\nBroken\r\n\r\n".utf8)
        XCTAssertEqual(HTTPProxyWire.parse(malformed), .invalid(.malformedRequest))

        let oversized = Array(repeating: UInt8(ascii: "x"), count: HTTPProxyWire.maximumHeaderLength)
        XCTAssertEqual(HTTPProxyWire.parse(oversized), .invalid(.headerTooLarge))
    }

    func testForwardReplacesClientConnectionManagementHeaders() {
        let bytes = Array(
            "GET http://example.com/ HTTP/1.1\r\nConnection: keep-alive\r\nKeep-Alive: timeout=5\r\nX-A|B: 1\r\n\r\n".utf8
        )
        guard case let .parsed(.forward(_, _, header), _) = HTTPProxyWire.parse(bytes) else {
            return XCTFail("expected forward request")
        }
        XCTAssertEqual(
            String(data: header, encoding: .utf8),
            "GET / HTTP/1.1\r\nX-A|B: 1\r\nHost: example.com\r\nConnection: close\r\n\r\n"
        )
    }

    func testForwardStripsDeviceIdentifyingHeaders() {
        let bytes = Array(
            "GET http://example.com/ HTTP/1.1\r\nUser-Agent: Mozilla/5.0 (Macintosh; Intel Mac OS X)\r\nAccept: text/html\r\nSec-CH-UA-Platform: \"macOS\"\r\nSec-CH-UA-Mobile: ?0\r\n\r\n".utf8
        )
        guard case let .parsed(.forward(_, _, header), _) = HTTPProxyWire.parse(bytes) else {
            return XCTFail("expected forward request")
        }
        XCTAssertEqual(
            String(data: header, encoding: .utf8),
            "GET / HTTP/1.1\r\nAccept: text/html\r\nHost: example.com\r\nConnection: close\r\n\r\n"
        )
    }

    func testForwardStripsClientHintsAndCharacteristicHeaders() {
        let bytes = Array(
            "GET http://example.com/ HTTP/1.1\r\nDPR: 2\r\nDevice-Memory: 8\r\nViewport-Width: 1280\r\nSec-CH-Prefers-Color-Scheme: dark\r\nDownlink: 10\r\nX-Requested-With: XMLHttpRequest\r\nAccept: text/html\r\n\r\n".utf8
        )
        guard case let .parsed(.forward(_, _, header), _) = HTTPProxyWire.parse(bytes) else {
            return XCTFail("expected forward request")
        }
        XCTAssertEqual(
            String(data: header, encoding: .utf8),
            "GET / HTTP/1.1\r\nAccept: text/html\r\nHost: example.com\r\nConnection: close\r\n\r\n"
        )
    }

    func testForwardStripsDeviceHeadersCaseInsensitively() {
        let bytes = Array(
            "GET http://example.com/ HTTP/1.1\r\nUSER-AGENT: curl/8\r\nSec-Ch-Ua-Mobile: ?0\r\nAccept: */*\r\n\r\n".utf8
        )
        guard case let .parsed(.forward(_, _, header), _) = HTTPProxyWire.parse(bytes) else {
            return XCTFail("expected forward request")
        }
        XCTAssertEqual(
            String(data: header, encoding: .utf8),
            "GET / HTTP/1.1\r\nAccept: */*\r\nHost: example.com\r\nConnection: close\r\n\r\n"
        )
    }

    func testConnectIsUnaffectedByDeviceHeaderStripping() {
        let bytes = Array(
            "CONNECT example.com:443 HTTP/1.1\r\nUser-Agent: Mac\r\nSec-CH-UA-Platform: \"macOS\"\r\n\r\n".utf8
        )
        guard case let .parsed(request, _) = HTTPProxyWire.parse(bytes) else {
            return XCTFail("expected CONNECT request")
        }
        XCTAssertEqual(request, .connect(host: "example.com", port: 443))
    }

    func testHeaderValueRejectsDEL() {
        let bytes = Array("GET http://example.com/ HTTP/1.1\r\nX-Test: a\u{7F}b\r\n\r\n".utf8)
        XCTAssertEqual(HTTPProxyWire.parse(bytes), .invalid(.malformedRequest))
    }

}
