import ActivityKit
import Foundation
import os
import UIKit

@MainActor
protocol LiveActivityManaging: AnyObject {
    /// False once the system or the user ended the activity, so the app
    /// model recreates it when next in the foreground.
    var isShowing: Bool { get }

    func start(port: UInt16, state: ProxyActivityAttributes.ContentState)
    func update(_ state: ProxyActivityAttributes.ContentState)
    func end()
}

/// Owns the single "proxy running" Live Activity.
///
/// The activity is only an indicator; it never drives proxy state, and it is
/// updated only on events (start, health or connection-count changes, stop).
///
/// There is deliberately no heartbeat or stale date: liveactivitiesd rejects
/// every update from a process that is "only playing background media" —
/// exactly our silent-audio keepalive while the phone is locked (verified in
/// device logs; a background task around the update does not change that).
/// A stale date would therefore always turn a healthy proxy gray. Updates
/// that happen while backgrounded are not sent (they would be rejected);
/// the latest state is sent once the app becomes active again. Stop,
/// force-quit and relaunch end the activity.
@MainActor
final class ProxyLiveActivityController: LiveActivityManaging {
    typealias ContentState = ProxyActivityAttributes.ContentState

    static let minimumUpdateInterval: TimeInterval = 5

    private var activity: Activity<ProxyActivityAttributes>?
    private var latestState: ContentState?
    private var lastSentAt: Date?
    /// Set when a send was skipped because the app was in the background.
    private var needsResendOnActivation = false
    private var pendingUpdateTask: Task<Void, Never>?
    private var stateObservationTask: Task<Void, Never>?
    private var lifecycleObservers: [NSObjectProtocol] = []

