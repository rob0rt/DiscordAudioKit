import WSClient
import Foundation
import NIOFoundationCompat

enum VoiceGateway  {

    // https://discord.com/developers/docs/topics/opcodes-and-status-codes#voice
    enum Opcode: UInt8, Codable {
        case identify = 0
        case selectProtocol = 1
        case ready = 2
        case heartbeat = 3
        case sessionDescription = 4
        case speaking = 5
        case heartbeatAck = 6
        case resume = 7
        case hello = 8
        case resumed = 9
        case clientsConnect = 11
        case clientDisconnect = 13
        case davePrepareTransition = 21
        case daveExecuteTransition = 22
        case daveTransitionReady = 23
        case davePrepareEpoch = 24
        case daveMLSExternalSender = 25
        case daveMLSKeyPackage = 26
        case daveMLSProposals = 27
        case daveMLSCommitWelcome = 28
        case daveMLSAnnounceCommitTransition = 29
        case daveMLSWelcome = 30
        case daveMLSInvalidCommitWelcome = 31
    }

    struct ServerEvent: Decodable {
        enum Payload {
            case ready(Ready)
            case sessionDescription(SessionDescription)
            case speaking(Speaking)
            case heartbeatAck(HeartbeatAck)
            case hello(Hello)
            case resumed
            case clientsConnect(ClientsConnect)
            case clientDisconnect(ClientDisconnect)
            case davePrepareTransition(DavePrepareTransition)
            case daveExecuteTransition(DaveCommitTransition)
            case davePrepareEpoch(DavePrepareEpoch)
            case daveMLSExternalSender(Data)
            case daveMLSProposals(Data)
            case daveMLSAnnounceCommitTransition(transitionId: UInt16, commit: Data)
            case daveMLSWelcome(transitionId: UInt16, welcome: Data)

            var opcode: Opcode {
                switch self {
                case .ready:
                    return .ready
                case .sessionDescription:
                    return .sessionDescription
                case .speaking:
                    return .speaking
                case .heartbeatAck:
                    return .heartbeatAck
                case .hello:
                    return .hello
                case .resumed:
                    return .resumed
                case .clientsConnect:
                    return .clientsConnect
                case .clientDisconnect:
                    return .clientDisconnect
                case .davePrepareTransition:
                    return .davePrepareTransition
                case .daveExecuteTransition:
                    return .daveExecuteTransition
                case .davePrepareEpoch:
                    return .davePrepareEpoch
                case .daveMLSExternalSender:
                    return .daveMLSExternalSender
                case .daveMLSProposals:
                    return .daveMLSProposals
                case .daveMLSAnnounceCommitTransition:
                    return .daveMLSAnnounceCommitTransition
                case .daveMLSWelcome:
                    return .daveMLSWelcome
                }
            }
        }

        enum CodingKeys: String, CodingKey {
            case opcode = "op"
            case data = "d"
            case sequence = "seq"
        }

        let data: Payload
        let sequence: UInt16?

        init?(from message: WebSocketMessage) {
            switch message {
            case .text(let text):
                guard let buffer = text.data(using: .utf8) else {
                    return nil
                }
                guard let s = try? JSONDecoder().decode(Self.self, from: buffer) else {
                    return nil
                }
                self = s
            case .binary(var buffer):
                guard let seq = buffer.readInteger(as: UInt16.self) else {
                    return nil
                }
                self.sequence = seq

                guard let opcode = buffer.readInteger(as: UInt8.self),
                      let opcode = Opcode(rawValue: opcode)
                else {
                    return nil
                }

                switch opcode {
                    case .daveMLSExternalSender:
                        self.data = .daveMLSExternalSender(Data(buffer: buffer))
                    case .daveMLSProposals:
                        self.data = .daveMLSProposals(Data(buffer: buffer))
                    case .daveMLSAnnounceCommitTransition:
                        guard let transitionId = buffer.readInteger(as: UInt16.self) else {
                            return nil
                        }
                        let commit = Data(buffer: buffer)
                        self.data = .daveMLSAnnounceCommitTransition(transitionId: transitionId, commit: commit)
                    case .daveMLSWelcome:
                        guard let transitionId = buffer.readInteger(as: UInt16.self) else {
                            return nil
                        }
                        let welcome = Data(buffer: buffer)
                        self.data = .daveMLSWelcome(transitionId: transitionId, welcome: welcome)
                    default:
                        return nil
                }
            }
        }

