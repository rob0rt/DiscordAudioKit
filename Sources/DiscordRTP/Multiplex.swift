import NIOCore

/// Represents either an RTP or RTCP packet for multiplexed handling.
enum MultiplexRTP {
    case RTP(RTPPacket)

    // TODO: Implement RTCP packet parsing? Not currently needed.
    case RTCP

    init?(from buffer: ByteBuffer) {
        guard let firstByte = buffer.getInteger(at: buffer.readerIndex, as: UInt8.self) else {
            return nil
        }

        if RTCPControlPacketType(from: firstByte) != nil {
            self = .RTCP
            return
        }

        guard let rtpPacket = RTPPacket(rawValue: buffer) else {
            return nil
        }
        self = .RTP(rtpPacket)
    }
}