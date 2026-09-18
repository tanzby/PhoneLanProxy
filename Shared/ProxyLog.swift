import os

/// Unified-logging categories used by the app.
///
/// Entries land in the system log, which keeps them even while the app was
/// backgrounded, locked, or suspended — pull them back after the fact with
/// Xcode's Devices console (Window > Devices and Simulators > Open Console,
/// filtered to `subsystem:com.zubingtan.PhoneLanProxy`) or:
/// `log collect --device --start "..." --output out.logarchive`, then
/// `log show out.logarchive --predicate 'subsystem == "com.zubingtan.PhoneLanProxy"'`.
enum ProxyLog {
    private static let subsystem = "com.zubingtan.PhoneLanProxy"

    /// Live Activity lifecycle: start/update/refresh/end.
    static let liveActivity = Logger(subsystem: subsystem, category: "liveActivity")
    /// Background audio keepalive state and interruption handling.
    static let keepAlive = Logger(subsystem: subsystem, category: "keepAlive")
    /// AppModel supervision: scene phase, proxy snapshots, restarts.
    static let appModel = Logger(subsystem: subsystem, category: "appModel")
}
