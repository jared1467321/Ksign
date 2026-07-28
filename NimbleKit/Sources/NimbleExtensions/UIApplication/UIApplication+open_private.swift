//
//  UIApplication+open.swift
//  Feather
//
//  Created by samara on 21.04.2025.
//

import UIKit.UIApplication

extension UIApplication {
	/// Opens an app with an identifier
	/// - Parameter identifier: Application identifier
	static public func openApp(with identifier: String) {
		let classNameBase64 = "TFNBcHBsaWNhdGlvbldvcmtzcGFjZQ==" 			// LSApplicationWorkspace
		let defaultSelectorBase64 = "ZGVmYXVsdFdvcmtzcGFjZQ=="     			// defaultWorkspace
		let openSelectorBase64 = "b3BlbkFwcGxpY2F0aW9uV2l0aEJ1bmRsZUlEOg==" // openApplicationWithBundleID:
		
		guard
			let classNameData = Data(base64Encoded: classNameBase64),
			let defaultSelectorData = Data(base64Encoded: defaultSelectorBase64),
			let openSelectorData = Data(base64Encoded: openSelectorBase64),
			let className = String(data: classNameData, encoding: .utf8),
			let defaultSelector = String(data: defaultSelectorData, encoding: .utf8),
			let openSelector = String(data: openSelectorData, encoding: .utf8)
		else {
			return
		}
		
		guard
			let workspaceClass = NSClassFromString(className) as? NSObject.Type,
			let workspace = workspaceClass.perform(NSSelectorFromString(defaultSelector))?.takeUnretainedValue()
		else {
			return
		}
		
		_ = workspace.perform(NSSelectorFromString(openSelector), with: identifier)
	}
    
    
    /// Returns install progress for a bundle identifier (0.0 – 1.0)
    /// - Parameters:
    ///   - identifier: Bundle identifier
    ///   - synchronous: Whether the call should block
    /// - Returns: Progress value if available
    static public func installProgress(
        for identifier: String,
        makeSynchronous synchronous: Bool = true
    ) -> Double? {

        let classNameBase64 = "TFNBcHBsaWNhdGlvbldvcmtzcGFjZQ==" // LSApplicationWorkspace
        let defaultSelectorBase64 = "ZGVmYXVsdFdvcmtzcGFjZQ=="   // defaultWorkspace
        let progressSelectorBase64 = "aW5zdGFsbFByb2dyZXNzRm9yQnVuZGxlSUQ6bWFrZVN5bmNocm9ub3VzOg==" // installProgressForBundleID:makeSynchronous:

        guard
            let className = String(data: Data(base64Encoded: classNameBase64)!, encoding: .utf8),
            let defaultSelector = String(data: Data(base64Encoded: defaultSelectorBase64)!, encoding: .utf8),
            let progressSelector = String(data: Data(base64Encoded: progressSelectorBase64)!, encoding: .utf8),
            let workspaceClass = NSClassFromString(className) as? NSObject.Type,
            let workspace = workspaceClass.perform(NSSelectorFromString(defaultSelector))?.takeUnretainedValue()
        else { return nil }

        let result = workspace.perform(
            NSSelectorFromString(progressSelector),
            with: identifier,
            with: synchronous
        )?.takeUnretainedValue()

        if let number = result as? Progress {
            return number.fractionCompleted
        }

        return nil
    }

    /// The version of the installed app with this bundle identifier, as a single
    /// comparable string, or nil when nothing is installed under it.
    ///
    /// This is the level-triggered counterpart to `installProgress(for:)`.
    /// Progress is a transient — it rises, falls, and is gone — so anything that
    /// has to *witness* it is at the mercy of how often it gets to sample. The
    /// installed version is a fact that sits still, so a poller can miss fifty
    /// samples in a row and still get the right answer on the fifty-first.
    ///
    /// Short version and build are combined because either can move on its own.
    /// - Parameter identifier: Bundle identifier
    /// - Returns: e.g. "1.4.2 (37)", or nil when not installed
    static public func installedVersionIdentity(for identifier: String) -> String? {
        let classNameBase64 = "TFNBcHBsaWNhdGlvblByb3h5"                     // LSApplicationProxy
        let proxySelectorBase64 = "YXBwbGljYXRpb25Qcm94eUZvcklkZW50aWZpZXI6" // applicationProxyForIdentifier:
        let shortSelectorBase64 = "c2hvcnRWZXJzaW9uU3RyaW5n"                 // shortVersionString
        let buildSelectorBase64 = "YnVuZGxlVmVyc2lvbg=="                     // bundleVersion

        guard
            let className = String(data: Data(base64Encoded: classNameBase64)!, encoding: .utf8),
            let proxySelectorName = String(data: Data(base64Encoded: proxySelectorBase64)!, encoding: .utf8),
            let proxyClass = NSClassFromString(className) as? NSObject.Type
        else { return nil }

        let proxySelector = NSSelectorFromString(proxySelectorName)
        guard proxyClass.responds(to: proxySelector) else { return nil }

        // Object returns throughout — never a BOOL through `perform`, which
        // reinterprets a register as a pointer and can't be trusted.
        guard let proxy = proxyClass.perform(proxySelector, with: identifier)?.takeUnretainedValue() as? NSObject else {
            return nil
        }

        func string(_ base64: String) -> String? {
            guard let name = String(data: Data(base64Encoded: base64)!, encoding: .utf8) else { return nil }
            let selector = NSSelectorFromString(name)
            guard proxy.responds(to: selector) else { return nil }
            return proxy.perform(selector)?.takeUnretainedValue() as? String
        }

        let short = string(shortSelectorBase64)
        let build = string(buildSelectorBase64)

        // A proxy for an app that isn't installed still exists — it just has
        // nothing to say about versions. That nil is the "not installed"
        // answer, and it's what makes a fresh install detectable.
        if short == nil, build == nil { return nil }

        return "\(short ?? "?") (\(build ?? "?"))"
    }
}
