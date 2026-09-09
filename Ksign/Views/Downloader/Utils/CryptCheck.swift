//
//  CryptCheck.swift
//  Ksign
//
//  Native port of cryptcheck.py for downloaded IPA files.
//

import Foundation
import SwiftUI
import WebKit
import ZIPFoundation
import NimbleViews

enum CryptCheckError: LocalizedError {
    case invalidArchive
    case noMachOBinaries

    var errorDescription: String? {
        switch self {
        case .invalidArchive:
            return "The selected file could not be opened as an IPA archive."
        case .noMachOBinaries:
            return "No Mach-O binaries were found in this IPA."
        }
    }
}

enum CryptCheckAnalyzer {
    private static let mhMagic32: UInt32 = 0xFEEDFACE
    private static let mhCigam32: UInt32 = 0xCEFAEDFE
    private static let mhMagic64: UInt32 = 0xFEEDFACF
    private static let mhCigam64: UInt32 = 0xCFFAEDFE
    private static let fatMagic: UInt32 = 0xCAFEBABE
    private static let fatCigam: UInt32 = 0xBEBAFECA
    private static let fatMagic64: UInt32 = 0xCAFEBABF
    private static let fatCigam64: UInt32 = 0xBFBAFECA

    private static let lcEncryptionInfo: UInt32 = 0x21
    private static let lcEncryptionInfo64: UInt32 = 0x2C
    private static let lcIDDylib: UInt32 = 0x0D

    private static let allMagics: Set<UInt32> = [
        mhMagic32, mhCigam32, mhMagic64, mhCigam64,
        fatMagic, fatCigam, fatMagic64, fatCigam64,
    ]

    private static let skippedExtensions: Set<String> = [
        "plist", "png", "jpg", "jpeg", "gif", "car", "nib", "storyboardc",
        "strings", "js", "css", "html", "json", "xml", "mom", "momd", "map",
        "metallib", "dat", "db", "lproj", "txt", "md", "ttf", "otf", "woff",
        "woff2", "mp3", "mp4", "wav", "m4a", "caf", "mobileprovision",
        "signature", "xcprivacy",
    ]

    private struct Slice {
        let cpu: String
        let is64Bit: Bool
        let cryptOffset: UInt32
        let cryptSize: UInt32
        let cryptID: UInt32
        let entropy: Double
        let nullPercent: Double
        let printablePercent: Double
        let status: String
        let sample: Data
        let dylibID: String?
    }

    private struct ReportEntry {
        let name: String
        let size: Int
        let slices: [Slice]
    }

    static func generateReport(for ipaURL: URL) throws -> URL {
        guard let archive = try? Archive(url: ipaURL, accessMode: .read) else {
            throw CryptCheckError.invalidArchive
        }

        var entries: [ReportEntry] = []
        let fileManager = FileManager.default
        let hasDecryptedBy = mainInfoPlistHasDecryptedBy(in: archive)

        for entry in archive {
            guard case .file = entry.type else { continue }

            let path = entry.path
            let ext = URL(fileURLWithPath: path).pathExtension.lowercased()
            if skippedExtensions.contains(ext) { continue }

            do {
                var data = Data()
                _ = try archive.extract(entry, consumer: { chunk in
                    data.append(chunk)
                })

                guard isMachO(data) else { continue }

                var displayName = path
                if let payloadRange = displayName.range(of: "Payload/") {
                    displayName = String(displayName[payloadRange.upperBound...])
                }
                entries.append(
                    ReportEntry(
                        name: displayName,
                        size: data.count,
                        slices: analyzeMachO(data)
                    )
                )
            } catch {
                // Match the Python script's behavior: a single unreadable archive
                // entry should not prevent the rest of the IPA from being checked.
                continue
            }
        }

        guard !entries.isEmpty else {
            throw CryptCheckError.noMachOBinaries
        }

        let html = makeHTML(
            entries: entries,
            source: ipaURL.lastPathComponent,
            hasDecryptedBy: hasDecryptedBy
        )
        let reportDirectory = fileManager.temporaryDirectory
            .appendingPathComponent("CryptCheckReports", isDirectory: true)
        try fileManager.createDirectory(at: reportDirectory, withIntermediateDirectories: true)

        let stamp = fileTimestamp()
        let base = ipaURL.deletingPathExtension().lastPathComponent
            .replacingOccurrences(of: "/", with: "_")
        let reportURL = reportDirectory
            .appendingPathComponent("cryptcheck_\(base)_\(stamp).html")
        try html.write(to: reportURL, atomically: true, encoding: .utf8)
        return reportURL
    }

