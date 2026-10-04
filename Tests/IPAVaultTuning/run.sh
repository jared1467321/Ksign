#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/../.."
if ! command -v swiftc >/dev/null; then
  echo "IPA Vault tuning tests require swiftc."
  exit 77
fi
test_dir=$(mktemp -d "${TMPDIR:-/tmp}/ksign-vault-tests.XXXXXX")
trap 'rm -rf "$test_dir"' EXIT
python3 - "$test_dir/Tuning.swift" <<'PY'
from pathlib import Path
import sys
source = Path('Ksign/Views/Downloader/ViewModels/IPADownloadManager.swift').read_text()
def section(start, end):
    return source[source.index(start):source.index(end, source.index(start))]
parts = [
    section('    private enum IPAVaultBatchProbeDimension', '    private enum IPAVaultBatchTuningPhase'),
    section('    private final class IPAVaultBatchAdaptiveProbe', '    private final class IPAVaultConcurrencyTrial'),
    section('    private func nextIPAVaultStreamSearchTarget()', '    private func finishIPAVaultConcurrencySearch'),
    section('    private func continueIPAVaultBatchProbe(', '    private func finishIPAVaultBatchProbe('),
    section('    private func relativeNoise(', '    private func fileSize('),
]
constants = '\n'.join(line for line in source.splitlines() if line.strip().startswith('private let ipavault') and any(name in line for name in ['Probe', 'HigherConcurrencyTolerance']))
harness = Path('Tests/IPAVaultTuning/TuningTests.swift').read_text()
Path(sys.argv[1]).write_text(harness.replace('// ACTUAL_CONTROLLER_CODE', '\n'.join(parts) + '\n' + constants))
PY
swiftc "$test_dir/Tuning.swift" -o "$test_dir/tuning-tests"
"$test_dir/tuning-tests"
