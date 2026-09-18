import Foundation
import Network

/// Handles one HTTP proxy request or HTTPS CONNECT tunnel.
final class HTTPProxySession: @unchecked Sendable {
    private enum Stage: Equatable {
        case readingHeaders
        case connecting
        case relaying
        case finished
    }

    private let client: NWConnection
    private let queue: DispatchQueue
    private let onEvent: (@Sendable (ProxyConnectionEvent) -> Void)?
    private let onFinished: (@Sendable () -> Void)?

    private var stage: Stage = .readingHeaders
    private var protocolBuffer = [UInt8]()
    private var clientReceiveInFlight = false
    private var clientReadClosed = false
    private var outbound: NWConnection?
    /// Rewritten request header (for forwards) plus any body bytes already
    /// read; handed to the relay.
    private var pendingClientData = Data()
    private var relay: TCPRelay?
    private var relayTermination: TCPRelayTermination?
    private let timeout: QueueTimeout
    private var hasStarted = false
    private var hasFinished = false

    init(
        client: NWConnection,
        queue: DispatchQueue,
        onEvent: (@Sendable (ProxyConnectionEvent) -> Void)? = nil,
        onFinished: (@Sendable () -> Void)? = nil
    ) {
        self.client = client
        self.queue = queue
        self.onEvent = onEvent
        self.onFinished = onFinished
        self.timeout = QueueTimeout(queue: queue)
    }

    func start(
        initialData: Data = Data(),
        clientReadClosed: Bool = false,
        clientAlreadyStarted: Bool = false
    ) {
        queue.async { [weak self] in
            self?.startOnQueue(
                initialData: initialData,
                clientReadClosed: clientReadClosed,
                clientAlreadyStarted: clientAlreadyStarted
            )
        }
    }

    func cancel() {
        queue.async {
            self.finishOnQueue(reason: .cancelled)
        }
    }

