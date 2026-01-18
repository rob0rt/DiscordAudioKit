import WSClient
import DaveKit
import Foundation

final public actor DiscordAudioGateway {
    private var sequence: Int = -1
    private var outbound: WebSocketOutboundWriter
    private var heartbeatTask: Task<Void, Error>?

    private init(outbound: WebSocketOutboundWriter) {
        self.outbound = outbound
    }

    private var eventsStreamContinuations = [AsyncStream<VoiceGateway.ServerEvent>.Continuation]()
    var events: AsyncStream<VoiceGateway.ServerEvent> {
        AsyncStream { continuation in
            eventsStreamContinuations.append(continuation)
        }
    }

    @discardableResult
    static func connect(
        endpoint: String,
        serverId: String,
        userId: String,
        sessionId: String,
        token: String,
        onConnect: @escaping @Sendable (DiscordAudioGateway) async -> Void
    ) async throws -> WebSocketCloseFrame? {
        return try await WebSocketClient.connect(url: endpoint, logger: logger) { inbound, outbound, context in
    
            let gateway = DiscordAudioGateway(outbound: outbound)

            await withThrowingTaskGroup { taskGroup in
                taskGroup.addTask {
                    await onConnect(gateway)
                }

                taskGroup.addTask {
                    for try await frame in inbound.messages(maxSize: 1 << 14) {
                        if let event = VoiceGateway.ServerEvent(from: frame) {
                            await gateway.processEvent(event)
                        }
                    }
                }
            }

            await gateway.heartbeatTask?.cancel()
            await gateway.eventsStreamContinuations.forEach { $0.finish() }
        }
    }

    func send(_ event: VoiceGateway.ClientEvent) async throws {
        try await outbound.write(.init(from: event))
    }

    private func setSequence(_ sequence: Int) {
        self.sequence = sequence
    }

    private func setupHeartbeat(interval: Duration) {
        heartbeatTask = Task {
            while !Task.isCancelled {
                try await Task.sleep(for: interval)
                let heartbeat = VoiceGateway.ClientEvent(data: .heartbeat(.init(
                    nonce: UInt64(Date().timeIntervalSince1970),
                    sequence: self.sequence,
                )))
                try await outbound.write(.init(from: heartbeat))
            }
        }
    }

    private nonisolated func processEvent(_ event: VoiceGateway.ServerEvent) async {
        if let seq = event.sequence {
            await self.setSequence(Int(seq))
        }

        switch event.data {
        case .hello(let hello):
            await setupHeartbeat(interval: .milliseconds(hello.heartbeatInterval))
        default:
            break
        }

        for continuation in await eventsStreamContinuations {
            continuation.yield(event)
        }
    }
}
