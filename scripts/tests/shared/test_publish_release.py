import copy
import hashlib
import importlib.util
import itertools
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch
from urllib.parse import parse_qs, quote, urlsplit


SCRIPTS = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(SCRIPTS))
SPEC = importlib.util.spec_from_file_location("publish_release", SCRIPTS / "publish-release.py")
PUBLICATION = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(PUBLICATION)
import release_policy


COMPONENT_ASSETS = {component: PUBLICATION.component_assets(component, PUBLICATION.component_version(component))
                    for component in PUBLICATION.ASSET_TEMPLATES}


class ReleaseAPI:
    def __init__(self):
        self.releases = {}
        self.active_tag = release_policy.ROLLING_RELEASES["server"][0]
        self.commands = []
        self.policy = {"enabled": False, "enforced_by_owner": False}
        self.policy_error = None
        self.lookups = []
        self.hide_drafts = False
        self.pending_error = None

    @property
    def release(self):
        return self.releases.get(self.active_tag)

    @release.setter
    def release(self, value):
        if value is None:
            self.releases.pop(self.active_tag, None)
        else:
            self.releases[self.active_tag] = value

    def read(self, path, missing_ok=False):
        self.lookups.append(path)
        if path.endswith("/immutable-releases"):
            if self.policy_error:
                raise self.policy_error
            return self.policy
        if path == "repos/owner/repo/releases?per_page=100&page=1":
            return [copy.deepcopy(release) for release in self.releases.values()
                    if not (self.hide_drafts and release["draft"])]
        for release in self.releases.values():
            if path == f"repos/owner/repo/releases/{release['id']}":
                return copy.deepcopy(release)
        raise AssertionError("Unexpected release lookup: " + path)

    def pending_id(self, repository, tag):
        if repository != "owner/repo":
            raise AssertionError("Unexpected GraphQL repository")
        if self.pending_error:
            raise self.pending_error
        release = self.releases.get(tag)
        return None if release is None else release["id"]

    def command(self, *arguments):
        self.commands.append(arguments)
        if arguments[0] == "api":
            if arguments[2] == "DELETE":
                identity = int(arguments[3].rsplit("/", 1)[1])
                for release in self.releases.values():
                    release["assets"] = [asset for asset in release["assets"] if asset["id"] != identity]
                return
            if arguments[2] == "POST":
                endpoint = urlsplit(arguments[3])
                identity = int(endpoint.path.split("/")[-2])
                name = parse_qs(endpoint.query)["name"][0]
                path = Path(arguments[arguments.index("--input") + 1])
                for release in self.releases.values():
                    if release["id"] == identity:
                        release["assets"].append(dict(id=1000 + len(self.commands), name=name, contents=path.read_bytes()))
                        return
            raise AssertionError("Unexpected asset command")
        if arguments[0] != "release":
            raise AssertionError("Unexpected release command")
        operation, tag = arguments[1:3]
        if operation == "create":
            if tag in self.releases or "--draft" not in arguments or "--prerelease" not in arguments:
                raise AssertionError("First component release must be a unique draft")
            identity = 123 + len(self.releases)
            self.releases[tag] = dict(id=identity, tag_name=tag, draft=True, prerelease=True, immutable=False, assets=[],
                                      upload_url=f"https://uploads.github.com/repos/owner/renamed-repo/releases/{identity}/assets{{?name,label}}")
        elif operation != "edit":
            raise AssertionError("Unexpected release operation: " + operation)
        release = self.releases[tag]
        if "--title" in arguments:
            release["name"] = arguments[arguments.index("--title") + 1]
        if "--notes-file" in arguments:
            release["body"] = Path(arguments[arguments.index("--notes-file") + 1]).read_text()
        if "--draft=false" in arguments:
            if not release["assets"]:
                raise AssertionError("Attempted to publish without packages")
            release["draft"] = False


class ReleasePublicationTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.revision = "a" * 40
        self.environment = patch.dict(os.environ, dict(
            GITHUB_REPOSITORY="owner/repo", GITHUB_SHA=self.revision,
            GITHUB_REF="refs/heads/main", TUG_MUTABLE_RELEASES_CONFIRMED="", GITHUB_EVENT_NAME="push",
        ))
        self.environment.start()
        self.addCleanup(self.environment.stop)
        self.api = ReleaseAPI()
        self.policy = patch.object(PUBLICATION, "may_publish", return_value=True).start()
        patch.object(PUBLICATION, "github_json", side_effect=self.api.read).start()
        patch.object(PUBLICATION, "pending_release_id", side_effect=self.api.pending_id).start()
        patch.object(PUBLICATION, "github_command", side_effect=self.api.command).start()
        self.versions = {component: PUBLICATION.component_version(component) for component in COMPONENT_ASSETS}
        patch.object(PUBLICATION, "component_version", side_effect=self.versions.__getitem__).start()
        self.addCleanup(patch.stopall)
        self.directories = {}
        for component, names in COMPONENT_ASSETS.items():
            directory = self.root / component
            directory.mkdir()
            self.directories[component] = directory
            for name in names:
                (directory / name).write_bytes(b"mock archive bytes")
            self.metadata(component)

    def metadata(self, component, dirty=False, revision=None):
        directory = self.directories[component]
        metadata = dict(version=self.versions[component], source_commit=revision or self.revision, working_tree_dirty=dirty)
        if component == "android":
            metadata.update(signing="local Android debug keystore; not production distribution", signing_certificate_sha256="a" * 64,
                            artifacts=[dict(file=name, signing_certificate_sha256="a" * 64) for name in COMPONENT_ASSETS[component]])
        (directory / f"{component}-source.json").write_text(json.dumps(metadata))
        names = [*COMPONENT_ASSETS[component], f"{component}-source.json"]
        (directory / f"{component}-sha256.txt").write_text("".join(
            hashlib.sha256((directory / name).read_bytes()).hexdigest() + "  " + name + "\n" for name in names
        ))

    def publish(self, component):
        self.api.active_tag = release_policy.ROLLING_RELEASES[component][0]
        PUBLICATION.publish(component, self.directories[component])

    def test_each_component_publishes_immediately_to_its_own_release(self):
        for component, assets in COMPONENT_ASSETS.items():
            with self.subTest(component=component):
                self.publish(component)
                tag, title = release_policy.ROLLING_RELEASES[component]
                release = self.api.releases[tag]
                self.assertFalse(release["draft"])
                self.assertTrue(release["prerelease"])
                self.assertEqual(release["name"], title)
                self.assertEqual({asset["name"] for asset in release["assets"]}, set(assets))
        self.assertEqual(len(self.api.releases), 3)

    def test_created_and_updated_release_notes_keep_build_identity(self):
        for component in COMPONENT_ASSETS:
            with self.subTest(component=component):
                expected = (f"Rolling {component} build. Component version: {self.versions[component]}.\n\n"
                            f"Source commit: {self.revision}.")
                self.publish(component)
                self.assertEqual(self.api.release["body"], expected)
                self.api.release["body"] = "Old release notes"
                self.publish(component)
                self.assertEqual(self.api.release["body"], expected)

    def test_updates_clear_all_own_assets_and_preserve_other_releases(self):
        for component in COMPONENT_ASSETS:
            self.publish(component)
        self.api.active_tag = release_policy.ROLLING_RELEASES["windows"][0]
        self.api.release["assets"].append(dict(id=999, name="old-package.zip"))
        preserved = {tag: copy.deepcopy(release) for tag, release in self.api.releases.items() if tag != self.api.active_tag}
        self.api.commands.clear()
        self.publish("windows")
        self.assertEqual({asset["name"] for asset in self.api.release["assets"]}, set(COMPONENT_ASSETS["windows"]))
        self.assertEqual(preserved, {tag: release for tag, release in self.api.releases.items() if tag != self.api.active_tag})
        deletes = [command for command in self.api.commands if command[:3] == ("api", "--method", "DELETE")]
        self.assertEqual(len(deletes), 2)

    def test_hidden_draft_is_reused_and_finished_for_one_component(self):
        self.publish("server")
        self.api.release["draft"] = True
        self.api.hide_drafts = True
        self.api.commands.clear()
        self.publish("server")
        self.assertFalse(self.api.release["draft"])
        self.assertFalse(any(command[:2] == ("release", "create") for command in self.api.commands))

    def test_missing_or_extra_packages_prevent_draft_publication(self):
        assets = COMPONENT_ASSETS["server"]
        for names in (assets[:-1], [*assets, "unexpected.txt"]):
            with self.subTest(names=names):
                release = dict(draft=True, prerelease=True, immutable=False, assets=[dict(name=name) for name in names])
                with patch.object(PUBLICATION, "find_release", return_value=release):
                    with self.assertRaisesRegex(SystemExit, "assets do not match"):
                        PUBLICATION.finish_release("owner/repo", release_policy.ROLLING_RELEASES["server"][0], assets)
                self.assertEqual(self.api.commands, [])

    def test_mismatched_component_version_does_not_publish(self):
        self.versions["windows"] = "9.9.9"
        with self.assertRaises(SystemExit):
            self.publish("windows")
        self.assertEqual(self.api.commands, [])

    def test_superseded_revision_does_not_write(self):
        self.policy.return_value = False
        self.publish("server")
        self.assertEqual(self.api.commands, [])

    def test_immutable_policy_and_incompatible_release_do_not_write(self):
        for policy in ({"enabled": True}, {"enabled": False, "enforced_by_owner": True}):
            with self.subTest(policy=policy):
                self.api.policy = policy
                with self.assertRaises(SystemExit):
                    self.publish("windows")
                self.assertEqual(self.api.commands, [])
        self.api.policy = {"enabled": False}
        self.api.active_tag = release_policy.ROLLING_RELEASES["server"][0]
        for field in ("immutable", "prerelease"):
            with self.subTest(field=field):
                self.api.release = dict(id=123, tag_name=self.api.active_tag, draft=False, immutable=False, prerelease=True, assets=[])
                self.api.release[field] = field == "immutable"
                with self.assertRaises(SystemExit):
                    self.publish("server")
                self.assertEqual(self.api.commands, [])

    def test_admin_only_policy_requires_explicit_confirmation(self):
        self.api.policy_error = subprocess.CalledProcessError(1, ["gh"], stderr="gh: Forbidden (HTTP 403)")
        with self.assertRaises(SystemExit):
            self.publish("server")
        self.assertEqual(self.api.commands, [])
        with patch.dict(os.environ, TUG_MUTABLE_RELEASES_CONFIRMED="true"):
            self.publish("server")
        self.assertFalse(self.api.release["draft"])

    def test_dirty_or_mismatched_source_does_not_write(self):
        for component, (dirty, revision) in itertools.product(COMPONENT_ASSETS, ((True, self.revision), (False, "b" * 40))):
            with self.subTest(component=component, dirty=dirty, revision=revision):
                self.metadata(component, dirty, revision)
                with self.assertRaises(SystemExit):
                    self.publish(component)
                self.assertEqual(self.api.commands, [])

    def test_invalid_or_incomplete_checksums_do_not_write(self):
        for component, names in COMPONENT_ASSETS.items():
            directory = self.directories[component]
            for contents in (f"bad  {names[0]}\n", ""):
                with self.subTest(component=component, contents=contents):
                    (directory / f"{component}-sha256.txt").write_text(contents)
                    with self.assertRaises(SystemExit):
                        self.publish(component)
                    self.assertEqual(self.api.commands, [])

    def test_missing_package_does_not_write(self):
        for component, names in COMPONENT_ASSETS.items():
            with self.subTest(component=component):
                (self.directories[component] / names[0]).unlink()
                with self.assertRaises(SystemExit):
                    self.publish(component)
                self.assertEqual(self.api.commands, [])

    def test_internal_metadata_and_checksums_are_still_required(self):
        for component, suffix in itertools.product(COMPONENT_ASSETS, ("source.json", "sha256.txt")):
            with self.subTest(component=component, suffix=suffix):
                path = self.directories[component] / f"{component}-{suffix}"
                contents = path.read_bytes()
                path.unlink()
                with self.assertRaisesRegex(SystemExit, "Missing release asset"):
                    self.publish(component)
                path.write_bytes(contents)
                self.assertEqual(self.api.commands, [])

    def test_internal_source_metadata_is_still_checksum_verified(self):
        for component in COMPONENT_ASSETS:
            with self.subTest(component=component):
                path = self.directories[component] / f"{component}-source.json"
                path.write_text(json.dumps(dict(
                    version=self.versions[component], source_commit=self.revision, working_tree_dirty=False, unexpected="tampered",
                )))
                with self.assertRaisesRegex(SystemExit, "checksum mismatch"):
                    self.publish(component)
                self.assertEqual(self.api.commands, [])

    def test_checksum_lists_must_cover_packages_and_internal_metadata_exactly(self):
        for component in COMPONENT_ASSETS:
            directory = self.directories[component]
            path = directory / f"{component}-sha256.txt"
            original = path.read_text()
            metadata_line = original.splitlines(keepends=True)[-1]
            unexpected = directory / "unexpected.txt"
            unexpected.write_bytes(b"unexpected")
            extra_line = hashlib.sha256(unexpected.read_bytes()).hexdigest() + "  unexpected.txt\n"
            for contents in (original.replace(metadata_line, ""), original + metadata_line, original + extra_line):
                with self.subTest(component=component, contents=contents):
                    path.write_text(contents)
                    with self.assertRaises(SystemExit):
                        self.publish(component)
                    self.assertEqual(self.api.commands, [])

    def test_each_android_apk_is_required_and_checksum_verified(self):
        directory = self.directories["android"]
        for name in COMPONENT_ASSETS["android"]:
            with self.subTest(name=name):
                path = directory / name
                contents = path.read_bytes()
                path.unlink()
                with self.assertRaisesRegex(SystemExit, "Missing release asset"):
                    self.publish("android")
                path.write_bytes(b"tampered")
                with self.assertRaisesRegex(SystemExit, "checksum mismatch"):
                    self.publish("android")
                path.write_bytes(contents)
                self.assertEqual(self.api.commands, [])

    def test_android_publication_rejects_unverified_signing_before_api_calls(self):
        directory = self.directories["android"]
        source = directory / "android-source.json"
        original = json.loads(source.read_text())
        for name, value in (("signing", "debug keystore"), ("signing_certificate_sha256", ""),
                            ("artifacts", []), ("signing_certificate_sha256", "b" * 64)):
            with self.subTest(name=name, value=value):
                source.write_text(json.dumps(dict(original, **{name: value})))
                names = [*COMPONENT_ASSETS["android"], "android-source.json"]
                (directory / "android-sha256.txt").write_text("".join(
                    hashlib.sha256((directory / asset).read_bytes()).hexdigest() + "  " + asset + "\n"
                    for asset in names
                ))
                with self.assertRaisesRegex(SystemExit, "verified signing"):
                    self.publish("android")
                self.assertEqual(self.api.commands, [])

    def test_release_list_permission_failure_does_not_create_a_draft(self):
        original = self.api.read

        def inaccessible_list(path, missing_ok=False):
            if "/releases?" in path:
                raise subprocess.CalledProcessError(1, ["gh"], stderr="gh: Forbidden (HTTP 403)")
            return original(path, missing_ok)

        with patch.object(PUBLICATION, "github_json", side_effect=inaccessible_list):
            with self.assertRaises(subprocess.CalledProcessError):
                self.publish("server")
        self.assertEqual(self.api.commands, [])

    def test_graphql_permission_failure_does_not_create_a_draft(self):
        self.api.pending_error = subprocess.CalledProcessError(1, ["gh"], stderr="gh: Forbidden (HTTP 403)")
        with self.assertRaises(subprocess.CalledProcessError):
            self.publish("server")
        self.assertEqual(self.api.commands, [])

    def version_release(self, prerelease=False):
        return dict(id=456, tag_name="v0.1.3", draft=False, prerelease=prerelease, immutable=False,
                    upload_url="https://uploads.github.com/repos/owner/renamed-repo/releases/456/assets{?name,label}",
                    name="User release", body="User notes", assets=[
                        dict(id=789, name="unrelated.txt"), dict(id=790, name="windows-source.json"),
                    ])

    def test_version_upload_uses_original_id_and_preserves_user_metadata(self):
        for component, prerelease in itertools.product(COMPONENT_ASSETS, (False, True)):
            with self.subTest(component=component, prerelease=prerelease):
                release = self.version_release(prerelease)
                if component == "windows":
                    release["assets"][1]["name"] = "server-source.json"
                release["assets"].append(dict(id=791, name=COMPONENT_ASSETS[component][0]))
                release["assets"].append(dict(id=792, name=f"{component}-source.json"))
                release["assets"].append(dict(id=793, name=f"{component}-sha256.txt"))
                original = copy.deepcopy(release)
                with patch.dict(os.environ, GITHUB_EVENT_NAME="release"):
                    with patch.object(PUBLICATION, "published_release", return_value=release):
                        with patch.object(PUBLICATION, "github_command") as command:
                            self.publish(component)
                calls = [call.args for call in command.call_args_list]
                self.assertIn(("api", "--method", "DELETE", "repos/owner/repo/releases/assets/791"), calls)
                self.assertNotIn(("api", "--method", "DELETE", "repos/owner/repo/releases/assets/790"), calls)
                self.assertNotIn(("api", "--method", "DELETE", "repos/owner/repo/releases/assets/792"), calls)
                self.assertNotIn(("api", "--method", "DELETE", "repos/owner/repo/releases/assets/793"), calls)
                uploads = [call for call in calls if call[2] == "POST"]
                self.assertEqual(len(uploads), len(COMPONENT_ASSETS[component]))
                for upload in uploads:
                    self.assertEqual(upload[3], "https://uploads.github.com/repos/owner/renamed-repo/releases/456/assets?name="
                                     + quote(Path(upload[-1]).name, safe=""))
                    self.assertEqual(upload[-2], "--input")
                self.assertEqual({Path(upload[-1]).name for upload in uploads},
                                 set(COMPONENT_ASSETS[component]))
                self.assertEqual(release, original)
                self.assertEqual(self.api.commands, [])
                self.assertEqual(self.api.lookups, [])

    def test_version_upload_encodes_filename_with_or_without_url_template(self):
        name = "tug Windows+x64&test.zip"
        upload_url = "https://uploads.github.com/repos/owner/renamed-repo/releases/456/assets"
        for template in ("{?name,label}", ""):
            with self.subTest(template=template):
                release = self.version_release()
                release["upload_url"] = upload_url + template
                with patch.object(PUBLICATION, "published_release", return_value=release):
                    with patch.object(PUBLICATION, "github_command") as command:
                        PUBLICATION.publish_version("windows", self.root, [name])
                command.assert_called_once_with(
                    "api", "--method", "POST", upload_url + "?name=tug%20Windows%2Bx64%26test.zip",
                    "--header", "Content-Type: application/octet-stream", "--input", str(self.root / name),
                )

    def test_version_upload_errors_are_skipped_only_when_target_is_deleted(self):
        release = self.version_release()
        cases = (
            ("deleted before upload", [release, None], None, False, 0),
            ("deleted after failure", [release, release, None], "gh: Not Found (HTTP 404)", False, 1),
            ("existing after failure", [release, release, release], "gh: Forbidden (HTTP 403)", True, 1),
        )
        for name, lookups, stderr, raises, calls in cases:
            with self.subTest(case=name), patch.dict(os.environ, GITHUB_EVENT_NAME="release"):
                failure = subprocess.CalledProcessError(1, ["gh"], stderr=stderr) if stderr else None
                with patch.object(PUBLICATION, "published_release", side_effect=lookups):
                    with patch.object(PUBLICATION, "github_command", side_effect=failure) as command:
                        if raises:
                            with self.assertRaises(subprocess.CalledProcessError):
                                self.publish("server")
                        else:
                            self.publish("server")
                self.assertEqual(command.call_count, calls)

    def test_immutable_version_release_cannot_be_modified(self):
        release = self.version_release()
        release["immutable"] = True
        with patch.dict(os.environ, GITHUB_EVENT_NAME="release"):
            with patch.object(PUBLICATION, "published_release", return_value=release):
                with patch.object(PUBLICATION, "github_command") as command:
                    with self.assertRaisesRegex(SystemExit, "immutable"):
                        self.publish("server")
        command.assert_not_called()


