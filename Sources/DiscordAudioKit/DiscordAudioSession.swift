import DaveKit
import Foundation
import Logging
import NIO
import OpusKit
import DiscordRTP
import Crypto

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
    /// the voice server.
    private var udpConnectionTask: Task<Void, Error>?

    /// Once we get the session description from the gateway, we can listen for incoming audio
    /// packets.
    private var udpListenTask: Task<Void, Error>?

    /// A reference to the underlying gateway for sending events.
    private let gateway: DiscordAudioGateway

    /// The underlying UDP connection to the voice server.
    private var udpConnection: DiscordAudioUDPConnection?

    private init(gateway: DiscordAudioGateway) {
        self.gateway = gateway
    }

    // MARK: - Public API

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

    // MARK: - Gateway Event Handling

    private func handleGatewayEvent(
        _ event: VoiceGateway.ServerEvent,
    ) async throws {
        switch event.data {
        case .ready(let ready):
            try await self.setupUDPConnection(ready: ready)
        
        case .sessionDescription(let description):
            await dave.selectProtocol(protocolVersion: UInt16(description.daveProtocolVersion))
            self.listen(description: description)

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

    // MARK: - UDP Connection and Listening
    
    /// Connect to the UDP voice server using the information from the "ready" event.
    private func setupUDPConnection(
        ready: VoiceGateway.ServerEvent.Ready,
    ) async throws {
        self.udpConnectionTask = Task {
            defer {
                // When the UDP connection ends, cancel the gateway events task
                self.gatewayEventsTask?.cancel()
            }

            try await DiscordAudioUDPConnection.connect(
                host: ready.ip,
                port: Int(ready.port)
            ) { connection in
                guard let (ip, port) = try await connection.discoverExternalIP(
                    ssrc: ready.ssrc,
                ) else {
                    logger.error("Failed to discover external IP and port")
                    return
                }

                guard let mode = CryptoMode.allCases.first(where: { mode in
                    ready.modes.contains(mode.rawValue)
                }) else {
                    logger.error("No supported crypto modes found")
                    return
                }

                await self.gateway.send(.init(
                    data: .selectProtocol(.init(
                        protocol: "udp",
                        data: .init(
                            address: ip,
                            port: port,
                            mode: mode.rawValue,
                        ),
                    )),
                ))

                await self.setUDPConnection(connection)
            }
        }
    }

    /// Start listening for incoming audio packets on the UDP connection.
    private func listen(
        description: VoiceGateway.ServerEvent.SessionDescription,
    ) {
        guard let cryptoMode = CryptoMode(rawValue: description.mode) else {
            logger.error("Unsupported crypto mode: \(description.mode)")
            return
        }

        let key = SymmetricKey(data: description.secretKey)

        self.udpListenTask = Task {
            guard let udpConnection = self.udpConnection else {
                return
            }

            defer {
                // When the UDP listening ends, cancel the UDP connection task
                self.udpConnectionTask?.cancel()
            }

            for try await envelope in udpConnection.inbound {
                guard let packet = RTPPacket(from: envelope.data) else {
                    continue
                }

                await self.processVoicePacket(
                    packet,
                    cryptoMode: cryptoMode,
                    key: key
                )
            }
        }
    }

    /// Process an incoming voice packet. Voice packets are RTP packets that are encrypted
    /// using the selected crypto mode and key, E2EE encrypted using Dave, and then encoded
    /// using OPUS.
    private func processVoicePacket(
        _ packet: RTPPacket,
        cryptoMode: CryptoMode,
        key: SymmetricKey
    ) async {
        var buffer = packet.payload

        // First, decrypt the RTP packet payload

        var extensionLength: UInt16?
        if packet.extension {
            // If the packet has an extension, the metadata for the extension is stored
            // outside of the encrypted portion of the payload, but the extension data itself
            // is encrypted. This is not compliant with the RTP spec, but is how Discord
            // implements it.
            guard let _ = buffer.readInteger(as: UInt16.self), // extension info
                  let length = buffer.readInteger(as: UInt16.self)
            else {
                return
            }

            extensionLength = length
        }

        guard var data = cryptoMode.decrypt(
            buffer: packet.payload,
            with: key,
        ) else {
            return
        }

        if let extensionLength {
            data.removeFirst(Int(extensionLength) * 4)
        }

        if data.isEmpty {
            return
        }

        // We've removed the crypto layer, now to remove the Dave E2EE layer

        guard let userId = knownSSRCs[packet.ssrc] else {
            return
        }

        guard let data = try? await dave.decrypt(userId: userId, data: data, mediaType: .audio) else {
            return
        }

        // And finally, decode the OPUS audio frame

        var decodedData = Data()
        guard let _ = try? decoder.decode(data, to: &decodedData) else {
            return
        }
    }

    // MARK: - Setters for actor isolation

    private func setGatewayEventsTask(_ gatewayEvents: @escaping @Sendable () async throws -> Void) {
        self.gatewayEventsTask = Task {
            try await gatewayEvents()
        }
    }

    private func setUDPConnection(_ connection: DiscordAudioUDPConnection) {
        self.udpConnection = connection
    }

    // MARK: - DaveSessionDelegate

    public func mlsKeyPackage(keyPackage: Data) async {
        let event = VoiceGateway.ClientEvent(data: .daveMLSKeyPackage(keyPackage))
        await gateway.send(event)
    }

    public func readyForTransition(transitionId: UInt16) async {
        let event = VoiceGateway.ClientEvent(
            data: .daveTransitionReady(.init(transitionId: transitionId)),
        )
        await gateway.send(event)
    }

    public func mlsCommitWelcome(welcome: Data) async {
        let event = VoiceGateway.ClientEvent(data: .daveMLSCommitWelcome(welcome))
        await gateway.send(event)
    }

    public func mlsInvalidCommitWelcome(transitionId: UInt16) async {
        let event = VoiceGateway.ClientEvent(
            data: .daveMLSInvalidCommitWelcome(.init(transitionId: transitionId)),
        )
        await gateway.send(event)
    }
}
