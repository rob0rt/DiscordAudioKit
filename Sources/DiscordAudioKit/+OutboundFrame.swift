import WSCore
import Foundation
import NIOCore

extension WebSocketOutboundWriter.OutboundFrame {
    init(from event: VoiceGateway.ClientEvent) throws {
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
                
                let data = try! JSONEncoder().encode(event)
                self = .text(String(data: data, encoding: .utf8)!)

            // Client binary-encoded opcodes
            // (format: [opcode: UInt8][data: Data])
            case .daveMLSKeyPackage(let data),
                 .daveMLSCommitWelcome(let data):

                var frame = Data([event.data.opcode.rawValue])
                frame.append(data)
                self = .binary(ByteBuffer(data: frame))
        }
    }
}