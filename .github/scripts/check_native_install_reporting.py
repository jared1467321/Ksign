#!/usr/bin/env python3
"""Check native install reporting and selection batching without signing IPAs.

Compile the production reporter and selection-construction block with controlled
job/system-report substitutes. This verifies coordination, not the device's
installation service or native transport performance. Requires Xcode on macOS.
"""
import os
from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[2]
PREFIX = r'''import Foundation
import Combine
final class InstallerStatusViewModel {
 enum InstallerStatus { case none, ready, sendingManifest, sendingPayload, installing, completed(Result<Void,Error>), broken(Error) }
}
struct IDeviceInstallSkip: Error {}
struct Failure: Error {}
final class BackgroundTaskManager {
 static let shared = BackgroundTaskManager()
 enum Owner { case bulkInstalls }
 struct Report { let completed: Int?; let total: Int?; let fraction: Double?; let detail: String?; let currentItem: String? }
 private let lock = NSLock()
 private var values: [Report] = []
 var reports: [Report] { lock.lock(); defer { lock.unlock() }; return values }
 func clearReport(_ owner: Owner) { lock.lock(); values.removeAll(); lock.unlock() }
 func report(_ owner: Owner, completed: Int?, total: Int?, fraction: Double?, detail: String?, currentItem: String?) {
  lock.lock(); values.append(Report(completed: completed,total:total,fraction:fraction,detail:detail,currentItem:currentItem)); lock.unlock()
 }
}
'''

REPORTER_CHECKS = r'''let r = BulkInstallLiveActivityReporter.shared
let system = BackgroundTaskManager.shared
r.reset()
let ids = (0..<100).map { _ in UUID() }
r.register(ids.map { (id: $0, name: "App") })
precondition(system.reports.count == 1 && system.reports.last?.total == 100)
for id in ids { r.updateStatus(jobID: id, status: .installing) }
r.testBarrier()
precondition(system.reports.count == 101)
for step in 1...20 { for id in ids { r.updateInstall(jobID: id, progress: Double(step)/21) } }
r.testBarrier()
Thread.sleep(forTimeInterval: 0.3)
r.testBarrier()
let burstReports = system.reports.count
precondition(burstReports < 110)
print("PASS: 100 registrations produce one summary; 2,000 numeric updates produce",burstReports - 101,"summaries")
for id in ids { r.updateStatus(jobID: id, status: .completed(.success(()))) }
r.testBarrier()
precondition(system.reports.count == burstReports + 100 && system.reports.last?.completed == 100)
let terminalCount = system.reports.count
Thread.sleep(forTimeInterval: 0.3); r.testBarrier()
precondition(system.reports.count == terminalCount)
print("PASS: immediate completions, exact totals, no delayed report after terminal state")
r.reset(); let a = UUID(), b = UUID(), c = UUID()
r.register([(id:a,name:"a"),(id:b,name:"b"),(id:c,name:"c")])
r.updatePackage(jobID:a,progress:0.5); r.testBarrier()
precondition(system.reports.last?.fraction == 0.25/3)
r.updateInstall(jobID:a, progress:0.3); r.testBarrier()
precondition(system.reports.last?.fraction == 0.65/3)
r.updateStatus(jobID:b,status:.broken(IDeviceInstallSkip()))
r.updateStatus(jobID:c,status:.broken(Failure()))
r.updateStatus(jobID:a,status:.completed(.success(()))); r.testBarrier()
precondition(system.reports.last?.completed == 3 && system.reports.last?.detail == "Error")
print("PASS: immediate package/install phase changes, failures and skips")
r.reset(); r.register(a,name:"a")
r.updateInstall(jobID:a,progress:0.1); r.testBarrier()
r.updateInstall(jobID:a,progress:0.9,isCurrent:{false})
r.updatePackage(jobID:a,progress:1,isCurrent:{false}); r.testBarrier()
r.setPaused(true); r.testBarrier()
precondition(system.reports.last?.detail == "Paused" && system.reports.last?.fraction == 0.55)
r.updateInstall(jobID:a,progress:0.7); r.testBarrier()
r.reset(); r.register(b,name:"new")
Thread.sleep(forTimeInterval:0.3); r.testBarrier()
precondition(system.reports.count == 1 && system.reports.last?.fraction == 0)
print("PASS: stale-generation rejection, pause flush, reset cancels pending progress")
'''

