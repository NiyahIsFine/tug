import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[3]
POWERSHELL = shutil.which("pwsh")


@unittest.skipUnless(POWERSHELL, "PowerShell 7 is required for Android Pub cache tests")
class AndroidPubCacheTests(unittest.TestCase):
    def setUp(self):
        (ROOT / ".local").mkdir(exist_ok=True)
        self.temporary = tempfile.TemporaryDirectory(dir=ROOT / ".local")
        self.addCleanup(self.temporary.cleanup)
        self.directory = Path(self.temporary.name)
        self.source = self.directory / "original cache"
        self.destination = self.directory / "copied cache"
        self.source.mkdir()
        self.environment = os.environ.copy()

    def prepare(self, source=None, destination=None):
        command = (
            '& $env:TUG_CACHE_SCRIPT -SourceDirectory $env:TUG_CACHE_SOURCE '
            '-DestinationDirectory $env:TUG_CACHE_DESTINATION; '
            'if (!$?) { exit 1 }; '
            '@{pub_cache=$env:PUB_CACHE} | ConvertTo-Json -Compress'
        )
        self.environment.update(
            TUG_CACHE_SCRIPT=str(ROOT / "scripts/prepare-android-pub-cache.ps1"),
            TUG_CACHE_SOURCE=str(source) if source is not None else "",
            TUG_CACHE_DESTINATION=str(destination or self.destination),
        )
        return subprocess.run(
            [POWERSHELL, "-NoProfile", "-Command", command],
            capture_output=True, text=True, env=self.environment,
        )

    def test_copies_nested_and_hidden_entries_without_changing_source(self):
        files = {
            "hosted/pub.dev/plugin/android/src/Plugin.kt": b"plugin source",
            "hosted-hashes/pub.dev/plugin.sha256": b"package hash",
            ".metadata": b"cache metadata",
        }
        for name, contents in files.items():
            path = self.source / name
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_bytes(contents)
        result = self.prepare(source=self.source)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(json.loads(result.stdout.splitlines()[-1])["pub_cache"], str(self.destination))
        for name, contents in files.items():
            self.assertEqual((self.source / name).read_bytes(), contents)
            self.assertEqual((self.destination / name).read_bytes(), contents)

    def test_repeated_copy_merges_without_nesting_or_deleting_existing_packages(self):
        plugin = self.source / "hosted/plugin/source.kt"
        plugin.parent.mkdir(parents=True)
        plugin.write_text("original")
        result = self.prepare(source=self.source)
        self.assertEqual(result.returncode, 0, result.stderr)
        retained = self.destination / "hosted/other/source.kt"
        retained.parent.mkdir(parents=True)
        retained.write_text("keep")
        plugin.write_text("updated")
        result = self.prepare(source=self.source)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual((self.destination / "hosted/plugin/source.kt").read_text(), "updated")
        self.assertEqual(retained.read_text(), "keep")
        self.assertFalse((self.destination / "hosted/hosted").exists())

    def test_uses_configured_pub_cache(self):
        (self.source / "marker").write_text("configured cache")
        self.environment["PUB_CACHE"] = str(self.source)
        result = self.prepare()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual((self.destination / "marker").read_text(), "configured cache")

    def test_uses_default_windows_pub_cache(self):
        local_app_data = self.directory / "profile"
        cache = local_app_data / "Pub/Cache"
        cache.mkdir(parents=True)
        (cache / "marker").write_text("default cache")
        self.environment.pop("PUB_CACHE", None)
        self.environment["LOCALAPPDATA"] = str(local_app_data)
        result = self.prepare()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual((self.destination / "marker").read_text(), "default cache")

    def test_missing_source_creates_empty_cache(self):
        result = self.prepare(source=self.directory / "missing")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(list(self.destination.iterdir()), [])

    def test_same_source_and_destination_does_not_copy_into_itself(self):
        (self.source / "marker").write_text("keep")
        result = self.prepare(source=self.source, destination=self.source)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(list(self.source.iterdir()), [self.source / "marker"])

    def test_rejects_overlapping_directories_before_copying(self):
        for source, destination in (
            (self.source, self.source / "nested"),
            (self.source / "nested", self.source),
        ):
            with self.subTest(source=source, destination=destination):
                result = self.prepare(source=source, destination=destination)
                self.assertNotEqual(result.returncode, 0)
                self.assertIn("must not contain one another", result.stderr)
                self.assertEqual(list(self.source.iterdir()), [])

    @unittest.skipUnless(os.name == "nt", "Windows drive roots are required")
    def test_rejects_destination_on_another_drive(self):
        other_drive = "Z:" if ROOT.drive.upper() != "Z:" else "Y:"
        result = self.prepare(source=self.source, destination=Path(other_drive + "/pub-cache"))
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("destination must be on the project drive", result.stderr)

    def validate_build(self, exit_code):
        scripts = self.directory / "scripts"
        scripts.mkdir()
        for name in ("build-android-client.ps1", "prepare-android-pub-cache.ps1"):
            shutil.copyfile(ROOT / "scripts" / name, scripts / name)
        for name in ("core", "android"):
            (self.directory / "client" / name).mkdir(parents=True)
        sdk = self.directory / "sdk"
        (sdk / "bin").mkdir(parents=True)
        for name in ("flutter.bat", "dart.bat"):
            (sdk / "bin" / name).write_text(
                '@echo off\n>>"%TUG_CACHE_LOG%" echo %PUB_CACHE%\n'
                f"exit /b {exit_code}\n"
            )
        other_drive = "Z:" if ROOT.drive.upper() != "Z:" else "Y:"
        original_cache = other_drive + "/missing-" + self.directory.name
        self.assertFalse(Path(original_cache).exists())
        log = self.directory / "commands.txt"
        self.environment.update(
            PUB_CACHE=original_cache,
            TUG_BUILD_SCRIPT=str(scripts / "build-android-client.ps1"),
            TUG_FLUTTER_SDK=str(sdk),
            TUG_CACHE_LOG=str(log),
        )
        command = (
            'try { & $env:TUG_BUILD_SCRIPT -FlutterSdk $env:TUG_FLUTTER_SDK -ValidateOnly; '
            '$failed=$false } catch { $failed=$true }; '
            '@{failed=$failed;pub_cache=$env:PUB_CACHE} | ConvertTo-Json -Compress'
        )
        result = subprocess.run(
            [POWERSHELL, "-NoProfile", "-Command", command],
            capture_output=True, text=True, env=self.environment,
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        state = json.loads(result.stdout.splitlines()[-1])
        self.assertEqual(state["pub_cache"], original_cache)
        self.assertEqual(state["failed"], exit_code != 0)
        expected_cache = self.directory / ".local/pub-cache"
        self.assertTrue(expected_cache.is_dir())
        self.assertEqual(log.read_text().splitlines(), [str(expected_cache)] * (1 if exit_code else 6))

    @unittest.skipUnless(os.name == "nt", "Windows batch tool stubs are required")
    def test_build_uses_project_cache_before_dependency_resolution_and_restores_environment(self):
        self.validate_build(exit_code=0)

    @unittest.skipUnless(os.name == "nt", "Windows batch tool stubs are required")
    def test_failed_build_restores_environment(self):
        self.validate_build(exit_code=7)


if __name__ == "__main__":
    unittest.main()
