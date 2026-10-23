import Foundation

/// Portable records rather than a copy of the live Core Data database or app container.
struct SettingsBackup: Codable, Sendable {
    static let currentVersion = 1
    static let maximumFileSize = 128 * 1024 * 1024

    var version = currentVersion
    var createdAt = Date()
    var preferences: Data
    var certificates: [Certificate]
    var selectedCertificateID: String?
    var sources: [Source]

    struct Certificate: Codable, Sendable {
        let id: String
        let date: Date
        let expiration: Date
        let nickname: String?
        let password: String?
        let ppq: Bool
        let revoked: Bool
        let p12: Data
        let provision: Data
    }

    struct Source: Codable, Sendable {
        let identifier: String
        let date: Date
        let name: String?
        let url: URL
        let iconURL: URL?
        let isBuiltIn: Bool
    }

    func validate() throws {
        guard version == Self.currentVersion else { throw BackupError.unsupportedVersion }
        guard certificates.count <= 500, sources.count <= 1_000,
              Set(certificates.map(\.id)).count == certificates.count,
              certificates.allSatisfy({ UUID(uuidString: $0.id) != nil && !$0.p12.isEmpty && !$0.provision.isEmpty }),
              Set(sources.map(\.identifier)).count == sources.count,
              sources.allSatisfy({ !$0.identifier.isEmpty && ["https", "http"].contains($0.url.scheme?.lowercased() ?? "") }),
              selectedCertificateID == nil || certificates.contains(where: { $0.id == selectedCertificateID }) else {
            throw BackupError.invalidContents
        }
        _ = try preferenceValues()
    }

    func preferenceValues() throws -> [String: Any] {
        guard let values = try PropertyListSerialization.propertyList(from: preferences, format: nil) as? [String: Any],
              values.count <= 10_000, values.keys.allSatisfy(Self.includesPreference) else {
            throw BackupError.invalidContents
        }
        return values
    }

    static func includesPreference(_ key: String) -> Bool {
        // Keep legacy preference keys so existing installations and backups remain compatible.
        let portable = key.hasPrefix("Feather.") || key.hasPrefix("feather.") || key.hasPrefix("Ksign.") || key == "signing_options"
        let excluded = key.hasPrefix("Ksign.pendingVPNReconnect") || key == "Ksign.needsFreshBuiltInPairing" ||
            key == "feather.selectedCert" || key.lowercased().contains("bookmark")
        return portable && !excluded
    }

    func encoded() throws -> Data {
        try validate()
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .binary
        let data = try encoder.encode(self)
        guard data.count <= Self.maximumFileSize else { throw BackupError.tooLarge }
        return data
    }

    static func decode(_ data: Data) throws -> Self {
        guard data.count <= maximumFileSize else { throw BackupError.tooLarge }
        let backup = try PropertyListDecoder().decode(Self.self, from: data)
        try backup.validate()
        return backup
    }
}

enum BackupError: LocalizedError {
    case unsupportedVersion, invalidContents, tooLarge, passwordTooShort, encryptionFailed, incorrectPassword
    case missingCertificate(String)

    var errorDescription: String? {
        switch self {
        case .unsupportedVersion: return "This backup requires a different version of Asign."
        case .invalidContents: return "This is not a valid Asign settings backup."
        case .tooLarge: return "The backup exceeds the 128 MB limit."
        case .passwordTooShort: return "Use a backup password with at least 8 characters."
        case .encryptionFailed: return "Could not protect the backup. Try again."
        case .incorrectPassword: return "The password is incorrect or the backup is damaged."
        case .missingCertificate(let name): return "The files for certificate \(name) are missing. Import that certificate again before backing up."
        }
    }
}
