import Foundation
import IDeviceSwift

struct DeviceUninstallSelection: Identifiable {
    let id = UUID()
    let apps: [IDeviceInstalledApp]

    init(apps: [IDeviceInstalledApp]) {
        var seen: Set<String> = []
        self.apps = apps.filter { seen.insert($0.id).inserted }
    }
}
