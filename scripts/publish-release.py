import argparse
import hashlib
import json
import os
import re
from pathlib import Path
import subprocess
from urllib.parse import quote

from component_version import ASSET_TEMPLATES, component_assets, component_version
from release_policy import ROLLING_RELEASES, github_json, may_publish, published_release


def github_command(*arguments):
    subprocess.run(["gh", *arguments], check=True)


def check_release(release):
    if release and (release.get("immutable", False) or not release["prerelease"]):
        raise SystemExit("Existing component pre-release has incompatible type or immutability")


def pending_release_id(repository, tag):
    owner, name = repository.split("/", 1)
    query = ("query($owner: String!, $name: String!, $tagName: String!) { "
             "repository(owner: $owner, name: $name) { "
             "release(tagName: $tagName) { databaseId tagName } } }")
    result = subprocess.run([
        "gh", "api", "graphql", "-f", f"query={query}",
        "-f", f"owner={owner}", "-f", f"name={name}", "-f", f"tagName={tag}",
    ], check=True, capture_output=True, text=True)
    response = json.loads(result.stdout)
    if response.get("errors"):
        raise SystemExit("GraphQL pre-release lookup failed; no draft created")
    repository_data = response["data"]["repository"]
    if repository_data is None:
        raise SystemExit("Repository is inaccessible to GraphQL release lookup; no draft created")
    release = repository_data["release"]
    if release is None:
        return None
    if release["tagName"] != tag or not isinstance(release["databaseId"], int) or release["databaseId"] <= 0:
        raise SystemExit("GraphQL pre-release identity is invalid; no draft created")
    return release["databaseId"]


def find_release(repository, tag, missing_ok=False):
    matches = []
    page = 1
    while True:
        releases = github_json(f"repos/{repository}/releases?per_page=100&page={page}")
        matches.extend(release for release in releases if release["tag_name"] == tag)
        if len(matches) > 1:
            raise SystemExit("Multiple pre-releases have the same pending tag; refusing to choose or create another draft")
        if len(releases) < 100:
            break
        page += 1
    if matches:
        release_id = matches[0]["id"]
    else:
        print("Component pre-release absent from REST list; checking pending tag with GraphQL")
        release_id = pending_release_id(repository, tag)
    if release_id is None:
        if missing_ok:
            return None
        raise SystemExit("Component pre-release was not found after creation; no duplicate draft created")
    release = github_json(f"repos/{repository}/releases/{release_id}")
    if release["tag_name"] != tag:
        raise SystemExit("Component pre-release tag changed during publication")
    return release


def upload_asset(release, directory, name):
    upload_url = release["upload_url"].split("{", 1)[0]
    endpoint = f"{upload_url}?name={quote(name, safe='')}"
    github_command("api", "--method", "POST", endpoint, "--header", "Content-Type: application/octet-stream",
                   "--input", str(directory / name))


def finish_release(repository, tag, assets):
    release = find_release(repository, tag)
    check_release(release)
    names = {asset["name"] for asset in release["assets"]}
    if names != set(assets):
        raise SystemExit("Component pre-release assets do not match the uploaded packages")
    if release["draft"]:
        if not may_publish():
            print("Skip draft publication: source is no longer current main")
            return
        github_command("release", "edit", tag, "--repo", repository, "--draft=false", "--latest=false")


def publish_version(component, directory, assets):
    repository = os.environ["GITHUB_REPOSITORY"]
    for name in assets:
        release = published_release()
        if release is None:
            return
        if release.get("immutable", False):
            raise SystemExit("Published release is immutable; assets cannot be changed. No settings changed.")
        try:
            for asset in release["assets"]:
                if asset["name"] == name:
                    if published_release() is None:
                        return
                    github_command("api", "--method", "DELETE", f"repos/{repository}/releases/assets/{asset['id']}")
            if published_release() is None:
                return
            upload_asset(release, directory, name)
        except subprocess.CalledProcessError:
            if published_release() is None:
                print("Skip remaining assets: release or tag disappeared during upload")
                return
            raise
    print(f"Uploaded {component} packages to the original collection release; metadata preserved")


