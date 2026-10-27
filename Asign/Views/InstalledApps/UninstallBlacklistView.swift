import SwiftUI
import NimbleViews
import NimbleExtensions

struct UninstallBlacklistView: View {
    @ObservedObject private var blacklist = UninstallBlacklist.shared

    private var protectedIDs: [String] {
        blacklist.entries.keys.sorted {
            let comparison = (blacklist.entries[$0] ?? $0).localizedCaseInsensitiveCompare(blacklist.entries[$1] ?? $1)
            return comparison == .orderedSame ? $0 < $1 : comparison == .orderedAscending
        }
    }

    var body: some View {
        NBListAdaptable(rendersAurora: false, adaptsContainerText: false) {
            NBSection("Protected Apps", secondary: protectedIDs.count.description) {
                if protectedIDs.isEmpty {
                    Text("No blacklisted apps.").nbThemeForeground(.textSecondary)
                }
                ForEach(protectedIDs, id: \.self) { id in
                    HStack(spacing: 12) {
                        Image(systemName: "shield.lefthalf.filled")
                            .nbThemeForeground(.accent)
                            .accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(blacklist.entries[id] ?? id).nbThemeForeground(.heading)
                            Text(id).font(.caption).nbThemeForeground(.textSecondary)
                        }
                        Spacer(minLength: 0)
                        Button {
                            blacklist.remove(id)
                        } label: {
                            Image(systemName: "minus.circle")
                                .font(.title3)
                                .nbThemeForeground(.accent)
                                .frame(minWidth: 44, minHeight: 44)
                        }
                        .buttonStyle(.borderless)
                        .accessibilityLabel("Remove \(blacklist.entries[id] ?? id) from Blacklist")
                    }
                }
            } footer: {
                Text("Blacklisted apps are hidden from Installed Apps and cannot be uninstalled through Asign. Long-press an installed app to add it here.")
            }
        }
        .nbThemeNavigationTitle("Blacklisted Apps", displayMode: .inline)
        .onAppear { blacklist.reload() }
    }
}
