#!/usr/bin/env python3
"""Run real transfer/cancellation and bounded-presentation checks without an iOS SDK.

Only platform imports and Linux-unavailable URLSession configuration are adapted.
The production range scheduler, file I/O, pause/retry and mailbox code are compiled
unchanged. The main thread is deliberately blocked while the transfers run.
"""
import argparse
from pathlib import Path
import shutil
import socket
import subprocess
import tempfile
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

ROOT = Path(__file__).resolve().parents[2]
PAYLOAD = bytes(range(256)) * (32 * 1024)


class Server(BaseHTTPRequestHandler):
    attempts = {}
    attempts_lock = threading.Lock()

    def log_message(self, *_):
        pass

    def do_GET(self):
        ranged = self.headers.get('Range')
        start, end = (ranged or f'bytes=0-{len(PAYLOAD) - 1}').removeprefix('bytes=').split('-')
        start, end = int(start), int(end)
        body = PAYLOAD[start:end + 1]
        if self.path == '/bad' or not ranged:
            self.send_response(200)
        else:
            self.send_response(206)
        self.send_header('Content-Range', f'bytes {start}-{end}/{len(PAYLOAD)}')
        self.send_header('Content-Length', len(body))
        self.end_headers()
        with self.attempts_lock:
            attempt = self.attempts.get((self.path, start), 0)
            self.attempts[(self.path, start)] = attempt + 1
        try:
            if self.path == '/retry' and attempt == 0:
                self.wfile.write(body[:65536])
                self.wfile.flush()
                self.connection.shutdown(socket.SHUT_RDWR)
                self.connection.close()
                return
            for offset in range(0, len(body), 65536):
                self.wfile.write(body[offset:offset + 65536])
                self.wfile.flush()
                time.sleep(0.004)
        except (BrokenPipeError, ConnectionResetError, OSError):
            pass


STUBS = r'''
import Foundation
import FoundationNetworking
@propertyWrapper struct Published<Value> {
    var wrappedValue: Value
    init(wrappedValue: Value) { self.wrappedValue = wrappedValue }
}
protocol ObservableObject: AnyObject {}
final class UIApplication {
    static let shared = UIApplication()
    enum State { case active, background }
    var applicationState = State.active
    static let willResignActiveNotification = Notification.Name("resign")
    static let didEnterBackgroundNotification = Notification.Name("background")
    static let didBecomeActiveNotification = Notification.Name("foreground")
}
enum UIAlertController {
    static func showAlertWithOk(title: String, message: String) { fatalError(title + ": " + message) }
}
extension String { static func localized(_ value: String) -> String { value } }
enum Shader {
    struct Argument: Sendable {
        let bytes: Data
        static func data(_ bytes: Data) -> Self { Self(bytes: bytes) }
    }
}
enum NBAuroraTextVisibility {
    static func usable(_ rect: CGRect) -> Bool { !rect.isNull && !rect.isInfinite && !rect.isEmpty }
}
extension URL { static var documentsDirectory: URL { URL(fileURLWithPath: CommandLine.arguments[2]) } }
extension URL {
    func startAccessingSecurityScopedResource() -> Bool { false }
    func stopAccessingSecurityScopedResource() {}
}
extension Int64 { var formattedByteCount: String { String(self) } }
extension FileManager {
    func createDirectoryIfNeeded(at url: URL) throws { try createDirectory(at: url, withIntermediateDirectories: true) }
}
final class BackgroundTaskManager: @unchecked Sendable {
    static let shared = BackgroundTaskManager()
    enum Owner: Hashable { case ipaVaultDownloads, extracting }
    private let lock = NSLock()
    private var releases: [Owner: Bool] = [:]
    let downloadProgress = DispatchSemaphore(value: 0)
    func clearReport(_ owner: Owner) {}
    func claim(_ owner: Owner) { lock.lock(); releases.removeValue(forKey: owner); lock.unlock() }
    func release(_ owner: Owner, success: Bool) { lock.lock(); releases[owner] = success; lock.unlock() }
    func releaseResult(_ owner: Owner) -> Bool? { lock.lock(); defer { lock.unlock() }; return releases[owner] }
    func updateProgress(for id: String, progress: Double) { downloadProgress.signal() }
    func report(_ owner: Owner, completed: Int?, total: Int?, fraction: Double?, detail: String?, currentItem: String?) {}
}
'''

