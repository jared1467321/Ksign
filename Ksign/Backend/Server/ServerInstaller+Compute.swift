//
//  Server+Compute.swift
//  feather
//
//  Created by samara on 22.08.2024.
//  Copyright © 2024 Lakr Aream. All Rights Reserved.
//  ORIGINALLY LICENSED UNDER GPL-3.0, MODIFIED FOR USE FOR FEATHER
//

import Foundation
import UIKit.UIGraphicsImageRenderer

extension ServerInstaller {
	var plistEndpoint: URL {
		var comps = URLComponents()
		comps.scheme = ServerInstaller.getServerMethod() == 1 ? "http" : "https"
		comps.host = Self.sni
		comps.path = "/\(id).plist"
		comps.port = port
		return comps.url!
	}

	var payloadEndpoint: URL {
		var comps = URLComponents()
		comps.scheme = ServerInstaller.getServerMethod() == 1 ? "http" : "https"
		comps.host = Self.sni
		comps.path = "/\(id).ipa"
		comps.port = port
		return comps.url!
	}
	
	var pageEndpoint: URL {
		var comps = URLComponents()
		comps.scheme = ServerInstaller.getServerMethod() == 1 ? "http" : "https"
		comps.host = Self.sni
		comps.path = "/install"
		comps.port = port
		return comps.url!
	}
	
	var externalServerLink: String {
		let baseUrl = "https://api.palera.in/genPlist?bundleid=\(app.identifier!)&name=\(app.name!)&version=\(app.version!)&fetchurl=\(self.payloadEndpoint.absoluteString)"
		let encodedBaseUrl = baseUrl.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed)!
		let finalEncodedUrl = encodedBaseUrl.addingPercentEncoding(withAllowedCharacters: .alphanumerics)!
		
		return finalEncodedUrl
	}

	var iTunesLink: String {
		_iTunesLink(with: plistEndpoint.absoluteString)
	}
	
	var iTunesLinkExternal: String {
		_iTunesLink(with: externalServerLink)
	}
	
	private func _iTunesLink(with url: String) -> String {
		return "itms-services://?action=download-manifest&url=\(url)"
	}

	var displayImageSmallEndpoint: URL {
		var comps = URLComponents()
		comps.scheme = "https"
		comps.host = Self.sni
		comps.path = "/app57x57.png"
		comps.port = port
		return comps.url!
	}

	var displayImageLargeEndpoint: URL {
		var comps = URLComponents()
		comps.scheme = "https"
		comps.host = Self.sni
		comps.path = "/app512x512.png"
		comps.port = port
		return comps.url!
	}
	
	var displayImageSmallData: Data {
		_createIcon(57)
	}
	
	var displayImageLargeData: Data {
		_createIcon(512)
	}
	
	private func _createIcon(_ r: CGFloat) -> Data {
		// Prefer the app's own icon. These endpoints existed but nothing ever
		// requested them, so nobody noticed they only ever drew a flat square —
		// which would have been a visible downgrade the moment the manifest
		// started pointing here instead of at the GitHub logo.
		if let real = _appIcon(r) { return real }

		let renderer = UIGraphicsImageRenderer(size: .init(width: r, height: r))
		let image = renderer.image { ctx in
			UIColor.accent.setFill()
			ctx.fill(.init(x: 0, y: 0, width: r, height: r))
		}
		return image.pngData()!
	}

	// Same lookup  uses to draw icons everywhere else.
	private func _appIcon(_ r: CGFloat) -> Data? {
		guard
			let iconPath = Storage.shared.getAppDirectory(for: app)?
				.appendingPathComponent(app.icon ?? ""),
			let image = UIImage(contentsOfFile: iconPath.path)
		else {
			return nil
		}

		let renderer = UIGraphicsImageRenderer(size: .init(width: r, height: r))
		return renderer.image { _ in
			image.draw(in: .init(x: 0, y: 0, width: r, height: r))
		}.pngData()
	}

	var html: String {
		"""
		<html style="background-color: black;">
		<script type="text/javascript">window.location="\(iTunesLinkExternal)"</script>
		</html>
		"""
	}

	// This server's own app as one manifest item.
	var ownManifestItem: [String: Any] {[
		"assets": [
			[
				"kind": "software-package",
				"url": payloadEndpoint.absoluteString,
			],
			// Served from this server rather than fetched from GitHub, so the
			// prompt icon has no network dependency on an otherwise local install.
			[
				"kind": "display-image",
				"url": displayImageSmallEndpoint.absoluteString,
			],
			[
				"kind": "full-size-image",
				"url": displayImageLargeEndpoint.absoluteString,
			],
		],
		"metadata": [
			"bundle-identifier": app.identifier,
			"bundle-version": app.version,
			"kind": "software",
			"title": app.name,
		],
	]}

	// This app first, then any apps batched onto the same prompt. With no extras
	// it's the same single-app manifest as before.
	var installManifest: [String: Any] {
		["items": [ownManifestItem] + extraManifestItems]
	}

	var installManifestData: Data {
		(try? PropertyListSerialization.data(
			fromPropertyList: installManifest,
			format: .xml,
			options: .zero
		)) ?? .init()
	}
}
