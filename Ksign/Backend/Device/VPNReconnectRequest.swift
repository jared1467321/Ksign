import Foundation

enum VPNReconnectRequest {
    static func url(shortcutName: String) -> URL? {
        let name = shortcutName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return nil }
        var components = URLComponents()
        components.scheme = "shortcuts"
        components.host = "run-shortcut"
        // The shortcut name is data, including spaces, Unicode, and '&'. Do
        // not interpolate a query string or pass clipboard/IPA input.
        components.queryItems = [URLQueryItem(name: "name", value: name)]
        return components.url
    }
}
