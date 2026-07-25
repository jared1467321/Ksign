//
//  FRAppIconView.swift
//  Feather
//
//  Created by samara on 18.04.2025.
//
//  The old version called `UIImage(contentsOfFile:)` directly inside `body`.
//  That reads the file and decodes the full-resolution image *synchronously on
//  the main thread*, once per row, with no caching — and re-runs on every body
//  invalidation (first render, tab switch, typing in search, the fetch's
//  animation). With a large library that stalls the main thread right after the
//  UI draws: the classic "app opens, then freezes" on launch.
//
//  This version instead:
//    - decodes off the main thread,
//    - downsamples to the display size (ImageIO thumbnail, not a full decode),
//    - caches the result so each icon is decoded once, not on every body pass.
//  The initializer is unchanged, so no call sites need to change.
//

import SwiftUI
import UIKit

struct FRAppIconView: View {
	private var _app: AppInfoPresentable
	private var _size: CGFloat

	@State private var _icon: UIImage?

	init(app: AppInfoPresentable, size: CGFloat = 87) {
		self._app = app
		self._size = size
	}

	var body: some View {
		Group {
			if let icon = _icon {
				Image(uiImage: icon)
					.appIconStyle(size: _size)
			} else {
				Image("App_Unknown")
					.appIconStyle(size: _size)
			}
		}
		// Re-runs when the row is reused for a different app, and cancels when
		// the row scrolls away — so scrolled-past decodes don't pile up.
		.task(id: _cacheKey) {
			await _loadIcon()
		}
	}

	// Identity for caching. Each sign/import creates a new row with a new uuid,
	// so keying on uuid (+ icon name) means a re-signed app naturally gets a
	// fresh entry instead of showing its old icon. Size isn't part of the key:
	// SwiftUI scales the one decoded image to whatever frame the call site asks.
	private var _cacheKey: String {
		let uuid = _app.uuid ?? "?"
		let iconName = _app.icon ?? "?"
		return "\(uuid)|\(iconName)"
	}

	@MainActor
	private func _loadIcon() async {
		let key = _cacheKey

		// Fast path: already decoded. NSCache reads are synchronous, so a hit
		// applies immediately with no placeholder flash.
		if let cached = AppIconCache.shared.image(forKey: key) {
			_icon = cached
			return
		}

		// Clear any icon left over from a reused row so we never show the wrong
		// app's icon while the new one decodes.
		_icon = nil

		guard
			let dir = Storage.shared.getAppDirectory(for: _app),
			let iconName = _app.icon, !iconName.isEmpty
		else { return }

		let url = dir.appendingPathComponent(iconName)

		let decoded = await Task.detached(priority: .userInitiated) {
			_decodedAppIcon(atPath: url.path)
		}.value

		// `.task(id:)` cancels us if the row was reused; don't apply a stale image.
		guard !Task.isCancelled, let decoded else { return }

		AppIconCache.shared.set(decoded, forKey: key)
		_icon = decoded
	}
}

// MARK: - Cache

// Memory-only, thread-safe, self-evicting. Icons are tiny once downsampled;
// this exists purely to keep decoding off the main thread and out of `body`.
private final class AppIconCache {
	static let shared = AppIconCache()

	private let _cache = NSCache<NSString, UIImage>()

	private init() {
		_cache.countLimit = 256
	}

	func image(forKey key: String) -> UIImage? {
		_cache.object(forKey: key as NSString)
	}

	func set(_ image: UIImage, forKey key: String) {
		_cache.setObject(image, forKey: key as NSString)
	}
}

// MARK: - Decoding

// App-bundle icons are frequently stored as iOS-optimised "CgBI" PNGs (byte-
// swapped channels, premultiplied alpha). UIImage decodes those; ImageIO /
// CGImageSource does not. So decode with UIImage, and force the decode to
// happen here — off the main thread — with `preparingForDisplay()`, which is
// documented as safe to call from a background thread.
private func _decodedAppIcon(atPath path: String) -> UIImage? {
	guard let image = UIImage(contentsOfFile: path) else { return nil }
	return image.preparingForDisplay() ?? image
}