    private static func mainInfoPlistHasDecryptedBy(in archive: Archive) -> Bool {
        for entry in archive {
            guard case .file = entry.type else { continue }

            let components = entry.path.split(separator: "/", omittingEmptySubsequences: true)
            guard
                components.count == 3,
                components[0] == "Payload",
                components[1].hasSuffix(".app"),
                components[2] == "Info.plist"
            else { continue }

            do {
                var data = Data()
                _ = try archive.extract(entry, consumer: { chunk in
                    data.append(chunk)
                })

                if let plist = try PropertyListSerialization.propertyList(
                    from: data,
                    options: [],
                    format: nil
                ) as? [String: Any], plist["DecryptedBy"] != nil {
                    return true
                }
            } catch {
                // A missing or unreadable Info.plist should not prevent the
                // Mach-O report from being generated.
                continue
            }
        }

        return false
    }

    // MARK: - Mach-O parsing

    private static func analyzeMachO(_ data: Data) -> [Slice] {
        guard let magic = u32(data, at: 0, bigEndian: true) else { return [] }
        if [fatMagic, fatCigam, fatMagic64, fatCigam64].contains(magic) {
            return parseFat(data)
        }
        if let slice = parseEncryptionInfo(data, base: 0) {
            return [slice]
        }
        return []
    }

    private static func parseFat(_ data: Data) -> [Slice] {
        guard let magic = u32(data, at: 0, bigEndian: true) else { return [] }

        let bigEndian: Bool
        let isFat64: Bool
        switch magic {
        case fatMagic:
            bigEndian = true; isFat64 = false
        case fatCigam:
            bigEndian = false; isFat64 = false
        case fatMagic64:
            bigEndian = true; isFat64 = true
        case fatCigam64:
            bigEndian = false; isFat64 = true
        default:
            return []
        }

        guard let count = u32(data, at: 4, bigEndian: bigEndian) else { return [] }
        var headerOffset = 8
        var slices: [Slice] = []

        for _ in 0..<Int(count) {
            let sliceOffset: UInt64?
            if isFat64 {
                sliceOffset = u64(data, at: headerOffset + 8, bigEndian: bigEndian)
                headerOffset += 32
            } else {
                sliceOffset = u32(data, at: headerOffset + 8, bigEndian: bigEndian).map(UInt64.init)
                headerOffset += 20
            }

            guard let rawOffset = sliceOffset, rawOffset <= UInt64(Int.max) else { continue }
            if let slice = parseEncryptionInfo(data, base: Int(rawOffset)) {
                slices.append(slice)
            }
        }
        return slices
    }

    private static func parseEncryptionInfo(_ data: Data, base: Int) -> Slice? {
        guard let magic = u32(data, at: base, bigEndian: false) else { return nil }

        let is64Bit: Bool
        let bigEndian: Bool
        switch magic {
        case mhMagic32:
            is64Bit = false; bigEndian = false
        case mhCigam32:
            is64Bit = false; bigEndian = true
        case mhMagic64:
            is64Bit = true; bigEndian = false
        case mhCigam64:
            is64Bit = true; bigEndian = true
        default:
            return nil
        }

        guard
            let cpuValue = u32(data, at: base + 4, bigEndian: bigEndian),
            let commandCount = u32(data, at: base + 16, bigEndian: bigEndian)
        else { return nil }

        var commandOffset = base + (is64Bit ? 32 : 28)
        var encryptionSlice: Slice?
        var dylibID: String?

        for _ in 0..<Int(commandCount) {
            guard
                let command = u32(data, at: commandOffset, bigEndian: bigEndian),
                let commandSizeRaw = u32(data, at: commandOffset + 4, bigEndian: bigEndian)
            else { break }

            let commandSize = Int(commandSizeRaw)
            guard commandSize >= 8, commandOffset <= data.count - 8 else { break }

            if command == lcEncryptionInfo || command == lcEncryptionInfo64 {
                guard
                    let cryptOffset = u32(data, at: commandOffset + 8, bigEndian: bigEndian),
                    let cryptSize = u32(data, at: commandOffset + 12, bigEndian: bigEndian),
                    let cryptID = u32(data, at: commandOffset + 16, bigEndian: bigEndian)
                else {
                    commandOffset += commandSize
                    continue
                }

                let regionStart64 = UInt64(base) + UInt64(cryptOffset)
                let sample: Data
                if regionStart64 <= UInt64(data.count), regionStart64 <= UInt64(Int.max) {
                    let regionStart = Int(regionStart64)
                    let requestedEnd = regionStart64 + UInt64(cryptSize)
                    let regionEnd = Int(min(UInt64(data.count), min(requestedEnd, UInt64(Int.max))))
                    if regionStart < regionEnd {
                        sample = data.subdata(in: regionStart..<min(regionEnd, regionStart + 4096))
                    } else {
                        sample = Data()
                    }
                } else {
                    sample = Data()
                }

                let entropyValue = entropy(sample)
                let nullValue = nullPercent(sample)
                let printableValue = printablePercent(sample)
                let status: String

                if cryptID != 0 {
                    status = "ENCRYPTED"
                } else if cryptSize == 0 || sample.isEmpty {
                    status = "DECRYPTED"
                } else if entropyValue > 7.9 && nullValue < 1.0 {
                    status = "ENCRYPTED"
                } else if entropyValue > 7.5 && nullValue < 2.0 {
                    status = "LIKELY ENC"
                } else if entropyValue < 7.0 || nullValue > 5.0 {
                    status = "DECRYPTED"
                } else {
                    status = "LIKELY ENC"
                }

                encryptionSlice = Slice(
                    cpu: cpuName(cpuValue),
                    is64Bit: is64Bit,
                    cryptOffset: cryptOffset,
                    cryptSize: cryptSize,
                    cryptID: cryptID,
                    entropy: entropyValue,
                    nullPercent: nullValue,
                    printablePercent: printableValue,
                    status: status,
                    sample: sample,
                    dylibID: nil
                )
            } else if command == lcIDDylib,
                      let nameOffsetRaw = u32(data, at: commandOffset + 8, bigEndian: bigEndian) {
                let nameStart = commandOffset + Int(nameOffsetRaw)
                if nameStart >= 0, nameStart < data.count {
                    let bytes = [UInt8](data[nameStart..<data.count])
                    let end = bytes.firstIndex(of: 0) ?? bytes.count
                    dylibID = String(decoding: bytes[..<end], as: UTF8.self)
                }
            }

            if commandSize > data.count - commandOffset { break }
            commandOffset += commandSize
        }

        guard let slice = encryptionSlice else { return nil }
        return Slice(
            cpu: slice.cpu,
            is64Bit: slice.is64Bit,
            cryptOffset: slice.cryptOffset,
            cryptSize: slice.cryptSize,
            cryptID: slice.cryptID,
            entropy: slice.entropy,
            nullPercent: slice.nullPercent,
            printablePercent: slice.printablePercent,
            status: slice.status,
            sample: slice.sample,
            dylibID: dylibID
        )
    }

