//
//  FeatherApp.swift
//  Feather
//
//  Created by samara on 10.04.2025.
//

import SwiftUI
import Nuke
import OSLog
import IDeviceSwift
import NimbleExtensions
import NimbleViews
import UserNotifications

@main
struct FeatherApp: App {
	@Environment(\.scenePhase) private var scenePhase
	@UIApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
	let heartbeat = HeartbeatManager.shared
	@StateObject var downloadManager = DownloadManager.shared
	@StateObject var themeManager = NBThemeManager.shared
    @AppStorage("Feather.glossySurfaces") private var glossySurfaces = true
    @AppStorage("Feather.auroraBackground") private var auroraBackground = true
    @AppStorage("Feather.userInterfaceStyle") private var userInterfaceStyle = 0
    @StateObject var extractManager = ExtractManager.shared
	@StateObject var logsManager = LogsManager.shared
	let storage = Storage.shared

	var body: some Scene {
		WindowGroup {
            ThemeEditingRoot {
                VStack {
                    // Inline at the top of the stack rather than an overlay: an
                    // overlay would float over each tab's navigation bar title,
                    // which is the one place at the top of the screen that's
                    // already spoken for.
                    ExtractHeaderView(extractManager: extractManager)
                        .transition(.move(edge: .top).combined(with: .opacity))
                    DownloadHeaderView(downloadManager: downloadManager)
                        .transition(.move(edge: .top).combined(with: .opacity))
                    VPNReconnectBannerView()
                    VariedTabbarView()
                        .environment(\.managedObjectContext, storage.context)
                        .onOpenURL(perform: _handleURL)
                        .transition(.move(edge: .top).combined(with: .opacity))
                }
            }
			.nbThemeTint(.accent)
            .nbThemeBackground(.background, ignoresSafeAreaEdges: .all)
            .background(ThemeAppearanceObserver())
            .preferredColorScheme(userInterfaceStyle == 1 ? .light : userInterfaceStyle == 2 ? .dark : nil)
			.animation(.smooth, value: downloadManager.manualDownloads.description)
            .animation(.smooth, value: extractManager.extractItems.description)
			.onReceive(themeManager.objectWillChange) { _ in
				// @Published emits before its value changes. Refresh UIKit and any
				// open Crypt Check DOM on the next main-loop turn so both read the
				// newly selected/live-preview value.
				DispatchQueue.main.async {
					HalloweenAppearance.apply(refreshExistingViews: true)
                    ThemeReportBridge.shared.refreshAllOpenReports()
					// The widget runs in another process. Never push an
					// unsaved editor preview to ActivityKit; commit triggers
					// this normal refresh once the profile is persisted.
					if !themeManager.isColorPreviewActive, #available(iOS 16.2, *) {
						KeepAliveActivityController.shared.refreshTheme()
					}
				}
			}
			.onAppear {
				NBAurora.setActive(scenePhase == .active)
				HalloweenAppearance.apply(refreshExistingViews: true)
				if logsManager.isCapturing { logsManager.startCapture() }
				Task { await VPNReconnectCoordinator.shared.appBecameActive() }
			}
            .onChange(of: glossySurfaces) { _ in
                HalloweenAppearance.apply(refreshExistingViews: true)
            }
            .onChange(of: auroraBackground) { _ in
                HalloweenAppearance.apply(refreshExistingViews: true)
            }
            .onReceive(NotificationCenter.default.publisher(for: UIAccessibility.reduceTransparencyStatusDidChangeNotification)) { _ in
                HalloweenAppearance.apply(refreshExistingViews: true)
            }
            .onReceive(NotificationCenter.default.publisher(for: UIAccessibility.darkerSystemColorsStatusDidChangeNotification)) { _ in
                HalloweenAppearance.apply(refreshExistingViews: true)
            }
			.onChange(of: scenePhase) { phase in
				NBAurora.setActive(phase == .active)
				if phase == .active {
					Task { await VPNReconnectCoordinator.shared.appBecameActive() }
				}
			}
		}
	}
	
	private func _handleURL(_ url: URL) {
		if url.scheme == "ksign" {
			if let fullPath = url.validatedScheme(after: "/source/") {
				FR.handleSource(fullPath) { }
			}
			
			if
				let fullPath = url.validatedScheme(after: "/install/"),
				let downloadURL = URL(string: fullPath)
			{
				_ = DownloadManager.shared.startDownload(from: downloadURL, id: "FeatherManualDownload_\(UUID().uuidString)")
			}
		} else {
			if url.pathExtension == "ipa" || url.pathExtension == "tipa" {
				if FileManager.default.isFileFromFileProvider(at: url) {
					guard url.startAccessingSecurityScopedResource() else { return }
					FR.handlePackageFile(url) { _ in }
				} else {
					FR.handlePackageFile(url) { _ in }
				}
				
				return
			}
			
            if url.pathExtension == "ksign" {
                UIAlertController.showAlertWithOk(title: .localized("Error"), message: .localized("Ksign certificate file (.ksign) is now unsupported from v1.5.1, please refer to use .p12 and .mobileprovision instead."))
            }
		}
	}
	
}

