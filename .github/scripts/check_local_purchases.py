#!/usr/bin/env python3
"""Exercise shipping local-purchase hooks against StoreKit-shaped test objects.

Requires macOS Foundation; no Apple account, device or network connection.
"""
from pathlib import Path
import platform
import subprocess
import tempfile
import uuid

ROOT = Path(__file__).resolve().parents[2]
SOURCE = ROOT / "Native/IdentityPatch"


def main():
    if platform.system() != "Darwin":
        raise SystemExit("Local purchase runtime checks require macOS Foundation.")
    with tempfile.TemporaryDirectory(prefix="asign-purchases-") as directory:
        output = Path(directory) / "purchase-checks"
        subprocess.run([
            "xcrun", "clang", "-fobjc-arc", "-fblocks", "-std=gnu11", "-Wall", "-Wextra", "-Werror",
            "-DASIGN_PURCHASE_TESTING=1", "-I", str(SOURCE),
            str(SOURCE / "LocalPurchases.m"), str(SOURCE / "StoreKitPurchasePatch.m"),
            str(SOURCE / "RevenueCatPurchasePatch.m"), str(SOURCE / "Tests/LocalPurchasesTests.m"),
            "-framework", "Foundation", "-o", str(output),
        ], check=True)
        suite = "asign.purchase.checks." + uuid.uuid4().hex
        try:
            for mode in ("write", "read", "runtime"):
                subprocess.run([str(output), suite, mode], check=True, timeout=30)
        finally:
            subprocess.run([str(output), suite, "cleanup"], check=True, timeout=30)


if __name__ == "__main__":
    main()
