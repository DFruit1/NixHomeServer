#!/usr/bin/env bash
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/test-common.sh"
cd "$TESTS_REPO_ROOT"
ensure_tools python3 bash
python3 - <<'PY'
from pathlib import Path
import subprocess
import tempfile

source = Path('system-resources.nix').read_text()
script = source.split('gpuPowerLimitScript = pkgs.writeShellApplication {', 1)[1].split("text = ''", 1)[1].split("\n    '';", 1)[0]
script = script.replace('${toString power.gpu.powerLimitWatts}', '175').replace("''${", '${')
with tempfile.TemporaryDirectory() as directory:
    root = Path(directory)
    script = script.replace('/sys/class/hwmon', str(root))
    def run():
        return subprocess.run(['bash', '-c', script], capture_output=True, text=True)
    assert run().returncode != 0, 'Missing GPU must fail visibly'
    hwmon = root / 'hwmon7'
    hwmon.mkdir()
    (hwmon / 'name').write_text('xe\n')
    (hwmon / 'power1_cap').write_text('220000000\n')
    (hwmon / 'power1_crit').write_text('440000000\n')
    result = run()
    assert result.returncode == 0, result.stderr
    assert (hwmon / 'power1_cap').read_text().strip() == '175000000'
    assert (hwmon / 'power1_crit').read_text().strip() == '440000000'
    assert run().returncode == 0, 'Repeated application must be idempotent'
    (hwmon / 'power1_cap').write_text('150000000\n')
    (hwmon / 'power1_crit').write_text('160000000\n')
    assert run().returncode != 0, 'Reject requests above the firmware limit'
    assert (hwmon / 'power1_cap').read_text().strip() == '150000000'
print('GPU power limit: missing hardware, cap write/readback, idempotence and bound checks passed.')
PY
