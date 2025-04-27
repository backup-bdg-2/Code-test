import CommonCrypto
import Foundation

/// Helper for basic cryptography operations using native iOS libraries
class CryptoHelper {
    // Singleton instance
    static let shared = CryptoHelper()

    private init() {}

    // MARK: - Encryption Methods

    /// Encrypt data using AES with a password
    /// - Parameters:
    ///   - data: Data to encrypt
    ///   - password: Password for encryption
    /// - Returns: Encrypted data as a base64 string
    func encryptAES(_ data: Data, password: String) -> String? {
        // Generate a key from the password
        guard let key = deriveKeyData(from: password, salt: "backdoorsalt", keyLength: 32) else {
            Debug.shared.log(message: "Key derivation failed for encryption", type: .error)
            return nil
        }

        // Generate random IV
        let iv = generateRandomBytes(length: 16)

        // Create a mutable data to store the cipher text
        let cipherData = NSMutableData()

        // Reserve space for the IV at the beginning
        cipherData.append(iv)

        // Create a buffer for the ciphertext
        let bufferSize = data.count + kCCBlockSizeAES128
        var buffer = [UInt8](repeating: 0, count: bufferSize)

        // Perform the encryption
        var numBytesEncrypted = 0

        let cryptStatus = key.withUnsafeBytes { keyBytes in
            iv.withUnsafeBytes { ivBytes in
                data.withUnsafeBytes { dataBytes in
                    CCCrypt(
                        CCOperation(kCCEncrypt),
                        CCAlgorithm(kCCAlgorithmAES),
                        CCOptions(kCCOptionPKCS7Padding),
                        keyBytes.baseAddress, key.count,
                        ivBytes.baseAddress,
                        dataBytes.baseAddress, data.count,
                        &buffer, bufferSize,
                        &numBytesEncrypted
                    )
                }
            }
        }

        // Check encryption status
        if cryptStatus == kCCSuccess {
            // Append the encrypted data to the IV
            cipherData.append(buffer, length: numBytesEncrypted)

            // Return as base64 string
            return cipherData.base64EncodedString()
        } else {
            Debug.shared.log(message: "AES encryption failed with error: \(cryptStatus)", type: .error)
            return nil
        }
    }

    // ... rest of the code remains unchanged ...
}