    init() {
        // A fresh process always starts with the proxy stopped, so anything
        // left over from a previous process is stale by definition.
        let leftovers = Activity<ProxyActivityAttributes>.activities
        if !leftovers.isEmpty {
            ProxyLog.liveActivity.notice("init: ending \(leftovers.count) leftover activity(ies) from a previous process")
        }
        for leftover in leftovers {
            Self.endImmediately(activityID: leftover.id)
        }
        let center = NotificationCenter.default
        lifecycleObservers = [
            center.addObserver(forName: UIApplication.willTerminateNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.endBeforeTermination() }
            },
            center.addObserver(forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.sendSkippedUpdate() }
            },
        ]
    }

    var isShowing: Bool {
        activity != nil
    }

    func start(port: UInt16, state: ContentState) {
        guard activity == nil else {
            update(state)
            return
        }
        // Activities can only be requested from the foreground; a background
        // caller simply retries the next time the app becomes active.
        guard ActivityAuthorizationInfo().areActivitiesEnabled,
              UIApplication.shared.applicationState != .background
        else {
            ProxyLog.liveActivity.notice("start: skipped (activitiesEnabled=\(ActivityAuthorizationInfo().areActivitiesEnabled, privacy: .public), appState=\(UIApplication.shared.applicationState.rawValue, privacy: .public))")
            return
        }

        do {
            let newActivity = try Activity.request(
                attributes: ProxyActivityAttributes(port: port),
                content: Self.content(for: state),
                pushType: nil
            )
            activity = newActivity
            latestState = state
            lastSentAt = Date()
            observeState(of: newActivity)
            ProxyLog.liveActivity.notice("start: requested activity \(newActivity.id, privacy: .public)")
        } catch {
            // Disabled in Settings, too many activities, or not foreground.
            // The indicator is best-effort; the proxy is unaffected.
            ProxyLog.liveActivity.error("start: Activity.request failed: \(String(describing: error), privacy: .public)")
        }
    }

    func update(_ state: ContentState) {
        guard activity != nil else { return }
        guard state != latestState else {
            ProxyLog.liveActivity.debug("update: skipped, state unchanged")
            return
        }
        latestState = state
        scheduleSend()
    }

    func end() {
        guard let activityID = activity?.id else { return }
        ProxyLog.liveActivity.notice("end: ending activity \(activityID, privacy: .public)")
        clear()
        Self.endImmediately(activityID: activityID)
    }

    // MARK: - Sending

    private func scheduleSend() {
        guard pendingUpdateTask == nil else { return }
        let elapsed = lastSentAt.map { Date().timeIntervalSince($0) } ?? .infinity
        let delay = Self.minimumUpdateInterval - elapsed
        guard delay > 0 else {
            send(reason: "update")
            return
        }
        pendingUpdateTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard let self, !Task.isCancelled else { return }
            self.pendingUpdateTask = nil
            self.send(reason: "debounced update")
        }
    }

    private func send(reason: String) {
        guard let activityID = activity?.id, let latestState else { return }
        guard UIApplication.shared.applicationState != .background else {
            needsResendOnActivation = true
            ProxyLog.liveActivity.debug("send(\(reason, privacy: .public)): deferred until active")
            return
        }
        needsResendOnActivation = false
        lastSentAt = Date()
        let content = Self.content(for: latestState)
        ProxyLog.liveActivity.notice("send(\(reason, privacy: .public)): health=\(String(describing: latestState.health), privacy: .public) connections=\(latestState.connectionCount)")
        Task {
            await Self.update(activityID: activityID, content: content)
        }
    }

    private func sendSkippedUpdate() {
        guard needsResendOnActivation else { return }
        pendingUpdateTask?.cancel()
        pendingUpdateTask = nil
        send(reason: "after activation")
    }

    private static func content(for state: ContentState) -> ActivityContent<ContentState> {
        ActivityContent(state: state, staleDate: nil)
    }

    // MARK: - Lifecycle

    private func observeState(of observed: Activity<ProxyActivityAttributes>) {
        stateObservationTask?.cancel()
        stateObservationTask = Task { [weak self] in
            for await state in observed.activityStateUpdates {
                guard state == .ended || state == .dismissed else { continue }
                guard let self, self.activity?.id == observed.id else { return }
                // Ended by the system (duration limit) or dismissed by the
                // user; the app model restarts it when next in the foreground.
                ProxyLog.liveActivity.notice("observeState: activity \(observed.id, privacy: .public) became \(String(describing: state), privacy: .public)")
                self.clear()
                return
            }
        }
    }

    private func clear() {
        activity = nil
        latestState = nil
        lastSentAt = nil
        needsResendOnActivation = false
        pendingUpdateTask?.cancel()
        pendingUpdateTask = nil
        stateObservationTask?.cancel()
        stateObservationTask = nil
    }

    /// Best-effort removal when the user force-quits a running app. The wait
    /// is bounded so termination can never hang on ActivityKit.
    private func endBeforeTermination() {
        guard let activityID = activity?.id else { return }
        clear()
        let finished = DispatchSemaphore(value: 0)
        Task.detached {
            await Self.end(activityID: activityID)
            finished.signal()
        }
        _ = finished.wait(timeout: .now() + 2)
    }

    private static func endImmediately(activityID: String) {
        Task {
            await end(activityID: activityID)
        }
    }

    // `Activity` is not Sendable, so only its id crosses isolation domains;
    // these helpers look the instance up where they use it.

    nonisolated private static func update(
        activityID: String,
        content: ActivityContent<ContentState>
    ) async {
        guard let activity = Activity<ProxyActivityAttributes>.activities.first(where: { $0.id == activityID }) else {
            ProxyLog.liveActivity.error("update: activity \(activityID, privacy: .public) not found in Activity.activities, update dropped")
            return
        }
        await activity.update(content)
    }

    nonisolated private static func end(activityID: String) async {
        guard let activity = Activity<ProxyActivityAttributes>.activities.first(where: { $0.id == activityID }) else {
            return
        }
        await activity.end(nil, dismissalPolicy: .immediate)
    }
}
