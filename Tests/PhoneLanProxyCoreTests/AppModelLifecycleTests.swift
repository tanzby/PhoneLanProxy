#if canImport(UIKit) && canImport(AVFoundation) && canImport(ActivityKit)

import SwiftUI
import XCTest
@testable import PhoneLanProxyCore

@MainActor
final class AppModelLifecycleTests: XCTestCase {
    private var proxy: FakeProxyServer!
    private var audio: FakeBackgroundAudio!
    private var liveActivity: FakeLiveActivity!
    private var sleeper: RecordingSleeper!

    override func setUp() async throws {
        proxy = FakeProxyServer()
        audio = FakeBackgroundAudio()
        liveActivity = FakeLiveActivity()
        sleeper = RecordingSleeper()
    }

    private func makeModel(suspendRestarts: Bool = false) -> AppModel {
        let sleeper = self.sleeper!
        return AppModel(
            proxyServer: proxy,
            addressMonitor: FakeLANAddressMonitor(),
            backgroundAudio: audio,
            liveActivity: liveActivity,
            sleep: { duration in
                await sleeper.record(duration)
                if suspendRestarts {
                    try await Task.sleep(for: .seconds(3600))
                }
            }
        )
    }

    func testKeepAliveStartFailureStillStartsListener() async {
        audio.stateOnStart = .degraded("测试后台保活启动失败")
        let model = makeModel()

        model.toggleProxy()
        proxy.emit(.running)
        await drain()

        XCTAssertEqual(audio.startCount, 1)
        XCTAssertEqual(proxy.startCount, 1)
        XCTAssertEqual(model.status, .running)
        XCTAssertEqual(model.statusText, "正在代理")
        XCTAssertFalse(model.isHealthy)
        XCTAssertNotNil(model.keepAliveWarning)
        XCTAssertEqual(liveActivity.states.last?.health, .recovering)
    }

    func testKeepAliveDegradationKeepsListenerRunning() async {
        let model = makeModel()

        model.toggleProxy()
        proxy.emit(.running)
        await drain()
        audio.emit(.degraded("测试音频错误"))

        XCTAssertEqual(proxy.stopCount, 0)
        XCTAssertTrue(model.isActive)
        XCTAssertEqual(model.statusText, "正在代理")
        XCTAssertTrue(model.keepAliveWarning?.contains("测试音频错误") == true)
        XCTAssertEqual(liveActivity.states.last?.health, .recovering)

        audio.emit(.active)
        XCTAssertNil(model.keepAliveWarning)
        XCTAssertTrue(model.isHealthy)
        XCTAssertEqual(liveActivity.states.last?.health, .running)
    }

    func testReturningToForegroundChecksKeepAliveOnlyWhileWanted() {
        let model = makeModel()

        model.handleScenePhase(.active)
        XCTAssertEqual(audio.ensurePlayingCount, 0)

        model.toggleProxy()
        model.handleScenePhase(.background)
        model.handleScenePhase(.active)
        XCTAssertEqual(audio.ensurePlayingCount, 1)
    }

    func testListenerFailureRestartsWithBackoffThatResetsOnSuccess() async {
        let model = makeModel()

        model.toggleProxy()
        proxy.emit(.running)
        await drain()
        proxy.emit(.failed)
        await waitUntil { self.proxy.startCount == 2 }

        XCTAssertEqual(proxy.startCount, 2)
        XCTAssertEqual(sleeper.durations, [.seconds(1)])
        XCTAssertEqual(model.statusText, "正在恢复")
        XCTAssertEqual(liveActivity.states.last?.health, .recovering)
        XCTAssertEqual(audio.stopCount, 0)

        proxy.emit(.failed)
        await waitUntil { self.proxy.startCount == 3 }
        XCTAssertEqual(proxy.startCount, 3)
        XCTAssertEqual(sleeper.durations, [.seconds(1), .seconds(2)])

        proxy.emit(.running)
        await drain()
        XCTAssertEqual(model.statusText, "正在代理")
        XCTAssertEqual(liveActivity.states.last?.health, .running)

        proxy.emit(.failed)
        await waitUntil { self.proxy.startCount == 4 }
        XCTAssertEqual(sleeper.durations, [.seconds(1), .seconds(2), .seconds(1)])
    }

