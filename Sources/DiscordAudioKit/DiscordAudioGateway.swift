import WSClient
import Foundation
import AsyncAlgorithms

final actor DiscordAudioGateway {
    private var sequence: Int = -1
    private var outbound: WebSocketOutboundWriter?
    private var inbound: WebSocketInboundStream?
    private var heartbeatTask: Task<Void, Error>?

    private let outboundEvents = AsyncChannel<VoiceGateway.ClientEvent>()

    let events = AsyncChannel<VoiceGateway.ServerEvent>()

    static func connect(
        endpoint: String,
        serverId: String,
        userId: String,
        sessionId: String,
        token: String,
        onConnect: @escaping @Sendable (DiscordAudioGateway) async -> Void
    ) async throws {
        let gateway = DiscordAudioGateway()

        while true {
            let closeFrame = try await WebSocketClient.connect(url: endpoint, logger: logger) { inbound, outbound, context in
                await withThrowingTaskGroup { taskGroup in
                    taskGroup.addTask {
                        await onConnect(gateway)
                    }

                    taskGroup.addTask {
                        for try await message in inbound.messages(maxSize: 1 << 14) {
                            await gateway.processMessage(message)
                        }
                    }
                }
            }

            guard let closeFrame,
                let errorCode = VoiceGateway.CloseErrorCode(from: closeFrame),
                errorCode.shouldReconnect else {
                break
            }
        }

        gateway.events.finish()
        gateway.outboundEvents.finish()
    }

    func send(_ event: VoiceGateway.ClientEvent) async {
        await outboundEvents.send(.init(data: event.data))
    }

    private func setupHeartbeat(interval: Duration) {
        heartbeatTask = Task {
            while !Task.isCancelled {
                try await Task.sleep(for: interval)
                let heartbeat = VoiceGateway.ClientEvent(data: .heartbeat(.init(
                    nonce: UInt64(Date().timeIntervalSince1970),
                    sequence: self.sequence,
                )))
                await send(heartbeat)
            }
        }
    }

    private func processMessage(_ message: WebSocketMessage) async {
        guard let event = VoiceGateway.ServerEvent(from: message) else {
            return
        }

        if let seq = event.sequence {
            self.sequence = Int(seq)
        }

        switch event.data {
        case .hello(let hello):
            setupHeartbeat(interval: .milliseconds(hello.heartbeatInterval))
        default:
            break
        }

        await events.send(event)
    }
}
