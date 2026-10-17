#!/usr/bin/env python3
"""Run the production theme model with platform-only SwiftUI/Combine doubles."""
from pathlib import Path
import shutil
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[2]


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


if __name__ == "__main__":
    main()
