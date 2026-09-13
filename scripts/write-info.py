#!/usr/bin/env python3
"""Create bundle metadata without interpolating unescaped XML in shell."""
import json
import os
import plistlib
import re
import sys
from pathlib import Path

config = json.loads(Path("Config/release.json").read_text())
version = os.environ.get("MATILDE_VERSION", config["version"])
if not re.fullmatch(r"(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)", version):
    raise SystemExit("MATILDE_VERSION must be a stable version such as 0.1.0")
info = {
    "CFBundleExecutable": "Matilde",
    "CFBundleIdentifier": config["bundleIdentifier"],
    "CFBundleName": "Matilde", "CFBundleDisplayName": "Matilde",
    "CFBundleIconFile": "Matilde.icns", "CFBundlePackageType": "APPL",
    "CFBundleShortVersionString": version, "CFBundleVersion": version,
    "LSMinimumSystemVersion": "14.0", "NSHighResolutionCapable": True,
    "SUFeedURL": config["feedURL"], "SUPublicEDKey": config["sparklePublicKey"],
    "SUVerifyUpdateBeforeExtraction": True,
    "SURequireSignedFeed": True,
    "SUEnableAutomaticChecks": True,
    "SUAutomaticallyUpdate": False,
    "SUAllowsAutomaticUpdates": False,
    "SUSendProfileInfo": False,
}
with Path(sys.argv[1]).open("wb") as file:
    plistlib.dump(info, file)
