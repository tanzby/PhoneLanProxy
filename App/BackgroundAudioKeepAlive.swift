import AVFoundation
import Foundation
import os

enum KeepAliveState: Equatable, Sendable {
    /// Not requested.
    case inactive
    /// Silent playback is running; the process stays alive in the background.
    case active
    /// Playback stopped (interruption, media reset, failed start) and is being
    /// restored.
    case recovering
    /// Automatic recovery gave up. The proxy still works in the foreground;
    /// `ensurePlaying()` retries.
    case degraded(String)
}

@MainActor
protocol BackgroundAudioKeeping: AnyObject {
    var onStateChange: ((KeepAliveState) -> Void)? { get set }

    /// Requests keepalive playback. Never fails outright: problems are
    /// reported through `onStateChange` and retried.
    func start()
    func stop()
    /// Health check for moments the app knows it may play again, such as
    /// returning to the foreground. Retries immediately if playback stopped.
    func ensurePlaying()
}

/// Background execution support for the local proxy.
///
/// A silent, zero-volume, mixable player keeps the process running while the
/// proxy is wanted. Because the session mixes with others, music and video in
/// other apps neither interrupt it nor are affected by it. Calls, Siri and
/// alarms still interrupt it; recovery is attempted when they end regardless
/// of `.shouldResume`, since resuming inaudible mixable audio cannot disturb
/// the user.
@MainActor
// @preconcurrency: the iOS 27 SDK marks AVAudioPlayerDelegate main-actor; older SDKs
// (the CI runner's Xcode 26) leave it nonisolated though callbacks still arrive on main.
final class BackgroundAudioKeepAlive: NSObject, @preconcurrency AVAudioPlayerDelegate, BackgroundAudioKeeping {
    private static let retryDelays: [Duration] = [.seconds(1), .seconds(3), .seconds(10)]
    private static let watchdogInterval: Duration = .seconds(30)
    private static let lostInterruptionEndAfter: TimeInterval = 60

    var onStateChange: ((KeepAliveState) -> Void)?

    private(set) var state: KeepAliveState = .inactive {
        didSet {
            if state != oldValue {
                ProxyLog.keepAlive.notice("state \(String(describing: oldValue), privacy: .public) -> \(String(describing: self.state), privacy: .public)")
                onStateChange?(state)
            }
        }
    }

    private let audioSession: AVAudioSession
    private let notificationCenter: NotificationCenter
    private var audioPlayer: AVAudioPlayer?
    private var notificationTokens: [NSObjectProtocol] = []
    private var wantsPlayback = false
    private var isInterrupted = false
    private var interruptedSince: Date?
    private var recoveryTask: Task<Void, Never>?
    private var watchdogTask: Task<Void, Never>?
    private var generation: UInt64 = 0
    private var lastFailureDetail: String?

    init(
        audioSession: AVAudioSession = .sharedInstance(),
        notificationCenter: NotificationCenter = .default
    ) {
        self.audioSession = audioSession
        self.notificationCenter = notificationCenter
    }

    func start() {
        guard !wantsPlayback else {
            ensurePlaying()
            return
        }

        generation &+= 1
        wantsPlayback = true
        isInterrupted = false
        installObservers(for: generation)
        startWatchdog(for: generation)
        recover()
    }

    func stop() {
        generation &+= 1
        wantsPlayback = false
        isInterrupted = false
        lastFailureDetail = nil
        recoveryTask?.cancel()
        recoveryTask = nil
        watchdogTask?.cancel()
        watchdogTask = nil
        removeObservers()
        teardownPlayer()

        do {
            try audioSession.setActive(false, options: [.notifyOthersOnDeactivation])
        } catch {
            // Deactivation is best-effort during teardown. The proxy must still
            // be allowed to stop when the audio session is already unavailable.
        }
        state = .inactive
    }

    func ensurePlaying() {
        guard wantsPlayback else { return }
        // The caller knows playback is allowed again (e.g. the app is active),
        // so an interruption whose end was never delivered no longer applies.
        isInterrupted = false
        recoveryTask?.cancel()
        recoveryTask = nil
        checkHealth()
    }

    // MARK: - Playback

