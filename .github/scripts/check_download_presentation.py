#!/usr/bin/env python3
"""macOS checks for row observation isolation and shared chrome geometry.

Compile the production model/cache definitions with controlled inputs. UIKit's
view hierarchy is substituted for the geometry check; device visual QA is still
needed for native bar transitions and rotations.
"""
import os
from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[2]
ROW_PREFIX = r'''import Foundation
import Combine
extension Int64 { var formattedByteCount: String { String(self) } }
enum IPAVaultTransfer {
    struct AdaptivePresentation: Equatable {
        var concurrentCount = 0; var streamsPerFile = 2; var status = "Idle"
        var streamCount = 0; var speedBPS: Double = 0
    }
}
'''
ROW_CHECKS = r'''do {
let list = DownloadItemsPresentation()
let url = URL(fileURLWithPath: "/test.ipa")
var a = DownloadItem(title: "a", url: url, localPath: url, isFinished: false, progress: 0, totalBytes: 100, bytesDownloaded: 0)
let b = DownloadItem(title: "b", url: url, localPath: url, isFinished: false, progress: 0, totalBytes: 100, bytesDownloaded: 0)
list.replaceItems([a, b])
let status = IPAVaultStatusModel()
let rowA = list.activeRows[0], rowB = list.activeRows[1]
var lists = 0, updatesA = 0, updatesB = 0, statuses = 0
var subs = Set<AnyCancellable>()
list.$activeRows.dropFirst().sink { _ in lists += 1 }.store(in: &subs)
rowA.$item.dropFirst().sink { _ in updatesA += 1 }.store(in: &subs)
rowB.$item.dropFirst().sink { _ in updatesB += 1 }.store(in: &subs)
status.$state.dropFirst().sink { _ in statuses += 1 }.store(in: &subs)
status.apply(.init(speedBPS: 1234))
precondition(lists == 0 && updatesA == 0 && updatesB == 0 && statuses == 1)
a.progress = 0.5; a.bytesDownloaded = 50
list.updateProgress(a)
precondition(lists == 0 && updatesA == 1 && updatesB == 0 && statuses == 1)
list.updateProgress(a)
precondition(lists == 0 && updatesA == 1 && updatesB == 0)
list.replaceItems([b,a])
precondition(lists == 1 && list.activeRows[0] === rowB && list.activeRows[1] === rowA)
a.isFinished = true
list.replaceItems([b,a])
precondition(lists == 2 && list.activeRows.count == 1 && list.activeRows[0] === rowB)
list.updateProgress(rowA.item)
precondition(list.finishedItems == [a] && list.items == [b, a] && list.hasItems)
list.replaceItems([])
precondition(lists == 3 && list.activeRows.isEmpty && !list.hasItems)
print("PASS: statistics isolation, changed-row-only updates, duplicate suppression, stable identity, reorder and completion/removal")

let membership = IPAVaultTransfer.Presentation(items: [rowA.item, rowB.item], progress: [:],
    adaptive: .init(), controls: .init(hasDownloads: true))
let deltaA = IPAVaultTransfer.Presentation(items: nil, progress: [a.id: rowA.item],
    adaptive: .init(), controls: membership.controls)
var updatedB = b
updatedB.progress = 0.8
let deltaB = IPAVaultTransfer.Presentation(items: nil, progress: [b.id: updatedB],
    adaptive: .init(speedBPS: 300), controls: membership.controls)
let combined = membership.merging(deltaA).merging(deltaB)
precondition(combined.items == membership.items && combined.progress.count == 2)
precondition(combined.progress[b.id] == updatedB && combined.adaptive.speedBPS == 300)
let removed = IPAVaultTransfer.Presentation(items: [updatedB], progress: [:],
    adaptive: .init(), controls: membership.controls)
precondition(combined.merging(removed).items == [updatedB] && combined.merging(removed).progress.isEmpty)
print("PASS: coalesced Vault deltas retain every changed row and yield to later membership")
}
'''
GEOMETRY_PREFIX = r'''import Foundation
import CoreGraphics
@MainActor class UIView {
    var superview: UIView?
    var bounds = CGRect(x: 0, y: 0, width: 100, height: 100)
    var offset = CGPoint.zero
    var alpha: CGFloat = 1
    var isHidden = false
    var clipsToBounds = false
    static var conversions = 0
    var window: UIWindow? { (self as? UIWindow) ?? superview?.window }
    func convert(_ rect: CGRect, to view: UIView?) -> CGRect {
        Self.conversions += 1
        var offset = CGPoint.zero
        var node: UIView? = self
        while let current = node { offset.x += current.offset.x; offset.y += current.offset.y; node = current.superview }
        return rect.offsetBy(dx: offset.x, dy: offset.y)
    }
}
@MainActor final class UIWindow: UIView {}
'''
GEOMETRY_CHECKS = r'''@main struct Checks {
 @MainActor static func main() {
    let window = UIWindow(); window.bounds = CGRect(x: 0, y: 0, width: 400, height: 800)
    let root = UIView(); root.superview = window
    let clip = UIView(); clip.superview = root; clip.clipsToBounds = true
    let rows = (0..<50).map { index in
        let row = UIView(); row.superview = clip
        row.bounds = CGRect(x: 0, y: 0, width: 50, height: 10)
        row.offset = CGPoint(x: index % 4, y: index * 2)
        return row
    }
    func reference(_ view: UIView) -> CGRect {
        var frame = view.convert(view.bounds, to: window).intersection(window.bounds)
        var current: UIView? = view; var alpha: CGFloat = 1
        while let node = current {
            alpha *= node.alpha
            if node.isHidden || alpha <= 0.02 { return .null }
            if node.clipsToBounds { frame = frame.intersection(node.convert(node.bounds, to: window)) }
            current = node.superview
        }
        return frame
    }
    let cache = NBAuroraChromeGeometry()
    for phase in 0..<5 {
        if phase == 1 { root.isHidden = true }
        if phase == 2 { root.isHidden = false; root.alpha = 0.01 }
        if phase == 3 { root.alpha = 0.6; clip.bounds.size.height = 35 }
        if phase == 4 { clip.offset.y = 20; root.offset.x = 5 }
        UIView.conversions = 0
        let expected = rows.map(reference)
        let before = UIView.conversions
        UIView.conversions = 0; cache.beginFrame()
        let actual = rows.map { cache.visibleFrame(of: $0, in: window) }
        precondition(expected == actual)
        if phase == 0 {
            precondition(UIView.conversions < before)
            print("PASS: shared ancestry,",before,"→",UIView.conversions,"rectangle conversions for 50 glyphs")
        }
    }
    print("PASS: exact clipping, stationary ancestor hiding/alpha/resize, and scrolling movement")

    let textCache = NBAuroraTextClipping()
    root.offset = .zero
    clip.offset = .zero
    clip.bounds.size.height = 50
    root.alpha = 0.1
    clip.alpha = 0.1
    UIView.conversions = 0
    for row in rows {
        precondition(textCache.visibleClip(of: row.superview, in: window) == clip.bounds)
    }
    precondition(UIView.conversions == 1)
    textCache.beginFrame()
    root.isHidden = true
    precondition(textCache.visibleClip(of: clip, in: window) == nil)
    textCache.beginFrame()
    root.isHidden = false
    clip.offset.y = 20
    precondition(textCache.visibleClip(of: clip, in: window) == clip.bounds.offsetBy(dx: 0, dy: 20))
    textCache.beginFrame()
    root.alpha = 0.01
    precondition(textCache.visibleClip(of: clip, in: window) == nil)
    print("PASS: adaptive labels share clipping while preserving per-view opacity and current geometry")
 }
}
'''

