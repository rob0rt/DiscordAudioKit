import DaveKit
import Foundation
import Logging
import NIO
import OpusKit

let logger = Logger(label: "net.robort.discordaudiokit")

public actor DiscordAudioSession {

    private let endpoint: String
    private let guildId: String
    private let userId: String
    private let sessionId: String
    private let token: String

    private let decoder: Decoder = try! Decoder(sampleRate: .`48000`, channels: .stereo)

    // Discord sends 
    private var knownSSRCs: [UInt32: String] = [:]

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
        try await DiscordAudioGateway.connect(
            endpoint: endpoint,
            serverId: guildId,
            userId: userId,
            sessionId: sessionId,
            token: token
        ) { gateway in
        
            let dave = DaveSessionManager(
                selfUserId: self.userId,
                groupId: UInt64(self.guildId)!,
                delegate: gateway,
            )

            for await event in await gateway.events {
                switch event.data {
                case .ready(let ready):
                    try? await self.listen(ready: ready, dave: dave)
                case .speaking(let speaking):
                    await self.setUserSSRC(userId: speaking.userId, ssrc: speaking.ssrc)
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

    nonisolated private func listen(
        ready: VoiceGateway.ServerEvent.Ready,
        dave: DaveSessionManager
    ) async throws {
        try await DiscordAudioUDPConnection.connect(host: ready.ip, port: Int(ready.port)) { connection in
            for try await packet in await connection.packets {
                try await self.processVoicePacket(
                    packet: packet,
                    dave: dave,
                )
            }
        }
    }

    private func setUserSSRC(userId: String, ssrc: UInt32) {
        knownSSRCs[ssrc] = userId
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
        _ = try self.decoder.decode(decryptedFrame, to: &decodedData)
    }
}

extension DiscordAudioGateway: DaveSessionDelegate {
    public func mlsKeyPackage(keyPackage: Data) async {
        let event = VoiceGateway.ClientEvent(data: .daveMLSKeyPackage(keyPackage))
        try? await send(event)
    }

    public func readyForTransition(transitionId: UInt16) async {
        let event = VoiceGateway.ClientEvent(
            data: .daveTransitionReady(.init(transitionId: transitionId)))
        try? await send(event)
    }

    public func mlsCommitWelcome(welcome: Data) async {
        let event = VoiceGateway.ClientEvent(data: .daveMLSCommitWelcome(welcome))
        try? await send(event)
    }

    public func mlsInvalidCommitWelcome(transitionId: UInt16) async {
        let event = VoiceGateway.ClientEvent(
            data: .daveMLSInvalidCommitWelcome(.init(transitionId: transitionId)))
        try? await send(event)
    }
}
