#!/usr/bin/env python3
"""
Patch IDeviceKit's install path on the CI runner.

IDeviceKit is a git submodule that Xcode consumes as a *local* Swift package
(`XCLocalSwiftPackageReference`, relativePath = IDeviceKit). That means the
build uses whatever is in that directory on the runner — but files inside a
submodule path can't be committed from this repo, so the edits have to happen
after checkout and before `make`.

Every replacement below is asserted. If the submodule pointer ever moves and
one of these no longer matches, this script exits non-zero and the build fails
here — loudly — rather than quietly producing an IPA that silently lacks the
changes. If that happens, re-derive the patches against the new source; don't
just delete the failing one.

Changes, in order of expected impact:

  1. QoS. The whole install ran at `.utility`, below default. The AFC upload of
     the entire .ipa happens inside it. We already have on-device evidence from
     the zip step that being below default is a real, measurable tax here.

  2. Memory-map the archive instead of reading it into RAM. `Data(contentsOf:)`
     pulled the whole file resident before a single byte moved — a full serial
     read up front, and ~400MB per app held for the duration. At three
     concurrent installs that is over a gigabyte, and the resulting memory
     pressure slows the entire device, not just this.

  3. Stop hoisting the buffer pointer out of `withUnsafeBytes`. Using it after
     the closure returns is undefined behaviour. It survived on luck while the
     Data owned a plain heap allocation; with a memory mapping that luck is a
     worse bet, so (2) and (3) genuinely have to ship together.
"""

import sys
from pathlib import Path

TARGET = Path("IDeviceKit/Sources/IDeviceSwift/InstallationProxy/InstallationProxy.swift")

# (description, old, new) — tabs matter, the file is tab-indented.
PATCHES = [
    (
        "install() QoS: .utility -> .userInitiated",
        "\t\ttry await Task.detached(priority: .utility) {\n",
        "\t\ttry await Task.detached(priority: .userInitiated) {\n",
    ),
    (
        "memory-map the archive instead of reading it resident",
        "\t\t\tlet data = try Data(contentsOf: url)\n",
        "\t\t\tlet data = try Data(contentsOf: url, options: .mappedIfSafe)\n",
    ),
    (
        "keep the AFC write pointer inside withUnsafeBytes",
        (
            "\t\t\tguard let rawBuffer = data.withUnsafeBytes({ $0.baseAddress })?.assumingMemoryBound(to: UInt8.self) else {\n"
            "\t\t\t\tthrow IDeviceSwiftError(message: \"Error writing to AFC\")\n"
            "\t\t\t}\n"
            "\t\t\t\n"
            "\t\t\twhile totalBytesWritten < totalSize {\n"
            "\t\t\t\tlet bytesLeft = totalSize - totalBytesWritten\n"
            "\t\t\t\tlet bytesToWrite = min(chunkSize, bytesLeft)\n"
            "\t\t\t\tlet writePtr = rawBuffer.advanced(by: totalBytesWritten)\n"
            "\t\t\t\t\n"
            "\t\t\t\tlet result = afc_file_write(fileHandle, writePtr, bytesToWrite)\n"
            "\t\t\t\tif result != nil {\n"
            "\t\t\t\t\tthrow IDeviceSwiftError(result)\n"
            "\t\t\t\t}\n"
            "\t\t\t\t\n"
            "\t\t\t\ttotalBytesWritten += bytesToWrite\n"
            "\t\t\t\t\n"
            "\t\t\t\tlet progress = Double(totalBytesWritten) / Double(totalSize)\n"
            "\t\t\t\ttry await self._updateUploadProgress(with: progress)\n"
            "\t\t\t}\n"
        ),
        (
            "\t\t\t// Replaces the old check on `baseAddress` being non-nil. A\n"
            "\t\t\t// non-empty Data always has one, so the only case that guard\n"
            "\t\t\t// actually caught was an empty file — which is what this says.\n"
            "\t\t\tguard totalSize > 0 else {\n"
            "\t\t\t\tthrow IDeviceSwiftError(message: \"Error writing to AFC\")\n"
            "\t\t\t}\n"
            "\t\t\t\n"
            "\t\t\twhile totalBytesWritten < totalSize {\n"
            "\t\t\t\tlet bytesLeft = totalSize - totalBytesWritten\n"
            "\t\t\t\tlet bytesToWrite = min(chunkSize, bytesLeft)\n"
            "\t\t\t\tlet offset = totalBytesWritten\n"
            "\t\t\t\t\n"
            "\t\t\t\t// The pointer is now obtained and used entirely within the\n"
            "\t\t\t\t// closure. `withUnsafeBytes` only guarantees the buffer for\n"
            "\t\t\t\t// the closure's duration; the previous code held it across\n"
            "\t\t\t\t// the whole loop. With a memory-mapped Data that is not a\n"
            "\t\t\t\t// bet worth taking.\n"
            "\t\t\t\t//\n"
            "\t\t\t\t// Re-entering per chunk costs nothing — it hands back the\n"
            "\t\t\t\t// same mapping each time, it doesn't copy.\n"
            "\t\t\t\tlet result = data.withUnsafeBytes { raw in\n"
            "\t\t\t\t\tafc_file_write(\n"
            "\t\t\t\t\t\tfileHandle,\n"
            "\t\t\t\t\t\traw.baseAddress!.assumingMemoryBound(to: UInt8.self).advanced(by: offset),\n"
            "\t\t\t\t\t\tbytesToWrite\n"
            "\t\t\t\t\t)\n"
            "\t\t\t\t}\n"
            "\t\t\t\t\n"
            "\t\t\t\tif result != nil {\n"
            "\t\t\t\t\tthrow IDeviceSwiftError(result)\n"
            "\t\t\t\t}\n"
            "\t\t\t\t\n"
            "\t\t\t\ttotalBytesWritten += bytesToWrite\n"
            "\t\t\t\t\n"
            "\t\t\t\tlet progress = Double(totalBytesWritten) / Double(totalSize)\n"
            "\t\t\t\ttry await self._updateUploadProgress(with: progress)\n"
            "\t\t\t}\n"
        ),
    ),
]


def main() -> int:
    if not TARGET.exists():
        print(f"::error::{TARGET} not found. Were submodules checked out?")
        return 1

    source = TARGET.read_text()
    failures = []

    for description, old, new in PATCHES:
        if new in source and old not in source:
            print(f"  already applied: {description}")
            continue

        count = source.count(old)
        if count != 1:
            failures.append(f"{description} — expected 1 match, found {count}")
            continue

        source = source.replace(old, new, 1)
        print(f"  patched: {description}")

    if failures:
        print("::error::IDeviceKit patch failed to apply. The submodule has "
              "probably moved and these patches need re-deriving against the "
              "new source. Refusing to build an unpatched IPA.")
        for failure in failures:
            print(f"::error::  {failure}")
        return 1

    TARGET.write_text(source)
    print("IDeviceKit patched successfully.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
