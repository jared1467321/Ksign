# Aurora reference and verification

`AuroraShaderReference.metal` is the original shader from the supplied
`Tallyapp-Beautiful.zip`, with its SHA-256 recorded in the header. It is a test
fixture, outside the application and NimbleKit targets. Keep this copy unchanged
when optimizing the production shader.

The source audit confirmed the same installation words, generation counter,
identity mixing, star seeds, particle generator, ten particle parameter ranges,
and adaptive quality controller. The optimized renderer retains all 128 identity
bits and all 41 random streams, including 2–6 independently generated curtains,
their geometry/detail/palette/motion, and 0–2 coronas.

The pre-build theme test runner has been removed. Its differential tests
compared the production shader directly with the original:

- 15,908 exact identity values across 388 identities, including every identity bit.
- 82,944 exact sky pixels across multiple identities, times and viewport origins;
  the sampled identities cover every curtain count and corona count.
- 216,000 exact optics pixels across five render scales and overlapping/absent panes.
- Particle cache reuse, original particle parameters, shuffle invalidation and release.
- Bounded pane selection against the previous full sort across 1,026 layouts,
  including equal-area/equal-origin ties.
- Display-link ownership, orphan cleanup, stop/restart and the existing adaptive
  quality ramp and system-pressure caps, using UIKit interface doubles.

The fixed corpus still uses fewer texture samples: 17,335,296 → 15,375,692 noise
reads and 570,606 → 433,136 optics reads. These are test-harness operation counts,
not measurements of device power or frame time. Cached identity uniforms, cached
noise, cached particle layouts, the 30 Hz clock, adaptive resolution, and inactive
animation suspension remain in production.

Layout-dependent shader arguments, pane optics and particle lookups are prepared
outside the timeline callback. Only time-dependent rendering runs at 30 Hz;
layout, identity and render-scale changes rebuild the captured inputs. Pane
selection scans row geometry once and retains at most two candidates rather than
mapping and sorting every pane. Display links use a weak target and invalidate
themselves on the next callback if their backdrop controller has been released.
Disabled Aurora backdrops do not install a viewport observer. These changes
reduce temporary allocations and retention risk; device memory and frame-time
improvements have not been measured by this test harness.

Pane geometry now feeds `backgroundPreferenceValue` directly instead of state
on the foreground canvas modifier. An equality check on the backdrop's base and
selected panes avoids updates when only unselected panes move; the backdrop's
own clock, quality, accessibility and appearance dependencies remain live. The
theme editor's geometry polling task exists only while picking and is cancelled
when picking ends or its window disappears. Shader formulas, sampling, animation
cadence and glass surface parameters are unchanged.

There is no appearance parameter in the Aurora shader or backdrop. Both modes
render the original RGB scene and star opacities. With Adaptive Text Colors
enabled, shared SwiftUI text, headings, list foregrounds and inline glass titles
use a procedural Metal glyph fill on iOS 17+. Each text pixel evaluates the
same sky function as the backdrop, with the same 128-bit identity, cached noise,
window coordinates, intensity and elapsed time. The fill normalizes the sky's
chromatic component before taking its RGB complement: green gives magenta,
blue gives yellow, and red gives cyan, including in dark skies. Saturation is
independent of sky exposure; the strongest ink channel stays at 1. Only colors
below an encoded RGB brightness of 0.42 receive a white lift, which preserves
their complementary hue. Near-neutral sky samples transition smoothly to white.
This is deliberately different from raw inversion, which becomes dim over
bright sky, and the rejected hard-light treatment, which compressed all colors
into a narrow pastel-blue range.

