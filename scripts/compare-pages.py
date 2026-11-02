#!/usr/bin/env python3
"""Render every fixture page in dossier-format's examples/ and compare it with the fixture's.

    make release
    python3 -I scripts/compare-pages.py [SPEC_TREE] [--dossier PATH] [--keep DIR]

SPEC_TREE defaults to .dossier-format/. Not in CI: `ConformancePageTests` runs the same comparison
in `make test`, and this says where each difference is. Standard library only.

Every fixture is copied to a temporary directory first, so nothing under SPEC_TREE is written. The
pages must be byte-identical apart from the payloads of image data: URIs, which differ by encoder
(DF-45) and are compared only by count and dimensions. Every other difference is printed with its
file and offset. Neither side is assumed to be right.

Each fixture's page is one of three things:
  strict   the page as filled. A difference is a failure (exit 1).
  altered  a valid fixture whose page has content added after filling. Differences are reported.
  faulty   deliberately faulty or out of date. Differences are reported, and are the point.
"""
import argparse
import base64
import bisect
import difflib
import hashlib
import json
import os
import re
import shutil
import struct
import subprocess
import sys
import tempfile
from pathlib import Path

IMAGE = re.compile(rb"data:image/jpeg;base64,([A-Za-z0-9+/=]+)")
TOKEN = re.compile(rb"[^>\n]*[>\n]|[^>\n]+$")
ALTERED = {"valid/page-allowed-references": "extra elements added after filling",
           "valid/page-at-size-limit": "padded after filling"}
FAULTY = {"warnings/W-STALE-template": "made with another template's hash",
          "warnings/W-STALE-input-member": "the member changed after it was filled"}


def classify(fixture):
    path = fixture["path"]
    if path in ALTERED:
        return "altered", ALTERED[path]
    if path in FAULTY:
        return "faulty", FAULTY[path]
    if any(code.startswith("W-PAGE-") for code in fixture.get("codes", [])):
        return "faulty", "a page fault added after filling"
    return "strict", ""


def jpeg_size(data):
    position = 2
    while position + 9 <= len(data):
        marker = data[position + 1]
        length = struct.unpack(">H", data[position + 2:position + 4])[0]
        if marker in (0xC0, 0xC1, 0xC2):
            height, width = struct.unpack(">HH", data[position + 5:position + 9])
            return width, height
        position += 2 + length
    return None


def without_payloads(page):
    """The page with each image payload gone, the sizes in order, and a way back to file offsets."""
    pieces, sizes, starts, originals = [], [], [], []
    position, length = 0, 0
    for match in IMAGE.finditer(page):
        piece = page[position:match.start(1)]
        starts.append(length)
        originals.append(position)
        pieces.append(piece)
        length += len(piece)
        sizes.append(jpeg_size(base64.b64decode(match.group(1))))
        position = match.end(1)
    starts.append(length)
    originals.append(position)
    pieces.append(page[position:])
    return b"".join(pieces), sizes, (starts, originals)


def file_offset(places, offset):
    starts, originals = places
    index = bisect.bisect_right(starts, offset) - 1
    return originals[index] + offset - starts[index]


def tokens_with_offsets(text):
    tokens, offsets = [], []
    for match in TOKEN.finditer(text):
        tokens.append(match.group(0))
        offsets.append(match.start())
    offsets.append(len(text))
    return tokens, offsets


def excerpt(data, limit=160):
    text = data.decode("utf-8", "replace")
    return text if len(text) <= limit else text[:limit] + f"... ({len(data)} bytes)"