    private func attemptPlayback() -> Bool {
        do {
            try audioSession.setCategory(.playback, mode: .default, options: [.mixWithOthers])
            // Best effort: ringing calls become a banner instead of an
            // interruption, and a disconnected route does not interrupt.
            try? audioSession.setPrefersNoInterruptionsFromSystemAlerts(true)
            try? audioSession.setPrefersInterruptionOnRouteDisconnect(false)
            try audioSession.setActive(true)

            let player = try audioPlayer ?? makePlayer()
            audioPlayer = player
            guard player.play() else {
                lastFailureDetail = "播放调用返回失败"
                return false
            }
            lastFailureDetail = nil
            return true
        } catch {
            lastFailureDetail = error.localizedDescription
            return false
        }
    }

    private func makePlayer() throws -> AVAudioPlayer {
        let player = try AVAudioPlayer(
            data: Self.silentWAVData,
            fileTypeHint: AVFileType.wav.rawValue
        )
        player.delegate = self
        player.numberOfLoops = -1
        player.volume = 0
        player.prepareToPlay()
        return player
    }

    private func teardownPlayer() {
        let player = audioPlayer
        audioPlayer = nil
        player?.delegate = nil
        player?.stop()
    }

    private func checkHealth() {
        guard wantsPlayback, !isInterrupted, recoveryTask == nil else { return }
        if audioPlayer?.isPlaying == true {
            state = .active
        } else {
            recover()
        }
    }

    /// Tries to resume now, then on a short backoff, before reporting
    /// `.degraded`. Recovery never stops the proxy.
    private func recover() {
        recoveryTask?.cancel()
        recoveryTask = nil
        guard wantsPlayback, !isInterrupted else { return }

        if attemptPlayback() {
            state = .active
            return
        }

        state = .recovering
        let generation = self.generation
        recoveryTask = Task { [weak self] in
            for delay in Self.retryDelays {
                try? await Task.sleep(for: delay)
                guard let self, !Task.isCancelled, generation == self.generation else { return }
                if self.attemptPlayback() {
                    self.recoveryTask = nil
                    self.state = .active
                    return
                }
            }
            guard let self, !Task.isCancelled, generation == self.generation else { return }
            self.recoveryTask = nil
            let detail = self.lastFailureDetail ?? "未知错误"
            self.state = .degraded("后台保活音频无法恢复：\(detail)")
        }
    }

