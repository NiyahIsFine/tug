import hashlib
import json
from pathlib import Path
import re
import shutil
import subprocess
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[3]
POWERSHELL = shutil.which("pwsh")


@unittest.skipUnless(POWERSHELL, "PowerShell 7 is required for Android packaging tests")
class AndroidPackageTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.directory = Path(self.temporary.name)
        self.release = self.directory / "release"
        self.release.mkdir()
        self.output = self.directory / "package"
        self.artifacts = []
        for name, architecture in (
            ("tug-android.apk", "arm64-v8a"),
            ("tug-android-arm32.apk", "armeabi-v7a"),
            ("tug-android-x86_64.apk", "x86_64"),
        ):
            apk = self.release / name
            apk.write_bytes(b"mock verified APK bytes " + architecture.encode())
            self.artifacts.append(dict(
                file=name, architecture=architecture,
                sha256=hashlib.sha256(apk.read_bytes()).hexdigest(), bytes=apk.stat().st_size,
                signing_certificate_sha256="a" * 64,
            ))
        self.apk = self.release / "tug-android.apk"
        revision = subprocess.check_output(["git", "-C", str(ROOT), "rev-parse", "HEAD"], text=True).strip()
        dirty = bool(subprocess.check_output([
            "git", "-C", str(ROOT), "status", "--porcelain", "--untracked-files=normal",
        ], text=True).strip())
        version = re.search(r"^version:\s*(\S+)", (ROOT / "client/android/pubspec.yaml").read_text(), re.MULTILINE).group(1)
        self.packaged_names = [f"tug-android-{architecture}-{version}.apk" for architecture in ("arm64", "arm32", "x86_64")]
        self.manifest = dict(
            source_commit=revision, source_dirty=dirty, version=version,
            architectures=["arm64-v8a", "armeabi-v7a", "x86_64"], artifacts=self.artifacts,
            flutter="3.47.7", dart="3.13.5", min_sdk=24, compile_sdk=36, target_sdk=36,
            signing="local Android debug keystore; not production distribution", signing_certificate_sha256="a" * 64,
            sha256=hashlib.sha256(self.apk.read_bytes()).hexdigest(), bytes=self.apk.stat().st_size,
        )
        self.write_manifest()

    def write_manifest(self):
        (self.release / "manifest.json").write_text(json.dumps(self.manifest), encoding="utf-8")

    def package(self):
        return subprocess.run([
            POWERSHELL, "-NoProfile", "-File", str(ROOT / "scripts/package-android-client.ps1"),
            "-ReleaseDirectory", str(self.release), "-OutputDirectory", str(self.output),
        ], capture_output=True, text=True)

    def test_packages_exact_assets_with_source_signing_and_checksums(self):
        result = self.package()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual({path.name for path in self.output.iterdir()}, {*self.packaged_names, "android-source.json", "android-sha256.txt"})
        self.assertEqual((self.output / self.packaged_names[0]).read_bytes(), self.apk.read_bytes())
        for artifact, packaged_name in zip(self.artifacts, self.packaged_names):
            self.assertEqual((self.output / packaged_name).read_bytes(), (self.release / artifact["file"]).read_bytes())
        metadata = json.loads((self.output / "android-source.json").read_text(encoding="utf-8-sig"))
        self.assertEqual(metadata["component"], "tug-android")
        self.assertEqual(metadata["source_commit"], self.manifest["source_commit"])
        self.assertEqual(metadata["working_tree_dirty"], self.manifest["source_dirty"])
        for name in ("version", "architectures", "signing", "signing_certificate_sha256", "flutter", "dart", "min_sdk", "compile_sdk", "target_sdk", "bytes"):
            self.assertEqual(metadata[name], self.manifest[name])
        self.assertEqual(metadata["artifacts"], [dict(artifact, file=packaged_name)
                                               for artifact, packaged_name in zip(self.artifacts, self.packaged_names)])
        self.assertEqual(metadata["apk_sha256"], self.manifest["sha256"])
        self.assertEqual(metadata["manifest_sha256"], hashlib.sha256((self.release / "manifest.json").read_bytes()).hexdigest())
        verified = set()
        for line in (self.output / "android-sha256.txt").read_text().splitlines():
            expected, name = line.split("  ", 1)
            self.assertEqual(expected, hashlib.sha256((self.output / name).read_bytes()).hexdigest())
            verified.add(name)
        self.assertEqual(verified, {*self.packaged_names, "android-source.json"})

    def test_refuses_tampered_apk_before_creating_output(self):
        for artifact in self.artifacts:
            with self.subTest(architecture=artifact["architecture"]):
                apk = self.release / artifact["file"]
                original = apk.read_bytes()
                apk.write_bytes(b"tampered APK")
                result = self.package()
                apk.write_bytes(original)
                self.assertNotEqual(result.returncode, 0)
                self.assertIn("APK manifest mismatch", result.stderr)
                self.assertFalse(self.output.exists())

    def test_refuses_missing_duplicate_or_mislabeled_architecture_metadata(self):
        original = json.loads(json.dumps(self.manifest))
        variants = (
            self.artifacts[:-1],
            [self.artifacts[0], self.artifacts[0], self.artifacts[2]],
            [dict(self.artifacts[0], architecture="x86_64"), *self.artifacts[1:]],
        )
        for artifacts in variants:
            with self.subTest(artifacts=artifacts):
                self.manifest = dict(original, artifacts=artifacts)
                self.write_manifest()
                result = self.package()
                self.assertNotEqual(result.returncode, 0)
                self.assertIn("APK manifest mismatch", result.stderr)
                self.assertFalse(self.output.exists())

    def test_refuses_mismatched_source_status_and_version(self):
        original = self.manifest.copy()
        for name, value in (("source_commit", "0" * 40), ("source_dirty", not original["source_dirty"]), ("version", "9.9.9+99")):
            with self.subTest(name=name):
                self.manifest = dict(original, **{name: value})
                self.write_manifest()
                result = self.package()
                self.assertNotEqual(result.returncode, 0)
                self.assertIn("current source revision, working tree and version", result.stderr)
                self.assertFalse(self.output.exists())

    def test_refuses_unknown_signing_or_mismatched_certificate(self):
        original = self.manifest.copy()
        for name, value in (("signing", "debug keystore"), ("signing_certificate_sha256", None),
                            ("signing_certificate_sha256", "b" * 64)):
            with self.subTest(name=name, value=value):
                self.manifest = dict(original, **{name: value})
                self.write_manifest()
                result = self.package()
                self.assertNotEqual(result.returncode, 0)
                self.assertIn("APK manifest mismatch", result.stderr)
                self.assertFalse(self.output.exists())

    def test_refuses_missing_build_files(self):
        for name in ("tug-android.apk", "tug-android-arm32.apk", "tug-android-x86_64.apk", "manifest.json"):
            with self.subTest(name=name):
                path = self.release / name
                contents = path.read_bytes()
                path.unlink()
                result = self.package()
                path.write_bytes(contents)
                self.assertNotEqual(result.returncode, 0)
                self.assertIn("Incomplete Release", result.stderr)
                self.assertFalse(self.output.exists())

    def test_refuses_existing_output_without_overwriting(self):
        self.output.mkdir()
        marker = self.output / "keep.txt"
        marker.write_text("preserve me")
        result = self.package()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("Refusing to overwrite package directory", result.stderr)
        self.assertEqual(marker.read_text(), "preserve me")
        self.assertEqual(list(self.output.iterdir()), [marker])


if __name__ == "__main__":
    unittest.main()
