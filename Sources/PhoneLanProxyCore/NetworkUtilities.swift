import Foundation
import Network
import Darwin

public enum SOCKS5NetworkUtilities {
    public static func boundAddress(for endpoint: NWEndpoint?) -> SOCKS5BoundAddress {
        guard let endpoint else {
            return .unspecified
        }

        guard case let .hostPort(host, port) = endpoint else {
            return .unspecified
        }

        switch host {
        case let .ipv4(address):
            return SOCKS5BoundAddress(kind: .ipv4(Array(address.rawValue)), port: port.rawValue)
        case let .ipv6(address):
            return SOCKS5BoundAddress(kind: .ipv6(Array(address.rawValue)), port: port.rawValue)
        case let .name(name, _):
            let bytes = Array(name.utf8)
            guard !bytes.isEmpty, bytes.count <= 255 else {
                return .unspecified
            }
            return SOCKS5BoundAddress(kind: .domain(bytes), port: port.rawValue)
        @unknown default:
            return .unspecified
        }
    }

    public static func replyCode(for error: NWError) -> UInt8 {
        guard case let .posix(code) = error else {
            return SOCKS5Wire.generalFailure
        }

        switch code.rawValue {
        case Int32(ECONNREFUSED):
            return SOCKS5Wire.connectionRefused
        case Int32(ETIMEDOUT):
            return SOCKS5Wire.ttlExpired
        case Int32(ENETUNREACH):
            return SOCKS5Wire.networkUnreachable
        case Int32(EHOSTUNREACH):
            return SOCKS5Wire.hostUnreachable
        default:
            return SOCKS5Wire.generalFailure
        }
    }
}

enum ProxyTimeouts {
    /// Time a client gets to finish the SOCKS5 or HTTP handshake.
    static let clientHandshake: TimeInterval = 10
    /// Upper bound for DNS + TCP setup to a target. Refused or unroutable
    /// targets fail immediately through `.waiting`; this only bounds
    /// black-holed ones, so it must leave room for slow VPN/cellular paths.
    static let outboundConnect: TimeInterval = 15
}

/// A single pending timeout on a session's queue; arming replaces the
/// previous one. Confined to that queue like its owner.
final class QueueTimeout {
    private let queue: DispatchQueue
    private var workItem: DispatchWorkItem?

    init(queue: DispatchQueue) {
        self.queue = queue
    }

    func arm(seconds: TimeInterval, action: @escaping @Sendable () -> Void) {
        workItem?.cancel()
        let item = DispatchWorkItem(block: action)
        workItem = item
        queue.asyncAfter(deadline: .now() + seconds, execute: item)
    }

    func cancel() {
        workItem?.cancel()
        workItem = nil
    }
}
