#!/usr/bin/env python3
import json
import os
import re
import subprocess
from pathlib import Path


def parse_version(value):
    if not re.fullmatch(r"(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)", value):
        raise ValueError("Use a stable version such as 0.1.0")
    parts = tuple(map(int, value.split(".")))
    # CFBundleVersion's documented component limits.
    if parts[0] > 9999 or parts[1] > 99 or parts[2] > 99:
        raise ValueError("Version components exceed Apple's bundle-version limits")
    return parts


def main():
    ref = os.environ.get("GITHUB_REF", "")
    version = ref.removeprefix("refs/tags/v") if ref.startswith("refs/tags/v") else os.environ.get("INPUT_VERSION", "")
    proposed = parse_version(version)
    subprocess.run(["git", "merge-base", "--is-ancestor", "HEAD", "origin/main"], check=True)
    releases = json.loads(subprocess.check_output([
        "gh", "release", "list", "--limit", "1000", "--json", "tagName,isDraft,isPrerelease"
    ]))
    for release in releases:
        if release["isDraft"] or release["isPrerelease"]:
            continue
        current = parse_version(release["tagName"].removeprefix("v"))
        if proposed <= current:
            raise ValueError("Release version must be greater than every published stable version")
    tag = f"v{version}"
    existing = subprocess.run(["git", "rev-parse", "--verify", f"refs/tags/{tag}^{{commit}}"], capture_output=True, text=True)
    head = subprocess.check_output(["git", "rev-parse", "HEAD"], text=True).strip()
    if existing.returncode == 0 and existing.stdout.strip() != head:
        raise ValueError("Existing tag points at a different commit")
    with Path(os.environ["GITHUB_ENV"]).open("a") as output:
        output.write(f"MATILDE_VERSION={version}\n")
        output.write(f"RELEASE_EXISTS={'true' if any(r['tagName'] == tag for r in releases) else 'false'}\n")
    print(f"Releasing {tag} from {head}")


if __name__ == "__main__":
    main()
