import CommonCrypto
import Foundation

// Protocol/frame facts are based on Polyfish0/abo-light-stick-app, released under GPL-3.0:
// LightStickCommandBuilder.kt at c11638d25ecf83a6d1eeef6334b42898a6b03ae8.
// This is an independent Swift implementation of its fixed AES-128-ECB RGB frame.
enum PenlightProtocol {
    private static let key: [UInt8] = [
        0x21, 0x74, 0x51, 0x64, 0x73, 0xA1, 0xF5, 0x35,
        0x10, 0x04, 0xA1, 0x3E, 0x6B, 0x71, 0x6A, 0xB9,
    ]

    static func encode(rgb: ScreenRGB) throws -> Data {
        let plaintext: [UInt8] = [
            0x82, 0x01, rgb.red, rgb.green, rgb.blue,
            0x00, 0x00, 0x00, 0x00, 0x00,
            0xFD, 0x47, 0x52, 0x41, 0x56, 0x45,
        ]
        var ciphertext = [UInt8](repeating: 0, count: plaintext.count)
        let outputCapacity = ciphertext.count
        var moved: size_t = 0
        let status = plaintext.withUnsafeBytes { input in
            key.withUnsafeBufferPointer { keyBytes in
                ciphertext.withUnsafeMutableBytes { output in
                    CCCrypt(
                        CCOperation(kCCEncrypt),
                        CCAlgorithm(kCCAlgorithmAES),
                        CCOptions(kCCOptionECBMode),
                        keyBytes.baseAddress,
                        kCCKeySizeAES128,
                        nil,
                        input.baseAddress,
                        plaintext.count,
                        output.baseAddress,
                        outputCapacity,
                        &moved
                    )
                }
            }
        }
        guard status == kCCSuccess, moved == 16 else {
            throw PenlightProtocolError.encryptionFailed(status: status)
        }
        return Data(ciphertext)
    }
}

private enum PenlightProtocolError: Error, LocalizedError {
    case encryptionFailed(status: CCCryptorStatus)

    var errorDescription: String? {
        switch self {
        case .encryptionFailed(let status):
            return "Could not encode the RGB command (CommonCrypto status \(status))."
        }
    }
}
