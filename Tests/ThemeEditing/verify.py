#!/usr/bin/env python3
"""Portable source/mapping checks and actual bridge JS execution in JavaScriptCore.

This does not compile Swift or emulate UIKit/WKWebView presentation behavior.
"""
import ctypes
import ctypes.util
import json
from pathlib import Path
import re
import unittest

ROOT = Path(__file__).resolve().parents[2]
BRIDGE = (ROOT / 'Ksign/Utilities/ThemeReportBridge.swift').read_text()
REPORTS = [ROOT / 'Ksign/Views/Downloader/Utils/CryptCheck.swift',
           ROOT / 'Ksign/Views/Library/CryptCheckExtracted.swift']
MAPPING = dict(re.findall(r'cssName: "([^"]+)", role: \.(\w+)', BRIDGE))


class ThemeReportTests(unittest.TestCase):
    def test_complete_mapping_for_both_generators(self):
        roles = (ROOT / 'NimbleKit/Sources/NimbleExtensions/Color/Color+halloween.swift').read_text()
        report_roles = set(re.findall(r'case (report[A-Z]\w*)\b', roles))
        self.assertEqual(set(MAPPING.values()), report_roles)
        for path in REPORTS:
            source = path.read_text()
            definitions = dict(re.findall(r'(--[a-z-]+):\\\(theme.color\(for: \.(\w+)\).cssRGBA\);', source))
            self.assertEqual(MAPPING, definitions, path.name)
            self.assertEqual(set(re.findall(r'var\((--[a-z-]+)\)', source)), set(MAPPING))

    def test_export_replacement_preserves_content_and_all_variables(self):
        # Exercise the bridge's substitution pattern against BOTH production
        # HTML templates, including names sharing suffixes (bg / green-fill).
        for path in REPORTS:
            source = path.read_text()
            start = source.index(':root {')
            end = source.index('</style>', start)
            html = source[start:end]
            original = html
            for index, name in enumerate(MAPPING):
                pattern = '(' + re.escape(name) + r'\s*:)\s*[^;]+;'
                html, count = re.subn(pattern, lambda m: m[1] + f'rgba({index},2,3,0.5);', html)
                self.assertEqual(count, 1, (path.name, name))
            for index, name in enumerate(MAPPING):
                self.assertIn(f'{name}:rgba({index},2,3,0.5);', html)
            self.assertEqual(html[html.index('}'):],
                             original[original.index('}'):])
        persistence = BRIDGE[BRIDGE.index('func persistCurrentTheme'):]
        self.assertIn('activeTheme', persistence)
        self.assertNotIn('activeColor', persistence)
        self.assertIn('throws', persistence)
        self.assertNotIn('try?', persistence.split('final class ThemeReportNavigationCoordinator')[0])

    def test_actual_dom_inspection_script(self):
        library = ctypes.util.find_library('javascriptcoregtk-4.1')
        if not library:
            self.skipTest('JavaScriptCore unavailable; DOM bridge script not executed')
        js = ctypes.CDLL(library)
        ptr = ctypes.c_void_p
        js.JSGlobalContextCreate.argtypes = [ptr]
        js.JSGlobalContextCreate.restype = ptr
        js.JSStringCreateWithUTF8CString.argtypes = [ctypes.c_char_p]
        js.JSStringCreateWithUTF8CString.restype = ptr
        js.JSEvaluateScript.argtypes = [ptr, ptr, ptr, ptr, ctypes.c_int, ctypes.POINTER(ptr)]
        js.JSEvaluateScript.restype = ptr
        js.JSValueToBoolean.argtypes = [ptr, ptr]
        js.JSValueToBoolean.restype = ctypes.c_bool
        js.JSValueToStringCopy.argtypes = [ptr, ptr, ptr]
        js.JSValueToStringCopy.restype = ptr
        js.JSStringGetUTF8CString.argtypes = [ptr, ctypes.c_char_p, ctypes.c_size_t]
        js.JSStringRelease.argtypes = [ptr]
        js.JSGlobalContextRelease.argtypes = [ptr]
        script = BRIDGE.split('let script = """', 1)[1].split('"""', 1)[0]
        script = script.replace(r'\(mapJSON)', json.dumps(MAPPING))
        script = script.replace(r'\(Double(local.x))', '40').replace(r'\(Double(local.y))', '60')
        harness = '''
        function style(properties) {
          const keys = Object.keys(properties);
          keys.getPropertyValue = name => properties[name];
          return keys;
        }
        function element(selector, parent, properties) {
          return {matches: value => value === selector,
                  parentElement: parent, style: style(properties || {})};
        }
        let rules = [];
        let target = null;
        let expectedX = 40, expectedY = 60;
        const window = {visualViewport: {scale: 1, offsetLeft: 0, offsetTop: 0}};
        const document = {
          styleSheets: [{get cssRules() {return rules;}}],
          elementFromPoint: (x, y) => {
            if (x !== expectedX || y !== expectedY) throw Error('wrong viewport point');
            return target;
          }
        };
        function inspect() { return SCRIPT }
        function rule(selector, properties) {
          return {selectorText: selector, style: style(properties)};
        }
        function has(values) {
          const result = inspect();
          if (!values.every(value => result.includes(value))) throw Error('missing role: ' + values + ' in ' + result);
          if (new Set(result).size !== result.length) throw Error('duplicates');
        }
        '''.replace('SCRIPT', script.strip())
        # Every semantic variable is independently discoverable, regardless of
        # equal RGB values, from both stylesheets and inline declarations.
        for css_name, role in MAPPING.items():
            harness += f'''
            rules = [rule('.target', {{color: 'var({css_name})'}})];
            target = element('.target', null);
            has(['{role}']);
            rules = [];
            target = element('.target', null, {{color: 'var({css_name})'}});
            has(['{role}']);
            '''
        harness += '''
        rules = [rule('body', {color:'var(--text)', background:'var(--bg)'}),
                 rule('.card', {background:'var(--card)', border:'1px solid var(--border)'})];
        target = element('span', element('.card', element('body', null)));
        has(['reportText', 'reportCard', 'reportBorder', 'reportBackground']);
        rules = [{cssRules:[rule('span', {color:'var(--pink)'})]}];
        has(['reportPink']);
        window.visualViewport = {scale: 2, offsetLeft: 5, offsetTop: 9};
        expectedX = 25; expectedY = 39;
        has(['reportPink']);
        target = null;
        if (inspect().length) throw Error('empty tap');
        true;
        '''
        context = js.JSGlobalContextCreate(None)
        source = js.JSStringCreateWithUTF8CString(harness.encode())
        exception = ptr()
        try:
            value = js.JSEvaluateScript(context, source, None, None, 1, ctypes.byref(exception))
            if exception.value:
                error = js.JSValueToStringCopy(context, exception, None)
                buffer = ctypes.create_string_buffer(4096)
                js.JSStringGetUTF8CString(error, buffer, len(buffer))
                js.JSStringRelease(error)
                self.fail(buffer.value.decode())
            self.assertTrue(js.JSValueToBoolean(context, value))
        finally:
            js.JSStringRelease(source)
            js.JSGlobalContextRelease(context)


if __name__ == '__main__':
    unittest.main(verbosity=2)
