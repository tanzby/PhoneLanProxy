import Foundation
import Network

public enum ProxyServerStatus: Equatable, Sendable {
    case stopped
    case starting
    case running
    case failed
}

public enum ProxyConnectionProtocol: String, Equatable, Sendable {
    case socks5 = "SOCKS5"
    case http = "HTTP"
    case httpConnect = "HTTP CONNECT"

    public var displayName: String {
        rawValue
    }
}

public enum ProxyConnectionPhase: String, Equatable, Sendable {
    case detecting = "识别协议"
    case handshaking = "握手中"
    case connecting = "连接目标"
    case relaying = "传输中"
    case ended = "已结束"

    public var displayName: String {
        rawValue
    }
}

public enum ProxyConnectionEndReason: Equatable, Sendable {
    case completed
    case clientDisconnected
    case protocolError
    case targetConnectionFailed
    case relayFailed
    case timeout
    case cancelled

    public var displayName: String {
        switch self {
        case .completed:
            return "连接已关闭"
        case .clientDisconnected:
            return "客户端已断开"
        case .protocolError:
            return "协议错误"
        case .targetConnectionFailed:
            return "目标连接失败"
        case .relayFailed:
            return "转发中断"
        case .timeout:
            return "连接超时"
        case .cancelled:
            return "代理已停止"
        }
    }

    public var isFailure: Bool {
        switch self {
        case .completed, .clientDisconnected, .cancelled:
            return false
        case .protocolError, .targetConnectionFailed, .relayFailed, .timeout:
            return true
        }
    }
}

/// Immutable metadata and traffic counters for one inbound proxy TCP session.
public struct ProxyConnectionSnapshot: Equatable, Sendable, Identifiable {
    public let id: UUID
    public let phase: ProxyConnectionPhase
    public let protocolKind: ProxyConnectionProtocol?
    public let host: String?
    public let port: UInt16?
    public let clientAddress: String?
    public let acceptedAt: Date
    public let connectedAt: Date?
    public let endedAt: Date?
    public let lastActivityAt: Date
    public let uploadedBytes: UInt64
    public let downloadedBytes: UInt64
    public let uploadRate: Double
    public let downloadRate: Double
    public let averageUploadRate: Double
    public let averageDownloadRate: Double
    public let endReason: ProxyConnectionEndReason?
    public let failureDescription: String?

    public init(
        id: UUID = UUID(),
        phase: ProxyConnectionPhase,
        protocolKind: ProxyConnectionProtocol? = nil,
        host: String? = nil,
        port: UInt16? = nil,
        clientAddress: String? = nil,
        acceptedAt: Date = Date(),
        connectedAt: Date? = nil,
        endedAt: Date? = nil,
        lastActivityAt: Date? = nil,
        uploadedBytes: UInt64 = 0,
        downloadedBytes: UInt64 = 0,
        uploadRate: Double = 0,
        downloadRate: Double = 0,
        averageUploadRate: Double = 0,
        averageDownloadRate: Double = 0,
        endReason: ProxyConnectionEndReason? = nil,
        failureDescription: String? = nil
    ) {
        self.id = id
        self.phase = phase
        self.protocolKind = protocolKind
        self.host = host
        self.port = port
        self.clientAddress = clientAddress
        self.acceptedAt = acceptedAt
        self.connectedAt = connectedAt
        self.endedAt = endedAt
        self.lastActivityAt = lastActivityAt ?? endedAt ?? connectedAt ?? acceptedAt
        self.uploadedBytes = uploadedBytes
        self.downloadedBytes = downloadedBytes
        self.uploadRate = uploadRate
        self.downloadRate = downloadRate
        self.averageUploadRate = averageUploadRate
        self.averageDownloadRate = averageDownloadRate
        self.endReason = endReason
        self.failureDescription = failureDescription
    }

    public var endpoint: String? {
        guard let host else { return nil }
        guard let port else { return host }
        return host.contains(":") ? "[\(host)]:\(port)" : "\(host):\(port)"
    }

    public var isEnded: Bool {
        endedAt != nil
    }

    public var duration: TimeInterval {
        let end = endedAt ?? Date()
        return max(0, end.timeIntervalSince(acceptedAt))
    }
}

enum ProxyConnectionEvent: Sendable {
    case phase(ProxyConnectionPhase)
    case protocolDetected(ProxyConnectionProtocol)
    case target(protocolKind: ProxyConnectionProtocol, host: String, port: UInt16)
    case outboundReady
    case relayStarted
    case bytes(uploaded: Int, downloaded: Int)
    case finished(ProxyConnectionEndReason, failureDescription: String?)
}

