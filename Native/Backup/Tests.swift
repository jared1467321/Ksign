import Foundation
#if canImport(CoreData)
import CoreData
#else
// Service doubles for Linux. macOS runs the same restore against real Core Data.
struct BackupSortDescriptor { init(key: String, ascending: Bool) {} }
final class NSFetchRequest<T> { var sortDescriptors: [BackupSortDescriptor]? }
final class NSManagedObjectContext {
    enum ConcurrencyType { case mainQueueConcurrencyType }
    var parent: NSManagedObjectContext?
    var certificates: [CertificatePair] = []
    var sources: [AltSource] = []
    private var savedCertificates: [CertificatePair] = []
    private var savedSources: [AltSource] = []
    var failSave = false
    var hasChanges: Bool { certificates.count != savedCertificates.count || sources.count != savedSources.count }
    init(concurrencyType: ConcurrencyType) {}
    func fetch<T>(_ request: NSFetchRequest<T>) throws -> [T] {
        if T.self == CertificatePair.self {
            var values = (parent?.certificates ?? []) + certificates
            if request.sortDescriptors != nil { values.sort { ($0.date ?? .distantPast) > ($1.date ?? .distantPast) } }
            return values as! [T]
        }
        return ((parent?.sources ?? []) + sources) as! [T]
    }
    func save() throws {
        if failSave { throw BackupError.invalidContents }
        if let parent {
            parent.certificates += certificates
            parent.sources += sources
            certificates = []
            sources = []
        } else {
            savedCertificates = certificates
            savedSources = sources
        }
    }
    func rollback() {
        certificates = savedCertificates
        sources = savedSources
    }
}
#endif

#if canImport(CoreData)
final class BackupTestContext: NSManagedObjectContext {
    var failSave = false
    override func save() throws {
        if failSave { throw BackupError.invalidContents }
        try super.save()
    }
}
@objc(CertificatePair) final class CertificatePair: NSManagedObject {
    @NSManaged var uuid: String?
    @NSManaged var date: Date?
    @NSManaged var expiration: Date?
    @NSManaged var nickname: String?
    @NSManaged var password: String?
    @NSManaged var ppQCheck: Bool
    @NSManaged var revoked: Bool
    @NSManaged var p12Data: Data?
    @NSManaged var provisionData: Data?
    static func fetchRequest() -> NSFetchRequest<CertificatePair> { .init(entityName: "CertificatePair") }
}
@objc(AltSource) final class AltSource: NSManagedObject {
    @NSManaged var identifier: String?
    @NSManaged var date: Date?
    @NSManaged var name: String?
    @NSManaged var sourceURL: URL?
    @NSManaged var iconURL: URL?
    @NSManaged var isBuiltIn: Bool
    static func fetchRequest() -> NSFetchRequest<AltSource> { .init(entityName: "AltSource") }
}
#else
typealias BackupTestContext = NSManagedObjectContext
final class CertificatePair {
    var uuid: String?, nickname: String?, password: String?
    var date: Date?, expiration: Date?
    var ppQCheck = false, revoked = false
    var p12Data: Data?, provisionData: Data?
    init(context: NSManagedObjectContext) { context.certificates.append(self) }
    static func fetchRequest() -> NSFetchRequest<CertificatePair> { .init() }
}
final class AltSource {
    var identifier: String?, name: String?
    var date: Date?
    var sourceURL: URL?, iconURL: URL?
    var isBuiltIn = false
    init(context: NSManagedObjectContext) { context.sources.append(self) }
    static func fetchRequest() -> NSFetchRequest<AltSource> { .init() }
}
#endif

