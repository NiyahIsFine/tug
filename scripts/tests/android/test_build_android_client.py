import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest
import zipfile


ROOT = Path(__file__).resolve().parents[3]
POWERSHELL = shutil.which("pwsh")


@unittest.skipUnless(POWERSHELL and os.name == "nt", "Windows PowerShell and batch tool stubs are required")
class AndroidBuildTests(unittest.TestCase):
    def setUp(self):
        (ROOT / ".local").mkdir(exist_ok=True)
        self.temporary = tempfile.TemporaryDirectory(dir=ROOT / ".local")
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        scripts = self.root / "scripts"
        scripts.mkdir()
        for name in ("build-android-client.ps1", "prepare-android-pub-cache.ps1"):
            shutil.copyfile(ROOT / "scripts" / name, scripts / name)
        for name in ("core", "android"):
            project = self.root / "client" / name
            project.mkdir(parents=True)
            (project / "pubspec.yaml").write_text("version: 0.1.0+1\n")
        self.wrapper = self.root / "client/android/android/gradlew.bat"
        self.wrapper.parent.mkdir()
        self.wrapper.write_bytes(b"@echo off\r\njava org.gradle.wrapper.GradleWrapperMain %CMD_LINE_ARGS%\r\n")
        self.wrapper_original = self.wrapper.read_bytes()
        self.sdk = self.root / "sdk"
        (self.sdk / "bin").mkdir(parents=True)
        (self.sdk / "bin/flutter.bat").write_text(
            '@echo off\n>>"%TUG_BUILD_LOG%" echo flutter %*\n'
            'if "%1"=="build" (\n'
            '  findstr /C:"GradleWrapperMain --profile" "%TUG_WRAPPER%" >nul\n'
            '  if errorlevel 1 exit /b 8\n'
            '  if "%TUG_FAIL_BUILD%"=="1" exit /b 7\n'
            '  copy /Y "%TUG_FIXTURES%\\*.apk" "%TUG_APK_OUTPUT%\\" >nul\n'
            ')\n'
            'if "%1"=="--version" echo {"flutterVersion":"3.47.7","dartSdkVersion":"3.13.5"}\n'
            'exit /b 0\n'
        )
        (self.sdk / "bin/dart.bat").write_text('@echo off\n>>"%TUG_BUILD_LOG%" echo dart %*\nexit /b 0\n')
        self.android_sdk = self.root / "android-sdk"
        for name in ("platforms/android-36/android.jar", "ndk/28.2.13676358/source.properties", "licenses/android-sdk-license"):
            path = self.android_sdk / name
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text("fixture")
        signer = self.android_sdk / "build-tools/36.0.0/apksigner.bat"
        signer.parent.mkdir(parents=True)
        signer.write_text(
            '@echo off\n>>"%TUG_BUILD_LOG%" echo signer %*\necho Verifies\n'
            'if "%TUG_MISMATCH_CERT%"=="1" if "%~nx4"=="app-armeabi-v7a-release.apk" (\n'
            '  echo Signer #1 certificate SHA-256 digest: ' + "b" * 64 + '\n'
            '  exit /b 0\n)\n'
            'echo Signer #1 certificate SHA-256 digest: %TUG_SIGNER_CERT%\nexit /b 0\n'
        )
        self.fixtures = self.root / "fixtures"
        self.fixtures.mkdir()
        self.write_apks()
        output = self.root / "client/android/build/app/outputs/flutter-apk"
        output.mkdir(parents=True)
        subprocess.run(["git", "init", "--quiet", str(self.root)], check=True)
        subprocess.run(["git", "-C", str(self.root), "-c", "user.name=Test", "-c", "user.email=test@example.com",
                        "commit", "--quiet", "--allow-empty", "-m", "fixture"], check=True)
        self.log = self.root / "commands.txt"
        self.certificate = "a" * 64
        self.environment = dict(os.environ, PUB_CACHE=str(self.root / "pub-cache"),
                                TUG_BUILD_LOG=str(self.log), TUG_WRAPPER=str(self.wrapper),
                                TUG_FIXTURES=str(self.fixtures), TUG_APK_OUTPUT=str(output), TUG_FAIL_BUILD="0",
                                TUG_SIGNER_CERT=self.certificate, TUG_MISMATCH_CERT="0")

    def write_apks(self, wrong_abi=False):
        for architecture in ("arm64-v8a", "armeabi-v7a", "x86_64"):
            with zipfile.ZipFile(self.fixtures / f"app-{architecture}-release.apk", "w") as archive:
                actual = "x86_64" if wrong_abi and architecture == "arm64-v8a" else architecture
                archive.writestr(f"lib/{actual}/libflutter.so", b"mock engine")
                archive.writestr(f"lib/{actual}/libapp.so", b"mock application")

    def run_stage(self, stage, profile=False):
        command = [POWERSHELL, "-NoProfile", "-File", str(self.root / "scripts/build-android-client.ps1"),
                   "-FlutterSdk", str(self.sdk), "-AndroidSdk", str(self.android_sdk), "-Stage", stage]
        if profile:
            command.append("-GradleProfile")
        return subprocess.run(command, capture_output=True, text=True, env=self.environment)

    def test_stages_do_not_repeat_dependencies_analysis_or_tests(self):
        expected = {
            "Dependencies": ["dart pub get --enforce-lockfile", "flutter pub get --enforce-lockfile"],
            "Analyze": ["dart analyze", "flutter analyze --no-pub"],
            "Test": ["dart test", "flutter test --no-pub --concurrency=1"],
        }
        for stage, commands in expected.items():
            with self.subTest(stage=stage):
                self.log.unlink(missing_ok=True)
                result = self.run_stage(stage)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(self.log.read_text().splitlines(), commands)

    def test_build_runs_once_for_all_target_abis(self):
        result = self.run_stage("Build", profile=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        commands = self.log.read_text().splitlines()
        builds = [command for command in commands if command.startswith("flutter build")]
        self.assertEqual(len(builds), 1)
        self.assertIn("--release --no-pub --split-per-abi --target-platform=android-arm,android-arm64,android-x64", builds[0])
        self.assertFalse(any("pub get" in command or "analyze" in command or " test" in command for command in commands))

    def test_profile_build_restores_wrapper(self):
        result = self.run_stage("Build", profile=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.wrapper.read_bytes(), self.wrapper_original)

    def test_build_verifies_signatures_for_every_apk(self):
        result = self.run_stage("Build", profile=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        verifications = [command for command in self.log.read_text().splitlines() if command.startswith("signer verify")]
        self.assertEqual(len(verifications), 3)
        for architecture in ("arm64-v8a", "armeabi-v7a", "x86_64"):
            with self.subTest(architecture=architecture):
                self.assertTrue(any(f"app-{architecture}-release.apk" in command for command in verifications))
        self.assertTrue(all("--print-certs" in command for command in verifications))

    def test_manifest_describes_verified_apks(self):
        result = self.run_stage("Build", profile=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        release = self.root / "dist/android"
        manifest = json.loads((release / "manifest.json").read_text(encoding="utf-8-sig"))
        self.assertEqual({artifact["file"] for artifact in manifest["artifacts"]},
                         {"tug-android.apk", "tug-android-arm32.apk", "tug-android-x86_64.apk"})
        self.assertEqual(len(manifest["artifacts"]), 3)
        for artifact in manifest["artifacts"]:
            self.assertEqual(artifact["bytes"], (release / artifact["file"]).stat().st_size)
            self.assertEqual(artifact["signing_certificate_sha256"], self.certificate)
        self.assertEqual(manifest["signing"], "local Android debug keystore; not production distribution")
        self.assertEqual(manifest["signing_certificate_sha256"], self.certificate)
        self.assertEqual(manifest["sha256"], manifest["artifacts"][0]["sha256"])
        self.assertEqual(len((release / "SHA256SUMS").read_text().splitlines()), 3)

    def test_failed_build_restores_wrapper_and_invalidates_previous_manifest(self):
        release = self.root / "dist/android"
        release.mkdir(parents=True)
        manifest = release / "manifest.json"
        manifest.write_text("stale")
        self.environment["TUG_FAIL_BUILD"] = "1"
        result = self.run_stage("Build", profile=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(self.wrapper.read_bytes(), self.wrapper_original)
        self.assertFalse(manifest.exists())

    def test_clean_checkout_uses_sdk_wrapper_template_for_profile(self):
        template = self.sdk / "bin/cache/artifacts/gradle_wrapper/gradlew.bat"
        template.parent.mkdir(parents=True)
        template.write_bytes(self.wrapper_original)
        self.wrapper.unlink()
        result = self.run_stage("Build", profile=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.wrapper.read_bytes(), self.wrapper_original)

    def test_wrong_abi_fails_before_writing_verified_manifest(self):
        self.write_apks(wrong_abi=True)
        result = self.run_stage("Build", profile=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("APK architecture mismatch", result.stderr)
        self.assertFalse((self.root / "dist/android/manifest.json").exists())
        self.assertEqual(self.wrapper.read_bytes(), self.wrapper_original)

    def test_release_and_validation_work_without_signing_secrets(self):
        for name in ("TUG_ANDROID_KEYSTORE_PATH", "TUG_ANDROID_KEYSTORE_PASSWORD", "TUG_ANDROID_KEY_ALIAS",
                     "TUG_ANDROID_KEY_PASSWORD", "TUG_ANDROID_CERT_SHA256"):
            self.environment.pop(name, None)
        result = self.run_stage("Test")
        self.assertEqual(result.returncode, 0, result.stderr)
        result = self.run_stage("Build", profile=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("flutter build", self.log.read_text())

    def test_invalid_or_mismatched_certificates_fail_without_verified_manifest(self):
        for certificate, mismatch in (("", "0"), ("a" * 63, "0"), (self.certificate, "1")):
            with self.subTest(certificate=certificate):
                self.environment["TUG_SIGNER_CERT"] = certificate
                self.environment["TUG_MISMATCH_CERT"] = mismatch
                result = self.run_stage("Build", profile=True)
                self.assertNotEqual(result.returncode, 0)
                self.assertIn("APK signing certificate", result.stderr)
                self.assertFalse((self.root / "dist/android/manifest.json").exists())
                self.assertEqual(self.wrapper.read_bytes(), self.wrapper_original)


if __name__ == "__main__":
    unittest.main()
