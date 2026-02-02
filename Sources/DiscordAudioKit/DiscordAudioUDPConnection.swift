import NIO
import Foundation
import NIOFoundationCompat
import Crypto
import AsyncAlgorithms

final actor DiscordAudioUDPConnection {
    private static let KEEPALIVE_INTERVAL: Duration = .seconds(5)

    let inbound: NIOAsyncChannelInboundStream<AddressedEnvelope<ByteBuffer>>
    let outbound: NIOAsyncChannelOutboundWriter<AddressedEnvelope<ByteBuffer>>

    private let socketAddress: SocketAddress

    private init(
        inbound: NIOAsyncChannelInboundStream<AddressedEnvelope<ByteBuffer>>,
        outbound: NIOAsyncChannelOutboundWriter<AddressedEnvelope<ByteBuffer>>,
        socketAddress: SocketAddress
    ) {
        self.inbound = inbound
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

    /// Perform IP discovery to find the external IP and port
    /// Reference: https://discord.com/developers/docs/topics/voice-connections#ip-discovery
    func discoverExternalIP(
        ssrc: UInt32,
    ) async throws -> (ip: String, port: UInt16)? {
        var buffer = ByteBufferAllocator().buffer(capacity: 74)
        buffer.writeInteger(UInt16(0x1)) // Type (Send)
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

    /// Start sending keepalive packets at regular intervals
    func keepalive(ssrc: UInt32) async throws {
        for await _ in AsyncTimerSequence(
            interval: DiscordAudioUDPConnection.KEEPALIVE_INTERVAL,
            clock: .continuous
        ) {
            var buffer: ByteBuffer = ByteBufferAllocator().buffer(capacity: 4)
            buffer.writeInteger(ssrc, endianness: .big)
            try await send(buffer: buffer)
        }
    }
}
