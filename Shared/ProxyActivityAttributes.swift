import ActivityKit
import Foundation

/// Live Activity model shared by the app (which starts and updates it) and
/// the widget extension (which renders it in the Dynamic Island and on the
/// Lock Screen).
///
/// Updated only on events; see `ProxyLiveActivityController` for why there is
/// no periodic refresh or stale date.
struct ProxyActivityAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable, Sendable {
        enum Health: String, Codable, Hashable, Sendable {
            /// Listener is accepting connections and the keepalive is healthy.
            case running
            /// The user wants the proxy running, but the listener or the
            /// background keepalive is currently being recovered.
            case recovering
        }

        var health: Health
        var connectionCount: Int
        var lanAddress: String?
    }

    var port: UInt16
}