public enum TCPRelayTermination: Sendable {
    case completed
    case failed
    case cancelled
}

public struct ProxyServerSnapshot: Equatable, Sendable {
    public let status: ProxyServerStatus
    public let port: UInt16
    public let connectionCount: Int
    public let activeConnections: [ProxyConnectionSnapshot]
    public let endedConnections: [ProxyConnectionSnapshot]
    public let errorDescription: String?

    public init(
        status: ProxyServerStatus,
        port: UInt16,
        connectionCount: Int,
        activeConnections: [ProxyConnectionSnapshot] = [],
        endedConnections: [ProxyConnectionSnapshot] = [],
        errorDescription: String? = nil
    ) {
        self.status = status
        self.port = port
        self.connectionCount = connectionCount
        self.activeConnections = activeConnections
        self.endedConnections = endedConnections
        self.errorDescription = errorDescription
    }
}

private struct MutableProxyConnection {
    let id: UUID
    let acceptedAt: Date
    let clientAddress: String?
    var phase: ProxyConnectionPhase = .detecting
    var protocolKind: ProxyConnectionProtocol?
    var host: String?
    var port: UInt16?
    var connectedAt: Date?
    var endedAt: Date?
    var lastActivityAt: Date
    var uploadedBytes: UInt64 = 0
    var downloadedBytes: UInt64 = 0
    var uploadRate: Double = 0
    var downloadRate: Double = 0
    var averageUploadRate: Double = 0
    var averageDownloadRate: Double = 0
    var endReason: ProxyConnectionEndReason?
    var failureDescription: String?
    var lastSampleAt: Date
    var sampledUploadedBytes: UInt64 = 0
    var sampledDownloadedBytes: UInt64 = 0

    init(id: UUID, clientAddress: String?, acceptedAt: Date) {
        self.id = id
        self.acceptedAt = acceptedAt
        self.clientAddress = clientAddress
        self.lastActivityAt = acceptedAt
        self.lastSampleAt = acceptedAt
    }

    var snapshot: ProxyConnectionSnapshot {
        ProxyConnectionSnapshot(
            id: id,
            phase: phase,
            protocolKind: protocolKind,
            host: host,
            port: port,
            clientAddress: clientAddress,
            acceptedAt: acceptedAt,
            connectedAt: connectedAt,
            endedAt: endedAt,
            lastActivityAt: lastActivityAt,
            uploadedBytes: uploadedBytes,
            downloadedBytes: downloadedBytes,
            uploadRate: uploadRate,
            downloadRate: downloadRate,
            averageUploadRate: averageUploadRate,
            averageDownloadRate: averageDownloadRate,
            endReason: endReason,
            failureDescription: failureDescription
        )
    }
}

/// Queue-confined connection history store. Keeping this separate from the
/// Network.framework listener makes lifecycle and rate behavior deterministic
/// to test without opening real sockets.
final class ProxyConnectionTracker {
    static let historyLimit = 200

    private let now: () -> Date
    private var connections: [UUID: MutableProxyConnection] = [:]
    private var endedConnections: [ProxyConnectionSnapshot] = []

    init(now: @escaping () -> Date = { Date() }) {
        self.now = now
    }

    var activeCount: Int {
        connections.count
    }

    var activeSnapshots: [ProxyConnectionSnapshot] {
        connections.values
            .map(\.snapshot)
            .sorted { $0.acceptedAt > $1.acceptedAt }
    }

    var endedSnapshots: [ProxyConnectionSnapshot] {
        endedConnections
    }

    func accept(id: UUID, clientAddress: String?) {
        connections[id] = MutableProxyConnection(
            id: id,
            clientAddress: clientAddress,
            acceptedAt: now()
        )
    }

    @discardableResult
    func handle(_ event: ProxyConnectionEvent, id: UUID) -> Bool {
        guard connections[id] != nil else { return false }
        var shouldEmit = true
        switch event {
        case let .phase(phase):
            connections[id]?.phase = phase
        case let .protocolDetected(protocolKind):
            connections[id]?.protocolKind = protocolKind
        case let .target(protocolKind, host, port):
            connections[id]?.protocolKind = protocolKind
            connections[id]?.host = host
            connections[id]?.port = port
            connections[id]?.phase = .connecting
        case .outboundReady:
            connections[id]?.connectedAt = now()
        case .relayStarted:
            connections[id]?.phase = .relaying
        case let .bytes(uploaded, downloaded):
            shouldEmit = false
            let uploadCount = UInt64(max(0, uploaded))
            let downloadCount = UInt64(max(0, downloaded))
            connections[id]?.uploadedBytes += uploadCount
            connections[id]?.downloadedBytes += downloadCount
            if uploadCount > 0 || downloadCount > 0 {
                connections[id]?.lastActivityAt = now()
            }
        case let .finished(reason, failureDescription):
            shouldEmit = false
            finish(
                id: id,
                reason: reason,
                failureDescription: failureDescription
            )
        }
        return shouldEmit
    }

