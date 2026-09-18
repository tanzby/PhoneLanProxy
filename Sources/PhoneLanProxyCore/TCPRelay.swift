import Foundation
import Network

/// Copies bytes between the SOCKS client and the target connection.
///
/// Each direction has at most one receive and one dependent send in flight.
/// This keeps the receive loop naturally back-pressured and lets each peer
/// half-close independently when Network.framework reports EOF.
public final class TCPRelay: @unchecked Sendable {
    private let client: NWConnection
    private let remote: NWConnection
    private let queue: DispatchQueue
    private let onTraffic: (@Sendable (_ uploaded: Int, _ downloaded: Int) -> Void)?
    private let onTermination: (@Sendable (TCPRelayTermination) -> Void)?
    private let onFinished: (@Sendable () -> Void)?

    private var clientReceiveInFlight = false
    private var remoteReceiveInFlight = false
    private var clientReadClosed = false
    private var remoteReadClosed = false
    private var clientWriteClosed = false
    private var remoteWriteClosed = false
    private var pendingSends = 0
    private var hasStarted = false
    private var hasFinished = false
    private var gracefulFinishWorkItem: DispatchWorkItem?

    public init(
        client: NWConnection,
        remote: NWConnection,
        queue: DispatchQueue,
        onTraffic: (@Sendable (_ uploaded: Int, _ downloaded: Int) -> Void)? = nil,
        onTermination: (@Sendable (TCPRelayTermination) -> Void)? = nil,
        onFinished: (@Sendable () -> Void)? = nil
    ) {
        self.client = client
        self.remote = remote
        self.queue = queue
        self.onTraffic = onTraffic
        self.onTermination = onTermination
        self.onFinished = onFinished
    }

    public func start(initialClientData: Data = Data(), clientReadClosed: Bool = false) {
        queue.async { [weak self] in
            self?.startOnQueue(initialClientData: initialClientData, clientReadClosed: clientReadClosed)
        }
    }

    public func cancel() {
        queue.async {
            self.finishOnQueue()
        }
    }

    private func startOnQueue(initialClientData: Data, clientReadClosed: Bool) {
        guard !hasStarted, !hasFinished else {
            return
        }
        hasStarted = true
        self.clientReadClosed = clientReadClosed

        receiveFromRemote()

        if !initialClientData.isEmpty {
            onTraffic?(initialClientData.count, 0)
            sendToRemote(initialClientData, closesRead: clientReadClosed)
        } else if clientReadClosed {
            closeRemoteWrite()
        } else {
            receiveFromClient()
        }
    }