    private static func isMachO(_ data: Data) -> Bool {
        guard data.count >= 4 else { return false }
        let big = u32(data, at: 0, bigEndian: true)
        let little = u32(data, at: 0, bigEndian: false)
        return (big.map { allMagics.contains($0) } ?? false)
            || (little.map { allMagics.contains($0) } ?? false)
    }

    private static func cpuName(_ value: UInt32) -> String {
        switch value {
        case 7: return "x86"
        case 12: return "ARM"
        case 16_777_223: return "x86_64"
        case 16_777_228: return "ARM64"
        default: return "?\(value)"
        }
    }

    private static func u32(_ data: Data, at offset: Int, bigEndian: Bool) -> UInt32? {
        guard offset >= 0, offset <= data.count - 4 else { return nil }
        let bytes = [UInt8](data[offset..<(offset + 4)])
        if bigEndian {
            return (UInt32(bytes[0]) << 24)
                | (UInt32(bytes[1]) << 16)
                | (UInt32(bytes[2]) << 8)
                | UInt32(bytes[3])
        }
        return UInt32(bytes[0])
            | (UInt32(bytes[1]) << 8)
            | (UInt32(bytes[2]) << 16)
            | (UInt32(bytes[3]) << 24)
    }

    private static func u64(_ data: Data, at offset: Int, bigEndian: Bool) -> UInt64? {
        guard offset >= 0, offset <= data.count - 8 else { return nil }
        let bytes = [UInt8](data[offset..<(offset + 8)])
        var value: UInt64 = 0
        if bigEndian {
            for byte in bytes { value = (value << 8) | UInt64(byte) }
        } else {
            for byte in bytes.reversed() { value = (value << 8) | UInt64(byte) }
        }
        return value
    }

    // MARK: - Sample analysis

    private static func entropy(_ data: Data) -> Double {
        guard !data.isEmpty else { return 0 }
        var frequencies = Array(repeating: 0, count: 256)
        for byte in data { frequencies[Int(byte)] += 1 }
        let count = Double(data.count)
        return -frequencies.reduce(0.0) { result, frequency in
            guard frequency > 0 else { return result }
            let p = Double(frequency) / count
            return result + p * log2(p)
        }
    }

    private static func nullPercent(_ data: Data) -> Double {
        guard !data.isEmpty else { return 0 }
        let nulls = data.reduce(0) { $0 + ($1 == 0 ? 1 : 0) }
        return Double(nulls) / Double(data.count) * 100.0
    }

    private static func printablePercent(_ data: Data) -> Double {
        guard !data.isEmpty else { return 0 }
        let printable = data.reduce(0) { count, byte in
            count + ((0x20...0x7E).contains(byte) ? 1 : 0)
        }
        return Double(printable) / Double(data.count) * 100.0
    }

    private static func countStrings(_ data: Data, minimumLength: Int = 4) -> Int {
        var count = 0
        var run = 0
        for byte in data {
            if (0x20...0x7E).contains(byte) {
                run += 1
            } else {
                if run >= minimumLength { count += 1 }
                run = 0
            }
        }
        if run >= minimumLength { count += 1 }
        return count
    }