    func testStopCancelsPendingRestart() async {
        let model = makeModel(suspendRestarts: true)

        model.toggleProxy()
        proxy.emit(.running)
        await drain()
        proxy.emit(.failed)
        await waitUntil { self.sleeper.durations.count == 1 }
        XCTAssertEqual(sleeper.durations.count, 1)

        model.stopProxy()
        await drain()

        XCTAssertEqual(proxy.startCount, 1)
        XCTAssertEqual(proxy.stopCount, 1)
        XCTAssertFalse(model.isActive)
        XCTAssertEqual(model.statusText, "未启动")
        XCTAssertEqual(liveActivity.endCount, 1)
    }

    func testForegroundRestartsFailedListenerWithoutWaitingForBackoff() async {
        let model = makeModel(suspendRestarts: true)

        model.toggleProxy()
        proxy.emit(.running)
        await drain()
        proxy.emit(.failed)
        await drain()
        XCTAssertEqual(proxy.startCount, 1)

        model.handleScenePhase(.active)
        XCTAssertEqual(proxy.startCount, 2)
    }

    func testLateSnapshotsAfterStopAreIgnored() async {
        let model = makeModel()

        model.toggleProxy()
        proxy.emit(.starting)
        await drain()
        model.stopProxy()
        proxy.emit(.running)
        await drain()

        XCTAssertFalse(model.isActive)
        XCTAssertNotEqual(model.status, .running)
        XCTAssertEqual(liveActivity.startCount, 0)

        proxy.emit(.stopped)
        await drain()
        XCTAssertEqual(model.status, .stopped)

        model.toggleProxy()
        XCTAssertEqual(audio.startCount, 2)
        XCTAssertEqual(proxy.startCount, 2)
    }

    func testStaleStoppedSnapshotDoesNotTearDownQuickRestart() async {
        let model = makeModel()

        model.toggleProxy()
        proxy.emit(.running)
        await drain()
        model.stopProxy()
        model.toggleProxy()
        // The .stopped echo of the first stop arrives after the restart.
        proxy.emit(.stopped)
        await drain()

        XCTAssertTrue(model.isActive)
        XCTAssertNotEqual(model.status, .stopped)
        XCTAssertEqual(audio.stopCount, 1)
        XCTAssertTrue(sleeper.durations.isEmpty)

        proxy.emit(.starting)
        proxy.emit(.running)
        await drain()
        XCTAssertTrue(model.isHealthy)
    }

    func testLiveActivityFollowsProxyLifecycle() async {
        let model = makeModel()

        model.toggleProxy()
        proxy.emit(.starting)
        await drain()
        XCTAssertEqual(liveActivity.startCount, 0)

        proxy.emit(.running)
        await drain()
        XCTAssertEqual(liveActivity.startCount, 1)
        XCTAssertTrue(liveActivity.isShowing)
        XCTAssertEqual(liveActivity.states.last?.health, .running)

        proxy.emit(.running, connections: 3)
        await drain()
        XCTAssertEqual(liveActivity.startCount, 1)
        XCTAssertEqual(liveActivity.states.last?.connectionCount, 3)

        model.stopProxy()
        XCTAssertEqual(liveActivity.endCount, 1)
        XCTAssertFalse(liveActivity.isShowing)
    }

    func testConnectionTelemetryUpdatesModelWithoutUpdatingLiveActivity() async {
        let model = makeModel()
        let connection = ProxyConnectionSnapshot(
            phase: .relaying,
            protocolKind: .httpConnect,
            host: "example.com",
            port: 443,
            clientAddress: "192.168.1.20:52000",
            uploadedBytes: 10,
            downloadedBytes: 20,
            uploadRate: 100,
            downloadRate: 200
        )

        model.toggleProxy()
        proxy.emit(.running)
        await drain()
        let activityUpdateCount = liveActivity.states.count

        proxy.emit(.running, connections: 1, active: [connection])
        await drain()

        XCTAssertEqual(model.activeConnections, [connection])
        XCTAssertEqual(liveActivity.states.count, activityUpdateCount + 1)

        let updatedConnection = ProxyConnectionSnapshot(
            id: connection.id,
            phase: .relaying,
            protocolKind: .httpConnect,
            host: "example.com",
            port: 443,
            clientAddress: "192.168.1.20:52000",
            acceptedAt: connection.acceptedAt,
            connectedAt: connection.connectedAt,
            uploadedBytes: 100,
            downloadedBytes: 200,
            uploadRate: 1000,
            downloadRate: 2000
        )
        proxy.emit(.running, connections: 1, active: [updatedConnection])
        await drain()

        XCTAssertEqual(model.activeConnections, [updatedConnection])
        XCTAssertEqual(liveActivity.states.count, activityUpdateCount + 1)
    }

