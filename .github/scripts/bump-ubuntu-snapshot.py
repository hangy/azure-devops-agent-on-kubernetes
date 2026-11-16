#!/usr/bin/env python3
"""Refresh the Ubuntu image digest and snapshot only when their content changes."""

import hashlib
import json
import os
from datetime import datetime, timezone
from pathlib import Path
import re
import sys
from urllib.error import URLError
from urllib.request import Request, urlopen


COMPONENTS = ("main", "restricted", "universe", "multiverse")
ARCHIVES = {"ubuntu": "amd64", "ubuntu-ports": "arm64"}
SNAPSHOT_ARG = re.compile(
    r'^(ARG ARG_UBUNTU_SNAPSHOT=")([0-9]{8}T[0-9]{6}Z)(")', re.MULTILINE
)
DIGEST_ARG = re.compile(
    r'^(ARG ARG_UBUNTU_BASE_IMAGE_DIGEST=")(sha256:[a-f0-9]{64})(")', re.MULTILINE
)


def latest_image_digest() -> str:
    # Fetch the multi-platform index, not a platform-specific image manifest.
    token_url = (
        "https://auth.docker.io/token"
        "?service=registry.docker.io&scope=repository:library/ubuntu:pull"
    )
    with urlopen(token_url, timeout=60) as response:
        token = json.load(response)["token"]
    media_types = (
        "application/vnd.oci.image.index.v1+json",
        "application/vnd.docker.distribution.manifest.list.v2+json",
    )
    request = Request(
        "https://registry-1.docker.io/v2/library/ubuntu/manifests/24.04",
        headers={"Authorization": f"Bearer {token}", "Accept": ", ".join(media_types)},
    )
    with urlopen(request, timeout=60) as response:
        content = response.read()
        advertised_digest = response.headers.get("Docker-Content-Digest")
    index = json.loads(content)
    if index.get("mediaType") not in media_types:
        raise ValueError("Ubuntu registry did not return a multi-platform image index")
    platforms = {
        (manifest.get("platform", {}).get("os"),
         manifest.get("platform", {}).get("architecture"))
        for manifest in index.get("manifests", [])
    }
    if not {("linux", "amd64"), ("linux", "arm64")} <= platforms:
        raise ValueError("Ubuntu image index is missing linux/amd64 or linux/arm64")
    digest = f"sha256:{hashlib.sha256(content).hexdigest()}"
    if advertised_digest != digest:
        raise ValueError("Ubuntu registry manifest digest does not match its content")
    return digest


def package_checksums(release: str, architecture: str) -> dict[str, str]:
    expected = {
        f"{component}/binary-{architecture}/Packages" for component in COMPONENTS
    }
    checksums = {}
    in_sha256 = False
    for line in release.splitlines():
        if line == "SHA256:":
            in_sha256 = True
        elif in_sha256:
            if not line.startswith(" "):
                break
            checksum, size, name = line.split()
            if name in expected:
                if not re.fullmatch(r"[a-fA-F0-9]{64}", checksum) or not size.isdigit():
                    raise ValueError(f"Invalid SHA256 entry for {name}")
                if name in checksums:
                    raise ValueError(f"Duplicate SHA256 entry for {name}")
                checksums[name] = checksum.lower()
    missing = expected - checksums.keys()
    if missing:
        raise ValueError(f"Release is missing SHA256 entries: {sorted(missing)}")
    return checksums


def snapshot_checksums(snapshot: str, codename: str) -> dict[str, dict[str, str]]:
    checksums = {}
    for archive, architecture in ARCHIVES.items():
        for suffix in ("", "-updates", "-security", "-backports"):
            suite = f"{codename}{suffix}"
            url = f"https://snapshot.ubuntu.com/{archive}/{snapshot}/dists/{suite}/Release"
            print(f"Checking {url}", flush=True)
            with urlopen(url, timeout=60) as response:
                release = response.read().decode("utf-8")
            checksums[f"{archive}/{suite}"] = package_checksums(release, architecture)
    return checksums


def bump_snapshot(dockerfile: Path, snapshot: str) -> bool:
    content = dockerfile.read_text()
    matches = list(SNAPSHOT_ARG.finditer(content))
    if len(matches) != 1:
        raise ValueError("Expected exactly one valid ARG_UBUNTU_SNAPSHOT in Dockerfile")
    digest_matches = list(DIGEST_ARG.finditer(content))
    if len(digest_matches) != 1:
        raise ValueError("Expected exactly one valid ARG_UBUNTU_BASE_IMAGE_DIGEST")
    current = matches[0].group(2)
    # Keep these suites in sync with the base image's default Ubuntu apt sources.
    if not re.search(r'^ARG ARG_UBUNTU_BASE_IMAGE_TAG="24\.04"$', content, re.MULTILINE):
        raise ValueError("Update the snapshot check's suites for the new Ubuntu base tag")
    if not re.search(r'^ARG ARG_UBUNTU_BASE_IMAGE="ubuntu"$', content, re.MULTILINE):
        raise ValueError("Update the registry check for the new Ubuntu base image")
    digest = latest_image_digest()
    packages_changed = current != snapshot and (
        snapshot_checksums(current, "noble") != snapshot_checksums(snapshot, "noble")
    )
    updated = content
    if packages_changed:
        updated = SNAPSHOT_ARG.sub(
            lambda match: f"{match[1]}{snapshot}{match[3]}", updated
        )
    updated = DIGEST_ARG.sub(lambda match: f"{match[1]}{digest}{match[3]}", updated)
    if updated == content:
        print("Ubuntu image digest and package indexes are unchanged.")
        return False
    # Do not write either pin until both remote checks succeed.
    dockerfile.write_text(updated)
    print(f"Ubuntu pins refreshed: snapshot={snapshot if packages_changed else current}, "
          f"digest={digest}")
    return True


def main() -> int:
    snapshot = datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%SZ")
    try:
        updated = bump_snapshot(Path("Dockerfile"), snapshot)
        content = Path("Dockerfile").read_text()
        with Path(os.environ["GITHUB_OUTPUT"]).open("a") as output:
            output.write(
                f"updated={str(updated).lower()}\n"
                f"snapshot={SNAPSHOT_ARG.search(content)[2]}\n"
                f"digest={DIGEST_ARG.search(content)[2]}\n"
            )
    except (OSError, URLError, ValueError, KeyError) as error:
        print(f"::error::{error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
