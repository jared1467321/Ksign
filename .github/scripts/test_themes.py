#!/usr/bin/env python3
"""Run the production theme model with platform-only SwiftUI/Combine doubles."""
from pathlib import Path
import shutil
import subprocess
import tempfile
import re

ROOT = Path(__file__).resolve().parents[2]


def test_aurora_work(directory, compiler):
    source = ROOT / "NimbleKit/Sources/NimbleExtensions/View/NBAuroraStarfield.swift"
    tests = ROOT / "Native/Theme/AuroraWork.swift"
    executable = directory / "AuroraWork"
    subprocess.run([compiler, "-swift-version", "6", "-parse-as-library", "-module-cache-path",
                    str(directory / "modules"), str(source),
                    str(source.with_name("NBGlassPaneSelection.swift")),
                    str(tests), "-o", str(executable)], check=True)
    subprocess.run([str(executable)], check=True, timeout=30)


def test_aurora_lifetime(directory, compiler):
    source = (ROOT / "NimbleKit/Sources/NimbleExtensions/View/NBAuroraReference.swift").read_text()
    start = source.index("@MainActor\nprivate final class AuroraPerformanceController")
    end = source.index("private struct Starfield: View", start)
    controller = source[start:end]
    # Linux lacks Objective-C selectors and UIKit's thermal/power properties.
    controller = controller.replace("@objc ", "")
    controller = controller.replace("#selector(AuroraDisplayLinkTarget.fire(_:))", '"fire"')
    controller = controller.replace("ProcessInfo.processInfo", "AuroraTestProcessInfo.processInfo")
    tests = (ROOT / "Native/Theme/AuroraLifetime.swift").read_text()
    path = directory / "AuroraLifetime.swift"
    path.write_text(tests.replace("// PRODUCTION_CONTROLLER", controller))
    executable = directory / "AuroraLifetime"
    subprocess.run([compiler, "-swift-version", "6", "-parse-as-library", "-module-cache-path",
                    str(directory / "modules"), str(path), "-o", str(executable)], check=True)
    subprocess.run([str(executable)], check=True, timeout=30)


def test_aurora_rendering(directory, compiler):
    view = ROOT / "NimbleKit/Sources/NimbleExtensions/View"
    identity = directory / "AuroraIdentity"
    subprocess.run([compiler, "-swift-version", "6", "-parse-as-library", "-module-cache-path",
                    str(directory / "modules"), str(view / "NBAuroraShaderIdentity.swift"),
                    str(ROOT / "Native/Theme/AuroraIdentity.swift"), "-o", str(identity)], check=True)
    arguments = directory / "identity-arguments.txt"
    with arguments.open("w") as output:
        subprocess.run([str(identity)], stdout=output, check=True, timeout=30)

    def shader_source(path):
        source = path.read_text()
        source = re.sub(r"^#include[^\n]*", "", source, flags=re.MULTILINE)
        # Metal's unsuffixed floating literals are Float, unlike C++'s Double.
        source = re.sub(r"(?<![\w.])(\d+\.\d*(?:[eE][+-]?\d+)?)(?![\w.])", r"\1f", source)
        return source.replace("using namespace metal;", "").replace("[[ stitchable ]]", "")

    reference = shader_source(ROOT / "Native/Theme/AuroraShaderReference.metal")
    production = shader_source(ROOT / "NimbleKit/Sources/NimbleExtensions/Shaders/AuroraShaders.metal")
    source = (ROOT / "Native/Theme/AuroraRendering.cpp").read_text()
    source = source.replace("// REFERENCE_SHADER", reference).replace("// PRODUCTION_SHADER", production)
    path = directory / "AuroraRendering.cpp"
    path.write_text(source)
    executable = directory / "AuroraRendering"
    subprocess.run(["clang++", "-std=c++17", "-O2", "-ffp-contract=off", str(path), "-o", str(executable)], check=True)
    subprocess.run([str(executable), str(arguments)], check=True, timeout=60)


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
        test_aurora_work(directory, compiler)
        test_aurora_lifetime(directory, compiler)
        test_aurora_rendering(directory, compiler)


if __name__ == "__main__":
    main()
