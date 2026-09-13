import Foundation
import ZsignC

public enum Zsign {
    public static func checkSigned(appExecutable: String) -> Bool {
        CheckIfSigned(appExecutable)
    }

    public static func injectDyLib(appExecutable: String, with path: String, weak: Bool = true) -> Bool {
        InjectDyLib(appExecutable, path, weak)
    }

    public static func removeDylibs(appExecutable: String, using dylibs: [String]) -> Bool {
        UninstallDylibs(appExecutable, dylibs)
    }

    public static func listDylibs(appExecutable: String) -> [String] {
        ListDylibs(appExecutable)
    }

    public static func changeDylibPath(appExecutable: String, for old: String, with new: String) -> Bool {
        ChangeDylibPath(appExecutable, old, new)
    }

    public static func sign(
        appPath: String = "",
        provisionPath: String = "",
        p12Path: String = "",
        p12Password: String = "",
        entitlementsPath: String = "",
        customIdentifier: String = "",
        customName: String = "",
        customVersion: String = "",
        adhoc: Bool = false,
        removeProvision: Bool = false,
        completion: ((Bool) -> Void)? = nil
    ) -> Bool {
        zsign(
            appPath,
            provisionPath,
            p12Path,
            p12Password,
            entitlementsPath,
            customIdentifier,
            customName,
            customVersion,
            adhoc,
            removeProvision,
            completion.map { callback in
                { success in callback(success) }
            }
        ) == 0
    }

    public static func checkRevokage(
        provisionPath: String = "",
        p12Path: String = "",
        p12Password: String = "",
        completionHandler: @escaping (Int32, Date?, String?) -> Void
    ) {
        checkCert(provisionPath, p12Path, p12Password) { status, expirationDate, error in
            completionHandler(status, expirationDate, error)
        }
    }
}