SELECTION_PREFIX = r'''struct TestApp {
 let uuid: String?
 let identifier: String?
 var name: String? { uuid }
}
final class InstallJob {
 enum Phase { case queued, running, completed, failed, skipped }
 var isDeviceInstall = true
 var isSelfUpdate: Bool { app.identifier == Bundle.main.bundleIdentifier }
 var isTerminal: Bool { phase == .completed || phase == .failed || phase == .skipped }
 let id = UUID()
 let app: TestApp
 var phase = Phase.queued
 static var onStart: ((InstallJob) -> Void)?
 init(app: TestApp) throws { if app.uuid == "bad" { throw Failure() }; self.app = app }
 func cancel() {}
 func start() { Self.onStart?(self) }
}
enum Logger {
 struct Sink { func error(_ message: String) {} }
 static let misc = Sink()
}
final class SelectionHarness {
 var publications = 0
 var jobs: [InstallJob] = [] { didSet { publications += 1 } }
 var _skippedJobIDs = Set<UUID>()
 var totalCount = 0
 var skippedCount = 0
 var _willBatch = false
 var tracked = Set<UUID>()
 func _trackJob(_ job: InstallJob) { tracked.insert(job.id) }
 func _untrackJob(_ job: InstallJob) { tracked.remove(job.id) }
 func add(apps: [TestApp], isDeviceInstall: Bool = true) {
'''

SELECTION_CHECKS = r'''r.reset()
let selection = SelectionHarness()
var starts: [String?] = []
InstallJob.onStart = { job in
 precondition(selection.jobs.count == 101 && selection.totalCount == 101 && selection.tracked.count == 101)
 starts.append(job.app.uuid)
}
let ordinary = (0..<100).map { TestApp(uuid:String($0),identifier:"test."+String($0)) }
let host = TestApp(uuid:"host",identifier:Bundle.main.bundleIdentifier)
selection.add(apps:[host]+ordinary+[ordinary[0],TestApp(uuid:"bad",identifier:"bad")])
precondition(selection.publications == 1 && selection.jobs.count == 101)
precondition(starts.count == 101 && starts.last! == "host")
precondition(system.reports.count == 1 && system.reports.last?.total == 101)
print("PASS: one membership publication and summary, duplicate suppression, construction failure and self-update-last ordering")
let stale = selection.jobs[0]
stale.phase = .skipped; selection._skippedJobIDs.insert(stale.id); selection.skippedCount = 1
InstallJob.onStart = { job in
 precondition(selection.jobs.count == 101 && selection.totalCount == 101)
 precondition(job.id != stale.id)
}
selection.add(apps:[stale.app])
precondition(selection.publications == 2 && selection.skippedCount == 0 && !selection.tracked.contains(stale.id))
precondition(system.reports.last?.total == 101)
let beforeDuplicate = selection.publications
selection.add(apps:[host])
precondition(selection.publications == beforeDuplicate)
print("PASS: skipped retry replacement, stable denominator and duplicate-only no-op")
r.reset(); let batch = SelectionHarness(); batch._willBatch = true
var started = false; InstallJob.onStart = { _ in started = true }
batch.add(apps:ordinary,isDeviceInstall:false)
precondition(batch.jobs.count == 100 && !started && batch.publications == 1)
print("PASS: server batch jobs retain deferred admission")
'''
ADMISSION_PREFIX = r'''final class InstallQueueCoordinator {
 static let shared = InstallQueueCoordinator()
 var activeCount = 0
 var hasDeviceWorkInProgress = false
}
final class AdmissionHarness {
 private var _trackedJobs: [UUID: InstallJob] = [:]
 var jobs: [InstallJob] = [] {
  didSet {
   _trackedJobs = Dictionary(uniqueKeysWithValues: jobs.map { ($0.id, $0) })
   _deviceAdmission = nil
  }
 }
 func phaseChanged(_ job: InstallJob, to phase: InstallJob.Phase) {
  job.phase = phase
  _deviceAdmission = nil
 }
'''

