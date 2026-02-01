import WSClient
import Foundation
import AsyncAlgorithms
import DaveKit

/// High-level API for maintaining a connection to the Discord Voice Gateway websocket,
/// handling heartbeats, reconnections, and processing incoming and outgoing events.
final actor DiscordAudioGateway {

    /// Every inbound event can contain a sequence number, which is used for resuming connections.
    private var sequence: Int = -1

    /// The gateway will tell us how often to send heartbeats after connecting.
    private var heartbeatTask: Task<Void, Error>?

    /// Outbound events are processed in a separate task to allow for rate-limiting.
    private var outboundTask: Task<Void, Error>?

    /// A task that is executed once the gateway connection is successfully established.
    private var onConnectTask: Task<Void, Error>?

    /// The active websocket connection task. Used to manage shutdown and cancellation.
    private var websocketConnectionTask: Task<Void, Error>?

    /// Channel for outbound events to be sent to the gateway.
    private let outboundEvents = AsyncChannel<VoiceGateway.ClientEvent>()

    /// Channel for inbound events received from the gateway.
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
                await gateway.setWebsocketConnectionTask {
                    try await gateway.handleConnection(
                        inbound: inbound,
                        outbound: outbound,
                        serverId: serverId,
                        userId: userId,
                        sessionId: sessionId,
                        token: token,
                        onConnect: onConnect
                    )
                }

                // Wait for the websocket connection to close
                try await gateway.websocketConnectionTask?.value
            }

            // Connection closed - stop sending outbound events
            await gateway.outboundTask?.cancel()

            guard let closeFrame,
                let errorCode = VoiceGateway.CloseErrorCode(from: closeFrame),
                errorCode.shouldReconnect else {
                break
            }
        }

        await gateway.onConnectTask?.cancel()
        await gateway.heartbeatTask?.cancel()
        gateway.events.finish()
        gateway.outboundEvents.finish()
    }

    func send(_ event: VoiceGateway.ClientEvent) async {
        await outboundEvents.send(.init(data: event.data))
    }

    private func handleConnection(
        inbound: WebSocketInboundStream,
        outbound: WebSocketOutboundWriter,
        serverId: String,
        userId: String,
        sessionId: String,
        token: String,
        onConnect: @escaping @Sendable (DiscordAudioGateway) async -> Void
    ) async throws {
        outboundTask = Task {
            for await event in outboundEvents._throttle(for: .milliseconds(500)) {
                try await outbound.write(.init(from: event))
            }
        }

        if self.sequence == -1 {
            self.onConnectTask = Task {
                defer {
                    // onConnect completed, shutdown the websocket connection - this should
                    // start the full shutdown process.
                    websocketConnectionTask?.cancel()
                }

                await onConnect(self)
            }

            let identify = VoiceGateway.ClientEvent(
                data: .identify(.init(
                    serverId: serverId,
                    userId: userId,
                    sessionId: sessionId,
                    token: token,
                    maxDaveProtocolVersion: DaveSessionManager.maxSupportedProtocolVersion(),
                )),
            )
            await self.send(identify)

            // The first event after identifying should be READY or HELLO - we handle "HELLO"
            // automatically in processMessage to setup heartbeats, and expect the caller to
            // handle READY in their onConnect closure.
        } else {
            let resume = VoiceGateway.ClientEvent(
                data: .resume(.init(
                    serverId: serverId,
                    sessionId: sessionId,
                    token: token,
                    sequence: UInt16(self.sequence),
                )),
            )
            await self.send(resume)

            // If resuming, wait for it to be acknowledged before proceeding
            var iterator = inbound.messages(maxSize: 1 << 14).makeAsyncIterator()
            guard
                let message = try await iterator.next(),
                case .resumed = try self.processMessage(message).data
            else {
                throw DiscordAudioGatewayError.unableToResume
            }
        }

        for try await message in inbound.messages(maxSize: 1 << 14) {
            await self.events.send(try self.processMessage(message))
        }
    }

    private func setupOutbound(_ outbound: WebSocketOutboundWriter) {
        outboundTask = Task {
            for await event in outboundEvents._throttle(for: .milliseconds(500)) {
                try await outbound.write(.init(from: event))
            }
        }
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

    private func processMessage(_ message: WebSocketMessage) throws(DiscordAudioGatewayError) -> VoiceGateway.ServerEvent {
        guard let event = VoiceGateway.ServerEvent(from: message) else {
            throw DiscordAudioGatewayError.invalidEventReceived
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

        return event
    }

    private func setWebsocketConnectionTask(_ connection: @escaping @Sendable () async throws -> Void) {
        self.websocketConnectionTask = Task {
            try await connection()
        }
    }
}

enum DiscordAudioGatewayError: Error {
    case invalidEventReceived
    case unableToResume
}