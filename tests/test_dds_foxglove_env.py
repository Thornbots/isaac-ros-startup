"""thornbots-launch.sh resolves the remote-DDS and Foxglove switches as documented."""
from pathlib import Path
import subprocess
import unittest

SCRIPT = (Path(__file__).resolve().parents[1] / 'thornbots-launch.sh').read_text()
DDS = SCRIPT[SCRIPT.index('case "${THORNBOTS_REMOTE_DDS'):SCRIPT.index('boot "remote DDS')]
FOXGLOVE = SCRIPT[SCRIPT.index('foxglove="${'):SCRIPT.index('if [[ "${foxglove,,}"')]


def run(snippet, *assignments):
    env = ['env', '-i', 'PATH=/usr/bin:/bin', *assignments]
    out = subprocess.run(
        [*env, 'bash', '-c', snippet + '\nprintf "%s|%s|%s" "${THORNBOTS_REMOTE_DDS-}" '
         '"${FASTRTPS_DEFAULT_PROFILES_FILE-unset}" "${ROS_AUTOMATIC_DISCOVERY_RANGE-unset}"'],
        capture_output=True, text=True, check=True)
    return out.stdout


class StartupSwitchTest(unittest.TestCase):
    def test_remote_dds_is_off_by_default_and_ignores_the_baked_profile(self):
        stale = 'FASTRTPS_DEFAULT_PROFILES_FILE=/etc/fastdds/profile.xml'
        self.assertEqual(run(DDS, stale), 'false|unset|LOCALHOST')
        self.assertEqual(run(DDS, stale, 'THORNBOTS_REMOTE_DDS=false'), 'false|unset|LOCALHOST')
        self.assertEqual(run(DDS, stale, 'THORNBOTS_REMOTE_DDS=bogus'), 'false|unset|LOCALHOST')

    def test_remote_dds_on_restores_the_peer_profile(self):
        for value in ('true', '1', 'TRUE'):
            self.assertEqual(
                run(DDS, 'ROS_AUTOMATIC_DISCOVERY_RANGE=LOCALHOST', f'THORNBOTS_REMOTE_DDS={value}'),
                'true|/etc/fastdds/profile.xml|unset')

    def test_foxglove_is_on_by_default_and_old_env_is_honoured(self):
        probe = FOXGLOVE + '\nprintf "%s" "$foxglove"; printf "|"'
        self.assertTrue(run(probe).startswith('true|'))
        self.assertTrue(run(probe, 'ENABLE_FOXGLOVE=false').startswith('false|'))
        self.assertTrue(run(probe, 'ENABLE_FOXGLOVE=false', 'THORNBOTS_FOXGLOVE=true').startswith('true|'))
        self.assertTrue(run(probe, 'THORNBOTS_FOXGLOVE=false').startswith('false|'))


if __name__ == '__main__':
    unittest.main()
