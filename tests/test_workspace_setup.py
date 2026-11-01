"""Exercise missing, complete and partially shadowed robot overlays."""
import pathlib
import subprocess
import sys
import tempfile
import unittest

SRC = pathlib.Path(sys.argv.pop(1)).resolve()


class WorkspaceSetup(unittest.TestCase):
    def check_overlay(self, setup):
        with tempfile.TemporaryDirectory() as tmp:
            workspace = pathlib.Path(tmp)
            if setup is not None:
                (workspace / 'install').mkdir()
                (workspace / 'install/local_setup.bash').write_text(setup)
            return subprocess.run(
                ['bash', '-c', 'source "$1/workspace-setup.sh"; '
                 'thornbots_source_overlay "$2"', 'test', str(SRC), tmp],
                capture_output=True, text=True, check=False)

    def test_missing(self):
        result = self.check_overlay(None)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('overlay missing', result.stderr)

    def test_complete(self):
        result = self.check_overlay('ros2() { echo "$workspace/install/$3"; }\n')
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_shadowed_package(self):
        result = self.check_overlay(
            'ros2() { if [[ "$3" == thornbots_pkg ]]; then '
            'echo /workspaces/ros2_ws/install/thornbots_pkg; else '
            'echo "$workspace/install/$3"; fi; }\n')
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('thornbots_pkg resolves outside', result.stderr)

    def test_missing_package(self):
        result = self.check_overlay('ros2() { return 1; }\n')
        self.assertNotEqual(result.returncode, 0)


if __name__ == '__main__':
    unittest.main()
