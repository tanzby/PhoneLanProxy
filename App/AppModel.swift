import Observation
import SwiftUI
import Foundation
import os
import PhoneLanProxyCore

protocol ProxyServing: AnyObject {
    var onSnapshot: (@Sendable (ProxyServerSnapshot) -> Void)? { get set }

    func start()
    func stop()
}

extension ProxyServer: ProxyServing {}

protocol LANAddressMonitoring: AnyObject {
    func start(onChange: @escaping @Sendable (String?) -> Void)
}

extension LANAddressMonitor: LANAddressMonitoring {}

/// Supervises the proxy from the user's intent (`wantsRunning`) rather than
/// from whatever the listener or the keepalive last reported.
///
/// While the proxy is wanted, a failed listener is restarted with backoff and
/// a keepalive problem only degrades background execution; neither stops the
/// proxy. Only `stopProxy()` does.
@MainActor
@Observable
final class AppModel {
    var status: ProxyServerStatus = .stopped
    var connectionCount = 0
    var activeConnections: [ProxyConnectionSnapshot] = []
    var endedConnections: [ProxyConnectionSnapshot] = []
    var errorDescription: String?
    var lanAddress: String?
    private(set) var wantsRunning = false
    private(set) var listenerRecovering = false
    private(set) var keepAliveState: KeepAliveState = .inactive

    let port = ProxyServer.defaultPort

    @ObservationIgnored private let proxyServer: any ProxyServing
    @ObservationIgnored private let addressMonitor: any LANAddressMonitoring
    @ObservationIgnored private let backgroundAudio: any BackgroundAudioKeeping
    @ObservationIgnored private let liveActivity: any LiveActivityManaging
    @ObservationIgnored private let sleep: @Sendable (Duration) async throws -> Void
    @ObservationIgnored private var restartTask: Task<Void, Never>?
    @ObservationIgnored private var restartAttempt = 0

