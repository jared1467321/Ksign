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
and stars. It does not capture the composited screen. One shared 30 Hz clock
serves every visible text scope. The serial worker allows only one GPU request
in flight, copies the small generated map into immutable RGBA data off the main
thread, and caches a single shared shader argument. Raw bytes avoid image
color-space conversions. The glyph shader interpolates these bytes without
running the sky or reading the procedural noise texture. Render work is bounded
at 73,728 sky evaluations per map, independent of glyph count or display scale.
The map is 294,912 bytes (about 8.4 MiB/s at 30 Hz before uploads/copies).

The map cache is not an ObservableObject and does not broadcast frames to
retained views. Each scope owns a lease and a separate observable paint object;
only active leases receive frames. The scope observes its lease, while its
small foreground view observes paint, so color delivery does not trigger scope
geometry work. A frame ID suppresses duplicate delivery when a scope registers
again. Offscreen scopes clear their paint once, releasing the shader buffer,
and receive no further frame notifications. On reentry they immediately receive
the latest matching cached frame. Reduce Motion clients receive only the frozen
cache, including when animated clients are also active.

`NBListAdaptable` supplies a shared text viewport outside the row builder. This
measures the scroll container's full bounds and window conversion once;
safe-area content margins are not subtracted from visible glass-backed content.
Nested viewports still intersect their parent's bounds, and window clipping
excludes content outside the screen.
Descendant labels need no individual UIKit window anchor. Layout measurements
retain their coordinates independently of viewport readiness and clipping.
A positive intersection with
both viewport and window is required, in addition to onAppear and active scene
state: prefetched but offscreen rows cannot register for live paint. Visible
geometry changes update shader coordinates without re-registering an unchanged
lease. Text outside a supplied viewport retains its own window reader and is
clipped against that window.

The Library's navigation canvas, list canvas and section-level inherited text
styles use `adaptsContainerText: false`. They retain their theme foregrounds but
no longer receive animated paint around the app collection. Titles, subtitles,
chevrons, selection icons and headers already have explicit foreground roles;
those individual paints retain their vivid colors. Other screens keep the
existing default for inherited container text. The row collection and native
list/grid containers are unchanged.

Downloads now follows the same policy for its navigation, list and section
containers, supplies one shared text viewport, and installs row tracking on
finished downloads, active downloads and import/status rows. Explicit labels
retain adaptive colors while inherited container styles stay out of the live
paint path. The empty-state overlay keeps its independent foreground tracking.

The IPA Vault and bulk install drawers also disable inherited adaptive paint
on their canvases. Vault file and upload labels use row tracking within each
list's shared viewport, and section titles use chrome foregrounds. File labels
compare their name, size and selection before rebuilding. Download progress
does not observe through the Vault screen; upload progress observes only through
its section, publishes at 0.4-second intervals plus the final byte update, and
compares unchanged upload rows. Directory decoding, sorting and local file
metadata reads run off the main actor. Bulk install cells drop their progress
views and repeating animations on disappearance while jobs continue in the
session. Check both drawers with large queues, active transfers, selection,
scrolling, detent changes and minimize/restore on a device; the Linux suites
cannot measure SwiftUI frame times or verify these presentation lifecycles.

Library and Downloads cells install `nbThemeTextRow()`. One global geometry measurement
tracks the row's movement; titles, subtitles, chevrons and selection glyphs only
report their local offsets when their layout changes. The row tracker updates
small foreground placement objects directly, without publishing movement or
ink through the cell's body or environment. Each label still clips independently
at the viewport edge and retains its own ink lease. The coordinate conversion
accounts for the row's selection scale. Fully offscreen rows retain their latest
geometry without publishing placement or updating their clients on each scroll
step. Disabling adaptive ink or using the iOS 16 fallback bypasses row tracking.

Weak scope leases stop the shared clock when no animated text is visible. A
weak clock target also cleans up a discarded owner. Reduce Motion uses a
separately cached frame at time 1.8, matching the backdrop. Shuffling discards
old in-flight identities. Until a matching map arrives, or if Metal setup fails,
text retains a visible white-difference fallback. A render failure gets one
immediate retry with rebuilt Metal resources; two consecutive failures stop
requests until the app becomes active again or all clients leave and return.
Existing valid paint survives failed refreshes. The app's Aurora activity hook
also suspends the map clock, rejects pre-suspension results (including failures),
and requests fresh animated ink on resume. Text scopes revalidate their leases
on appearance and scene activation. A deferred, coalesced session revision also
requests fresh measurements after foregrounding.
The first active launch also requests this deferred pass, even though the
animation clock already started at session construction. Duplicate activation
does not repeat it, and an interrupted launch cancels delivery until activation
resumes. The pass preserves the current sky identity and running clock.
Each scroll viewport keeps one UIKit reader and requests a report on appearance,
parent/viewport movement and foreground return. Request identities allow unchanged coordinates to report
again; the reader coalesces queued requests, rejects unattached/zero-size layout,
and reports bounds changes as well as window/origin changes. It does not poll.
Completed window reports reconfigure row visibility even when positions are
unchanged. Persistent GeometryReaders capture immutable layout values for the
viewport, each row, and each local label. `NBAuroraTextGeometryReport` delivers
the initial value on appearance and each changed value as layout settles; it
also replays the current value on the session's foreground revision. There are
no temporary probes or one-shot geometry tasks to consume a provisional frame
and then stop reporting. No deferred callback queries a retained GeometryProxy.
UIKit reports update only window coordinates, and the viewport measurement
owner supports either callback arriving first.

