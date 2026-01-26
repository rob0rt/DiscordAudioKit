import NIO
import Foundation
import NIOFoundationCompat

final actor DiscordAudioUDPConnection {
    private let outbound: NIOAsyncChannelOutboundWriter<AddressedEnvelope<ByteBuffer>>
    private let socketAddress: SocketAddress

    let packets: AsyncStream<DiscordAudioVoicePacket?>

    private init(
        inbound: NIOAsyncChannelInboundStream<AddressedEnvelope<ByteBuffer>>,
        outbound: NIOAsyncChannelOutboundWriter<AddressedEnvelope<ByteBuffer>>,
        socketAddress: SocketAddress
    ) {
        self.outbound = outbound
        self.socketAddress = socketAddress
        self.packets = AsyncStream { continuation in
            Task {
                for try await envelope in inbound {
                    let packet = Self.processVoicePacket(buffer: envelope.data)
                    continuation.yield(packet)
                }
                continuation.finish()
            }
        }
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
                inbound: inbound,
                outbound: outbound,
                socketAddress: socketAddress
            )

            try await onConnect(connection)
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

    /// Process a raw UDP voice packet
    private static func processVoicePacket(
        buffer: consuming ByteBuffer,
    ) -> DiscordAudioVoicePacket? {
        guard let version = buffer.readInteger(as: UInt8.self),
              version == 0x80
        else {
            // Unsupported RTP version
            return nil
        }

        guard let payloadType = buffer.readInteger(as: UInt8.self),
              payloadType == 0x78
        else {
            // Unsupported payload type
            return nil
        }

        _ = buffer.readInteger(as: UInt16.self) // Sequence
        _ = buffer.readInteger(as: UInt32.self) // Timestamp

        guard let ssrc = buffer.readInteger(as: UInt32.self)
        else {
            return nil
        }

        return DiscordAudioVoicePacket(
            ssrc: ssrc,
            data: Data(buffer: buffer)
        )
    }
}

struct DiscordAudioVoicePacket {
    let ssrc: UInt32
    let data: Data
}