#if canImport(CryptoKit) && canImport(CommonCrypto)
import Foundation
import CryptoKit
import CommonCrypto
import Security

enum SettingsBackupCrypto {
    private static let rounds: UInt32 = 210_000
    private static let authentication = Data("ASignBackup-v1".utf8)

    private struct Envelope: Codable {
        let format: String
        let version: Int
        let rounds: UInt32
        let salt: Data
        let sealed: Data
    }

    static func encrypt(_ backup: SettingsBackup, password: String) throws -> Data {
        guard password.count >= 8 else { throw BackupError.passwordTooShort }
        let plaintext = try backup.encoded()
        var salt = Data(count: 16)
        let status = salt.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, $0.count, $0.baseAddress!) }
        guard status == errSecSuccess else { throw BackupError.encryptionFailed }
        let key = try deriveKey(password: password, salt: salt)
        guard let sealed = try AES.GCM.seal(plaintext, using: key, authenticating: authentication).combined else {
            throw BackupError.encryptionFailed
        }
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .binary
        let data = try encoder.encode(Envelope(format: "ASignBackup", version: 1, rounds: rounds, salt: salt, sealed: sealed))
        guard data.count <= SettingsBackup.maximumFileSize else { throw BackupError.tooLarge }
        return data
    }

    static func decrypt(_ data: Data, password: String) throws -> SettingsBackup {
        guard data.count <= SettingsBackup.maximumFileSize else { throw BackupError.tooLarge }
        let envelope: Envelope
        do { envelope = try PropertyListDecoder().decode(Envelope.self, from: data) }
        catch { throw BackupError.invalidContents }
        guard envelope.format == "ASignBackup" else { throw BackupError.invalidContents }
        guard envelope.version == 1 else { throw BackupError.unsupportedVersion }
        guard envelope.rounds == rounds, envelope.salt.count == 16, envelope.sealed.count >= 28 else {
            throw BackupError.invalidContents
        }
        let key = try deriveKey(password: password, salt: envelope.salt)
        let plaintext: Data
        do {
            plaintext = try AES.GCM.open(AES.GCM.SealedBox(combined: envelope.sealed), using: key, authenticating: authentication)
        } catch { throw BackupError.incorrectPassword }
        return try SettingsBackup.decode(plaintext)
    }

    private static func deriveKey(password: String, salt: Data) throws -> SymmetricKey {
        let bytes = Array(password.utf8)
        var key = Data(count: 32)
        let status = key.withUnsafeMutableBytes { output in
            salt.withUnsafeBytes { saltBytes in
                bytes.withUnsafeBytes { passwordBytes in
                    CCKeyDerivationPBKDF(CCPBKDFAlgorithm(kCCPBKDF2),
                        passwordBytes.bindMemory(to: Int8.self).baseAddress, bytes.count,
                        saltBytes.bindMemory(to: UInt8.self).baseAddress, salt.count,
                        CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256), rounds,
                        output.bindMemory(to: UInt8.self).baseAddress, output.count)
                }
            }
        }
        guard status == kCCSuccess else { throw BackupError.encryptionFailed }
        return SymmetricKey(data: key)
    }
}
#endif