    func remove(id: UUID) {
        guard connections[id] != nil else { return }
        finish(id: id, reason: .cancelled, failureDescription: nil)
    }

    func sample() {
        guard !connections.isEmpty else { return }
        let sampleDate = now()
        for id in connections.keys {
            guard var connection = connections[id] else { continue }
            let elapsed = max(sampleDate.timeIntervalSince(connection.lastSampleAt), 0.001)
            connection.uploadRate = Double(connection.uploadedBytes - connection.sampledUploadedBytes) / elapsed
            connection.downloadRate = Double(connection.downloadedBytes - connection.sampledDownloadedBytes) / elapsed
            connection.sampledUploadedBytes = connection.uploadedBytes
            connection.sampledDownloadedBytes = connection.downloadedBytes
            connection.lastSampleAt = sampleDate
            connections[id] = connection
        }
    }

    func reset() {
        connections.removeAll(keepingCapacity: false)
        endedConnections.removeAll(keepingCapacity: false)
    }

    private func finish(
        id: UUID,
        reason: ProxyConnectionEndReason,
        failureDescription: String?
    ) {
        guard var connection = connections.removeValue(forKey: id) else {
            return
        }
        let endedAt = now()
        connection.endedAt = endedAt
        connection.phase = .ended
        connection.endReason = reason
        connection.failureDescription = failureDescription
        let elapsed = max(endedAt.timeIntervalSince(connection.acceptedAt), 0.001)
        connection.averageUploadRate = Double(connection.uploadedBytes) / elapsed
        connection.averageDownloadRate = Double(connection.downloadedBytes) / elapsed
        connection.uploadRate = 0
        connection.downloadRate = 0
        endedConnections.insert(connection.snapshot, at: 0)
        if endedConnections.count > Self.historyLimit {
            endedConnections.removeLast(endedConnections.count - Self.historyLimit)
        }
    }
}

/// Owns the fixed-port TCP listener and all active proxy sessions.
public final class ProxyServer: @unchecked Sendable {
    public static let defaultPort: UInt16 = 10808

    private let queue: DispatchQueue
    private let configuredPort: UInt16
    private var listener: NWListener?
    private var sessions: [UUID: ProxySession] = [:]
    private let connectionTracker = ProxyConnectionTracker()
    private var samplingTimer: DispatchSourceTimer?
    private var status: ProxyServerStatus = .stopped
    private var lastError: String?

    public var onSnapshot: (@Sendable (ProxyServerSnapshot) -> Void)?

    public init(port: UInt16 = ProxyServer.defaultPort) {
        self.configuredPort = port
        self.queue = DispatchQueue(label: "com.example.PhoneLanProxy.proxy-server")
    }

    public var snapshot: ProxyServerSnapshot {
        queue.sync {
            makeSnapshotOnQueue()
        }
    }

    public func start() {
        queue.async { [weak self] in
            self?.startOnQueue()
        }
    }

    public func stop() {
        queue.async { [weak self] in
            self?.stopOnQueue()
        }
    }

    private func startOnQueue() {
        guard listener == nil,
              status != .starting,
              status != .running
        else {
            return
        }

        resetConnectionHistoryOnQueue()
        lastError = nil
        status = .starting
        emitSnapshotOnQueue()

        do {
            guard let port = NWEndpoint.Port(rawValue: configuredPort) else {
                throw ProxyServerError.invalidPort
            }
            // Reuse lets the app supervisor restart a failed listener on the
            // fixed port immediately, e.g. after iOS reclaimed the socket.
            let parameters = NWParameters.tcp
            parameters.allowLocalEndpointReuse = true
            let newListener = try NWListener(using: parameters, on: port)
            newListener.stateUpdateHandler = { [weak self, weak newListener] state in
                guard let self, let source = newListener else { return }
                self.queue.async {
                    self.handleListenerState(state, source: source)
                }
            }
            newListener.newConnectionHandler = { [weak self, weak newListener] connection in
                guard let self, let source = newListener else { return }
                self.queue.async {
                    self.accept(connection, source: source)
                }
            }
            listener = newListener
            newListener.start(queue: queue)
        } catch {
            listener = nil
            status = .failed
            lastError = error.localizedDescription
            emitSnapshotOnQueue()
        }
    }

