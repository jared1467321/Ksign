import Foundation
#if os(iOS)
import ObjectiveC
#endif

public enum IDeviceInstalledAppDates {
    /// LaunchServices records the latest registration of an installed copy.
    /// Updates/reinstalls may change it. Never substitute a build timestamp,
    /// first-seen time, or a library-file date for a missing device date.
    public static func registrationDate(for bundleIdentifier: String) -> Date? {
        #if os(iOS)
        let lookup = NSSelectorFromString("applicationProxyForIdentifier:")
        let registeredDate = NSSelectorFromString("registeredDate")
        guard let proxyClass = NSClassFromString("LSApplicationProxy") as? NSObject.Type,
              class_getClassMethod(proxyClass, lookup) != nil,
              let proxy = proxyClass.perform(lookup, with: bundleIdentifier)?.takeUnretainedValue() as? NSObject,
              proxy.responds(to: registeredDate),
              let date = proxy.perform(registeredDate)?.takeUnretainedValue() as? Date,
              date.timeIntervalSince1970.isFinite, date.timeIntervalSince1970 > 0 else { return nil }
        return date
        #else
        return nil
        #endif
    }
}
