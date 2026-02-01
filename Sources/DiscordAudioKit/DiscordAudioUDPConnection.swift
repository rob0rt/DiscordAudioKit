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
        onConnect: @Sendable @escaping (DiscordAudioUDPConnection, (ip: String, port: UInt16)) async throws -> Void
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
            guard let externalAddress = try await discoverExternalIP(
                inbound: inbound,
                outbound: outbound,
                ssrc: UInt32.random(in: 0...UInt32.max),
                socketAddress: socketAddress
            ) else {
                return
            }
            
            let connection = DiscordAudioUDPConnection(
                inbound: inbound,
                outbound: outbound,
                socketAddress: socketAddress
            )

            try await onConnect(connection, externalAddress)
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

    /// Perform IP discovery to find the external IP and port
    /// Reference: https://discord.com/developers/docs/topics/voice-connections#ip-discovery
    private static func discoverExternalIP(
        inbound: NIOAsyncChannelInboundStream<AddressedEnvelope<ByteBuffer>>,
        outbound: NIOAsyncChannelOutboundWriter<AddressedEnvelope<ByteBuffer>>,
        ssrc: UInt32,
        socketAddress: SocketAddress
    ) async throws -> (ip: String, port: UInt16)? {
        var buffer = ByteBufferAllocator().buffer(capacity: 74)
        buffer.writeInteger(UInt16(0x1)) // Type
        buffer.writeInteger(UInt16(70))  // Length
        buffer.writeInteger(ssrc)
        try await outbound.write(
            AddressedEnvelope(
                remoteAddress: socketAddress,
                data: buffer
            )
        )

        var iterator = inbound.makeAsyncIterator()
        guard let discoveryResponse = try await iterator.next() else {
            return nil
        }

        let data = discoveryResponse.data
        guard
            let address = data.getData(at: 6, length: 64),
            let address = String(
                data: address.prefix(upTo: address.firstIndex(of: 0) ?? address.endIndex),
                encoding: .utf8,
            ),
            let port = data.getInteger(at: 70, as: UInt16.self)
        else {
            return nil
        }

        return (ip: address, port: port)
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