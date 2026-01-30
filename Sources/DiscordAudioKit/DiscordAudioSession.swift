import DaveKit
import Foundation
import Logging
import NIO
import OpusKit

let logger = Logger(label: "net.robort.discordaudiokit")

public actor DiscordAudioSession: DaveSessionDelegate {

    // private let decoder: Decoder = try! Decoder(sampleRate: .`48000`, channels: .stereo)

    private lazy var dave: DaveSessionManager = {
        return DaveSessionManager(
            selfUserId: "",
            groupId: 0,
            delegate: self,
        )
    }()
    private var knownSSRCs: [UInt32: String] = [:]
    private var udpTask: Task<Void, Error>?

    private let gateway: DiscordAudioGateway

    private init(gateway: DiscordAudioGateway) {
        self.gateway = gateway
    }

    public static func connect(
        endpoint: String,
        guildId: String,
        userId: String,
        sessionId: String,
        token: String,
    ) async throws {
        try await DiscordAudioGateway.connect(
            endpoint: endpoint,
            serverId: guildId,
            userId: userId,
            sessionId: sessionId,
            token: token
        ) { gateway in
            let session = DiscordAudioSession(gateway: gateway)

            for await event: VoiceGateway.ServerEvent in gateway.events {
                await session.handleGatewayEvent(event)
            }
        }
    }

    private func setupUDPConnection(
        ready: VoiceGateway.ServerEvent.Ready,
    ) async throws {
        try await DiscordAudioUDPConnection.connect(host: ready.ip, port: Int(ready.port)) { connection in
            for try await packet in connection.packets {
                if let packet {
                    try await self.processVoicePacket(
                        packet: packet,
                        dave: self.dave,
                    )
                }
            }
        }
    }

    private func handleGatewayEvent(
        _ event: VoiceGateway.ServerEvent,
    ) async {
        switch event.data {
        case .ready(let ready):
            try? await self.setupUDPConnection(ready: ready)
        case .speaking(let speaking):
            await self.setKnownSSRC(userId: speaking.userId, ssrc: speaking.ssrc)
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

    private func setKnownSSRC(userId: String, ssrc: UInt32) async {
        self.knownSSRCs[ssrc] = userId
    }

    private func processVoicePacket(
        packet: DiscordAudioVoicePacket,
        dave: DaveSessionManager,
    ) async throws {
        guard let userId = self.knownSSRCs[packet.ssrc] else {
            // Unknown SSRC (user missing from map - did we miss a "speaking" event?)
            return
        }

        guard let decryptedFrame = try? await dave.decrypt(userId: userId, data: packet.data) else {
            return
        }

        var decodedData = Data()
        // _ = try self.decoder.decode(decryptedFrame, to: &decodedData)
    }

    public func mlsKeyPackage(keyPackage: Data) async {
        let event = VoiceGateway.ClientEvent(data: .daveMLSKeyPackage(keyPackage))
        await gateway.send(event)
    }

    public func readyForTransition(transitionId: UInt16) async {
        let event = VoiceGateway.ClientEvent(
            data: .daveTransitionReady(.init(transitionId: transitionId)))
        await gateway.send(event)
    }

    public func mlsCommitWelcome(welcome: Data) async {
        let event = VoiceGateway.ClientEvent(data: .daveMLSCommitWelcome(welcome))
        await gateway.send(event)
    }

    public func mlsInvalidCommitWelcome(transitionId: UInt16) async {
        let event = VoiceGateway.ClientEvent(
            data: .daveMLSInvalidCommitWelcome(.init(transitionId: transitionId)))
        await gateway.send(event)
    }
}
