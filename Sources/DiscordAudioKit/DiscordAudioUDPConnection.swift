import NIO
import Foundation
import NIOFoundationCompat

final public actor DiscordAudioUDPConnection {
    private let outbound: NIOAsyncChannelOutboundWriter<AddressedEnvelope<ByteBuffer>>
    private let socketAddress: SocketAddress

    private var packetsStreamContinuations = [AsyncStream<DiscordAudioVoicePacket>.Continuation]()
    var packets: AsyncStream<DiscordAudioVoicePacket> {
        AsyncStream { continuation in
            packetsStreamContinuations.append(continuation)
        }
    }

    private init(
        outbound: NIOAsyncChannelOutboundWriter<AddressedEnvelope<ByteBuffer>>,
        socketAddress: SocketAddress
    ) {
        self.outbound = outbound
        self.socketAddress = socketAddress
    }

    static func connect(
        host: String,
        port: Int,
        onConnect: @Sendable @escaping (DiscordAudioUDPConnection) async throws -> Void
    ) async throws {
        let socketAddress = try SocketAddress(ipAddress: host, port: port)
        let server = try await DatagramBootstrap(group: NIOSingletons.posixEventLoopGroup)
            .bind(to: socketAddress)
            .flatMapThrowing { channel in
                return try NIOAsyncChannel(
                    wrappingChannelSynchronously: channel,
                    configuration: NIOAsyncChannel.Configuration(
                        inboundType: AddressedEnvelope<ByteBuffer>.self,
                        outboundType: AddressedEnvelope<ByteBuffer>.self
                    )
                )
            }
            .get()

        try await server.executeThenClose { inbound, outbound in
            let connection = DiscordAudioUDPConnection(
                outbound: outbound,
                socketAddress: socketAddress
            )

            await withThrowingTaskGroup { taskGroup in
                taskGroup.addTask {
                    try await onConnect(connection)
                }

                taskGroup.addTask {
                    for try await var packet in inbound {
                        try await connection.processVoicePacket(buffer: &packet.data)
                    }
                }
            }

            await connection.packetsStreamContinuations.forEach { $0.finish() }
        }
    }

    func send(buffer: ByteBuffer) async throws {
        try await outbound.write(
            AddressedEnvelope(
                remoteAddress: socketAddress,
                data: buffer
            )
        )
    }

    /// Process a raw UDP voice packet and yield it to the packets stream.
    /// 
    /// https://discord.com/developers/docs/topics/voice-connections#transport-encryption-modes-voice-packet-structure
    private func processVoicePacket(
        buffer: inout ByteBuffer,
    ) async throws {
        guard let version = buffer.readInteger(as: UInt8.self),
              version == 0x80
        else {
            // Unsupported RTP version
            return
        }

        guard let payloadType = buffer.readInteger(as: UInt8.self),
              payloadType == 0x78
        else {
            // Unsupported payload type
            return
        }

        _ = buffer.readInteger(as: UInt16.self) // Sequence
        _ = buffer.readInteger(as: UInt32.self) // Timestamp

        guard let ssrc = buffer.readInteger(as: UInt32.self)
        else {
            return
        }

        let packet = DiscordAudioVoicePacket(
            ssrc: ssrc,
            data: Data(buffer: buffer)
        )

        for continuation in packetsStreamContinuations {
            continuation.yield(packet)
        }
    }
}

struct DiscordAudioVoicePacket {
    let ssrc: UInt32
    let data: Data
}