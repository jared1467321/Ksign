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
import SwiftUI
import IDeviceSwift

// MARK: - Class
class ServerInstaller: Identifiable, ObservableObject {
	let id = UUID()
	private(set) var port = 0
	private var _needsShutdown = false

	var packageUrl: URL?

	// Other apps this server also serves. A batched group is served from a
	// single server: the host serves its own payload plus every member's, each
	// keyed by app id, so only one server (and one port) is stood up for the
	// whole manifest instead of one per app. Members never serve.
	private(set) var hostedInstallers: [ServerInstaller] = []

	var app: AppInfoPresentable
	@ObservedObject var viewModel: InstallerStatusViewModel
	private var _server: Application?

	init(app: AppInfoPresentable, viewModel: InstallerStatusViewModel, startsServer: Bool = true) throws {
		self.app = app
		self.viewModel = viewModel
		if startsServer {
			try startServing()
		}
	}

	deinit {
		_shutdownServer()
	}

	// Binds a port and starts the TLS server. Deferred out of `init` so a
	// batched app can archive its package without ever standing up a server —
	// only the group's host serves, for itself and all its members. Idempotent.
	func startServing() throws {
		guard _server == nil else { return }

		// The port is picked at random; a collision throws, so retry a few
		// times with fresh ports before giving up on this app.
		var lastError: Error?
		self.port = Int.random(in: 4000...8000)
		self._server = try Self.setupApp(port: port)

		for attempt in 0..<6 {
			if attempt > 0 {
				_server?.shutdown()
				self.port = Int.random(in: 4000...8000)
				self._server = try Self.setupApp(port: port)
			}

			do {
				try _configureRoutes()
				try _server?.server.start()
				_needsShutdown = true
				return
			} catch {
				lastError = error
			}
		}

		_server = nil
		throw lastError ?? ServerInstallerError.couldNotStart
	}

	// Registers the members this host also serves. Set just before the host
	// starts serving and fires the shared prompt.
	func setHosted(_ installers: [ServerInstaller]) {
		hostedInstallers = installers
	}

	func shutDown() {
		_shutdownServer()
	}

	// One "*" handler serves the host and every hosted member. Payloads and
	// icons are keyed by app id, so a request can be routed to whichever app
	// it's for, and that app's row is what gets updated.
	private func _configureRoutes() throws {
		_server?.get("*") { [weak self] req in
			guard let self else { return Response(status: .badGateway) }
			let path = req.url.path

			// The manifest and landing page belong to the host alone.
			if path == self.plistEndpoint.path {
				self.report(.sendingManifest)
				return Response(status: .ok, version: req.version, headers: [
					"Content-Type": "text/xml",
				], body: .init(data: self.installManifestData))
			}

			if path == "/install" {
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

					target.report(.sendingPayload)

					return req.fileio.streamFile(at: packageUrl.path) { result in
						switch result {
						case .success:
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
		DispatchQueue.main.async {
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

	var errorDescription: String? {
		"Couldn't start a local server for this app. Try installing it again."
	}
}