    private func startWatchdog(for generation: UInt64) {
        watchdogTask?.cancel()
        watchdogTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: Self.watchdogInterval)
                guard let self, !Task.isCancelled, generation == self.generation else { return }
                ProxyLog.keepAlive.debug("watchdog tick: state=\(String(describing: self.state), privacy: .public) isPlaying=\(self.audioPlayer?.isPlaying == true, privacy: .public)")
                // Catches playback that stopped without a notification. A
                // degraded keepalive waits for ensurePlaying() instead of
                // retrying forever in the background.
                if case .degraded = self.state { continue }
                // iOS does not guarantee an interruption's `.ended`; if the
                // process is running long after `.began`, try again anyway.
                if self.isInterrupted,
                   let since = self.interruptedSince,
                   Date().timeIntervalSince(since) >= Self.lostInterruptionEndAfter {
                    ProxyLog.keepAlive.notice("watchdog: assuming a lost interruption-ended notification after \(Date().timeIntervalSince(since))s")
                    self.isInterrupted = false
                }
                self.checkHealth()
            }
        }
    }

    // MARK: - AVAudioPlayerDelegate

    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        guard player === audioPlayer, wantsPlayback else { return }
        ProxyLog.keepAlive.error("audioPlayerDidFinishPlaying unexpectedly (successfully=\(flag, privacy: .public))")
        lastFailureDetail = "静音音频播放意外结束"
        teardownPlayer()
        recover()
    }

    func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer, error: Error?) {
        guard player === audioPlayer, wantsPlayback else { return }
        ProxyLog.keepAlive.error("audioPlayerDecodeErrorDidOccur: \(String(describing: error), privacy: .public)")
        lastFailureDetail = error?.localizedDescription ?? "未知解码错误"
        teardownPlayer()
        recover()
    }

    // MARK: - Notifications

    private func installObservers(for generation: UInt64) {
        removeObservers()

        notificationTokens.append(
            notificationCenter.addObserver(
                forName: AVAudioSession.interruptionNotification,
                object: audioSession,
                queue: .main
            ) { [weak self] notification in
                let rawType = (notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? NSNumber)?.uintValue
                Task { @MainActor [weak self] in
                    self?.handleInterruption(rawType: rawType, generation: generation)
                }
            }
        )
        notificationTokens.append(
            notificationCenter.addObserver(
                forName: AVAudioSession.mediaServicesWereLostNotification,
                object: audioSession,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.handleMediaServicesLost(generation: generation)
                }
            }
        )
        notificationTokens.append(
            notificationCenter.addObserver(
                forName: AVAudioSession.mediaServicesWereResetNotification,
                object: audioSession,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.handleMediaServicesReset(generation: generation)
                }
            }
        )
        notificationTokens.append(
            notificationCenter.addObserver(
                forName: AVAudioSession.routeChangeNotification,
                object: audioSession,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor [weak self] in
                    guard let self, generation == self.generation else { return }
                    self.checkHealth()
                }
            }
        )
    }

    private func removeObservers() {
        notificationTokens.forEach(notificationCenter.removeObserver)
        notificationTokens.removeAll(keepingCapacity: false)
    }

    private func handleInterruption(rawType: UInt?, generation: UInt64) {
        guard generation == self.generation,
              wantsPlayback,
              let rawType,
              let type = AVAudioSession.InterruptionType(rawValue: rawType)
        else {
            return
        }

        ProxyLog.keepAlive.notice("interruption \(String(describing: type), privacy: .public)")

        switch type {
        case .began:
            // The system has already paused playback. Do not fight it; wait
            // for the end of the interruption (or ensurePlaying()).
            isInterrupted = true
            interruptedSince = Date()
            recoveryTask?.cancel()
            recoveryTask = nil
            lastFailureDetail = "音频被系统中断"
            state = .recovering

        case .ended:
            // `.shouldResume` is a hint for audible playback. Resuming silent,
            // mixable audio cannot disturb the user, so always try.
            isInterrupted = false
            recover()

        @unknown default:
            isInterrupted = false
            recover()
        }
    }

    private func handleMediaServicesLost(generation: UInt64) {
        guard generation == self.generation, wantsPlayback else { return }
        ProxyLog.keepAlive.notice("mediaServicesWereLost")
        recoveryTask?.cancel()
        recoveryTask = nil
        // The player is invalid until the reset; drop it so the watchdog
        // cannot mistake it for healthy playback.
        teardownPlayer()
        lastFailureDetail = "系统音频服务不可用"
        state = .recovering
    }

    private func handleMediaServicesReset(generation: UInt64) {
        guard generation == self.generation, wantsPlayback else { return }
        ProxyLog.keepAlive.notice("mediaServicesWereReset")
        // After a reset every audio object is invalid: rebuild the session
        // configuration and the player from scratch.
        teardownPlayer()
        isInterrupted = false
        lastFailureDetail = "系统音频服务已重置"
        recover()
    }

    // MARK: - Silent WAV

    private static let silentWAVData: Data = {
        let sampleRate: UInt32 = 44_100
        let channels: UInt16 = 1
        let bitsPerSample: UInt16 = 16
        let bytesPerSample = UInt32(bitsPerSample / 8)
        let frameCount = sampleRate
        let dataSize = frameCount * UInt32(channels) * bytesPerSample
        let byteRate = sampleRate * UInt32(channels) * bytesPerSample
        let blockAlign = channels * (bitsPerSample / 8)

        var data = Data()
        data.append(contentsOf: Array("RIFF".utf8))
        data.append(contentsOf: littleEndianBytes(36 + dataSize))
        data.append(contentsOf: Array("WAVE".utf8))
        data.append(contentsOf: Array("fmt ".utf8))
        data.append(contentsOf: littleEndianBytes(UInt32(16)))
        data.append(contentsOf: littleEndianBytes(UInt16(1)))
        data.append(contentsOf: littleEndianBytes(channels))
        data.append(contentsOf: littleEndianBytes(sampleRate))
        data.append(contentsOf: littleEndianBytes(byteRate))
        data.append(contentsOf: littleEndianBytes(blockAlign))
        data.append(contentsOf: littleEndianBytes(bitsPerSample))
        data.append(contentsOf: Array("data".utf8))
        data.append(contentsOf: littleEndianBytes(dataSize))
        data.append(contentsOf: repeatElement(UInt8(0), count: Int(dataSize)))
        return data
    }()

    private static func littleEndianBytes<T: FixedWidthInteger>(_ value: T) -> [UInt8] {
        withUnsafeBytes(of: value.littleEndian, Array.init)
    }
}
