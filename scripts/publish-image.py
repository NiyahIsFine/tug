import argparse
import json
import os
import subprocess

from release_policy import ROLLING_TAG, image_tag, may_publish


def promote(image, digest):
    result = subprocess.run(["docker", "buildx", "imagetools", "inspect", f"{image}@{digest}", "--raw"],
                            check=True, capture_output=True, text=True)
    manifest = json.loads(result.stdout)
    platforms = {(entry["platform"]["os"], entry["platform"]["architecture"]): entry["digest"]
                 for entry in manifest["manifests"]}
    if not {("linux", "amd64"), ("linux", "arm64")} <= platforms.keys():
        raise SystemExit("Missing required Linux image architectures")
    tag = image_tag()
    if len(tag) + len("-amd64") > 128:
        raise SystemExit("Server version is too long for architecture-specific image tags")
    publications = [(architecture, platforms[("linux", architecture)]) for architecture in ("amd64", "arm64")]
    publications.append(("", digest))
    published_tags = []
    try:
        for architecture, source_digest in publications:
            if not may_publish():
                print("Skip remaining image tags: publication target was deleted, changed or superseded; uploaded images may remain by digest")
                return
            suffix = f"-{architecture}" if architecture else ""
            tags = [f"{image}:{tag}{suffix}"]
            if os.environ.get("GITHUB_EVENT_NAME", "push") != "release":
                tags.append(f"{image}:{ROLLING_TAG}{suffix}")
            arguments = ["docker", "buildx", "imagetools", "create"]
            if architecture:
                arguments.append("--prefer-index=false")
            for target in tags:
                arguments.extend(["--tag", target])
            subprocess.run([*arguments, f"{image}@{source_digest}"], check=True)
            published_tags.extend(tags)
    except subprocess.CalledProcessError:
        if not may_publish():
            print("Skip image publication failure: target disappeared or changed during promotion")
            return
        raise
    with open(os.environ["GITHUB_STEP_SUMMARY"], "a", encoding="utf-8") as summary:
        summary.write("Published image tags: " + ", ".join(f"`{target}`" for target in published_tags)
                      + f"\nMulti-platform digest: `{image}@{digest}`\n")
    return True


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("image")
    parser.add_argument("digest")
    arguments = parser.parse_args()
    if promote(arguments.image, arguments.digest):
        with open(os.environ["GITHUB_OUTPUT"], "a", encoding="utf-8") as output:
            output.write("published=true\n")
