import os
from pathlib import Path
import subprocess
import sys
import unittest
from unittest.mock import patch


SCRIPTS = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(SCRIPTS))
import cleanup_image as CLEANUP


def digest(version_id):
    return f"sha256:{version_id:064x}"


def package_version(version_id, *tags):
    return dict(id=version_id, name=digest(version_id),
                metadata=dict(package_type="container", container=dict(tags=list(tags))))


def image_index(*children):
    return dict(schemaVersion=2, mediaType="application/vnd.oci.image.index.v1+json",
                manifests=[dict(digest=child) for child in children])


def image_manifest():
    return dict(schemaVersion=2, mediaType="application/vnd.oci.image.manifest.v1+json",
                config=dict(digest=digest(900)), layers=[dict(digest=digest(901))])


def reference_graph(versions, edges):
    references = {version_digest: set() for version_digest in versions}
    references.update({digest(parent): {digest(child) for child in children} for parent, children in edges.items()})
    referrers = {version_digest: set() for version_digest in references}
    for parent, children in references.items():
        for child in children:
            referrers.setdefault(child, set()).add(parent)
    return references, referrers


class ImageCleanupGraphTests(unittest.TestCase):
    def test_nested_images_are_removed_in_one_parent_first_pass(self):
        versions = {digest(version_id): package_version(version_id) for version_id in (4, 1, 2, 3)}
        references, referrers = reference_graph(versions, {3: [1, 2], 2: [4]})
        plan = CLEANUP.deletion_plan(versions, references, referrers)
        self.assertEqual(set(plan), set(versions))
        self.assertLess(plan.index(digest(3)), plan.index(digest(1)))
        self.assertLess(plan.index(digest(3)), plan.index(digest(2)))
        self.assertLess(plan.index(digest(2)), plan.index(digest(4)))

    def test_shared_children_and_nested_dependencies_of_tagged_image_are_retained(self):
        versions = {digest(version_id): package_version(version_id) for version_id in range(1, 5)}
        versions[digest(5)] = package_version(5, "1.0.0")
        references, referrers = reference_graph(versions, {3: [1, 2], 5: [2], 2: [4]})
        self.assertEqual(CLEANUP.deletion_plan(versions, references, referrers), [digest(3), digest(1)])

    def test_tagged_child_is_retained_but_untagged_parent_can_be_deleted(self):
        versions = {digest(version_id): package_version(version_id) for version_id in range(1, 4)}
        versions[digest(1)] = package_version(1, "1.0.0-amd64")
        references, referrers = reference_graph(versions, {3: [1, 2]})
        self.assertEqual(CLEANUP.deletion_plan(versions, references, referrers), [digest(3), digest(2)])

    def test_cycles_and_their_dependencies_are_conservatively_retained(self):
        versions = {digest(version_id): package_version(version_id) for version_id in range(1, 5)}
        references, referrers = reference_graph(versions, {1: [2], 2: [1, 3]})
        self.assertEqual(CLEANUP.deletion_plan(versions, references, referrers), [digest(4)])

    def test_reference_from_manifest_missing_from_package_list_blocks_deletion(self):
        versions = {digest(version_id): package_version(version_id) for version_id in (1, 3)}
        references, referrers = reference_graph(versions, {1: [2], 2: [3]})
        self.assertEqual(CLEANUP.deletion_plan(versions, references, referrers), [digest(1)])

    def test_every_manifest_is_inspected_once_including_unlisted_dependencies(self):
        versions = {digest(version_id): package_version(version_id) for version_id in (4, 2)}
        manifests = {digest(4): image_index(digest(2), digest(3)), digest(3): image_index(digest(2)),
                     digest(2): image_index(digest(1)), digest(1): image_manifest()}
        with patch.object(CLEANUP, "inspect_manifest", side_effect=lambda image, manifest_digest: manifests[manifest_digest]) as inspect:
            references, referrers = CLEANUP.build_reference_graph(CLEANUP.IMAGE, versions)
        self.assertEqual(inspect.call_count, len(manifests))
        self.assertEqual({call.args[1] for call in inspect.call_args_list}, set(manifests))
        self.assertEqual(references[digest(2)], {digest(1)})
        self.assertEqual(referrers[digest(2)], {digest(3), digest(4)})

    def test_subject_is_a_reference_but_config_and_layers_are_not(self):
        manifest = image_manifest()
        self.assertEqual(CLEANUP.manifest_references(manifest), set())
        manifest["subject"] = dict(digest=digest(1))
        self.assertEqual(CLEANUP.manifest_references(manifest), {digest(1)})

    def test_unsupported_or_malformed_manifests_abort_planning(self):
        invalid = [None, dict(schemaVersion=1), dict(schemaVersion=2, mediaType="unknown"),
                   dict(schemaVersion=2, mediaType="application/vnd.oci.image.index.v1+json", manifests=None),
                   image_index("sha256:invalid"), image_index(None)]
        for manifest in invalid:
            with self.subTest(manifest=manifest), self.assertRaises(CLEANUP.CleanupError):
                CLEANUP.manifest_references(manifest)

    def test_package_listing_is_paginated(self):
        first_page = [package_version(version_id) for version_id in range(1, 101)]
        with patch.object(CLEANUP, "github_json", side_effect=[first_page, [package_version(101)]]) as read:
            versions = CLEANUP.list_versions()
        self.assertEqual(len(versions), 101)
        self.assertEqual([call.args[0] for call in read.call_args_list],
                         [f"{CLEANUP.PACKAGE_ENDPOINT}?per_page=100&page={page}&state=active" for page in (1, 2)])

    def test_duplicate_versions_during_pagination_abort_planning(self):
        first_page = [package_version(version_id) for version_id in range(1, 101)]
        with patch.object(CLEANUP, "github_json", side_effect=[first_page, [package_version(1)]]):
            with self.assertRaisesRegex(CLEANUP.CleanupError, "Duplicate"):
                CLEANUP.list_versions()

    def test_malformed_package_metadata_is_rejected(self):
        invalid = [None, dict(id=True, name=digest(1)), dict(id=1, name=digest(1), metadata=None),
                   dict(id=1, name=digest(1), metadata=dict(package_type="container", container=None)),
                   package_version(1, ""), dict(id=1, name="not-a-digest", metadata=package_version(1)["metadata"])]
        for version in invalid:
            with self.subTest(version=version), self.assertRaises(CLEANUP.CleanupError):
                CLEANUP.validate_version(version)


