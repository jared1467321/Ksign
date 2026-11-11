//
//  Server+TLS.swift
//  feather
//
//  Created by samara on 22.08.2024.
//  Copyright © 2024 Lakr Aream. All Rights Reserved.
//  ORIGINALLY LICENSED UNDER GPL-3.0, MODIFIED FOR USE FOR FEATHER
//

import Foundation
import NIOSSL
import OSLog
import NIOTLS
import Vapor
import SystemConfiguration.CaptiveNetwork

// MARK: - Class extension: TLS/Setup
extension ServerInstaller {
	// MARK: Setup
	private static let tlsIdentityLock = NSLock()
	private static let env: Environment = {
		var env = try! Environment.detect()
		try! LoggingSystem.bootstrap(from: &env)
		return env
	}()
	
	struct ServerConfiguration {
		let host: String
		let bindAddress: String
		let tls: TLSConfiguration?
		let usesOnDeviceCertificate: Bool
	}

	static func setupApp(port: Int, bindAddress: String, tls: TLSConfiguration? = nil) -> Application {
		let app = Application(env)
		app.threadPool = .init(numberOfThreads: 1)
		app.http.server.configuration.tlsConfiguration = tls
		app.http.server.configuration.tcpNoDelay = true
		app.http.server.configuration.address = .hostname(bindAddress, port: port)
		app.routes.defaultMaxBodySize = "128mb"
		app.routes.caseInsensitive = false
		return app
	}

	static func serverConfiguration() throws -> ServerConfiguration {
		let loopback = LocalTLSIdentity.bindAddress
		if getServerMethod() == 1 {
			let host = getIPFix() ? loopback : (getLocalAddress() ?? loopback)
			return .init(host: host, bindAddress: "0.0.0.0", tls: nil, usesOnDeviceCertificate: false)
		}

		if LocalTLSIdentity.isSelected {
			do {
				let identity = try LocalTLSIdentity.load()
				try identity.checkSystemTrust()
				try LocalTLSIdentity.checkLoopbackResolution()
				return try .init(
					host: LocalTLSIdentity.host, bindAddress: loopback, tls: identity.configuration(), usesOnDeviceCertificate: true
				)
			} catch {
				Logger.misc.error("On-device HTTPS setup failed: \(error.localizedDescription, privacy: .public)")
				throw error
			}
		}

		#if SERVER
		if FR.isActiveSSLCertificateBlocked() {
			throw NSError(
				domain: "dev.asign.ssl",
				code: -1,
				userInfo: [
					NSLocalizedDescriptionKey: "The active SSL certificate has been revoked and is blocked. Update SSL certificates before using Fully Local installation."
				]
			)
		}
		#endif

		return try withTLSIdentityLock {
			guard
				let crt = getUrl("server", ext: "crt"),
				let pem = getUrl("server", ext: "pem")
			else {
				throw ServerInstallerError.missingTLSIdentity
			}

			return try .init(
				host: readCommonName() ?? loopback,
				bindAddress: "0.0.0.0",
				tls: makeTLSConfiguration(certificateURL: crt, privateKeyURL: pem),
				usesOnDeviceCertificate: false
			)
		}
	}

	/// Coordinates readers with the three-file certificate replacement so a
	/// server can never load a new key with an old certificate (or vice versa).
	static func withTLSIdentityLock<T>(_ operation: () throws -> T) rethrows -> T {
		tlsIdentityLock.lock()
		defer { tlsIdentityLock.unlock() }
		return try operation()
	}

	/// Parses the complete PEM chain and private key and asks NIOSSL to build a
	/// server context. Building the context verifies that the staged identity is
	/// usable before it is allowed to replace the currently working files.
	static func validateTLSIdentity(
		certificateURL: URL,
		privateKeyURL: URL
	) throws {
		_ = try NIOSSLContext(
			configuration: makeTLSConfiguration(
				certificateURL: certificateURL,
				privateKeyURL: privateKeyURL
			)
		)
	}

	private static func makeTLSConfiguration(
		certificateURL: URL,
		privateKeyURL: URL
	) throws -> TLSConfiguration {
		try TLSConfiguration.makeServerConfiguration(
			certificateChain: NIOSSLCertificate.fromPEMFile(certificateURL.path).map {
				NIOSSLCertificateSource.certificate($0)
			},
			privateKey: .privateKey(
				try NIOSSLPrivateKey(file: privateKeyURL.path, format: .pem)
			)
		)
	}
	
	// Call while holding tlsIdentityLock.
	private static func readCommonName() -> String? {
		guard let url = getUrl("commonName", ext: "txt"),
		      let value = try? String(contentsOf: url, encoding: .utf8)
			.trimmingCharacters(in: .whitespacesAndNewlines),
		      !value.isEmpty
		else { return nil }

		return value
	}
}

extension ServerInstaller {
	static func getUrl(_ name: String, ext: String) -> URL? {
		let fileManager = FileManager.default
		
		let serverURL = URL.documentsDirectory.appendingPathComponent("App").appendingPathComponent("Server").appendingPathComponent("\(name).\(ext)")
		if fileManager.fileExists(atPath: serverURL.path) {
			return serverURL
		}
		
		let documentsURL = URL.documentsDirectory.appendingPathComponent("\(name).\(ext)")
		if fileManager.fileExists(atPath: documentsURL.path) {
			return documentsURL
		}
		
		let oldServerURL = URL.documentsDirectory.appendingPathComponent("Server").appendingPathComponent("\(name).\(ext)")
		if fileManager.fileExists(atPath: oldServerURL.path) {
			return oldServerURL
		}
		
		return Bundle.main.url(forResource: name, withExtension: ext)
	}
	
	static func getLocalAddress() -> String? {
		var address: String?
		var ifaddr: UnsafeMutablePointer<ifaddrs>?
		
		if getifaddrs(&ifaddr) == 0 {
			var ptr = ifaddr
			while ptr != nil {
				let interface = ptr!.pointee
				let addrFamily = interface.ifa_addr.pointee.sa_family
				
				if addrFamily == UInt8(AF_INET) {
					
					let name = String(cString: interface.ifa_name)
					if name == "en0" || name == "pdp_ip0" {
						
						var hostname = [CChar](repeating: 0, count: Int(NI_MAXHOST))
						if getnameinfo(interface.ifa_addr, socklen_t(interface.ifa_addr.pointee.sa_len),
									   &hostname, socklen_t(hostname.count),
									   nil, socklen_t(0), NI_NUMERICHOST) == 0 {
							address = String(cString: hostname)
						}
						
					}
				}
				ptr = ptr!.pointee.ifa_next
			}
			freeifaddrs(ifaddr)
		}
		
		return address
	}
}
