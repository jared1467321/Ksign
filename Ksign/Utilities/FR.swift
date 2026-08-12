//
//  FR.swift
//  Feather
//
//  Created by samara on 22.04.2025.
//

import Foundation.NSURL
import OSLog
import UIKit.UIImage
import Zsign
import NimbleJSON
import AltSourceKit
import IDeviceSwift
#if SERVER
import NIOSSL
#endif

enum FR {
	static func handlePackageFile(
		_ ipa: URL,
		download: Download? = nil,
		completion: @escaping (Error?) -> Void
	) {
		Task.detached {
			await TempMaintenance.shared.beginOperation()

			// Unzipping an IPA and moving it into place is real work, and it's
			// exactly the moment someone locks the phone. Counted rather than
			// identity-claimed because two imports can be in flight at once —
			// dropping a couple of files in, or a download finishing mid-import
			// — and the first to finish must not cut the second one off.
			//
			// `defer` rather than a call on each exit path: the catch branch
			// below is easy to extend later and forget about, and an unbalanced
			// begin leaks the engine.
			BackgroundAudioManager.shared.begin(.importing)
			defer { BackgroundAudioManager.shared.end(.importing) }

			let handler = AppFileHandler(file: ipa, download: download)
			
			do {
				try await handler.extract()
				try await handler.move()
				try await handler.addToDatabase()
                
				try? await handler.clean()
				await TempMaintenance.shared.endOperation()
				await MainActor.run {
					completion(nil)
				}
			} catch {
				try? await handler.clean()
				await TempMaintenance.shared.endOperation()
				await MainActor.run {
					completion(error)
				}
			}
		}
	}
	