    private static let opLabels: [String: String] = [
        "BL": "function calls",
        "B": "branches",
        "STP": "stack pushes",
        "LDP": "stack pops",
        "ADD": "additions",
        "SUB": "subtractions",
        "MOV": "register moves",
        "LDR": "memory loads",
        "STR": "memory stores",
        "RET": "returns",
        "NOP": "no-ops",
        "CBZ": "zero-checks",
        "CBNZ": "nonzero-checks",
        "TBZ": "bit tests",
        "TBNZ": "bit tests",
        "ADRP": "address calcs",
    ]

    private static func arm64Map(_ data: Data) -> (counts: [String: Int], positions: [Int: String]) {
        var counts: [String: Int] = [:]
        var positions: [Int: String] = [:]
        let bytes = [UInt8](data)
        guard bytes.count >= 4 else { return (counts, positions) }

        for offset in stride(from: 0, through: bytes.count - 4, by: 4) {
            let word = UInt32(bytes[offset])
                | (UInt32(bytes[offset + 1]) << 8)
                | (UInt32(bytes[offset + 2]) << 16)
                | (UInt32(bytes[offset + 3]) << 24)
            let top = UInt8((word >> 24) & 0xFF)

            let name: String?
            switch top {
            case 0x94, 0x97: name = "BL"
            case 0x14, 0x17: name = "B"
            case 0xA9, 0xA8: name = "STP"
            case 0x6D, 0x6C: name = "LDP"
            case _ where (top & 0xFE) == 0x11 || (top & 0xFE) == 0x91: name = "ADD"
            case _ where (top & 0xFE) == 0x51 || (top & 0xFE) == 0xD1: name = "SUB"
            case 0xD2, 0xF2, 0x52, 0x72, 0x92, 0x12: name = "MOV"
            case 0xF9, 0xB9, 0x39, 0x79, 0xF8, 0xB8: name = "LDR"
            case 0x38, 0x78: name = "STR"
            case _ where word == 0xD65F03C0: name = "RET"
            case _ where word == 0xD503201F: name = "NOP"
            case 0x34, 0xB4: name = "CBZ"
            case 0x35, 0xB5: name = "CBNZ"
            case 0x36, 0xB6: name = "TBZ"
            case 0x37, 0xB7: name = "TBNZ"
            case _ where (top & 0x9F) == 0x90: name = "ADRP"
            default: name = nil
            }

            if let name {
                counts[name, default: 0] += 1
                for byteOffset in offset..<(offset + 4) {
                    positions[byteOffset] = name
                }
            }
        }
        return (counts, positions)
    }

    // MARK: - HTML report

