import Foundation
import Network

/// Handles one SOCKS5 client from greeting through a single CONNECT relay.
public final class SOCKS5Session: @unchecked Sendable {
    private enum Stage: Equatable {
        case greeting
        case waitingForMethodResponse
        case request
        case connecting
        case relaying
        case finished
    }

    private let client: NWConnection
    private let queue: DispatchQueue
    private let onEvent: (@Sendable (ProxyConnectionEvent) -> Void)?
    private let onFinished: (@Sendable () -> Void)?

    private var stage: Stage = .greeting
    private var protocolBuffer = [UInt8]()
    private var clientReceiveInFlight = false
    private var clientReadClosed = false
    private var outbound: NWConnection?
    /// Client bytes that arrived after the request; handed to the relay.
    private var pendingClientData = Data()
    private var relay: TCPRelay?
    private var relayTermination: TCPRelayTermination?
    private let timeout: QueueTimeout
    private var hasStarted = false
    private var hasFinished = false

    public convenience init(
        client: NWConnection,
        queue: DispatchQueue,
        onFinished: (@Sendable () -> Void)? = nil
    ) {
        self.init(
            client: client,
            queue: queue,
            onEvent: nil,
            onFinished: onFinished
        )
    }

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

    public func start() {
        start(initialData: Data())
    }

