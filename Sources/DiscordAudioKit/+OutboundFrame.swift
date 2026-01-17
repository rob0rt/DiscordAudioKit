import WSCore
import Foundation
import NIOCore

extension WebSocketOutboundWriter.OutboundFrame {
    init(from event: VoiceGateway.Event) throws {
        switch event.data {
            // Client JSON-encoded opcodes
            // Should be kept in sync with `VoiceGateway.Event.encode`
            case .identify,
                 .selectProtocol,
                 .heartbeat,
                 .speaking,
                 .resume,
                 .daveTransitionReady,
                 .daveMLSInvalidCommitWelcome:
                
                guard let data = try? JSONEncoder().encode(event),
                      let string = String(data: data, encoding: .utf8) else {
                    throw VoiceGateway.EncodingError.jsonEncodingFailure(opcode: event.data.opcode)
                }
                self = .text(string)

            // Client binary-encoded opcodes
            // (format: [opcode: UInt8][data: Data])
            case .daveMLSKeyPackage(let data),
                 .daveMLSCommitWelcome(let data):

                var frame = Data([event.data.opcode.rawValue])
                frame.append(data)
                self = .binary(ByteBuffer(data: frame))
            
            default:
                // Unsupported opcode for client (outbound) frame
                throw VoiceGateway.EncodingError.invalidClientOpcode(opcode: event.data.opcode)
        }
    }
}