The fill samples the procedural sky before pane refraction, glass highlights
and stars. It does not capture the composited screen. Each active foreground
scope has a 30 Hz timeline, paused offscreen, when inactive or under Reduce
Motion. Its geometry tracks the window position, including scrolling and
presentation offsets; the shader's fill bounds span that window so inherited
row/canvas paint does not normalize the sky to a word's own bounds. This adds
sky evaluation for glyph pixels rather than a second full-screen sky renderer.
Device GPU cost and inherited-style alignment still require device validation.
The shared elapsed-time calculation keeps Reduce Motion at the same fixed time
(1.8) for text and backdrop. iOS 16 retains full-strength white difference
blending over the fallback sky. Images and surface paints retain their existing
rendering; status roles and text on filled buttons keep their semantic colors.

The app installs `nbThemeAdaptiveChrome()` outside its tab/navigation containers
to cover native large titles, toolbar glyphs, search text/placeholders and tab
labels/icons. Native controls keep their layout, hit testing, selection, input,
focus and accessibility. Only their glyph paint moves to a transparent SwiftUI
overlay above the native compositing containers. Small alpha bitmaps are cached
until text, selection, font, image, bounds or appearance changes; they never
capture the aurora or read back the whole screen. A weak display-link target
tracks known glyph geometry at up to 30 Hz and discovers/recycles native views
at 4 Hz. It stops while inactive or disabled, restores original masks and search
attributes, and cleans up orphaned owners on its next callback. Empty glyph
captures leave native paint visible and retry at most four times per second. Unknown tab
layouts keep their native paint. Each overlay scans only its own presentation's
controller hierarchy. Glass sheets install a fresh presentation scope with
`nbThemeAdaptiveChrome(inPresentation: true)`; separately presented system panels
are excluded.

`NBSection` uses `nbThemeChromeForeground` to carry header/footer glyphs through
anchor preferences to the same overlay. Its source retains layout/accessibility
and is suppressed only after the overlay actually appears. A container without
an overlay continues drawing the original foreground.

Two tight dark shadows define glyph edges where bright ink alone has poor
contrast, especially over pale or white backings. This is a visual treatment,
not a guarantee of a minimum contrast ratio for every possible background. Disabling
Adaptive Text Colors or Aurora, enabling Reduce Transparency or Increase
Contrast, and previewing or overriding an individual text color restore the
theme's foreground colors. Reports, Live Activities and separately presented
system interfaces retain their existing theme colors.

Validate on an iOS device with the aurora moving behind a large heading and a
small caption, including a single letter crossing two colors. Check both
appearances, scrolling, shuffling, glass sheets, and the iOS 16 fallback. Also
check the adaptive toggle, solid/accessibility surfaces, Reduce Motion, theme
previews and saved element overrides. The preview in `NBAuroraTextStyle.swift`
uses the actual moving aurora, a shuffle button, and fixed black/gray/white
surfaces for checking color response and glyph edges. Check that explicit text
and inherited row/canvas styles sample the same window positions. For native chrome, also check large-title
collapse, tab switching/reselection, RTL layouts, search typing/selection/long
queries/clearing, and toggling Adaptive Text while a search field is focused.
Swift syntax checks on Linux cannot verify SwiftUI's compositor or substitute
for this device check.

Run `python3 Native/Theme/run_text_tests.py --swiftc PATH` to execute production
Metal color/scene math through the existing C++ vector adapters. It tests
complementary hue, saturation/brightness, exposure independence, neutral colors,
premultiplied alpha, offset continuity, and variation across actual auroras.
`--preview-dir DIR` exports four matching sky/ink PPM pairs for inspecting the
color field. These are CPU shader references, not SwiftUI screenshots.

Run `python3 Native/Theme/run_chrome_tests.py` (or pass `--swiftc PATH`) to check
production glyph caching, original-mask restoration, search-attribute restoration,
view recycling, tab element identity, status tint preservation and orphaned
display-link cleanup with platform doubles. These tests do not claim to verify
UIKit drawing or the device compositor and are not part of the app pre-build.

The removed color-conversion tests enforced obsolete day/night recoloring. The
removed UIKit hierarchy doubles tested the old sibling glass panel; the inline
title now owns its glass background in SwiftUI. Device layout and compositor
rendering still require an iOS build.
