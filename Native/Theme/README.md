# Aurora reference and verification

The theme test sources, runners and reference fixtures have been removed.
The following records their historical coverage and the production behavior
that still requires device verification.

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

The quality monitor compares delivered callbacks with their scheduled duration
(`targetTimestamp - timestamp`), rather than an unconditional 30 fps target.
Steady system-selected 24 Hz delivery therefore does not reduce resolution or
prevent recovery. Missed scheduled callbacks still reduce quality, and the
thermal/Low Power caps and four-window recovery ramp remain in place.

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
when picking ends or its window disappears. Shader formulas, sampling, backdrop animation
cadence and glass surface parameters are unchanged.

There is no appearance parameter in the Aurora shader or backdrop. Both modes
render the original RGB scene and star opacities. With Adaptive Text Colors
enabled, shared SwiftUI text, headings, list foregrounds and inline glass titles
use a shared procedural color map on iOS 17+. A single 192 × 384 Metal compute
pass evaluates the same sky function as the backdrop, with the same 128-bit
identity, cached noise, intensity and elapsed-time calculation. Each glyph
pixel interpolates four neighboring cached colors at its window position. The fill normalizes the sky's
chromatic component before taking its RGB complement: green gives magenta,
blue gives yellow, and red gives cyan, including in dark skies. Saturation is
independent of sky exposure; the strongest ink channel stays at 1. Only colors
below an encoded RGB brightness of 0.42 receive a white lift, which preserves
their complementary hue. Near-neutral sky samples transition smoothly to white.
This is deliberately different from raw inversion, which becomes dim over
bright sky, and the rejected hard-light treatment, which compressed all colors
into a narrow pastel-blue range.

The map samples the procedural sky before pane refraction, glass highlights
and stars. It does not capture the composited screen. One shared 15 Hz clock
serves every visible text scope. The serial worker allows only one GPU request
in flight, copies the small generated map into immutable RGBA data off the main
thread, and caches a single shared shader argument. Raw bytes avoid image
color-space conversions. The glyph shader interpolates these bytes without
running the sky or reading the procedural noise texture. Render work is bounded
at 73,728 sky evaluations per map, independent of glyph count or display scale.
The map is 294,912 bytes (about 4.2 MiB/s at 15 Hz before uploads/copies).
The text cadence is half the backdrop's 30 Hz cadence; map resolution, color
math and glyph sharpness are unchanged. This halves scheduled map renders and
paint deliveries, not necessarily total UI cost. Device measurements are still
needed to assess responsiveness and whether color transitions look smooth.

The map cache is not an ObservableObject and does not broadcast frames to
retained views. Each scope owns a lease and a separate observable paint object;
only active leases receive frames. The scope observes its lease, while its
small foreground view observes paint, so color delivery does not trigger scope
geometry work. A frame ID suppresses duplicate delivery when a scope registers
again. Offscreen scopes clear their paint once, releasing the shader buffer,
and receive no further frame notifications. On reentry they immediately receive
the latest matching cached frame. Reduce Motion clients receive only the frozen
cache, including when animated clients are also active.

Adaptive labels now attach one transparent UIKit anchor to their background.
The anchor explicitly accepts the proposed label size. A single shared 15 Hz
layout clock measures presented, attached labels directly in window coordinates.
Changed window/local geometry immediately refreshes native clipping, hidden state and
opacity on that tick. Stationary labels cache that result, including invisibility,
for 0.25 seconds (rechecked on the next tick, about four times per second).
This bounded recheck catches ancestor-only visibility/clipping changes without
walking every label's ancestors on every tick. SwiftUI updates, reparenting,
window changes and suspension invalidate the cache. A zero-sized initial
layout stays registered: the next usable display tick starts color delivery
without another SwiftUI appearance/geometry callback or user interaction. The
same path covers retained cells, tab entry, sheets and drawer detent changes.
Window/local sizes preserve alignment when selection scales a row.

Layout ticks publish only changed visible placements and lease transitions.
Offscreen anchors release paint and do not publish placement or receive animated
frames. Disappeared SwiftUI scopes also unregister their anchors immediately,
even if their native views remain attached to a window. They receive no geometry
polling until they appear again. The layout clock has weak anchor references,
cleans up abandoned anchors, and stops when no anchors remain or the application
becomes inactive. The map
still uses its separate shared 15 Hz clock, serial GPU worker, cached frames and
weak leases. This adds one shared native geometry scan, not one timer or render
per label; device performance still needs measurement with long lists.

