//
//  Storage+Shared.swift
//  Feather
//
//  Created by samara on 17.04.2025.
//

import CoreData
import Foundation
import ASignArchiveKit

// MARK: - Class extension: Apps (Shared)
extension Storage {
	func getUuidDirectory(for app: AppInfoPresentable) -> URL? {
		guard let uuid = app.uuid else { return nil }
		return app.isSigned
		? FileManager.default.signed(uuid)
		: FileManager.default.unsigned(uuid)
	}
	
	func getAppDirectory(for app: AppInfoPresentable) -> URL? {
		guard let url = getUuidDirectory(for: app) else { return nil }
		return FileManager.default.getPath(in: url, for: "app")
	}

	/// Canonical archive backing for newly-imported/newly-signed apps.
	/// Legacy records continue to expose a complete `.app` through
	/// `getAppDirectory(for:)` instead.
	func getArchiveURL(for app: AppInfoPresentable) -> URL? {
		guard let directory = getUuidDirectory(for: app) else { return nil }
		let archive = directory.appendingPathComponent("Archive.ipa", isDirectory: false)
		guard FileManager.default.fileExists(atPath: archive.path) else { return nil }
		return archive
	}

	func isArchiveBacked(_ app: AppInfoPresentable) -> Bool {
		getArchiveURL(for: app) != nil
	}

	func getArchiveBackedApp(for app: AppInfoPresentable) throws -> ArchiveBackedApp? {
		guard let archiveURL = getArchiveURL(for: app) else { return nil }
		return try ArchiveBackedApp(archiveURL: archiveURL)
	}

	/// Icons for archive-backed records are selectively cached beside Archive.ipa.
	/// Legacy records still resolve the icon relative to the extracted .app.
	func getIconURL(for app: AppInfoPresentable) -> URL? {
		guard let icon = app.icon, !icon.isEmpty else { return nil }
		if let archive = getArchiveURL(for: app) {
			let candidate = archive.deletingLastPathComponent().appendingPathComponent(icon)
			return FileManager.default.fileExists(atPath: candidate.path) ? candidate : nil
		}
		guard let appDirectory = getAppDirectory(for: app) else { return nil }
		let candidate = appDirectory.appendingPathComponent(icon)
		return FileManager.default.fileExists(atPath: candidate.path) ? candidate : nil
	}
	
	func deleteApp(for app: AppInfoPresentable) {
		do {
			if let url = getUuidDirectory(for: app) {
				try? FileManager.default.removeItem(at: url)
			}
			if let object = app as? NSManagedObject {
				context.delete(object)
			}
			saveContext()
		}
	}
	
	func getCertificate(from app: AppInfoPresentable) -> CertificatePair? {
		if let signed = app as? Signed {
			return signed.certificate
		}
		return nil
	}
}

// MARK: - Archive-backed app abstraction

struct ArchiveBackedAppMetadata: Sendable {
	let rootAppPath: String
	let name: String?
	let identifier: String?
	let version: String?
	let executable: String?
	let iconArchivePath: String?
}

enum ArchiveBackedAppError: LocalizedError {
	case invalidArchive
	case rootAppNotFound
	case unsafePath(String)
	case infoPlistMissing
	case infoPlistTooLarge
	case invalidInfoPlist

	var errorDescription: String? {
		switch self {
		case .invalidArchive:
			return "The IPA could not be opened as a ZIP archive."
		case .rootAppNotFound:
			return "No root Payload/*.app bundle was found in the IPA."
		case .unsafePath(let path):
			return "The IPA contains an unsafe path: \(path)"
		case .infoPlistMissing:
			return "The app's Info.plist is missing from the IPA."
		case .infoPlistTooLarge:
			return "The app's Info.plist is unexpectedly large."
		case .invalidInfoPlist:
			return "The app's Info.plist could not be decoded."
		}
	}
}

/// Read-only logical view of a root .app living inside an IPA. It intentionally
/// does not extract the app tree. Small metadata resources can be read or cached
/// selectively, and callers that need a directory listing operate on ZIP names.
final class ArchiveBackedApp {
	let archiveIndex: ASignArchiveIndex
	private var cachedRootInfo: Data?
	let archiveURL: URL
	let rootAppPath: String
	private let entriesByPath: [String: ASignArchiveEntry]

