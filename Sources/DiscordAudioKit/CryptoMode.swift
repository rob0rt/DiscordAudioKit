import Crypto
import Foundation
import DiscordRTP
import NIOCore

enum CryptoMode: String, CaseIterable {
    case aes256Gcm = "aead_aes256_gcm_rtpsize"
    case xChaCha20Poly1305 = "aead_xchacha20_poly1305_rtpsize"

    func decrypt(
        buffer: consuming ByteBuffer,
        with key: SymmetricKey,
    ) -> Data? {
        guard
            let rtpNonce = buffer.readBytes(length: rtpNonceLength),
            let ciphertext = buffer.readData(length: buffer.readableBytes - tagLength),
            let tag = buffer.readData(length: tagLength)
        else {
            return nil
        }

        var nonce = Data(repeating: 0, count: nonceLength)
        nonce.replaceSubrange(nonce.count - rtpNonce.count ..< nonce.count, with: rtpNonce)

        switch self {
            case .aes256Gcm:
                guard
                    let nonce = try? AES.GCM.Nonce(data: nonce),
                    let box = try? AES.GCM.SealedBox(
                        nonce: nonce,
                        ciphertext: ciphertext,
                        tag: tag
                    )
                else {
                    return nil
                }
                return try? AES.GCM.open(box, using: key)

            case .xChaCha20Poly1305:
                guard
                    let nonce = try? ChaChaPoly.Nonce(data: nonce),
                    let box = try? ChaChaPoly.SealedBox(
                        nonce: nonce,
                        ciphertext: ciphertext,
                        tag: tag
                    )
                else {
                    return nil
                }
                return try? ChaChaPoly.open(box, using: key)
        }
    }

    /// The length of the nonce as it is stored in the RTP packet
    private var rtpNonceLength: Int {
        switch self {
            case .aes256Gcm:
                return 4
            case .xChaCha20Poly1305:
                return 4
        }
    }

    /// The length of the nonce as required by the crypto algorithm
    private var nonceLength: Int {
        switch self {
            case .aes256Gcm:
                // From `AES.GCM.defaultNonceByteCount`
                return 12
            case .xChaCha20Poly1305:
                // Other implementations sometimes use 24, but swift-crypto
                // requires 12.
                // From `ChaChaPoly.nonceByteCount`
                return 12
        }
    }

    /// The length of the authentication tag used by the crypto algorithm
    private var tagLength: Int {
        switch self {
            case .aes256Gcm:
                // From `AES.GCM.tagByteCount`
                return 16
            case .xChaCha20Poly1305:
                // From `ChaChaPoly.tagByteCount`
                return 16
        }
    }
} 