import XCTest
@testable import PhoneLanProxyCore

final class SOCKS5ProtocolTests: XCTestCase {
    func testGreetingSupportsNoAuthenticationAndConsumesOnlyGreetingBytes() {
        let bytes: [UInt8] = [5, 2, 2, 0, 5, 1, 0x1F]

        guard case let .parsed(greeting, consumed) = SOCKS5Wire.parseGreeting(bytes) else {
            return XCTFail("expected a complete greeting")
        }

        XCTAssertEqual(greeting.methods, [2, 0])
        XCTAssertTrue(greeting.supportsNoAuthentication)
        XCTAssertEqual(consumed, 4)
    }

    func testGreetingNeedsMoreDataAtEveryFragmentBoundary() {
        let bytes: [UInt8] = [5, 3, 2, 1, 0]

        for end in 0..<(bytes.count) {
            XCTAssertEqual(
                parseGreeting(Array(bytes[..<end])),
                .needMoreData,
                "prefix length \(end)"
            )
        }
        guard case let .parsed(greeting, consumed) = SOCKS5Wire.parseGreeting(bytes) else {
            return XCTFail("expected complete greeting")
        }
        XCTAssertEqual(greeting.methods, [2, 1, 0])
        XCTAssertEqual(consumed, bytes.count)
    }

    func testRequestsForIPv4IPv6AndDomain() {
        let requests: [([UInt8], SOCKS5Request)] = [
            (
                [5, 1, 0, 1, 192, 168, 1, 25, 0x01, 0xBB],
                SOCKS5Request(command: 1, address: .ipv4("192.168.1.25"), port: 443)
            ),
            (
                [5, 1, 0, 4, 0x20, 0x01, 0x0D, 0xB8] + Array(repeating: UInt8(0), count: 10) + [0, 1, 0, 80],
                SOCKS5Request(command: 1, address: .ipv6("2001:db8::1"), port: 80)
            ),
            (
                [5, 1, 0, 4] + Array(repeating: UInt8(0), count: 15) + [1, 0, 22],
                SOCKS5Request(command: 1, address: .ipv6("::1"), port: 22)
            ),
            (
                [5, 1, 0, 4] + Array(repeating: UInt8(0), count: 18),
                SOCKS5Request(command: 1, address: .ipv6("::"), port: 0)
            ),
            (
                [5, 1, 0, 3, 11] + Array("example.com".utf8) + [1, 0xBB],
                SOCKS5Request(command: 1, address: .domain("example.com"), port: 443)
            )
        ]

        for (bytes, expected) in requests {
            guard case let .parsed(request, consumed) = SOCKS5Wire.parseRequest(bytes) else {
                return XCTFail("expected complete request for \(bytes)")
            }
            XCTAssertEqual(request, expected)
            XCTAssertEqual(consumed, bytes.count)
        }
    }

    func testRequestNeedsMoreDataAtEveryFragmentBoundary() {
        let bytes: [UInt8] = [5, 1, 0, 3, 11] + Array("example.com".utf8) + [0x01, 0xBB]

        for end in 0..<(bytes.count) {
            XCTAssertEqual(
                parseRequest(Array(bytes[..<end])),
                .needMoreData,
                "prefix length \(end)"
            )
        }
        guard case .parsed = SOCKS5Wire.parseRequest(bytes) else {
            return XCTFail("expected complete request")
        }
    }

    func testCoalescedGreetingPreservesRequestTail() {
        let greeting: [UInt8] = [5, 1, 0]
        let request: [UInt8] = [5, 1, 0, 1, 127, 0, 0, 1, 0, 80]
        let bytes = greeting + request

        guard case let .parsed(_, greetingLength) = SOCKS5Wire.parseGreeting(bytes) else {
            return XCTFail("expected greeting")
        }
        let tail = Array(bytes.dropFirst(greetingLength))
        guard case let .parsed(parsedRequest, requestLength) = SOCKS5Wire.parseRequest(tail) else {
            return XCTFail("expected request in preserved tail")
        }
        XCTAssertEqual(parsedRequest.address, .ipv4("127.0.0.1"))
        XCTAssertEqual(parsedRequest.port, 80)
        XCTAssertEqual(requestLength, request.count)
    }

