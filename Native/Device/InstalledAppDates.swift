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
        guard let date = applicationProperty("registeredDate", for: bundleIdentifier) as? Date,
              date.timeIntervalSince1970.isFinite, date.timeIntervalSince1970 > 0 else { return nil }
        return date
        #else
        return nil
        #endif
    }

    public static func installationPath(for bundleIdentifier: String) -> String? {
        #if os(iOS)
        guard let url = applicationProperty("bundleURL", for: bundleIdentifier) as? URL,
              url.isFileURL, !url.path.isEmpty else { return nil }
        return url.path
        #else
        return nil
        #endif
    }

    #if os(iOS)
    private static func applicationProperty(_ name: String, for bundleIdentifier: String) -> AnyObject? {
        let lookup = NSSelectorFromString("applicationProxyForIdentifier:")
        let selector = NSSelectorFromString(name)
        guard let proxyClass = NSClassFromString("LSApplicationProxy") as? NSObject.Type,
              class_getClassMethod(proxyClass, lookup) != nil,
              let proxy = proxyClass.perform(lookup, with: bundleIdentifier)?.takeUnretainedValue() as? NSObject,
              proxy.responds(to: selector) else { return nil }
        return proxy.perform(selector)?.takeUnretainedValue()
    }
    #endif

}
