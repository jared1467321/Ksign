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

    private static let lcSegment: UInt32 = 0x01
    private static let lcIDDylib: UInt32 = 0x0D
    private static let lcSegment64: UInt32 = 0x19
    private static let lcEncryptionInfo: UInt32 = 0x21
    private static let lcEncryptionInfo64: UInt32 = 0x2C
    private static let lcMain: UInt32 = 0x80000028

    private static let allMagics: Set<UInt32> = [
        mhMagic32, mhCigam32, mhMagic64, mhCigam64,
        fatMagic, fatCigam, fatMagic64, fatCigam64,
    ]

    // Preserve the existing obvious-resource exclusions. Everything else is
    // magic-probed, so speedups do not depend on trusting a filename extension.
    private static let skippedExtensions: Set<String> = [
        "plist", "png", "jpg", "jpeg", "gif", "car", "nib", "storyboardc",
        "strings", "js", "css", "html", "json", "xml", "mom", "momd", "map",
        "metallib", "dat", "db", "lproj", "txt", "md", "ttf", "otf", "woff",
        "woff2", "mp3", "mp4", "wav", "m4a", "caf", "mobileprovision",
        "signature", "xcprivacy",
    ]

    // Keep binaries in RAM when that is comfortably cheap for the device. Very
    // large binaries spill to a temporary memory map, avoiding jetsam without
    // penalizing high-memory devices that are faster scanning resident bytes.
    private static var memoryResidentThreshold: UInt64 {
        let minimum: UInt64 = 128 * 1024 * 1024
        let maximum: UInt64 = 1024 * 1024 * 1024
        let adaptive = ProcessInfo.processInfo.physicalMemory / 8
        return min(maximum, max(minimum, adaptive))
    }
    private static let archiveBufferSize = 1024 * 1024
    private static let previewWindowSize: UInt64 = 4096

    private enum PrefixProbeComplete: Error {
        case done
    }

    private struct Slice {
        let cpu: String
        let isARM64: Bool
        let is64Bit: Bool
        let cpuSubtype: UInt32
        let sliceOffset: UInt64
        let sliceSize: UInt64

        let cryptOffset: UInt64?
        let cryptSize: UInt64?
        let cryptID: UInt32?
        let bytesAnalyzed: UInt64
        let entropy: Double
        let nullPercent: Double
        let printablePercent: Double
        let stringCount: UInt64
        let status: String?
        let preview: Data
        let previewBaseOffset: UInt64
        let dylibID: String?
        let rangeIssue: String?

        let textSize: UInt64
        let entryOffset: UInt64?
    }

    private struct ReportEntry {
        let name: String
        let size: UInt64
        let slices: [Slice]
    }

    private struct RegionAnalysis {
        let bytesAnalyzed: UInt64
        let entropy: Double
        let nullPercent: Double
        let printablePercent: Double
        let stringCount: UInt64
        let preview: Data
        let previewBaseOffset: UInt64
    }

    static func generateReport(for ipaURL: URL) throws -> URL {
        guard let archive = try? Archive(url: ipaURL, accessMode: .read) else {
            throw CryptCheckError.invalidArchive
        }

        var entries: [ReportEntry] = []
        let fileManager = FileManager.default
        let hasDecryptedBy = mainInfoPlistHasDecryptedBy(in: archive)

        for entry in archive {
            guard case .file = entry.type, entry.uncompressedSize >= 4 else { continue }

            let path = entry.path
            let ext = URL(fileURLWithPath: path).pathExtension.lowercased()
            if skippedExtensions.contains(ext) { continue }

            do {
                // The old implementation inflated every candidate file completely
                // before learning whether it was Mach-O. A four-byte early-abort
                // probe makes file-heavy Python/shell apps dramatically cheaper.
                let prefix = try readEntryPrefix(entry, from: archive, byteCount: 4)
                guard isMachO(prefix) else { continue }

                let slices = try analyzeArchiveEntry(entry, from: archive)

                var displayName = path
                if let payloadRange = displayName.range(of: "Payload/") {
                    displayName = String(displayName[payloadRange.upperBound...])
                }
                entries.append(
                    ReportEntry(
                        name: displayName,
                        size: entry.uncompressedSize,
                        slices: slices
                    )
                )
            } catch {
                // A single unreadable entry should not prevent the rest of the IPA
                // from being checked.
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

    private static func readEntryPrefix(
        _ entry: Entry,
        from archive: Archive,
        byteCount: Int
    ) throws -> Data {
        guard byteCount > 0 else { return Data() }

        var prefix = Data()
        prefix.reserveCapacity(byteCount)

        do {
            _ = try archive.extract(
                entry,
                bufferSize: byteCount,
                skipCRC32: true,
                consumer: { chunk in
                    let remaining = byteCount - prefix.count
                    if remaining > 0 {
                        prefix.append(contentsOf: chunk.prefix(remaining))
                    }
                    if prefix.count >= byteCount {
                        throw PrefixProbeComplete.done
                    }
                }
            )
        } catch PrefixProbeComplete.done {
            // Expected: abort decompression as soon as the magic bytes are read.
        }

        return prefix
    }

    private static func analyzeArchiveEntry(_ entry: Entry, from archive: Archive) throws -> [Slice] {
        let size = entry.uncompressedSize

        if size <= memoryResidentThreshold, size <= UInt64(Int.max) {
            var data = Data()
            data.reserveCapacity(Int(size))
            _ = try archive.extract(
                entry,
                bufferSize: archiveBufferSize,
                skipCRC32: true,
                consumer: { data.append($0) }
            )
            return analyzeMachO(data)
        }

        let fileManager = FileManager.default
        let directory = fileManager.temporaryDirectory
            .appendingPathComponent("CryptCheckScan", isDirectory: true)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        let temporaryURL = directory.appendingPathComponent(UUID().uuidString, isDirectory: false)
        defer { try? fileManager.removeItem(at: temporaryURL) }

        _ = try archive.extract(
            entry,
            to: temporaryURL,
            bufferSize: archiveBufferSize,
            skipCRC32: true
        )
        let mapped = try Data(contentsOf: temporaryURL, options: [.mappedIfSafe])
        return analyzeMachO(mapped)
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
                if entry.uncompressedSize <= UInt64(Int.max) {
                    data.reserveCapacity(Int(entry.uncompressedSize))
                }
                _ = try archive.extract(
                    entry,
                    bufferSize: 64 * 1024,
                    skipCRC32: true,
                    consumer: { data.append($0) }
                )

                if let plist = try PropertyListSerialization.propertyList(
                    from: data,
                    options: [],
                    format: nil
                ) as? [String: Any], plist["DecryptedBy"] != nil {
                    return true
                }
            } catch {
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

        guard let slice = parseMachOSlice(
            data,
            sliceOffset: 0,
            sliceSize: UInt64(data.count)
        ) else { return [] }
        return [slice]
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
        let archSize = isFat64 ? 32 : 20
        var headerOffset = 8
        var slices: [Slice] = []
        let dataSize = UInt64(data.count)

        for _ in 0..<Int(count) {
            guard headerOffset >= 0, headerOffset <= data.count - archSize else { break }

            let sliceOffset: UInt64?
            let sliceSize: UInt64?
            if isFat64 {
                sliceOffset = u64(data, at: headerOffset + 8, bigEndian: bigEndian)
                sliceSize = u64(data, at: headerOffset + 16, bigEndian: bigEndian)
            } else {
                sliceOffset = u32(data, at: headerOffset + 8, bigEndian: bigEndian).map(UInt64.init)
                sliceSize = u32(data, at: headerOffset + 12, bigEndian: bigEndian).map(UInt64.init)
            }
            headerOffset += archSize

            guard let rawOffset = sliceOffset, let rawSize = sliceSize else { continue }
            guard rawOffset <= dataSize, rawSize <= dataSize - rawOffset else { continue }

            if let slice = parseMachOSlice(
                data,
                sliceOffset: rawOffset,
                sliceSize: rawSize
            ) {
                slices.append(slice)
            }
        }
        return slices
    }

    private static func parseMachOSlice(
        _ data: Data,
        sliceOffset: UInt64,
        sliceSize: UInt64
    ) -> Slice? {
        guard
            sliceOffset <= UInt64(Int.max),
            sliceSize <= UInt64(Int.max),
            sliceOffset <= UInt64(data.count),
            sliceSize <= UInt64(data.count) - sliceOffset
        else { return nil }

        let base = Int(sliceOffset)
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

        let headerSize = is64Bit ? 32 : 28
        guard sliceSize >= UInt64(headerSize) else { return nil }
        guard
            let cpuValue = u32(data, at: base + 4, bigEndian: bigEndian),
            let cpuSubtype = u32(data, at: base + 8, bigEndian: bigEndian),
            let commandCount = u32(data, at: base + 16, bigEndian: bigEndian),
            let commandsSize = u32(data, at: base + 20, bigEndian: bigEndian)
        else { return nil }

        let commandsStart64 = sliceOffset + UInt64(headerSize)
        let commandsSize64 = UInt64(commandsSize)
        guard
            commandsStart64 <= sliceOffset + sliceSize,
            commandsSize64 <= sliceOffset + sliceSize - commandsStart64,
            commandsStart64 <= UInt64(Int.max),
            commandsStart64 + commandsSize64 <= UInt64(Int.max)
        else { return nil }

        var commandOffset = Int(commandsStart64)
        let commandsEnd = Int(commandsStart64 + commandsSize64)
        var encryption: (offset: UInt64, size: UInt64, id: UInt32)?
        var dylibID: String?
        var textSize: UInt64 = 0
        var entryOffset: UInt64?

        for _ in 0..<Int(commandCount) {
            guard commandOffset <= commandsEnd - 8 else { break }
            guard
                let command = u32(data, at: commandOffset, bigEndian: bigEndian),
                let commandSizeRaw = u32(data, at: commandOffset + 4, bigEndian: bigEndian)
            else { break }

            let commandSize = Int(commandSizeRaw)
            guard commandSize >= 8, commandSize <= commandsEnd - commandOffset else { break }
            let commandEnd = commandOffset + commandSize

            if command == lcEncryptionInfo || command == lcEncryptionInfo64 {
                let minimum = command == lcEncryptionInfo64 ? 24 : 20
                if commandSize >= minimum,
                   let cryptOffset = u32(data, at: commandOffset + 8, bigEndian: bigEndian),
                   let cryptSize = u32(data, at: commandOffset + 12, bigEndian: bigEndian),
                   let cryptID = u32(data, at: commandOffset + 16, bigEndian: bigEndian) {
                    encryption = (UInt64(cryptOffset), UInt64(cryptSize), cryptID)
                }
            } else if command == lcIDDylib, commandSize >= 24,
                      let nameOffsetRaw = u32(data, at: commandOffset + 8, bigEndian: bigEndian) {
                let nameOffset = Int(nameOffsetRaw)
                if nameOffset >= 0, nameOffset < commandSize {
                    let nameStart = commandOffset + nameOffset
                    if nameStart < commandEnd {
                        dylibID = cString(data, from: nameStart, limit: commandEnd)
                    }
                }
            } else if command == lcMain, commandSize >= 24,
                      let rawEntryOffset = u64(data, at: commandOffset + 8, bigEndian: bigEndian) {
                entryOffset = rawEntryOffset
            } else if command == lcSegment64, is64Bit, commandSize >= 72 {
                textSize = saturatingAdd(
                    textSize,
                    parseTextSize64(
                        data,
                        commandOffset: commandOffset,
                        commandSize: commandSize,
                        bigEndian: bigEndian
                    )
                )
            } else if command == lcSegment, !is64Bit, commandSize >= 56 {
                textSize = saturatingAdd(
                    textSize,
                    parseTextSize32(
                        data,
                        commandOffset: commandOffset,
                        commandSize: commandSize,
                        bigEndian: bigEndian
                    )
                )
            }

            commandOffset = commandEnd
        }

        let cpu = cpuName(cpuValue, subtype: cpuSubtype)
        let isARM64 = cpuValue == 16_777_228

        guard let encryption else {
            return Slice(
                cpu: cpu,
                isARM64: isARM64,
                is64Bit: is64Bit,
                cpuSubtype: cpuSubtype,
                sliceOffset: sliceOffset,
                sliceSize: sliceSize,
                cryptOffset: nil,
                cryptSize: nil,
                cryptID: nil,
                bytesAnalyzed: 0,
                entropy: 0,
                nullPercent: 0,
                printablePercent: 0,
                stringCount: 0,
                status: nil,
                preview: Data(),
                previewBaseOffset: 0,
                dylibID: dylibID,
                rangeIssue: nil,
                textSize: textSize,
                entryOffset: entryOffset
            )
        }

        let cryptOffset = encryption.offset
        let cryptSize = encryption.size
        var rangeIssue: String?
        var available: UInt64 = 0

        if cryptOffset > sliceSize {
            rangeIssue = "cryptoff exceeds the Mach-O slice boundary"
        } else {
            available = sliceSize - cryptOffset
            if cryptSize > available {
                rangeIssue = "cryptoff + cryptsize exceeds the Mach-O slice boundary"
            }
        }

        let analysisLength = min(cryptSize, available)
        let absoluteStart = sliceOffset + min(cryptOffset, sliceSize)
        let analysis = analyzeRegion(data, start: absoluteStart, length: analysisLength)

        let status: String
        if rangeIssue != nil {
            status = "INCONCLUSIVE"
        } else if encryption.id != 0 {
            status = "ENCRYPTED"
        } else if cryptSize == 0 {
            status = "DECRYPTED"
        } else if analysis.entropy > 7.9 && analysis.nullPercent < 1.0 {
            // cryptid=0 is authoritative metadata; high-entropy content is a
            // diagnostic warning rather than proof that FairPlay is still active.
            status = "LIKELY ENC"
        } else if analysis.entropy > 7.5 && analysis.nullPercent < 2.0 {
            status = "LIKELY ENC"
        } else {
            status = "DECRYPTED"
        }

        return Slice(
            cpu: cpu,
            isARM64: isARM64,
            is64Bit: is64Bit,
            cpuSubtype: cpuSubtype,
            sliceOffset: sliceOffset,
            sliceSize: sliceSize,
            cryptOffset: cryptOffset,
            cryptSize: cryptSize,
            cryptID: encryption.id,
            bytesAnalyzed: analysis.bytesAnalyzed,
            entropy: analysis.entropy,
            nullPercent: analysis.nullPercent,
            printablePercent: analysis.printablePercent,
            stringCount: analysis.stringCount,
            status: status,
            preview: analysis.preview,
            previewBaseOffset: analysis.previewBaseOffset,
            dylibID: dylibID,
            rangeIssue: rangeIssue,
            textSize: textSize,
            entryOffset: entryOffset
        )
    }

    private static func parseTextSize64(
        _ data: Data,
        commandOffset: Int,
        commandSize: Int,
        bigEndian: Bool
    ) -> UInt64 {
        guard let sectionCount = u32(data, at: commandOffset + 64, bigEndian: bigEndian) else { return 0 }
        let sectionSize = 80
        let sectionsStart = commandOffset + 72
        let commandEnd = commandOffset + commandSize
        var total: UInt64 = 0

        let availableSections = max(0, (commandEnd - sectionsStart) / sectionSize)
        let count = min(Int(sectionCount), availableSections)
        for index in 0..<count {
            let sectionOffset = sectionsStart + index * sectionSize
            let sectionName = fixedString(data, at: sectionOffset, length: 16)
            guard sectionName == "__text" else { continue }
            if let size = u64(data, at: sectionOffset + 40, bigEndian: bigEndian) {
                total = saturatingAdd(total, size)
            }
        }
        return total
    }

    private static func parseTextSize32(
        _ data: Data,
        commandOffset: Int,
        commandSize: Int,
        bigEndian: Bool
    ) -> UInt64 {
        guard let sectionCount = u32(data, at: commandOffset + 48, bigEndian: bigEndian) else { return 0 }
        let sectionSize = 68
        let sectionsStart = commandOffset + 56
        let commandEnd = commandOffset + commandSize
        var total: UInt64 = 0

        let availableSections = max(0, (commandEnd - sectionsStart) / sectionSize)
        let count = min(Int(sectionCount), availableSections)
        for index in 0..<count {
            let sectionOffset = sectionsStart + index * sectionSize
            let sectionName = fixedString(data, at: sectionOffset, length: 16)
            guard sectionName == "__text" else { continue }
            if let size = u32(data, at: sectionOffset + 36, bigEndian: bigEndian) {
                total = saturatingAdd(total, UInt64(size))
            }
        }
        return total
    }

    private static func saturatingAdd(_ lhs: UInt64, _ rhs: UInt64) -> UInt64 {
        UInt64.max - lhs < rhs ? UInt64.max : lhs + rhs
    }

    private static func analyzeRegion(_ data: Data, start: UInt64, length: UInt64) -> RegionAnalysis {
        guard
            length > 0,
            start <= UInt64(Int.max),
            length <= UInt64(Int.max),
            start <= UInt64(data.count),
            length <= UInt64(data.count) - start
        else {
            return RegionAnalysis(
                bytesAnalyzed: 0,
                entropy: 0,
                nullPercent: 0,
                printablePercent: 0,
                stringCount: 0,
                preview: Data(),
                previewBaseOffset: 0
            )
        }

        let startIndex = Int(start)
        let byteCount = Int(length)

        // Fast path for null-padded ranges. It is exact, and for ordinary code
        // it exits almost immediately on the first non-zero byte.
        let firstNonNull: UInt64? = data.withUnsafeBytes { rawBuffer in
            guard let rawBase = rawBuffer.baseAddress else { return nil }
            let bytes = rawBase.assumingMemoryBound(to: UInt8.self).advanced(by: startIndex)
            var index = 0
            while index < byteCount {
                if bytes[index] != 0 { return UInt64(index) }
                index += 1
            }
            return nil
        }

        if firstNonNull == nil {
            let previewLength = min(previewWindowSize, length)
            let preview: Data
            if previewLength > 0 {
                preview = data.subdata(in: startIndex..<(startIndex + Int(previewLength)))
            } else {
                preview = Data()
            }
            return RegionAnalysis(
                bytesAnalyzed: length,
                entropy: 0,
                nullPercent: 100.0,
                printablePercent: 0,
                stringCount: 0,
                preview: preview,
                previewBaseOffset: 0
            )
        }

        var frequencies = [UInt64](repeating: 0, count: 256)

        // One exact linear pass over the declared crypt range. All aggregate
        // metrics come from the histogram, avoiding extra per-byte classification
        // branches while still covering 100% of cryptsize.
        data.withUnsafeBytes { rawBuffer in
            guard let rawBase = rawBuffer.baseAddress else { return }
            let bytes = rawBase.assumingMemoryBound(to: UInt8.self).advanced(by: startIndex)

            frequencies.withUnsafeMutableBufferPointer { freq in
                var index = 0
                while index < byteCount {
                    freq[Int(bytes[index])] &+= 1
                    index += 1
                }
            }
        }

        let total = Double(length)
        let nulls = frequencies[0]
        var printable: UInt64 = 0
        for value in 0x20...0x7E {
            printable &+= frequencies[value]
        }

        var entropyValue = 0.0
        for frequency in frequencies where frequency > 0 {
            let p = Double(frequency) / total
            entropyValue -= p * log2(p)
        }
        if entropyValue == 0 { entropyValue = 0 } // normalize floating-point -0.0

        let previewBase = (firstNonNull! / 12) * 12
        let previewLength = min(previewWindowSize, length - min(previewBase, length))
        let previewStart = start + previewBase
        let preview: Data
        if previewLength > 0,
           previewStart <= UInt64(Int.max),
           previewLength <= UInt64(Int.max) {
            let begin = Int(previewStart)
            let end = begin + Int(previewLength)
            preview = data.subdata(in: begin..<end)
        } else {
            preview = Data()
        }

        return RegionAnalysis(
            bytesAnalyzed: length,
            entropy: entropyValue,
            nullPercent: Double(nulls) / total * 100.0,
            printablePercent: Double(printable) / total * 100.0,
            stringCount: UInt64(countStrings(preview)),
            preview: preview,
            previewBaseOffset: previewBase
        )
    }

    private static func countStrings(_ data: Data, minimumLength: Int = 4) -> Int {
        var count = 0
        var run = 0
        for byte in data {
            if byte >= 0x20 && byte <= 0x7E {
                run += 1
            } else {
                if run >= minimumLength { count += 1 }
                run = 0
            }
        }
        if run >= minimumLength { count += 1 }
        return count
    }

    private static func isMachO(_ data: Data) -> Bool {
        guard data.count >= 4 else { return false }
        let big = u32(data, at: 0, bigEndian: true)
        let little = u32(data, at: 0, bigEndian: false)
        return (big.map { allMagics.contains($0) } ?? false)
            || (little.map { allMagics.contains($0) } ?? false)
    }

    private static func cpuName(_ value: UInt32, subtype: UInt32) -> String {
        switch value {
        case 7:
            return "x86"
        case 12:
            return "ARM"
        case 16_777_223:
            return "x86_64"
        case 16_777_228:
            switch subtype & 0x00FF_FFFF {
            case 1: return "ARM64v8"
            case 2: return "ARM64e"
            default: return "ARM64"
            }
        default:
            return "?\(value)"
        }
    }

    private static func u32(_ data: Data, at offset: Int, bigEndian: Bool) -> UInt32? {
        guard offset >= 0, offset <= data.count - 4 else { return nil }
        let b0 = UInt32(data[offset])
        let b1 = UInt32(data[offset + 1])
        let b2 = UInt32(data[offset + 2])
        let b3 = UInt32(data[offset + 3])
        if bigEndian {
            return (b0 << 24) | (b1 << 16) | (b2 << 8) | b3
        }
        return b0 | (b1 << 8) | (b2 << 16) | (b3 << 24)
    }

    private static func u64(_ data: Data, at offset: Int, bigEndian: Bool) -> UInt64? {
        guard offset >= 0, offset <= data.count - 8 else { return nil }
        var value: UInt64 = 0
        if bigEndian {
            for index in 0..<8 {
                value = (value << 8) | UInt64(data[offset + index])
            }
        } else {
            for index in stride(from: 7, through: 0, by: -1) {
                value = (value << 8) | UInt64(data[offset + index])
            }
        }
        return value
    }

    private static func fixedString(_ data: Data, at offset: Int, length: Int) -> String {
        guard offset >= 0, length >= 0, offset <= data.count - length else { return "" }
        var bytes: [UInt8] = []
        bytes.reserveCapacity(length)
        for index in 0..<length {
            let byte = data[offset + index]
            if byte == 0 { break }
            bytes.append(byte)
        }
        return String(decoding: bytes, as: UTF8.self)
    }

    private static func cString(_ data: Data, from offset: Int, limit: Int) -> String? {
        guard offset >= 0, limit >= offset, limit <= data.count else { return nil }
        var bytes: [UInt8] = []
        bytes.reserveCapacity(min(128, limit - offset))
        var index = offset
        while index < limit {
            let byte = data[index]
            if byte == 0 { break }
            bytes.append(byte)
            index += 1
        }
        return String(decoding: bytes, as: UTF8.self)
    }

    // MARK: - Preview analysis

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
                guard let status = slice.status else { continue }
                switch status {
                case "ENCRYPTED":
                    encryptedCount += 1
                    appendUnique(entry.name, to: &encryptedNames)
                case "DECRYPTED":
                    decryptedCount += 1
                    appendUnique(entry.name, to: &decryptedNames)
                default:
                    if status.contains("LIKELY") {
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
        let architectureMeta = "slice +0x\(String(slice.sliceOffset, radix: 16, uppercase: true)) &nbsp;&middot;&nbsp; \(formattedInteger(slice.sliceSize)) bytes"
        var codeMeta: [String] = []
        if slice.textSize > 0 {
            codeMeta.append("__text \(formattedInteger(slice.textSize)) bytes")
        }
        if let entryOffset = slice.entryOffset {
            codeMeta.append("entryoff 0x\(String(entryOffset, radix: 16, uppercase: true))")
        }
        let codeMetaHTML = codeMeta.isEmpty
            ? ""
            : "<div class=\"stats\">\(codeMeta.joined(separator: " &nbsp;&middot;&nbsp; "))</div>"

        guard
            let cryptOffset = slice.cryptOffset,
            let cryptSize = slice.cryptSize,
            let cryptID = slice.cryptID,
            let status = slice.status
        else {
            let installName: String
            if let dylibID = slice.dylibID, !dylibID.isEmpty {
                installName = "<br><span class=\"dim\">install name: \(escapeHTML(dylibID))</span>"
            } else {
                installName = ""
            }
            return """
            <div class="slice">
              <div class="slice-head">Slice \(index + 1): \(escapeHTML(slice.cpu)) (\(slice.is64Bit ? "64" : "32")-bit)</div>
              <div class="meta"><span>\(architectureMeta)</span></div>
              \(codeMetaHTML)
              <div class="no-enc">No LC_ENCRYPTION_INFO\(installName)</div>
            </div>
            """
        }

        let mapping = slice.isARM64 ? arm64Map(slice.preview) : (counts: [:], positions: [:])
        let totalARM = mapping.counts.values.reduce(0, +)

        let tagClass: String
        let icon: String
        switch status {
        case "DECRYPTED": tagClass = "status-dec"; icon = "&#x2705;"
        case "ENCRYPTED": tagClass = "status-enc"; icon = "&#x1F512;"
        default: tagClass = "status-likely"; icon = "&#x26A0;&#xFE0F;"
        }

        let instructionHTML: String
        if totalARM > 0 && status == "DECRYPTED" {
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
        if let rangeIssue = slice.rangeIssue {
            verdictClass = "verdict-unk"
            verdict = "Invalid crypt range<br><span class=\"dim\">\(escapeHTML(rangeIssue))</span>"
        } else if status == "ENCRYPTED" {
            verdictClass = "verdict-enc"
            verdict = "FairPlay encryption active (cryptid \(cryptID))"
        } else if status.contains("LIKELY") {
            verdictClass = "verdict-unk"
            verdict = "cryptid is 0, but the full crypt range is ciphertext-like"
        } else if cryptSize > 0 && slice.nullPercent > 99.5 {
            verdictClass = "verdict-stub"
            var details: [String] = ["Crypt range is null-padded"]
            if slice.textSize > 0 {
                details.append("declared __text: \(formattedInteger(slice.textSize)) bytes")
            }
            if let dylibID = slice.dylibID, !dylibID.isEmpty {
                details.append("install name: \(escapeHTML(dylibID))")
            }
            verdict = details.enumerated().map { offset, value in
                offset == 0 ? value : "<span class=\"dim\">\(value)</span>"
            }.joined(separator: "<br>")
        } else {
            verdictClass = "verdict-ok"
            verdict = "Decrypted crypt range"
        }

        let entropyWidth = max(0, min(100, slice.entropy / 8.0 * 100.0))
        let coverage: Double
        if cryptSize == 0 {
            coverage = 100.0
        } else {
            coverage = min(100.0, Double(slice.bytesAnalyzed) / Double(cryptSize) * 100.0)
        }

        var stats = String(
            format: "Coverage %.2f%% &nbsp;&middot;&nbsp; Null %.1f%% &nbsp;&middot;&nbsp; Print %.1f%%",
            coverage,
            slice.nullPercent,
            slice.printablePercent
        )
        if totalARM > 0 {
            stats += " &nbsp;&middot;&nbsp; Preview ARM64-like x\(totalARM)"
        }
        if slice.stringCount > 0 {
            stats += " &nbsp;&middot;&nbsp; Preview strings \(formattedInteger(slice.stringCount))"
        }

        let previewHTML: String
        if slice.preview.isEmpty {
            previewHTML = ""
        } else {
            let previewOffset = slice.previewBaseOffset > 0
                ? " (+0x\(String(slice.previewBaseOffset, radix: 16, uppercase: true)) into crypt range)"
                : ""
            previewHTML = """
            <details class="hex-details">
              <summary>Hex preview\(previewOffset)</summary>
              <pre class="hex">\(hexPreviewHTML(slice.preview, positions: mapping.positions, baseOffset: slice.previewBaseOffset))</pre>
            </details>
            """
        }

        return """
        <div class="slice">
          <div class="slice-head">Slice \(index + 1): \(escapeHTML(slice.cpu)) (\(slice.is64Bit ? "64" : "32")-bit)</div>
          <div class="tag \(tagClass)">\(icon) \(escapeHTML(status))</div>
          <div class="meta">
            <span>cryptid \(cryptID)</span>
            <span>offset 0x\(String(cryptOffset, radix: 16, uppercase: true))</span>
            <span>size 0x\(String(cryptSize, radix: 16, uppercase: true))</span>
            <span>analyzed \(formattedInteger(slice.bytesAnalyzed)) / \(formattedInteger(cryptSize)) bytes</span>
            <span>\(architectureMeta)</span>
          </div>
          \(codeMetaHTML)
          <div class="entropy-row">
            <div class="entropy-bar"><div class="entropy-fill" style="width:\(String(format: "%.1f", entropyWidth))%"></div></div>
            <span class="entropy-val">\(String(format: "%.2f", slice.entropy)) / 8.0</span>
          </div>
          <div class="stats">\(stats)</div>
          \(instructionHTML)
          <div class="verdict \(verdictClass)">&#x2192; \(verdict)</div>
          \(previewHTML)
        </div>
        """
    }

    private static func hexPreviewHTML(_ data: Data, positions: [Int: String], baseOffset: UInt64) -> String {
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
        let effectiveOffset = baseOffset + UInt64(skip)
        if effectiveOffset > 0 {
            let note = skip > 0
                ? "crypt range +0x\(String(effectiveOffset, radix: 16, uppercase: true)); skipped \(skip) leading null bytes in preview"
                : "crypt range +0x\(String(effectiveOffset, radix: 16, uppercase: true))"
            lines.append("<span class=\"dim\">(\(note))</span>")
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

    private static func formattedInteger(_ value: UInt64) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return formatter.string(from: NSNumber(value: value)) ?? String(value)
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
