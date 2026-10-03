import Foundation
import UIKit
import Darwin

// Records evidence before termination; no unsafe crash/signal handlers. Absence
// of an expiration/termination event does not identify why the OS ended a run.
final class InstallDiagnostics {
    static let shared = InstallDiagnostics()
    private let log = PersistentDiagnosticLog(directory: FileManager.default.urls(
        for: .documentDirectory, in: .userDomainMask
    )[0].appendingPathComponent("Diagnostics", isDirectory: true))
    private var observers: [NSObjectProtocol] = []
    private var timer: DispatchSourceTimer?

    private init() {
        record("process_start", details: [
            "version": Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "unknown",
            "build": Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "unknown",
            "os": UIDevice.current.systemVersion
        ])
        for (name, event) in [
            (UIApplication.didBecomeActiveNotification, "app_active"),
            (UIApplication.didEnterBackgroundNotification, "app_background"),
            (UIApplication.didReceiveMemoryWarningNotification, "memory_warning"),
            (UIApplication.willTerminateNotification, "termination_notification")
        ] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: nil) { [weak self] _ in
                self?.record(event)
            })
        }
    }

    func record(_ event: String, details: [String: String] = [:]) {
        var fields = details
        fields["available_memory_bytes"] = String(os_proc_available_memory())
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        if result == KERN_SUCCESS { fields["footprint_bytes"] = String(info.phys_footprint) }
        log.record(event, details: fields)
    }

    // Owned by the MainActor install session. Sample only while a batch is active.
    @MainActor func startSampling() {
        guard timer == nil else { return }
        let source = DispatchSource.makeTimerSource(queue: DispatchQueue.global(qos: .utility))
        source.schedule(deadline: .now(), repeating: .seconds(5))
        source.setEventHandler { [weak self] in self?.record("install_memory_sample") }
        timer = source
        source.resume()
    }

    @MainActor func stopSampling() {
        timer?.cancel()
        timer = nil
    }
}
