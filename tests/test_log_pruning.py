"""Exercise the production pruning block without starting the robot service."""

import os
from pathlib import Path
import subprocess
import sys
import tempfile

source = Path(sys.argv[1])
script = (source / 'thornbots-start.sh').read_text()
block = script.split('pruned=()', 1)[1].split('# Flags follow', 1)[0]
block = 'pruned=()' + block

with tempfile.TemporaryDirectory() as temporary:
    root = Path(temporary)
    binary = root / 'bin'
    binary.mkdir()
    df = binary / 'df'
    df.write_text("""#!/bin/bash
n=$(cat "$DF_CALLS")
echo $((n + 1)) > "$DF_CALLS"
echo Avail
if (( n < LOW_CHECKS )); then echo 1G; else echo 100G; fi
""")
    df.chmod(0o755)
    for low_checks, keep, expected in [
            (0, 2, []), (2, 2, [1, 2]), (100, 2, [1, 2, 3, 4]),
            (100, 0, [1, 2, 3, 4, 5])]:
        logs = root / f'logs-{low_checks}-{keep}'
        logs.mkdir()
        current = 'thornbots-run00006'
        # Include an active text log: even keep=0 must protect the current run.
        for number in range(1, 7):
            name = f'thornbots-run{number:05}'
            (logs / name / 'bag').mkdir(parents=True)
            (logs / name / 'bag' / 'recording.mcap').write_text('bag')
            (logs / f'{name}.log').write_text('log')
        (logs / 'latest').symlink_to(current)
        (logs / 'latest.log').symlink_to(f'{current}.log')
        (logs / 'unrelated').write_text('keep')
        calls = root / 'df-calls'
        calls.write_text('0')
        env = dict(os.environ, PATH=f'{binary}:' + os.environ['PATH'],
                   LOG_DIR=str(logs), RUN_NAME=current, LOG_KEEP_RUNS=str(keep),
                   LOG_MIN_FREE_GB='20', LOW_CHECKS=str(low_checks), DF_CALLS=str(calls))
        subprocess.run(['bash', '-euo', 'pipefail', '-c', block], env=env, check=True)
        for number in range(1, 7):
            name = f'thornbots-run{number:05}'
            assert (logs / name).exists() == (number not in expected), name
            assert (logs / f'{name}.log').exists() == (number not in expected), name
        assert (logs / 'latest' / 'bag' / 'recording.mcap').is_file()
        assert (logs / 'latest.log').read_text() == 'log'
        assert (logs / 'unrelated').exists()
        print(f'PASS low_checks={low_checks} keep={keep} deleted={expected}; active run retained')
