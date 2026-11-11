import Foundation
import UIKit
import Vapor

@MainActor
final class LocalTLSProfileDownload {
	private var server: Application?
	private var backgroundTask: UIBackgroundTaskIdentifier = .invalid

	static func open() async throws {
		let (server, url) = try await Task.detached(priority: .userInitiated) {
			try startServer()
		}.value
		let download = LocalTLSProfileDownload()
		download.server = server
		download.backgroundTask = UIApplication.shared.beginBackgroundTask(withName: "Asign TLS profile") { [weak download] in
			download?.stop()
		}
		Task {
			try? await Task.sleep(nanoseconds: 30_000_000_000)
			download.stop()
		}
		if await !UIApplication.shared.open(url) {
			download.stop()
			throw LocalTLSError.profileDownload
		}
	}

	private nonisolated static func startServer() throws -> (Application, URL) {
		let profile = try LocalTLSIdentity.load(createIfNeeded: true).configurationProfile()
		let host = LocalTLSIdentity.bindAddress
		let path = UUID().uuidString + ".mobileconfig"
		let app = ServerInstaller.setupApp(port: 0, bindAddress: host)
		do {
			app.get(.constant(path)) { _ in
				Response(status: .ok, headers: [
					"Content-Type": "application/x-apple-aspen-config",
					"Cache-Control": "no-store",
				], body: .init(data: profile))
			}
			try app.server.start()
			guard let port = app.http.server.shared.localAddress?.port,
			      let url = URL(string: "http://\(host):\(port)/\(path)")
			else { throw LocalTLSError.profileDownload }
			return (app, url)
		} catch {
			app.server.shutdown()
			app.shutdown()
			throw error
		}
	}

	private func stop() {
		guard let server else { return }
		self.server = nil
		if backgroundTask != .invalid {
			UIApplication.shared.endBackgroundTask(backgroundTask)
			backgroundTask = .invalid
		}
		Task.detached {
			await server.server.shutdown()
			try? await server.asyncShutdown()
		}
	}
}