Text activation requires both SwiftUI presentation ownership and usable native
layout. `onAppear` grants ownership and `onDisappear` clears paint and withdraws
the anchor from the layout clock. Native attachment and appearance can happen
in either order: the later event registers the anchor. A provisional zero-sized
layout still recovers on its next usable tick without another appearance event.
Queued updates and foregrounding cannot reactivate a disappeared scope. Native
anchor rebinding retires the previous scope outside the SwiftUI update, and
deferred cleanup checks ownership before touching a scope that has moved elsewhere.
No SwiftUI scroll viewport, row-local frame, scene-phase environment change,
or one-shot recovery measurement is required.
The old geometry reporters, row trackers and session measurement revisions have
been removed. `nbThemeTextRow()` and `nbThemeTextViewport()` remain as no-op source
compatibility helpers; existing call sites do not install those observers.
SwiftUI still owns the original controls, layout, accessibility and semantic
foreground styles. Only small foreground views observe placement and paint.

Library, Downloads, Settings and IPA Vault keep inherited adaptive paint disabled
on grouping containers whose labels already have explicit foreground roles.
Vault file/upload equality checks and progress throttling remain in place.

`NBList` keeps the inherited adaptive foreground on rows and a static foreground
on its outer canvas. This avoids a second animated foreground around the entire
Form/List while retaining colors on controls that rely on inherited styles.
Logs likewise animate their explicitly styled lines without an animated canvas.
Capture keeps only a 1,000-entry / 1 MiB recent tail in memory; complete current
session output is streamed to a cache file and exported in bounded chunks off
the main queue. Closed/inactive Logs screens receive no automatic snapshots.
Clearing resets both histories, and capped lists scroll by last-entry identity
instead of count. The session cache is replaced on the next capture session
after app launch, while pause/resume within a launch retains the history.

Shake detection consumes the same 30 Hz readings and uses the same reversal
threshold, timing and cooldown on a serial background operation queue. Only
recognized shakes schedule main-actor work. Each capture owns a fresh detector,
and a generation check rejects queued shakes from a disabled/restarted capture.

Reduce Motion receives a separately cached frame at time 1.8, matching the
backdrop. The attachment checks shader identity so shuffling also refreshes
frozen ink without an animation clock. Shuffling rejects old in-flight work.
Until the matching map arrives, or if Metal setup fails, text retains its visible
white-difference fallback. Render failures receive one immediate retry, then
stop until a new presentation or foreground return permits recovery. Existing
valid paint survives failed refreshes. Application suspension stops both clocks
and invalidates pre-suspension GPU results.

The removed map tests compiled the production attachment/clock and map scheduler
against UIKit/GPU boundary doubles. They verified a zero-to-valid layout with no
layout callbacks, hidden-tab return, stationary drawer expansion, clipping,
selection scale, unchanged-frame suppression, Reduce Motion/shuffle, foreground
return, detachment and weak cleanup. A 103-row / 309-label fixture verified that
only the 24 visible labels receive paint and all anchors share one layout clock.
These checks do not execute UIKit or SwiftUI's actual compositor; verify initial
colors on an iOS build in Settings, Downloaded, Signed and IPA Vault.

The cached grid approximates the per-pixel source, especially around very sharp
hue boundaries. The fixed CPU corpus measures average maximum-channel error
about 0.00263, 95th-percentile error about 0.00683, and comparable variation across
8-point spans (5,536 cached versus 5,517 direct samples above a 0.015 threshold).
These are shader-reference results, not iOS frame-time or visual measurements.
Device checks still need to confirm performance, buffer binding and inherited
foreground alignment. Images and surfaces retain their existing rendering;
status roles and text on filled buttons keep their semantic colors.

The app installs `nbThemeAdaptiveChrome()` outside its tab/navigation containers
to cover native large titles, toolbar glyphs, search text/placeholders and tab
labels/icons. Native controls keep their layout, hit testing, selection, input,
focus and accessibility. Only their glyph paint moves to a transparent SwiftUI
overlay above the native compositing containers. Small alpha bitmaps are cached
until text, selection, font, image, bounds or appearance changes; they never
capture the aurora or read back the whole screen. A weak display-link target
tracks known glyph geometry at up to 30 Hz and discovers/recycles native views
at 4 Hz. It stops while inactive, disabled, or disappeared, restores original masks
and search attributes, and cleans up orphaned owners on its next callback. Empty glyph
captures leave native paint visible and retry at most four times per second. Unknown tab
layouts keep their native paint. Each overlay scans only its own presentation's
controller hierarchy. Glass sheets install a fresh presentation scope with
`nbThemeAdaptiveChrome(inPresentation: true)`; separately presented system panels
are excluded.

