import Foundation
#if canImport(UIKit)
import UIKit
#endif

/// Independent of stdout capture so reconnect diagnostics remain available in
/// Files even when the in-app log capture is paused. Never logs shared content.
@MainActor
final class VPNReconnectDiagnostics {
    private static let shared = VPNReconnectDiagnostics()
    private let sessionID = UUID().uuidString
    private let formatter = ISO8601DateFormatter()
    private var observers: [NSObjectProtocol] = []
    private let maximumBytes = 2 * 1_024 * 1_024

    static func record(_ message: String) {
        shared.append(message)
    }

    private init() {
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        #if canImport(UIKit)
        let notifications: [(Notification.Name, String)] = [
            (UIApplication.willResignActiveNotification, "willResignActive"),
            (UIApplication.didEnterBackgroundNotification, "didEnterBackground"),
            (UIApplication.willEnterForegroundNotification, "willEnterForeground"),
            (UIApplication.didBecomeActiveNotification, "didBecomeActive"),
            (UIApplication.willTerminateNotification, "willTerminate")
        ]
        for (name, label) in notifications {
            observers.append(NotificationCenter.default.addObserver(
                forName: name, object: nil, queue: .main
            ) { _ in
                Task { @MainActor in
                    Self.record("lifecycle: \(label)")
                }
            })
        }
        #endif
        let bundle = Bundle.main
        append("session started; bundle=\(bundle.bundleIdentifier ?? "unknown"); "
            + "version=\(bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") ?? "unknown"); "
            + "build=\(bundle.object(forInfoDictionaryKey: "CFBundleVersion") ?? "unknown"); "
            + "os=\(ProcessInfo.processInfo.operatingSystemVersionString)")
    }

    private func append(_ message: String) {
        // Keep each event on one line, including NSError descriptions.
        let escaped = message.replacingOccurrences(of: "\r", with: "\\r")
            .replacingOccurrences(of: "\n", with: "\\n")
        var state = ""
        #if canImport(UIKit)
        switch UIApplication.shared.applicationState {
        case .active: state = " active"
        case .inactive: state = " inactive"
        case .background: state = " background"
        @unknown default: state = " unknown"
        }
        #endif
        let line = "\(formatter.string(from: Date())) [\(sessionID)]\(state) \(escaped)\n"
        do {
            let files = FileManager.default
            let documents = try files.url(for: .documentDirectory, in: .userDomainMask,
                                          appropriateFor: nil, create: true)
            let url = documents.appendingPathComponent("share-sheet-debug.txt")
            if files.fileExists(atPath: url.path) {
                let size = (try files.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.intValue ?? 0
                if size >= maximumBytes {
                    let previous = documents.appendingPathComponent("share-sheet-debug.previous.txt")
                    if files.fileExists(atPath: previous.path) { try files.removeItem(at: previous) }
                    try files.moveItem(at: url, to: previous)
                }
            }
            if !files.fileExists(atPath: url.path) {
                guard files.createFile(atPath: url.path, contents: nil) else {
                    throw CocoaError(.fileWriteUnknown)
                }
            }
            // Open for each event so deleting/exporting the file in Files is
            // safe. Synchronous writes persist events before a handoff/crash.
            let handle = try FileHandle(forWritingTo: url)
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: Data(line.utf8))
        } catch {
            // A diagnostic failure must never interrupt installation/reconnect.
            print("[ShareSheetDebug] Could not write diagnostic file: \(error)")
        }
    }
}
