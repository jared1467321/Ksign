#!/usr/bin/env python3
"""Compatibility entry point; local and CI builds use the same device overlays."""
import runpy
from pathlib import Path

if __name__ == "__main__":
    runpy.run_path(str(Path(__file__).with_name("integrate_devicekit.py")), run_name="__main__")
