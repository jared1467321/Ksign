#!/usr/bin/env python3
"""Execute the production C selector. UIKit/SwiftUI geometry is input to this
core, not emulated by these tests; adapter source guards live in verify_picker.
Build output is isolated in a temporary directory and automatically removed.
"""
import ctypes as C
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
CORE = ROOT / 'NimbleKit/Sources/NBThemePicking'
CANVAS, BACKGROUND, FILL, OVERLAY, CONTROL, FOREGROUND, STROKE, SHADOW, CHROME = range(9)


class Layer(C.Structure):
    _fields_ = [('group', C.c_uint64), ('id', C.c_uint64), ('order', C.c_double)]


class Target(C.Structure):
    _fields_ = [(n, C.c_double) for n in ('x', 'y', 'width', 'height', 'alpha')] + [
        ('owner', C.c_uint64), ('ancestors_offset', C.c_size_t), ('ancestors_count', C.c_size_t),
        ('layers_offset', C.c_size_t), ('layers_count', C.c_size_t),
        ('kind', C.c_int), ('path_hit', C.c_int), ('covers', C.c_int)]


def target(owner, *, parents=(), kind=CANVAS, frame=(0, 0, 300, 600), alpha=1,
           layers=(), hit=True, covers=True):
    return dict(owner=owner, parents=parents, kind=kind, frame=frame, alpha=alpha,
                layers=layers, hit=hit, covers=covers)


class OwnershipTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.tmp = tempfile.TemporaryDirectory(prefix='ksign-ownership-')
        lib = Path(cls.tmp.name) / 'picker.so'
        subprocess.run(['clang', '-std=c11', '-Wall', '-Wextra', '-Werror', '-pedantic',
                        '-shared', '-fPIC', '-I', str(CORE / 'include'),
                        str(CORE / 'NBThemePicking.c'), '-lm', '-o', str(lib)], check=True)
        cls.library = C.CDLL(str(lib))
        cls.pick = cls.library.nb_theme_pick
        cls.pick.argtypes = [C.POINTER(Target), C.c_size_t, C.POINTER(C.c_uint64), C.c_size_t,
                            C.POINTER(Layer), C.c_size_t, C.c_double, C.c_double, C.POINTER(C.c_size_t)]
        cls.pick.restype = C.c_size_t

    @classmethod
    def tearDownClass(cls):
        cls.tmp.cleanup()

    def resolve(self, targets, point=(25, 25)):
        paths, layers, ts = [], [], []
        for t in targets:
            ts.append(Target(*t['frame'], t['alpha'], t['owner'], len(paths), len(t['parents']),
                             len(layers), len(t['layers']), t['kind'], t['hit'], t['covers']))
            paths.extend(t['parents'])
            layers.extend(Layer(*v) for v in t['layers'])
        output = (C.c_size_t * len(ts))()
        n = self.pick((Target * len(ts))(*ts), len(ts), (C.c_uint64 * len(paths))(*paths),
                      len(paths), (Layer * len(layers))(*layers), len(layers), *point, output)
        return [targets[output[i]]['owner'] for i in range(n)]

    def test_nested_equal_canvases_old_bug(self):
        ts = [target(1), target(2, parents=(1,)), target(3, parents=(1, 2))]
        # Old area sorting retained all three, and ties depended on source ID.
        old_hits = sorted(ts, key=lambda t: t['frame'][2] * t['frame'][3])
        smallest = old_hits[0]['frame'][2] * old_hits[0]['frame'][3]
        old_eligible = [t['owner'] for t in old_hits
                        if t['frame'][2] * t['frame'][3] <= max(smallest * 4, smallest + 1600)]
        self.assertEqual(old_eligible, [1, 2, 3])
        self.assertEqual(self.resolve(ts), [3])
        self.assertEqual(self.resolve(list(reversed(ts))), [3])

    def test_smaller_card_over_canvas(self):
        self.assertEqual(self.resolve([target(1), target(2, parents=(1,), kind=BACKGROUND,
                                                        frame=(0, 0, 60, 60))]), [2])

    def test_foreground_over_background(self):
        ts = [target(1), target(2, parents=(1,), kind=FOREGROUND, covers=False, frame=(0, 0, 30, 30))]
        self.assertEqual(self.resolve(ts)[0], 2)

    def test_partial_overlap_declared_siblings(self):
        ts = [target(1, layers=((10, 11, 0),), frame=(0, 0, 100, 100)),
              target(2, layers=((10, 12, 1),), frame=(50, 0, 100, 100))]
        self.assertEqual(self.resolve(ts, (75, 25)), [2])
        self.assertEqual(self.resolve(ts, (25, 25)), [1])

    def test_equal_frame_declared_siblings(self):
        ts = [target(1, layers=((10, 11, 0),)), target(2, layers=((10, 12, 1),))]
        self.assertEqual(self.resolve(ts), [2])
        self.assertEqual(self.resolve(list(reversed(ts))), [2])

    def test_unknown_sibling_order_does_not_invent_occlusion(self):
        self.assertEqual(set(self.resolve([target(1), target(2)])), {1, 2})

    def test_clipping_rejects_outside_visible_frame_and_shape(self):
        self.assertEqual(self.resolve([target(1, frame=(0, 0, 10, 10))]), [])
        self.assertEqual(self.resolve([target(1, hit=False)]), [])

    def test_hidden_alpha_removed_and_zero_size(self):
        self.assertEqual(self.resolve([target(1, alpha=0), target(2, alpha=.01),
                                       target(3, frame=(0, 0, 0, 0))]), [])
        self.assertEqual(self.resolve([]), [])

    def test_scroll_uses_current_snapshot_only(self):
        self.assertEqual(self.resolve([target(1)]), [1])
        self.assertEqual(self.resolve([target(1, frame=(0, -600, 300, 600))]), [])
        self.assertEqual(self.resolve([target(1, frame=(0, -600, 300, 600))], (25, -25)), [1])

    def test_safe_area_region_is_not_content_region(self):
        self.assertEqual(self.resolve([target(1, frame=(0, 0, 300, 600))], (20, 10)), [1])
        self.assertEqual(self.resolve([target(1, frame=(0, 44, 300, 556))], (20, 10)), [])

    def test_exact_selection_returns_visible_paint_owner(self):
        # Caller must map index back to this exact record/elementID, never role.
        self.assertEqual(self.resolve([target(101), target(202, parents=(101,))]), [202])

    def test_translucent_surface_retains_contributing_background(self):
        self.assertEqual(self.resolve([target(1), target(2, parents=(1,), alpha=.4)]), [2, 1])

    def test_opaque_overlay_covers_foreground_descendants(self):
        self.assertEqual(self.resolve([target(1, kind=OVERLAY),
                                       target(2, parents=(1,), kind=FOREGROUND, covers=False)]), [1])

    def test_stroke_hollow_interior_does_not_steal_fill(self):
        ts = [target(1, kind=FILL), target(2, kind=STROKE, hit=False)]
        self.assertEqual(self.resolve(ts), [1])

    def test_outer_explicit_layer_survives_nested_compositing_group(self):
        ts = [target(1, layers=((10, 11, 0), (20, 21, 100))),
              target(2, layers=((10, 12, 1),))]
        self.assertEqual(self.resolve(ts), [2])

    def test_inherited_root_tint_cannot_beat_inner_canvas(self):
        ts = [target(1, kind=CONTROL, covers=False), target(2, parents=(1,))]
        self.assertEqual(self.resolve(ts), [2])

    def test_giant_inherited_control_loses_to_small_fill(self):
        ts = [target(1, kind=CONTROL, covers=False), target(2, kind=FILL, frame=(0, 0, 40, 40))]
        self.assertEqual(self.resolve(ts)[0], 2)

    def test_native_bar_covers_safe_area_canvas_but_not_its_label(self):
        ts = [target(1), target(2, kind=CHROME, frame=(0, 0, 300, 44)),
              target(3, kind=FOREGROUND, covers=False, frame=(10, 10, 30, 20))]
        self.assertEqual(self.resolve(ts), [3, 2])
        self.assertEqual(self.resolve(ts, (200, 20)), [2])
        self.assertEqual(self.resolve(ts, (200, 100)), [1])

    def test_invalid_geometry_fails_closed(self):
        self.assertEqual(self.resolve([target(1, frame=(float('nan'), 0, 300, 600))]), [])

    def test_subpoint_separator_is_real_paint(self):
        self.assertEqual(self.resolve([target(1, kind=OVERLAY, frame=(0, 0, 100, .333))], (25, .1)), [1])

    def test_layer_above_small_foreground_wins_before_specificity(self):
        ts = [target(1, kind=FOREGROUND, covers=False, frame=(0, 0, 30, 30), layers=((10, 11, 0),)),
              target(2, kind=BACKGROUND, layers=((10, 12, 1),))]
        self.assertEqual(self.resolve(ts), [2])

    def test_nested_canvas_without_matching_role_or_rgb(self):
        # Neither semantic role nor RGB is an input to the selector at all.
        ts = [target(400), target(2, parents=(400,))]
        self.assertEqual(self.resolve(ts), [2])

    def test_child_under_transparent_parent_overlay(self):
        ts = [target(1, kind=OVERLAY, alpha=.2), target(2, parents=(1,), kind=FOREGROUND, covers=False)]
        self.assertEqual(self.resolve(ts), [1, 2])


if __name__ == '__main__':
    unittest.main(verbosity=2)
