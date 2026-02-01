import DaveKit
import Foundation
import Logging
import NIO
import OpusKit

let logger = Logger(label: "net.robort.discordaudiokit")

public actor DiscordAudioSession: DaveSessionDelegate {

    /// Dave session manager for handling encryption/decryption and session management.
    private lazy var dave: DaveSessionManager = {
        return DaveSessionManager(
            selfUserId: "",
            groupId: 0,
            delegate: self,
        )
    }()

    /// Opus decoder for decoding incoming audio frames.
    let decoder = try! Decoder(sampleRate: .`48000`, channels: .stereo)

    /// Opus encoder for encoding outgoing audio frames.
    let encoder = try! Encoder(sampleRate: .`48000`, channels: .stereo, mode: .voip)

    /// SSRCs, (sync source identifiers) are used to identify audio sources in RTP packets and
    /// are mapped to user IDs.
    private var knownSSRCs: [UInt32: String] = [:]

    /// The task managing events from the gateway.
    private var gatewayEventsTask: Task<Void, Error>?

    /// Once we receive a "ready" event from the gateway, we can establish a UDP connection to
    /// receive voice packets.
    private var udpTask: Task<Void, Error>?

    /// A reference to the underlying gateway for sending events.
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
            await session.setGatewayEventsTask {
                for await event: VoiceGateway.ServerEvent in gateway.events {
                    // TODO: Handle errors when processing events
                    try await session.handleGatewayEvent(event)
                }
            }
            try? await session.gatewayEventsTask?.value
        }
    }

    private func setupUDPConnection(
        ready: VoiceGateway.ServerEvent.Ready,
    ) async throws {
        self.udpTask = Task {
            defer {
                // When the UDP connection ends, cancel the gateway events task
                self.gatewayEventsTask?.cancel()
            }

            try await DiscordAudioUDPConnection.connect(host: ready.ip, port: Int(ready.port)) { connection, externalAddress in
                await self.gateway.send(.init(
                    data: .selectProtocol(.init(
                        protocol: "udp",
                        data: .init(
                            address: externalAddress.ip,
                            port: externalAddress.port,

                            // TODO: Check supported encryption modes from "ready" event and select appropriately
                            mode: "aead_aes256_gcm_rtpsize",
                        ),
                    )),
                ))
                
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
    }

    private func handleGatewayEvent(
        _ event: VoiceGateway.ServerEvent,
    ) async throws {
        switch event.data {
        case .ready(let ready):
            try await self.setupUDPConnection(ready: ready)

        case .speaking(let speaking):
            self.knownSSRCs[speaking.ssrc] = speaking.userId

        case .clientsConnect(let clients):
            for userId in clients.userIds {
                await dave.addUser(userId: userId)
            }

        case .clientDisconnect(let client):
            await dave.removeUser(userId: client.userId)

        case .davePrepareTransition(let transition):
            await dave.prepareTransition(
                transitionId: transition.transitionId,
                protocolVersion: transition.protocolVersion,
            )

        case .daveExecuteTransition(let transition):
            await dave.executeTransition(transitionId: transition.transitionId)

        case .davePrepareEpoch(let epoch):
            await dave.prepareEpoch(
                epoch: String(epoch.epoch),
                protocolVersion: epoch.protocolVersion,
            )

        case .daveMLSExternalSender(let data):
            await dave.mlsExternalSenderPackage(externalSenderPackage: data)

        case .daveMLSProposals(let data):
            await dave.mlsProposals(proposals: data)

        case .daveMLSAnnounceCommitTransition(let transitionId, let commit):
            await dave.mlsPrepareCommitTransition(
                transitionId: transitionId,
                commit: commit,
            )

        case .daveMLSWelcome(let transitionId, let welcome):
            await dave.mlsWelcome(transitionId: transitionId, welcome: welcome)

        default:
            break
        }
    }

    private func setGatewayEventsTask(_ gatewayEvents: @escaping @Sendable () async throws -> Void) async {
        self.gatewayEventsTask = Task {
            try await gatewayEvents()
        }
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
