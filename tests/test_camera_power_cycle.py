"""Run camera-power-cycle.sh against a fake sysfs tree."""
import os
from pathlib import Path
import subprocess
import sys
import tempfile

script = Path(sys.argv[1]) / 'camera-power-cycle.sh'


def hub(root, name, ports=4):
    for n in range(1, ports + 1):
        port = root / name / f'{name}:1.0' / f'{name}-port{n}'
        port.mkdir(parents=True)
        (port / 'disable').write_text('0\n')


def run(root, *hubs):
    env = dict(os.environ, THORNBOTS_USB_SYSFS=str(root),
               CAMERA_POWER_OFF_S='0', CAMERA_POWER_WAIT_S='1')
    return subprocess.run(['bash', str(script), *hubs], env=env,
                          capture_output=True, text=True)


with tempfile.TemporaryDirectory(prefix='camera-power-') as tmp:
    root = Path(tmp)
    hub(root, '2-1')
    hub(root, '1-2')
    disables = sorted(root.glob('*/*/*-port*/disable'))

    # Camera already present: nothing is touched.
    cam = root / '2-1.2'
    cam.mkdir()
    (cam / 'idVendor').write_text('8086\n')
    for d in disables:
        d.write_text('x\n')
    assert run(root, '2-1', '1-2').returncode == 0
    assert all(d.read_text() == 'x\n' for d in disables)

    # Camera absent and stays absent: every port of both hubs is cycled
    # (ends enabled) and the helper reports failure.
    (cam / 'idVendor').unlink()
    result = run(root, '2-1', '1-2')
    assert result.returncode == 1, result
    assert len(disables) == 8
    assert all(d.read_text() == '0\n' for d in disables)

    # No such hub: fails without writing anything.
    result = run(root, '9-9')
    assert result.returncode == 1 and 'no switchable ports' in result.stderr, result
print('ok')