    func testProtocolRejectsInvalidAndUnsupportedMessages() {
        guard case .invalid(.invalidVersion) = SOCKS5Wire.parseGreeting([4, 1, 0]) else {
            return XCTFail("invalid greeting version should fail")
        }
        guard case .invalid(.invalidMethodCount) = SOCKS5Wire.parseGreeting([5, 0]) else {
            return XCTFail("zero method count should fail")
        }
        guard case .invalid(.invalidReservedField) = SOCKS5Wire.parseRequest([5, 1, 1, 1]) else {
            return XCTFail("non-zero RSV should fail")
        }
        guard case .invalid(.unsupportedAddressType) = SOCKS5Wire.parseRequest([5, 1, 0, 2]) else {
            return XCTFail("unknown ATYP should fail")
        }
        guard case .invalid(.emptyDomain) = SOCKS5Wire.parseRequest([5, 1, 0, 3, 0]) else {
            return XCTFail("empty domain should fail")
        }
    }

    func testRequestCanRepresentUnsupportedCommandsForSessionToReply() {
        let bytes: [UInt8] = [5, 2, 0, 1, 10, 0, 0, 1, 0, 22]
        guard case let .parsed(request, _) = SOCKS5Wire.parseRequest(bytes) else {
            return XCTFail("expected request")
        }
        XCTAssertEqual(request.command, 2)
        XCTAssertEqual(request.address, .ipv4("10.0.0.1"))
    }

    func testWireResponsesUseRFC1928Shape() {
        XCTAssertEqual(
            Array(SOCKS5Wire.methodSelectionResponse(SOCKS5Wire.noAuthentication)),
            [5, 0]
        )
        XCTAssertEqual(
            Array(SOCKS5Wire.response(reply: SOCKS5Wire.connectionRefused)),
            [5, 5, 0, 1, 0, 0, 0, 0, 0, 0]
        )
        XCTAssertEqual(
            Array(SOCKS5Wire.response(
                reply: SOCKS5Wire.succeeded,
                boundAddress: SOCKS5BoundAddress(kind: .ipv6(Array(repeating: UInt8(0), count: 16)), port: 1080)
            )),
            [5, 0, 0, 4] + Array(repeating: UInt8(0), count: 16) + [0x04, 0x38]
        )
    }

    private func parseGreeting(_ bytes: [UInt8]) -> SOCKS5ParseResult<SOCKS5Greeting> {
        SOCKS5Wire.parseGreeting(bytes)
    }

    private func parseRequest(_ bytes: [UInt8]) -> SOCKS5ParseResult<SOCKS5Request> {
        SOCKS5Wire.parseRequest(bytes)
    }
}

final class ProxyConnectionTrackerTests: XCTestCase {
    func testLifecycleMovesConnectionToEndedHistoryWithMetadata() {
        let clock = ProxyConnectionTestClock()
        let tracker = ProxyConnectionTracker(now: { clock.now })
        let id = UUID()

        tracker.accept(id: id, clientAddress: "192.168.1.8:51000")
        XCTAssertEqual(tracker.activeSnapshots.first?.phase, .detecting)
        XCTAssertEqual(tracker.activeSnapshots.first?.clientAddress, "192.168.1.8:51000")

        tracker.handle(.phase(.handshaking), id: id)
        tracker.handle(.protocolDetected(.socks5), id: id)
        tracker.handle(
            .target(protocolKind: .socks5, host: "example.com", port: 443),
            id: id
        )
        clock.advance(1)
        tracker.handle(.outboundReady, id: id)
        tracker.handle(.relayStarted, id: id)

        guard let active = tracker.activeSnapshots.first else {
            return XCTFail("expected active connection")
        }
        XCTAssertEqual(active.phase, .relaying)
        XCTAssertEqual(active.protocolKind, .socks5)
        XCTAssertEqual(active.endpoint, "example.com:443")
        XCTAssertEqual(active.connectedAt, Date(timeIntervalSince1970: 1))

        clock.advance(2)
        tracker.handle(
            .finished(.completed, failureDescription: nil),
            id: id
        )

        XCTAssertTrue(tracker.activeSnapshots.isEmpty)
        guard let completed = tracker.endedSnapshots.first else {
            return XCTFail("expected ended connection")
        }
        XCTAssertEqual(completed.id, id)
        XCTAssertEqual(completed.phase, .ended)
        XCTAssertEqual(completed.endReason, .completed)
        XCTAssertEqual(completed.endedAt, Date(timeIntervalSince1970: 3))

        let targetFailureID = UUID()
        tracker.accept(id: targetFailureID, clientAddress: nil)
        tracker.handle(
            .target(protocolKind: .httpConnect, host: "unreachable.example", port: 443),
            id: targetFailureID
        )
        tracker.handle(
            .finished(.targetConnectionFailed, failureDescription: "connection refused"),
            id: targetFailureID
        )

        let protocolFailureID = UUID()
        tracker.accept(id: protocolFailureID, clientAddress: nil)
        tracker.handle(.protocolDetected(.socks5), id: protocolFailureID)
        tracker.handle(
            .finished(.protocolError, failureDescription: "invalid request"),
            id: protocolFailureID
        )

        let endedByID = Dictionary(uniqueKeysWithValues: tracker.endedSnapshots.map { ($0.id, $0) })
        XCTAssertEqual(endedByID[targetFailureID]?.phase, .ended)
        XCTAssertEqual(endedByID[targetFailureID]?.protocolKind, .httpConnect)
        XCTAssertEqual(endedByID[targetFailureID]?.endReason, .targetConnectionFailed)
        XCTAssertEqual(endedByID[targetFailureID]?.failureDescription, "connection refused")
        XCTAssertEqual(endedByID[protocolFailureID]?.protocolKind, .socks5)
        XCTAssertEqual(endedByID[protocolFailureID]?.endReason, .protocolError)
        XCTAssertEqual(endedByID[protocolFailureID]?.failureDescription, "invalid request")
    }

