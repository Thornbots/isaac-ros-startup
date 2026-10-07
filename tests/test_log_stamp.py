"""Exercise the log pipe without starting the robot service or a container."""
from pathlib import Path
import re
import subprocess
import sys
import tempfile
import unittest


SCRIPT = Path(__file__).resolve().parents[1] / 'log-stamp.py'
STAMP = re.compile(r'^\[\s*\d+\.\d{3} \d{2}:\d{2}:\d{2}\.\d{3}\??\] ')


class LogStampTest(unittest.TestCase):
    def run_pipe(self, destination, data):
        return subprocess.run(
            [sys.executable, str(SCRIPT), str(destination)], input=data,
            stdout=subprocess.PIPE, stderr=subprocess.PIPE, check=True, timeout=10,
        ).stdout.decode('utf-8')

    def test_mirrors_stamped_lines_and_flushes_final_partial_line(self):
        with tempfile.TemporaryDirectory() as directory:
            destination = Path(directory) / 'run.log'
            output = self.run_pipe(destination, b'first\r\nsecond\npartial')
            self.assertEqual(destination.read_text(), output)
            lines = output.splitlines()
            self.assertEqual(len(lines), 4)
            self.assertIn('[clock] NTP ', lines[0])
            for line in lines:
                self.assertRegex(line, STAMP)
            self.assertEqual([STAMP.sub('', line) for line in lines[1:]],
                             ['first', 'second', 'partial'])

    def test_appends_existing_log_and_replaces_invalid_utf8(self):
        with tempfile.TemporaryDirectory() as directory:
            destination = Path(directory) / 'run.log'
            destination.write_text('previous run\n')
            output = self.run_pipe(destination, b'bad \xff byte\n')
            self.assertEqual(destination.read_text(), 'previous run\n' + output)
            self.assertIn('bad \ufffd byte\n', output)

    def test_unwritable_log_keeps_stdout(self):
        with tempfile.TemporaryDirectory() as directory:
            destination = Path(directory) / 'missing' / 'run.log'
            output = self.run_pipe(destination, b'keep the journal\n')
            self.assertIn('[log-stamp] cannot open ', output)
            self.assertIn('journal only\n', output)
            self.assertIn('keep the journal\n', output)
            self.assertFalse(destination.exists())


if __name__ == '__main__':
    unittest.main()
