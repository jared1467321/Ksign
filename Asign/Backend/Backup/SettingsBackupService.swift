import CoreData
import Foundation
import NimbleExtensions

@MainActor
enum SettingsBackupService {
    static func snapshot(storage: Storage = .shared, defaults: UserDefaults = .standard,
                         domainName: String = Bundle.main.bundleIdentifier ?? "Ksign") async throws -> SettingsBackup {
        if storage.context.hasChanges { try storage.context.save() }
        let worker = storage.container.newBackgroundContext()
        return try await worker.perform {
            try makeSnapshot(context: worker, storage: storage, defaults: defaults, domainName: domainName)
        }
    }

    nonisolated private static func makeSnapshot(context: NSManagedObjectContext, storage: Storage,
                                                defaults: UserDefaults, domainName: String) throws -> SettingsBackup {
        let request: NSFetchRequest<CertificatePair> = CertificatePair.fetchRequest()
        request.sortDescriptors = [NSSortDescriptor(key: "date", ascending: false)]
        let pairs = try context.fetch(request)
        let certificates = try pairs.map { pair -> SettingsBackup.Certificate in
            guard let id = pair.uuid else { throw BackupError.invalidContents }
            let p12 = try certificateData(pair, type: .certificate, storage: storage)
            let provision = try certificateData(pair, type: .provision, storage: storage)
            return .init(id: id, date: pair.date ?? Date(), expiration: pair.expiration ?? Date(),
                         nickname: pair.nickname, password: pair.password, ppq: pair.ppQCheck,
                         revoked: pair.revoked, p12: p12, provision: provision)
        }
        let sourceRequest: NSFetchRequest<AltSource> = AltSource.fetchRequest()
        let sources = try context.fetch(sourceRequest).map { source -> SettingsBackup.Source in
            guard let identifier = source.identifier, let url = source.sourceURL else { throw BackupError.invalidContents }
            return .init(identifier: identifier, date: source.date ?? Date(), name: source.name,
                         url: url, iconURL: source.iconURL, isBuiltIn: source.isBuiltIn)
        }
        let domain = defaults.persistentDomain(forName: domainName) ?? [:]
        var preferences = domain.filter { SettingsBackup.includesPreference($0.key) }
        // Container URLs cannot survive a reinstall. Keep portable signing options.
        if let data = preferences["signing_options"] as? Data {
            var options = try JSONDecoder().decode(Options.self, from: data)
            options.appEntitlementsFile = nil
            options.injectionFiles = []
            options.defaultInjectionDylibs = nil
            preferences["signing_options"] = try JSONEncoder().encode(options)
        }
        let selected = defaults.integer(forKey: "feather.selectedCert")
        let backup = SettingsBackup(preferences: try PropertyListSerialization.data(fromPropertyList: preferences, format: .binary, options: 0),
            certificates: certificates, selectedCertificateID: pairs.indices.contains(selected) ? pairs[selected].uuid : nil, sources: sources)
        try backup.validate()
        return backup
    }

    nonisolated private static func certificateData(_ pair: CertificatePair, type: Storage.FileRequest, storage: Storage) throws -> Data {
        let embedded = type == .certificate ? pair.p12Data : pair.provisionData
        if let embedded, !embedded.isEmpty { return embedded }
        guard let url = storage.getFile(type, from: pair), FileManager.default.fileExists(atPath: url.path) else {
            throw BackupError.missingCertificate(pair.nickname ?? pair.uuid ?? "Unknown")
        }
        return try Data(contentsOf: url)
    }

    /// Stage files and save database records before applying preferences. A failed
    /// database save rolls back only this restore and removes its newly staged files.
    static func restore(_ backup: SettingsBackup, storage: Storage = .shared, defaults: UserDefaults = .standard,
                        domainName: String = Bundle.main.bundleIdentifier ?? "Ksign") async throws {
        let context = storage.context
        if context.hasChanges { try context.save() }
        let worker = storage.container.newBackgroundContext()
        let restored = try await worker.perform {
            try restoreRecords(backup, context: worker, storage: storage)
        }
        NSManagedObjectContext.mergeChanges(fromRemoteContextSave:
            [NSInsertedObjectsKey: restored.insertedIDs], into: [context])
        if let domain = defaults.persistentDomain(forName: domainName) {
            for key in domain.keys where SettingsBackup.includesPreference(key) { defaults.removeObject(forKey: key) }
        }
        for (key, value) in restored.preferences { defaults.set(value, forKey: key) }
        defaults.set(restored.selectedIndex, forKey: "feather.selectedCert")
        NBThemeManager.shared.reloadFromDefaults()
        OptionsManager.shared.reloadFromDefaults()
        VPNReconnectCoordinator.shared.disable()
        if let raw = defaults.string(forKey: "Ksign.deviceConnectionMode"), let mode = DeviceConnectionMode(rawValue: raw) {
            DeviceInstallationManager.shared.mode = mode
        }
        HalloweenAppearance.apply(refreshExistingViews: true)
    }