def main():
    env = dict(os.environ)
    env.setdefault('DEVELOPER_DIR', '/Applications/Xcode.app/Contents/Developer')
    sdk = subprocess.check_output(['xcrun', '--sdk', 'macosx', '--show-sdk-path'], text=True, env=env).strip()
    swift = subprocess.check_output(['xcrun', '--find', 'swiftc'], text=True, env=env).strip()
    facade = (ROOT / 'Asign/Views/Downloader/ViewModels/IPADownloadManager.swift').read_text()
    rows = facade[facade.index('final class ActiveDownloadState'):facade.index('// UI rows are main-queue owned')]
    item = (ROOT / 'Asign/Views/Downloader/Models/DownloadItem.swift').read_text().replace('import SwiftUI', 'import Foundation')
    chrome = (ROOT / 'NimbleKit/Sources/NimbleExtensions/View/NBAuroraChromeObserver.swift').read_text()
    geometry = chrome[chrome.index('@MainActor\nprivate final class NBAuroraChromeGeometry'):chrome.index('private struct NBAuroraChromeCoordinates')]
    transfer = (ROOT / 'Asign/Views/Downloader/ViewModels/IPAVaultTransfer.swift').read_text()
    presentation = transfer[transfer.index('    struct Controls:'):transfer.index('    private let queue')]
    presentation = 'extension IPAVaultTransfer {\n' + presentation + '}\n'
    attachments = (ROOT / 'NimbleKit/Sources/NimbleExtensions/View/NBAuroraTextAttachment.swift').read_text()
    text_cache = attachments[attachments.index('@MainActor\nfinal class NBAuroraTextClipping'):
                             attachments.index('@MainActor\nfinal class NBAuroraTextLayoutClock')]
    text_cache = text_cache.split('@available')[0]
    visibility = (ROOT / 'NimbleKit/Sources/NimbleExtensions/View/NBAuroraTextVisibility.swift').read_text()
    cases = [('rows', ROW_PREFIX + item + rows + presentation + ROW_CHECKS, []),
             ('geometry', GEOMETRY_PREFIX + geometry + visibility + text_cache + GEOMETRY_CHECKS, ['-parse-as-library'])]
    with tempfile.TemporaryDirectory(prefix='asign-presentation-') as directory:
        for name, source, flags in cases:
            path = Path(directory) / (name + '.swift')
            binary = Path(directory) / name
            path.write_text(source)
            subprocess.run([swift, '-swift-version', '5', '-sdk', sdk, *flags, str(path), '-o', str(binary)], env=env, check=True)
            subprocess.run([str(binary)], check=True)

if __name__ == '__main__':
    main()
