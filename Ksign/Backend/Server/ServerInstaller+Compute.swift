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

	// A manifest item for an app this host serves — at this host's port, under
	// that app's id. Works for the host's own app and for each member.
	func manifestItem(id: UUID, app: AppInfoPresentable) -> [String: Any] {[
		"assets": [
			[
				"kind": "software-package",
				"url": _assetURL("/\(id).ipa"),
			],
			// Served from this same server rather than fetched from GitHub, so the
			// prompt icon has no network dependency on an otherwise local install.
			[
				"kind": "display-image",
				"url": _assetURL("/\(id)-57.png"),
			],
			[
				"kind": "full-size-image",
				"url": _assetURL("/\(id)-512.png"),
			],
		],
		"metadata": [
			"bundle-identifier": app.identifier,
			"bundle-version": app.version,
			"kind": "software",
			"title": app.name,
		],
	]}

	private func _assetURL(_ path: String) -> String {
		var comps = URLComponents()
		comps.scheme = ServerInstaller.getServerMethod() == 1 ? "http" : "https"
		comps.host = Self.sni
		comps.path = path
		comps.port = port
		return comps.url!.absoluteString
	}

	// This host's own app first, then every member it also serves. With no
	// members it's a plain single-app manifest.
	var installManifest: [String: Any] {
		var items = [manifestItem(id: id, app: app)]
		for hosted in hostedInstallers {
			items.append(manifestItem(id: hosted.id, app: hosted.app))
		}
		return ["items": items]
	}

	var installManifestData: Data {
		(try? PropertyListSerialization.data(
			fromPropertyList: installManifest,
			format: .xml,
			options: .zero
		)) ?? .init()
	}
}
