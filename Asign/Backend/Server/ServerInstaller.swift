//
//  Server.swift
//  feather
//
//  Created by samara on 22.08.2024.
//  Copyright © 2024 Lakr Aream. All Rights Reserved.
//  ORIGINALLY LICENSED UNDER GPL-3.0, MODIFIED FOR USE FOR FEATHER
//

import Foundation
import Vapor
import NIOSSL
import NIOTLS
import OSLog
import SwiftUI
import IDeviceSwift

// MARK: - Class
class ServerInstaller: Identifiable, ObservableObject {
	private static let lifecycleQueue = DispatchQueue(label: "Asign.install-server", qos: .userInitiated)
	let id = UUID()
	private let stateLock = NSLock()
	private var _port = 0
	private var _host = "127.0.0.1"
	private var _packageUrl: URL?
	private var _hostedInstallers: [ServerInstaller] = []
	private(set) var port: Int {
		get { withState { _port } }
		set { withState { _port = newValue } }
	}
	private(set) var host: String {
		get { withState { _host } }
		set { withState { _host = newValue } }
	}
	private var _needsShutdown = false

	var packageUrl: URL? {
		get { withState { _packageUrl } }
		set { withState { _packageUrl = newValue } }
	}
	let installTracking: ServerInstallTracking

	// Other apps this server also serves. A batched group is served from a
	// single server: the host serves its own payload plus every member's, each
	// keyed by app id, so only one server (and one port) is stood up for the
	// whole manifest instead of one per app. Members never serve.
	var hostedInstallers: [ServerInstaller] { withState { _hostedInstallers } }

	let app: AppInfoPresentable
	let viewModel: InstallerStatusViewModel
	private var _server: Application?
	private let _statusReporter: ((InstallerStatusViewModel.InstallerStatus) -> Void)?

	private func withState<T>(_ body: () -> T) -> T {
		stateLock.lock()
		defer { stateLock.unlock() }
		return body()
	}

	init(
		app: AppInfoPresentable,
		viewModel: InstallerStatusViewModel,
		installTracking: ServerInstallTracking = ServerInstallTracking(),
		statusReporter: ((InstallerStatusViewModel.InstallerStatus) -> Void)? = nil
	) {
		self.app = app
		self.viewModel = viewModel
		self.installTracking = installTracking
		self._statusReporter = statusReporter
	}

	deinit {
		if _needsShutdown, let server = _server {
			Self.lifecycleQueue.async {
				server.server.shutdown()
				server.shutdown()
			}
		}
	}