    private static func makeHTML(entries: [ReportEntry], source: String, hasDecryptedBy: Bool) -> String {
        let now = displayTimestamp()
        var decryptedCount = 0
        var encryptedCount = 0
        var likelyCount = 0
        var allNames: [String] = []
        var decryptedNames: [String] = []
        var encryptedNames: [String] = []
        var likelyNames: [String] = []

        for entry in entries {
            allNames.append(entry.name)
            for slice in entry.slices {
                switch slice.status {
                case "ENCRYPTED":
                    encryptedCount += 1
                    appendUnique(entry.name, to: &encryptedNames)
                case "DECRYPTED":
                    decryptedCount += 1
                    appendUnique(entry.name, to: &decryptedNames)
                default:
                    if slice.status.contains("LIKELY") {
                        likelyCount += 1
                        appendUnique(entry.name, to: &likelyNames)
                    }
                }
            }
        }

        let cards = entries.map { entry -> String in
            let slicesHTML: String
            if entry.slices.isEmpty {
                slicesHTML = "<div class=\"no-enc\">No LC_ENCRYPTION_INFO</div>"
            } else {
                slicesHTML = entry.slices.enumerated().map { sliceHTML($0.element, index: $0.offset) }.joined()
            }
            return """
            <div class="card" id="\(cardID(entry.name))">
              <div class="card-head">&#x1F4E6; \(escapeHTML(entry.name))</div>
              <div class="card-size">\(formattedInteger(entry.size)) bytes</div>
              \(slicesHTML)
            </div>
            """
        }.joined(separator: "\n")

        return """
        <!DOCTYPE html>
        <html lang="en">
        <head>
        <meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1, viewport-fit=cover">
        <title>cryptcheck report — \(escapeHTML(now))</title>
        <style>
          :root {
            color-scheme: dark;
            --bg:#0a0a0f; --card:#12121a; --border:#1e1e2e; --text:#c8c8d4;
            --dim:#66667a; --green:#4ade80; --red:#f87171; --orange:#fb923c;
            --cyan:#22d3ee; --pink:#f472b6; --purple:#a78bfa; --blue:#60a5fa;
            --lime:#a3e635;
          }
          * { box-sizing:border-box; }
          html { scroll-behavior:smooth; }
          body {
            margin:0; background:var(--bg); color:var(--text);
            font-family:-apple-system,BlinkMacSystemFont,"SF Pro Text",sans-serif;
            padding:22px 16px calc(60px + env(safe-area-inset-bottom));
            -webkit-text-size-adjust:100%;
          }
          .header { position:relative; border-bottom:1px solid var(--border); padding:0 40px 18px 0; margin-bottom:22px; }
          .header h1 { margin:0; font-family:ui-monospace,SFMono-Regular,Menlo,monospace; font-size:1.28rem; color:var(--cyan); }
          .decrypted-by-marker { position:absolute; top:0; right:0; font:800 1.65rem/1 ui-monospace,SFMono-Regular,Menlo,monospace; }
          .decrypted-by-present { color:var(--green); }
          .decrypted-by-absent { color:var(--red); }
          .sub { color:var(--dim); font-size:.78rem; margin-top:5px; }
          .source { color:var(--text); font-size:.86rem; margin-top:8px; word-break:break-all; }
          .summary { display:grid; grid-template-columns:repeat(2,1fr); gap:10px; margin-bottom:26px; overflow:visible; }
          @media (min-width:500px) { .summary { grid-template-columns:repeat(4,1fr); } }
          .stat {
            position:relative; text-align:center; padding:14px 10px; border-radius:14px;
            background:linear-gradient(180deg,rgba(255,255,255,.04),rgba(255,255,255,.01)),var(--card);
            border:1px solid var(--border); -webkit-tap-highlight-color:transparent;
          }
          .stat-btn { cursor:pointer; }
          .stat.active { border-color:rgba(255,255,255,.2); z-index:20; }
          .num { font:700 1.55rem ui-monospace,SFMono-Regular,Menlo,monospace; line-height:1; }
          .lbl { color:var(--dim); font-size:.67rem; text-transform:uppercase; letter-spacing:.06em; margin-top:5px; }
          .num-dec{color:var(--green)} .num-enc{color:var(--red)} .num-likely{color:var(--orange)}
          .dropdown {
            position:absolute; visibility:hidden; opacity:0; pointer-events:none; left:50%; top:calc(100% + 9px);
            transform:translateX(-50%) translateY(5px); min-width:270px; max-width:92vw; max-height:360px;
            overflow:auto; background:rgba(22,22,35,.96); border:.5px solid rgba(255,255,255,.18);
            border-radius:18px; padding:5px 0; box-shadow:0 16px 44px rgba(0,0,0,.5); text-align:left;
            transition:opacity .16s ease, transform .16s ease;
          }
          .stat.active .dropdown { visibility:visible; opacity:1; pointer-events:auto; transform:translateX(-50%) translateY(0); }
          .filter-bar { display:flex; gap:6px; flex-wrap:wrap; padding:9px 11px 8px; border-bottom:.5px solid rgba(255,255,255,.07); }
          .filter-pill { border:.5px solid rgba(255,255,255,.09); border-radius:100px; padding:5px 12px; background:rgba(255,255,255,.05); color:var(--dim); font:600 .67rem -apple-system,BlinkMacSystemFont,"SF Pro Text",sans-serif; }
          .filter-pill.active { background:rgba(255,255,255,.16); border-color:rgba(255,255,255,.24); color:#fff; }
          .dd-item { display:flex; gap:8px; padding:11px 14px; color:var(--text); text-decoration:none; font: .73rem ui-monospace,SFMono-Regular,Menlo,monospace; word-break:break-all; border-bottom:.5px solid rgba(255,255,255,.04); }
          .dd-item:last-child{border-bottom:0}.dd-item.dd-hidden{display:none}.dd-icon{color:var(--dim);width:13px;text-align:center}.dd-empty{padding:16px;color:var(--dim);font-size:.75rem;text-align:center}
          .card { scroll-margin-top:16px; background:var(--card); border:1px solid var(--border); border-radius:13px; padding:18px 16px; margin-bottom:16px; }
          .card-head { font:700 .84rem ui-monospace,SFMono-Regular,Menlo,monospace; word-break:break-all; }
          .card-size { color:var(--dim); font-size:.73rem; margin:3px 0 12px; }
          .no-enc { color:var(--dim); font-size:.8rem; font-style:italic; }
          .slice { border-top:1px solid var(--border); padding-top:14px; margin-top:14px; }
          .slice:first-of-type { border-top:0; padding-top:0; margin-top:0; }
          .slice-head { color:var(--dim); font:700 .78rem ui-monospace,SFMono-Regular,Menlo,monospace; }
          .tag { display:inline-block; font:700 .83rem ui-monospace,SFMono-Regular,Menlo,monospace; padding:4px 10px; border-radius:7px; margin:7px 0 10px; }
          .status-dec{background:rgba(74,222,128,.12);color:var(--green)}
          .status-enc{background:rgba(248,113,113,.12);color:var(--red)}
          .status-likely{background:rgba(251,146,60,.12);color:var(--orange)}
          .meta { display:flex; gap:14px; flex-wrap:wrap; color:var(--dim); font:.7rem ui-monospace,SFMono-Regular,Menlo,monospace; margin-bottom:10px; }
          .entropy-row{display:flex;align-items:center;gap:10px;margin-bottom:7px}.entropy-bar{flex:1;height:6px;background:var(--border);border-radius:4px;overflow:hidden}.entropy-fill{height:100%;background:linear-gradient(90deg,var(--green),var(--orange),var(--red))}.entropy-val{white-space:nowrap;color:var(--dim);font:.7rem ui-monospace,SFMono-Regular,Menlo,monospace}
          .stats{color:var(--dim);font-size:.74rem;margin-bottom:9px}.instr{border-collapse:collapse;margin:8px 0;font-size:.74rem}.instr td{padding:2px 10px 2px 0}.op-name{font-family:ui-monospace,SFMono-Regular,Menlo,monospace;font-weight:700;color:var(--cyan)}.op-desc{color:var(--dim)}.op-count{font-family:ui-monospace,SFMono-Regular,Menlo,monospace}
          .verdict{font:700 .83rem ui-monospace,SFMono-Regular,Menlo,monospace;margin:10px 0 6px}.verdict-ok{color:var(--green)}.verdict-enc{color:var(--red)}.verdict-stub,.verdict-unk{color:var(--orange)}.verdict .dim{font-weight:400;font-size:.7rem;color:var(--dim)}
          .hex-details{margin-top:8px}.hex-details summary{color:var(--dim);font-size:.74rem;cursor:pointer}.hex{font:.64rem/1.5 ui-monospace,SFMono-Regular,Menlo,monospace;overflow-x:auto;margin-top:6px}.dim{color:var(--dim)}.print{color:var(--green)}.high{color:var(--red)}
          .op-bl,.op-b,.op-adrp{color:var(--cyan)}.op-stp,.op-ldp,.op-cbz,.op-cbnz,.op-tbz,.op-tbnz{color:var(--pink)}.op-add,.op-sub{color:var(--blue)}.op-mov{color:var(--purple)}.op-ldr,.op-str{color:var(--orange)}.op-ret{color:var(--lime)}.op-nop{color:var(--dim)}
        </style>
        </head>
        <body>
          <div class="header">
            <h1>&#x1F510; cryptcheck</h1>
            <div
              class="decrypted-by-marker \(hasDecryptedBy ? "decrypted-by-present" : "decrypted-by-absent")"
              title="DecryptedBy \(hasDecryptedBy ? "present" : "absent")"
              aria-label="DecryptedBy \(hasDecryptedBy ? "present" : "absent")"
            >\(hasDecryptedBy ? "&#x2713;" : "&#x2715;")</div>
            <div class="sub">\(escapeHTML(now))</div>
            <div class="source">\(escapeHTML(source))</div>
          </div>
          <div class="summary">
            \(summaryCard(number: entries.count, label: "Binaries", cssClass: "", names: allNames))
            \(summaryCard(number: decryptedCount, label: "Decrypted", cssClass: "num-dec", names: decryptedNames))
            \(summaryCard(number: encryptedCount, label: "Encrypted", cssClass: "num-enc", names: encryptedNames))
            \(summaryCard(number: likelyCount, label: "Likely Enc", cssClass: "num-likely", names: likelyNames))
          </div>
          \(cards)
        <script>
        (function(){
          window.toggleDD=function(el,e){
            if(e&&e.target.closest&&e.target.closest('.dropdown')) return;
            var was=el.classList.contains('active');
            document.querySelectorAll('.stat.active').forEach(function(s){s.classList.remove('active');});
            if(!was) el.classList.add('active');
          };
          window.filterDD=function(pill,e){
            e.stopPropagation();
            var bar=pill.closest('.filter-bar');
            bar.querySelectorAll('.filter-pill').forEach(function(p){p.classList.remove('active');});
            pill.classList.add('active');
            var kind=pill.getAttribute('data-filter');
            var dd=pill.closest('.dropdown');
            dd.querySelectorAll('.dd-item').forEach(function(item){
              if(kind==='all'||item.getAttribute('data-kind')===kind) item.classList.remove('dd-hidden');
              else item.classList.add('dd-hidden');
            });
          };
          document.addEventListener('click',function(e){
            if(!e.target.closest('.stat')) document.querySelectorAll('.stat.active').forEach(function(s){s.classList.remove('active');});
          });
          document.querySelectorAll('.dd-item').forEach(function(a){
            a.addEventListener('click',function(e){
              e.stopPropagation();
              document.querySelectorAll('.stat.active').forEach(function(s){s.classList.remove('active');});
              var t=document.getElementById(a.getAttribute('href').substring(1));
              if(t){e.preventDefault();t.scrollIntoView({behavior:'smooth',block:'start'});}
            });
          });
        })();
        </script>
        </body>
        </html>
        """
    }

