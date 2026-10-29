"""Exercise installer and mount gating with fake commands in a temporary tree."""
import os
import re
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile

source = Path(sys.argv[1])


def run(script, *args, env):
    return subprocess.run(['bash', str(script), *args], env=env, check=True,
                          capture_output=True, text=True).stdout


with tempfile.TemporaryDirectory(prefix='mmm-wiring-') as tmp:
    root = Path(tmp)
    fixture = root / 'source'
    fixture.mkdir()
    for name in ('install.sh', 'launch.env', 'thornbots-launch.sh', 'thornbots-start.sh',
                 'thornbots.service', 'mcap-storage.yaml', 'logind-thornbots.conf',
                 'thornbots-mmm-poweroff.path', 'thornbots-mmm-poweroff.service'):
        shutil.copy(source / name, fixture / name)
    installer = fixture / 'install.sh'
    script = installer.read_text().replace('/etc/', f'{root}/etc/').replace(
        '/usr/local/', f'{root}/usr/local/')
    installer.write_text(script)
    (fixture / 'build-helpers.sh').write_text(
        '#!/bin/bash\ntouch "$1/cuda-probe" "$1/log-stamp" "$1/mmm-poweroff"\n')
    for name in ('etc/systemd/system', 'etc/tmpfiles.d', 'usr/local/bin', 'bin', 'workspace'):
        (root / name).mkdir(parents=True, exist_ok=True)
    log = root / 'commands'
    fakes = {
        'id': '#!/bin/sh\necho 0\n',
        'getent': f'#!/bin/sh\necho "test:x:1:1::{root}/home:/bin/bash"\n',
        'systemctl': f'#!/bin/sh\necho "$*" >> "{log}"\n',
        'systemd-tmpfiles': f'#!/bin/sh\necho "tmpfiles $*" >> "{log}"\n',
    }
    for name, text in fakes.items():
        target = root / 'bin' / name
        target.write_text(text)
        target.chmod(0o755)
    env = dict(os.environ, PATH=f'{root}/bin:' + os.environ['PATH'])
    run(installer, '--ws', str(root / 'workspace'), env=env)
    marker = root / 'etc/thornbots/mmm-shutdown.enabled'
    assert not marker.exists()
    assert not (root / 'etc/tmpfiles.d/thornbots-mmm.conf').exists()
    assert 'mmm-poweroff' not in log.read_text()
    cfg = root / 'etc/thornbots/launch.env'
    configured_ws = root / 'configured-workspace'
    configured_ws.mkdir()
    cfg.write_text(re.sub(r'^HOST_USER_GID=.*$', 'HOST_USER_GID=',
                          re.sub(r'^ISAAC_ROS_WS_HOST=.*$', f'ISAAC_ROS_WS_HOST={configured_ws}',
                                 cfg.read_text(), flags=re.MULTILINE),
                          flags=re.MULTILINE))
    # Distinguish the preserved workspace from --ws without requiring extra groups.
    stat = root / 'bin/stat'
    stat.write_text(f'#!/bin/sh\nif [ "$1" = -c ] && [ "$2" = %g ] && '
                    f'[ "$3" = "{configured_ws}" ]; then echo 12345; '
                    'else exec /usr/bin/stat "$@"; fi\n')
    stat.chmod(0o755)
    run(installer, '--ws', str(root / 'workspace'), '--enable-mmm-shutdown', env=env)
    assert marker.exists()
    assert (root / 'etc/tmpfiles.d/thornbots-mmm.conf').read_text() == (
        'd /run/thornbots-mmm 0730 root 12345 -\n')
    assert 'enable --now thornbots-mmm-poweroff.path' in log.read_text()
    log.write_text('')
    run(installer, '--ws', str(root / 'workspace'), env=env)
    assert marker.exists() and 'enable --now thornbots-mmm-poweroff.path' not in log.read_text()
    # Execute the actual mount-gating block without running the robot stack.
    startup = (source / 'thornbots-start.sh').read_text()
    block = startup[startup.index('mmm_mount=()'):startup.index('# ── Image:')]
    block = block.replace('/etc/thornbots/', f'{root}/etc/thornbots/').replace(
        '/run/thornbots-mmm', f'{root}/run/thornbots-mmm')
    gate = root / 'gate.sh'
    gate.write_text('set -eu\n' + block + '\nprintf "%s\\n" "${mmm_mount[@]}"\n')
    request_dir = root / 'run/thornbots-mmm'
    request_dir.mkdir(parents=True)
    assert 'type=bind' in run(gate, env=env)
    marker.unlink()
    assert run(gate, env=env).strip() == ''
    marker.touch()
    request_dir.rmdir()
    result = subprocess.run(['bash', str(gate)], env=env, capture_output=True)
    assert result.returncode != 0 and b'type=bind' not in result.stdout
print('installer opt-in, preserved config, and startup mount gating passed')