    func testDirectionalBytesSamplingAndAverageRates() {
        let clock = ProxyConnectionTestClock()
        let tracker = ProxyConnectionTracker(now: { clock.now })
        let id = UUID()
        tracker.accept(id: id, clientAddress: nil)
        tracker.handle(
            .target(protocolKind: .httpConnect, host: "secure.example", port: 443),
            id: id
        )
        tracker.handle(.bytes(uploaded: 1_500, downloaded: 2_500), id: id)

        clock.advance(2)
        tracker.sample()
        guard let sampled = tracker.activeSnapshots.first else {
            return XCTFail("expected sampled connection")
        }
        XCTAssertEqual(sampled.uploadedBytes, 1_500)
        XCTAssertEqual(sampled.downloadedBytes, 2_500)
        XCTAssertEqual(sampled.uploadRate, 750, accuracy: 0.001)
        XCTAssertEqual(sampled.downloadRate, 1_250, accuracy: 0.001)

        tracker.handle(.bytes(uploaded: 500, downloaded: 1_000), id: id)
        clock.advance(1)
        tracker.sample()
        guard let resampled = tracker.activeSnapshots.first else {
            return XCTFail("expected resampled connection")
        }
        XCTAssertEqual(resampled.uploadRate, 500, accuracy: 0.001)
        XCTAssertEqual(resampled.downloadRate, 1_000, accuracy: 0.001)

        tracker.handle(.finished(.completed, failureDescription: nil), id: id)
        guard let ended = tracker.endedSnapshots.first else {
            return XCTFail("expected ended connection")
        }
        XCTAssertEqual(ended.uploadedBytes, 2_000)
        XCTAssertEqual(ended.downloadedBytes, 3_500)
        XCTAssertEqual(ended.averageUploadRate, 2_000.0 / 3.0, accuracy: 0.001)
        XCTAssertEqual(ended.averageDownloadRate, 3_500.0 / 3.0, accuracy: 0.001)
        XCTAssertEqual(ended.uploadRate, 0)
        XCTAssertEqual(ended.downloadRate, 0)
    }

    func testEndedHistoryEvictsOldestAfterTwoHundredRecords() {
        let clock = ProxyConnectionTestClock()
        let tracker = ProxyConnectionTracker(now: { clock.now })

        for index in 0...200 {
            let id = UUID()
            tracker.accept(id: id, clientAddress: nil)
            tracker.handle(
                .target(protocolKind: .http, host: "host-\(index).example", port: 80),
                id: id
            )
            tracker.handle(.finished(.completed, failureDescription: nil), id: id)
            clock.advance(1)
        }

        XCTAssertEqual(tracker.endedSnapshots.count, 200)
        XCTAssertEqual(tracker.endedSnapshots.first?.host, "host-200.example")
        XCTAssertEqual(tracker.endedSnapshots.last?.host, "host-1.example")
    }

    func testResetClearsActiveAndEndedRuntimeHistory() {
        let tracker = ProxyConnectionTracker()
        let activeID = UUID()
        let endedID = UUID()

        tracker.accept(id: activeID, clientAddress: nil)
        tracker.accept(id: endedID, clientAddress: nil)
        tracker.handle(.finished(.cancelled, failureDescription: nil), id: endedID)
        XCTAssertEqual(tracker.activeSnapshots.count, 1)
        XCTAssertEqual(tracker.endedSnapshots.count, 1)

        tracker.reset()

        XCTAssertTrue(tracker.activeSnapshots.isEmpty)
        XCTAssertTrue(tracker.endedSnapshots.isEmpty)
    }
}

private final class ProxyConnectionTestClock {
    var now: Date

    init() {
        self.now = Date(timeIntervalSince1970: 0)
    }

    func advance(_ seconds: TimeInterval) {
        now = now.addingTimeInterval(seconds)
    }
}
