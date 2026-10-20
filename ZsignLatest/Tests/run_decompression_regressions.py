#!/usr/bin/env python3
"""Compile production extraction against actual SWCompression/BitByteData sources.

Use checkouts matching the versions in the app's Package.resolved. No dependency
doubles or network access are used. Requires Swift, Python and those checkouts.
"""

import argparse
import bz2
import gzip
import io
import lzma
import os
from pathlib import Path
import subprocess
import sys
import tarfile
import tempfile


ROOT = Path(__file__).resolve().parents[2]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--swiftc", default="swiftc")
    parser.add_argument("--swcompression-source", type=Path, required=True)
    parser.add_argument("--bitbytedata-source", type=Path, required=True)
    args = parser.parse_args()
    with tempfile.TemporaryDirectory(prefix="ksign-decompression-regressions-") as temporary:
        work = Path(temporary)
        suffix = ".dylib" if sys.platform == "darwin" else ".so"
        for module, source in [("BitByteData", args.bitbytedata_source), ("SWCompression", args.swcompression_source)]:
            sources = sorted(path for path in (source / "Sources").rglob("*.swift")
                             if "swcomp" not in path.relative_to(source / "Sources").parts)
            if not sources:
                raise SystemExit(f"No Swift sources found for {module} at {source}")
            command = [args.swiftc, "-swift-version", "5", "-emit-library", "-emit-module",
                       "-module-name", module, "-module-cache-path", str(work / "cache"),
                       "-emit-module-path", str(work / f"{module}.swiftmodule"),
                       "-I", str(work), "-L", str(work)]
            if module == "SWCompression":
                command.append("-lBitByteData")
            subprocess.run([*command, *map(str, sources), "-o", str(work / f"lib{module}{suffix}")], check=True)

        production = (ROOT / "Ksign/Utilities/ARDecompression/Decompression.swift").read_text()
        # Compression is an unused Apple-only import; the decoder implementation
        # and its actual third-party APIs remain unchanged on Linux.
        if sys.platform != "darwin":
            production = production.replace("import Compression\n", "")
        errors = (ROOT / "Ksign/Utilities/Handlers/TweakHandler.swift").read_text().split("enum TweakHandlerError: Error {", 1)[1]
        helper = work / "Decompression.swift"
        helper.write_text(production + "\nenum TweakHandlerError: Error {" + errors)
        executable = work / "decompression-regressions"
        subprocess.run([args.swiftc, "-swift-version", "5", "-parse-as-library",
                        "-module-cache-path", str(work / "cache"), "-I", str(work), "-L", str(work),
                        "-lSWCompression", "-lBitByteData", str(helper),
                        str(ROOT / "ZsignLatest/Tests/decompression_regressions.swift"),
                        "-o", str(executable)], check=True)

        expected = bytes(range(256)) * 32
        (work / "expected.bin").write_bytes(expected)
        for unsafe in (False, True):
            buffer = io.BytesIO()
            with tarfile.open(fileobj=buffer, mode="w", format=tarfile.USTAR_FORMAT) as archive:
                entry = tarfile.TarInfo("../escaped.txt" if unsafe else "Library/Frameworks/Test.framework/resource.bin")
                entry.size = len(expected)
                archive.addfile(entry, io.BytesIO(expected))
            data = buffer.getvalue()
            if unsafe:
                (work / "unsafe.tar").write_bytes(data)
            else:
                for name, payload in [("data.tar", data), ("data.tar.gz", gzip.compress(data)),
                                      ("data.tar.bz2", bz2.compress(data)),
                                      ("data.tar.lzma", lzma.compress(data, format=lzma.FORMAT_ALONE)),
                                      ("data.tar.xz", lzma.compress(data))]:
                    (work / name).write_bytes(payload)
        variable = "DYLD_LIBRARY_PATH" if sys.platform == "darwin" else "LD_LIBRARY_PATH"
        environment = {**os.environ, variable: str(work) + os.pathsep + os.environ.get(variable, "")}
        subprocess.run([str(executable), str(work)], env=environment, check=True, timeout=30)


if __name__ == "__main__":
    main()
