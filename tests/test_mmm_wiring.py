"""Exercise installer, mount and launch wiring with fake commands in a temporary tree."""
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
                 'camera-power-cycle.sh',
                 'thornbots-mmm-poweroff.path', 'thornbots-mmm-poweroff.service', 'eduroam.sh',
                 'thornbots-match-wifi-off.path', 'thornbots-match-wifi-off.service'):
        shutil.copy(source / name, fixture / name)
    installer = fixture / 'install.sh'
    script = installer.read_text().replace('/etc/', f'{root}/etc/').replace(
        '/usr/local/', f'{root}/usr/local/')
    installer.write_text(script)
    (fixture / 'build-helpers.sh').write_text(
        '#!/bin/bash\ntouch "$1/cuda-probe" "$1/log-stamp" "$1/mmm-poweroff" "$1/match-wifi-off"\n')
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
    env.pop('AUTO_LAUNCH_ARGS', None)
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
    # Execute the actual gate and launch arguments without running the robot stack.
    startup = (source / 'thornbots-start.sh').read_text()
    assert '-e AUTO_LAUNCH_ARGS' in startup
    block = startup[startup.index('mmm_mount=()'):startup.index('# ── Image:')]
    block = block.replace('/etc/thornbots/', f'{root}/etc/thornbots/').replace(
        '/run/thornbots-mmm', f'{root}/run/thornbots-mmm').replace(
        '/run/thornbots-net', f'{root}/run/thornbots-net')
    gate = root / 'gate.sh'
    gate.write_text('set -eu\n' + block + '\nprintf "%s\\n" "${mmm_mount[@]}" "${wifi_mount[@]}"\n'
                    'bash "$1"\n')
    launch = (source / 'thornbots-launch.sh').read_text()
    invocation = launch[launch.index('setsid env --default-signal=INT ros2 launch thornbots_pkg'):
                        launch.index('auto_pid=$!')]
    launch_args = root / 'launch-args.sh'
    launch_args.write_text('set -eu\nsetsid() { printf "arg=%s\\n" "$@"; }\n' +
                           invocation + '\nwait\n')
    request_dir = root / 'run/thornbots-mmm'
    request_dir.mkdir(parents=True)
    for configured in (None, '', 'map_output_dir:=/tmp/maps mmm_shutdown_after_save:=false'):
        launch_env = dict(env)
        launch_env.pop('AUTO_LAUNCH_ARGS', None)
        if configured is not None:
            launch_env['AUTO_LAUNCH_ARGS'] = configured
        output = run(gate, str(launch_args), env=launch_env)
        assert 'type=bind' in output
        args = [line.removeprefix('arg=') for line in output.splitlines()
                if line.startswith('arg=')]
        assert args[-1] == 'mmm_shutdown_after_save:=true'
        if configured:
            assert args[-3:-1] == configured.split()
    marker.unlink()
    output = run(gate, str(launch_args), env=env)
    assert 'type=bind' not in output and 'mmm_shutdown_after_save:=' not in output
    output = run(gate, str(launch_args), env=dict(env, AUTO_LAUNCH_ARGS='map_output_dir:=/tmp/maps'))
    assert 'arg=map_output_dir:=/tmp/maps' in output
    assert 'type=bind' not in output and 'mmm_shutdown_after_save:=' not in output
    marker.touch()
    # Both opt-ins survive reinstall and append after operator arguments.
    run(installer, '--ws', str(root / 'workspace'), '--enable-match-wifi-off', env=env)
    wifi_marker = root / 'etc/thornbots/match-wifi-off.enabled'
    assert wifi_marker.exists()
    assert (root / 'etc/tmpfiles.d/thornbots-net.conf').read_text() == (
        'd /run/thornbots-net 0730 root 12345 -\n')
    assert 'enable --now thornbots-match-wifi-off.path' in log.read_text()
    run(installer, '--ws', str(root / 'workspace'), '--reset-config', env=env)
    assert marker.exists() and wifi_marker.exists()
    wifi_dir = root / 'run/thornbots-net'
    wifi_dir.mkdir(parents=True)
    output = run(gate, str(launch_args), env=dict(env, AUTO_LAUNCH_ARGS='match_wifi_off:=false'))
    assert 'dst=' + str(wifi_dir) in output
    assert output.rfind('arg=match_wifi_off:=true') > output.find('arg=match_wifi_off:=false')
    wifi_dir.rmdir()
    result = subprocess.run(['bash', str(gate)], env=env, capture_output=True)
    assert result.returncode != 0 and b'type=bind' not in result.stdout
    wifi_marker.unlink()
    request_dir.rmdir()
    result = subprocess.run(['bash', str(gate)], env=env, capture_output=True)
    assert result.returncode != 0 and b'type=bind' not in result.stdout
print('installer opt-in, preserved config, startup mount and launch wiring passed')
