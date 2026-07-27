//
//  FRAppIconView.swift
//  Feather
//
//  Created by samara on 18.04.2025.
//
//  The original called `UIImage(contentsOfFile:)` directly inside `body`, which
//  decoded a full-resolution image synchronously on the main thread on every
//  body invalidation. That was the launch stall.
//
//  Decoding moved off the main thread and behind a cache, which fixed the stall
//  but introduced a placeholder flash. Three things were wrong:
//
//    1. The cache was only read inside `.task`, which runs *after* the first
//       render — so even an already-decoded icon painted `App_Unknown` for a
//       frame first. It's now read synchronously in `init`, so a warm icon is
//       part of the very first frame.
//
//    2. `_icon` was cleared to nil on every cache miss, which dropped a
//       correctly-displayed icon back to the placeholder. It's now only cleared
//       when the view has genuinely been reused for a different app.
//
//    3. Nothing deduplicated concurrent decodes. `InstallProgressView` stacks
//       two of these per app, so a 16-app batch install kicked off 32 competing
//       full-resolution decodes. Requests for the same icon now share one.
//
//  The header used to claim this downsampled. It didn't — that's fixed too, and
//  it's what keeps icons from being evicted and re-decoded later on.
//

import SwiftUI
import UIKit

struct FRAppIconView: View {
	private var _app: AppInfoPresentable
	private var _size: CGFloat

	@State private var _icon: UIImage?
	// The key `_icon` was loaded for. Lets us distinguish "this view is showing
	// the right icon" from "this view was reused and is still showing the
	// previous app's icon", so only the second case gets blanked.
	@State private var _loadedKey: String?

	init(app: AppInfoPresentable, size: CGFloat = 87) {
		self._app = app
		self._size = size

		let key = Self._cacheKey(for: app)
		let cached = AppIconCache.shared.image(forKey: key)

		// Double underscore is not a typo: the property is named `_icon`, and a
		// property wrapper's backing storage is that name with one more
		// underscore in front. This is the standard way to give @State an
		// initial value from init.
		__icon = State(initialValue: cached)
		__loadedKey = State(initialValue: cached != nil ? key : nil)
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
		// Re-runs when the view is reused for a different app.
		.task(id: _cacheKey) {
			await _loadIcon()
		}
	}

	// Identity for caching. Each sign/import creates a new row with a new uuid,
	// so keying on uuid (+ icon name) means a re-signed app naturally gets a
	// fresh entry instead of showing its old icon. Size isn't part of the key:
	// one decoded image is scaled to whatever frame the call site asks for.
	private static func _cacheKey(for app: AppInfoPresentable) -> String {
		"\(app.uuid ?? "?")|\(app.icon ?? "?")"
	}

	private var _cacheKey: String {
		Self._cacheKey(for: _app)
	}

	@MainActor
	private func _loadIcon() async {
		let key = _cacheKey

		// Fast path. Also covers the case where another view decoded this icon
		// between our init and this task running.
		if let cached = AppIconCache.shared.image(forKey: key) {
			_icon = cached
			_loadedKey = key
			return
		}

		// Only blank the view if what's on screen belongs to a different app.
		// Clearing unconditionally is what made good icons drop back to the
		// placeholder.
		if _loadedKey != key {
			_icon = nil
			_loadedKey = nil
		}

		guard
			let dir = Storage.shared.getAppDirectory(for: _app),
			let iconName = _app.icon, !iconName.isEmpty
		else { return }

		let url = dir.appendingPathComponent(iconName)
		let decoded = await AppIconLoader.shared.icon(forKey: key, path: url.path)

		// The view may have been reused while we were waiting; don't apply a
		// stale image over whatever it's showing now.
		guard !Task.isCancelled, _cacheKey == key, let decoded else { return }

		_icon = decoded
		_loadedKey = key
	}
}

// MARK: - Loader

// Serialises requests per icon so N views asking for the same image produce one
// decode instead of N. The decode itself is a detached task, which deliberately
// does *not* inherit cancellation: a view that scrolls away mid-decode still
// leaves a warm cache entry behind rather than throwing the work away.
private actor AppIconLoader {
	static let shared = AppIconLoader()

	private var _inFlight: [String: Task<UIImage?, Never>] = [:]

	func icon(forKey key: String, path: String) async -> UIImage? {
		if let cached = AppIconCache.shared.image(forKey: key) {
			return cached
		}

		// Someone else is already decoding this exact icon — wait on theirs.
		if let existing = _inFlight[key] {
			return await existing.value
		}

		let task = Task.detached(priority: .userInitiated) {
			_decodedAppIcon(atPath: path)
		}
		_inFlight[key] = task

		let image = await task.value
		_inFlight[key] = nil

		if let image {
			AppIconCache.shared.set(image, forKey: key)
		}
		return image
	}
}

// MARK: - Cache

// Memory-only, thread-safe, self-evicting. NSCache handles its own locking,
// hence the unchecked conformance.
private final class AppIconCache: @unchecked Sendable {
	static let shared = AppIconCache()

	private let _cache = NSCache<NSString, UIImage>()

	private init() {
		_cache.countLimit = 256
		// Downsampled icons run ~280 KB each, so this holds a couple of hundred
		// of them. Before downsampling a single 1024x1024 icon was 4 MB decoded,
		// which meant a large library blew the cache constantly and icons kept
		// being evicted and re-decoded — visible as them dropping back to the
		// placeholder.
		_cache.totalCostLimit = 64 * 1024 * 1024
	}

	func image(forKey key: String) -> UIImage? {
		_cache.object(forKey: key as NSString)
	}

	func set(_ image: UIImage, forKey key: String) {
		_cache.setObject(image, forKey: key as NSString, cost: image._decodedByteSize)
	}
}

private extension UIImage {
	var _decodedByteSize: Int {
		guard let bitmap = cgImage else { return 0 }
		return bitmap.bytesPerRow * bitmap.height
	}
}

// MARK: - Decoding

// The largest size any call site asks for is the 87pt default; at 3x that's
// 261px. Decoding or caching anything bigger is wasted work and wasted memory.
// If a call site ever asks for something larger than 88pt, raise this.
private let _maxIconPixelSize: CGFloat = 264

private func _decodedAppIcon(atPath path: String) -> UIImage? {
	// App-bundle icons are frequently iOS-optimised "CgBI" PNGs (byte-swapped
	// channels, premultiplied alpha). UIImage decodes those; ImageIO does not,
	// which is why this can't use CGImageSourceCreateThumbnailAtIndex.
	guard let image = UIImage(contentsOfFile: path) else { return nil }

	let pixelWidth = image.size.width * image.scale
	let pixelHeight = image.size.height * image.scale
	let longestEdge = max(pixelWidth, pixelHeight)

	guard longestEdge > _maxIconPixelSize, longestEdge > 0 else {
		// Already small enough. Still force the decode here, off the main thread.
		return image.preparingForDisplay() ?? image
	}

	let ratio = _maxIconPixelSize / longestEdge
	let target = CGSize(
		width: max(1, (pixelWidth * ratio).rounded()),
		height: max(1, (pixelHeight * ratio).rounded())
	)

	let format = UIGraphicsImageRendererFormat.preferred()
	format.scale = 1
	format.opaque = false

	// UIGraphicsImageRenderer is safe off the main thread, and the redraw is
	// what forces the decode — so no full-resolution bitmap ever reaches the
	// main thread, and what lands in the cache is already display-ready.
	let renderer = UIGraphicsImageRenderer(size: target, format: format)
	return renderer.image { _ in
		image.draw(in: CGRect(origin: .zero, size: target))
	}
}
