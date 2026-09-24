Run `python3 Tests/ThemeEditing/verify.py` from the repository root. These portable
checks compare every current report role with both generators and the bridge,
exercise export substitution on both production CSS templates, and execute the
actual DOM-inspection JavaScript against fixtures using Linux JavaScriptCore
(`libjavascriptcoregtk-4.1`). The JS check explicitly skips if that library is
missing. They do not compile Swift, execute Foundation's regular expressions,
or replace WKWebView/UIKit device testing.

Build on macOS using the repository's `make` workflow (Xcode and the iOS SDK are
required). For compilation without packaging/signing, the makefile's build step
is:

```sh
xcodebuild -project Ksign.xcodeproj -scheme Ksign -configuration Release \
  -arch arm64 -sdk iphoneos -derivedDataPath /tmp/Ksign \
  -skipPackagePluginValidation CODE_SIGNING_ALLOWED=NO \
  ALWAYS_EMBED_SWIFT_STANDARD_LIBRARIES=NO
```

Device verification still required:

- With Theme Edit off, scroll, switch tabs, navigate, and use normal controls.
  Only the paintbrush should intercept touches.
- Select Halloween and enter Theme Edit. Cancel duplication, then accept it.
  Verify the custom copy is selected and Halloween remains unchanged.
- On a real screen, select overlapping text/background roles. The chooser must
  expose all candidates. Drag across a target without activating its control.
- Select a role, adjust every slider and the ColorPicker, collapse/expand and
  move the panel. No yellow target outline may remain anywhere during editing.
  Taps outside the panel must not trigger app actions.
- Cancel and confirm the original color returns. Save and confirm persistence
  after relaunch. Both actions must return to target selection.
- Repeat above on navigation screens, sheets, nested sheets and full-screen
  covers. Covered screens must never offer targets, including during dismissal.
- Scroll before entering selection; offscreen/clipped rows must not be offered.
  Background/foreground the scene while selecting and while editing, rotate,
  and disconnect/reconnect a scene. Check for stale markers/windows/previews.
- On both downloaded IPA and extracted .app reports, use real report content,
  including expanded dropdowns, selected filters and instruction colors.
  Inspect at multiple scroll positions and zoom levels. Check foreground,
  background, border, status fill and shadow roles; overlapping roles must be
  selectable without triggering report links or buttons.
- Change report colors and verify immediate updates without reload or loss of
  scroll position. Cancel must restore them. Save, exit Theme Edit, export each
  report page and open the HTML independently; it must use the saved theme.
  A write failure must show an error instead of presenting stale export data.
- Verify advanced Settings still lists every semantic role, including unused
  colors and external Live Activity surfaces.

Theme-picker ownership checks:

- `python3 Tests/ThemeEditing/verify_picker.py` runs source integration guards.
- `python3 Tests/ThemeEditing/verify_ownership.py` compiles and executes the
  production dependency-free C selection core with clang in a temporary directory.
- [OWNERSHIP.md](OWNERSHIP.md) documents the registration pipeline, ordering
  contract, Downloads regression, limits, and device checks. The portable
  metadata tests do not substitute for SwiftUI/UIKit execution.