	// Binds a port and starts the TLS server on a serial worker. Deferred out of `init` so a
	// batched app can archive its package without ever standing up a server —
	// only the group's host serves, for itself and all its members. Idempotent.
	func startServing() async throws {
		try Task.checkCancellation()
		do {
			try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
				Self.lifecycleQueue.async {
					continuation.resume(with: Result { try self._startServing() })
				}
			}
		} catch {
			try Task.checkCancellation()
			throw error
		}
		try Task.checkCancellation()
	}

	private func _startServing() throws {
		guard _server == nil else { return }
		let configuration = try Self.serverConfiguration()
		host = configuration.host

		// The port is picked at random; a collision throws, so retry a few
		// times with fresh ports before giving up on this app.
		var lastError: Error?
		for _ in 0..<6 {
			port = Int.random(in: 4000...8000)
			let server = Self.setupApp(port: port, bindAddress: configuration.bindAddress, tls: configuration.tls)
			_configureRoutes(on: server, logLocalManifest: configuration.usesOnDeviceCertificate)
			do {
				try server.server.start()
				_server = server
				_needsShutdown = true
				if configuration.usesOnDeviceCertificate {
					Logger.misc.info("On-device HTTPS passed iOS trust evaluation and is listening at \(self.host, privacy: .public):\(self.port, privacy: .public)")
				}
				return
			} catch {
				lastError = error
				server.server.shutdown()
				server.shutdown()
			}
		}

		throw lastError ?? ServerInstallerError.couldNotStart
	}

	// Registers the members this host also serves. Set just before the host
	// starts serving and fires the shared prompt.
	func setHosted(_ installers: [ServerInstaller]) {
		withState { _hostedInstallers = installers }
	}

	func shutDown() {
		Self.lifecycleQueue.async { self._shutdownServer() }
	}

	// One "*" handler serves the host and every hosted member. Payloads and
	// icons are keyed by app id, so a request can be routed to whichever app
	// it's for, and that app's row is what gets updated.
	private func _configureRoutes(on server: Application, logLocalManifest: Bool) {
		server.get("*") { [weak self] req async throws -> Response in
			guard let self else { return Response(status: .badGateway) }
			let path = req.url.path
			let pool = req.application.threadPool

			// The manifest and landing page belong to the host alone.
			if path == self.plistEndpoint.path {
				let trackers = ([self] + self.hostedInstallers).map(\.installTracking)
				try? await pool.runIfActive {
					for tracker in trackers { tracker.captureBaseline() }
				}
				if logLocalManifest {
					Logger.misc.info("On-device HTTPS served an installation manifest")
				}
				self.report(.sendingManifest)
				return Response(status: .ok, version: req.version, headers: [
					"Content-Type": "text/xml",
				], body: .init(data: self.installManifestData))
			}

			if path == "/install" {
				let tracking = self.installTracking
				_ = try? await pool.runIfActive { tracking.captureBaseline() }
				var headers = HTTPHeaders()
				headers.add(name: .contentType, value: "text/html")
				return Response(status: .ok, headers: headers, body: .init(string: self.html))
			}

			// Payloads/icons: find which app (the host or one of its members)
			// this request is for, serve its file, and drive that app's status.
			for target in [self] + self.hostedInstallers {
				if path == "/\(target.id).ipa" {
					guard let packageUrl = target.packageUrl else {
						return Response(status: .notFound)
					}

					let tracking = target.installTracking
					let observation = try? await pool.runIfActive { tracking.captureBaseline() }
					target.report(.sendingPayload)

					return try await req.fileio.asyncStreamFile(at: packageUrl.path) { result in
						switch result {
						case .success:
							if let observation {
								try? await pool.runIfActive { tracking.recordTransfer(observation) }
							}
							target.report(.installing)
						case .failure(let error):
							target.report(.broken(error))
						}
					}
				}

				if path == "/\(target.id)-57.png" {
					return Response(status: .ok, version: req.version, headers: [
						"Content-Type": "image/png",
					], body: .init(data: target.displayImageSmallData))
				}

				if path == "/\(target.id)-512.png" {
					return Response(status: .ok, version: req.version, headers: [
						"Content-Type": "image/png",
					], body: .init(data: target.displayImageLargeData))
				}
			}

			return Response(status: .notFound)
		}
	}

	private func _shutdownServer() {
		guard _needsShutdown, let server = _server else { return }

		_needsShutdown = false
		server.server.shutdown()
		server.shutdown()
		_server = nil
	}

	// Pushes a status onto this app's row, on the main actor. Called for the
	// host and, by the host, for each of its members.
	func report(_ newStatus: InstallerStatusViewModel.InstallerStatus) {
		// The server receives these transitions on a Vapor/NIo worker queue.
		// Mirror them to the Live Activity before publishing the UI model on main.
		_statusReporter?(newStatus)

		DispatchQueue.main.async {
			guard !self.viewModel.isCompleted else { return }
			self.viewModel.status = newStatus
		}
	}

	static func getServerMethod() -> Int {
		UserDefaults.standard.integer(forKey: "Feather.serverMethod")
	}

	static func getIPFix() -> Bool {
		UserDefaults.standard.bool(forKey: "Feather.ipFix")
	}

	static func setServerMethod(_ method: Int) {
		UserDefaults.standard.set(method, forKey: "Feather.serverMethod")
	}

	static func setIPFix(_ enabled: Bool) {
		UserDefaults.standard.set(enabled, forKey: "Feather.ipFix")
	}
}

enum ServerInstallerError: LocalizedError {
	case couldNotStart
	case missingTLSIdentity

	var errorDescription: String? {
		switch self {
		case .couldNotStart:
			return "Couldn't start a local server for this app. Try installing it again."
		case .missingTLSIdentity:
			return "No SSL certificate is available. Update SSL Certificates in Settings > Installation."
		}
	}
}
