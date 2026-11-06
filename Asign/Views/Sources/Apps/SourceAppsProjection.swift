import Foundation
import AltSourceKit

/// Immutable catalog input/output. Filtering and date parsing never run in table callbacks.
enum SourceAppsProjection {
    typealias Entry = (source: ASRepository, app: ASRepository.App)

    struct Request {
        let sources: [ASRepository]
        let searchText: String
        let sortOption: SourceAppsView.SortOption
        let ascending: Bool
        let generation: UUID
    }

    struct Snapshot {
        var apps: [Entry] = []
        var groups: [String: [Entry]] = [:]
        var titles: [String] = []
    }

    static func build(_ request: Request) -> Snapshot {
        let query = request.searchText
        let filtered: [Entry] = request.sources.flatMap { source in
            source.apps.compactMap { app in
                guard query.isEmpty || [app.name, app.description, app.subtitle, app.localizedDescription]
                    .contains(where: { $0?.localizedCaseInsensitiveContains(query) == true }) else { return nil }
                return (source: source, app: app)
            }
        }
        switch request.sortOption {
        case .default:
            return Snapshot(apps: request.ascending ? filtered : filtered.reversed())
        case .name:
            let sorted = filtered.sorted {
                let comparison = ($0.app.name ?? "").localizedCaseInsensitiveCompare($1.app.name ?? "")
                return comparison == (request.ascending ? .orderedAscending : .orderedDescending)
            }
            let grouped = Dictionary(grouping: sorted) { entry in
                let first = entry.app.name?.trimmingCharacters(in: .whitespacesAndNewlines).first?.uppercased() ?? "#"
                return first.range(of: "[A-Z]", options: .regularExpression) != nil ? first : "#"
            }
            let titles = grouped.keys.sorted {
                if $0 == "#" { return false }
                if $1 == "#" { return true }
                return request.ascending ? $0 < $1 : $0 > $1
            }
            return Snapshot(apps: sorted, groups: grouped, titles: titles)
        case .date:
            // Resolve each app's date once before sorting and grouping.
            let dated = filtered.map { (entry: $0, date: $0.app.currentDate?.date ?? .distantPast) }.sorted {
                request.ascending ? $0.date < $1.date : $0.date > $1.date
            }
            let grouped = Dictionary(grouping: dated) { Calendar.current.startOfDay(for: $0.date) }
            let dates = grouped.keys.sorted { request.ascending ? $0 > $1 : $0 < $1 }
            let formatter = DateFormatter()
            formatter.dateFormat = "MMMM d, yyyy"
            var result = Snapshot(apps: dated.map(\.entry))
            for date in dates {
                let title = formatter.string(from: date)
                result.titles.append(title)
                result.groups[title] = grouped[date]?.map(\.entry)
            }
            return result
        }
    }
}