    func testLiveActivityIsRecreatedInForegroundAfterSystemEndsIt() async {
        let model = makeModel()

        model.toggleProxy()
        proxy.emit(.running)
        await drain()
        liveActivity.endBySystem()
        XCTAssertFalse(liveActivity.isShowing)

        model.handleScenePhase(.active)
        XCTAssertEqual(liveActivity.startCount, 2)
        XCTAssertTrue(liveActivity.isShowing)
    }

    func testRestartDelaysBackOffToThirtySeconds() {
        XCTAssertEqual(AppModel.restartDelay(forAttempt: 0), .seconds(1))
        XCTAssertEqual(AppModel.restartDelay(forAttempt: 1), .seconds(2))
        XCTAssertEqual(AppModel.restartDelay(forAttempt: 4), .seconds(16))
        XCTAssertEqual(AppModel.restartDelay(forAttempt: 5), .seconds(30))
        XCTAssertEqual(AppModel.restartDelay(forAttempt: 50), .seconds(30))
    }

    /// Lets queued main-queue snapshot deliveries run.
    private func drain() async {
        for _ in 0..<20 {
            await Task.yield()
        }
    }

    /// Restart tasks hop through the injected (nonisolated) sleep, so wait on
    /// their observable effect rather than a fixed number of yields.
    private func waitUntil(_ condition: () -> Bool) async {
        let deadline = ContinuousClock.now + .seconds(2)
        while !condition(), ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(1))
        }
    }
}

private final class FakeProxyServer: ProxyServing {
    var onSnapshot: (@Sendable (ProxyServerSnapshot) -> Void)?
    private(set) var startCount = 0
    private(set) var stopCount = 0

    func start() {
        startCount += 1
    }

    func stop() {
        stopCount += 1
    }

    func emit(
        _ status: ProxyServerStatus,
        connections: Int = 0,
        active: [ProxyConnectionSnapshot] = [],
        ended: [ProxyConnectionSnapshot] = []
    ) {
        onSnapshot?(
            ProxyServerSnapshot(
                status: status,
                port: ProxyServer.defaultPort,
                connectionCount: connections,
                activeConnections: active,
                endedConnections: ended
            )
        )
    }
}

@MainActor
private final class FakeBackgroundAudio: BackgroundAudioKeeping {
    var onStateChange: ((KeepAliveState) -> Void)?
    var stateOnStart: KeepAliveState = .active
    private(set) var startCount = 0
    private(set) var stopCount = 0
    private(set) var ensurePlayingCount = 0

    func start() {
        startCount += 1
        onStateChange?(stateOnStart)
    }

    func stop() {
        stopCount += 1
        onStateChange?(.inactive)
    }

    func ensurePlaying() {
        ensurePlayingCount += 1
    }

    func emit(_ state: KeepAliveState) {
        onStateChange?(state)
    }
}

@MainActor
private final class FakeLiveActivity: LiveActivityManaging {
    private(set) var isShowing = false
    private(set) var startCount = 0
    private(set) var endCount = 0
    private(set) var states: [ProxyActivityAttributes.ContentState] = []

    func start(port: UInt16, state: ProxyActivityAttributes.ContentState) {
        guard !isShowing else { return }
        startCount += 1
        isShowing = true
        states.append(state)
    }

    func update(_ state: ProxyActivityAttributes.ContentState) {
        states.append(state)
    }


    func end() {
        guard isShowing else { return }
        isShowing = false
        endCount += 1
    }

    func endBySystem() {
        isShowing = false
    }
}

@MainActor
private final class RecordingSleeper {
    private(set) var durations: [Duration] = []

    func record(_ duration: Duration) {
        durations.append(duration)
    }
}

private final class FakeLANAddressMonitor: LANAddressMonitoring {
    func start(onChange: @escaping @Sendable (String?) -> Void) {}
}

#endif