final class Storage {
    static let shared = Storage()
    static var root = FileManager.default.temporaryDirectory.appendingPathComponent("backup-tests-\(UUID().uuidString)")
    static var blockWrites = false
    let context: BackupTestContext
    enum FileRequest: String { case certificate = "p12", provision = "mobileprovision" }
    init() {
#if canImport(CoreData)
        let model = NSManagedObjectModel()
        func entity(_ name: String, type: AnyClass, fields: [(String, NSAttributeType)]) -> NSEntityDescription {
            let entity = NSEntityDescription()
            entity.name = name
            entity.managedObjectClassName = NSStringFromClass(type)
            entity.properties = fields.map { name, type in
                let attribute = NSAttributeDescription()
                attribute.name = name
                attribute.attributeType = type
                attribute.isOptional = true
                if type == .booleanAttributeType { attribute.defaultValue = false }
                return attribute
            }
            return entity
        }
        model.entities = [entity("CertificatePair", type: CertificatePair.self, fields: [
            ("uuid", .stringAttributeType), ("date", .dateAttributeType), ("expiration", .dateAttributeType),
            ("nickname", .stringAttributeType), ("password", .stringAttributeType), ("ppQCheck", .booleanAttributeType),
            ("revoked", .booleanAttributeType), ("p12Data", .binaryDataAttributeType), ("provisionData", .binaryDataAttributeType)
        ]), entity("AltSource", type: AltSource.self, fields: [
            ("identifier", .stringAttributeType), ("date", .dateAttributeType), ("name", .stringAttributeType),
            ("sourceURL", .URIAttributeType), ("iconURL", .URIAttributeType), ("isBuiltIn", .booleanAttributeType)
        ])]
        let coordinator = NSPersistentStoreCoordinator(managedObjectModel: model)
        try! coordinator.addPersistentStore(ofType: NSInMemoryStoreType, configurationName: nil, at: nil)
        context = BackupTestContext(concurrencyType: .mainQueueConcurrencyType)
        context.persistentStoreCoordinator = coordinator
#else
        context = BackupTestContext(concurrencyType: .mainQueueConcurrencyType)
#endif
    }
    func getFile(_ type: FileRequest, from pair: CertificatePair) -> URL? {
        guard let id = pair.uuid else { return nil }
        return FileManager.default.certificates(id).appendingPathComponent(type == .certificate ? "certificate.p12" : "profile.mobileprovision")
    }
}
extension FileManager {
    func certificates(_ id: String) -> URL {
        (Storage.blockWrites ? URL(fileURLWithPath: "/dev/null") : Storage.root).appendingPathComponent(id)
    }
}
struct NBThemeProfile: Codable { let id: String; let name: String }
final class NBThemeManager { static let shared = NBThemeManager(); var reloads = 0; func reloadFromDefaults() { reloads += 1 } }
struct Options: Codable {
    var appEntitlementsFile: URL?
    var injectionFiles: [URL] = []
    var defaultInjectionDylibs: [String]?
}
final class OptionsManager { static let shared = OptionsManager(); func reloadFromDefaults() {} }
final class VPNReconnectCoordinator { static let shared = VPNReconnectCoordinator(); func disable() {} }
enum DeviceConnectionMode: String { case builtIn, manual }
final class DeviceInstallationManager { static let shared = DeviceInstallationManager(); var mode = DeviceConnectionMode.manual }
enum HalloweenAppearance { static func apply(refreshExistingViews: Bool) {} }

