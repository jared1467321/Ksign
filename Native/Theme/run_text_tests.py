#!/usr/bin/env python3
"""Execute production text/sky Metal math with the existing CPU adapters.

This checks color response and coordinate math, not SwiftUI's compositor.
"""
import argparse
from pathlib import Path
import re
import shutil
import subprocess
import tempfile


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--swiftc", default=shutil.which("swiftc"))
    parser.add_argument("--preview-dir", type=Path)
    args = parser.parse_args()
    if not args.swiftc:
        parser.error("swiftc is required (or pass --swiftc)")
    root = Path(__file__).resolve().parents[2]
    with tempfile.TemporaryDirectory(prefix="ksign-text-tests-") as folder:
        folder = Path(folder)
        identity = folder / "Identity"
        subprocess.run([args.swiftc, "-parse-as-library", "-module-cache-path", str(folder / "modules"),
                        str(root / "NimbleKit/Sources/NimbleExtensions/View/NBAuroraShaderIdentity.swift"),
                        str(root / "Native/Theme/AuroraIdentity.swift"), "-o", str(identity)], check=True)
        identities = folder / "identities.txt"
        with identities.open("w") as output:
            subprocess.run([str(identity)], stdout=output, check=True)

        adapters = (root / "Native/Theme/AuroraRendering.cpp").read_text().split("namespace Reference {")[0]
        shader = (root / "NimbleKit/Sources/NimbleExtensions/Shaders/AuroraShaders.metal").read_text()
        shader = re.sub(r"^#include[^\n]*", "", shader, flags=re.MULTILINE)
        shader = re.sub(r"(?<![\w.])(\d+\.\d*(?:[eE][+-]?\d+)?)(?![\w.])", r"\1f", shader)
        shader = shader.replace("using namespace metal;", "").replace("[[ stitchable ]]", "")
        fixture = (root / "Native/Theme/AuroraText.cpp").read_text()
        source = folder / "AuroraText.cpp"
        source.write_text(fixture.replace("// SHADER_SUPPORT", adapters).replace("// PRODUCTION_SHADER", shader))
        binary = folder / "AuroraText"
        renderer = (root / "NimbleKit/Sources/NimbleExtensions/View/NBAuroraInkMap.swift").read_text()
        width = re.search(r"static let width = (\d+)", renderer).group(1)
        height = re.search(r"static let height = (\d+)", renderer).group(1)
        subprocess.run(["clang++", "-std=c++17", "-O2", "-ffp-contract=off",
                        f"-DINK_MAP_WIDTH={width}", f"-DINK_MAP_HEIGHT={height}",
                        str(source), "-o", str(binary)], check=True)
        command = [str(binary), str(identities)]
        if args.preview_dir:
            args.preview_dir.mkdir(parents=True, exist_ok=True)
            command.append(str(args.preview_dir))
        subprocess.run(command, check=True, timeout=60)


if __name__ == "__main__":
    main()
