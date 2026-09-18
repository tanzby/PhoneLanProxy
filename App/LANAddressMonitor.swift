import Foundation
import Network
import Darwin

/// Publishes an address from the currently available Wi-Fi interface.
///
/// The interface name comes from NWPathMonitor, so the app does not assume
/// en0. VPN and cellular interfaces are excluded by requiring Wi-Fi here.
final class LANAddressMonitor: @unchecked Sendable {
    private let monitor = NWPathMonitor(requiredInterfaceType: .wifi)
    private let queue = DispatchQueue(label: "com.example.PhoneLanProxy.lan-address")

    func start(onChange: @escaping @Sendable (String?) -> Void) {
        monitor.pathUpdateHandler = { path in
            let wifiNames = Set(
                path.availableInterfaces
                    .filter { $0.type == .wifi }
                    .map(\.name)
            )
            guard path.status == .satisfied, !wifiNames.isEmpty else {
                onChange(nil)
                return
            }
            onChange(Self.findIPv4Address(onInterfaces: wifiNames))
        }
        monitor.start(queue: queue)
    }

    private static func findIPv4Address(onInterfaces interfaceNames: Set<String>) -> String? {
#if targetEnvironment(simulator)
        // The simulator's host-backed network can expose a tunnel address as
        // its Wi-Fi address. A real device supplies the physical Wi-Fi IP.
        return nil
#else
        var firstAddress: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&firstAddress) == 0, let firstAddress else {
            return nil
        }
        defer { freeifaddrs(firstAddress) }

        var cursor: UnsafeMutablePointer<ifaddrs>? = firstAddress
        while let interface = cursor {
            defer { cursor = interface.pointee.ifa_next }
            let flags = interface.pointee.ifa_flags
            guard flags & UInt32(IFF_UP) != 0,
                  flags & UInt32(IFF_RUNNING) != 0,
                  interfaceNames.contains(String(cString: interface.pointee.ifa_name)),
                  let addressPointer = interface.pointee.ifa_addr,
                  addressPointer.pointee.sa_family == UInt8(AF_INET)
            else {
                continue
            }

            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            let result = getnameinfo(
                addressPointer,
                socklen_t(MemoryLayout<sockaddr_in>.size),
                &host,
                socklen_t(host.count),
                nil,
                0,
                NI_NUMERICHOST
            )
            guard result == 0 else { continue }
            let address = String(
                decoding: host.prefix(while: { $0 != 0 }).map { UInt8(bitPattern: $0) },
                as: UTF8.self
            )
            guard let parsed = IPv4Address(address),
                  !parsed.isLoopback,
                  !parsed.isLinkLocal,
                  !parsed.isMulticast
            else {
                continue
            }
            return address
        }
        return nil
#endif
    }
}