ADMISSION_CHECKS = r'''let admission = AdmissionHarness()
let first = try InstallJob(app: ordinary[0])
let second = try InstallJob(app: ordinary[1])
let selfUpdate = try InstallJob(app: host)
admission.jobs = [selfUpdate, first, second]
precondition(admission.mayStartDeviceJob(first.id) && !admission.mayStartDeviceJob(second.id))
precondition(!admission.mayStartDeviceJob(selfUpdate.id))
admission.phaseChanged(first, to: .running)
precondition(admission.mayStartDeviceJob(second.id) && !admission.mayStartDeviceJob(selfUpdate.id))
admission.phaseChanged(first, to: .queued)
precondition(admission.mayStartDeviceJob(first.id) && !admission.mayStartDeviceJob(second.id))
admission.phaseChanged(second, to: .completed)
admission.jobs.removeAll { $0 === first }
InstallQueueCoordinator.shared.hasDeviceWorkInProgress = true
precondition(!admission.mayStartDeviceJob(selfUpdate.id))
InstallQueueCoordinator.shared.hasDeviceWorkInProgress = false
precondition(admission.mayStartDeviceJob(selfUpdate.id))
admission.phaseChanged(selfUpdate, to: .running)
admission.jobs.append(first)
precondition(!admission.mayStartDeviceJob(first.id))
print("PASS: native admission preserves selection order, retry priority and exclusive self-update through cleanup")
'''

NATIVE_PRESENTATION_PREFIX = r'''import Foundation
enum UIApplication {
    static let shared = UIApplicationState()
    static let willResignActiveNotification = Notification.Name("resign")
    static let didEnterBackgroundNotification = Notification.Name("background")
    static let didBecomeActiveNotification = Notification.Name("active")
}
final class UIApplicationState {
    enum State { case active }
    let applicationState = State.active
}
'''

NATIVE_PRESENTATION_CHECKS = r'''let presentation = IDeviceInstallPresentation.shared
RunLoop.main.run(until: Date().addingTimeInterval(0.01))
let mailboxes = (0..<5).map { _ in IDeviceInstallProgress() }
var samples = Array(repeating: [Double](), count: mailboxes.count)
let attempts = mailboxes.enumerated().map { index, mailbox in
    presentation.observe {
        if let upload = mailbox.drain(scheduled: true).upload { samples[index].append(upload) }
    }
}
func submit(_ value: Double, at index: Int) {
    if mailboxes[index].submit(upload: value) { presentation.request(attempts[index]) }
}
for step in 1...10 {
    for index in attempts.indices { submit(Double(step) / 10, at: index) }
}
precondition(samples.allSatisfy { $0.isEmpty })
RunLoop.main.run(until: Date().addingTimeInterval(0.28))
precondition(IDeviceInstallPresentation.testTicks == 1 && samples.allSatisfy { $0 == [1] })
NotificationCenter.default.post(name: UIApplication.willResignActiveNotification, object: nil)
for index in attempts.indices { submit(0.4, at: index) }
submit(0.7, at: 0)
precondition(mailboxes[1].drain(finishing: true).upload == 0.4)
precondition(!mailboxes[1].submit(upload: 1))
presentation.remove(attempts[1])
RunLoop.main.run(until: Date().addingTimeInterval(0.25))
precondition(IDeviceInstallPresentation.testTicks == 1 && samples.allSatisfy { $0 == [1] })
NotificationCenter.default.post(name: UIApplication.didBecomeActiveNotification, object: nil)
precondition(samples[0] == [1, 0.7] && samples[1] == [1] && samples[2] == [1, 0.4])
print("PASS: one foreground progress tick for five native attempts, latest values on resume, removed attempt stays closed")

func checkPacket(length: Int, headerWords: UInt8) {
    var bytes = (0..<length).map { UInt8(truncatingIfNeeded: $0) }
    bytes[0] = 0x40 | headerWords
    bytes[2] = UInt8(length >> 8)
    bytes[3] = UInt8(truncatingIfNeeded: length)
    bytes.replaceSubrange(12..<20, with: [10, 7, 0, 2, 10, 7, 0, 1])
    let input = Data(bytes)
    let padded = Data([0]) + input + Data([0])
    bytes[15] = 1
    bytes[19] = 2
    let expected = Data(bytes)
    precondition(LocalPacketReflection.reflect(input) == expected)
    precondition(LocalPacketReflection.reflect(padded[1..<(length + 1)]) == expected)
    precondition(input[15] == 2 && input[19] == 1)
    precondition(LocalPacketReflection.reflect(expected) == nil)
    precondition(LocalPacketReflection.reflect(input.dropLast()) == nil)
    var invalid = input
    invalid[0] = 0x44
    precondition(LocalPacketReflection.reflect(invalid) == nil)
    invalid[0] = 0x65
    precondition(LocalPacketReflection.reflect(invalid) == nil)
}
checkPacket(length: 20, headerWords: 5)
checkPacket(length: 1500, headerWords: 8)
precondition(LocalPacketReflection.reflect(Data(repeating: 0, count: 19)) == nil)
print("PASS: reflection preserves payload and options, accepts Data slices, and rejects invalid lengths and addresses")
'''


