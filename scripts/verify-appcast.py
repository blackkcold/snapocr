#!/usr/bin/env python3
"""Verify a Sparkle appcast before it is published.

Checks, in order:
  - the feed parses and carries exactly one item
  - the item describes the version and build that were just built
  - the enclosure URL points at the release asset
  - the enclosure carries an EdDSA signature
  - that signature verifies against the app's SUPublicEDKey over the exact
    bytes of the DMG (this is the check that catches a mismatched key pair,
    which would otherwise strand every installed copy)

usage:
  verify-appcast.py APPCAST --version X.Y.Z --build N --asset PATH \
      --prefix https://.../download/vX.Y.Z/ \
      [--public-key FILE] [--require-signed-feed]

Verifying the signature needs the `cryptography` package.
"""

import argparse
import base64
import sys
import xml.etree.ElementTree as ET
from pathlib import Path

SPARKLE_NS = "http://www.andymatuschak.org/xml-namespaces/sparkle"
NS = {"sparkle": SPARKLE_NS}


def fail(message):
    print(f"error: {message}", file=sys.stderr)
    raise SystemExit(1)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("appcast")
    parser.add_argument("--version", required=True)
    parser.add_argument("--build", required=True)
    parser.add_argument("--asset", required=True, help="path to the DMG/ZIP that was signed")
    parser.add_argument("--prefix", required=True, help="download URL prefix, ending in /")
    parser.add_argument(
        "--public-key",
        default=None,
        help="base64 EdDSA public key (default: scripts/signing/sparkle_ed25519.pub)",
    )
    parser.add_argument("--require-signed-feed", action="store_true")
    args = parser.parse_args()

    text = Path(args.appcast).read_text(encoding="utf-8")
    if args.require_signed_feed and "sparkle-signatures:" not in text:
        fail("feed is not signed, but SURequireSignedFeed is enabled")

    body = text.split("<!-- sparkle-signatures:")[0]
    try:
        root = ET.fromstring(body)
    except ET.ParseError as error:
        fail(f"feed is not valid XML: {error}")

    items = root.findall("./channel/item")
    if len(items) != 1:
        fail(f"expected exactly one item, found {len(items)}")
    item = items[0]

    found_build = item.findtext("sparkle:version", namespaces=NS)
    if found_build != args.build:
        fail(f"sparkle:version is {found_build!r}, expected {args.build!r}")

    found_version = item.findtext("sparkle:shortVersionString", namespaces=NS)
    if found_version != args.version:
        fail(f"sparkle:shortVersionString is {found_version!r}, expected {args.version!r}")

    enclosure = item.find("enclosure")
    if enclosure is None:
        fail("item has no enclosure")

    asset = Path(args.asset)
    url = enclosure.get("url", "")
    expected_url = args.prefix + asset.name
    if url != expected_url:
        fail(f"enclosure url is {url!r}, expected {expected_url!r}")

    signature = enclosure.get(f"{{{SPARKLE_NS}}}edSignature")
    if not signature:
        fail("enclosure is missing sparkle:edSignature")

    key_path = args.public_key or str(
        Path(__file__).resolve().parent / "signing/sparkle_ed25519.pub"
    )
    try:
        public_key = base64.b64decode(Path(key_path).read_text(encoding="utf-8").strip())
    except OSError as error:
        fail(f"cannot read public key {key_path}: {error}")
    if len(public_key) != 32:
        fail(f"public key must be 32 bytes, got {len(public_key)}")

    try:
        from cryptography.exceptions import InvalidSignature
        from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PublicKey
    except ImportError:
        fail("the `cryptography` package is required to verify the update signature")

    verifier = Ed25519PublicKey.from_public_bytes(public_key)
    try:
        verifier.verify(base64.b64decode(signature), asset.read_bytes())
    except InvalidSignature:
        fail(
            "the enclosure signature does not verify against the app's SUPublicEDKey; "
            "this build would never accept an update"
        )

    print(f"ok: v{args.version} (build {args.build}), signed feed and verified package")


if __name__ == "__main__":
    main()