@main struct BackupTests {
    static func expect(_ value: Bool, _ message: String) { precondition(value, message) }
    static func rejected(_ message: String, _ body: () throws -> Void) {
        do { try body() } catch { return }
        preconditionFailure(message)
    }
    @MainActor static func main() throws {
        let domain = "BackupTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: domain)!
        defer { defaults.removePersistentDomain(forName: domain); try? FileManager.default.removeItem(at: Storage.root) }
        let source = Storage()
        let pair = CertificatePair(context: source.context)
        pair.uuid = UUID().uuidString
        pair.date = Date(timeIntervalSince1970: 100)
        pair.expiration = Date(timeIntervalSince1970: 500)
        pair.nickname = "My certificate"
        pair.password = "certificate-secret"
        pair.p12Data = Data([1, 2, 3])
        pair.provisionData = Data([4, 5, 6])
        let subscription = AltSource(context: source.context)
        subscription.identifier = "my-source"
        subscription.sourceURL = URL(string: "https://example.com/apps.json")!
        subscription.date = Date(timeIntervalSince1970: 200)
        let theme = try JSONEncoder().encode([NBThemeProfile(id: "custom", name: "My theme")])
        defaults.setPersistentDomain([
            "Ksign.themeProfiles.v1": theme, "Ksign.selectedThemeProfile.v1": "custom",
            "Feather.installationMethod": 1, "Ksign.pendingVPNReconnectID": "stale",
            "Feather.exportBookmark": Data([9]), "signing_options": try JSONEncoder().encode(Options(
                appEntitlementsFile: URL(fileURLWithPath: "/old-container/entitlements.plist"),
                injectionFiles: [URL(fileURLWithPath: "/old-container/tweak.dylib")], defaultInjectionDylibs: ["tweak.dylib"]))
        ], forName: domain)
        let backup = try SettingsBackupService.snapshot(storage: source, defaults: defaults, domainName: domain)
        let decoded = try SettingsBackup.decode(backup.encoded())
        expect(decoded.certificates.first?.password == "certificate-secret", "Certificate passwords must round-trip")
        expect(try decoded.preferenceValues()["Ksign.themeProfiles.v1"] as? Data == theme, "Theme bytes must round-trip")
        expect(try decoded.preferenceValues()["Ksign.pendingVPNReconnectID"] == nil, "Do not restore stale reconnect requests")
        expect(try decoded.preferenceValues()["Feather.exportBookmark"] == nil, "Do not carry container bookmarks across installs")
        let optionsData = try decoded.preferenceValues()["signing_options"] as! Data
        let options = try JSONDecoder().decode(Options.self, from: optionsData)
        expect(options.appEntitlementsFile == nil && options.injectionFiles.isEmpty && options.defaultInjectionDylibs == nil,
               "Strip references to files outside this backup")

        var invalid = decoded
        invalid.version = 99
        rejected("Reject future formats") { _ = try invalid.encoded() }
        invalid = decoded
        invalid.certificates.append(decoded.certificates[0])
        rejected("Reject duplicate certificate IDs") { _ = try invalid.encoded() }
        invalid = decoded
        invalid.selectedCertificateID = UUID().uuidString
        rejected("Reject an unknown selected certificate") { _ = try invalid.encoded() }
        invalid = decoded
        invalid.preferences = try PropertyListSerialization.data(fromPropertyList: ["Ksign.pendingVPNReconnectID": "stale"], format: .binary, options: 0)
        rejected("Reject transient preferences in imported backups") { _ = try invalid.encoded() }

        let target = Storage()
        let retained = CertificatePair(context: target.context)
        retained.uuid = UUID().uuidString
        retained.date = Date(timeIntervalSince1970: 300)
        retained.p12Data = Data([7])
        retained.provisionData = Data([8])
        try target.context.save()
        defaults.setPersistentDomain(["Ksign.selectedThemeProfile.v1": "original", "Ksign.pendingVPNReconnectID": "keep"], forName: domain)
        Storage.blockWrites = true
        rejected("File failures must abort restore") { try SettingsBackupService.restore(decoded, storage: target, defaults: defaults, domainName: domain) }
        Storage.blockWrites = false
        expect(defaults.string(forKey: "Ksign.selectedThemeProfile.v1") == "original", "Failed restore must not apply preferences")
        expect(try target.context.fetch(CertificatePair.fetchRequest()).count == 1, "Failed restore must retain the existing database")

        target.context.failSave = true
        rejected("Database failure must abort restore") {
            try SettingsBackupService.restore(decoded, storage: target, defaults: defaults, domainName: domain)
        }
        target.context.failSave = false
        expect(try target.context.fetch(CertificatePair.fetchRequest()).count == 1, "Failed save must roll back the inserted records")
        expect(defaults.string(forKey: "Ksign.selectedThemeProfile.v1") == "original", "Failed save must not change settings")
        let staged = (try? FileManager.default.contentsOfDirectory(at: Storage.root, includingPropertiesForKeys: nil)) ?? []
        expect(staged.isEmpty, "Failed save must remove the new certificate directories")

        try SettingsBackupService.restore(decoded, storage: target, defaults: defaults, domainName: domain)
        let restored = try target.context.fetch(CertificatePair.fetchRequest())
        expect(restored.count == 2, "Restore must retain existing certificates and add missing ones")
        let imported = restored.first { $0.nickname == "My certificate" }!
        expect(imported.uuid != pair.uuid, "Restore must use a fresh directory ID")
        expect(try Data(contentsOf: target.getFile(.certificate, from: imported)!) == decoded.certificates[0].p12, "Restore must materialize certificate files")
        expect(defaults.string(forKey: "Ksign.selectedThemeProfile.v1") == "custom" && NBThemeManager.shared.reloads > 0, "Apply the theme immediately")
        expect(defaults.integer(forKey: "feather.selectedCert") == 1, "Remap certificate selection after merging with newer certificates")
        try SettingsBackupService.restore(decoded, storage: target, defaults: defaults, domainName: domain)
        expect(try target.context.fetch(CertificatePair.fetchRequest()).count == 2, "Repeated restore must not duplicate certificates")
        expect(try target.context.fetch(AltSource.fetchRequest()).count == 1, "Repeated restore must not duplicate sources")

#if canImport(CryptoKit) && canImport(CommonCrypto)
        let encrypted = try SettingsBackupCrypto.encrypt(decoded, password: "backup-🔐-password")
        let restoredPayload = try SettingsBackupCrypto.decrypt(encrypted, password: "backup-🔐-password")
        expect(restoredPayload.certificates[0].password == "certificate-secret", "Authenticated encrypted round-trip")
        rejected("Wrong password must fail") { _ = try SettingsBackupCrypto.decrypt(encrypted, password: "wrong-password") }
        rejected("Short backup passwords must fail") { _ = try SettingsBackupCrypto.encrypt(decoded, password: "short") }
        var envelope = try PropertyListSerialization.propertyList(from: encrypted, format: nil) as! [String: Any]
        var sealed = envelope["sealed"] as! Data
        sealed[sealed.count - 1] ^= 1
        envelope["sealed"] = sealed
        let corrupted = try PropertyListSerialization.data(fromPropertyList: envelope, format: .binary, options: 0)
        rejected("Tampered authentication tag must fail") { _ = try SettingsBackupCrypto.decrypt(corrupted, password: "backup-🔐-password") }
        envelope["rounds"] = 4_000_000_000
        let invalidEnvelope = try PropertyListSerialization.data(fromPropertyList: envelope, format: .binary, options: 0)
        rejected("Reject unsupported key derivation parameters before doing expensive work") {
            _ = try SettingsBackupCrypto.decrypt(invalidEnvelope, password: "backup-🔐-password")
        }
        print("Passed encrypted backup, wrong-password and tampering scenarios")
#else
        print("Encryption tests require macOS CryptoKit/CommonCrypto and run on the build runner")
#endif
        print("Passed backup round-trip, preference filtering, restore rollback, file restoration, selection and duplicate scenarios")
    }
}
