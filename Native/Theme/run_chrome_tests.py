#!/usr/bin/env python3
"""Manual lifecycle tests; UIKit drawing doubles do not verify compositing."""
import argparse
from pathlib import Path
import shutil
import subprocess
import tempfile


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--swiftc", default=shutil.which("swiftc"))
    args = parser.parse_args()
    if not args.swiftc:
        parser.error("swiftc is required (or pass --swiftc)")
    root = Path(__file__).resolve().parents[2]
    production = (root / "NimbleKit/Sources/NimbleExtensions/View/NBAuroraChromeObserver.swift").read_text()
    production = production.replace("import SwiftUI\n", "").replace("import UIKit\n", "")
    production = production.replace("@objc ", "")
    production = production.replace("#selector(NBAuroraChromeDisplayTarget.fire(_:))", '"fire"')
    fixture = (root / "Native/Theme/ChromeLifetime.swift").read_text()
    with tempfile.TemporaryDirectory(prefix="ksign-chrome-tests-") as folder:
        folder = Path(folder)
        source = folder / "ChromeTests.swift"
        source.write_text(fixture.replace("// PRODUCTION_CHROME", production))
        binary = folder / "ChromeTests"
        subprocess.run([args.swiftc, "-swift-version", "6", "-parse-as-library",
                        "-module-cache-path", str(folder / "modules"), str(source), "-o", str(binary)], check=True)
        subprocess.run([str(binary)], check=True, timeout=30)


if __name__ == "__main__":
    main()
