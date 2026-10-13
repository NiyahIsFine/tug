import argparse
import os
from pathlib import Path
import re


ROOT = Path(__file__).resolve().parent.parent
VERSION_PATTERN = r"(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)(?:-[0-9A-Za-z]+(?:[.-][0-9A-Za-z]+)*)?(?:\+[0-9]+)?"
ASSET_TEMPLATES = {
    "server": ["tug-server-linux-amd64-{version}.tar.gz", "tug-server-linux-arm64-{version}.tar.gz"],
    "windows": ["tug-windows-x64-{version}.zip"],
    "android": ["tug-android-arm64-{version}.apk", "tug-android-arm32-{version}.apk",
                "tug-android-x86_64-{version}.apk"],
}


def validate_version(version):
    if not isinstance(version, str) or not re.fullmatch(VERSION_PATTERN, version, flags=re.ASCII):
        raise SystemExit("Invalid component version: expected major.minor.patch with optional pre-release/build number")
    return version


def component_version(component):
    if component == "server":
        version = (ROOT / "server" / "VERSION").read_text(encoding="utf-8-sig").strip()
    else:
        source = (ROOT / "client" / component / "pubspec.yaml").read_text(encoding="utf-8-sig")
        matches = re.findall(r"^version:\s*([^\r\n]+)", source, flags=re.MULTILINE)
        if len(matches) != 1:
            raise SystemExit("Expected one version in client pubspec.yaml")
        version = matches[0].strip()
    validate_version(version)
    if component == "server" and ("+" in version or len(version) > 128):
        raise SystemExit("Server version must also be a valid Docker tag: no build-number suffix and at most 128 characters")
    return version


def component_assets(component, version):
    validate_version(version)
    return [template.format(version=version) for template in ASSET_TEMPLATES[component]]


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description="Read the version of one Tug component.")
    parser.add_argument("component", choices=ASSET_TEMPLATES)
    parser.add_argument("--github-env", action="store_true")
    parser.add_argument("--assets", action="store_true")
    arguments = parser.parse_args()
    version = component_version(arguments.component)
    print("\n".join(component_assets(arguments.component, version)) if arguments.assets else version)
    if arguments.github_env:
        with open(os.environ["GITHUB_ENV"], "a", encoding="utf-8") as output:
            output.write(f"VERSION={version}\n")