	init(archiveURL: URL) throws {
		self.archiveURL = archiveURL
		let archiveIndex = try ASignArchiveIndex(archiveURL: archiveURL)
		self.archiveIndex = archiveIndex
		let entries = try ASignArchive.entries(in: archiveURL, index: archiveIndex)

		var index: [String: ASignArchiveEntry] = [:]
		var rootCandidates = Set<String>()
		for entry in entries {
			try Self.validateArchivePath(entry.path)
			// Keep the last duplicate for direct metadata access. Untouched duplicate
			// handling during final archive construction is performed by minizip.
			index[entry.path] = entry

			let components = entry.path.split(separator: "/", omittingEmptySubsequences: true)
			if components.count == 3,
				components[0] == "Payload",
				components[1].hasSuffix(".app"),
				components[2] == "Info.plist" {
				rootCandidates.insert("Payload/\(components[1])")
			}
		}

		guard let root = rootCandidates.sorted().first else {
			throw ArchiveBackedAppError.rootAppNotFound
		}
		rootAppPath = root
		entriesByPath = index
	}

	func metadata(overlayAppURL: URL? = nil, deletedPaths: Set<String> = []) throws -> ArchiveBackedAppMetadata {
		let plistPath = rootAppPath + "/Info.plist"
		guard let entry = entriesByPath[plistPath] else {
			throw ArchiveBackedAppError.infoPlistMissing
		}
		guard entry.uncompressedSize <= 16 * 1024 * 1024 else {
			throw ArchiveBackedAppError.infoPlistTooLarge
		}

        let data: Data
        if let overlayAppURL {
            data = try Data(contentsOf: overlayAppURL.appendingPathComponent("Info.plist"))
        } else {
            data = try read(entry: entry, maximumBytes: 16 * 1024 * 1024)
        }
		guard
			let object = try PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any]
		else {
			throw ArchiveBackedAppError.invalidInfoPlist
		}

		let executable = Self.nonEmptyString(object["CFBundleExecutable"])
		let name = Self.nonEmptyString(object["CFBundleDisplayName"])
			?? Self.nonEmptyString(object["CFBundleName"])
			?? executable
		let identifier = Self.nonEmptyString(object["CFBundleIdentifier"])
		let version = Self.nonEmptyString(object["CFBundleShortVersionString"])
			?? Self.nonEmptyString(object["CFBundleVersion"])
		let iconPath = resolvePrimaryIconPath(from: object, overlayAppURL: overlayAppURL, deletedPaths: deletedPaths)