Clipping only determines paint eligibility; it never replaces stored geometry
with a null sentinel. A provisional nonempty viewport can still exclude a row
until a tab or drawer finishes layout. Once clipping changes, retained positions
allow immediate activation without scrolling, selection or another measurement.
Offscreen leases still release paint and receive no animation updates. The map
lifecycle suite covers stationary rows across provisional/settled clipping,
drawer expansion, tab return, and offscreen movement, as well as all 120 orders
of the initial row, label, appearance, window and clipping events. These are
production tracker tests with platform doubles; an iOS build must still verify
the SwiftUI callbacks and first visible frame in Settings, Downloaded, Signed
and IPA Vault without touching or scrolling the screen.
The scheduler inspects weak leases in one
pass without rebuilding client collections each tick. Map size, color math and
30 Hz timing are unchanged. iOS 16 retains its difference-blended text.

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
at 4 Hz. It stops while inactive or disabled, restores original masks and search
attributes, and cleans up orphaned owners on its next callback. Empty glyph
captures leave native paint visible and retry at most four times per second. Unknown tab
layouts keep their native paint. Each overlay scans only its own presentation's
controller hierarchy. Glass sheets install a fresh presentation scope with
`nbThemeAdaptiveChrome(inPresentation: true)`; separately presented system panels
are excluded.

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

Run `python3 Native/Theme/run_text_tests.py --swiftc PATH` to execute production
Metal color/scene math through the existing C++ vector adapters. It tests
complementary hue, saturation/brightness, exposure independence, neutral colors,
premultiplied alpha, offset continuity, raw-byte interpolation/orientation,
clamped edges, invalid-map fallback, zero glyph noise reads, and cached-map
fidelity/letter-scale variation across actual auroras.
`--preview-dir DIR` exports four matching sky/ink PPM pairs for inspecting the
color field. These are CPU shader references, not SwiftUI screenshots.

Run `python3 Native/Theme/run_map_tests.py --swiftc PATH` to execute the production
map coordinator and weak clock with platform/GPU boundary doubles. It checks
sharing across 100 scopes, bounded in-flight work, no redundant setup renders,
and 103 retained rows with eight visible: only visible paint gets notifications,
scrolling transfers delivery immediately, and offscreen paints release buffers.
It also checks window/viewport clipping and partial rows,
stale-frame rejection, offscreen cleanup, frozen/mixed-motion clients, orphaned
lease/owner cleanup, transient failure recovery, suspended-result rejection,
foreground/presentation recovery and bounded retries. The Metal driver and SwiftUI buffer
upload still require an iOS build and device rendering check.

The map suite also executes the production row tracker with three labels per
row: shared movement, per-label partial clipping, offscreen publication counts,
cached reentry, scaled coordinate continuity, changed local layout, scene
activity and Reduce Motion, including 103 retained rows with eight visible.
It executes the production session to check deferred foreground measurements,
rapid-return coalescing and cancellation when inactive, and models a culled
row and its invalid local label measurements recovering at their original
coordinates without scrolling or rendering a redundant map. Viewport cases
include the top and bottom visible strips, partial labels, parent clipping and
the window boundary. Initial readiness tests cover all 120 orders of row, label,
appearance, window and clipping measurements without scrolling. The production
UIKit reader runs with layout/conversion doubles to check late attachment,
zero-size layout, unchanged-position reports, 100 coalesced requests, drawer
resizing and reattachment. The production viewport measurement owner is also
tested for both callback orders, preservation of the latest SwiftUI frame,
deferred window reports, moved/resized drawers and temporary zero-size recovery.
SwiftUI task scheduling, actual coordinate conversion
and the reported iPhone appearance still require an iOS build and device check.

Run `python3 Native/Theme/run_chrome_tests.py` (or pass `--swiftc PATH`) to check
production glyph caching, original-mask restoration, search-attribute restoration,
view recycling, tab element identity, status tint preservation and orphaned
display-link cleanup with platform doubles. These tests do not claim to verify
UIKit drawing or the device compositor and are not part of the app pre-build.
Discovery checks also cover 206 table/grid cells with descendants that reject
traversal, while retaining navigation glyphs and explicit header search fields.

The removed color-conversion tests enforced obsolete day/night recoloring. The
removed UIKit hierarchy doubles tested the old sibling glass panel; the inline
title now owns its glass background in SwiftUI. Device layout and compositor
rendering still require an iOS build.
