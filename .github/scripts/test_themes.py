#!/usr/bin/env python3
"""Run the production theme model with platform-only SwiftUI/Combine doubles."""
from pathlib import Path
import shutil
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[2]


def test_aurora_colors(directory):
    compiler = shutil.which("clang++") or shutil.which("c++")
    if not compiler:
        raise SystemExit("a C++ compiler is required for the aurora color tests")
    shader = (ROOT / "NimbleKit/Sources/NimbleExtensions/Shaders/AuroraShaders.metal").read_text()
    start = shader.index("static float3 auroraLightAppearance(")
    end = shader.index("\n}\n", start) + 2
    test = (ROOT / "Native/Theme/AuroraColors.cpp").read_text()
    source = directory / "AuroraColors.cpp"
    source.write_text(test.replace("// PRODUCTION_LIGHT_APPEARANCE", shader[start:end]))
    executable = directory / "AuroraColors"
    subprocess.run([compiler, "-std=c++17", str(source), "-o", str(executable)], check=True)
    subprocess.run([str(executable)], check=True, timeout=30)


def test_navigation_layers(directory, compiler):
    bridge = (ROOT / "NimbleKit/Sources/NimbleExtensions/View/NBThemeNavigationBridge.swift").read_text()
    start = bridge.index("    private func updateBar(")
    opening = bridge.index("{", start)
    end, depth = opening + 1, 1
    while depth:
        depth += (bridge[end] == "{") - (bridge[end] == "}")
        end += 1
    tests = (ROOT / "Native/Theme/NavigationLayers.swift").read_text()
    source = directory / "NavigationLayers.swift"
    source.write_text(tests.replace("// PRODUCTION_UPDATE_BAR", bridge[start:end]))
    executable = directory / "NavigationLayers"
    subprocess.run([compiler, "-swift-version", "6", "-parse-as-library", "-module-cache-path",
                    str(directory / "modules"), str(source), "-o", str(executable)], check=True)
    subprocess.run([str(executable)], check=True, timeout=30)


def main():
    compiler = shutil.which("swiftc")
    if not compiler:
        raise SystemExit("swiftc is required")
    sources = [(ROOT / "Native/Theme/Tests.swift").read_text()]
    for name in ("Color+halloween.swift", "NBGlassPalette.swift"):
        source = (ROOT / "NimbleKit/Sources/NimbleExtensions/Color" / name).read_text()
        source = source.replace("import SwiftUI\n", "").replace("import Combine\n", "")
        # The unused UIKit color conversion is the only platform-specific code.
        while "#if canImport(UIKit)" in source:
            start = source.index("#if canImport(UIKit)")
            end = source.index("#endif", start) + len("#endif")
            source = source[:start] + source[end:]
        sources.append(source)
    with tempfile.TemporaryDirectory(prefix="asign-theme-tests-") as folder:
        directory = Path(folder)
        source = directory / "Themes.swift"
        source.write_text("\n".join(sources))
        executable = directory / "ThemeTests"
        subprocess.run([compiler, "-swift-version", "6", "-parse-as-library", "-module-cache-path",
                        str(directory / "modules"), str(source), "-o", str(executable)], check=True)
        subprocess.run([str(executable)], check=True, timeout=30)
        test_aurora_colors(directory)
        test_navigation_layers(directory, compiler)


if __name__ == "__main__":
    main()