    private func stopOnQueue() {
        guard listener != nil || !sessions.isEmpty || status != .stopped else {
            return
        }

        stopSamplingTimerOnQueue()
        listener?.cancel()
        listener = nil
        cancelSessionsAndResetConnectionHistoryOnQueue()
        status = .stopped
        lastError = nil
        emitSnapshotOnQueue()
    }

    private func handleListenerState(_ state: NWListener.State, source: NWListener) {
        guard self.listener === source else {
            return
        }
        switch state {
        case .ready:
            status = .running
            lastError = nil
            emitSnapshotOnQueue()

        case let .waiting(error):
            lastError = error.debugDescription
            emitSnapshotOnQueue()

        case let .failed(error):
            stopSamplingTimerOnQueue()
            self.listener?.cancel()
            self.listener = nil
            cancelSessionsAndResetConnectionHistoryOnQueue()
            status = .failed
            lastError = error.debugDescription
            emitSnapshotOnQueue()

        case .cancelled, .setup:
            break
        @unknown default:
            break
        }
    }

    private func accept(_ connection: NWConnection, source: NWListener) {
        guard self.listener === source,
              status == .starting || status == .running
        else {
            connection.cancel()
            return
        }

        let token = UUID()
        connectionTracker.accept(
            id: token,
            clientAddress: Self.clientAddress(for: connection.endpoint)
        )
        let session = ProxySession(
            client: connection,
            queue: queue,
            onEvent: { [weak self] event in
                self?.handleConnectionEvent(event, token: token)
            },
            onFinished: { [weak self] in
                guard let self else { return }
                self.removeSession(token)
            }
        )
        sessions[token] = session
        startSamplingTimerIfNeededOnQueue()
        emitSnapshotOnQueue()
        session.start()
    }

    private func removeSession(_ token: UUID) {
        guard sessions.removeValue(forKey: token) != nil else {
            return
        }
        connectionTracker.remove(id: token)
        stopSamplingTimerIfNeededOnQueue()
        emitSnapshotOnQueue()
    }

    private func makeSnapshotOnQueue() -> ProxyServerSnapshot {
        ProxyServerSnapshot(
            status: status,
            port: configuredPort,
            connectionCount: sessions.count,
            activeConnections: connectionTracker.activeSnapshots,
            endedConnections: connectionTracker.endedSnapshots,
            errorDescription: lastError
        )
    }

    private func emitSnapshotOnQueue() {
        let value = makeSnapshotOnQueue()
        onSnapshot?(value)
    }

    private func handleConnectionEvent(_ event: ProxyConnectionEvent, token: UUID) {
        if connectionTracker.handle(event, id: token) {
            emitSnapshotOnQueue()
        }
    }

    private func startSamplingTimerIfNeededOnQueue() {
        guard samplingTimer == nil else { return }
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 1, repeating: 1)
        timer.setEventHandler { [weak self] in
            self?.sampleConnectionRatesOnQueue()
        }
        samplingTimer = timer
        timer.resume()
    }

    private func stopSamplingTimerIfNeededOnQueue() {
        guard connectionTracker.activeCount == 0 else { return }
        stopSamplingTimerOnQueue()
    }

    private func stopSamplingTimerOnQueue() {
        samplingTimer?.setEventHandler {}
        samplingTimer?.cancel()
        samplingTimer = nil
    }

    private func sampleConnectionRatesOnQueue() {
        guard connectionTracker.activeCount > 0 else {
            stopSamplingTimerOnQueue()
            return
        }
        connectionTracker.sample()
        emitSnapshotOnQueue()
    }

    private func resetConnectionHistoryOnQueue() {
        stopSamplingTimerOnQueue()
        connectionTracker.reset()
    }

    private func cancelSessionsAndResetConnectionHistoryOnQueue() {
        sessions.values.forEach { $0.cancel() }
        sessions.removeAll(keepingCapacity: false)
        connectionTracker.reset()
    }

    private static func clientAddress(for endpoint: NWEndpoint) -> String? {
        guard case let .hostPort(host, port) = endpoint else {
            return String(describing: endpoint)
        }
        switch host {
        case let .ipv4(address):
            return "\(address):\(port.rawValue)"
        case let .ipv6(address):
            return "[\(address)]:\(port.rawValue)"
        case let .name(name, _):
            return "\(name):\(port.rawValue)"
        @unknown default:
            return "\(host):\(port.rawValue)"
        }
    }
}

private enum ProxyServerError: LocalizedError {
    case invalidPort

    var errorDescription: String? {
        switch self {
        case .invalidPort:
            return "代理端口无效"
        }
    }
}
