//
//  ZsignHandler.swift
//  Feather
//
//  Created by samara on 17.04.2025.
//

import Foundation
import Zsign
import UIKit

struct ArchiveSigningContext {
	let archiveURL: URL
	let rootAppPath: String
	let deletedPaths: Set<String>
}

final class ZsignHandler {
	private var _appUrl: URL
	private var _options: Options
	private var _certificate: CertificatePair?
	private var _archiveContext: ArchiveSigningContext?
	
	init(
		appUrl: URL,
		options: Options = OptionsManager.shared.options,
		cert: CertificatePair? = nil,
		archiveContext: ArchiveSigningContext? = nil
	) {
		self._appUrl = appUrl
		self._options = options
		self._certificate = cert
		self._archiveContext = archiveContext
	}
	
	func disinject() async throws {
		guard !_options.disInjectionFiles.isEmpty else {
			return
		}
		
		let bundle = Bundle(url: _appUrl)
		let execPath = _appUrl.appendingPathComponent(bundle?.exec ?? "").relativePath
		
		if !Zsign.removeDylibs(appExecutable: execPath, using: _options.disInjectionFiles) {
			throw SigningFileHandlerError.disinjectFailed
		}
	}
	
	func sign() async throws {
		guard let cert = _certificate else {
			throw SigningFileHandlerError.missingCertifcate
		}
		
        guard Zsign.sign(
            appPath: _appUrl.relativePath,
            provisionPath: Storage.shared.getFile(.provision, from: cert)?.path ?? "",
            p12Path: Storage.shared.getFile(.certificate, from: cert)?.path ?? "",
            p12Password: cert.password ?? "",
            entitlementsPath: _options.appEntitlementsFile?.path ?? "",
            customIdentifier: _options.appIdentifier ?? "",
            customName: _options.appName ?? "",
            customVersion: _options.appVersion ?? "",
            removeProvision: !_options.removeProvisioning,
            archivePath: _archiveContext?.archiveURL.path ?? "",
            archiveRootPath: _archiveContext?.rootAppPath ?? "",
            archiveDeletedPaths: Array(_archiveContext?.deletedPaths ?? []).sorted()
        ) else {
            throw SigningFileHandlerError.signFailed
        }
    }
	
	func adhocSign() async throws {
        guard Zsign.sign(
			appPath: _appUrl.relativePath,
			entitlementsPath: _options.appEntitlementsFile?.path ?? "",
			customIdentifier: _options.appIdentifier ?? "",
			customName: _options.appName ?? "",
			customVersion: _options.appVersion ?? "",
			adhoc: true,
            removeProvision: !_options.removeProvisioning,
            archivePath: _archiveContext?.archiveURL.path ?? "",
            archiveRootPath: _archiveContext?.rootAppPath ?? "",
            archiveDeletedPaths: Array(_archiveContext?.deletedPaths ?? []).sorted()
        ) else {
            throw SigningFileHandlerError.signFailed
        }
             
	}
}
