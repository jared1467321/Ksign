//
//  ThemeReportBridge.swift
//  Ksign
//
//  Bridges Crypt Check's generated HTML reports into the native in-place theme
//  editor. The report remains the real report: DOM hit-testing resolves the
//  semantic CSS variables under the user's finger, and live preview updates
//  those variables in the open WKWebView without regenerating a mock screen.
//

import Foundation
import UIKit
import WebKit
import NimbleExtensions
import NimbleViews

final class ThemeReportBridge {
    static let shared = ThemeReportBridge()

    private struct Variable {
        let cssName: String
        let role: NBThemeRole
    }

    private static let variables: [Variable] = [
        .init(cssName: "--bg", role: .reportBackground),
        .init(cssName: "--card", role: .reportCard),
        .init(cssName: "--border", role: .reportBorder),
        .init(cssName: "--text", role: .reportText),
        .init(cssName: "--dim", role: .reportDim),
        .init(cssName: "--green", role: .reportSuccess),
        .init(cssName: "--red", role: .reportDanger),
        .init(cssName: "--orange", role: .reportWarning),
        .init(cssName: "--green-fill", role: .reportSuccessFill),
        .init(cssName: "--orange-fill", role: .reportWarningFill),
        .init(cssName: "--red-fill", role: .reportDangerFill),
        .init(cssName: "--tap-highlight", role: .reportTapHighlight),
        .init(cssName: "--cyan", role: .reportAccent),
        .init(cssName: "--pink", role: .reportPink),
        .init(cssName: "--purple", role: .reportPurple),
        .init(cssName: "--blue", role: .reportBlue),
        .init(cssName: "--lime", role: .reportLime),
        .init(cssName: "--interactive-fill", role: .reportInteractiveFill),
        .init(cssName: "--interactive-border", role: .reportInteractiveBorder),
        .init(cssName: "--selected-fill", role: .reportSelectedFill),
        .init(cssName: "--selected-text", role: .reportSelectedText),
        .init(cssName: "--dropdown", role: .reportDropdown),
        .init(cssName: "--shadow", role: .reportShadow)
    ]

    private let webViews = NSHashTable<WKWebView>.weakObjects()

    private init() {}

    func register(_ webView: WKWebView) {
        precondition(Thread.isMainThread)
        webViews.add(webView)
    }

    func unregister(_ webView: WKWebView) {
        precondition(Thread.isMainThread)
        webViews.remove(webView)
    }

    func visibleWebViews(in window: UIWindow, within presentationRoot: UIView) -> [WKWebView] {
        precondition(Thread.isMainThread)
        return webViews.allObjects.filter { webView in
            guard webView.window === window,
                  !webView.isHidden,
                  webView.alpha > 0.02,
                  webView === presentationRoot || webView.isDescendant(of: presentationRoot) else { return false }
            let frame = NBThemeInspectorRegistry.visibleFrame(of: webView, in: window)
            return !frame.isNull && frame.width > 1 && frame.height > 1 && frame.intersects(window.bounds)
        }
    }

    func frame(of webView: WKWebView, in window: UIWindow) -> CGRect {
        NBThemeInspectorRegistry.visibleFrame(of: webView, in: window)
    }