		return ArchiveBackedAppMetadata(
			rootAppPath: rootAppPath,
			name: name,
			identifier: identifier,
			version: version,
			executable: executable,
			iconArchivePath: iconPath
		)
	}

	func data(relativePath: String, maximumBytes: Int = 64 * 1024 * 1024) throws -> Data? {
		guard let archivePath = archivePath(forRelativePath: relativePath),
			let entry = entriesByPath[archivePath]
		else { return nil }
		return try read(entry: entry, maximumBytes: maximumBytes)
	}

	func list(relativePrefix: String) -> [String] {
		let cleanPrefix = relativePrefix.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
		let prefix = rootAppPath + (cleanPrefix.isEmpty ? "/" : "/\(cleanPrefix)/")
		var children = Set<String>()
		for path in entriesByPath.keys where path.hasPrefix(prefix) {
			let remainder = String(path.dropFirst(prefix.count))
			guard let first = remainder.split(separator: "/", omittingEmptySubsequences: true).first else { continue }
			children.insert(String(first))
		}
		return children.sorted()
	}

	func paths(relativePrefix: String = "") -> [String] {
		let cleanPrefix = relativePrefix.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
		let prefix = rootAppPath + (cleanPrefix.isEmpty ? "/" : "/\(cleanPrefix)")
		return entriesByPath.keys.compactMap { path in
			guard path.hasPrefix(prefix) else { return nil }
			let start = path.index(path.startIndex, offsetBy: rootAppPath.count + 1)
			return start <= path.endIndex ? String(path[start...]) : nil
		}.sorted()
	}

	@discardableResult
    func cachePrimaryIcon(in directory: URL, fileName: String = "Icon", overlayAppURL: URL? = nil,
                          metadata suppliedMetadata: ArchiveBackedAppMetadata? = nil,
                          deletedPaths: Set<String> = []) throws -> String? {
        let metadata = try suppliedMetadata ?? metadata(overlayAppURL: overlayAppURL, deletedPaths: deletedPaths)
        guard let iconPath = metadata.iconArchivePath else { return nil }
		let ext = URL(fileURLWithPath: iconPath).pathExtension
		let cacheName = ext.isEmpty ? fileName : "\(fileName).\(ext)"
		let destination = directory.appendingPathComponent(cacheName)
		try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
		if FileManager.default.fileExists(atPath: destination.path) {
			try FileManager.default.removeItem(at: destination)
		}
        let relative = String(iconPath.dropFirst(rootAppPath.count + 1))
        if let overlayAppURL, FileManager.default.fileExists(atPath: overlayAppURL.appendingPathComponent(relative).path) {
            try FileManager.default.copyItem(at: overlayAppURL.appendingPathComponent(relative), to: destination)
        } else {
            guard entriesByPath[iconPath] != nil,
                  try ASignArchive.extractEntry(from: archiveURL, path: iconPath, to: destination, index: archiveIndex)
            else { return nil }
        }
		return cacheName
	}

	func extract(relativePath: String, to destination: URL) throws -> Bool {
		guard let archivePath = archivePath(forRelativePath: relativePath),
			entriesByPath[archivePath] != nil
		else { return false }
		try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
		return try ASignArchive.extractEntry(from: archiveURL, path: archivePath, to: destination, index: archiveIndex)
	}

	/// Resolves a resource name the same way iOS icon declarations commonly do:
	/// exact path first, then image variants such as `@2x`, `@3x`, and `~ipad`.
	/// The returned path is relative to the root .app.
	func resolvedResourceRelativePath(_ candidate: String) -> String? {
		let clean = candidate.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
		guard !clean.isEmpty, Self.isSafeRelativePath(clean) else { return nil }
		if let direct = archivePath(forRelativePath: clean), entriesByPath[direct] != nil {
			return clean
		}

		let candidateURL = URL(fileURLWithPath: clean)
		guard candidateURL.pathExtension.isEmpty else { return nil }
		let parent = candidateURL.deletingLastPathComponent().path == "."
			? ""
			: candidateURL.deletingLastPathComponent().path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
		let base = candidateURL.lastPathComponent
		let prefix = rootAppPath + (parent.isEmpty ? "/" : "/\(parent)/")
		let imageExtensions = Set(["png", "jpg", "jpeg", "heic"])

		let matches = entriesByPath.keys.compactMap { path -> String? in
			guard path.hasPrefix(prefix) else { return nil }
			let remainder = String(path.dropFirst(prefix.count))
			guard !remainder.contains("/") else { return nil }
			let fileURL = URL(fileURLWithPath: remainder)
			let ext = fileURL.pathExtension.lowercased()
			guard imageExtensions.contains(ext) else { return nil }
			let stem = String(fileURL.lastPathComponent.dropLast(ext.count + 1))
			guard stem == base || stem.hasPrefix(base + "@") || stem.hasPrefix(base + "~") else { return nil }
			return parent.isEmpty ? remainder : parent + "/" + remainder
		}
		return matches.sorted { Self.iconPreference($0) > Self.iconPreference($1) }.first
	}

	func resourceData(named candidate: String, maximumBytes: Int = 64 * 1024 * 1024) throws -> Data? {
		guard let relative = resolvedResourceRelativePath(candidate) else { return nil }
		return try data(relativePath: relative, maximumBytes: maximumBytes)
	}

	/// Selectively materializes one file or subtree from the root .app. The
	/// destination represents the selected path itself (for example Foo.framework).
	/// This is used only for explicit UI/export features that need real files.
	@discardableResult
	func extractTree(relativePath: String, to destination: URL) throws -> Bool {
		let clean = relativePath.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
		guard !clean.isEmpty, Self.isSafeRelativePath(clean),
			let archiveBase = archivePath(forRelativePath: clean),
			entriesByPath.keys.contains(where: { $0 == archiveBase || $0.hasPrefix(archiveBase + "/") })
		else { return false }
		return try ASignArchive.extractPrefix(from: archiveURL, prefix: archiveBase, to: destination, index: archiveIndex)
	}

	/// Explicit compatibility helper for features whose semantics require an
	/// extracted app tree (currently Crypt Check Extracted). Normal browsing,
	/// signing, installation and export do not call this.
	func extractRootApp(to destination: URL) throws {
		guard try ASignArchive.extractPrefix(from: archiveURL, prefix: rootAppPath, to: destination, index: archiveIndex) else {
			throw ArchiveBackedAppError.rootAppNotFound
		}
	}

	private func archivePath(forRelativePath relativePath: String) -> String? {
		let clean = relativePath.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
		guard Self.isSafeRelativePath(clean) else { return nil }
		return clean.isEmpty ? rootAppPath : rootAppPath + "/" + clean
	}

	private func read(entry: ASignArchiveEntry, maximumBytes: Int) throws -> Data {
		guard maximumBytes >= 0, entry.uncompressedSize >= 0, entry.uncompressedSize <= Int64(maximumBytes) else {
			throw ArchiveBackedAppError.infoPlistTooLarge
		}
        if entry.path == rootAppPath + "/Info.plist", let cachedRootInfo {
            guard cachedRootInfo.count <= maximumBytes else { throw ArchiveBackedAppError.infoPlistTooLarge }
            return cachedRootInfo
        }
		guard let data = try ASignArchive.readEntry(
			from: archiveURL,
			path: entry.path,
			maximumBytes: Int64(maximumBytes),
            index: archiveIndex
		) else {
			throw ArchiveBackedAppError.infoPlistMissing
		}
        if entry.path == rootAppPath + "/Info.plist" { cachedRootInfo = data }
		return data
	}

    private func resolvePrimaryIconPath(from plist: [String: Any], overlayAppURL: URL? = nil,
                                        deletedPaths: Set<String> = []) -> String? {
		var candidates: [String] = []

		func appendIconFiles(_ key: String) {
			guard let icons = plist[key] as? [String: Any],
				let primary = icons["CFBundlePrimaryIcon"] as? [String: Any]
			else { return }
			if let files = primary["CFBundleIconFiles"] as? [String] {
				candidates.append(contentsOf: files.reversed())
			}
		}

		appendIconFiles("CFBundleIcons")
		appendIconFiles("CFBundleIcons~ipad")
		for key in ["CFBundleIconFiles", "CFBundleIconFiles~iphone", "CFBundleIconFiles~ipad"] {
			if let files = plist[key] as? [String] {
				candidates.append(contentsOf: files.reversed())
			}
		}
		if let icon = Self.nonEmptyString(plist["CFBundleIconFile"]) {
			candidates.append(icon)
		}

		let rootPrefix = rootAppPath + "/"
		let imageExtensions = Set(["png", "jpg", "jpeg", "heic"])
        func isDeleted(_ path: String) -> Bool {
            let relative = String(path.dropFirst(rootPrefix.count))
            return deletedPaths.contains { relative == $0 || relative.hasPrefix($0 + "/") }
        }
        var rootFiles = Set(entriesByPath.keys.filter { path in
            guard path.hasPrefix(rootPrefix) else { return false }
            return !path.dropFirst(rootPrefix.count).contains("/") && !isDeleted(path)
        })
        if let overlayAppURL,
           let diskFiles = try? FileManager.default.contentsOfDirectory(atPath: overlayAppURL.path) {
            rootFiles.formUnion(diskFiles.map { rootPrefix + $0 }.filter { !isDeleted($0) })
        }

		for candidate in candidates where !candidate.isEmpty && Self.isSafeRelativePath(candidate) {
			let direct = rootPrefix + candidate
            if !isDeleted(direct), entriesByPath[direct] != nil ||
                (overlayAppURL.map { FileManager.default.fileExists(atPath: $0.appendingPathComponent(candidate).path) } ?? false) {
                return direct
            }
			if URL(fileURLWithPath: candidate).pathExtension.isEmpty {
				let matches = rootFiles.filter { path in
					let name = URL(fileURLWithPath: path).lastPathComponent
					let ext = URL(fileURLWithPath: name).pathExtension.lowercased()
					guard imageExtensions.contains(ext) else { return false }
					let stem = String(name.dropLast(ext.count + 1))
					return stem == candidate || stem.hasPrefix(candidate + "@") || stem.hasPrefix(candidate + "~")
				}
				if let preferred = matches.sorted(by: { Self.iconPreference($0) > Self.iconPreference($1) }).first {
					return preferred
				}
			}
		}
		return nil
	}

	private static func iconPreference(_ path: String) -> Int {
		let name = URL(fileURLWithPath: path).lastPathComponent.lowercased()
		var score = 0
		if name.contains("@3x") { score += 30 }
		else if name.contains("@2x") { score += 20 }
		if !name.contains("~ipad") { score += 5 }
		return score
	}

	private static func nonEmptyString(_ value: Any?) -> String? {
		guard let string = value as? String, !string.isEmpty else { return nil }
		return string
	}

	private static func validateArchivePath(_ path: String) throws {
		guard isSafeArchivePath(path) else { throw ArchiveBackedAppError.unsafePath(path) }
	}

	private static func isSafeArchivePath(_ path: String) -> Bool {
		guard !path.isEmpty, !path.hasPrefix("/"), !path.hasPrefix("\\"), !path.contains("\\") else { return false }
		let components = path.split(separator: "/", omittingEmptySubsequences: false)
		return !components.contains(where: { $0 == ".." })
	}

	private static func isSafeRelativePath(_ path: String) -> Bool {
		guard !path.hasPrefix("/"), !path.hasPrefix("\\"), !path.contains("\\") else { return false }
		return !path.split(separator: "/", omittingEmptySubsequences: false).contains(where: { $0 == ".." })
	}
}

// MARK: - Helpers
struct AnyApp: Identifiable {
	let base: AppInfoPresentable
	var archive: Bool = false
	var signAndInstall: Bool = false
	
	var id: String {
		base.uuid ?? UUID().uuidString
	}
}

protocol AppInfoPresentable {
	var name: String? { get }
	var version: String? { get }
	var identifier: String? { get }
	var date: Date? { get }
	var icon: String? { get }
	var uuid: String? { get }
	var isSigned: Bool { get }
	
}

extension Signed: AppInfoPresentable {
	var isSigned: Bool { true }
}

extension Imported: AppInfoPresentable {
	var isSigned: Bool { false }
}