class ImageCleanupExecutionTests(unittest.TestCase):
    def setUp(self):
        self.versions = {digest(version_id): package_version(version_id) for version_id in range(1, 5)}
        self.graph = reference_graph(self.versions, {3: [1, 2], 2: [4]})
        self.addCleanup(patch.stopall)
        patch.dict(os.environ, clear=True).start()
        self.list_versions = patch.object(CLEANUP, "list_versions", return_value=self.versions).start()
        self.build_graph = patch.object(CLEANUP, "build_reference_graph", return_value=self.graph).start()
        self.read = patch.object(CLEANUP, "github_json",
                                 side_effect=lambda endpoint: package_version(int(endpoint.rsplit("/", 1)[1]))).start()
        self.command = patch.object(CLEANUP.subprocess, "run").start()
        patch("builtins.print").start()

    def test_cleanup_refuses_any_other_package_before_reading(self):
        with self.assertRaisesRegex(CLEANUP.CleanupError, "restricted"):
            CLEANUP.cleanup("ghcr.io/niyahisfine/another-package", execute=True)
        self.list_versions.assert_not_called()
        self.command.assert_not_called()

    def test_dry_run_plans_without_any_deletion(self):
        self.assertEqual(CLEANUP.cleanup(CLEANUP.IMAGE), 4)
        self.list_versions.assert_called_once_with()
        self.read.assert_not_called()
        self.command.assert_not_called()

    def test_empty_package_requires_no_manifest_reads_or_deletions(self):
        self.list_versions.return_value = {}
        self.build_graph.return_value = ({}, {})
        self.assertEqual(CLEANUP.cleanup(CLEANUP.IMAGE, execute=True), 0)
        self.read.assert_not_called()
        self.command.assert_not_called()

    def test_execute_rechecks_candidates_and_deletes_parents_before_children(self):
        self.assertEqual(CLEANUP.cleanup(CLEANUP.IMAGE, execute=True), 4)
        self.assertEqual(self.list_versions.call_count, 2)
        deleted_ids = [int(call.args[0][-1].rsplit("/", 1)[1]) for call in self.command.call_args_list]
        self.assertEqual(set(deleted_ids), {1, 2, 3, 4})
        self.assertEqual(deleted_ids[0], 3)
        self.assertLess(deleted_ids.index(2), deleted_ids.index(4))
        self.assertEqual([call.args[0] for call in self.read.call_args_list],
                         [f"{CLEANUP.PACKAGE_ENDPOINT}/{version_id}" for version_id in deleted_ids])
        for call in self.command.call_args_list:
            self.assertEqual(call.args[0][:4], ["gh", "api", "--method", "DELETE"])
            self.assertTrue(call.kwargs["check"])

    def test_changed_package_snapshot_aborts_before_any_deletion(self):
        changed = {**self.versions, digest(3): package_version(3, "tug-pre-release")}
        self.list_versions.side_effect = [self.versions, changed]
        with self.assertRaisesRegex(CLEANUP.CleanupError, "changed during planning"):
            CLEANUP.cleanup(CLEANUP.IMAGE, execute=True)
        self.read.assert_not_called()
        self.command.assert_not_called()

    def test_candidate_that_gains_a_tag_stops_cleanup(self):
        self.read.side_effect = lambda endpoint: package_version(3, "tug-pre-release")
        with self.assertRaisesRegex(CLEANUP.CleanupError, "acquired a tag"):
            CLEANUP.cleanup(CLEANUP.IMAGE, execute=True)
        self.command.assert_not_called()

    def test_changed_candidate_identity_stops_cleanup(self):
        self.read.side_effect = lambda endpoint: package_version(100)
        with self.assertRaisesRegex(CLEANUP.CleanupError, "candidate changed"):
            CLEANUP.cleanup(CLEANUP.IMAGE, execute=True)
        self.command.assert_not_called()

    def test_failed_parent_deletion_stops_before_deleting_any_children(self):
        self.command.side_effect = subprocess.CalledProcessError(1, ["gh", "api"], stderr="Forbidden")
        with self.assertRaises(subprocess.CalledProcessError):
            CLEANUP.cleanup(CLEANUP.IMAGE, execute=True)
        self.command.assert_called_once()
        self.assertEqual(self.command.call_args.args[0][-1], f"{CLEANUP.PACKAGE_ENDPOINT}/3")
        self.read.assert_called_once()

    def test_manifest_read_failure_aborts_before_any_deletion(self):
        self.build_graph.side_effect = subprocess.CalledProcessError(1, ["docker"], stderr="Unavailable")
        with self.assertRaises(subprocess.CalledProcessError):
            CLEANUP.cleanup(CLEANUP.IMAGE, execute=True)
        self.read.assert_not_called()
        self.command.assert_not_called()

    def test_unsupported_manifest_aborts_before_any_deletion(self):
        self.build_graph.side_effect = CLEANUP.CleanupError("Unsupported image manifest type")
        with self.assertRaisesRegex(CLEANUP.CleanupError, "Unsupported"):
            CLEANUP.cleanup(CLEANUP.IMAGE, execute=True)
        self.read.assert_not_called()
        self.command.assert_not_called()


if __name__ == "__main__":
    unittest.main()
