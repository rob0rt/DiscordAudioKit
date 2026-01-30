import WSClient
import Foundation
import AsyncAlgorithms
import DaveKit

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
                if await gateway.sequence == -1 {
                    let identify = VoiceGateway.ClientEvent(
                        data: .identify(.init(
                            serverId: serverId,
                            userId: userId,
                            sessionId: sessionId,
                            token: token,
                            maxDaveProtocolVersion: DaveSessionManager.maxSupportedProtocolVersion(),
                        )),
                    )
                    try await outbound.write(.init(from: identify))

                    // TODO: Wait for "Ready" event and call "onConnect"
                } else {
                    let resume = VoiceGateway.ClientEvent(
                        data: .resume(.init(
                            serverId: serverId,
                            sessionId: sessionId,
                            token: token,
                            sequence: UInt16(await gateway.sequence),
                        )),
                    )
                    try await outbound.write(.init(from: resume))

                    // TODO: Wait for "Resumed" event
                }

                // TODO: Set "inbound" and "outbound" properties of gateway
                
                for try await message: WebSocketInboundMessageStream.Element in inbound.messages(maxSize: 1 << 14) {
                    await gateway.processMessage(message)
                }
            }

            // TODO: Remove "inbound" and "outbound" properties of gateway

            guard let closeFrame,
                let errorCode = VoiceGateway.CloseErrorCode(from: closeFrame),
                errorCode.shouldReconnect else {
                break
            }
        }

        await gateway.heartbeatTask?.cancel()
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
