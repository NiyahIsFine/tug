import copy
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
import release_policy

class VersionPolicyTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.event_path = Path(self.temporary.name) / "event.json"
        self.revision = "a" * 40
        self.event = dict(action="published", release=dict(id=456, tag_name="v0.1.3", draft=False))
        self.event_path.write_text(json.dumps(self.event))
        self.release = dict(id=456, tag_name="v0.1.3", draft=False, assets=[])
        self.environment = patch.dict(os.environ, GITHUB_EVENT_NAME="release", GITHUB_EVENT_PATH=str(self.event_path),
                                      GITHUB_SHA=self.revision, GITHUB_REF="refs/tags/v0.1.3", GITHUB_REPOSITORY="owner/repo")
        self.environment.start()
        self.addCleanup(self.environment.stop)

    def reference(self, revision=None):
        return dict(object=dict(type="commit", sha=revision or self.revision))

    def update_event(self, **changes):
        self.event["release"].update(changes)
        self.event_path.write_text(json.dumps(self.event))

    def test_published_release_uses_event_id_and_tag_commit_not_main(self):
        with patch.object(release_policy, "github_json", side_effect=[self.release, self.reference()]) as query:
            self.assertTrue(release_policy.may_publish())
        self.assertEqual([call.args[0] for call in query.call_args_list], [
            "repos/owner/repo/releases/456", "repos/owner/repo/git/ref/tags/v0.1.3",
        ])
        with patch.object(release_policy, "component_version", return_value="1.2.3"):
            self.assertEqual(release_policy.image_tag(), "1.2.3")

    def test_annotated_tags_are_resolved_to_commit(self):
        annotated_sha = "b" * 40
        annotated = dict(object=dict(type="tag", sha=annotated_sha))
        with patch.object(release_policy, "github_json", side_effect=[self.release, annotated, self.reference()]) as query:
            self.assertTrue(release_policy.may_publish())
        self.assertEqual(query.call_args_list[-1].args[0], f"repos/owner/repo/git/tags/{annotated_sha}")

    def test_deleted_release_does_not_look_up_another_release_with_same_tag(self):
        with patch.object(release_policy, "github_json", return_value=None) as query:
            self.assertFalse(release_policy.may_publish())
        query.assert_called_once_with("repos/owner/repo/releases/456", missing_ok=True)

    def test_deleted_tag_is_skipped(self):
        with patch.object(release_policy, "github_json", side_effect=[self.release, None]):
            self.assertFalse(release_policy.may_publish())

    def test_moved_tag_is_skipped(self):
        with patch.object(release_policy, "github_json", side_effect=[self.release, self.reference("b" * 40)]):
            self.assertFalse(release_policy.may_publish())

    def test_release_identity_or_published_state_changes_are_skipped(self):
        for changes in (dict(id=457), dict(tag_name="other"), dict(draft=True)):
            with self.subTest(changes=changes):
                release = copy.deepcopy(self.release)
                release.update(changes)
                with patch.object(release_policy, "github_json", return_value=release) as query:
                    self.assertFalse(release_policy.may_publish())
                self.assertEqual(query.call_count, 1)

    def test_permission_errors_are_not_treated_as_deletion(self):
        failure = subprocess.CalledProcessError(1, ["gh"], stderr="gh: Forbidden (HTTP 403)")
        with patch.object(release_policy, "github_json", side_effect=failure):
            with self.assertRaises(subprocess.CalledProcessError):
                release_policy.may_publish()

    def test_rolling_release_event_does_not_publish_recursively(self):
        for tag in release_policy.ROLLING_TAGS:
            with self.subTest(tag=tag):
                self.update_event(tag_name=tag)
                with patch.object(release_policy, "github_json") as query:
                    self.assertFalse(release_policy.may_publish())
                query.assert_not_called()

    def test_tag_only_event_never_publishes(self):
        with patch.dict(os.environ, GITHUB_EVENT_NAME="create"):
            with patch.object(release_policy, "github_json") as query:
                self.assertFalse(release_policy.may_publish())
        query.assert_not_called()

    def test_release_types_other_than_published_never_publish(self):
        for action in ("created", "edited", "deleted", "prereleased"):
            with self.subTest(action=action):
                self.event["action"] = action
                self.event_path.write_text(json.dumps(self.event))
                with patch.object(release_policy, "github_json") as query:
                    self.assertFalse(release_policy.may_publish())
                query.assert_not_called()

    def test_collection_tags_do_not_control_image_version(self):
        for tag in ("release/v1", "-v1", ".v1", "😀", "x" * 129, "latest", "sha-" + "a" * 40):
            with self.subTest(tag=tag):
                self.update_event(tag_name=tag)
                with patch.object(release_policy, "component_version", return_value="1.2.3"):
                    self.assertEqual(release_policy.image_tag(), "1.2.3")

    def test_date_collection_tags_do_not_change_server_image_version(self):
        for tag in ("2026.10.13", "bundle-2026.10.13.1", "release/2026-10-13"):
            with self.subTest(tag=tag):
                self.update_event(tag_name=tag)
                self.release["tag_name"] = tag
                with patch.object(release_policy, "github_json", side_effect=[self.release, self.reference()]):
                    self.assertTrue(release_policy.may_publish())
                with patch.object(release_policy, "component_version", return_value="1.2.3"):
                    self.assertEqual(release_policy.image_tag(), "1.2.3")

    def test_annotation_cycles_are_rejected(self):
        annotated = dict(object=dict(type="tag", sha="b" * 40))
        with patch.object(release_policy, "github_json", side_effect=[self.release, annotated, annotated]):
            with self.assertRaisesRegex(SystemExit, "resolved"):
                release_policy.may_publish()

    def test_missing_ok_applies_only_to_http_404(self):
        for status in ("403", "404", "500"):
            with self.subTest(status=status):
                failure = subprocess.CalledProcessError(1, ["gh"], stderr=f"gh: error (HTTP {status})")
                with patch.object(release_policy.subprocess, "run", side_effect=failure):
                    if status == "404":
                        self.assertIsNone(release_policy.github_json("path", missing_ok=True))
                    else:
                        with self.assertRaises(subprocess.CalledProcessError):
                            release_policy.github_json("path", missing_ok=True)


if __name__ == "__main__":
    unittest.main()
