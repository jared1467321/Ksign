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

There is no appearance parameter in the Aurora shader or backdrop. Both modes
render the original RGB scene and star opacities; text follows the selected theme.
The removed color-conversion tests enforced obsolete day/night recoloring. The
removed UIKit hierarchy doubles tested the old sibling glass panel; the inline
title now owns its glass background in SwiftUI. Device layout and compositor
rendering still require an iOS build.
