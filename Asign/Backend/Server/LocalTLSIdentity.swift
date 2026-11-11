import CryptoKit
import Darwin
import Foundation
import NIOSSL
import Security
import X509

struct LocalTLSIdentity: Codable {
	// appstored rejects a literal loopback address in an OTA manifest URL.
	static let host = "asign.127-0-0-1.dev"
	static let bindAddress = "127.0.0.1"
	static let preferenceKey = "Feather.useOnDeviceTLSCertificate"
	static let trustInstructions = "Install the Asign Local HTTPS profile in Settings > General > VPN & Device Management. Then turn on full trust for Asign Local HTTPS in Settings > General > About > Certificate Trust Settings."

	private let id: UUID
	private let hostname: String?
	private let rootDER: Data
	private let leafDER: Data
	private let leafKeyPEM: String
	private let expires: Date

	private static let storageLock = NSLock()

	static var isSelected: Bool {
		UserDefaults.standard.bool(forKey: preferenceKey)
	}

	// Persist one complete identity so a retry or concurrent install cannot
	// observe a new certificate with an old key.
	static func load(createIfNeeded: Bool = false) throws -> Self {
		storageLock.lock()
		defer { storageLock.unlock() }

		let fileManager = FileManager.default
		let support = try fileManager.url(
			for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true
		)
		var directory = support.appendingPathComponent("LocalTLS", isDirectory: true)
		let file = directory.appendingPathComponent("Identity.plist")
		do {
			let identity = try PropertyListDecoder().decode(Self.self, from: Data(contentsOf: file))
			if identity.hostname == host, identity.expires > Date() { return identity }
			if !createIfNeeded {
				throw identity.hostname == host ? LocalTLSError.expired : LocalTLSError.profileNeedsUpdate
			}
		} catch let error as CocoaError where error.code == .fileReadNoSuchFile || error.code == .fileNoSuchFile {
			guard createIfNeeded else { throw LocalTLSError.setupRequired }
		}

		let identity = try Self.generate()
		_ = try NIOSSLContext(configuration: identity.configuration())
		try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
		var resources = URLResourceValues()
		resources.isExcludedFromBackup = true
		try directory.setResourceValues(resources)
		let data = try PropertyListEncoder().encode(identity)
		try data.write(to: file, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
		return identity
	}

	static func generate(now: Date = Date()) throws -> Self {
		let id = UUID()
		let rootKey = X509.Certificate.PrivateKey(P256.Signing.PrivateKey())
		let leafKey = X509.Certificate.PrivateKey(P256.Signing.PrivateKey())
		let rootName = try DistinguishedName {
			CommonName("Asign Local HTTPS")
			OrganizationalUnitName(id.uuidString)
		}
		let leafName = try DistinguishedName { CommonName(host) }
		let notBefore = now.addingTimeInterval(-300)
		let notAfter = now.addingTimeInterval(730 * 24 * 60 * 60)
		let rootKeyID = SubjectKeyIdentifier(hash: rootKey.publicKey)
		let root = try X509.Certificate(
			version: .v3,
			serialNumber: .init(),
			publicKey: rootKey.publicKey,
			notValidBefore: notBefore,
			notValidAfter: notAfter,
			issuer: rootName,
			subject: rootName,
			signatureAlgorithm: .ecdsaWithSHA256,
			extensions: X509.Certificate.Extensions {
				Critical(BasicConstraints.isCertificateAuthority(maxPathLength: 0))
				Critical(KeyUsage(keyCertSign: true))
				rootKeyID
			},
			issuerPrivateKey: rootKey
		)
		let serverKeyUsage = try ExtendedKeyUsage([.serverAuth])
		let leaf = try X509.Certificate(
			version: .v3,
			serialNumber: .init(),
			publicKey: leafKey.publicKey,
			notValidBefore: notBefore,
			notValidAfter: notAfter,
			issuer: rootName,
			subject: leafName,
			signatureAlgorithm: .ecdsaWithSHA256,
			extensions: X509.Certificate.Extensions {
				Critical(BasicConstraints.notCertificateAuthority)
				Critical(KeyUsage(digitalSignature: true))
				serverKeyUsage
				SubjectAlternativeNames([.dnsName(host)])
				AuthorityKeyIdentifier(keyIdentifier: rootKeyID.keyIdentifier)
			},
			issuerPrivateKey: rootKey
		)
		// Discard the CA signing key after issuing the loopback leaf.
		return try Self(
			id: id,
			hostname: host,
			rootDER: Data(root.serializeAsPEM().derBytes),
			leafDER: Data(leaf.serializeAsPEM().derBytes),
			leafKeyPEM: leafKey.serializeAsPEM().pemString,
			expires: leaf.notValidAfter
		)
	}

	func configuration() throws -> TLSConfiguration {
		let leaf = try NIOSSLCertificate(bytes: Array(leafDER), format: .der)
		let key = try NIOSSLPrivateKey(bytes: Array(leafKeyPEM.utf8), format: .pem)
		var configuration = TLSConfiguration.makeServerConfiguration(
			certificateChain: [.certificate(leaf)], privateKey: .privateKey(key)
		)
		configuration.minimumTLSVersion = .tlsv12
		return configuration
	}

	static func checkLoopbackResolution() throws {
		var hints = addrinfo()
		hints.ai_socktype = SOCK_STREAM
		var results: UnsafeMutablePointer<addrinfo>?
		let status = getaddrinfo(host, nil, &hints, &results)
		guard status == 0, let first = results else {
			throw LocalTLSError.loopbackResolution(String(cString: gai_strerror(status)))
		}
		defer { freeaddrinfo(first) }

		var entry: UnsafeMutablePointer<addrinfo>? = first
		while let current = entry {
			let result = current.pointee
			var address = [CChar](repeating: 0, count: Int(NI_MAXHOST))
			let nameStatus = getnameinfo(
				result.ai_addr, result.ai_addrlen, &address, socklen_t(address.count), nil, 0, NI_NUMERICHOST
			)
			guard nameStatus == 0, String(cString: address) == bindAddress else {
				throw LocalTLSError.loopbackResolution("The hostname returned an address other than \(bindAddress).")
			}
			entry = result.ai_next
		}
	}

	func checkSystemTrust() throws {
		guard let leaf = SecCertificateCreateWithData(nil, leafDER as CFData),
		      let root = SecCertificateCreateWithData(nil, rootDER as CFData)
		else { throw LocalTLSError.invalidIdentity }

		let policy = SecPolicyCreateSSL(true, Self.host as CFString)
		var trust: SecTrust?
		let status = SecTrustCreateWithCertificates([leaf, root] as CFArray, policy, &trust)
		guard status == errSecSuccess, let trust else {
			throw LocalTLSError.trustEvaluation("OSStatus \(status)")
		}

		// Leave the system trust anchors in place, just as the iOS installer does.
		SecTrustSetNetworkFetchAllowed(trust, false)
		var failure: CFError?
		guard SecTrustEvaluateWithError(trust, &failure) else {
			let detail = failure.map {
				let message = CFErrorCopyDescription($0) as String? ?? "Certificate validation failed."
				let domain = CFErrorGetDomain($0) as String? ?? "Security"
				return "\(message) (\(domain) \(CFErrorGetCode($0)))"
			} ?? "No error detail returned."
			throw LocalTLSError.trustEvaluation(detail)
		}
	}

	func configurationProfile() throws -> Data {
		let identifier = "dev.asign.local-https"
		let certificate: [String: Any] = [
			"PayloadType": "com.apple.security.root",
			"PayloadVersion": 1,
			"PayloadIdentifier": "\(identifier).root",
			"PayloadUUID": id.uuidString,
			"PayloadDisplayName": "Asign Local HTTPS",
			"PayloadCertificateFileName": "AsignLocalHTTPS.cer",
			"PayloadContent": rootDER,
		]
		let profile: [String: Any] = [
			"PayloadType": "Configuration",
			"PayloadVersion": 1,
			"PayloadIdentifier": identifier,
			"PayloadUUID": "117214C9-B539-4748-94F2-8EE6E4FE18DA",
			"PayloadDisplayName": "Asign Local HTTPS",
			"PayloadDescription": "Trusts this device’s Asign installation server at \(Self.host).",
			"PayloadContent": [certificate],
		]
		return try PropertyListSerialization.data(fromPropertyList: profile, format: .xml, options: 0)
	}
}

enum LocalTLSError: LocalizedError {
	case setupRequired
	case expired
	case profileNeedsUpdate
	case invalidIdentity
	case loopbackResolution(String)
	case trustEvaluation(String)
	case profileDownload

	var errorDescription: String? {
		switch self {
		case .setupRequired:
			return "Set up the on-device certificate in Settings > Installation."
		case .expired:
			return "The on-device certificate expired. Download and trust a new profile in Settings > Installation."
		case .profileNeedsUpdate:
			return "The on-device certificate uses an old installation address. Download the updated profile in Settings > Installation, install it, and enable full trust again."
		case .invalidIdentity:
			return "The on-device certificate could not be read by iOS."
		case .loopbackResolution(let detail):
			return "Couldn’t resolve \(LocalTLSIdentity.host) to this device. \(detail)"
		case .trustEvaluation(let detail):
			return "iOS could not validate the on-device certificate for \(LocalTLSIdentity.host). \(LocalTLSIdentity.trustInstructions)\n\n\(detail)"
		case .profileDownload:
			return "Couldn’t open the on-device certificate profile. Try downloading it again."
		}
	}
}