        init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            
            let opcode = try container.decode(Opcode.self, forKey: .opcode)
            self.sequence = try container.decodeIfPresent(UInt16.self, forKey: .sequence)

            func decodeData<D: Decodable>(as type: D.Type = D.self) throws -> D {
                try container.decode(D.self, forKey: .data)
            }

            switch opcode {
            case .ready:
                self.data = try .ready(decodeData())
            case .sessionDescription:
                self.data = try .sessionDescription(decodeData())
            case .speaking:
                self.data = try .speaking(decodeData())
            case .heartbeatAck:
                self.data = try .heartbeatAck(decodeData())
            case .hello:
                self.data = try .hello(decodeData())
            case .resumed:
                self.data = .resumed
            case .clientsConnect:
                self.data = try .clientsConnect(decodeData())
            case .clientDisconnect:
                self.data = try .clientDisconnect(decodeData())
            case .davePrepareTransition:
                self.data = try .davePrepareTransition(decodeData())
            case .daveExecuteTransition:
                self.data = try .daveExecuteTransition(decodeData())
            case .davePrepareEpoch:
                self.data = try .davePrepareEpoch(decodeData())
            case .daveMLSExternalSender,
                 .daveMLSProposals,
                 .daveMLSAnnounceCommitTransition,
                 .daveMLSWelcome:
                throw DecodingError.dataCorruptedError(
                    forKey: .opcode,
                    in: container,
                    debugDescription: "Binary opcode cannot be decoded from JSON: \(opcode)",
                )
            case .identify,
                 .selectProtocol,
                 .heartbeat,
                 .resume,
                 .daveTransitionReady,
                 .daveMLSKeyPackage,
                 .daveMLSCommitWelcome,
                 .daveMLSInvalidCommitWelcome:
                throw DecodingError.dataCorruptedError(
                    forKey: .opcode,
                    in: container,
                    debugDescription: "Unsupported server opcode: \(opcode)",
                )
            }
        }

        /// https://discord.com/developers/docs/topics/voice-connections#establishing-a-voice-websocket-connection-example-voice-ready-payload
        struct Ready: Decodable {
            let ssrc: UInt32
            let ip: String
            let port: UInt16
            let modes: [String]
            let heartbeatInterval: UInt32
        }
      
        /// https://discord.com/developers/docs/topics/voice-connections#transport-encryption-modes-example-session-description-payload
        struct SessionDescription: Codable {
            let mode: String
            let secretKey: [UInt8]
            let daveProtocolVersion: UInt8
        }

        /// https://discord.com/developers/docs/topics/voice-connections#speaking-example-speaking-payload
        struct Speaking: Codable {
            let speaking: SpeakingFlags
            let ssrc: UInt32
            let userId: String
        }

        /// https://discord.com/developers/docs/topics/voice-connections#heartbeating-example-heartbeat-ack-payload-since-v8
        struct HeartbeatAck: Decodable {
            let nonce: UInt64

            enum CodingKeys: String, CodingKey {
                case nonce = "t"
            }
        }

        /// https://discord.com/developers/docs/topics/voice-connections#heartbeating-example-hello-payload
        struct Hello: Decodable {
            let heartbeatInterval: UInt32
        }

        // The following types have been inferred by utilizing Dysnomia's implementation
        // of the Discord Voice Gateway.
        //
        // https://github.com/projectdysnomia/dysnomia

        struct ClientsConnect: Decodable {
            let userIds: [String]
        }

        struct ClientDisconnect: Decodable {
            let userId: String
        }

        struct DavePrepareTransition: Decodable {
            let transitionId: UInt16
            let protocolVersion: UInt16
        }

        struct DaveCommitTransition: Decodable {
            let transitionId: UInt16
        }