    private struct RestoredRecords {
        let preferences: [String: Any]
        let selectedIndex: Int
        let insertedIDs: [NSManagedObjectID]
    }

    /// The private context owns every record used for matching and staging. A
    /// failed save cannot roll back unrelated edits in the UI's view context.
    nonisolated private static func restoreRecords(_ backup: SettingsBackup, context: NSManagedObjectContext,
                                                   storage: Storage) throws -> RestoredRecords {
        try backup.validate()
        let preferences = try backup.preferenceValues()
        if let data = preferences["Ksign.themeProfiles.v1"] as? Data {
            _ = try JSONDecoder().decode([NBThemeProfile].self, from: data)
        }
        var portablePreferences = preferences
        if let data = preferences["signing_options"] as? Data {
            var options = try JSONDecoder().decode(Options.self, from: data)
            options.appEntitlementsFile = nil
            options.injectionFiles = []
            options.defaultInjectionDylibs = nil
            portablePreferences["signing_options"] = try JSONEncoder().encode(options)
        }
        let fileManager = FileManager.default
        var createdDirectories: [URL] = []
        var selectedID: String?
        var selectedIndex = 0
        do {
            let certificateRequest: NSFetchRequest<CertificatePair> = CertificatePair.fetchRequest()
            var existing = try context.fetch(certificateRequest)
            // Read each existing certificate once, rather than once per restored record.
            var existingData: [NSManagedObjectID: (Data?, Data?)] = [:]
            for pair in existing {
                existingData[pair.objectID] = (try? certificateData(pair, type: .certificate, storage: storage),
                                              try? certificateData(pair, type: .provision, storage: storage))
            }
            for record in backup.certificates {
                let match = existing.first { pair in
                    existingData[pair.objectID]?.0 == record.p12 &&
                        existingData[pair.objectID]?.1 == record.provision &&
                        pair.password == record.password && pair.nickname == record.nickname
                }
                if let match {
                    if record.id == backup.selectedCertificateID { selectedID = match.uuid }
                    continue
                }
                let id = UUID().uuidString
                let directory = fileManager.certificates(id)
                try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
                createdDirectories.append(directory)
                try record.p12.write(to: directory.appendingPathComponent("certificate.p12"), options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
                try record.provision.write(to: directory.appendingPathComponent("profile.mobileprovision"), options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
                let pair = CertificatePair(context: context)
                pair.uuid = id
                pair.date = record.date
                pair.expiration = record.expiration
                pair.nickname = record.nickname
                pair.password = record.password
                pair.ppQCheck = record.ppq
                pair.revoked = record.revoked
                existingData[pair.objectID] = (record.p12, record.provision)
                existing.append(pair)
                if record.id == backup.selectedCertificateID { selectedID = id }
            }
            let sourceRequest: NSFetchRequest<AltSource> = AltSource.fetchRequest()
            var existingSources = try context.fetch(sourceRequest)
            for record in backup.sources where !existingSources.contains(where: { $0.identifier == record.identifier || $0.sourceURL == record.url }) {
                let source = AltSource(context: context)
                source.identifier = record.identifier
                source.date = record.date
                source.name = record.name
                source.sourceURL = record.url
                source.iconURL = record.iconURL
                source.isBuiltIn = record.isBuiltIn
                existingSources.append(source)
            }
            certificateRequest.sortDescriptors = [NSSortDescriptor(key: "date", ascending: false)]
            let pairs = try context.fetch(certificateRequest)
            selectedIndex = pairs.firstIndex(where: { $0.uuid == selectedID }) ?? 0
            let inserted = Array(context.insertedObjects)
            try context.save()
            return RestoredRecords(preferences: portablePreferences, selectedIndex: selectedIndex,
                                   insertedIDs: inserted.map(\.objectID))
        } catch {
            context.rollback()
            for directory in createdDirectories { try? fileManager.removeItem(at: directory) }
            throw error
        }
    }
}
