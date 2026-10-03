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
import NIOCore
import NIOPosix

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
	private let _statusReporter: ((InstallerStatusViewModel.InstallerStatus) -> Void)?
	private let _payloadProgressReporter: ((Double) -> Void)?

	init(
		app: AppInfoPresentable,
		viewModel: InstallerStatusViewModel,
		startsServer: Bool = true,
		statusReporter: ((InstallerStatusViewModel.InstallerStatus) -> Void)? = nil,
		payloadProgressReporter: ((Double) -> Void)? = nil
	) throws {
		self.app = app
		self.viewModel = viewModel
		self._statusReporter = statusReporter
		self._payloadProgressReporter = payloadProgressReporter
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

					let startedAt = Date()
					let attributes = try? FileManager.default.attributesOfItem(atPath: packageUrl.path)
					let size = (attributes?[.size] as? NSNumber)?.uint64Value ?? 0
					InstallDiagnostics.shared.record("payload_requested", details: [
						"server_app": target.id.uuidString,
						"bundle_id": target.app.identifier ?? "unknown",
						"file_bytes": String(size),
						"method": req.method.rawValue,
						"range": req.headers.first(name: .range) ?? "full"
					])
					// Keep Vapor's range/cache/HEAD metadata, but report progress
					// after each completed chunk write instead of only at EOF.
					let response = req.fileio.streamFile(at: packageUrl.path)
					guard req.method == .GET,
					      response.status == .ok || response.status == .partialContent else { return response }
					let byteCount = response.body.count
					let offset: Int64
					if response.status == .partialContent {
						guard let range = response.headers.first(name: .contentRange),
						      let start = range.split(separator: " ").last?.split(separator: "-").first,
						      let value = Int64(start) else { return response }
						offset = value
					} else { offset = 0 }
					let isFullPayload = offset == 0 && UInt64(byteCount) == size
					target.report(.sendingPayload)
					response.body = .init(stream: { stream in
						InstallDiagnostics.shared.record("payload_stream_started", details: [
							"server_app": target.id.uuidString, "response_bytes": String(byteCount),
							"offset": String(offset)
						])
						// All mutable counters are confined to this request's event loop.
						var sent = 0
						var lastProgressAt = Date.distantPast
						var lastDiagnosticAt = Date.distantPast
						let transfer = req.eventLoop.flatSubmit {
							do {
								let handle = try NIOFileHandle(path: packageUrl.path)
								let read = req.application.fileio.readChunked(
									fileHandle: handle, fromOffset: offset, byteCount: byteCount,
									chunkSize: 128 * 1024, allocator: req.byteBufferAllocator,
									eventLoop: req.eventLoop
								) { chunk in
									let count = chunk.readableBytes
									return stream.write(.buffer(chunk)).map {
										sent += count
										let now = Date()
										if isFullPayload && (now.timeIntervalSince(lastProgressAt) >= 1 || sent == byteCount) {
											lastProgressAt = now
											if byteCount > 0 { target._payloadProgressReporter?(Double(sent) / Double(byteCount)) }
										}
										if now.timeIntervalSince(lastDiagnosticAt) >= 5 || sent == byteCount {
											lastDiagnosticAt = now
											InstallDiagnostics.shared.record("payload_stream_progress", details: [
												"server_app": target.id.uuidString, "bytes_sent": String(sent),
												"response_bytes": String(byteCount), "offset": String(offset)
											])
										}
									}
								}
								read.whenComplete { _ in try? handle.close() }
								return read
							} catch { return req.eventLoop.makeFailedFuture(error) }
						}
						transfer.whenComplete { result in
							InstallDiagnostics.shared.record("payload_stream_finished", details: [
								"server_app": target.id.uuidString,
								"bytes_sent": String(sent),
								"elapsed_seconds": String(Date().timeIntervalSince(startedAt)),
								"result": String(describing: result)
							])
							switch result {
							case .success:
								stream.write(.end, promise: nil)
								target.report(.installing)
							case .failure(let error):
								stream.write(.error(error), promise: nil)
								target.report(.broken(error))
							}
						}
					}, count: byteCount, byteBufferAllocator: req.byteBufferAllocator)
					return response
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
