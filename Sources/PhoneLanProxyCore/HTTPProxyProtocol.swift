import Foundation
import Network

public enum HTTPProxyProtocolError: Error, Equatable, Sendable {
    case malformedRequest
    case headerTooLarge
    case unsupportedVersion
    case unsupportedScheme
    case invalidAuthority
    case invalidPort
}

public enum HTTPProxyRequest: Equatable, Sendable {
    case connect(host: String, port: UInt16)
    case forward(host: String, port: UInt16, header: Data)
}

public enum HTTPProxyParseResult: Equatable, Sendable {
    case needMoreData
    case parsed(HTTPProxyRequest, headerLength: Int)
    case invalid(HTTPProxyProtocolError)
}

public enum HTTPProxyWire {
    public static let maximumHeaderLength = 64 * 1024

    public static let connectionEstablished = Data(
        "HTTP/1.1 200 Connection Established\r\n\r\n".utf8
    )

    public static func errorResponse(
        statusCode: Int,
        reason: String
    ) -> Data {
        Data(
            "HTTP/1.1 \(statusCode) \(reason)\r\nConnection: close\r\nContent-Length: 0\r\n\r\n".utf8
        )
    }

    public static func errorResponse(for error: HTTPProxyProtocolError) -> Data {
        switch error {
        case .malformedRequest, .invalidAuthority, .invalidPort:
            return errorResponse(statusCode: 400, reason: "Bad Request")
        case .headerTooLarge:
            return errorResponse(statusCode: 431, reason: "Request Header Fields Too Large")
        case .unsupportedVersion:
            return errorResponse(statusCode: 505, reason: "HTTP Version Not Supported")
        case .unsupportedScheme:
            return errorResponse(statusCode: 501, reason: "Not Implemented")
        }
    }

    /// Response for a target connection that could not be established.
    public static func errorResponse(forConnectError error: NWError) -> Data {
        if case let .posix(code) = error, code == .ETIMEDOUT {
            return errorResponse(statusCode: 504, reason: "Gateway Timeout")
        }
        return errorResponse(statusCode: 502, reason: "Bad Gateway")
    }

    public static func parse(
        _ bytes: [UInt8],
        maximumHeaderLength: Int = maximumHeaderLength
    ) -> HTTPProxyParseResult {
        guard maximumHeaderLength > 0 else {
            return .invalid(.headerTooLarge)
        }

        guard let headerEnd = headerEnd(in: bytes) else {
            return bytes.count >= maximumHeaderLength
                ? .invalid(.headerTooLarge)
                : .needMoreData
        }
        guard headerEnd <= maximumHeaderLength else {
            return .invalid(.headerTooLarge)
        }

        let headerBytes = Array(bytes[..<headerEnd])
        guard let headerText = String(bytes: headerBytes, encoding: .utf8) else {
            return .invalid(.malformedRequest)
        }

        let lines = headerText.components(separatedBy: "\r\n")
        guard lines.count >= 3,
              lines[lines.count - 1].isEmpty,
              lines[lines.count - 2].isEmpty,
              !lines[0].isEmpty
        else {
            return .invalid(.malformedRequest)
        }

        let requestParts = lines[0].split(separator: " ", omittingEmptySubsequences: true)
        guard requestParts.count == 3,
              isToken(String(requestParts[0]))
        else {
            return .invalid(.malformedRequest)
        }

        let method = String(requestParts[0])
        let target = String(requestParts[1])
        let version = String(requestParts[2])
        guard version == "HTTP/1.1" else {
            return .invalid(.unsupportedVersion)
        }

        var forwardedHeaders: [String] = []
        for line in lines[1..<(lines.count - 2)] {
            guard let colon = line.firstIndex(of: ":") else {
                return .invalid(.malformedRequest)
            }
            let name = String(line[..<colon])
            let value = String(line[line.index(after: colon)...])
            guard isToken(name), isValidHeaderValue(value) else {
                return .invalid(.malformedRequest)
            }

            // Host is rebuilt from the URI; connection-management headers are
            // replaced below; device-identifying headers are stripped so the
            // origin — and any VPN on the phone's egress — cannot tell the
            // request came from the Mac rather than the phone. That covers the
            // User-Agent, every Client Hint (the `Sec-CH-*` family, incl. the
            // UA hints), and the legacy device/network characteristic hints
            // that are not `Sec-CH-`-prefixed. These hints are opt-in (a site
            // only receives them after advertising `Accept-CH`), so dropping
            // them just falls back to defaults.
            let lowered = name.lowercased()
            let stripped = ["host", "proxy-connection", "connection", "keep-alive",
                            "user-agent", "x-requested-with",
                            "dpr", "width", "viewport-width", "device-memory",
                            "downlink", "rtt", "ect", "save-data"].contains(lowered)
                || lowered.hasPrefix("sec-ch-")
            if !stripped {
                forwardedHeaders.append(line)
            }
        }

        if method == "CONNECT" {
            guard let authority = parseAuthority(target) else {
                return .invalid(.invalidAuthority)
            }
            return .parsed(
                .connect(host: authority.host, port: authority.port),
                headerLength: headerEnd
            )
        }

        guard let components = URLComponents(string: target),
              components.user == nil,
              components.password == nil,
              components.fragment == nil,
              components.scheme?.lowercased() == "http"
        else {
            if target.lowercased().hasPrefix("https://") {
                return .invalid(.unsupportedScheme)
            }
            return .invalid(.malformedRequest)
        }
        guard let rawHost = components.host,
              let host = normalizedURLHost(rawHost)
        else {
            return .invalid(.invalidAuthority)
        }

        let port: UInt16
        if let componentPort = components.port {
            guard (1...65535).contains(componentPort) else {
                return .invalid(.invalidPort)
            }
            port = UInt16(componentPort)
        } else {
            port = 80
        }

        var originTarget = components.percentEncodedPath
        if originTarget.isEmpty {
            originTarget = "/"
        } else if originTarget.first != "/" {
            originTarget = "/" + originTarget
        }
        if let query = components.percentEncodedQuery {
            originTarget.append("?\(query)")
        }

        var output = "\(method) \(originTarget) HTTP/1.1\r\n"
        output += forwardedHeaders.joined(separator: "\r\n")
        if !forwardedHeaders.isEmpty {
            output += "\r\n"
        }
        output += "Host: \(hostHeaderValue(host: host, port: port))\r\n"
        // After this header the session is a raw pipe to this one origin, so
        // the client must not reuse the connection for another request
        // (possibly to a different host).
        output += "Connection: close\r\n"
        output += "\r\n"

        return .parsed(
            .forward(host: host, port: port, header: Data(output.utf8)),
            headerLength: headerEnd
        )
    }