    private func receiveFromClient() {
        guard !hasFinished, !clientReadClosed, !clientReceiveInFlight else {
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

    private func receiveFromRemote() {
        guard !hasFinished, !remoteReadClosed, !remoteReceiveInFlight else {
            return
        }
        remoteReceiveInFlight = true
        remote.receive(
            minimumIncompleteLength: 1,
            maximumLength: 64 * 1024
        ) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            self.queue.async {
                self.remoteReceiveInFlight = false
                self.handleRemoteReceive(data: data, isComplete: isComplete, error: error)
            }
        }
    }

    private func handleClientReceive(data: Data?, isComplete: Bool, error: NWError?) {
        guard !hasFinished else { return }
        let closesRead = isComplete || error != nil
        if let data, !data.isEmpty {
            onTraffic?(data.count, 0)
            sendToRemote(data, closesRead: closesRead, hasError: error != nil)
        } else if error != nil {
            finishOnQueue(reason: .failed)
        } else if closesRead {
            clientReadClosed = true
            closeRemoteWrite()
            maybeFinish()
        } else {
            receiveFromClient()
        }
    }

    private func handleRemoteReceive(data: Data?, isComplete: Bool, error: NWError?) {
        guard !hasFinished else { return }
        let closesRead = isComplete || error != nil
        if let data, !data.isEmpty {
            onTraffic?(0, data.count)
            sendToClient(data, closesRead: closesRead, hasError: error != nil)
        } else if error != nil {
            finishOnQueue(reason: .failed)
        } else if closesRead {
            remoteReadClosed = true
            closeClientWrite()
            maybeFinish()
        } else {
            receiveFromRemote()
        }
    }

    private func sendToRemote(_ data: Data, closesRead: Bool, hasError: Bool = false) {
        guard !hasFinished else { return }
        pendingSends += 1
        remote.send(
            content: data,
            contentContext: .defaultMessage,
            isComplete: true,
            completion: .contentProcessed { [weak self] error in
                guard let self else { return }
                self.queue.async {
                    self.pendingSends -= 1
                    guard !self.hasFinished else { return }
                    if error != nil || hasError {
                        self.finishOnQueue(reason: .failed)
                    } else if closesRead {
                        self.clientReadClosed = true
                        self.closeRemoteWrite()
                        self.maybeFinish()
                    } else {
                        self.receiveFromClient()
                    }
                }
            }
        )
    }

    private func sendToClient(_ data: Data, closesRead: Bool, hasError: Bool = false) {
        guard !hasFinished else { return }
        pendingSends += 1
        client.send(
            content: data,
            contentContext: .defaultMessage,
            isComplete: true,
            completion: .contentProcessed { [weak self] error in
                guard let self else { return }
                self.queue.async {
                    self.pendingSends -= 1
                    guard !self.hasFinished else { return }
                    if error != nil || hasError {
                        self.finishOnQueue(reason: .failed)
                    } else if closesRead {
                        self.remoteReadClosed = true
                        self.closeClientWrite()
                        self.maybeFinish()
                    } else {
                        self.receiveFromRemote()
                    }
                }
            }
        )
    }

    private func closeRemoteWrite() {
        guard !hasFinished, !remoteWriteClosed else { return }
        remoteWriteClosed = true
        pendingSends += 1
        remote.send(
            content: nil,
            contentContext: .finalMessage,
            isComplete: true,
            completion: .contentProcessed { [weak self] error in
                guard let self else { return }
                self.queue.async {
                    self.pendingSends -= 1
                    if error != nil {
                        self.finishOnQueue(reason: .failed)
                    } else {
                        self.maybeFinish()
                    }
                }
            }
        )
    }

    private func closeClientWrite() {
        guard !hasFinished, !clientWriteClosed else { return }
        clientWriteClosed = true
        pendingSends += 1
        client.send(
            content: nil,
            contentContext: .finalMessage,
            isComplete: true,
            completion: .contentProcessed { [weak self] error in
                guard let self else { return }
                self.queue.async {
                    self.pendingSends -= 1
                    if error != nil {
                        self.finishOnQueue(reason: .failed)
                    } else {
                        self.maybeFinish()
                    }
                }
            }
        )
    }

    private func maybeFinish() {
        guard !hasFinished,
              clientReadClosed,
              remoteReadClosed,
              pendingSends == 0
        else {
            return
        }
        guard gracefulFinishWorkItem == nil else { return }
        let workItem = DispatchWorkItem { [weak self] in
            self?.finishOnQueue(reason: .completed)
        }
        gracefulFinishWorkItem = workItem
        // finalMessage completions mean bytes reached Network.framework's
        // send path; give the kernel a short bounded drain before canceling
        // the connections so the peer can receive the last packets.
        queue.asyncAfter(deadline: .now() + 0.25, execute: workItem)
    }

    private func finishOnQueue() {
        finishOnQueue(reason: .cancelled)
    }

    private func finishOnQueue(reason: TCPRelayTermination) {
        guard !hasFinished else { return }
        hasFinished = true
        gracefulFinishWorkItem?.cancel()
        gracefulFinishWorkItem = nil
        client.cancel()
        remote.cancel()
        onTermination?(reason)
        onFinished?()
    }
}