def differences(fixture_page, rendered_page):
    """A list of lines. Empty when the pages agree."""
    lines = []
    fixture_text, fixture_sizes, fixture_places = without_payloads(fixture_page)
    rendered_text, rendered_sizes, rendered_places = without_payloads(rendered_page)
    if len(fixture_sizes) != len(rendered_sizes):
        lines.append(f"images: the fixture has {len(fixture_sizes)}, the render {len(rendered_sizes)}")
    for index, (first, second) in enumerate(zip(fixture_sizes, rendered_sizes)):
        if first != second:
            lines.append(f"image {index}: the fixture's is {first}, the render's {second}")
    if fixture_text == rendered_text:
        return lines
    fixture_tokens, fixture_offsets = tokens_with_offsets(fixture_text)
    rendered_tokens, rendered_offsets = tokens_with_offsets(rendered_text)
    matcher = difflib.SequenceMatcher(None, fixture_tokens, rendered_tokens, autojunk=False)
    for tag, first, second, third, fourth in matcher.get_opcodes():
        if tag == "equal":
            continue
        fixture_part = fixture_text[fixture_offsets[first]:fixture_offsets[second]]
        rendered_part = rendered_text[rendered_offsets[third]:rendered_offsets[fourth]]
        lines.append(
            f"{tag}: fixture offset {file_offset(fixture_places, fixture_offsets[first])}, "
            f"render offset {file_offset(rendered_places, rendered_offsets[third])}\n"
            f"      fixture: {excerpt(fixture_part)!r}\n      render:  {excerpt(rendered_part)!r}")
    return lines


def tree_digest(root):
    digest = hashlib.sha256()
    for path in sorted(root.rglob("*")):
        if path.is_file() and ".git" not in path.parts and "__pycache__" not in path.parts:
            digest.update(str(path.relative_to(root)).encode())
            digest.update(hashlib.sha256(path.read_bytes()).digest())
    return digest.hexdigest()


def main():
    here = Path(__file__).resolve().parent.parent
    parser = argparse.ArgumentParser(description="Compare rendered pages with the fixtures'.")
    parser.add_argument("spec", nargs="?", default=str(here / ".dossier-format"))
    parser.add_argument("--dossier", default=str(here / "bin/dossier"))
    parser.add_argument("--keep", help="Keep the rendered pages in this directory.")
    arguments = parser.parse_args()
    spec = Path(arguments.spec).resolve()
    examples = spec / "examples"
    conformance = json.loads((examples / "conformance.json").read_text(encoding="utf-8"))
    before = tree_digest(examples)

    tally = {"identical": 0, "differ": 0}
    failures = 0
    checked = 0
    with tempfile.TemporaryDirectory() as work:
        for fixture in conformance["fixtures"]:
            bundle = examples / fixture["path"] / fixture["bundle"]
            pages = sorted(bundle.glob("*-dossier.html"))
            if not pages:
                continue
            checked += 1
            kind, why = classify(fixture)
            copy = Path(work) / str(checked)
            shutil.copytree(examples / fixture["path"], copy, symlinks=True)
            target = copy / fixture["bundle"]
            ran = subprocess.run(
                [arguments.dossier, "render", str(target), "--cast", str(copy / "CAST.md"), "--json"],
                capture_output=True, text=True, cwd=work)
            label = f"{fixture['path']} [{kind}{': ' + why if why else ''}]"
            if ran.returncode != 0:
                failures += 1
                tally["differ"] += 1
                print(f"{label}\n  RENDER FAILED, status {ran.returncode}: {ran.stdout.strip()}")
                continue
            rendered = (target / pages[0].name).read_bytes()
            found = differences(pages[0].read_bytes(), rendered)
            if arguments.keep:
                os.makedirs(arguments.keep, exist_ok=True)
                (Path(arguments.keep) / f"{checked}-{pages[0].name}").write_bytes(rendered)
            if found:
                tally["differ"] += 1
                failures += kind == "strict"
                print(f"{label}\n  file: {pages[0].relative_to(spec)}")
                for line in found:
                    print(f"  {line}")
            else:
                tally["identical"] += 1
                print(f"{label}\n  identical apart from image payloads ({len(without_payloads(rendered)[1])} images)")

    untouched = tree_digest(examples) == before
    print(f"{checked} fixture pages: {tally['identical']} identical, {tally['differ']} differ, {failures} strict failures")
    print(f"examples/ unchanged: {'yes' if untouched else 'NO'}")
    return 1 if failures or not untouched else 0


if __name__ == "__main__":
    sys.exit(main())
