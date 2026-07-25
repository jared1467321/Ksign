//
//  FRAppIconView.swift
//  Feather
//
//  Created by samara on 18.04.2025.
//

import SwiftUI
import UIKit

// MARK: - Icon loader / cache
//
// The old `FRAppIconView` did all of its work inside the view body:
//
//   - `Storage.shared.getAppDirectory(for:)` -> `getPath` runs a synchronous
//     `contentsOfDirectory` scan to find the `.app` bundle, and
//   - `UIImage(contentsOfFile:)` synchronously reads the file and decodes it.
//
// Both ran on the main thread, uncached, every single time SwiftUI evaluated
// the body — which happens constantly, and for every visible cell at once.
// A library refresh (importing an app, or a background Core Data merge landing
// on the main `viewContext`) therefore kicked off a burst of synchronous disk
// reads and image decodes on the main thread, which is what made the UI hard
// freeze — on import, and seemingly "at idle" when a background merge fired.
//
// This loader does the same work once, off the main thread, and caches the
// decoded image. After the first decode, every later render is a pure in-memory
// cache hit with zero disk access.
final class AppIconLoader {
	static let shared = AppIconLoader()

	private let _cache = NSCache<NSString, UIImage>()

	private init() {
		// Plenty for a scrolling library; images are evicted under pressure.
		_cache.countLimit = 256
	}

	/// Stable per-app key. The icon file name is part of the key so a changed
	/// icon naturally invalidates the old entry.
	static func cacheKey(for app: AppInfoPresentable) -> String {
		"\(app.isSigned ? "s" : "u"):\(app.uuid ?? "?"):\(app.icon ?? "?")"
	}

	/// Synchronous, main-thread-safe, no disk access. Returns an already
	/// decoded image if one is cached, so a re-render can paint instantly.
	func cachedImage(forKey key: String) -> UIImage? {
		_cache.object(forKey: key as NSString)
	}

	/// Resolves the icon path and decodes it off the main thread, then caches
	/// the result. Returns `nil` when there's no icon (caller shows the
	/// placeholder).
	///
	/// Must be called from the app's context thread (the main actor, for the
	/// main-queue `viewContext`) so the managed-object property reads below are
	/// safe. Only the plain snapshot values cross onto the background task.
	@MainActor
	func image(for app: AppInfoPresentable) async -> UIImage? {
		let key = Self.cacheKey(for: app)
		if let hit = _cache.object(forKey: key as NSString) {
			return hit
		}

		// Snapshot everything we need while still on the context's thread —
		// `NSManagedObject` must not be touched from the background task.
		let uuid = app.uuid
		let iconName = app.icon
		let isSigned = app.isSigned

		let image = await Task.detached(priority: .utility) { () -> UIImage? in
			guard
				let uuid,
				let iconName,
				!iconName.isEmpty
			else {
				return nil
			}

			let baseDirectory = isSigned
				? FileManager.default.signed(uuid)
				: FileManager.default.unsigned(uuid)

			guard
				let appDirectory = FileManager.default.getPath(in: baseDirectory, for: "app")
			else {
				return nil
			}

			let iconURL = appDirectory.appendingPathComponent(iconName)
			return UIImage(contentsOfFile: iconURL.path)
		}.value

		if let image {
			_cache.setObject(image, forKey: key as NSString)
		}
		return image
	}
}

// MARK: - View
struct FRAppIconView: View {
	private let _app: AppInfoPresentable
	private let _size: CGFloat

	@State private var _image: UIImage?

	init(app: AppInfoPresentable, size: CGFloat = 87) {
		self._app = app
		self._size = size
		// Seed from the cache synchronously (in-memory only, no disk). An
		// already-decoded icon paints on the very first frame with no flash and
		// no main-thread work — this is what makes re-render storms cheap.
		self._image = State(
			initialValue: AppIconLoader.shared.cachedImage(
				forKey: AppIconLoader.cacheKey(for: app)
			)
		)
	}

	var body: some View {
		Group {
			if let image = _image {
				Image(uiImage: image)
					.appIconStyle(size: _size)
			} else {
				Image("App_Unknown")
					.appIconStyle(size: _size)
			}
		}
		// Keyed on the app's identity so a reused cell (scrolling) reloads for
		// the app it now represents. If the icon is already loaded/seeded this
		// does nothing.
		.task(id: AppIconLoader.cacheKey(for: _app)) {
			if _image == nil {
				_image = await AppIconLoader.shared.image(for: _app)
			}
		}
	}
}
