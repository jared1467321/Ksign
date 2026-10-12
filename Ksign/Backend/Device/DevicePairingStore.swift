import Foundation
import Security

struct DeviceSetupError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
    init(_ message: String) { self.message = message }
}

struct DevicePairingRecord: Codable {
    let pairing_plist: String
    let host_alt_irk: [UInt8]
    let device_udid: String
    let device_name: String

    var pairingData: Data { Data(pairing_plist.utf8) }

    func validate() throws {
        let value = try PropertyListSerialization.propertyList(from: pairingData, format: nil) as? [String: Any]
        guard let value, (value["private_key"] as? Data)?.count == 32,
              (value["public_key"] as? Data)?.count == 32,
              !(value["identifier"] as? String ?? "").isEmpty,
              host_alt_irk.count == 16, !device_udid.isEmpty else {
            throw DeviceSetupError("The saved pairing is incomplete. Pair this device again.")
        }
    }
}

enum DevicePairingStore {
    private static var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: (Bundle.main.bundleIdentifier ?? "Ksign") + ".device-pairing",
         kSecAttrAccount as String: "local-device-v1"]
    }

    static func load() throws -> DevicePairingRecord? {
        var query = Self.query
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        try check(status)
        guard let data = result as? Data else { throw DeviceSetupError("Cannot read saved pairing.") }
        let record = try JSONDecoder().decode(DevicePairingRecord.self, from: data)
        try record.validate()
        return record
    }

    static func save(_ record: DevicePairingRecord) throws {
        try record.validate()
        let values: [String: Any] = [
            kSecValueData as String: try JSONEncoder().encode(record),
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        ]
        let status = SecItemUpdate(query as CFDictionary, values as CFDictionary)
        if status == errSecItemNotFound {
            try check(SecItemAdd(query.merging(values) { _, new in new } as CFDictionary, nil))
        } else { try check(status) }
    }

    // The native reader currently takes a path. Keep its working copy outside
    // Documents, exclude it from backups, and remove it when the connection ends.
    static func materialize(_ record: DevicePairingRecord) throws -> URL {
        try record.validate()
        var directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("DeviceConnection", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                               attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication])
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try directory.setResourceValues(values)
        let url = directory.appendingPathComponent("pairing.plist")
        try record.pairingData.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        return url
    }

    static func removeWorkingCopy() {
        let url = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("DeviceConnection/pairing.plist")
        try? FileManager.default.removeItem(at: url)
    }

    static func reset() throws {
        let status = SecItemDelete(query as CFDictionary)
        if status != errSecItemNotFound { try check(status) }
        removeWorkingCopy()
    }

    private static func check(_ status: OSStatus) throws {
        guard status == errSecSuccess else {
            throw DeviceSetupError("Cannot access the saved device pairing (Keychain error \(status)). Unlock the device and try again.")
        }
    }
}
