#!/usr/bin/env python3
"""Generate and validate SnapGlass's static update manifest."""

from __future__ import annotations

import argparse
import json
import re
from pathlib import Path


VERSION_PATTERN = re.compile(r"^[0-9]+\.[0-9]+\.[0-9]+$")
CHECKSUM_PATTERN = re.compile(r"^[0-9a-fA-F]{64}$")


def parse_arguments() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--version", required=True)
    parser.add_argument("--notes-file", required=True, type=Path)
    parser.add_argument("--checksum-file", required=True, type=Path)
    parser.add_argument("--output", required=True, type=Path)
    parser.add_argument("--repository", default="blackkcold/snapocr")
    return parser.parse_args()


def read_checksum(path: Path) -> str:
    token = path.read_text(encoding="utf-8").split(maxsplit=1)[0].lower()
    if not CHECKSUM_PATTERN.fullmatch(token):
        raise ValueError(f"Invalid SHA-256 checksum in {path}")
    return token


def main() -> None:
    arguments = parse_arguments()
    version = arguments.version
    if not VERSION_PATTERN.fullmatch(version):
        raise ValueError(f"Invalid semantic version: {version}")
    if not re.fullmatch(r"[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+", arguments.repository):
        raise ValueError(f"Invalid GitHub repository: {arguments.repository}")

    release_notes = arguments.notes_file.read_text(encoding="utf-8").strip()
    if not release_notes:
        raise ValueError("Release notes must not be empty")
    checksum = read_checksum(arguments.checksum_file)

    tag = f"v{version}"
    asset_name = f"SnapGlass-v{version}.dmg"
    release_base = f"https://github.com/{arguments.repository}/releases"
    manifest = {
        "schemaVersion": 1,
        "version": version,
        "releaseNotes": release_notes,
        "releasePageURL": f"{release_base}/tag/{tag}",
        "dmgURL": f"{release_base}/download/{tag}/{asset_name}",
        "checksumURL": f"{release_base}/download/{tag}/{asset_name}.sha256",
        "assetName": asset_name,
        "sha256": checksum,
    }

    arguments.output.parent.mkdir(parents=True, exist_ok=True)
    arguments.output.write_text(
        json.dumps(manifest, ensure_ascii=False, indent=2) + "\n",
        encoding="utf-8",
    )


if __name__ == "__main__":
    main()
