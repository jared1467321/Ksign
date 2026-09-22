#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/../.."
if ! command -v swiftc >/dev/null || [[ "$(uname -s)" != Darwin ]]; then
  echo "Requires macOS with the Swift command-line tools (Darwin process telemetry)." >&2
  exit 2
fi
test_dir=$(mktemp -d "${TMPDIR:-/tmp}/ksign-archive-tests.XXXXXX")
trap 'rm -rf "$test_dir"' EXIT
swiftc -swift-version 5 -target "$(uname -m)-apple-macosx13.0" \
  -D ARCHIVE_MEMORY_TESTING -parse-as-library \
  Ksign/Utilities/Handlers/ArchiveMemoryCoordinator.swift \
  Tests/ArchiveMemory/ArchiveMemoryTests.swift \
  -o "$test_dir/archive-memory-tests"
"$test_dir/archive-memory-tests"