    private static func sliceHTML(_ slice: Slice, index: Int) -> String {
        let mapping = arm64Map(slice.sample)
        let totalARM = mapping.counts.values.reduce(0, +)
        let strings = countStrings(slice.sample)
        let isStub = slice.status == "DECRYPTED"
            && totalARM == 0
            && strings == 0
            && (slice.nullPercent > 95.0 || slice.sample.isEmpty)

        let tagClass: String
        let icon: String
        switch slice.status {
        case "DECRYPTED": tagClass = "status-dec"; icon = "&#x2705;"
        case "ENCRYPTED": tagClass = "status-enc"; icon = "&#x1F512;"
        default: tagClass = "status-likely"; icon = "&#x26A0;&#xFE0F;"
        }

        let instructionHTML: String
        if totalARM > 0 && slice.status == "DECRYPTED" {
            let rows = mapping.counts
                .sorted { lhs, rhs in
                    lhs.value == rhs.value ? lhs.key < rhs.key : lhs.value > rhs.value
                }
                .prefix(6)
                .map { name, count in
                    "<tr><td class=\"op-name\">\(escapeHTML(name))</td><td class=\"op-desc\">\(escapeHTML(opLabels[name] ?? name))</td><td class=\"op-count\">x\(count)</td></tr>"
                }
                .joined()
            instructionHTML = "<table class=\"instr\">\(rows)</table>"
        } else {
            instructionHTML = ""
        }

        let verdict: String
        let verdictClass: String
        if slice.status == "DECRYPTED" {
            if isStub {
                verdictClass = "verdict-stub"
                if let dylibID = slice.dylibID, !dylibID.isEmpty {
                    verdict = "Stub framework (null-padded)<br><span class=\"dim\">install name: \(escapeHTML(dylibID))</span>"
                } else {
                    verdict = "Stub framework (null-padded)"
                }
            } else {
                verdictClass = "verdict-ok"
                verdict = "Real code"
            }
        } else if slice.status == "ENCRYPTED" {
            verdictClass = "verdict-enc"
            verdict = "Ciphertext"
        } else {
            verdictClass = "verdict-unk"
            verdict = "Inconclusive"
        }

        let entropyWidth = max(0, min(100, slice.entropy / 8.0 * 100.0))
        var stats = String(format: "Null %.1f%% &nbsp;&middot;&nbsp; Print %.1f%%", slice.nullPercent, slice.printablePercent)
        if totalARM > 0 { stats += " &nbsp;&middot;&nbsp; ARM64 x\(totalARM)" }
        if strings > 0 { stats += " &nbsp;&middot;&nbsp; Strings x\(strings)" }

        return """
        <div class="slice">
          <div class="slice-head">Slice \(index + 1): \(escapeHTML(slice.cpu)) (\(slice.is64Bit ? "64" : "32")-bit)</div>
          <div class="tag \(tagClass)">\(icon) \(escapeHTML(slice.status))</div>
          <div class="meta">
            <span>cryptid \(slice.cryptID)</span>
            <span>offset 0x\(String(slice.cryptOffset, radix: 16, uppercase: true))</span>
            <span>size 0x\(String(slice.cryptSize, radix: 16, uppercase: true))</span>
          </div>
          <div class="entropy-row">
            <div class="entropy-bar"><div class="entropy-fill" style="width:\(String(format: "%.1f", entropyWidth))%"></div></div>
            <span class="entropy-val">\(String(format: "%.2f", slice.entropy)) / 8.0</span>
          </div>
          <div class="stats">\(stats)</div>
          \(instructionHTML)
          <div class="verdict \(verdictClass)">&#x2192; \(verdict)</div>
          <details class="hex-details">
            <summary>Hex preview</summary>
            <pre class="hex">\(hexPreviewHTML(slice.sample, positions: mapping.positions))</pre>
          </details>
        </div>
        """
    }

