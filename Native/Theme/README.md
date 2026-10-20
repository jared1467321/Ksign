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
use a white difference-blended glyph style. Each glyph pixel takes the RGB
complement of its composited backing, including the glass, and follows the
aurora's existing frame cadence. This adds no sampling timer, geometry tracking,
screen capture or second aurora render. Images and surface paints keep their
existing rendering; status roles and text on filled buttons keep their colors.

Fine opposing light/dark shadows help define glyph edges where inversion alone
has poor contrast (notably middle gray). This is a visual treatment, not a
guarantee of a minimum contrast ratio for every possible background. Disabling
Adaptive Text Colors or Aurora, enabling Reduce Transparency or Increase
Contrast, and previewing or overriding an individual text color restore the
theme's foreground colors. Native UIKit search/tab/large-title text, reports,
and Live Activities retain their existing theme colors.

Validate on an iOS device with the aurora moving behind a large heading and a
small caption, including a single letter crossing two colors. Check both
appearances, scrolling, shuffling, glass sheets, and the iOS 16 fallback. Also
check the adaptive toggle, solid/accessibility surfaces, Reduce Motion, theme
previews and saved element overrides. The preview in `NBAuroraTextStyle.swift`
provides moving saturated bands and fixed black/gray/white backings for checking
compositor behavior and glyph edges. Swift syntax checks on Linux cannot verify
SwiftUI's compositor or substitute for this device check.

The removed color-conversion tests enforced obsolete day/night recoloring. The
removed UIKit hierarchy doubles tested the old sibling glass panel; the inline
title now owns its glass background in SwiftUI. Device layout and compositor
rendering still require an iOS build.
