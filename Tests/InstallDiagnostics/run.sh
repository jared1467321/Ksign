#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/../.."
if ! command -v swiftc >/dev/null || [[ "$(uname -s)" != Darwin ]]; then
  echo "Requires macOS with Swift command-line tools." >&2
  exit 2
fi
test_dir=$(mktemp -d "${TMPDIR:-/tmp}/ksign-diagnostic-tests.XXXXXX")
trap 'rm -rf "$test_dir"' EXIT
swiftc -D INSTALL_DIAGNOSTICS_TESTING -swift-version 5 -parse-as-library Ksign/Utilities/PersistentDiagnosticLog.swift Tests/InstallDiagnostics/LogTests.swift -o "$test_dir/log-tests"
"$test_dir/log-tests"