MAIN = r'''
import Foundation
import FoundationNetworking

func require(_ condition: @autoclosure () -> Bool, _ message: String) {
    if !condition() { fatalError(message) }
}

func mailboxChecks() {
    let queue = DispatchQueue(label: "test.presentation")
    let gate = DispatchSemaphore(value: 0)
    let delivered = DispatchSemaphore(value: 0)
    let lock = NSLock()
    var received: [Int] = []
    queue.async { gate.wait() }
    let mailbox = LatestValueDelivery<Int>(interval: 0.01, queue: queue) { value in
        lock.lock(); received.append(value); lock.unlock()
        delivered.signal()
    }
    for value in 0..<10000 { mailbox.submit(value) }
    gate.signal()
    require(delivered.wait(timeout: .now() + 3) == .success, "mailbox did not deliver")
    queue.sync {}
    require(received == [9999], "backlogged presentation must receive only the newest value")
    mailbox.setActive(false)
    mailbox.submit(10000)
    mailbox.submit(10001)
    require(delivered.wait(timeout: .now() + 0.04) == .timedOut, "inactive UI received work")
    mailbox.setActive(true)
    require(delivered.wait(timeout: .now() + 3) == .success, "foreground did not flush")
    mailbox.submit(10002)
    mailbox.cancel()
    require(delivered.wait(timeout: .now() + 0.04) == .timedOut, "cancelled progress was delivered")
    mailbox.submit(10003, immediately: true)
    require(delivered.wait(timeout: .now() + 3) == .success, "immediate completion missing")
    queue.sync {}
    require(received == [9999, 10001, 10003], "stale presentation replaced a completion")
    print("PASS: bounded mailbox, suspension, foreground flush and stale cancellation")
}

func spinUntil(_ description: String, _ predicate: () -> Bool) {
    let deadline = Date().addingTimeInterval(30)
    while !predicate() && Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.01)) }
    require(predicate(), "UI timed out: " + description)
}

func inkChecks() {
    let identity = NBAuroraShaderIdentity(high: 7, low: 11)
    let other = NBAuroraShaderIdentity(high: 8, low: 11)
    let window = CGRect(x: 0, y: 0, width: 390, height: 844)
    let rows = NBAuroraInkRows(frame: CGRect(x: 20, y: 100, width: 120, height: 40), window: window)
    let unseen = NBAuroraInkRows(frame: CGRect(x: 20, y: 700, width: 120, height: 40), window: window)
    let stride = NBAuroraInkMapFormat.width * 4
    var bytes = Data((0..<(stride * NBAuroraInkMapFormat.height)).map { UInt8($0 % 251) })
    let first = NBAuroraInkFrame(identity: identity, bytes: bytes, rows: [rows], previous: nil)
    let expected = bytes.subdata(in: rows.first * stride..<(rows.first + rows.count) * stride)
    require(first.sample(for: rows).bytes == expected, "ink crop changed texels")
    require(first.sample(for: unseen).rows == .full && first.sample(for: unseen).bytes == bytes,
            "newly visible/frozen labels must retain the exact full map")
    let same = NBAuroraInkFrame(identity: identity, bytes: bytes, rows: [rows], previous: first)
    require(same.sample(for: rows) === first.sample(for: rows), "unchanged label paint was invalidated")
    bytes[rows.first * stride] ^= 1
    let changed = NBAuroraInkFrame(identity: identity, bytes: bytes, rows: [rows], previous: same)
    require(changed.sample(for: rows) !== same.sample(for: rows), "changed ink did not publish")
    let shuffled = NBAuroraInkFrame(identity: other, bytes: bytes, rows: [rows], previous: changed)
    require(shuffled.sample(for: rows) !== changed.sample(for: rows), "shuffle reused the previous sky's identity")
    let visible = Set((0..<24).map {
        NBAuroraInkRows(frame: CGRect(x: 0, y: Double($0) * 35, width: 200, height: 30), window: window)
    })
    let dense = NBAuroraInkFrame(identity: identity, bytes: bytes, rows: visible, previous: nil)
    for row in visible { require(dense.sample(for: row).rows == row, "visible ink fell back to an oversized full map") }
    print("PASS: exact ink texels, frozen/scrolling fallback, unchanged-paint reuse and shuffle identity")
}

func workflowChecks() {
    let download = Download(id: "worker-check", url: URL(string: "https://example.invalid/app.ipa")!)
    for count in 0..<10000 { download.reportNetwork(bytes: Int64(count), total: 10000) }
    require(BackgroundTaskManager.shared.downloadProgress.wait(timeout: .now() + 3) == .success,
            "system download progress depended on main")
    download.stopPresentation()
    let manager = ExtractManager.shared
    let first = manager.start(fileName: "first.zip")
    let second = manager.start(fileName: "second.zip")
    for count in 0..<10000 { manager.updateProgress(for: first, progress: Double(count) / 10000) }
    manager.finish(item: first, succeeded: false)
    manager.finish(item: second, succeeded: true)
    let deadline = Date().addingTimeInterval(3)
    while BackgroundTaskManager.shared.releaseResult(.extracting) == nil && Date() < deadline {
        Thread.sleep(forTimeInterval: 0.01)
    }
    require(BackgroundTaskManager.shared.releaseResult(.extracting) == false,
            "extraction completion/failure accounting depended on UI callbacks")
    print("PASS: download system progress and overlapping extraction completion with blocked main")
}

func diskChecks() {
    var finished = false
    Task { @MainActor in
        let succeeded = try await BackgroundFileWork.perform {
            require(!Thread.isMainThread, "file work inherited the main actor")
            let root = URL.documentsDirectory.appendingPathComponent("disk-checks")
            let destination = root.appendingPathComponent("Tweaks")
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            let source = root.appendingPathComponent("sample.dylib")
            let data = Data(repeating: 73, count: 1024 * 1024)
            try data.write(to: source)
            let copied = TweakFileStore.importFiles([source], to: destination)
            require(copied.count == 1, "tweak import missing")
            let copiedData = try Data(contentsOf: copied[0])
            require(copiedData == data, "tweak copy changed data")
            _ = TweakFileStore.importFiles(copied, to: destination)
            let existingData = try Data(contentsOf: copied[0])
            require(existingData == data, "reimport deleted its own source")
            return TweakFileStore.list(in: destination).count == 1
        }
        require(succeeded, "background directory listing failed")
        finished = true
    }
    spinUntil("background file work") { finished }
    print("PASS: file work called from MainActor stays off-main; tweak copy/list/reimport integrity")
}

func facadeChecks(_ base: String, payload: Data) throws {
    let manager = IPADownloadManager()
    manager.enqueueIPAVaultDownloads([(URL(string: base + "/facade")!, "facade.ipa", Int64(payload.count))])
    spinUntil("vault facade completion") { manager.downloadItems.contains { $0.title == "facade.ipa" && $0.isFinished } }
    let old = manager.downloadItems.first { $0.title == "facade.ipa" }!
    manager.deleteFinishedDownload(old)
    spinUntil("completed row removal") { !manager.downloadItems.contains { $0.id == old.id } }
    manager.enqueueIPAVaultDownloads([(URL(string: base + "/next")!, "next.ipa", Int64(payload.count))])
    spinUntil("next vault transfer") { manager.downloadItems.contains { $0.title == "next.ipa" && $0.isFinished } }
    require(!manager.downloadItems.contains { $0.id == old.id }, "a new snapshot resurrected a deleted row")
    manager.startDownload(url: URL(string: base + "/ordinary-one")!, filename: "ordinary-one.ipa")
    manager.startDownload(url: URL(string: base + "/ordinary-two")!, filename: "ordinary-two.ipa")
    spinUntil("ordinary downloads") {
        manager.downloadItems.filter { $0.title.hasPrefix("ordinary-") && $0.isFinished }.count == 2
    }
    for item in manager.downloadItems where item.title.hasPrefix("ordinary-") {
        let actual = try Data(contentsOf: item.localPath)
        require(actual == payload, "ordinary completion wrote the wrong row/file")
    }
    print("PASS: UI snapshot merging, deleted-row retention, concurrent ordinary completions")
}

final class TransferCheck: @unchecked Sendable {
    let done = DispatchSemaphore(value: 0)
    let mode: String
    var transfer: IPAVaultTransfer!
    var acted = false
    var sawPaused = false
    var sawData = false
    var finished: [DownloadItem] = []
    var last: [DownloadItem] = []

    init(_ mode: String) {
        self.mode = mode
        transfer = IPAVaultTransfer { [weak self] in self?.receive($0) }
    }

    func receive(_ state: IPAVaultTransfer.Presentation) {
        require(!Thread.isMainThread, "transport ran on main")
        last = state.items
        guard let item = state.items.first else {
            if acted && (mode == "cancel" || mode == "bad") { done.signal() }
            return
        }
        if mode == "bad" { acted = true }
        if item.progress > 0 && !item.isFinished {
            sawData = true
            if !acted && (mode == "pause" || mode == "cancel") {
                acted = true
                if mode == "pause" { transfer.pauseIPAVaultDownload(item) }
                else { transfer.cancelDownload(item) }
            }
        }
        if item.isPaused && !sawPaused {
            sawPaused = true
            DispatchQueue.global().asyncAfter(deadline: .now() + 0.08) { self.transfer.resumeIPAVaultDownload(item) }
        }
        let completed = state.items.filter(\.isFinished)
        if completed.count == (mode == "concurrent" ? 2 : 1) {
            finished = completed
            done.signal()
        }
    }
}

@main struct Checks {
    static func main() throws {
        inkChecks()
        mailboxChecks()
        workflowChecks()
        diskChecks()
        let base = CommandLine.arguments[1]
        let root = URL.documentsDirectory
        let payload = try Data(contentsOf: root.appendingPathComponent("expected"))
        for mode in ["concurrent", "pause", "cancel", "retry", "background", "bad"] {
            let check = TransferCheck(mode)
            check.transfer.setActive(mode != "background")
            let paths = mode == "concurrent" ? ["one", "two"] : [mode]
            check.transfer.enqueueIPAVaultDownloads(paths.map {
                (url: URL(string: base + "/" + $0)!, filename: mode + "-" + $0 + ".ipa", size: Int64(payload.count))
            })
            // No RunLoop or dispatchMain: completion must work with the UI blocked.
            require(check.done.wait(timeout: .now() + 30) == .success, "transfer timeout: " + mode)
            if mode == "cancel" || mode == "bad" {
                require(check.last.isEmpty, "failed/cancelled row retained")
            } else {
                for item in check.finished {
                    let actual = try Data(contentsOf: item.localPath)
                    require(actual == payload, "corrupt or prematurely finished download: " + mode)
                }
            }
            if mode == "pause" { require(check.sawPaused, "pause was never acknowledged") }
            print("PASS: " + mode + " transfer with blocked main thread")
        }
        try facadeChecks(base, payload: payload)
    }
}
'''


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--swiftc', default=shutil.which('swiftc') or str(ROOT / '.build/swift-toolchain/usr/bin/swiftc'))
    args = parser.parse_args()
    server = ThreadingHTTPServer(('127.0.0.1', 0), Server)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    try:
        with tempfile.TemporaryDirectory(prefix='asign-ui-workers-') as work:
            work = Path(work)
            (work / 'expected').write_bytes(PAYLOAD)
            engine = (ROOT / 'Asign/Views/Downloader/ViewModels/IPAVaultTransfer.swift').read_text()
            engine = engine.replace('import Darwin', 'import Glibc\nimport FoundationNetworking').replace('Darwin.', 'Glibc.')
            engine = engine.replace('        config.waitsForConnectivity = true\n', '')
            model = (ROOT / 'Asign/Views/Downloader/Models/DownloadItem.swift').read_text().replace('import SwiftUI', 'import Foundation')
            (work / 'Transfer.swift').write_text(engine)
            (work / 'Model.swift').write_text(model)
            (work / 'Stubs.swift').write_text(STUBS)
            (work / 'Checks.swift').write_text(MAIN)
            facade = (ROOT / 'Asign/Views/Downloader/ViewModels/IPADownloadManager.swift').read_text()
            for module in ['SwiftUI', 'UIKit', 'WebKit']:
                facade = facade.replace('import ' + module, '')
            facade = 'import Foundation\nimport FoundationNetworking\n' + facade
            facade = facade.replace('        config.waitsForConnectivity = true\n', '')
            (work / 'Facade.swift').write_text(facade)
            foreground = (ROOT / 'Asign/Utilities/ForegroundValueDelivery.swift').read_text().replace('import UIKit', 'import Foundation')
            (work / 'Foreground.swift').write_text(foreground)
            ink = (ROOT / 'NimbleKit/Sources/NimbleExtensions/View/NBAuroraInkMap.swift').read_text().split('/// A scope owns its lease;')[0]
            for module in ['SwiftUI', 'UIKit', 'Metal']:
                ink = ink.replace('import ' + module, '')
            (work / 'Ink.swift').write_text('import Foundation\n' + ink)
            extract = (ROOT / 'Asign/Backend/Observable/ExtractManager.swift').read_text().replace('import Combine', '')
            (work / 'Extract.swift').write_text(extract)
            download = (ROOT / 'Asign/Backend/Observable/DownloadManager.swift').read_text()
            download = download[download.index('class Download:'):download.index('class DownloadManager:')]
            (work / 'Download.swift').write_text('import Foundation\nimport FoundationNetworking\n' + download)
            subprocess.run([args.swiftc, '-swift-version', '5', '-o', str(work / 'checks'),
                str(ROOT / 'Asign/Utilities/LatestValueDelivery.swift'),
                str(ROOT / 'Asign/Utilities/BackgroundFileWork.swift'),
                str(ROOT / 'NimbleKit/Sources/NimbleExtensions/View/NBAuroraShaderIdentity.swift'),
                *[str(work / name) for name in ['Transfer.swift', 'Model.swift', 'Stubs.swift', 'Checks.swift', 'Facade.swift', 'Foreground.swift', 'Ink.swift', 'Extract.swift', 'Download.swift']]], check=True)
            subprocess.run([str(work / 'checks'), f'http://127.0.0.1:{server.server_port}', str(work)], check=True, timeout=180)
    finally:
        server.shutdown()


if __name__ == '__main__':
    main()