class ReleaseLookupTests(unittest.TestCase):
    def test_draft_on_second_page_is_read_by_id(self):
        first_page = [dict(id=number, tag_name=f"historical-{number}") for number in range(100)]
        draft = dict(id=123, tag_name="tug-server-linux-pre-release", draft=True, assets=[])
        with patch.object(PUBLICATION, "github_json", side_effect=[first_page, [draft], draft]) as query:
            self.assertEqual(PUBLICATION.find_release("owner/repo", "tug-server-linux-pre-release"), draft)
            self.assertEqual([call.args[0] for call in query.call_args_list], [
                "repos/owner/repo/releases?per_page=100&page=1",
                "repos/owner/repo/releases?per_page=100&page=2",
                "repos/owner/repo/releases/123",
            ])

    def test_duplicate_pending_tags_across_pages_are_rejected(self):
        first_page = [dict(id=123, tag_name="tug-server-linux-pre-release")]
        first_page.extend(dict(id=number, tag_name=f"historical-{number}") for number in range(99))
        with patch.object(PUBLICATION, "github_json", side_effect=[first_page, [dict(id=124, tag_name="tug-server-linux-pre-release")]]):
            with self.assertRaisesRegex(SystemExit, "Multiple pre-releases"):
                PUBLICATION.find_release("owner/repo", "tug-server-linux-pre-release", missing_ok=True)

    def test_missing_after_creation_is_reported_without_creating_another_draft(self):
        with patch.object(PUBLICATION, "github_json", return_value=[]), patch.object(PUBLICATION, "pending_release_id", return_value=None):
            self.assertIsNone(PUBLICATION.find_release("owner/repo", "tug-server-linux-pre-release", missing_ok=True))
            with self.assertRaisesRegex(SystemExit, "not found after creation"):
                PUBLICATION.find_release("owner/repo", "tug-server-linux-pre-release")

    def test_tag_changed_between_list_and_id_lookup_is_rejected(self):
        with patch.object(PUBLICATION, "github_json", side_effect=[
            [dict(id=123, tag_name="tug-server-linux-pre-release")], dict(id=123, tag_name="other"),
        ]):
            with self.assertRaisesRegex(SystemExit, "tag changed"):
                PUBLICATION.find_release("owner/repo", "tug-server-linux-pre-release")

    def test_hidden_draft_is_read_by_graphql_id(self):
        draft = dict(id=123, tag_name="tug-server-linux-pre-release", draft=True, assets=[])
        with patch.object(PUBLICATION, "github_json", side_effect=[[], draft]) as query:
            with patch.object(PUBLICATION, "pending_release_id", return_value=123) as pending:
                self.assertEqual(PUBLICATION.find_release("owner/repo", "tug-server-linux-pre-release"), draft)
        pending.assert_called_once_with("owner/repo", "tug-server-linux-pre-release")
        self.assertEqual([call.args[0] for call in query.call_args_list], [
            "repos/owner/repo/releases?per_page=100&page=1", "repos/owner/repo/releases/123",
        ])

    def test_hidden_draft_id_read_failure_is_not_treated_as_absent(self):
        failure = subprocess.CalledProcessError(1, ["gh"], stderr="gh: Not Found (HTTP 404)")
        with patch.object(PUBLICATION, "github_json", side_effect=[[], failure]):
            with patch.object(PUBLICATION, "pending_release_id", return_value=123):
                with self.assertRaises(subprocess.CalledProcessError):
                    PUBLICATION.find_release("owner/repo", "tug-server-linux-pre-release", missing_ok=True)


