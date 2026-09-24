#!/usr/bin/env python3
"""Source regression guards; these do NOT compile Swift or validate UIKit layout.

Keep the portable audit honest about module boundaries, API return types,
semantic paint provenance, and persistence/selection regressions. Runtime
scenarios are listed in README.md and must also run on an iOS device.
"""
from pathlib import Path
import re
import unittest

ROOT = Path(__file__).resolve().parents[2]
PAINT = ROOT / 'NimbleKit/Sources/NimbleExtensions/View/NBThemeInspectorTarget.swift'
MODEL = ROOT / 'NimbleKit/Sources/NimbleExtensions/Color/Color+halloween.swift'
OVERLAY = ROOT / 'Ksign/Views/Settings/Appearance/ThemeEditingOverlay.swift'


def body(source, start, end):
    return source.split(start, 1)[1].split(end, 1)[0]


class PickerSourceTests(unittest.TestCase):
    def test_all_paint_apis_exist_and_imports_are_explicit(self):
        api = set(re.findall(r'func (nbTheme\w+)(?:<[^\n]+>)?\(', PAINT.read_text()))
        for root in (ROOT / 'Ksign', ROOT / 'NimbleKit/Sources/NimbleViews'):
            for path in root.rglob('*.swift'):
                source = path.read_text()
                calls = set(re.findall(r'\.(nbTheme\w+)\(', source))
                self.assertFalse(calls - api, (path, calls - api))
                if calls or 'NBThemePaint(' in source:
                    self.assertIn('import NimbleExtensions', source, path)

    def test_no_text_only_description_uses_view_modifier(self):
        for path in (ROOT / 'Ksign').rglob('*.swift'):
            self.assertNotRegex(path.read_text(),
                                r'description:\s*Text\([^\n]+\)\s*\.nbThemeForeground')

    def test_no_unregistered_legacy_theme_paints_in_views(self):
        for path in (ROOT / 'Ksign/Views').rglob('*.swift'):
            code = re.sub(r'//[^\n]*', '', path.read_text())
            self.assertNotIn('NBHalloween.', code, path)
            self.assertNotIn('.foregroundColor(.disabled())', code, path)
        for relative, role in (
            ('Sources/Apps/News/SourceNewsCardView.swift', 'imageScrim'),
            ('Sources/Apps/Detail/SourceAppsDetailView.swift', 'mask'),
            ('Settings/Installation/Tunnel & Pairing/TunnelHeaderCellView.swift', 'success'),
            ('Settings/Installation/Tunnel & Pairing/TunnelHeaderCellView.swift', 'warning'),
        ):
            source = (ROOT / 'Ksign/Views' / relative).read_text()
            self.assertIn(f'.nbThemeInspectorTarget(.{role})', source)
            self.assertIn('@ObservedObject', source)

    def test_legacy_decode_and_override_lifecycle(self):
        source = MODEL.read_text()
        self.assertIn('decodeIfPresent([String: NBThemeColor].self, forKey: .elementOverrides) ?? [:]', source)
        self.assertIn('try container.encode(elementOverrides, forKey: .elementOverrides)', source)
        self.assertIn('elementOverrides: base.elementOverrides', source)
        local_save = body(source, 'private func setElementOverride(', 'public func resetActiveThemeColors')
        self.assertNotIn('color ==', local_save, 'Equal RGB still needs a pinned local override')
        self.assertIn('theme.setElementOverride(stored, for: elementID)', local_save)
        reset = body(source, 'public func resetThemeColors(id:', 'public func deleteActiveTheme')
        self.assertIn('save: false', reset)
        self.assertIn('theme.elementOverrides.removeAll()', reset)
        global_save = body(source, 'public func setColor(_ color: NBThemeColor, for role: NBThemeRole, in themeID:', 'public func hasElementOverride')
        self.assertNotIn('elementOverrides', global_save)
        resolve = body(source, 'public func activeColor(for role: NBThemeRole, elementID:', 'public func beginColorPreview')
        self.assertLess(resolve.index('activeTheme.elementOverride'), resolve.index('return activeColor(for: role)'))

    def test_selection_respects_actual_bounds_and_semantic_targets(self):
        source = body(OVERLAY.read_text(), 'private func pickTarget(at point:', 'private func colorBinding')
        self.assertIn('NBThemeInspectorRegistry.pickTargets(targets, at: point)', source)
        self.assertNotIn('expandedHitRect', source)
        self.assertNotIn('exactHits', source, 'A semantic-only foreground must outrank an exact canvas')
        self.assertIn('seenElements', source, 'Same-role local paints must not be collapsed')
        self.assertNotIn('ThemePixelRoleSampler', OVERLAY.read_text(), 'RGB is not semantic provenance')

    def test_ids_are_deterministic_and_file_ids_are_unique(self):
        source = PAINT.read_text()
        self.assertIn('fileID: StaticString = #fileID', source)
        self.assertIn('line: UInt = #line', source)
        self.assertIn('column: UInt = #column', source)
        self.assertIn('explicitElementID ??', source)
        identity = body(source, 'private func nbThemeSourceID(', 'private func nbThemeSemanticColor')
        self.assertNotIn('UUID', identity)
        self.assertNotIn('hashValue', identity)
        for directory in ('Ksign', 'NimbleKit/Sources/NimbleExtensions', 'NimbleKit/Sources/NimbleViews'):
            names = [p.name for p in (ROOT / directory).rglob('*.swift')]
            self.assertEqual(len(names), len(set(names)), directory)

    def test_canvas_and_rows_paint_real_surfaces(self):
        source = PAINT.read_text()
        canvas = body(source, 'private struct NBThemeCanvasModifier', 'private struct NBThemeFilledShape')
        self.assertIn('.scrollContentBackground(.hidden)', canvas)
        self.assertIn('.ignoresSafeArea()', canvas)
        self.assertLess(canvas.index('.background {'), canvas.index('NBThemeInspectorTargetModifier('))
        self.assertLess(canvas.index('NBThemeInspectorTargetModifier('), canvas.index('.ignoresSafeArea()'))
        background = body(source, 'private struct NBThemeBackgroundModifier', 'private struct NBThemeShapedBackgroundModifier')
        self.assertLess(background.index('.background {'), background.index('NBThemeInspectorTargetModifier('))
        self.assertLess(background.index('NBThemeInspectorTargetModifier('), background.index('.ignoresSafeArea('))
        row = body(source, 'private struct NBThemeRowModifier', 'private struct NBThemeCanvasModifier')
        self.assertIn('.listRowBackground(NBThemePaint(.elevated, elementID: elementID))', row)
        for path in (ROOT / 'Ksign/Views').rglob('*.swift'):
            if re.search(r'\b(?:List|Form)\s*[{(]', re.sub(r'//[^\n]*', '', path.read_text())):
                self.assertIn('.nbThemeCanvas()', path.read_text(), path)
                self.assertIn('.nbThemeRow()', path.read_text(), path)

    def test_registry_filters_visibility_and_dismantles(self):
        source = PAINT.read_text()
        self.assertIn('view.isDescendant(of: presentationRoot)', source)
        self.assertIn('effectiveAlpha *= node.alpha', source)
        self.assertIn('node.clipsToBounds', source)
        self.assertIn('uiView.isDismantled = true', source)
        self.assertIn('uiView.unregister()', source)

    def test_ownership_adapter_and_safe_area_ancestry(self):
        source = PAINT.read_text()
        for name, end in [('NBThemeCanvasModifier', 'NBThemeFilledShape'),
                          ('NBThemeBackgroundModifier', 'NBThemeShapedBackgroundModifier')]:
            block = body(source, 'private struct ' + name, 'private struct ' + end)
            self.assertIn('.environment(\\.nbPaintAncestry, ancestors + [ownerID])', block)
            self.assertIn('scopeID: ownerID', block)
        self.assertIn('input.ancestors_count = parents.count', source)
        self.assertIn('input.layers_count = paintLayers.count', source)
        self.assertIn('nb_theme_pick(ts.baseAddress', source)
        self.assertIn('indices.prefix(count).map { sorted[$0] }', source)
        self.assertIn('target.frame.contains(point) && (target.pathContains?(point) ?? true)', source)

    def test_clips_shapes_opacity_and_current_geometry_are_bridged(self):
        source = PAINT.read_text()
        self.assertIn('view.convert(point, from: window)', source)
        self.assertIn('clips.allSatisfy', source)
        self.assertIn('shape.inset(by: lineWidth / 2).path', source)
        self.assertIn('.strokedPath(style)', source)
        self.assertIn('outset: style.lineWidth / 2', source)
        self.assertIn('alpha: alpha * inheritedOpacity', source)
        self.assertIn('metadata.alpha = min(metadata.alpha, visibility.alpha)', source)
        self.assertIn('Self.visibility(of: view, in: window', source)
        self.assertIn('path: { [shape] in shape.path(in: $0) }', source,
                      'Clip-region path must not capture its owning StateObject through self')

    def test_pixel_fallback_cannot_override_registered_paint(self):
        source = OVERLAY.read_text()
        self.assertNotIn('ThemePixelRoleSampler', source)
        self.assertNotIn('UIGraphicsImageRenderer', source)
        self.assertIn('NBThemeInspectorRegistry.pickTargets(targets, at: point)', source)

    def test_hosted_cells_preserve_live_inspector_context(self):
        source = (ROOT / 'Ksign/Views/Sources/Apps/UIKit/SourceAppsTableRepresentableView.swift').read_text()
        self.assertIn('@Environment(\\.nbThemeInspectorContext)', source)
        self.assertIn('@Published var inspectorContext', source)
        self.assertIn('content.environment(\\.nbThemeInspectorContext, coordinator.inspectorContext)', source)
        self.assertEqual(source.count('SourceAppsThemeHost(coordinator:'), 3)

    def test_normalization_does_not_merge_distinct_exact_owners(self):
        source = body(OVERLAY.read_text(), 'private func normalizedTargets(', 'private func discoveryMarkers')
        self.assertNotIn('sameFrame', source)
        self.assertNotIn('removeAll', source)

    def test_core_enum_and_package_dependency_match(self):
        source = PAINT.read_text()
        self.assertIn('case canvas, background, fill, overlay, control, foreground, stroke, shadow, chrome', source)
        header = (ROOT / 'NimbleKit/Sources/NBThemePicking/include/NBThemePicking.h').read_text()
        self.assertIn('NBCanvas, NBBackground, NBFill, NBOverlay, NBControl, NBForeground, NBStroke, NBShadow, NBChrome', header)
        manifest = (ROOT / 'NimbleKit/Package.swift').read_text()
        self.assertIn('dependencies: ["NBThemePicking"]', manifest)


if __name__ == '__main__':
    unittest.main(verbosity=2)