Chrome presentation ownership persists independently of its display link. A
queued layout callback may remember an anchor but cannot start tracking after
`onDisappear` has revoked ownership. Reappearance resumes from the remembered
anchor, including when the native update preceded `onAppear`. Dismantling fences
pending anchor callbacks, and an old anchor's teardown cannot detach its replacement.

Chrome discovery skips table/collection cell trees, including their retained
reuse content. It still visits explicit table headers/footers and visible
collection headers/footers so standalone native search controls there remain
discoverable. Native navigation and tab bar scanning stays in its existing
presentation scope.

`NBSection` uses `nbThemeChromeForeground`. On iOS 17+ its shader-based
header/footer text stays in the original supplementary view. On iOS 16,
difference blending still carries glyphs through anchor preferences to the
overlay, retaining source layout/accessibility and hiding source paint only
after the overlay actually appears. A container without an overlay draws the
original foreground.

One centered black shadow (opacity 0.85, radius 0.35 points) defines glyph edges
without the previous pair's wider, offset dark halo. Color math and fonts are
unchanged. Check darker blue/purple strokes and bright strokes over pale glass
on a device to confirm the tighter shadow's readability. This is a visual treatment,
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
and inherited row/canvas styles sample the same window positions. For a large Library, also check 103 apps, rapid scrolling in both directions,
search, switching Signed/Downloaded, edit selection, rotation/grid layout and
returning from a presentation. Confirm that colors still line up as rows enter,
headers stay visible, and Instruments shows work scaling with visible labels.
For native chrome, also check large-title
collapse, tab switching/reselection, RTL layouts, search typing/selection/long
queries/clearing, and toggling Adaptive Text while a search field is focused.
Swift syntax checks on Linux cannot verify SwiftUI's compositor or substitute
for this device check.

The removed text tests executed production Metal color/scene math through C++
vector adapters. They tested
complementary hue, saturation/brightness, exposure independence, neutral colors,
premultiplied alpha, offset continuity, raw-byte interpolation/orientation,
clamped edges, invalid-map fallback, zero glyph noise reads, and cached-map
fidelity/letter-scale variation across actual auroras.
Their previews exported four matching sky/ink PPM pairs for inspecting the
color field. These were CPU shader references, not SwiftUI screenshots.

The removed map tests executed the production map coordinator and weak clock
with platform/GPU boundary doubles. They checked
sharing across 100 scopes, bounded in-flight work, no redundant setup renders,
and 103 retained rows with eight visible: only visible paint gets notifications,
scrolling transfers delivery immediately, and offscreen paints release buffers.
They also checked window/viewport clipping and partial rows,
stale-frame rejection, offscreen cleanup, frozen/mixed-motion clients, orphaned
lease/owner cleanup, transient failure recovery, suspended-result rejection,
foreground/presentation recovery and bounded retries. The Metal driver and SwiftUI buffer
upload still require an iOS build and device rendering check.

The map suite also executed the production row tracker with three labels per
row: shared movement, per-label partial clipping, offscreen publication counts,
cached reentry, scaled coordinate continuity, changed local layout, scene
activity and Reduce Motion, including 103 retained rows with eight visible.
It executed the production session to check deferred foreground measurements,
rapid-return coalescing and cancellation when inactive, and modeled a culled
row and its invalid local label measurements recovering at their original
coordinates without scrolling or rendering a redundant map. Viewport cases
included the top and bottom visible strips, partial labels, parent clipping and
the window boundary. Initial readiness tests covered all 120 orders of row, label,
appearance, window and clipping measurements without scrolling. The production
UIKit reader ran with layout/conversion doubles to check late attachment,
zero-size layout, unchanged-position reports, 100 coalesced requests, drawer
resizing and reattachment. The production viewport measurement owner was also
tested for both callback orders, preservation of the latest SwiftUI frame,
deferred window reports, moved/resized drawers and temporary zero-size recovery.
SwiftUI task scheduling, actual coordinate conversion
and the reported iPhone appearance still require an iOS build and device check.

The removed chrome tests checked production glyph caching, original-mask
restoration, search-attribute restoration,
view recycling, tab element identity, status tint preservation and orphaned
display-link cleanup with platform doubles. These tests did not verify
UIKit drawing or the device compositor and were not part of the app pre-build.
Discovery checks also covered 206 table/grid cells with descendants that reject
traversal, while retaining navigation glyphs and explicit header search fields.

The removed color-conversion tests enforced obsolete day/night recoloring. The
removed UIKit hierarchy doubles tested the old sibling glass panel; the inline
title now owns its glass background in SwiftUI. Device layout and compositor
rendering still require an iOS build.