    init(
        proxyServer: any ProxyServing = ProxyServer(),
        addressMonitor: any LANAddressMonitoring = LANAddressMonitor(),
        backgroundAudio: any BackgroundAudioKeeping = BackgroundAudioKeepAlive(),
        liveActivity: any LiveActivityManaging = ProxyLiveActivityController(),
        sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }
    ) {
        self.proxyServer = proxyServer
        self.addressMonitor = addressMonitor
        self.backgroundAudio = backgroundAudio
        self.liveActivity = liveActivity
        self.sleep = sleep

        proxyServer.onSnapshot = { [weak self] snapshot in
            DispatchQueue.main.async { [weak self] in
                self?.apply(snapshot)
            }
        }
        addressMonitor.start { [weak self] address in
            Task { @MainActor [weak self] in
                self?.lanAddress = address
                self?.syncLiveActivity()
            }
        }
        backgroundAudio.onStateChange = { [weak self] state in
            ProxyLog.appModel.notice("keepAliveState -> \(String(describing: state), privacy: .public)")
            self?.keepAliveState = state
            self?.syncLiveActivity()
        }
    }

    var isActive: Bool {
        wantsRunning
    }

    /// True when the listener is accepting connections and the process can
    /// stay alive in the background.
    var isHealthy: Bool {
        wantsRunning && status == .running && !listenerRecovering && keepAliveState == .active
    }

    var statusText: String {
        guard wantsRunning else { return "未启动" }
        if listenerRecovering { return "正在恢复" }
        switch status {
        case .running:
            return "正在代理"
        case .starting, .stopped:
            return "正在启动"
        case .failed:
            return "正在恢复"
        }
    }

    var keepAliveWarning: String? {
        guard wantsRunning, case let .degraded(message) = keepAliveState else { return nil }
        return "\(message)。代理在前台仍可使用，回到 App 时会自动重试后台保活。"
    }

    func toggleProxy() {
        if wantsRunning {
            stopProxy()
        } else {
            startProxy()
        }
    }

    func startProxy() {
        guard !wantsRunning else { return }
        wantsRunning = true
        listenerRecovering = false
        errorDescription = nil
        clearConnectionHistory()
        restartAttempt = 0
        // The keepalive never blocks the proxy: if it cannot start, the proxy
        // still serves in the foreground and the keepalive keeps retrying.
        backgroundAudio.start()
        proxyServer.start()
    }

    func stopProxy() {
        wantsRunning = false
        listenerRecovering = false
        errorDescription = nil
        clearConnectionHistory()
        cancelRestart()
        backgroundAudio.stop()
        proxyServer.stop()
        liveActivity.end()
    }

    func handleScenePhase(_ phase: ScenePhase) {
        ProxyLog.appModel.notice("scenePhase -> \(String(describing: phase), privacy: .public) (wantsRunning=\(self.wantsRunning, privacy: .public))")
        guard phase == .active, wantsRunning else { return }
        backgroundAudio.ensurePlaying()
        // The listening socket can be reclaimed while the app is suspended;
        // restart right away instead of waiting out the backoff.
        if status == .failed || listenerRecovering {
            cancelRestart()
            proxyServer.start()
        }
        // Recreates the Live Activity if the system or the user ended it.
        syncLiveActivity()
    }

    private func apply(_ snapshot: ProxyServerSnapshot) {
        ProxyLog.appModel.debug("snapshot: status=\(String(describing: snapshot.status), privacy: .public) connections=\(snapshot.connectionCount) (wantsRunning=\(self.wantsRunning, privacy: .public))")
        if wantsRunning {
            // While the proxy is wanted, `.stopped` can only be the late echo
            // of an earlier stop that raced a restart; the start that followed
            // it is already queued on the server.
            guard snapshot.status != .stopped else { return }
        } else {
            // Late `.starting`/`.running` echoes of a cancelled start, and
            // failures after the user stopped, no longer matter.
            guard snapshot.status == .stopped else { return }
        }

        let statusChanged = status != snapshot.status
        let connectionCountChanged = connectionCount != snapshot.connectionCount
        status = snapshot.status
        connectionCount = snapshot.connectionCount
        activeConnections = snapshot.activeConnections
        endedConnections = snapshot.endedConnections
        errorDescription = snapshot.errorDescription

        switch snapshot.status {
        case .running:
            listenerRecovering = false
            restartAttempt = 0
        case .failed:
            scheduleListenerRestart()
        case .starting, .stopped:
            break
        }
        // Connection telemetry (host, phase, counters and rates) is sampled
        // independently and must not wake Live Activity. Only lifecycle and
        // connection-count changes are meaningful to that surface.
        if statusChanged || connectionCountChanged {
            syncLiveActivity()
        }
    }

    private func clearConnectionHistory() {
        activeConnections = []
        endedConnections = []
    }

    private func scheduleListenerRestart() {
        guard wantsRunning, restartTask == nil else { return }
        listenerRecovering = true
        let delay = Self.restartDelay(forAttempt: restartAttempt)
        restartAttempt += 1
        let sleep = self.sleep
        restartTask = Task { [weak self] in
            try? await sleep(delay)
            guard let self, !Task.isCancelled else { return }
            self.restartTask = nil
            guard self.wantsRunning else { return }
            self.proxyServer.start()
        }
    }

    private func cancelRestart() {
        restartTask?.cancel()
        restartTask = nil
    }

    /// 1s, 2s, 4s, 8s, 16s, then every 30s.
    static func restartDelay(forAttempt attempt: Int) -> Duration {
        .seconds(min(30, 1 << min(attempt, 5)))
    }

    private func syncLiveActivity() {
        guard wantsRunning else {
            liveActivity.end()
            return
        }
        let state = ProxyActivityAttributes.ContentState(
            health: isHealthy ? .running : .recovering,
            connectionCount: connectionCount,
            lanAddress: lanAddress
        )
        if liveActivity.isShowing {
            liveActivity.update(state)
        } else if status == .running {
            ProxyLog.appModel.notice("syncLiveActivity: starting (isHealthy=\(self.isHealthy, privacy: .public))")
            liveActivity.start(port: port, state: state)
        }
    }
}