def main():
    source = (ROOT / 'Asign/Views/Library/Install/InstallSession.swift').read_text()
    reporter = source[source.index('final class BulkInstallLiveActivityReporter'):]
    # Only expose a queue barrier in the test copy; shipping code has no test hooks.
    reporter = reporter.replace('\tprivate init() { }',
        '\tprivate init() { }\n func testBarrier() { _queue.sync {} }', 1)
    start = source.index('\t\tlet orderedApps = isDeviceInstall')
    end = source.index('\n\t\tif _willBatch { _admitBatchJobs() }', start)
    cache = source[source.index('\tprivate struct DeviceAdmission'):
                   source.index('\n\t// Foreground drawer counters')]
    admission = source[source.index('\tfunc mayStartDeviceJob'):
                       source.index('\n\tfunc jobDidFinish')]
    fixture = (PREFIX + reporter + REPORTER_CHECKS + SELECTION_PREFIX
               + source[start:end] + '\n}\n}\n' + SELECTION_CHECKS
               + ADMISSION_PREFIX + cache + '\n' + admission + '\n}\n' + ADMISSION_CHECKS)
    env = dict(os.environ)
    env.setdefault('DEVELOPER_DIR', '/Applications/Xcode.app/Contents/Developer')
    sdk = subprocess.check_output(['xcrun', '--sdk', 'macosx', '--show-sdk-path'], text=True, env=env).strip()
    swift = subprocess.check_output(['xcrun', '--find', 'swiftc'], text=True, env=env).strip()
    proxy = (ROOT / 'Native/Device/InstallationProxy.swift').read_text()
    presentation = proxy[proxy.index('final class IDeviceInstallProgress'):
                         proxy.index('public final class InstallationProxy')]
    presentation = presentation.replace('    private var scheduled = false',
        '    private var scheduled = false\n    static var testTicks = 0', 1)
    presentation = presentation.replace('if scheduled { self.scheduled = false }',
        'if scheduled { self.scheduled = false; Self.testTicks += 1 }', 1)
    reflection = (ROOT / 'AsignDeviceTunnel/LocalPacketReflection.swift').read_text()
    native = NATIVE_PRESENTATION_PREFIX + presentation + reflection + NATIVE_PRESENTATION_CHECKS
    with tempfile.TemporaryDirectory(prefix='asign-native-reporting-') as directory:
        for name, contents in [('reporting', fixture), ('presentation', native)]:
            path = Path(directory) / (name + '.swift')
            binary = Path(directory) / name
            path.write_text(contents)
            subprocess.run([swift, '-swift-version', '5', '-sdk', sdk, str(path), '-o', str(binary)], env=env, check=True)
            subprocess.run([str(binary)], check=True)

if __name__ == '__main__':
    main()