    private static func hexPreviewHTML(_ data: Data, positions: [Int: String]) -> String {
        let bytes = [UInt8](data)
        guard !bytes.isEmpty else { return "" }
        let bytesPerLine = 12
        let maximum = 48

        var skip = 0
        if let firstNonNull = bytes.firstIndex(where: { $0 != 0 }) {
            skip = (firstNonNull / bytesPerLine) * bytesPerLine
        }

        var selected = Array(bytes.dropFirst(skip).prefix(maximum))
        if selected.isEmpty {
            selected = Array(bytes.prefix(maximum))
            skip = 0
        }

        var lines: [String] = []
        if skip > 0 {
            lines.append("<span class=\"dim\">(+0x\(String(skip, radix: 16, uppercase: true)), skipped \(skip) null bytes)</span>")
        }

        for rowStart in stride(from: 0, to: selected.count, by: bytesPerLine) {
            let row = Array(selected[rowStart..<min(rowStart + bytesPerLine, selected.count)])
            var hexParts: [String] = []
            var asciiParts: [String] = []

            for (index, byte) in row.enumerated() {
                let position = skip + rowStart + index
                let hex = String(format: "%02x", byte)
                if byte == 0 {
                    hexParts.append("<span class=\"dim\">00</span>")
                    asciiParts.append("<span class=\"dim\">.</span>")
                } else if let op = positions[position] {
                    let css = "op-\(op.lowercased())"
                    hexParts.append("<span class=\"\(css)\">\(hex)</span>")
                    let char = (0x20...0x7E).contains(byte) ? escapeHTML(String(UnicodeScalar(byte))) : "."
                    asciiParts.append("<span class=\"\(css)\">\(char)</span>")
                } else if (0x20...0x7E).contains(byte) {
                    hexParts.append("<span class=\"print\">\(hex)</span>")
                    asciiParts.append("<span class=\"print\">\(escapeHTML(String(UnicodeScalar(byte))))</span>")
                } else if byte >= 0xF0 {
                    hexParts.append("<span class=\"high\">\(hex)</span>")
                    asciiParts.append("<span class=\"dim\">.</span>")
                } else {
                    hexParts.append(hex)
                    asciiParts.append("<span class=\"dim\">.</span>")
                }
            }
            lines.append(hexParts.joined(separator: " ") + "  " + asciiParts.joined())
        }
        return lines.joined(separator: "<br>")
    }

