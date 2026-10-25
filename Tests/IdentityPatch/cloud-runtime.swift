import CloudKit
import Foundation
import SQLite3
import SwiftData

enum ProbeFailure: Error { case failed(String) }
func check(_ condition: @autoclosure () -> Bool, _ message: String) throws {
    if !condition() { throw ProbeFailure.failed(message) }
}

@available(macOS 14, *)
final class Delegate: CKSyncEngineDelegate {
    func handleEvent(_ event: CKSyncEngine.Event, syncEngine: CKSyncEngine) async {}
    func nextRecordZoneChangeBatch(_ context: CKSyncEngine.SendChangesContext,
                                   syncEngine: CKSyncEngine) async -> CKSyncEngine.RecordZoneChangeBatch? { nil }
}

@main
struct CloudRuntimeProbe {
    @available(macOS 14, *)
    static func main() async throws {
        // Match SQLiteData's discovery path. The host has an explicitly empty
        // CloudKit signature; only the original app snapshot supplies this ID.
        let configuration = ModelConfiguration(groupContainer: .none)
        let identifier = configuration.cloudKitContainerIdentifier
        try check(identifier == "iCloud.org.example.original", "Automatic CloudKit discovery did not preserve local startup")
        let explicitlyLocal = ModelConfiguration(groupContainer: .none, cloudKitDatabase: .none)
        try check(explicitlyLocal.cloudKitContainerIdentifier == nil, "An explicit local configuration was changed")

        let container = CKContainer(identifier: identifier!)
        try check(container.containerIdentifier == identifier, "Container identity changed")
        try check(CKContainer.default().containerIdentifier == identifier, "Default container discovery failed")
        let status = try await container.accountStatus()
        try check(status == .restricted, "Unavailable container advertised a usable cloud account")

        let delegate = Delegate()
        var syncConfiguration = CKSyncEngine.Configuration(database: container.privateCloudDatabase,
                                                           stateSerialization: nil, delegate: delegate)
        syncConfiguration.automaticallySync = false
        let sync = CKSyncEngine(syncConfiguration)
        try check(container.privateCloudDatabase.databaseScope == .private, "Private database was invalid")
        try check(container.sharedCloudDatabase.databaseScope == .shared, "Shared database was invalid")

        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("local.sqlite").path
        var database: OpaquePointer?
        try check(sqlite3_open(path, &database) == SQLITE_OK, "Cannot open local database")
        try check(sqlite3_exec(database, "CREATE TABLE records (value TEXT); INSERT INTO records VALUES ('retained');",
                              nil, nil, nil) == SQLITE_OK, "Cannot write local database")
        sqlite3_close(database)

        do {
            _ = try await container.userRecordID()
            throw ProbeFailure.failed("A cloud request incorrectly reported success")
        } catch let error as CKError {
            try check(error.code == .notAuthenticated, "Unexpected unavailable-cloud error")
        }

        // Exercise a real CKDatabase operation. Dropping it would hang this
        // continuation; the parent runner enforces a timeout for the probe.
        do {
            _ = try await container.privateCloudDatabase.record(for: CKRecord.ID(recordName: "local-probe"))
            throw ProbeFailure.failed("A local cloud operation incorrectly reported success")
        } catch let error as CKError {
            try check(error.code == .operationCancelled, "Cloud operation was not cancelled before execution")
        }
        await sync.cancelOperations()

        try check(sqlite3_open(path, &database) == SQLITE_OK, "Cannot reopen local database")
        var statement: OpaquePointer?
        try check(sqlite3_prepare_v2(database, "SELECT value FROM records", -1, &statement, nil) == SQLITE_OK,
                  "Cannot read retained local data")
        try check(sqlite3_step(statement) == SQLITE_ROW, "Local record disappeared")
        let value = String(cString: sqlite3_column_text(statement, 0))
        sqlite3_finalize(statement)
        sqlite3_close(database)
        try check(value == "retained", "Local database content changed")
        print("Real SwiftData discovery, CKContainer, CKSyncEngine initialization, async cancellation and local persistence passed")
    }
}
