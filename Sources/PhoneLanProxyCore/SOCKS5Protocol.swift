import Foundation
import Network

/// The address carried by a SOCKS5 CONNECT request.
public enum SOCKS5Address: Equatable, Sendable {
    case ipv4(String)
    case ipv6(String)
    case domain(String)

    public var host: String {
        switch self {
        case let .ipv4(value), let .ipv6(value), let .domain(value):
            return value
        }
    }
}

public struct SOCKS5Greeting: Equatable, Sendable {
    public let methods: [UInt8]

    public init(methods: [UInt8]) {
        self.methods = methods
    }

    public var supportsNoAuthentication: Bool {
        methods.contains(SOCKS5Wire.noAuthentication)
    }
}

public struct SOCKS5Request: Equatable, Sendable {
    public let command: UInt8
    public let address: SOCKS5Address
    public let port: UInt16

    public init(command: UInt8, address: SOCKS5Address, port: UInt16) {
        self.command = command
        self.address = address
        self.port = port
    }
}

public enum SOCKS5ProtocolError: Error, Equatable, Sendable {
    case invalidVersion
    case invalidMethodCount
    case unsupportedAddressType
    case invalidReservedField
    case emptyDomain
    case invalidDomainEncoding
}

public enum SOCKS5ParseResult<Value: Equatable>: Equatable {
    case needMoreData
    case parsed(Value, consumed: Int)
    case invalid(SOCKS5ProtocolError)
}

public enum SOCKS5Wire {
    public static let version: UInt8 = 0x05
    public static let noAuthentication: UInt8 = 0x00
    public static let noAcceptableMethods: UInt8 = 0xFF

    public static let connect: UInt8 = 0x01
    public static let commandNotSupported: UInt8 = 0x07

    public static let succeeded: UInt8 = 0x00
    public static let generalFailure: UInt8 = 0x01
    public static let networkUnreachable: UInt8 = 0x03
    public static let hostUnreachable: UInt8 = 0x04
    public static let connectionRefused: UInt8 = 0x05
    public static let ttlExpired: UInt8 = 0x06
    public static let addressTypeNotSupported: UInt8 = 0x08

    public static func parseGreeting(_ bytes: [UInt8]) -> SOCKS5ParseResult<SOCKS5Greeting> {
        guard let version = bytes.first else {
            return .needMoreData
        }
        guard version == self.version else {
            return .invalid(.invalidVersion)
        }
        guard bytes.count >= 2 else {
            return .needMoreData
        }

        let methodCount = Int(bytes[1])
        guard methodCount > 0 else {
            return .invalid(.invalidMethodCount)
        }
        let totalLength = 2 + methodCount
        guard bytes.count >= totalLength else {
            return .needMoreData
        }

        return .parsed(
            SOCKS5Greeting(methods: Array(bytes[2..<totalLength])),
            consumed: totalLength
        )
    }

    public static func parseRequest(_ bytes: [UInt8]) -> SOCKS5ParseResult<SOCKS5Request> {
        guard let version = bytes.first else {
            return .needMoreData
        }
        guard version == self.version else {
            return .invalid(.invalidVersion)
        }
        guard bytes.count >= 4 else {
            return .needMoreData
        }
        guard bytes[2] == 0 else {
            return .invalid(.invalidReservedField)
        }

        let command = bytes[1]
        let addressType = bytes[3]
        var offset = 4
        let address: SOCKS5Address

        switch addressType {
        case 0x01:
            guard bytes.count >= offset + 4 + 2 else {
                return .needMoreData
            }
            let octets = bytes[offset..<(offset + 4)]
            address = .ipv4(octets.map(String.init).joined(separator: "."))
            offset += 4

        case 0x03:
            guard bytes.count > offset else {
                return .needMoreData
            }
            let length = Int(bytes[offset])
            offset += 1
            guard length > 0 else {
                return .invalid(.emptyDomain)
            }
            guard bytes.count >= offset + length + 2 else {
                return .needMoreData
            }
            let domainBytes = bytes[offset..<(offset + length)]
            guard let domain = String(bytes: domainBytes, encoding: .utf8) else {
                return .invalid(.invalidDomainEncoding)
            }
            address = .domain(domain)
            offset += length

        case 0x04:
            guard bytes.count >= offset + 16 + 2 else {
                return .needMoreData
            }
            // Network formats per RFC 5952 (compressed, lowercase).
            let octets = Data(bytes[offset..<(offset + 16)])
            address = .ipv6(IPv6Address(octets)?.debugDescription ?? "::")
            offset += 16

        default:
            return .invalid(.unsupportedAddressType)
        }

        let port = (UInt16(bytes[offset]) << 8) | UInt16(bytes[offset + 1])
        return .parsed(
            SOCKS5Request(command: command, address: address, port: port),
            consumed: offset + 2
        )
    }

    public static func methodSelectionResponse(_ method: UInt8) -> Data {
        Data([version, method])
    }

    public static func response(reply: UInt8, boundAddress: SOCKS5BoundAddress = .unspecified) -> Data {
        var bytes = [version, reply, 0]
        bytes.append(contentsOf: boundAddress.encodedAddress)
        bytes.append(UInt8(boundAddress.port >> 8))
        bytes.append(UInt8(boundAddress.port & 0xFF))
        return Data(bytes)
    }
}

public struct SOCKS5BoundAddress: Equatable, Sendable {
    public enum Kind: Equatable, Sendable {
        case ipv4([UInt8])
        case ipv6([UInt8])
        case domain([UInt8])
    }

    public let kind: Kind
    public let port: UInt16

    public init(kind: Kind, port: UInt16) {
        self.kind = kind
        self.port = port
    }

    public static let unspecified = SOCKS5BoundAddress(kind: .ipv4([0, 0, 0, 0]), port: 0)

    fileprivate var encodedAddress: [UInt8] {
        switch kind {
        case let .ipv4(bytes) where bytes.count == 4:
            return [0x01] + bytes
        case let .ipv6(bytes) where bytes.count == 16:
            return [0x04] + bytes
        case let .domain(bytes) where bytes.count <= 255:
            return [0x03, UInt8(bytes.count)] + bytes
        default:
            return SOCKS5BoundAddress.unspecified.encodedAddress
        }
    }
}