	static func signPackageFile(
		_ app: AppInfoPresentable,
		using options: Options,
		icon: UIImage?,
		certificate: CertificatePair?,
		backgroundCompletion: ((Error?) -> Void)? = nil,
		completion: @escaping (Error?) -> Void
	) {
		Task.detached {
			await TempMaintenance.shared.beginOperation()

			// zsign on a large app is the longest stretch of pure CPU work in
			// here, and it was the one major pipeline with no keep-alive at
			// all. Counted for the same reason as import above; the bulk signer
			// runs these strictly one at a time, but nothing in the type system
			// says a single sign can't overlap a bulk batch.
			BackgroundAudioManager.shared.begin(.signing)
			defer { BackgroundAudioManager.shared.end(.signing) }

			let handler = SigningHandler(app: app, options: options)
			if !options.onlyModify {
				handler.appCertificate = certificate
			}
			handler.appIcon = icon

			// These reports originate on the signing worker, not MainActor. The
			// expanded Live Activity can therefore change phase while SwiftUI is
			// backgrounded, and the compact island keeps showing the batch count.
			func stage(_ name: String?) {
				if #available(iOS 16.2, *) {
					KeepAliveActivityController.shared.report(.signing, detail: name)
				}
			}

			do {
				stage("Copying")
				try await handler.copy()

				stage("Modifying")
				try await handler.modify()

				stage("Finishing")
				try? await handler.clean()

				stage(nil)
				await TempMaintenance.shared.endOperation()

				// Batch count reporting happens before the UI callback so it cannot
				// be delayed until the app returns to the foreground.
				backgroundCompletion?(nil)
				DispatchQueue.main.async {
					completion(nil)
				}
			} catch {
				try? await handler.clean()
				stage(nil)
				await TempMaintenance.shared.endOperation()
				backgroundCompletion?(error)
				DispatchQueue.main.async {
					completion(error)
				}
			}
		}
	}

	static func handleCertificateFiles(
		p12URL: URL,
		provisionURL: URL,
		p12Password: String,
		certificateName: String,
		completion: @escaping (Error?) -> Void
	) {
		Task.detached {
			let handler = CertificateFileHandler(
				key: p12URL,
				provision: provisionURL,
				password: p12Password,
				nickname: certificateName.isEmpty ? nil : certificateName
			)
			
			do {
				try await handler.copy()
				try await handler.addToDatabase()
				await MainActor.run {
					completion(nil)
				}
			} catch {
				await MainActor.run {
					completion(error)
				}
			}
		}
	}
	
	
	static func checkPasswordForCertificate(
		for key: URL,
		with password: String,
		using provision: URL
	) -> Bool {
		defer {
			password_check_fix_WHAT_THE_FUCK_free(provision.path)
		}
		
		password_check_fix_WHAT_THE_FUCK(provision.path)
		
		if (!p12_password_check(key.path, password)) {
			return false
		}
		
		return true
	}
	
	static func checkPasswordForCertificateData(
		p12Data: Data,
		provisionData: Data,
		password: String
	) -> Bool {
		let tempDir = FileManager.default.temporaryDirectory
		let tempP12 = tempDir.appendingPathComponent("temp_cert.p12")
		let tempProvision = tempDir.appendingPathComponent("temp_provision.mobileprovision")
		
		defer {
			try? FileManager.default.removeItem(at: tempP12)
			try? FileManager.default.removeItem(at: tempProvision)
		}
		
		do {
			try p12Data.write(to: tempP12)
			try provisionData.write(to: tempProvision)
			
			return checkPasswordForCertificate(for: tempP12, with: password, using: tempProvision)
		} catch {
			print("Error creating temporary files for password check: \(error)")
			return false
		}
	}
	
	static func movePairing(_ url: URL) {
		let fileManager = FileManager.default
		let dest = URL.documentsDirectory.appendingPathComponent("pairingFile.plist")

		try? fileManager.removeFileIfNeeded(at: dest)
		
		try? fileManager.copyItem(at: url, to: dest)
		
		HeartbeatManager.shared.start(true)
	}
	
	#if SERVER
	private static let _sslPackFallbackURLs = [
		"https://raw.githubusercontent.com/perki/backloop.dev/gh-pages/pack.json",
	]
	private static let _sslCertificateInstallQueue = DispatchQueue(
		label: "dev.backloop.ksign.ssl-certificate-install"
	)

	private struct SSLCertificateMaterial {
		let leafCertificate: String
		let fullCertificateChain: String
		let privateKey: String
		let commonName: String
		let issuerCommonName: String
		let notBefore: Date
		let notAfter: Date
	}

	private struct SSLCertificateCandidate {
		let source: String
		let pack: ServerPackModel
		let material: SSLCertificateMaterial
	}

	private struct InstalledSSLCertificateInfo {
		let leafCertificate: String
		let notBefore: Date
		let notAfter: Date
	}

	private enum SSLCertificateUpdateError: LocalizedError {
		case allDownloadsFailed([String])
		case invalidPack(String)
		case fileUpdateFailed(Error)

		var errorDescription: String? {
			switch self {
			case .allDownloadsFailed(let failures):
				return "Could not download a usable SSL certificate pack. "
					+ failures.joined(separator: " | ")
			case .invalidPack(let reason):
				return "The downloaded SSL certificate pack is invalid: \(reason)"
			case .fileUpdateFailed(let error):
				return "The SSL certificate files could not be updated: \(error.localizedDescription)"
			}
		}
	}

	static func downloadSSLCertificates(
		from urlString: String,
		completion: @escaping (Result<Void, Error>) -> Void
	) {
		var seen = Set<String>()
		let sources = ([urlString] + _sslPackFallbackURLs).filter {
			seen.insert($0).inserted
		}
		let fetcher = NBFetchService()

		func finish(
			candidates: [SSLCertificateCandidate],
			failures: [String]
		) {
			_sslCertificateInstallQueue.async {
				guard let winner = _newestSSLCertificateCandidate(in: candidates) else {
					completion(.failure(SSLCertificateUpdateError.allDownloadsFailed(failures)))
					return
				}

				do {
					if _shouldInstallSSLCertificate(winner.material) {
						try _installSSLCertificatePack(winner.pack)
						Logger.misc.info("SSL certificate pack updated from \(winner.source, privacy: .public); issuer=\(winner.material.issuerCommonName, privacy: .public), notBefore=\(_formatSSLDate(winner.material.notBefore), privacy: .public), notAfter=\(_formatSSLDate(winner.material.notAfter), privacy: .public)")
						DispatchQueue.main.async {
							UINotificationFeedbackGenerator().notificationOccurred(.success)
						}
					} else {
						Logger.misc.info("SSL certificate update skipped; installed identity is the same or newer than \(winner.source, privacy: .public)")
					}
					completion(.success(()))
				} catch {
					let wrapped: Error
					if let updateError = error as? SSLCertificateUpdateError {
						wrapped = updateError
					} else {
						wrapped = SSLCertificateUpdateError.fileUpdateFailed(error)
					}
					Logger.misc.error(
						"SSL certificate update failed: \(wrapped.localizedDescription, privacy: .public)"
					)
					completion(.failure(wrapped))
				}
			}
		}

		func trySource(
			at index: Int,
			candidates: [SSLCertificateCandidate],
			failures: [String]
		) {
			guard index < sources.count else {
				finish(candidates: candidates, failures: failures)
				return
			}

			let source = sources[index]
			fetcher.fetch(from: source) { (result: Result<ServerPackModel, Error>) in
				switch result {
				case .success(let pack):
					_sslCertificateInstallQueue.async {
						do {
							let material = try _validateSSLCertificatePack(pack)
							let candidate = SSLCertificateCandidate(
								source: source,
								pack: pack,
								material: material
							)
							Logger.misc.info("SSL certificate candidate accepted from \(source, privacy: .public); issuer=\(material.issuerCommonName, privacy: .public), notBefore=\(_formatSSLDate(material.notBefore), privacy: .public), notAfter=\(_formatSSLDate(material.notAfter), privacy: .public)")
							trySource(
								at: index + 1,
								candidates: candidates + [candidate],
								failures: failures
							)
						} catch {
							let label = URL(string: source)?.host ?? source
							let failure = "\(label): \(error.localizedDescription)"
							Logger.misc.warning(
								"SSL certificate source was unusable: \(failure, privacy: .public)"
							)
							trySource(
								at: index + 1,
								candidates: candidates,
								failures: failures + [failure]
							)
						}
					}

				case .failure(let error):
					let label = URL(string: source)?.host ?? source
					let failure = "\(label): \(error.localizedDescription)"
					Logger.misc.warning(
						"SSL certificate source failed: \(failure, privacy: .public)"
					)
					trySource(
						at: index + 1,
						candidates: candidates,
						failures: failures + [failure]
					)
				}
			}
		}

		trySource(at: 0, candidates: [], failures: [])
	}

	private static func _newestSSLCertificateCandidate(
		in candidates: [SSLCertificateCandidate]
	) -> SSLCertificateCandidate? {
		candidates.max { lhs, rhs in
			let lhsDominates = lhs.material.notBefore >= rhs.material.notBefore
				&& lhs.material.notAfter >= rhs.material.notAfter
				&& (lhs.material.notBefore > rhs.material.notBefore
					|| lhs.material.notAfter > rhs.material.notAfter)
			let rhsDominates = rhs.material.notBefore >= lhs.material.notBefore
				&& rhs.material.notAfter >= lhs.material.notAfter
				&& (rhs.material.notBefore > lhs.material.notBefore
					|| rhs.material.notAfter > lhs.material.notAfter)

			if lhsDominates { return false }
			if rhsDominates { return true }

			// If the candidates are incomparable (for example, a later issuance
			// that expires sooner), keep the one with the longer remaining
			// validity instead of trading a distant expiration for a newer date.
			if lhs.material.notAfter != rhs.material.notAfter {
				return lhs.material.notAfter < rhs.material.notAfter
			}
			if lhs.material.notBefore != rhs.material.notBefore {
				return lhs.material.notBefore < rhs.material.notBefore
			}
			return lhs.source > rhs.source
		}
	}

	private static func _validateSSLCertificatePack(
		_ pack: ServerPackModel
	) throws -> SSLCertificateMaterial {
		let material = try _sslCertificateMaterial(from: pack)
		let fileManager = FileManager.default
		let validationDir = fileManager.temporaryDirectory.appendingPathComponent(
			"ksign-ssl-validation-\(UUID().uuidString)"
		)
		defer { try? fileManager.removeItem(at: validationDir) }

		do {
			try fileManager.createDirectory(
				at: validationDir,
				withIntermediateDirectories: true
			)
			let certificateURL = validationDir.appendingPathComponent("server.crt")
			let privateKeyURL = validationDir.appendingPathComponent("server.pem")
			try material.fullCertificateChain.write(
				to: certificateURL,
				atomically: true,
				encoding: .utf8
			)
			try material.privateKey.write(
				to: privateKeyURL,
				atomically: true,
				encoding: .utf8
			)
			try ServerInstaller.validateTLSIdentity(
				certificateURL: certificateURL,
				privateKeyURL: privateKeyURL
			)
			return material
		} catch let error as SSLCertificateUpdateError {
			throw error
		} catch {
			throw SSLCertificateUpdateError.invalidPack(
				"the certificate chain and private key do not form a usable TLS identity: "
					+ error.localizedDescription
			)
		}
	}

	private static func _sslCertificateMaterial(
		from pack: ServerPackModel
	) throws -> SSLCertificateMaterial {
		let certificate = pack.cert.trimmingCharacters(in: .whitespacesAndNewlines)
		let certificateAuthorities = pack.ca.trimmingCharacters(in: .whitespacesAndNewlines)
		let privateKey = pack.key.trimmingCharacters(in: .whitespacesAndNewlines)
		let commonName = pack.info.domains.commonName
			.trimmingCharacters(in: .whitespacesAndNewlines)
		let issuerCommonName = pack.info.issuer.commonName
			.trimmingCharacters(in: .whitespacesAndNewlines)

		guard
			certificate.contains("-----BEGIN CERTIFICATE-----"),
			certificate.contains("-----END CERTIFICATE-----")
		else {
			throw SSLCertificateUpdateError.invalidPack(
				"the leaf certificate is missing or malformed"
			)
		}

		guard
			certificateAuthorities.contains("-----BEGIN CERTIFICATE-----"),
			certificateAuthorities.contains("-----END CERTIFICATE-----")
		else {
			throw SSLCertificateUpdateError.invalidPack(
				"the CA/intermediate chain is missing"
			)
		}

		guard
			privateKey.contains("-----BEGIN PRIVATE KEY-----")
				|| privateKey.contains("-----BEGIN RSA PRIVATE KEY-----"),
			privateKey.contains("-----END PRIVATE KEY-----")
				|| privateKey.contains("-----END RSA PRIVATE KEY-----")
		else {
			throw SSLCertificateUpdateError.invalidPack(
				"the private key is missing or malformed"
			)
		}

		guard !commonName.isEmpty else {
			throw SSLCertificateUpdateError.invalidPack("the common name is empty")
		}
		guard !issuerCommonName.isEmpty else {
			throw SSLCertificateUpdateError.invalidPack("the issuer common name is empty")
		}

		let normalizedLeafCertificate = certificate + "\n"
		guard let certificateValidity = _certificateValidity(fromPEMCertificate: normalizedLeafCertificate) else {
			throw SSLCertificateUpdateError.invalidPack(
				"the leaf certificate validity dates could not be read"
			)
		}
		let notBefore = certificateValidity.notBefore
		let notAfter = certificateValidity.notAfter

		let now = Date()
		guard now >= notBefore else {
			throw SSLCertificateUpdateError.invalidPack(
				"the certificate is not valid until \(_formatSSLDate(notBefore))"
			)
		}
		guard now < notAfter else {
			throw SSLCertificateUpdateError.invalidPack(
				"the certificate expired at \(_formatSSLDate(notAfter))"
			)
		}

		let fullCertificateChain = certificate + "\n\n" + certificateAuthorities + "\n"
		let certificateCount = fullCertificateChain
			.components(separatedBy: "-----BEGIN CERTIFICATE-----")
			.count - 1
		guard certificateCount >= 2 else {
			throw SSLCertificateUpdateError.invalidPack(
				"the full certificate chain was not supplied"
			)
		}

		return SSLCertificateMaterial(
			leafCertificate: normalizedLeafCertificate,
			fullCertificateChain: fullCertificateChain,
			privateKey: privateKey + "\n",
			commonName: commonName,
			issuerCommonName: issuerCommonName,
			notBefore: notBefore,
			notAfter: notAfter
		)
	}

	private static func _formatSSLDate(_ date: Date) -> String {
		let formatter = ISO8601DateFormatter()
		formatter.formatOptions = [.withInternetDateTime]
		return formatter.string(from: date)
	}

	private static func _shouldInstallSSLCertificate(
		_ candidate: SSLCertificateMaterial
	) -> Bool {
		guard let installed = _installedSSLCertificateInfo() else {
			return true
		}

		if installed.leafCertificate == candidate.leafCertificate {
			return false
		}

		if candidate.notBefore < installed.notBefore
			|| candidate.notAfter < installed.notAfter {
			Logger.misc.warning("Refusing SSL certificate downgrade; installed notBefore=\(_formatSSLDate(installed.notBefore), privacy: .public), notAfter=\(_formatSSLDate(installed.notAfter), privacy: .public); candidate notBefore=\(_formatSSLDate(candidate.notBefore), privacy: .public), notAfter=\(_formatSSLDate(candidate.notAfter), privacy: .public)")
			return false
		}

		return true
	}

	private static func _installedSSLCertificateInfo() -> InstalledSSLCertificateInfo? {
		ServerInstaller.withTLSIdentityLock {
			guard
				let certificateURL = ServerInstaller.getUrl("server", ext: "crt"),
				let privateKeyURL = ServerInstaller.getUrl("server", ext: "pem"),
				let certificateText = try? String(contentsOf: certificateURL, encoding: .utf8),
				let leafCertificate = _firstPEMCertificate(in: certificateText),
				let validity = _certificateValidity(fromPEMCertificate: leafCertificate)
			else {
				return nil
			}

			do {
				try ServerInstaller.validateTLSIdentity(
					certificateURL: certificateURL,
					privateKeyURL: privateKeyURL
				)
			} catch {
				Logger.misc.warning("Installed SSL identity is unusable; allowing replacement: \(error.localizedDescription, privacy: .public)")
				return nil
			}

			return InstalledSSLCertificateInfo(
				leafCertificate: leafCertificate,
				notBefore: validity.notBefore,
				notAfter: validity.notAfter
			)
		}
	}

	private static func _certificateValidity(
		fromPEMCertificate certificatePEM: String
	) -> (notBefore: Date, notAfter: Date)? {
		guard let certificate = try? NIOSSLCertificate(
			bytes: Array(certificatePEM.utf8),
			format: .pem
		) else {
			return nil
		}

		let notBefore = Date(
			timeIntervalSince1970: TimeInterval(certificate.notValidBefore)
		)
		let notAfter = Date(
			timeIntervalSince1970: TimeInterval(certificate.notValidAfter)
		)
		guard notAfter > notBefore else {
			return nil
		}

		return (notBefore, notAfter)
	}

	private static func _firstPEMCertificate(in text: String) -> String? {
		let beginMarker = "-----BEGIN CERTIFICATE-----"
		let endMarker = "-----END CERTIFICATE-----"
		guard
			let begin = text.range(of: beginMarker),
			let end = text.range(
				of: endMarker,
				range: begin.lowerBound..<text.endIndex
			)
		else {
			return nil
		}

		return String(text[begin.lowerBound..<end.upperBound])
			.trimmingCharacters(in: .whitespacesAndNewlines) + "\n"
	}

	private static func _installSSLCertificatePack(_ pack: ServerPackModel) throws {
		let material = try _sslCertificateMaterial(from: pack)
		let fileManager = FileManager.default
		let serverDir = URL.documentsDirectory
			.appendingPathComponent("App")
			.appendingPathComponent("Server")
		let stagingDir = serverDir.appendingPathComponent(
			".ssl-update-\(UUID().uuidString)"
		)
		let backupDir = serverDir.appendingPathComponent(
			".ssl-backup-\(UUID().uuidString)"
		)

		defer {
			try? fileManager.removeItem(at: stagingDir)
			try? fileManager.removeItem(at: backupDir)
		}

		do {
			try fileManager.createDirectoryIfNeeded(at: serverDir)
			try fileManager.createDirectory(
				at: stagingDir,
				withIntermediateDirectories: false
			)
			try fileManager.createDirectory(
				at: backupDir,
				withIntermediateDirectories: false
			)

			let stagedPEM = stagingDir.appendingPathComponent("server.pem")
			let stagedCRT = stagingDir.appendingPathComponent("server.crt")
			let stagedCommonName = stagingDir.appendingPathComponent("commonName.txt")

			try material.privateKey.write(
				to: stagedPEM,
				atomically: true,
				encoding: .utf8
			)
			try material.fullCertificateChain.write(
				to: stagedCRT,
				atomically: true,
				encoding: .utf8
			)
			try (material.commonName + "\n").write(
				to: stagedCommonName,
				atomically: true,
				encoding: .utf8
			)

			try ServerInstaller.validateTLSIdentity(
				certificateURL: stagedCRT,
				privateKeyURL: stagedPEM
			)

			let replacements: [(staged: URL, destination: URL)] = [
				(stagedPEM, serverDir.appendingPathComponent("server.pem")),
				(stagedCRT, serverDir.appendingPathComponent("server.crt")),
				(stagedCommonName, serverDir.appendingPathComponent("commonName.txt")),
			]

			try ServerInstaller.withTLSIdentityLock {
				for replacement in replacements
				where fileManager.fileExists(atPath: replacement.destination.path) {
					try fileManager.copyItem(
						at: replacement.destination,
						to: backupDir.appendingPathComponent(
							replacement.destination.lastPathComponent
						)
					)
				}

				do {
					for replacement in replacements {
						if fileManager.fileExists(atPath: replacement.destination.path) {
							_ = try fileManager.replaceItemAt(
								replacement.destination,
								withItemAt: replacement.staged,
								backupItemName: nil,
								options: .usingNewMetadataOnly
							)
						} else {
							try fileManager.moveItem(
								at: replacement.staged,
								to: replacement.destination
							)
						}
					}
				} catch {
					for replacement in replacements {
						try? fileManager.removeItem(at: replacement.destination)
						let backup = backupDir.appendingPathComponent(
							replacement.destination.lastPathComponent
						)
						if fileManager.fileExists(atPath: backup.path) {
							try? fileManager.moveItem(
								at: backup,
								to: replacement.destination
							)
						}
					}
					throw error
				}
			}
		} catch let error as SSLCertificateUpdateError {
			throw error
		} catch {
			throw SSLCertificateUpdateError.fileUpdateFailed(error)
		}
	}
	#endif
	
	static func handleSource(
		_ urlString: String,
		competion: @escaping () -> Void
	) {
		guard let url = URL(string: urlString) else { return }
		
		NBFetchService().fetch<ASRepository>(from: url) { (result: Result<ASRepository, Error>) in
			switch result {
			case .success(let data):
				let id = data.id ?? url.absoluteString
				
				if !Storage.shared.sourceExists(id) {
					Storage.shared.addSource(url, repository: data, id: id) { _ in
						competion()
					}
				} else {
					DispatchQueue.main.async {
						UIAlertController.showAlertWithOk(title: "Error", message: "Repository already added.")
					}
				}
			case .failure(let error):
				DispatchQueue.main.async {
					UIAlertController.showAlertWithOk(title: "Error", message: error.localizedDescription)
				}
			}
		}
	}
}

private enum CertificateHandlerError: Error {
	case invalidCertificate
}
