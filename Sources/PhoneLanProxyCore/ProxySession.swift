import Foundation
import Network

/// A protocol handler that takes over a client after detection.
private protocol DelegatedSession: AnyObject {
    func start(initialData: Data, clientReadClosed: Bool, clientAlreadyStarted: Bool)
    func cancel()
}

extension SOCKS5Session: DelegatedSession {}
extension HTTPProxySession: DelegatedSession {}

/// Detects the protocol on the shared listener and delegates the connection.
final class ProxySession: @unchecked Sendable {
    private enum Stage {
        case detecting
        case delegated
        case finished
    }

    private let client: NWConnection
    private let queue: DispatchQueue
    private let onEvent: (@Sendable (ProxyConnectionEvent) -> Void)?
    private let onFinished: (@Sendable () -> Void)?

    private var stage: Stage = .detecting
    private var protocolBuffer = [UInt8]()
    private var clientReceiveInFlight = false
    private var clientReadClosed = false
    private let timeout: QueueTimeout
    private var delegatedSession: (any DelegatedSession)?
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

    func start() {
        queue.async { [weak self] in
            self?.startOnQueue()
        }
    }

    func cancel() {
        queue.async {
            self.finishOnQueue()
        }
    }

    private func startOnQueue() {
        guard !hasStarted, !hasFinished else { return }
        hasStarted = true
        client.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            self.queue.async {
                self.handleClientState(state)
            }
        }
        client.start(queue: queue)
        timeout.arm(seconds: ProxyTimeouts.clientHandshake) { [weak self] in
            self?.finishOnQueue(reason: .timeout)
        }
        receiveFromClient()
    }

    private func handleClientState(_ state: NWConnection.State) {
        guard !hasFinished, stage == .detecting else { return }
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
              stage == .detecting,
              !clientReadClosed,
              !clientReceiveInFlight
        else {
            return
        }

        clientReceiveInFlight = true
        client.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            self.queue.async {
                self.clientReceiveInFlight = false
                self.handleClientReceive(data: data, isComplete: isComplete, error: error)
            }
        }
    }

    private func handleClientReceive(data: Data?, isComplete: Bool, error: NWError?) {
        guard !hasFinished, stage == .detecting else { return }
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
        guard let firstByte = protocolBuffer.first else {
            if clientReadClosed {
                finishOnQueue(reason: .clientDisconnected)
            } else {
                receiveFromClient()
            }
            return
        }

        stage = .delegated
        timeout.cancel()
        onEvent?(.phase(.handshaking))
        let initialData = Data(protocolBuffer)
        protocolBuffer.removeAll(keepingCapacity: false)
        let onDelegateFinished: @Sendable () -> Void = { [weak self] in
            self?.queue.async { [weak self] in
                self?.finishOnQueue()
            }
        }
        let session: any DelegatedSession = firstByte == SOCKS5Wire.version
            ? SOCKS5Session(
                client: client,
                queue: queue,
                onEvent: onEvent,
                onFinished: onDelegateFinished
            )
            : HTTPProxySession(
                client: client,
                queue: queue,
                onEvent: onEvent,
                onFinished: onDelegateFinished
            )
        if firstByte == SOCKS5Wire.version {
            onEvent?(.protocolDetected(.socks5))
        }
        delegatedSession = session
        session.start(
            initialData: initialData,
            clientReadClosed: clientReadClosed,
            clientAlreadyStarted: true
        )
    }

    private func finishOnQueue(reason: ProxyConnectionEndReason = .cancelled) {
        guard !hasFinished else { return }
        hasFinished = true
        stage = .finished
        timeout.cancel()
        delegatedSession?.cancel()
        client.cancel()
        if delegatedSession == nil {
            onEvent?(.finished(reason, failureDescription: nil))
        }
        onFinished?()
    }
}
