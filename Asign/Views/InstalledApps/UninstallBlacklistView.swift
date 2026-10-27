import SwiftUI
import IDeviceSwift
import NimbleViews
import NimbleExtensions

struct UninstallBlacklistView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var model: InstalledAppsModel
    @ObservedObject private var blacklist = UninstallBlacklist.shared

    private var protectedIDs: [String] {
        blacklist.entries.keys.sorted {
            let comparison = (blacklist.entries[$0] ?? $0).localizedCaseInsensitiveCompare(blacklist.entries[$1] ?? $1)
            return comparison == .orderedSame ? $0 < $1 : comparison == .orderedAscending
        }
    }

    private var availableApps: [IDeviceInstalledApp] {
        model.apps.filter { !blacklist.contains($0.id) }
    }

    var body: some View {
        NBNavigationView("Uninstall Blacklist", adaptsContainerText: false) {
            NBListAdaptable(rendersAurora: false, adaptsContainerText: false) {
                NBSection("Protected Apps", secondary: protectedIDs.count.description) {
                    Text("Blacklisted apps are hidden from the uninstall list and cannot be uninstalled through Asign. Protection is saved after refreshing or restarting Asign.")
                        .font(.callout).nbThemeForeground(.textSecondary)
                    if protectedIDs.isEmpty {
                        Text("No apps are blacklisted yet.").nbThemeForeground(.textSecondary)
                    }
                    ForEach(protectedIDs, id: \.self) { id in
                        VStack(alignment: .leading, spacing: 6) {
                            Text(blacklist.entries[id] ?? id).nbThemeForeground(.heading)
                            Text(id).font(.caption).nbThemeForeground(.textSecondary)
                            Button("Remove from Blacklist", systemImage: "shield.slash") {
                                blacklist.remove(id)
                            }
                            .buttonStyle(.borderless)
                        }
                    }
                }
                NBSection("Add Apps") {
                    if !model.hasLoaded {
                        Text("Load Installed Apps, then return here to choose apps to protect.")
                            .nbThemeForeground(.textSecondary)
                    } else if availableApps.isEmpty {
                        Text("No more loaded apps to add.").nbThemeForeground(.textSecondary)
                    }
                    ForEach(availableApps) { app in
                        Button {
                            blacklist.add(app)
                        } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(app.name).nbThemeForeground(.heading)
                                    Text(app.id).font(.caption).nbThemeForeground(.textSecondary)
                                }
                                Spacer()
                                Image(systemName: "plus.shield").nbThemeForeground(.accent)
                            }
                        }
                        .accessibilityLabel("Add \(app.name) to Blacklist")
                    }
                }
            }
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .onAppear { blacklist.reload() }
    }
}