        struct DavePrepareEpoch: Decodable {
            let epoch: UInt32
            let protocolVersion: UInt16
        }
    }

    struct ClientEvent: Encodable {
        enum Payload {
            case identify(Identify)
            case selectProtocol(SelectProtocol)
            case heartbeat(Heartbeat)
            case speaking(Speaking)
            case resume(Resume)
            case daveTransitionReady(DaveTransitionReady)
            case daveMLSKeyPackage(Data)
            case daveMLSCommitWelcome(Data)
            case daveMLSInvalidCommitWelcome(DaveMLSInvalidCommitWelcome)

            var opcode: Opcode {
                switch self {
                case .identify:
                    return .identify
                case .selectProtocol:
                    return .selectProtocol
                case .heartbeat:
                    return .heartbeat
                case .speaking:
                    return .speaking
                case .resume:
                    return .resume
                case .daveTransitionReady:
                    return .daveTransitionReady
                case .daveMLSKeyPackage:
                    return .daveMLSKeyPackage
                case .daveMLSCommitWelcome:
                    return .daveMLSCommitWelcome
                case .daveMLSInvalidCommitWelcome:
                    return .daveMLSInvalidCommitWelcome
                }
            }
        }

         enum CodingKeys: String, CodingKey {
            case opcode = "op"
            case data = "d"
        }

        let data: Payload

        func encode(to encoder: any Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(data.opcode, forKey: .opcode)

            switch data {
            case .identify(let identify):
                try container.encode(identify, forKey: .data)
            case .selectProtocol(let selectProtocol):
                try container.encode(selectProtocol, forKey: .data)
            case .heartbeat(let heartbeat):
                try container.encode(heartbeat, forKey: .data)
            case .speaking(let speaking):
                try container.encode(speaking, forKey: .data)
            case .resume(let resume):
                try container.encode(resume, forKey: .data)
            case .daveTransitionReady(let daveTransitionReady):
                try container.encode(daveTransitionReady, forKey: .data)
            case .daveMLSInvalidCommitWelcome(let daveMLSInvalidCommitWelcome):
                try container.encode(daveMLSInvalidCommitWelcome, forKey: .data)
            case .daveMLSKeyPackage,
                 .daveMLSCommitWelcome:
                throw EncodingError.invalidValue(
                    data,
                    EncodingError.Context(
                        codingPath: container.codingPath,
                        debugDescription: "Binary opcode cannot be encoded to JSON: \(data.opcode)"
                    )
                )
            }
        }

        /// https://discord.com/developers/docs/topics/voice-connections#establishing-a-voice-websocket-connection-example-voice-identify-payload
        struct Identify: Encodable {
            let serverId: String
            let userId: String
            let sessionId: String
            let token: String
            let maxDaveProtocolVersion: UInt16
        }

        /// https://discord.com/developers/docs/topics/voice-connections#establishing-a-voice-udp-connection-example-select-protocol-payload
        struct SelectProtocol: Encodable {
            let `protocol`: String
            let data: SelectProtocolData

            struct SelectProtocolData: Encodable {
                let address: String
                let port: UInt16
                let mode: String
            }
        }

        /// https://discord.com/developers/docs/topics/voice-connections#heartbeating-example-heartbeat-payload-since-v8
        struct Heartbeat: Encodable {
            let nonce: UInt64
            let sequence: Int

            enum CodingKeys: String, CodingKey {
                case nonce = "t"
                case sequence = "seq_ack"
            }
        }

        /// https://discord.com/developers/docs/topics/voice-connections#speaking-example-speaking-payload
        struct Speaking: Codable {
            let speaking: SpeakingFlags
            let delay: UInt32
            let ssrc: UInt32
        }

        /// https://discord.com/developers/docs/topics/voice-connections#resuming-voice-connection-example-resume-connection-payload-since-v8
        struct Resume: Encodable {
            let serverId: String
            let sessionId: String
            let token: String
            let sequence: UInt16

            enum CodingKeys: String, CodingKey {
                case serverId = "server_id"
                case sessionId = "session_id"
                case token
                case sequence = "seq_ack"
            }
        }

        struct DaveTransitionReady: Encodable {
            let transitionId: UInt16
        }

        struct DaveMLSInvalidCommitWelcome: Encodable {
            let transitionId: UInt16
        }
    }

    /// https://discord.com/developers/docs/topics/voice-connections#speaking
    struct SpeakingFlags: OptionSet, Codable {
        let rawValue: UInt8

        static let microphone = SpeakingFlags(rawValue: 1 << 0)
        static let soundshare = SpeakingFlags(rawValue: 1 << 1)
        static let priority = SpeakingFlags(rawValue: 1 << 2)
    }
}