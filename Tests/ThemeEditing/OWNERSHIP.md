Theme paint ownership

The old pipeline attached transparent UIView anchors to themed views, queued
registration on the main thread, and stored them in a UUID-keyed dictionary.
At pick time it converted anchor bounds into window coordinates, clipped them,
and sorted overlapping rectangles by area and source identity. There was no
logical ancestry, paint order, or zIndex information. Registration timing and
dictionary order were not drawing order. The overlay's PreferenceKey described
only its own touch regions; it did not carry target ownership. Equal-frame
canvas registrations therefore survived as unrelated exact candidates.

The new pipeline preserves the persistent source-derived elementID and adds
separate runtime-only ownership information:

- modifier scope UUID and logical ancestor UUIDs;
- paint kind and resolved alpha;
- nested, explicitly declared compositing group/layer identifiers and order;
- shape/stroke hit path, explicit clip regions, and inherited view opacity;
- whether the region can claim opaque coverage and whether it is editable.

Canvas/background modifiers give their scope to CONTENT as well as identifying
their background paint. This distinction is essential: putting a scope only
on the background Color would not make the List content its descendant. The
safe-area fix remains: the target anchor is on the painted Color, inside
ignoresSafeArea. UIKit hosting configurations explicitly forward the context,
including updates to already-hosted cells/header content.

No ownership data changes the persisted override key. UUIDs are used only to
relate live scopes and layers; the per-call-site IDs still use fileID/line/column
(and paint kind). Runtime instances of one call site still share an override.
Future source movement can invalidate automatic IDs, as before.

View-builder nbThemeBackground/nbThemeOverlay wrappers preserve SwiftUI's actual
background/overlay operation and add its known content-versus-paint order.
nbThemePaintGroup/nbThemePaintLayer annotate real ZStack siblings; the latter
also applies the matching zIndex. Nested layer paths preserve OUTER ordering
when a child introduces its own group. There is no inference from UIView
subview index, callback timing, or PreferenceKey reduction. Arbitrary unannotated
zIndex is not recoverable from this registry.

The platform-independent NBThemePicking C target is local to NimbleKit and has
no third-party dependency. The Swift adapter snapshots geometry/paths and sends
only numeric metadata to this same production selector that the Linux tests
execute. It does not render or sample pixels.

Selection rules, in order:

1. Reject invalid/zero-size/outside frames, path/clip misses and effectively
   invisible paints. Positive sub-point separators remain valid.
2. Establish known order from matching explicit layer groups, nested background
   ownership, and ancestor overlay ownership. Native navigation/tab backgrounds
   precede canvases extending underneath their safe-area regions.
3. Eliminate a lower owner only where an opaque, covering, known-front region
   hits the same tap. Transparent paints retain contributing lower owners.
4. Topologically order remaining targets; known order always precedes heuristics.
5. Between unrelated targets, a much smaller region beats a giant one. For
   similarly sized regions: foreground/stroke, control, fill/overlay, background,
   canvas, then shadow. Smaller area and deeper ancestry break remaining ties.
   Source identity supplies a stable fallback, never asserted as visual order.
6. Map output indices back to their original records and elementIDs. Content
   blockers do not become editable candidates. The UI deduplicates shared
   override IDs and semantic-role choices, not distinct paints with equal frames.

Downloads regression trace (empty List area):

Before: app canvas, navigation canvas and List canvas all hit. Equal/near-equal
areas passed the old area window and all three exact IDs survived.
After: List canvas carries navigation/app canvas ancestors. Its opaque paint at
the point excludes both covered canvases. The selected record retains the List
call-site elementID. THIS ELEMENT saves that key, which the SAME List paint
resolves on redraw. ALL Page Background remains the separate role save path.
A transparent List canvas keeps the contributing lower background selectable.
No DownloaderView-specific selector condition was introduced.

Clipping/lifetime/performance:

- Shape containment is evaluated in original local coordinates, not resized to
  a clipped frame. Stroke paths include StrokeStyle/dashes and strokeBorder inset;
  regular strokes include the outside half-width in their registered bounds.
- Explicit clip wrappers retain the original visual clipping operation and
  forward its path. Clip regions reference their UIKit anchors weakly. Shape
  closures capture shape values, avoiding a StateObject/closure retain cycle.
- View opacity is explicitly forwarded where SwiftUI might only change its
  render graph. UIKit ancestor alpha is also checked, conservatively taking a
  minimum rather than double-applying a mirrored opacity.
- Window/presentation/scroll clipping and live coordinate conversion happen
  when querying. Picking refreshes geometry immediately; discovery refreshes
  at the existing 0.2-second timer while editing.
- Dismantle unregisters, queued reports cannot resurrect a dismantled anchor,
  layout reports coalesce, and off-main deinit schedules main-thread cleanup.
- Registry storage has one record per mounted anchor and no history. Ownership
  comparisons run only on a tap. The selector uses O(N) temporary storage and
  O(H^2) pair comparisons for H overlapping targets (each comparison reads short
  ancestry/layer paths). Discovery/normal app rendering does not run this core.

Deliberate boundaries and Apple-platform verification:

This is a paint-ownership model, not a rendering engine. Unannotated sibling
zIndex, custom masks, blur halos, presentation-layer animation geometry and glyph
alpha cannot be reconstructed perfectly from SwiftUI anchors. Foreground and
control rectangles do not claim opaque coverage of every pixel inside them.
Gradients/pulses retain semantic-only editing, without per-stop exact editing or
per-pixel alpha reconstruction. UIKit discovery remains semantic-only and uses
its existing control geometry heuristics. System pickers/Safari/Quick Look,
Live Activities, generated installer icons and theme-profile swatches are not
made exact-editable app paint.

Content-surface annotations intentionally reserve artwork bounds for artwork,
without assigning it a theme role. They conservatively block through-image
selection; transparent texels in an arbitrary image are not decoded into a
separate theme hit mask. Theme roles remain available in the role editor, and
registered image-border paths remain directly selectable. This restriction is
explicit rather than treating photo pixels as theme colors.

Run:

    python3 Tests/ThemeEditing/verify_ownership.py
    python3 Tests/ThemeEditing/verify_picker.py
    python3 Tests/ThemeEditing/verify.py

verify_ownership compiles/executes the actual production C core. Its clipping,
scroll, opacity and safe-area cases verify the selector's metadata contract;
they do NOT instantiate SwiftUI or prove UIKit supplies those values correctly.
verify_picker adds source guards for that adapter, safe-area scope propagation,
hosted-context forwarding, shape containment, lifetime, and unchanged persistence
paths. The pixel-fallback test asserts that the editor has no sampler at all;
no sampled color can override an explicit target. verify.py executes the report
DOM bridge JavaScript and verifies its semantic mappings.

Required on iOS: empty Downloads THIS ELEMENT repaint; global edit with local
exceptions; transparent inner canvas; card/text/stroke selection; news image
load/placeholder replacement; clipped image/card corners; UIKit row recycling;
scroll, navigation, sheets, rotation and safe areas; hidden loading content;
animated progress/masks; ColorPicker save/cancel/reset/duplicate/relaunch.
Swift/Xcode compilation is a separate required platform check. Passing Linux
C/Python checks is not evidence that SwiftUI compiled or ran.
