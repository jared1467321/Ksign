import Foundation

for name in ["Reconnect Tailscale", "VPN & DNS=on?", "VPN + 家", "Run #1", "VPN%20", "Line\nBreak"] {
    guard let url = VPNReconnectRequest.url(shortcutName: name),
          let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
        fatalError("Could not create shortcut URL")
    }
    precondition(components.scheme == "shortcuts")
    precondition(components.host == "run-shortcut")
    precondition(components.queryItems?.count == 1, "Shortcut name injected extra query parameters")
    precondition(components.queryItems?.first?.name == "name")
    precondition(components.queryItems?.first?.value == name, "Shortcut name changed during encoding")
    precondition(components.fragment == nil, "Shortcut name injected a fragment")
}
precondition(VPNReconnectRequest.url(shortcutName: "  \n ") == nil)
precondition(URLComponents(url: VPNReconnectRequest.url(shortcutName: "  Reconnect Tailscale  ")!, resolvingAgainstBaseURL: false)?.queryItems?.first?.value == "Reconnect Tailscale")
print("VPN reconnect URL tests passed")
