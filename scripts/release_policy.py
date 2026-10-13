import json
import os
from pathlib import Path
import subprocess
import sys
from urllib.parse import quote

from component_version import component_version


ROLLING_TAG = "tug-pre-release"
ROLLING_RELEASES = {
    "server": ("tug-server-linux-pre-release", "tug server-linux pre-release"),
    "windows": ("tug-windows-pre-release", "tug windows pre-release"),
    "android": ("tug-android-pre-release", "tug android pre-release"),
}
ROLLING_TAGS = {ROLLING_TAG} | {release[0] for release in ROLLING_RELEASES.values()}


def github_json(path, missing_ok=False):
    try:
        result = subprocess.run(["gh", "api", path], check=True, capture_output=True, text=True)
    except subprocess.CalledProcessError as error:
        if missing_ok and "(HTTP 404)" in error.stderr:
            return None
        raise
    return json.loads(result.stdout)


def release_event():
    if os.environ.get("GITHUB_EVENT_NAME") != "release":
        return None
    event = json.loads(Path(os.environ["GITHUB_EVENT_PATH"]).read_text(encoding="utf-8"))
    if event["action"] != "published":
        return None
    release = event["release"]
    if not isinstance(release["id"], int) or release["id"] <= 0 or not isinstance(release["tag_name"], str):
        raise SystemExit("Invalid release event identity")
    return release


def image_tag():
    return component_version("server")


def published_release():
    event = release_event()
    if event is None or event["tag_name"] in ROLLING_TAGS:
        return None
    repository = os.environ["GITHUB_REPOSITORY"]
    release = github_json(f"repos/{repository}/releases/{event['id']}", missing_ok=True)
    if release is None:
        print("Skip publication: original release was deleted")
        return None
    if release["id"] != event["id"] or release["tag_name"] != event["tag_name"] or release["draft"]:
        print("Skip publication: original release identity or publication state changed")
        return None
    tag = quote(event["tag_name"], safe="")
    reference = github_json(f"repos/{repository}/git/ref/tags/{tag}", missing_ok=True)
    if reference is None:
        print("Skip publication: release tag was deleted")
        return None
    target = reference["object"]
    visited = set()
    while target["type"] == "tag":
        if target["sha"] in visited or len(visited) >= 16:
            raise SystemExit("Release tag cannot be resolved to a commit")
        visited.add(target["sha"])
        annotated = github_json(f"repos/{repository}/git/tags/{target['sha']}")
        target = annotated["object"]
    if target["type"] != "commit" or target["sha"] != os.environ["GITHUB_SHA"]:
        print("Skip publication: release tag no longer identifies the built source commit")
        return None
    return release


def may_publish():
    if os.environ.get("GITHUB_EVENT_NAME") == "release":
        return published_release() is not None
    if os.environ.get("GITHUB_EVENT_NAME", "push") not in ("push", "workflow_dispatch"):
        return False
    if os.environ.get("GITHUB_REF") != "refs/heads/main":
        return False
    repository = os.environ["GITHUB_REPOSITORY"]
    return github_json(f"repos/{repository}/git/ref/heads/main")["object"]["sha"] == os.environ["GITHUB_SHA"]


if __name__ == "__main__":
    event = release_event()
    target = event["tag_name"] if event else "component pre-release"
    if "--validate" in sys.argv:
        print("Publication target: " + target)
        raise SystemExit(0)
    publish = may_publish()
    print("Publication allowed: " + target if publish else "Build only: target absent, changed, non-main or superseded revision")
    with open(os.environ["GITHUB_OUTPUT"], "a", encoding="utf-8") as output:
        output.write(f"publish={str(publish).lower()}\n")
        output.write(f"image_tag={image_tag()}\n")
