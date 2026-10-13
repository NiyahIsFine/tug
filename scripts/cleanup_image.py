import argparse
from collections import deque
import json
import os
import re
import subprocess


IMAGE = "ghcr.io/niyahisfine/tug-server"
PACKAGE_ENDPOINT = "users/niyahisfine/packages/container/tug-server/versions"
INDEX_TYPES = {"application/vnd.oci.image.index.v1+json", "application/vnd.docker.distribution.manifest.list.v2+json"}
MANIFEST_TYPES = {"application/vnd.oci.image.manifest.v1+json", "application/vnd.docker.distribution.manifest.v2+json"}


class CleanupError(Exception):
    pass


def validate_digest(digest):
    if not isinstance(digest, str) or not re.fullmatch(r"sha256:[0-9a-f]{64}", digest):
        raise CleanupError("Invalid manifest digest; refusing to delete package versions")
    return digest


def github_json(endpoint):
    result = subprocess.run(["gh", "api", "--method", "GET", endpoint],
                            check=True, capture_output=True, text=True, timeout=60)
    return json.loads(result.stdout)


def validate_version(version):
    if not isinstance(version, dict) or type(version.get("id")) is not int or version["id"] <= 0:
        raise CleanupError("Invalid container package version; refusing to delete package versions")
    metadata = version.get("metadata")
    if not isinstance(metadata, dict) or metadata.get("package_type") != "container":
        raise CleanupError("Invalid container package metadata; refusing to delete package versions")
    digest = validate_digest(version.get("name"))
    container = metadata.get("container")
    if not isinstance(container, dict):
        raise CleanupError("Invalid container package metadata; refusing to delete package versions")
    tags = container.get("tags")
    if not isinstance(tags, list) or any(not isinstance(tag, str) or not tag for tag in tags):
        raise CleanupError("Invalid package tags; refusing to delete package versions")
    return digest


def list_versions():
    versions = {}
    identities = set()
    page = 1
    while True:
        batch = github_json(f"{PACKAGE_ENDPOINT}?per_page=100&page={page}&state=active")
        if not isinstance(batch, list):
            raise CleanupError("Invalid package version list; refusing to delete package versions")
        for version in batch:
            digest = validate_version(version)
            if digest in versions or version["id"] in identities:
                raise CleanupError("Duplicate package version during pagination; retry cleanup after publication settles")
            versions[digest] = version
            identities.add(version["id"])
        if len(batch) < 100:
            return versions
        page += 1


def manifest_references(manifest):
    if not isinstance(manifest, dict) or manifest.get("schemaVersion") != 2:
        raise CleanupError("Invalid image manifest; refusing to delete package versions")
    media_type = manifest.get("mediaType")
    if media_type in INDEX_TYPES:
        descriptors = manifest.get("manifests")
        if not isinstance(descriptors, list):
            raise CleanupError("Invalid image index references; refusing to delete package versions")
    elif media_type in MANIFEST_TYPES:
        if not isinstance(manifest.get("config"), dict) or not isinstance(manifest.get("layers"), list):
            raise CleanupError("Invalid image configuration or layers; refusing to delete package versions")
        descriptors = []
    else:
        raise CleanupError("Unsupported image manifest type; refusing to delete package versions")
    if "subject" in manifest:
        descriptors = [*descriptors, manifest["subject"]]
    references = set()
    for descriptor in descriptors:
        if not isinstance(descriptor, dict):
            raise CleanupError("Invalid image descriptor; refusing to delete package versions")
        references.add(validate_digest(descriptor.get("digest")))
    return references


def inspect_manifest(image, digest):
    result = subprocess.run(["docker", "buildx", "imagetools", "inspect", f"{image}@{digest}", "--raw"],
                            check=True, capture_output=True, text=True, timeout=60)
    return json.loads(result.stdout)


def build_reference_graph(image, versions):
    references = {}
    referrers = {digest: set() for digest in versions}
    pending = deque(versions)
    scheduled = set(versions)
    while pending:
        digest = pending.popleft()
        children = manifest_references(inspect_manifest(image, digest))
        references[digest] = children
        for child in children:
            referrers.setdefault(child, set()).add(digest)
            if child not in scheduled:
                scheduled.add(child)
                pending.append(child)
        referrers.setdefault(digest, set())
    return references, referrers


def deletion_plan(versions, references, referrers):
    counts = {digest: len(parents) for digest, parents in referrers.items()}
    eligible = {digest for digest, version in versions.items() if not version["metadata"]["container"]["tags"]}
    pending = deque(digest for digest in counts if digest in eligible and counts[digest] == 0)
    plan = []
    while pending:
        digest = pending.popleft()
        plan.append(digest)
        for child in references[digest]:
            counts[child] -= 1
            if counts[child] == 0 and child in eligible:
                pending.append(child)
    return plan


def snapshot(versions):
    return {digest: (version["id"], tuple(sorted(version["metadata"]["container"]["tags"])))
            for digest, version in versions.items()}


def cleanup(image, execute=False):
    if image != IMAGE:
        raise CleanupError(f"Cleanup is restricted to {IMAGE}; no other package may be deleted")
    versions = list_versions()
    references, referrers = build_reference_graph(image, versions)
    plan = deletion_plan(versions, references, referrers)
    print(f"Cleanup plan for {image}: {len(plan)} untagged versions removable, {len(versions) - len(plan)} retained")
    for digest in plan:
        print(f"{'Planned deletion of' if execute else 'Would delete'} package version {versions[digest]['id']}: {digest}")
    if not execute or not plan:
        return len(plan)
    if snapshot(list_versions()) != snapshot(versions):
        raise CleanupError("Package versions or tags changed during planning; no versions deleted")
    deleted = 0
    for digest in plan:
        version_id = versions[digest]["id"]
        endpoint = f"{PACKAGE_ENDPOINT}/{version_id}"
        current = github_json(endpoint)
        current_digest = validate_version(current)
        if current["id"] != version_id or current_digest != digest or current["metadata"]["container"]["tags"]:
            raise CleanupError("A deletion candidate changed or acquired a tag; remaining cleanup stopped")
        subprocess.run(["gh", "api", "--method", "DELETE", endpoint],
                       check=True, capture_output=True, text=True, timeout=60)
        deleted += 1
        print(f"Deleted package version {version_id}: {digest}")
    summary_path = os.environ.get("GITHUB_STEP_SUMMARY")
    if summary_path:
        with open(summary_path, "a", encoding="utf-8") as summary:
            summary.write(f"\nCleaned {deleted} untagged, unreferenced versions from `{IMAGE}`.\n")
    return deleted


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description="Plan or execute reference-safe cleanup of the Tug server package.")
    parser.add_argument("image")
    parser.add_argument("--execute", action="store_true")
    arguments = parser.parse_args()
    try:
        cleanup(arguments.image, execute=arguments.execute)
    except (CleanupError, subprocess.CalledProcessError, subprocess.TimeoutExpired, ValueError) as error:
        detail = error.stderr if isinstance(error, subprocess.CalledProcessError) else str(error)
        raise SystemExit("Image cleanup stopped safely: " + str(detail)
                         + ". The workflow repository needs admin access to this package for deletion.") from error
