#!/usr/bin/env python3
"""Fail release packaging if the signed feed points at the wrong build or asset."""
import base64
import json
import sys
import re
import subprocess
import xml.etree.ElementTree as ET
from pathlib import Path

path, version = Path(sys.argv[1]), sys.argv[2]
config = json.loads(Path("Config/release.json").read_text())
ns = "{http://www.andymatuschak.org/xml-namespaces/sparkle}"
root = ET.parse(path).getroot()
item = root.find("./channel/item")
assert item is not None, "Missing update item"
assert item.findtext(ns + "version") == version, "Wrong build version"
enclosure = item.find("enclosure")
assert enclosure is not None, "Missing update download"
assert enclosure.get("url") == f'https://github.com/{config["repository"]}/releases/download/v{version}/Matilde.dmg'
assert int(enclosure.get("length", "0")) == (path.parent / "Matilde.dmg").stat().st_size
assert len(base64.b64decode(enclosure.get(ns + "edSignature", ""), validate=True)) == 64
assert "<!-- sparkle-signatures:" in path.read_text(), "Missing signed-feed signature"
assert item.findtext(ns + "minimumSystemVersion") == "14.0"
assert item.findtext(ns + "hardwareRequirements") == "arm64", "Update must exclude Intel Macs"
feed = path.read_bytes()
marker = feed.rfind(b"<!-- sparkle-signatures:\n")
block = re.fullmatch(rb"<!-- sparkle-signatures:\nedSignature: ([A-Za-z0-9+/=]+)\nlength: ([0-9]+)\n-->\n?", feed[marker:])
assert block and int(block[2]) == marker, "Invalid signed feed boundary"
for file, signature, length in [
    (path.parent / "Matilde.dmg", enclosure.get(ns + "edSignature"), (path.parent / "Matilde.dmg").stat().st_size),
    (path, block[1].decode(), marker),
]:
    subprocess.run(["swift", "-module-cache-path", ".build/module-cache", "scripts/verify-signature.swift", config["sparklePublicKey"], str(file), signature, str(length)], check=True)
print(f"Verified metadata and Ed25519 signatures for {version}")