    private static func headerEnd(in bytes: [UInt8]) -> Int? {
        guard bytes.count >= 4 else { return nil }
        for index in 0...(bytes.count - 4) {
            if bytes[index] == 13,
               bytes[index + 1] == 10,
               bytes[index + 2] == 13,
               bytes[index + 3] == 10 {
                return index + 4
            }
        }
        return nil
    }

    private static func isToken(_ value: String) -> Bool {
        guard !value.isEmpty else { return false }
        return value.utf8.allSatisfy { byte in
            switch byte {
            case 33...126:
                return ![34, 40, 41, 44, 47, 58, 59, 60, 61, 62, 63, 64, 91, 92, 93, 123, 125]
                    .contains(Int(byte))
            default:
                return false
            }
        }
    }

    private static func isValidHeaderValue(_ value: String) -> Bool {
        value.utf8.allSatisfy { byte in
            byte == 9 || (byte >= 32 && byte != 127)
        }
    }

    private static func isValidHost(_ host: String) -> Bool {
        guard !host.isEmpty else { return false }
        return host.utf8.allSatisfy { byte in
            byte > 32 && byte != 34 && byte != 47 && byte != 60 && byte != 62
        }
    }

    /// Parses a CONNECT `host:port` authority; the port is required.
    private static func parseAuthority(_ authority: String) -> (host: String, port: UInt16)? {
        guard !authority.isEmpty else { return nil }

        let host: String
        let portText: String
        if authority.first == "[" {
            guard let closingBracket = authority.firstIndex(of: "]") else { return nil }
            host = String(authority[authority.index(after: authority.startIndex)..<closingBracket])
            let suffix = String(authority[authority.index(after: closingBracket)...])
            guard suffix.first == ":", IPv6Address(host) != nil else { return nil }
            portText = String(suffix.dropFirst())
        } else {
            guard authority.filter({ $0 == ":" }).count == 1,
                  let colon = authority.lastIndex(of: ":")
            else {
                return nil
            }
            host = String(authority[..<colon])
            portText = String(authority[authority.index(after: colon)...])
        }

        guard isValidHost(host), !portText.isEmpty,
              let portValue = Int(portText),
              (1...65535).contains(portValue)
        else {
            return nil
        }
        return (host, UInt16(portValue))
    }

    private static func normalizedURLHost(_ host: String) -> String? {
        if host.first == "[", host.last == "]" {
            let value = String(host.dropFirst().dropLast())
            return IPv6Address(value) == nil ? nil : value
        }
        if IPv6Address(host) != nil {
            return host
        }
        guard !host.contains("["), !host.contains("]"), !host.contains(":"), isValidHost(host) else {
            return nil
        }
        return host
    }

    private static func hostHeaderValue(host: String, port: UInt16) -> String {
        let value = host.contains(":") ? "[\(host)]" : host
        return port == 80 ? value : "\(value):\(port)"
    }
}