    func start(
        initialData: Data,
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

    public func cancel() {
        queue.async {
            self.finishOnQueue(reason: .cancelled)
        }
    }

    private func startOnQueue(
        initialData: Data,
        clientReadClosed: Bool,
        clientAlreadyStarted: Bool
    ) {
        guard !hasStarted, !hasFinished else {
            return
        }
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
        protocolBuffer.append(contentsOf: initialData)
        timeout.arm(seconds: ProxyTimeouts.clientHandshake) { [weak self] in
            self?.protocolTimeoutOnQueue()
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
              !clientReadClosed,
              !clientReceiveInFlight,
              stage == .greeting || stage == .request
        else {
            return
        }

        clientReceiveInFlight = true
        client.receive(
            minimumIncompleteLength: 1,
            maximumLength: 64 * 1024
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
        guard protocolBuffer.count <= 256 * 1024 else {
            replyAndFinish(
                SOCKS5Wire.response(reply: SOCKS5Wire.generalFailure),
                reason: .protocolError,
                failureDescription: "SOCKS5 请求过大"
            )
            return
        }

        processProtocolBuffer()
    }

    private func processProtocolBuffer() {
        guard !hasFinished else { return }
        switch stage {
        case .greeting:
            processGreeting()
        case .request:
            processRequest()
        case .waitingForMethodResponse, .connecting, .relaying, .finished:
            break
        }
    }

    private func processGreeting() {
        switch SOCKS5Wire.parseGreeting(protocolBuffer) {
        case .needMoreData:
            if clientReadClosed {
                finishOnQueue(reason: .clientDisconnected)
            } else {
                receiveFromClient()
            }

        case .invalid:
            replyAndFinish(
                SOCKS5Wire.methodSelectionResponse(SOCKS5Wire.noAcceptableMethods),
                reason: .protocolError,
                failureDescription: "SOCKS5 握手无效"
            )

        case let .parsed(greeting, consumed):
            protocolBuffer.removeFirst(consumed)
            stage = .waitingForMethodResponse
            timeout.arm(seconds: ProxyTimeouts.clientHandshake) { [weak self] in
                self?.protocolTimeoutOnQueue()
            }

            let method = greeting.supportsNoAuthentication
                ? SOCKS5Wire.noAuthentication
                : SOCKS5Wire.noAcceptableMethods
            send(SOCKS5Wire.methodSelectionResponse(method)) { [weak self] in
                guard let self else { return }
                if method == SOCKS5Wire.noAcceptableMethods {
                    self.finishOnQueue(
                        reason: .protocolError,
                        failureDescription: "客户端不支持无认证方式"
                    )
                } else {
                    self.stage = .request
                    self.processProtocolBuffer()
                }
            }
        }
    }

    private func processRequest() {
        switch SOCKS5Wire.parseRequest(protocolBuffer) {
        case .needMoreData:
            if clientReadClosed {
                replyAndFinish(
                    SOCKS5Wire.response(reply: SOCKS5Wire.generalFailure),
                    reason: .clientDisconnected,
                    failureDescription: nil
                )
            } else {
                receiveFromClient()
            }

        case let .invalid(error):
            let reply: UInt8 = error == .unsupportedAddressType
                ? SOCKS5Wire.addressTypeNotSupported
                : SOCKS5Wire.generalFailure
            replyAndFinish(
                SOCKS5Wire.response(reply: reply),
                reason: .protocolError,
                failureDescription: String(describing: error)
            )

        case let .parsed(request, consumed):
            protocolBuffer.removeFirst(consumed)
            guard request.command == SOCKS5Wire.connect else {
                replyAndFinish(
                    SOCKS5Wire.response(reply: SOCKS5Wire.commandNotSupported),
                    reason: .protocolError,
                    failureDescription: "仅支持 SOCKS5 CONNECT"
                )
                return
            }
            beginConnect(to: request, initialData: Data(protocolBuffer))
            protocolBuffer.removeAll(keepingCapacity: false)
        }
    }

    private func beginConnect(to request: SOCKS5Request, initialData: Data) {
        guard !hasFinished else { return }
        stage = .connecting
        pendingClientData = initialData
        onEvent?(.target(
            protocolKind: .socks5,
            host: request.address.host,
            port: request.port
        ))
        let host = NWEndpoint.Host(request.address.host)
        let port = NWEndpoint.Port(integerLiteral: request.port)
        let target = NWEndpoint.hostPort(host: host, port: port)
        let connection = NWConnection(to: target, using: .tcp)
        outbound = connection

        connection.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            self.queue.async {
                self.handleOutboundState(state)
            }
        }
        connection.start(queue: queue)
        timeout.arm(seconds: ProxyTimeouts.outboundConnect) { [weak self] in
            self?.outboundTimeoutOnQueue()
        }
    }

    private func handleOutboundState(_ state: NWConnection.State) {
        guard !hasFinished else { return }
        switch state {
        case .ready:
            guard stage == .connecting else { return }
            timeout.cancel()
            onEvent?(.outboundReady)
            let boundAddress = SOCKS5NetworkUtilities.boundAddress(for: outbound?.currentPath?.localEndpoint)
            send(SOCKS5Wire.response(reply: SOCKS5Wire.succeeded, boundAddress: boundAddress)) { [weak self] in
                guard let self, !self.hasFinished, let outbound = self.outbound else { return }
                self.stage = .relaying
                self.onEvent?(.relayStarted)
                let relay = TCPRelay(
                    client: self.client,
                    remote: outbound,
                    queue: self.queue,
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
                let initialData = self.pendingClientData
                self.pendingClientData = Data()
                relay.start(initialClientData: initialData, clientReadClosed: self.clientReadClosed)
            }

        // NWConnection reports refused/unroutable targets as `.waiting` and
        // would retry indefinitely; a proxy should answer right away.
        case let .waiting(error), let .failed(error):
            if stage == .connecting {
                replyAndFinish(
                    SOCKS5Wire.response(reply: SOCKS5NetworkUtilities.replyCode(for: error)),
                    reason: .targetConnectionFailed,
                    failureDescription: error.debugDescription
                )
            }
        case .cancelled:
            if stage == .connecting {
                replyAndFinish(
                    SOCKS5Wire.response(reply: SOCKS5Wire.generalFailure),
                    reason: .targetConnectionFailed,
                    failureDescription: "目标连接已取消"
                )
            }
        case .setup, .preparing:
            break
        @unknown default:
            break
        }
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
                self?.finishOnQueue(
                    reason: reason,
                    failureDescription: failureDescription
                )
            }
        )
    }

    private func protocolTimeoutOnQueue() {
        guard !hasFinished else { return }
        if stage == .connecting {
            return
        }
        replyAndFinish(
            SOCKS5Wire.response(reply: SOCKS5Wire.generalFailure),
            reason: .timeout,
            failureDescription: "SOCKS5 握手超时"
        )
    }

    private func outboundTimeoutOnQueue() {
        guard !hasFinished, stage == .connecting else { return }
        stage = .finished
        outbound?.cancel()
        replyAndFinish(
            SOCKS5Wire.response(reply: SOCKS5Wire.ttlExpired),
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
