"""Exercise the native signing policy with local, CloudKit and KVS bundles."""
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]


class CloudEntitlementTests(unittest.TestCase):
    def test_native_policy(self):
        core = ROOT / "ZsignLatest/Sources/ZsignC/Core"
        with tempfile.TemporaryDirectory(prefix="asign-cloud-policy-") as temporary:
            executable = Path(temporary) / "cloud-policy"
            json_object = Path(temporary) / "json.o"
            subprocess.run(["clang++", "-std=c++17", "-c", str(core / "common/json.cpp"),
                            "-o", str(json_object)], check=True)
            subprocess.run(["clang++", "-std=c++17", "-Wall", "-Wextra", "-Werror",
                            "-I", str(core), str(ROOT / "Tests/IPAPatching/cloud_entitlements.cpp"),
                            str(json_object), "-o", str(executable)], check=True)
            subprocess.run([str(executable)], check=True)
