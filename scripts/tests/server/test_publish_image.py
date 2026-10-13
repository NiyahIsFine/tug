import importlib.util
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch


SCRIPTS = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(SCRIPTS))
SPEC = importlib.util.spec_from_file_location("publish_image", SCRIPTS / "publish-image.py")
IMAGE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(IMAGE)


class ImagePublicationTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.summary = Path(self.temporary.name) / "summary.txt"
        self.manifest = dict(manifests=[dict(digest=f"sha256:{architecture}", platform=dict(os="linux", architecture=architecture))
                                        for architecture in ("amd64", "arm64")])
        self.result = subprocess.CompletedProcess(["docker"], 0, stdout=json.dumps(self.manifest))

    def test_server_version_is_promoted_and_main_also_updates_rolling_alias(self):
        tag = "1.2.3"
        for event in ("release", "push", "workflow_dispatch"):
            with self.subTest(event=event), patch.dict(os.environ, GITHUB_STEP_SUMMARY=str(self.summary), GITHUB_EVENT_NAME=event):
                with patch.object(IMAGE, "image_tag", return_value=tag), patch.object(IMAGE, "may_publish", return_value=True):
                    with patch.object(IMAGE.subprocess, "run", return_value=self.result) as command:
                        self.assertTrue(IMAGE.promote("ghcr.io/owner/server", "sha256:abc"))
                expected = []
                for architecture in ("amd64", "arm64", ""):
                    suffix = f"-{architecture}" if architecture else ""
                    arguments = ["docker", "buildx", "imagetools", "create"]
                    if architecture:
                        arguments.append("--prefer-index=false")
                    arguments.extend(["--tag", f"ghcr.io/owner/server:{tag}{suffix}"])
                    if event != "release":
                        arguments.extend(["--tag", f"ghcr.io/owner/server:tug-pre-release{suffix}"])
                    arguments.append(f"ghcr.io/owner/server@sha256:{architecture or 'abc'}")
                    expected.append(arguments)
                self.assertEqual([call.args[0] for call in command.call_args_list[1:]], expected)
                self.assertEqual(command.call_count, 4)

    def test_attestation_manifests_are_not_given_architecture_tags(self):
        self.manifest["manifests"].append(dict(digest="sha256:proof", platform=dict(os="unknown", architecture="unknown")))
        self.result.stdout = json.dumps(self.manifest)
        with patch.dict(os.environ, GITHUB_STEP_SUMMARY=str(self.summary), GITHUB_EVENT_NAME="push"):
            with patch.object(IMAGE, "image_tag", return_value="1.2.3"), patch.object(IMAGE, "may_publish", return_value=True):
                with patch.object(IMAGE.subprocess, "run", return_value=self.result) as command:
                    IMAGE.promote("ghcr.io/owner/server", "sha256:abc")
        self.assertEqual(command.call_count, 4)
        self.assertFalse(any("ghcr.io/owner/server@sha256:proof" in call.args[0] for call in command.call_args_list))

    def test_superseded_target_stops_remaining_architecture_and_index_tags(self):
        with patch.object(IMAGE, "image_tag", return_value="1.2.3"), patch.object(IMAGE, "may_publish", side_effect=[True, False]):
            with patch.object(IMAGE.subprocess, "run", return_value=self.result) as command:
                self.assertIsNone(IMAGE.promote("ghcr.io/owner/server", "sha256:abc"))
        self.assertEqual(command.call_count, 2)
        self.assertEqual(command.call_args_list[-1].args[0][-1], "ghcr.io/owner/server@sha256:amd64")
        self.assertFalse(self.summary.exists())

    def test_deleted_or_superseded_target_does_not_promote(self):
        with patch.object(IMAGE, "image_tag", return_value="v0.1.3"), patch.object(IMAGE, "may_publish", return_value=False):
            with patch.object(IMAGE.subprocess, "run", return_value=self.result) as command:
                IMAGE.promote("ghcr.io/owner/server", "sha256:abc")
        self.assertEqual(command.call_count, 1)
        self.assertFalse(self.summary.exists())

    def test_missing_architecture_prevents_promotion(self):
        self.manifest["manifests"].pop()
        result = subprocess.CompletedProcess(["docker"], 0, stdout=json.dumps(self.manifest))
        with patch.object(IMAGE.subprocess, "run", return_value=result) as command:
            with self.assertRaisesRegex(SystemExit, "architectures"):
                IMAGE.promote("ghcr.io/owner/server", "sha256:abc")
        self.assertEqual(command.call_count, 1)

    def test_promotion_failure_after_target_deletion_is_skipped(self):
        failure = subprocess.CalledProcessError(1, ["docker"])
        with patch.object(IMAGE, "image_tag", return_value="v0.1.3"), patch.object(IMAGE, "may_publish", side_effect=[True, False]):
            with patch.object(IMAGE.subprocess, "run", side_effect=[self.result, failure]):
                IMAGE.promote("ghcr.io/owner/server", "sha256:abc")

    def test_promotion_failure_for_existing_target_is_an_error(self):
        failure = subprocess.CalledProcessError(1, ["docker"])
        with patch.object(IMAGE, "image_tag", return_value="v0.1.3"), patch.object(IMAGE, "may_publish", return_value=True):
            with patch.object(IMAGE.subprocess, "run", side_effect=[self.result, failure]):
                with self.assertRaises(subprocess.CalledProcessError):
                    IMAGE.promote("ghcr.io/owner/server", "sha256:abc")


if __name__ == "__main__":
    unittest.main()