    private func startOnQueue(
        initialData: Data,
        clientReadClosed: Bool,
        clientAlreadyStarted: Bool
    ) {
        guard !hasStarted, !hasFinished else { return }
        hasStarted = true
        self.clientReadClosed = clientReadClosed
        client.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            self.queue.async {
                self.handleClientState(state)
            }
        }
        if !clientAlreadyStarted {
            client.start(queue: queue)
        }
        if !initialData.isEmpty {
            protocolBuffer.append(contentsOf: initialData)
        }
        timeout.arm(seconds: ProxyTimeouts.clientHandshake) { [weak self] in
            self?.headerTimeoutOnQueue()
        }
        processProtocolBuffer()
    }

    private func handleClientState(_ state: NWConnection.State) {
        guard !hasFinished, stage != .finished else { return }
        switch state {
        case .failed, .cancelled:
            finishOnQueue(reason: .clientDisconnected)
        case .setup, .waiting, .preparing, .ready:
            break
        @unknown default:
            break
        }
    }

    private func receiveFromClient() {
        guard !hasFinished,
              stage == .readingHeaders,
              !clientReadClosed,
              !clientReceiveInFlight
        else {
            return
        }

        clientReceiveInFlight = true
        client.receive(
            minimumIncompleteLength: 1,
            maximumLength: HTTPProxyWire.maximumHeaderLength
        ) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            self.queue.async {
                self.clientReceiveInFlight = false
                self.handleClientReceive(data: data, isComplete: isComplete, error: error)
            }
        }
    }

    private func handleClientReceive(data: Data?, isComplete: Bool, error: NWError?) {
        guard !hasFinished else { return }
        if let data, !data.isEmpty {
            protocolBuffer.append(contentsOf: data)
        }
        if isComplete || error != nil {
            clientReadClosed = true
        }

        guard error == nil || data != nil else {
            finishOnQueue(reason: .clientDisconnected)
            return
        }
        processProtocolBuffer()
    }

    private func processProtocolBuffer() {
        guard !hasFinished, stage == .readingHeaders else { return }
        switch HTTPProxyWire.parse(protocolBuffer) {
        case .needMoreData:
            if clientReadClosed {
                replyAndFinish(
                    HTTPProxyWire.errorResponse(statusCode: 400, reason: "Bad Request"),
                    reason: .clientDisconnected
                )
            } else {
                receiveFromClient()
            }

        case let .invalid(error):
            replyAndFinish(
                HTTPProxyWire.errorResponse(for: error),
                reason: .protocolError,
                failureDescription: String(describing: error)
            )

        case let .parsed(request, headerLength):
            guard protocolBuffer.count >= headerLength else {
                replyAndFinish(
                    HTTPProxyWire.errorResponse(statusCode: 400, reason: "Bad Request"),
                    reason: .protocolError,
                    failureDescription: "HTTP 请求头无效"
                )
                return
            }
            let trailingData = Data(protocolBuffer.dropFirst(headerLength))
            protocolBuffer.removeAll(keepingCapacity: false)
            beginConnect(to: request, trailingData: trailingData)
        }
    }

    private func beginConnect(to request: HTTPProxyRequest, trailingData: Data) {
        guard !hasFinished else { return }
        let host: String
        let port: UInt16
        let isTunnel: Bool
        var initialData = Data()
        switch request {
        case let .connect(requestHost, requestPort):
            host = requestHost
            port = requestPort
            isTunnel = true
        case let .forward(requestHost, requestPort, header):
            host = requestHost
            port = requestPort
            isTunnel = false
            initialData.append(header)
        }
        onEvent?(.target(
            protocolKind: isTunnel ? .httpConnect : .http,
            host: host,
            port: port
        ))
        initialData.append(trailingData)
        pendingClientData = initialData

        stage = .connecting
        let target = NWEndpoint.hostPort(
            host: NWEndpoint.Host(host),
            port: NWEndpoint.Port(integerLiteral: port)
        )
        let connection = NWConnection(to: target, using: .tcp)
        outbound = connection
        connection.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            self.queue.async {
                self.handleOutboundState(state, isTunnel: isTunnel)
            }
        }
        connection.start(queue: queue)
        timeout.arm(seconds: ProxyTimeouts.outboundConnect) { [weak self] in
            self?.outboundTimeoutOnQueue()
        }
    }

    private func handleOutboundState(_ state: NWConnection.State, isTunnel: Bool) {
        guard !hasFinished, stage == .connecting else { return }
        switch state {
        case .ready:
            timeout.cancel()
            onEvent?(.outboundReady)
            if isTunnel {
                send(HTTPProxyWire.connectionEstablished) { [weak self] in
                    self?.startRelay()
                }
            } else {
                startRelay()
            }

        // NWConnection reports refused/unroutable targets as `.waiting` and
        // would retry indefinitely; a proxy should answer right away.
        case let .waiting(error), let .failed(error):
            replyAndFinish(
                HTTPProxyWire.errorResponse(forConnectError: error),
                reason: .targetConnectionFailed,
                failureDescription: error.debugDescription
            )
        case .cancelled:
            replyAndFinish(
                HTTPProxyWire.errorResponse(statusCode: 502, reason: "Bad Gateway"),
                reason: .targetConnectionFailed,
                failureDescription: "目标连接已取消"
            )
        case .setup, .preparing:
            break
        @unknown default:
            break
        }
    }

    private func startRelay() {
        guard !hasFinished, let outbound else { return }
        stage = .relaying
        onEvent?(.relayStarted)
        let relay = TCPRelay(
            client: client,
            remote: outbound,
            queue: queue,
            onTraffic: { [weak self] uploaded, downloaded in
                self?.onEvent?(.bytes(uploaded: uploaded, downloaded: downloaded))
            },
            onTermination: { [weak self] termination in
                self?.relayTermination = termination
            }
        ) { [weak self] in
            self?.finishOnQueue()
        }
        self.relay = relay
        let initialData = pendingClientData
        pendingClientData = Data()
        relay.start(initialClientData: initialData, clientReadClosed: clientReadClosed)
    }

    private func send(_ data: Data, completion: @escaping @Sendable () -> Void) {
        guard !hasFinished else { return }
        client.send(
            content: data,
            contentContext: .defaultMessage,
            isComplete: true,
            completion: .contentProcessed { [weak self] error in
                guard let self else { return }
                self.queue.async {
                    guard !self.hasFinished else { return }
                    if error != nil {
                        self.finishOnQueue(
                            reason: .clientDisconnected,
                            failureDescription: error?.debugDescription
                        )
                    } else {
                        completion()
                    }
                }
            }
        )
    }

    private func replyAndFinish(
        _ data: Data,
        reason: ProxyConnectionEndReason = .protocolError,
        failureDescription: String? = nil
    ) {
        guard !hasFinished else { return }
        stage = .finished
        timeout.cancel()
        client.send(
            content: data,
            contentContext: .defaultMessage,
            isComplete: true,
            completion: .contentProcessed { [weak self] _ in
                guard let self else { return }
                self.queue.async { [weak self] in
                    self?.finishOnQueue(
                        reason: reason,
                        failureDescription: failureDescription
                    )
                }
            }
        )
    }

    private func headerTimeoutOnQueue() {
        guard !hasFinished, stage == .readingHeaders else { return }
        replyAndFinish(
            HTTPProxyWire.errorResponse(statusCode: 408, reason: "Request Timeout"),
            reason: .timeout,
            failureDescription: "HTTP 请求头超时"
        )
    }

    private func outboundTimeoutOnQueue() {
        guard !hasFinished, stage == .connecting else { return }
        outbound?.cancel()
        replyAndFinish(
            HTTPProxyWire.errorResponse(statusCode: 504, reason: "Gateway Timeout"),
            reason: .timeout,
            failureDescription: "目标连接超时"
        )
    }

    private func finishOnQueue(
        reason: ProxyConnectionEndReason? = nil,
        failureDescription: String? = nil
    ) {
        guard !hasFinished else { return }
        hasFinished = true
        stage = .finished
        timeout.cancel()
        relay?.cancel()
        outbound?.cancel()
        client.cancel()
        let finalReason: ProxyConnectionEndReason
        if let reason {
            finalReason = reason
        } else {
            switch relayTermination {
            case .completed:
                finalReason = .completed
            case .failed:
                finalReason = .relayFailed
            case .cancelled, .none:
                finalReason = .cancelled
            }
        }
        onEvent?(.finished(finalReason, failureDescription: failureDescription))
        onFinished?()
    }
}
