import WSClient
import DaveKit
import Foundation

public actor DiscordAudioGateway {
    private let endpoint: String
    private let serverId: String
    private let userId: String
    private let sessionId: String
    private let token: String

    private var sequence: Int = -1
    private var outbound: WebSocketOutboundWriter?
    private var heartbeatTask: Task<Void, Error>?

    init(
        endpoint: String,
        serverId: String,
        userId: String,
        sessionId: String,
        token: String,
    ) {
        self.endpoint = endpoint
        self.serverId = serverId
        self.userId = userId
        self.sessionId = sessionId
        self.token = token
    }

    private var eventsStreamContinuations = [AsyncStream<VoiceGateway.Event>.Continuation]()
    var events: AsyncStream<VoiceGateway.Event> {
        AsyncStream { continuation in
            eventsStreamContinuations.append(continuation)
        }
    }

    public func connect() async throws {
        let ws = WebSocketClient(url: "ws://mywebsocket.com/ws", logger: logger) { inbound, outbound, context in

            // Unlike the primary Discord gateway, we need to identify immediately upon connection
            let identify = VoiceGateway.Event(from: .identify(.init(
                serverId: self.serverId,
                userId: self.userId,
                sessionId: self.sessionId,
                token: self.token,
                maxDaveProtocolVersion: DaveSessionManager.maxSupportedProtocolVersion(),
            )))
            try await outbound.write(.init(from: identify))

            await self.setOutboundWriter(outbound)

            // Process inbound messages
            for try await frame in inbound.messages(maxSize: 1 << 14) {
                if let event = VoiceGateway.Event(from: frame) {
                    await self.processEvent(event)
                }
            }

            await self.heartbeatTask?.cancel()
            await self.eventsStreamContinuations.forEach { $0.finish() }
        }

        try await ws.run()
    }

    func send(_ event: VoiceGateway.Event) async throws {
        try await outbound?.write(.init(from: event))
    }

    private func setOutboundWriter(_ outbound: WebSocketOutboundWriter) {
        self.outbound = outbound
    }

    private func setSequence(_ sequence: Int) {
        self.sequence = sequence
    }

    private func setupHeartbeat(interval: Duration) {
        heartbeatTask = Task {
            while !Task.isCancelled {
                try await Task.sleep(for: interval)
                let heartbeat = VoiceGateway.Event(from: .heartbeat(.init(
                    nonce: UInt64(Date().timeIntervalSince1970),
                    sequence: self.sequence,
                )))
                try await outbound?.write(.init(from: heartbeat))
            }
        }
    }

    private nonisolated func processEvent(_ event: VoiceGateway.Event) async {
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