/// Reads the effective window appearance, including changes while following
/// the system. The manager resolves matching colors for SwiftUI and UIKit.
private struct ThemeAppearanceObserver: View {
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        Color.clear
            .frame(width: 0, height: 0)
            .onAppear { NBThemeManager.shared.setColorScheme(scheme) }
            .onChange(of: scheme) { NBThemeManager.shared.setColorScheme($0) }
    }
}

class AppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {

        // Before anything else: appearance proxies only affect views created
        // after they're set, so this has to run ahead of the first window.
        HalloweenAppearance.apply()
        UNUserNotificationCenter.current().delegate = self

        DevicePairingService.registerBackgroundTask()

        _createPipeline()
        _createSourcesDirectory()
        if !UserDefaults.standard.bool(forKey: "hasInitializedBuiltInSources") {
            _initializeBuiltInSources()
            UserDefaults.standard.set(true, forKey: "hasInitializedBuiltInSources")
        }
        
        _clean()
        
        _copyServerCertificates()
        _addDefaultCertificates()

#if SERVER
        // fallback just in case xd
        _downloadSSLCertificates()
#endif
        return true
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping () -> Void) {
        guard response.actionIdentifier == UNNotificationDefaultActionIdentifier,
              let id = response.notification.request.content.userInfo["ksignVPNReconnectID"] as? String,
              response.notification.request.identifier == VPNReconnectCoordinator.notificationIdentifier + "." + id else {
            completionHandler()
            return
        }
        Task { @MainActor in
            await VPNReconnectCoordinator.shared.notificationTapped(id: id)
            completionHandler()
        }
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler(notification.request.identifier.hasPrefix(VPNReconnectCoordinator.notificationIdentifier + ".")
                          ? [.banner, .sound] : [])
    }
    
    private func _initializeBuiltInSources() { 
        Storage.shared.addBuiltInSources()
    }
    
    private func _createPipeline() {
        DataLoader.sharedUrlCache.diskCapacity = 0
        
        let pipeline = ImagePipeline {
            let dataLoader: DataLoader = {
                let config = URLSessionConfiguration.default
                config.urlCache = nil
                return DataLoader(configuration: config)
            }()
            let dataCache = try? DataCache(name: "thewonderofyou.Feather.datacache") // disk cache
            let imageCache = Nuke.ImageCache() // memory cache
            dataCache?.sizeLimit = 500 * 1024 * 1024
            imageCache.costLimit = 100 * 1024 * 1024
            $0.dataCache = dataCache
            $0.imageCache = imageCache
            $0.dataLoader = dataLoader
            $0.dataCachePolicy = .automatic
            $0.isStoringPreviewsInMemoryCache = false
        }
        
        ImagePipeline.shared = pipeline
    }
    
    private func _createSourcesDirectory() {
        let fileManager = FileManager.default
        
        let appDirectory = URL.documentsDirectory.appendingPathComponent("App")
        try? fileManager.createDirectoryIfNeeded(at: appDirectory)
        
        let directories = ["Signed", "Unsigned", "Archives", "Server", "Tweaks"].map {
            appDirectory.appendingPathComponent($0)
        }
        
        for url in directories {
            try? fileManager.createDirectoryIfNeeded(at: url)
        }
    }
    
    private func _clean() {
        // Was a synchronous recursive delete of the entire tmp directory on
        // the main thread. Its cost grew with every batch — a frozen or
        // force-quit run left gigabytes behind — so it eventually froze cold
        // launches before the UI was interactive. Now it runs off the main
        // thread, and is paired with TempMaintenance's idle sweep so tmp is
        // cleared while the app is quiet instead of piling up until launch.
        TempMaintenance.shared.cleanAtLaunch()
    }
    
    private func _copyServerCertificates() {
        let fileManager = FileManager.default
        let serverDirectory = URL.documentsDirectory.appendingPathComponent("App/Server")
        
        try? fileManager.createDirectoryIfNeeded(at: serverDirectory)
        
        let filesToCopy = ["server.crt", "server.pem", "commonName.txt"]
        
        for fileName in filesToCopy {
            guard let bundleURL = Bundle.main.url(forResource: fileName.components(separatedBy: ".").first!, withExtension: fileName.components(separatedBy: ".").last!) else {
                print("File \(fileName) not found in app bundle")
                continue
            }
            
            let destinationURL = serverDirectory.appendingPathComponent(fileName)

            // The bundled identity is only a bootstrap fallback. Preserve a newer
            // certificate pack that was already downloaded successfully.
            guard !fileManager.fileExists(atPath: destinationURL.path) else {
                continue
            }

            do {
                try fileManager.copyItem(at: bundleURL, to: destinationURL)
            } catch {
                Logger.misc.error("Error copying \(fileName): \(error.localizedDescription)")
            }
        }
    }
    
    private func _addDefaultCertificates() {
            guard
                UserDefaults.standard.bool(forKey: "feather.didImportDefaultCertificates") == false,
                let signingAssetsURL = Bundle.main.url(forResource: "signing-assets", withExtension: nil)
            else {
                return
            }
            
            do {
                let folderContents = try FileManager.default.contentsOfDirectory(
                    at: signingAssetsURL,
                    includingPropertiesForKeys: nil,
                    options: .skipsHiddenFiles
                )
                
                for folderURL in folderContents {
                    guard folderURL.hasDirectoryPath else { continue }
                    
                    let certName = folderURL.lastPathComponent
                    
                    let p12Url = folderURL.appendingPathComponent("cert.p12")
                    let provisionUrl = folderURL.appendingPathComponent("cert.mobileprovision")
                    let passwordUrl = folderURL.appendingPathComponent("cert.txt")
                    
                    guard
                        FileManager.default.fileExists(atPath: p12Url.path),
                        FileManager.default.fileExists(atPath: provisionUrl.path),
                        FileManager.default.fileExists(atPath: passwordUrl.path)
                    else {
                        Logger.misc.warning("Skipping \(certName): missing required files")
                        continue
                    }
                    
                    let password = try String(contentsOf: passwordUrl, encoding: .utf8)
                    
                    FR.handleCertificateFiles(
                        p12URL: p12Url,
                        provisionURL: provisionUrl,
                        p12Password: password,
                        certificateName: certName,
                    ) { _ in
                        
                    }
                }
                UserDefaults.standard.set(true, forKey: "feather.didImportDefaultCertificates")
            } catch {
                Logger.misc.error("Failed to list signing-assets: \(error)")
            }
        }

#if SERVER
    private func _downloadSSLCertificates() {
        let serverURL = "https://backloop.dev/pack.json"
        
        FR.downloadSSLCertificates(from: serverURL) { result in
            switch result {
            case .success:
                Logger.misc.info("SSL certificates downloaded successfully")
            case .failure(let error):
                // The staged updater preserves the existing working identity when
                // either download source is temporarily unavailable.
                Logger.misc.error("Failed to update SSL certificates: \(error.localizedDescription)")
            }
        }
    }
#endif
}
