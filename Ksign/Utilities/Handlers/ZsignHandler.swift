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
    let manifest: Data?
    let resourceDigests: Data?
}

struct SigningCredentials {
    let provisionPath: String
    let certificatePath: String
    let password: String

    init(_ certificate: CertificatePair?) {
        provisionPath = certificate.flatMap { Storage.shared.getFile(.provision, from: $0)?.path } ?? ""
        certificatePath = certificate.flatMap { Storage.shared.getFile(.certificate, from: $0)?.path } ?? ""
        password = certificate?.password ?? ""
    }
}

final class ZsignHandler {
	private var _appUrl: URL
	private var _options: Options
	private var _certificate: CertificatePair?
	private var _archiveContext: ArchiveSigningContext?
    private let _session: ZsignSigningSession?
    private let _credentials: SigningCredentials?
	
	init(
		appUrl: URL,
		options: Options = OptionsManager.shared.options,
		cert: CertificatePair? = nil,
		archiveContext: ArchiveSigningContext? = nil,
        session: ZsignSigningSession? = nil,
        credentials: SigningCredentials? = nil
	) {
		self._appUrl = appUrl
		self._options = options
		self._certificate = cert
		self._archiveContext = archiveContext
        self._session = session
        self._credentials = credentials
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
		
        let credentials = _credentials ?? SigningCredentials(cert)
        guard Zsign.sign(
            appPath: _appUrl.relativePath,
            provisionPath: credentials.provisionPath,
            p12Path: credentials.certificatePath,
            p12Password: credentials.password,
            entitlementsPath: _options.appEntitlementsFile?.path ?? "",
            customIdentifier: _options.appIdentifier ?? "",
            customName: _options.appName ?? "",
            customVersion: _options.appVersion ?? "",
            removeProvision: !_options.removeProvisioning,
            archivePath: _archiveContext?.archiveURL.path ?? "",
            archiveRootPath: _archiveContext?.rootAppPath ?? "",
            archiveDeletedPaths: Array(_archiveContext?.deletedPaths ?? []).sorted(),
            archiveManifest: _archiveContext?.manifest,
            archiveResourceDigests: _archiveContext?.resourceDigests,
            session: _session
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
            archiveDeletedPaths: Array(_archiveContext?.deletedPaths ?? []).sorted(),
            archiveManifest: _archiveContext?.manifest,
            archiveResourceDigests: _archiveContext?.resourceDigests,
            session: _session
        ) else {
            throw SigningFileHandlerError.signFailed
        }
             
	}
}
