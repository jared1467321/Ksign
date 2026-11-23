//
//  Server.swift
//  feather
//
//  Created by samara on 22.08.2024.
//  Copyright © 2024 Lakr Aream. All Rights Reserved.
//  ORIGINALLY LICENSED UNDER GPL-3.0, MODIFIED FOR USE FOR FEATHER
//

import Darwin
import Foundation
import Vapor
import NIOSSL
import NIOTLS
import OSLog
import SwiftUI
import UIKit
import IDeviceSwift

// MARK: - Class
class ServerInstaller: Identifiable, ObservableObject {
	private static let lifecycleQueue = DispatchQueue(label: "Asign.install-server", qos: .userInitiated)
	let id = UUID()
	private let stateLock = NSLock()
	private var _port = 0
	private var _host = "127.0.0.1"
	private var _packageUrl: URL?
	private var _payloadTransfer = ServerPayloadTransfer()
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
		set {
			withState {
				_packageUrl = newValue
				_payloadTransfer = ServerPayloadTransfer()
			}
		}
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
	private let _payloadProgressReporter: (@Sendable (Double) -> Void)?

	private func withState<T>(_ body: () -> T) -> T {
		stateLock.lock()
		defer { stateLock.unlock() }
		return body()
	}

	init(
		app: AppInfoPresentable,
		viewModel: InstallerStatusViewModel,
		installTracking: ServerInstallTracking = ServerInstallTracking(),
		payloadProgressReporter: (@Sendable (Double) -> Void)? = nil,
		statusReporter: ((InstallerStatusViewModel.InstallerStatus) -> Void)? = nil
	) {
		self.app = app
		self.viewModel = viewModel
		self.installTracking = installTracking
		self._payloadProgressReporter = payloadProgressReporter
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

	func resetPayloadTransfer() {
		installTracking.resetBaseline()
		withState { _payloadTransfer = ServerPayloadTransfer() }
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
				var headers = HTTPHeaders()
				headers.add(name: .contentType, value: "text/html")
				return Response(status: .ok, headers: headers, body: .init(string: self.html))
			}

			// Payloads/icons: find which app (the host or one of its members)
			// this request is for, serve its file, and drive that app's status.
			for target in [self] + self.hostedInstallers {
				if path == "/\(target.id).ipa" {
					return try await target._servePayload(req)
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

	private func _servePayload(_ request: Request) async throws -> Response {
		let (packageURL, transfer) = withState { (_packageUrl, _payloadTransfer) }
		guard let packageURL else { return Response(status: .notFound) }
		let path = packageURL.path
		// Reuse Vapor's conditional response and range handling. Replace its
		// stream so we can count writes without buffering the IPA.
		let response = try await request.fileio.asyncStreamFile(at: path)
		guard response.status != .notModified else { return response }
		let expectedBytes = response.body.count
		let offset: Int
		let totalBytes: Int
		if case let .withinWithLimit(start, _, size)? = response.headers.contentRange?.range {
			offset = start
			totalBytes = size
		} else {
			offset = 0
			totalBytes = expectedBytes
		}
		guard expectedBytes > 0, offset >= 0, offset < totalBytes, expectedBytes <= totalBytes - offset else {
			throw Abort(.rangeNotSatisfiable)
		}
		response.headers.replaceOrAdd(name: .acceptRanges, value: "bytes")

		let pool = request.application.threadPool
		let tracking = installTracking
		let pacer = ServerPayloadPacer.shared
		let observation = try await pool.runIfActive {
			let observation = tracking.captureBaseline()
			if let observation { try tracking.recordOffer(observation) }
			return observation
		}
		if transfer.begin(), withState({ _payloadTransfer === transfer }) { report(.sendingPayload) }

		response.body = .init(asyncStream: { writer in
			var sent = 0
			var reported = 0
			var nextSample = DispatchTime.now()
			func reportWrittenBytes() {
				guard sent > reported else { return }
				let progress = transfer.record((offset + reported)..<(offset + sent), totalBytes: totalBytes)
				reported = sent
				if let progress, self.withState({ self._payloadTransfer === transfer }) {
					self._payloadProgressReporter?(progress)
				}
			}

			do {
				let chunks = try await request.fileio.readFile(at: path, chunkSize: ServerPayloadBudget.chunkSize,
					offset: Int64(offset), byteCount: expectedBytes)
				do {
					for try await chunk in chunks {
						guard chunk.readableBytes <= expectedBytes - sent else {
							throw ServerInstallerError.incompletePayload
						}
						try await pacer.waitToWrite(chunk.readableBytes)
						try await writer.writeBuffer(chunk)
						sent += chunk.readableBytes
						let now = DispatchTime.now()
						if now >= nextSample {
							reportWrittenBytes()
							nextSample = now + .seconds(1)
						}
					}
				} catch {
					try? await chunks.closeHandle()
					throw error
				}
				reportWrittenBytes()
				guard sent == expectedBytes else { throw ServerInstallerError.incompletePayload }
				// A new UI attempt or server shutdown cannot discard completed coverage.
				let completed = try transfer.finish(totalBytes: totalBytes) {
					if let observation { try tracking.recordTransfer(observation) }
				}
				try await writer.write(.end)
				Logger.misc.notice("Install IPA \(self.id.uuidString, privacy: .public) streamed \(sent, privacy: .public)/\(expectedBytes, privacy: .public) bytes at offset \(offset, privacy: .public)")
				if completed, self.withState({ self._payloadTransfer === transfer }) { self.report(.installing) }
			} catch {
				reportWrittenBytes()
				Logger.misc.error("Install IPA \(self.id.uuidString, privacy: .public) stream failed after \(sent, privacy: .public)/\(expectedBytes, privacy: .public) bytes at offset \(offset, privacy: .public): \(error.localizedDescription, privacy: .public)")
				try? await writer.write(.error(error))
				if self.withState({ self._payloadTransfer === transfer }) { self.report(.broken(error)) }
			}
		}, count: expectedBytes, byteBufferAllocator: request.byteBufferAllocator)
		return response
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

enum ServerInstallProgress {
	static let payloadEnd = 0.85

	static func payload(_ progress: Double) -> Double {
		0.5 + (payloadEnd - 0.5) * progress
	}
}

/// All background responses spend the same process CPU budget. The iPhone
/// allowed 48 CPU seconds per minute in the failed run. A full burst plus
/// one minute of refill gives 45 CPU seconds, with room for in-flight writes.
private struct ServerPayloadBudget {
	static let chunkSize = 512 * 1024
	private static let second: UInt64 = 1_000_000_000
	private static let sampleInterval: UInt64 = 20_000_000
	private static let refillRate = 0.70
	private static let burst = 3.0
	private static let recoveryCredit = 0.02
	private var credit = Self.burst
	private var lastSample: (time: UInt64, cpuSeconds: Double)?
	private var pauseUntil: UInt64 = 0
	private var nextFallbackWrite: UInt64 = 0

	mutating func delay(now: UInt64, readCPU: () -> Double?) -> UInt64? {
		if let lastSample, now - lastSample.time < Self.sampleInterval {
			return max(now, pauseUntil) - now
		}
		guard let cpuSeconds = readCPU() else { return nil }
		if let lastSample {
			let elapsed = Double(now - lastSample.time) / Double(Self.second)
			let spent = max(0, cpuSeconds - lastSample.cpuSeconds)
			credit = min(Self.burst, credit + elapsed * Self.refillRate - spent)
		}
		lastSample = (now, cpuSeconds)
		guard credit <= 0 else {
			pauseUntil = 0
			return 0
		}
		let recovery = (Self.recoveryCredit - credit) / Self.refillRate
		let delay = UInt64((recovery * Double(Self.second)).rounded(.up))
		pauseUntil = now + delay
		return delay
	}

	/// Used only when process CPU accounting is temporarily unavailable.
	mutating func reserveFallback(_ bytes: Int, now: UInt64) -> UInt64 {
		let start = max(now, nextFallbackWrite)
		nextFallbackWrite = start + UInt64(bytes) * Self.second / UInt64(16 * 1024 * 1024)
		return start - now
	}

	mutating func suspendSampling() {
		lastSample = nil
		pauseUntil = 0
		nextFallbackWrite = 0
	}
}

private final class ServerPayloadPacer: @unchecked Sendable {
	static let shared = ServerPayloadPacer()
	private let lock = NSLock()
	private var budget = ServerPayloadBudget()
	private var isActive = false
	private var announced = false

	private init() {
		let center = NotificationCenter.default
		_ = center.addObserver(forName: UIApplication.willResignActiveNotification, object: nil, queue: nil) { [weak self] _ in
			self?.setActive(false)
		}
		_ = center.addObserver(forName: UIApplication.didBecomeActiveNotification, object: nil, queue: nil) { [weak self] _ in
			self?.setActive(true)
		}
		Task { @MainActor [weak self] in
			self?.setActive(UIApplication.shared.applicationState == .active)
		}
	}

	private func setActive(_ active: Bool) {
		lock.lock()
		defer { lock.unlock() }
		isActive = active
		if active {
			budget.suspendSampling()
			announced = false
		}
	}

	func waitToWrite(_ bytes: Int) async throws {
		try Task.checkCancellation()
		while true {
			let decision = nextWrite(bytes)
			if decision.announce {
				Logger.misc.notice("Server install adaptive CPU pacing active")
			}
			guard decision.delay > 0 else { return }
			try await Task.sleep(nanoseconds: decision.delay)
			if decision.reserved { return }
		}
	}

	private func nextWrite(_ bytes: Int) -> (delay: UInt64, reserved: Bool, announce: Bool) {
		lock.lock()
		defer { lock.unlock() }
		guard !isActive else { return (0, false, false) }
		let announce = !announced
		announced = true
		let now = DispatchTime.now().uptimeNanoseconds
		if let delay = budget.delay(now: now, readCPU: Self.processCPUTime) {
			// Check for a foreground transition even when the CPU pause is long.
			return (min(delay, 200_000_000), false, announce)
		}
		return (budget.reserveFallback(bytes, now: now), true, announce)
	}

	private static func processCPUTime() -> Double? {
		var usage = rusage()
		guard getrusage(RUSAGE_SELF, &usage) == 0 else { return nil }
		let seconds = Double(usage.ru_utime.tv_sec) + Double(usage.ru_stime.tv_sec)
		let microseconds = Double(usage.ru_utime.tv_usec) + Double(usage.ru_stime.tv_usec)
		return seconds + microseconds / 1_000_000
	}
}

private final class ServerPayloadTransfer: @unchecked Sendable {
	private let lock = NSLock()
	private var written = IndexSet()
	private var lastReportedCount = 0
	private var nextReport = DispatchTime(uptimeNanoseconds: 0)
	private var started = false
	private var finished = false

	func begin() -> Bool {
		lock.lock()
		defer { lock.unlock() }
		guard !started else { return false }
		started = true
		return true
	}

	func record(_ bytes: Range<Int>, totalBytes: Int, now: DispatchTime = .now()) -> Double? {
		lock.lock()
		defer { lock.unlock() }
		guard !finished else { return nil }
		written.insert(integersIn: bytes)
		let count = written.count
		guard now >= nextReport, count > lastReportedCount else { return nil }
		lastReportedCount = count
		nextReport = now + .seconds(1)
		return Double(count) / Double(totalBytes)
	}

	func finish(totalBytes: Int, persist: () throws -> Void) rethrows -> Bool {
		lock.lock()
		defer { lock.unlock() }
		guard !finished, written.count == totalBytes else { return false }
		try persist()
		finished = true
		return true
	}
}

enum ServerInstallerError: LocalizedError {
	case couldNotStart
	case missingTLSIdentity
	case incompletePayload

	var errorDescription: String? {
		switch self {
		case .couldNotStart:
			return "Couldn't start a local server for this app. Try installing it again."
		case .missingTLSIdentity:
			return "No SSL certificate is available. Update SSL Certificates in Settings > Installation."
		case .incompletePayload:
			return "The IPA stream ended before all requested bytes were sent."
		}
	}
}
