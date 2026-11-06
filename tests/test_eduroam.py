"""Exercise profile reuse and credential-free instructions with a fake nmcli."""
import os
from pathlib import Path
import subprocess
import sys
import tempfile

source = Path(sys.argv[1])
with tempfile.TemporaryDirectory(prefix='eduroam-test-') as tmp:
    root = Path(tmp)
    log = root / 'calls'
    for name, text in {
        'id': '#!/bin/sh\necho 0\n',
        'nmcli': '''#!/bin/bash
set -eu
if [[ "$*" == '-g UUID connection show' ]]; then
    [[ "$MODE" != enumerate-fail ]] || exit 7
    printf '%s\\n' one two three
elif [[ "$1" == connection ]]; then
    printf '%s\\n' "$*" >> "$CALLS"
elif [[ "$2" == connection.type ]]; then
    echo 802-11-wireless
elif [[ "$2" == 802-11-wireless.ssid ]]; then
    if [[ "$MODE" == existing && "$6" != three ]]; then echo eduroam; else echo RHIT-OPEN; fi
elif [[ "$2" == connection.autoconnect-priority ]]; then
    echo 20
else exit 9
fi
''',
    }.items():
        path = root / name
        path.write_text(text)
        path.chmod(0o755)
    env = dict(os.environ, PATH=f'{root}:' + os.environ['PATH'], CALLS=str(log))
    result = subprocess.run(['bash', str(source / 'eduroam.sh')],
                            env=dict(env, MODE='existing'), capture_output=True, text=True)
    assert result.returncode == 0, result.stderr
    assert log.read_text().splitlines() == [
        f'connection modify uuid {uuid} connection.autoconnect yes '
        "connection.autoconnect-priority 21 connection.permissions " for uuid in ('one', 'two')]
    log.unlink()
    result = subprocess.run(['bash', str(source / 'eduroam.sh')],
                            env=dict(env, MODE='missing'), capture_output=True, text=True)
    assert result.returncode == 0, result.stderr
    assert not log.exists()
    assert 'sudo nmcli --ask connection add type wifi' in result.stdout
    assert '802-1x.identity' in result.stdout and 'ClearPass' in result.stdout
    assert '802-1x.password-flags 0' in result.stdout and '802-1x.password ' not in result.stdout
    result = subprocess.run(['bash', str(source / 'eduroam.sh')],
                            env=dict(env, MODE='enumerate-fail'), capture_output=True, text=True)
    assert result.returncode != 0 and not log.exists()
print('eduroam reuse, priority, interactive instructions and enumeration failure passed')
