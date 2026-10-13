import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest


SCRIPTS = Path(__file__).resolve().parents[2]


class ScriptTestRunnerTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.runner = self.root / "run-script-tests.py"
        shutil.copyfile(SCRIPTS / "run-script-tests.py", self.runner)
        self.log = self.root / "executed.txt"
        for group in ("shared", "windows", "android", "server"):
            directory = self.root / "tests" / group
            directory.mkdir(parents=True)
            (directory / "__init__.py").touch()
            (directory / "test_selection.py").write_text(
                "import os\n"
                "import unittest\n"
                "\n"
                "class SelectionTest(unittest.TestCase):\n"
                "    def test_selected(self):\n"
                "        with open(os.environ['TUG_DISCOVERY_LOG'], 'a') as log:\n"
                f"            log.write('{group}\\n')\n"
                f"        self.assertNotEqual(os.environ.get('TUG_FAIL_GROUP'), '{group}')\n",
                encoding="utf-8",
            )

    def run_suite(self, platform, failing_group=""):
        self.log.unlink(missing_ok=True)
        environment = dict(os.environ, TUG_DISCOVERY_LOG=str(self.log), TUG_FAIL_GROUP=failing_group)
        result = subprocess.run(
            [sys.executable, str(self.runner), platform],
            capture_output=True, text=True, env=environment,
        )
        executed = self.log.read_text().splitlines() if self.log.exists() else []
        return result, executed

    def test_platform_runs_shared_and_selected_tests_only(self):
        for platform in ("windows", "android", "server"):
            with self.subTest(platform=platform):
                result, executed = self.run_suite(platform)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertCountEqual(executed, ["shared", platform])

    def test_all_runs_each_group_once(self):
        result, executed = self.run_suite("all")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertCountEqual(executed, ["shared", "windows", "android", "server"])

    def test_failure_in_shared_or_selected_tests_returns_nonzero(self):
        for group in ("shared", "server"):
            with self.subTest(group=group):
                result, executed = self.run_suite("server", failing_group=group)
                self.assertEqual(result.returncode, 1, result.stderr)
                self.assertCountEqual(executed, ["shared", "server"])

    def test_failure_in_unselected_platform_does_not_affect_result(self):
        result, executed = self.run_suite("server", failing_group="android")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertCountEqual(executed, ["shared", "server"])


if __name__ == "__main__":
    unittest.main()
