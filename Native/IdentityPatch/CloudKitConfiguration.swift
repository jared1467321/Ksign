import SwiftData

/// Called only for an originally cloud-enabled app whose installed signature
/// has no usable CloudKit container. Explicit .none configurations never pass
/// through the .automatic getter and are left alone.
@_cdecl("AsignInitializeLocalCloudConfiguration")
func initializeLocalCloudConfiguration(_ destination: UnsafeMutableRawPointer,
                                       _ identifier: UnsafePointer<CChar>) -> Bool {
    if #available(iOS 17, macOS 14, tvOS 17, watchOS 10, *) {
        destination.assumingMemoryBound(to: ModelConfiguration.CloudKitDatabase.self)
            .initialize(to: .private(String(cString: identifier)))
        return true
    }
    return false
}
