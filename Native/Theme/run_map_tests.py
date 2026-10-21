#!/usr/bin/env python3
"""Run the production map scheduler with platform/GPU boundary doubles."""
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
    production = (root / "NimbleKit/Sources/NimbleExtensions/View/NBAuroraInkMap.swift").read_text()
    production = production.split("/// All Metal state")[0]
    for module in ("SwiftUI", "UIKit", "Metal"):
        production = production.replace(f"import {module}\n", "")
    production = production.replace("@objc ", "")
    production = production.replace("#selector(NBAuroraInkClock.fire(_:))", '"fire"')
    fixture = (root / "Native/Theme/InkMapLifetime.swift").read_text()
    row = (root / "NimbleKit/Sources/NimbleExtensions/View/NBAuroraTextRowTracking.swift").read_text()
    row = row.replace("import SwiftUI\n", "")
    reference = (root / "NimbleKit/Sources/NimbleExtensions/View/NBAuroraReference.swift").read_text()
    session = "@MainActor\nfinal class AuroraSession" + reference.split(
        "@MainActor\nfinal class AuroraSession", 1
    )[1].split("@MainActor\npublic enum NBAurora", 1)[0]
    with tempfile.TemporaryDirectory(prefix="ksign-ink-map-tests-") as folder:
        folder = Path(folder)
        source = folder / "InkMapTests.swift"
        source.write_text(fixture.replace("// PRODUCTION_MAP", production)
                          .replace("// PRODUCTION_ROW", row).replace("// PRODUCTION_SESSION", session))
        binary = folder / "InkMapTests"
        subprocess.run([args.swiftc, "-swift-version", "6", "-parse-as-library",
                        "-module-cache-path", str(folder / "modules"), str(source),
                        str(root / "NimbleKit/Sources/NimbleExtensions/View/NBAuroraShaderIdentity.swift"),
                        str(root / "NimbleKit/Sources/NimbleExtensions/View/NBAuroraTextVisibility.swift"),
                        "-o", str(binary)], check=True)
        subprocess.run([str(binary)], check=True, timeout=30)


if __name__ == "__main__":
    main()
