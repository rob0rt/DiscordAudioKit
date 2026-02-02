/// https://www.iana.org/assignments/rtp-parameters/rtp-parameters.xhtml#rtp-parameters-1
public enum RTPType {
    case pcmu
    case gsm
    case g723
    case dvi4(DVI4SampleRate)
    case lpc
    case pcma
    case g722
    case l16(channels: UInt8)
    case qcelp
    case cn
    case mpa
    case g728
    case g729
    case celB
    case jpeg
    case nv
    case h261
    case mpv
    case mp2t
    case h263
    case dynamic(UInt8)

    public enum DVI4SampleRate {
        case `8000`
        case `16000`
        case `11025`
        case `22050`
    }

    init?(from: UInt8) {
        switch from {
        case 0: self = .pcmu
        case 3: self = .gsm
        case 4: self = .g723
        case 5: self = .dvi4(.`8000`)
        case 6: self = .dvi4(.`16000`)
        case 7: self = .lpc
        case 8: self = .pcma
        case 9: self = .g722
        case 10: self = .l16(channels: 1)
        case 11: self = .l16(channels: 2)
        case 12: self = .qcelp
        case 13: self = .cn
        case 14: self = .mpa
        case 15: self = .g728
        case 16: self = .dvi4(.`11025`)
        case 17: self = .dvi4(.`22050`)
        case 18: self = .g729
        case 25: self = .celB
        case 26: self = .jpeg
        case 28: self = .nv
        case 31: self = .h261
        case 32: self = .mpv
        case 33: self = .mp2t
        case 34: self = .h263
        case 96...127: self = .dynamic(from)
        default:
            return nil
        }
    }
}