    /// Resolve semantic report roles for the exact DOM content under a screen
    /// point. CSS rules are inspected for var(--...) references so roles remain
    /// distinguishable even when two theme colors happen to share the same RGB.
    func roles(at screenPoint: CGPoint, in webView: WKWebView, window: UIWindow, completion: @escaping ([NBThemeRole]) -> Void) {
        precondition(Thread.isMainThread)
        let local = webView.convert(screenPoint, from: window)
        guard webView.bounds.contains(local) else {
            completion([])
            return
        }

        let roleMap = Dictionary(uniqueKeysWithValues: Self.variables.map { ($0.cssName, $0.role.rawValue) })
        guard let mapData = try? JSONSerialization.data(withJSONObject: roleMap),
              let mapJSON = String(data: mapData, encoding: .utf8) else {
            completion([])
            return
        }

        let script = """
        (function() {
          const roleMap = \(mapJSON);
          const viewport = window.visualViewport;
          const scale = viewport ? viewport.scale : 1;
          const x = \(Double(local.x)) / scale + (viewport ? viewport.offsetLeft : 0);
          const y = \(Double(local.y)) / scale + (viewport ? viewport.offsetTop : 0);
          const start = document.elementFromPoint(x, y);
          if (!start) return [];

          function addFromValue(value, out) {
            if (!value) return;
            Object.keys(roleMap).forEach(function(cssName) {
              if (value.indexOf('var(' + cssName + ')') !== -1 && out.indexOf(roleMap[cssName]) === -1) {
                out.push(roleMap[cssName]);
              }
            });
          }

          function walkRules(ruleList, element, out, colorOnly) {
            if (!ruleList) return;
            for (let i = 0; i < ruleList.length; i++) {
              const rule = ruleList[i];
              if (rule.cssRules) {
                walkRules(rule.cssRules, element, out, colorOnly);
                continue;
              }
              if (!rule.selectorText || !rule.style) continue;
              let matches = false;
              try { matches = element.matches(rule.selectorText); } catch (_) { matches = false; }
              if (!matches) continue;
              for (let p = 0; p < rule.style.length; p++) {
                const property = rule.style[p];
                if (colorOnly && property !== 'color' && property !== '-webkit-text-fill-color') continue;
                addFromValue(rule.style.getPropertyValue(property), out);
              }
            }
          }

          function directRoles(element, colorOnly) {
            const out = [];
            for (let i = 0; i < document.styleSheets.length; i++) {
              let rules = null;
              try { rules = document.styleSheets[i].cssRules; } catch (_) { rules = null; }
              walkRules(rules, element, out, colorOnly);
            }
            if (element.style) {
              for (let p = 0; p < element.style.length; p++) {
                const property = element.style[p];
                if (colorOnly && property !== 'color' && property !== '-webkit-text-fill-color') continue;
                addFromValue(element.style.getPropertyValue(property), out);
              }
            }
            return out;
          }

          const result = [];
          function append(values) {
            values.forEach(function(value) {
              if (result.indexOf(value) === -1) result.push(value);
            });
          }

          // Direct styling on the exact element is the strongest signal.
          append(directRoles(start, false));

          // If foreground color is inherited, find the nearest semantic color
          // declaration so tapping ordinary report text still selects Report Text.
          if (directRoles(start, true).length === 0) {
            let inherited = start.parentElement;
            while (inherited) {
              const inheritedColor = directRoles(inherited, true);
              if (inheritedColor.length) {
                append(inheritedColor);
                break;
              }
              inherited = inherited.parentElement;
            }
          }

          // Include containing semantic surfaces too. Do not truncate roles:
          // the scrollable chooser must also expose the report background.
          let parent = start.parentElement;
          while (parent) {
            append(directRoles(parent, false));
            parent = parent.parentElement;
          }

          return result;
        })();
        """

        webView.evaluateJavaScript(script) { result, _ in
            let rawRoles = result as? [String] ?? []
            completion(rawRoles.compactMap(NBThemeRole.init(rawValue:)))
        }
    }

    /// Applies the currently active value for every report role, including an
    /// unsaved live preview, to an already-open report.
    func refreshAllOpenReports() {
        precondition(Thread.isMainThread)
        for webView in webViews.allObjects where webView.window != nil {
            applyCurrentTheme(to: webView)
        }
    }

    func applyCurrentTheme(to webView: WKWebView) {
        precondition(Thread.isMainThread)
        let themes = NBThemeManager.shared
        let statements = Self.variables.map { variable in
            let value = themes.activeColor(for: variable.role).cssRGBA
            return "document.documentElement.style.setProperty('\(variable.cssName)', '\(value)');"
        }.joined(separator: "\n")

        webView.backgroundColor = themes.activeColor(for: .reportBackground).uiColor
        webView.scrollView.backgroundColor = themes.activeColor(for: .reportBackground).uiColor
        webView.evaluateJavaScript("(function(){\n\(statements)\n})();", completionHandler: nil)
    }

    /// Generated reports are standalone HTML files. Keep their persisted CSS
    /// defaults synchronized before export so a report saved after theme edits
    /// opens with the same colors the user was looking at in-app.
    func persistCurrentTheme(to urls: [URL]) throws {
        let theme = NBThemeManager.shared.activeTheme
        for url in urls {
            var html = try String(contentsOf: url, encoding: .utf8)
            var changed = false

            for variable in Self.variables {
                let escapedName = NSRegularExpression.escapedPattern(for: variable.cssName)
                let pattern = "(\(escapedName)\\s*:)\\s*[^;]+;"
                let regex = try NSRegularExpression(pattern: pattern)
                let range = NSRange(html.startIndex..<html.endIndex, in: html)
                let replacement = "$1\(theme.color(for: variable.role).cssRGBA);"
                let updated = regex.stringByReplacingMatches(in: html, range: range, withTemplate: replacement)
                if updated != html {
                    html = updated
                    changed = true
                }
            }

            if changed {
                try html.write(to: url, atomically: true, encoding: .utf8)
            }
        }
    }
}

/// Shared navigation delegate for both Crypt Check report variants. Reapplies
/// native theme values after the file finishes loading because an earlier
/// updateUIView call may occur before the DOM exists.
final class ThemeReportNavigationCoordinator: NSObject, WKNavigationDelegate {
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        ThemeReportBridge.shared.applyCurrentTheme(to: webView)
    }
}
