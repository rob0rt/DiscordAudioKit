import DaveKit
import Foundation
import Logging
import NIO
import OpusKit
import WSClient
import OpusKit

let logger = Logger(label: "net.robort.discordaudiokit")

public actor DiscordAudioSession {

    private let endpoint: String
    private let guildId: String
    private let userId: String
    private let sessionId: String
    private let token: String

    private let decoder: Decoder = try! Decoder(sampleRate: .`48000`, channels: .stereo)

    private var userSsrcs: [UInt32: String] = [:]

    init(
        endpoint: String,
        guildId: String,
        userId: String,
        sessionId: String,
        token: String,
    ) {
        self.endpoint = endpoint
        self.guildId = guildId
        self.userId = userId
        self.sessionId = sessionId
        self.token = token
    }

    public func connect() async throws {
        let gateway = DiscordAudioGateway(
            endpoint: endpoint,
            serverId: guildId,
            userId: userId,
            sessionId: sessionId,
            token: token,
        )

        let dave = DaveSessionManager(
            selfUserId: userId,
            groupId: UInt64(guildId)!,
            delegate: gateway,
        )

        await withTaskGroup(of: Void.self) { group in
            group.addTask {
                try? await gateway.connect()
            }

            // group.addTask {
            for await event in await gateway.events {
                group.addTask {
                    switch event.data {
                    case .ready(let ready):
                        try? await self.listen(ready: ready, dave: dave)
                    case .clientsConnect(let clients):
                        for userId in clients.userIds {
                            await dave.addUser(userId: userId)
                        }
                    case .clientDisconnect(let client):
                        await dave.removeUser(userId: client.userId)
                    case .davePrepareTransition(let transition):
                        await dave.prepareTransition(
                            transitionId: transition.transitionId,
                            protocolVersion: transition.protocolVersion)
                    case .daveExecuteTransition(let transition):
                        await dave.executeTransition(transitionId: transition.transitionId)
                    case .davePrepareEpoch(let epoch):
                        await dave.prepareEpoch(
                            epoch: String(epoch.epoch), protocolVersion: epoch.protocolVersion)
                    case .daveMLSExternalSender(let data):
                        await dave.mlsExternalSenderPackage(externalSenderPackage: data)
                    case .daveMLSProposals(let data):
                        await dave.mlsProposals(proposals: data)
                    case .daveMLSAnnounceCommitTransition(let transitionId, let commit):
                        await dave.mlsPrepareCommitTransition(
                            transitionId: transitionId, commit: commit)
                    case .daveMLSWelcome(let transitionId, let welcome):
                        await dave.mlsWelcome(transitionId: transitionId, welcome: welcome)
                    default:
                        break
                    }
                }
            }
        }
    }

    nonisolated private func listen(
        ready: VoiceGateway.Ready,
        dave: DaveSessionManager
    ) async throws {
        let server = try await DatagramBootstrap(group: NIOSingletons.posixEventLoopGroup)
            .bind(host: ready.ip, port: Int(ready.port))
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
            for try await var packet in inbound {
                try await self.processVoicePacket(
                    buffer: &packet.data,
                    dave: dave,
                )
            }
        }
    }

    private func processVoicePacket(
        buffer: inout ByteBuffer,
        dave: DaveSessionManager,
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

        guard let ssrc = buffer.readInteger(as: UInt32.self),
              let userId = self.userSsrcs[ssrc]
        else {
            // Unknown SSRC (user missing from map - did we miss a "speaking" event?)
            return
        }

        guard let decryptedFrame = try? await dave.decrypt(userId: userId, data: Data(buffer: buffer)) else {
            return
        }

        var decodedData = Data()
        _ = try self.decoder.decode(decryptedFrame, to: &decodedData)
    }
}

extension DiscordAudioGateway: DaveSessionDelegate {
    public func mlsKeyPackage(keyPackage: Data) async {
        let event = VoiceGateway.Event(from: .daveMLSKeyPackage(keyPackage))
        try? await send(event)
    }

    public func readyForTransition(transitionId: UInt16) async {
        let event = VoiceGateway.Event(
            from: .daveTransitionReady(.init(transitionId: transitionId)))
        try? await send(event)
    }

    public func mlsCommitWelcome(welcome: Data) async {
        let event = VoiceGateway.Event(from: .daveMLSCommitWelcome(welcome))
        try? await send(event)
    }

    public func mlsInvalidCommitWelcome(transitionId: UInt16) async {
        let event = VoiceGateway.Event(
            from: .daveMLSInvalidCommitWelcome(.init(transitionId: transitionId)))
        try? await send(event)
    }
}