def publish(component, directory):
    metadata_path = directory / f"{component}-source.json"
    if not metadata_path.is_file():
        raise SystemExit(f"Missing release asset: {metadata_path.name}")
    metadata = json.loads(metadata_path.read_text(encoding="utf-8-sig"))
    version = component_version(component)
    assets = component_assets(component, version)
    build_assets = [*assets, f"{component}-source.json", f"{component}-sha256.txt"]
    repository = os.environ["GITHUB_REPOSITORY"]
    revision = os.environ["GITHUB_SHA"]
    for name in build_assets:
        if not (directory / name).is_file():
            raise SystemExit(f"Missing release asset: {name}")
    if metadata.get("version") != version or metadata["source_commit"] != revision or metadata["working_tree_dirty"]:
        raise SystemExit("Release metadata does not identify a clean workflow source revision and component version")
    verified = set()
    for line in (directory / f"{component}-sha256.txt").read_text().splitlines():
        expected, name = line.split("  ", 1)
        if name not in build_assets or name in verified or hashlib.sha256((directory / name).read_bytes()).hexdigest() != expected:
            raise SystemExit("Release checksum mismatch")
        verified.add(name)
    if verified != set(build_assets) - {f"{component}-sha256.txt"}:
        raise SystemExit("Incomplete release checksums")
    if component == "android":
        certificate = metadata.get("signing_certificate_sha256", "")
        if (metadata.get("signing") not in ("release keystore; certificate verified",
                                           "local Android debug keystore; not production distribution")
                or not isinstance(certificate, str) or not re.fullmatch(r"[0-9a-f]{64}", certificate)
                or len(metadata.get("artifacts", [])) != len(assets)
                or {artifact.get("file") for artifact in metadata["artifacts"]} != set(assets)
                or any(artifact.get("signing_certificate_sha256") != certificate
                       for artifact in metadata["artifacts"])):
            raise SystemExit("Android publication requires verified signing metadata")
    if not may_publish():
        print("Skip release: publication target is no longer eligible")
        return
    if os.environ.get("GITHUB_EVENT_NAME") == "release":
        publish_version(component, directory, assets)
        return
    try:
        policy = github_json(f"repos/{repository}/immutable-releases")
    except subprocess.CalledProcessError as error:
        if not any(status in error.stderr for status in ("(HTTP 403)", "(HTTP 404)")):
            raise
        if os.environ.get("TUG_MUTABLE_RELEASES_CONFIRMED") != "true":
            raise SystemExit("GITHUB_TOKEN cannot read admin-only immutability settings. An admin must verify mutable releases and set repository variable TUG_MUTABLE_RELEASES_CONFIRMED=true. No settings changed.") from error
        print("Admin-only policy unavailable; using explicit repository owner confirmation")
        policy = {"enabled": False}
    if policy["enabled"] or policy.get("enforced_by_owner", False):
        raise SystemExit("Component pre-releases require mutable releases; repository policy is immutable. No settings changed.")
    tag, title = ROLLING_RELEASES[component]
    release = find_release(repository, tag, missing_ok=True)
    check_release(release)
    notes = (f"Rolling {component} build. Component version: {version}.\n\n"
             f"Source commit: {revision}.")
    notes_path = directory / f"{component}-notes.md"
    notes_path.write_text(notes, encoding="utf-8")
    if not may_publish():
        print("Skip release: source is no longer current main")
        return
    if release is None:
        github_command("release", "create", tag, "--repo", repository, "--target", revision,
                       "--title", title, "--notes-file", str(notes_path), "--latest=false", "--prerelease", "--draft")
        release = find_release(repository, tag)
        check_release(release)
    for asset in release["assets"]:
        if not may_publish():
            print("Skip asset removal: source is no longer current main")
            return
        github_command("api", "--method", "DELETE", f"repos/{repository}/releases/assets/{asset['id']}")
    for name in assets:
        if not may_publish():
            print("Skip asset upload: source is no longer current main")
            return
        upload_asset(release, directory, name)
    if not may_publish():
        print("Skip release metadata update: source is no longer current main")
        return
    github_command("release", "edit", tag, "--repo", repository, "--title", title,
                   "--notes-file", str(notes_path), "--latest=false", "--prerelease")
    finish_release(repository, tag, assets)


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("component", choices=ASSET_TEMPLATES)
    parser.add_argument("directory", type=Path)
    arguments = parser.parse_args()
    publish(arguments.component, arguments.directory)