class PendingReleaseLookupTests(unittest.TestCase):
    def lookup(self, response):
        result = subprocess.CompletedProcess(["gh"], 0, stdout=json.dumps(response))
        with patch.object(PUBLICATION.subprocess, "run", return_value=result) as command:
            release_id = PUBLICATION.pending_release_id("owner/repo", "tug-server-linux-pre-release")
        arguments = command.call_args.args[0]
        self.assertEqual(arguments[:3], ["gh", "api", "graphql"])
        self.assertIn("owner=owner", arguments)
        self.assertIn("name=repo", arguments)
        self.assertIn("tagName=tug-server-linux-pre-release", arguments)
        self.assertTrue(command.call_args.kwargs["check"])
        return release_id

    def test_exact_pending_tag_returns_database_id(self):
        self.assertEqual(self.lookup({"data": {"repository": {"release": {
            "databaseId": 123, "tagName": "tug-server-linux-pre-release",
        }}}}), 123)

    def test_null_release_is_absent(self):
        self.assertIsNone(self.lookup({"data": {"repository": {"release": None}}}))

    def test_inaccessible_repository_is_not_absent(self):
        with self.assertRaisesRegex(SystemExit, "inaccessible"):
            self.lookup({"data": {"repository": None}})

    def test_graphql_errors_with_partial_data_are_not_absent(self):
        with self.assertRaisesRegex(SystemExit, "lookup failed"):
            self.lookup({"errors": [{"message": "Resource not accessible by integration"}],
                         "data": {"repository": {"release": None}}})

    def test_invalid_release_identity_is_rejected(self):
        for release in (dict(databaseId=123, tagName="other"), dict(databaseId=None, tagName="tug-server-linux-pre-release")):
            with self.subTest(release=release), self.assertRaisesRegex(SystemExit, "identity is invalid"):
                self.lookup({"data": {"repository": {"release": release}}})

    def test_network_or_permission_error_propagates(self):
        failure = subprocess.CalledProcessError(1, ["gh"], stderr="connection failed")
        with patch.object(PUBLICATION.subprocess, "run", side_effect=failure):
            with self.assertRaises(subprocess.CalledProcessError):
                PUBLICATION.pending_release_id("owner/repo", "tug-server-linux-pre-release")


class MainRevisionPolicyTests(unittest.TestCase):
    def test_only_current_main_may_publish(self):
        revision = "a" * 40
        with patch.dict(os.environ, GITHUB_EVENT_NAME="push", GITHUB_REF="refs/heads/main", GITHUB_REPOSITORY="owner/repo", GITHUB_SHA=revision):
            with patch.object(release_policy, "github_json", return_value={"object": {"sha": revision}}):
                self.assertTrue(release_policy.may_publish())
                with patch.dict(os.environ, GITHUB_REF="refs/heads/feature"):
                    self.assertFalse(release_policy.may_publish())
            with patch.object(release_policy, "github_json", return_value={"object": {"sha": "b" * 40}}):
                self.assertFalse(release_policy.may_publish())


if __name__ == "__main__":
    unittest.main()