    private static func summaryCard(number: Int, label: String, cssClass: String, names: [String]) -> String {
        let dropdownContent: String
        if names.isEmpty {
            dropdownContent = "<div class=\"dd-empty\">None</div>"
        } else {
            let presentKinds = ["main", "framework", "plugin"].filter { kind in
                names.contains { binaryKind($0) == kind }
            }

            let filterBar: String
            if presentKinds.count > 1 {
                let labels = ["main": "Main", "framework": "Frameworks", "plugin": "Plugins"]
                let extraPills = presentKinds.map { kind in
                    "<button class=\"filter-pill\" data-filter=\"\(kind)\" onclick=\"filterDD(this,event)\">\(labels[kind] ?? kind)</button>"
                }.joined()
                filterBar = "<div class=\"filter-bar\"><button class=\"filter-pill active\" data-filter=\"all\" onclick=\"filterDD(this,event)\">All</button>\(extraPills)</div>"
            } else {
                filterBar = ""
            }

            let items = names.map { name in
                let kind = binaryKind(name)
                let icon: String
                switch kind {
                case "framework": icon = "&#x25CB;"
                case "plugin": icon = "&#x25CE;"
                default: icon = "&#x25C9;"
                }
                let shortName = name.split(separator: "/").last.map(String.init) ?? name
                return "<a class=\"dd-item\" data-kind=\"\(kind)\" href=\"#\(cardID(name))\"><span class=\"dd-icon\">\(icon)</span>\(escapeHTML(shortName))</a>"
            }.joined(separator: "\n")
            dropdownContent = filterBar + items
        }

        return """
        <div class="stat stat-btn" onclick="toggleDD(this,event)">
          <div class="num \(cssClass)">\(number)</div>
          <div class="lbl">\(escapeHTML(label))</div>
          <div class="dropdown">\(dropdownContent)</div>
        </div>
        """
    }

    private static func binaryKind(_ name: String) -> String {
        let lower = name.lowercased()
        if lower.contains("/frameworks/") || lower.contains(".framework/") { return "framework" }
        if lower.contains("/plugins/") || lower.contains(".appex/") { return "plugin" }
        return "main"
    }

    private static func cardID(_ name: String) -> String {
        var hash: UInt64 = 14_695_981_039_346_656_037
        for byte in name.utf8 {
            hash ^= UInt64(byte)
            hash &*= 1_099_511_628_211
        }
        return "card-\(String(hash, radix: 16))"
    }

    private static func appendUnique(_ name: String, to names: inout [String]) {
        if !names.contains(name) { names.append(name) }
    }

    private static func formattedInteger(_ value: Int) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return formatter.string(from: NSNumber(value: value)) ?? String(value)
    }

    private static func escapeHTML(_ string: String) -> String {
        string
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&#39;")
    }

    private static func displayTimestamp() -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return formatter.string(from: Date())
    }

    private static func fileTimestamp() -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd_HHmmss"
        return formatter.string(from: Date())
    }
}

struct CryptCheckReportView: View {
    let reportURL: URL

    @Environment(\.dismiss) private var dismiss
    @State private var showExporter = false

    var body: some View {
        NavigationView {
            CryptCheckHTMLView(url: reportURL)
                .ignoresSafeArea(edges: .bottom)
                .navigationTitle("Crypt Check")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .navigationBarLeading) {
                        Button("Close") { dismiss() }
                    }
                    ToolbarItem(placement: .navigationBarTrailing) {
                        Button("Save") { showExporter = true }
                    }
                }
        }
        .sheet(isPresented: $showExporter) {
            FileExporterRepresentableView(
                urlsToExport: [reportURL],
                asCopy: true,
                useLastLocation: false,
                onCompletion: { _ in showExporter = false }
            )
        }
        .onDisappear {
            // The report is deliberately temporary. Saving exports a copy;
            // closing without saving leaves nothing behind in the app container.
            try? FileManager.default.removeItem(at: reportURL)
        }
    }
}

private struct CryptCheckHTMLView: UIViewRepresentable {
    let url: URL

    func makeUIView(context: Context) -> WKWebView {
        let webView = WKWebView(frame: .zero)
        webView.isOpaque = false
        webView.backgroundColor = .black
        webView.scrollView.backgroundColor = .black
        webView.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())
        return webView
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {}
}
