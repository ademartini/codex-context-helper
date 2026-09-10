"""The unit runner must expose failures without reporting success."""
import os
from pathlib import Path
import subprocess
import tempfile
import unittest


class UnitRunnerTests(unittest.TestCase):
    def run_runner(self, build_exit=0, test_exit=0):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            commands = {
                'xcode-select': 'echo /MockXcode/Developer',
                'xcrun': f'echo "{root}/mock-xctest"',
                'xcodebuild': f'echo BUILD_DIAGNOSTIC; exit {build_exit}',
                'mock-xctest': f'echo TEST_DIAGNOSTIC; exit {test_exit}',
            }
            for name, body in commands.items():
                path = root / name
                path.write_text('#!/bin/bash\n' + body + '\n')
                path.chmod(0o755)
            env = dict(os.environ, PATH=f'{root}:/usr/bin:/bin', TEST_DERIVED_DATA=str(root / 'build'))
            script = Path(__file__).resolve().parents[1] / 'test_unit.sh'
            return subprocess.run(['/bin/bash', str(script)], env=env, text=True, capture_output=True)

    def test_build_failure_exposes_diagnostics_and_preserves_exit_code(self):
        result = self.run_runner(build_exit=23)
        self.assertEqual(result.returncode, 23)
        self.assertIn('BUILD_DIAGNOSTIC', result.stdout + result.stderr)

    def test_test_failure_exposes_diagnostics_and_preserves_exit_code(self):
        result = self.run_runner(test_exit=17)
        self.assertEqual(result.returncode, 17)
        self.assertIn('TEST_DIAGNOSTIC', result.stdout + result.stderr)

    def test_successful_exit_without_test_execution_still_fails(self):
        result = self.run_runner()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('No passing unit-test execution', result.stdout + result.stderr)


if __name__ == '__main__':
    unittest.main()
