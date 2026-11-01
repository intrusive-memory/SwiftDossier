#!/usr/bin/env bash
# make acceptance PROJECT=<path> [REF=<git ref>] [REPARTO=<path>]
#
# REQUIREMENTS §9 items 1, 2, 4 and 5 against a local project checkout. Not in CI (SD-4).
# Items 3 and 4's migrate half belong to phases 3 and 4.
#
# The project is read and never written, apart from what Git LFS's own smudge keeps in its
# object cache. REF's committed state goes into a temporary directory by `git archive`, every
# command runs on that copy, and the copy is removed on exit. The one thing read from the
# working tree is item 2's .generations/, and only when REF doesn't hold it, which is usual
# since it's ignored; the output says when.
#
# Output holds names, codes, counts and key names. Never a prompt, a description, a sidecar
# value or a tool's message, which can quote those.
#
# Exit status: 0 no failure, 1 a failure, 2 couldn't run, 64 a bad command line. A project that
# isn't there is 0 with a skip message.
set -euo pipefail

usage() {
  echo "usage: make acceptance PROJECT=<path> [REF=<git ref>] [REPARTO=<path>]" >&2
  echo "  REF defaults to dossier/v2-migration. REPARTO defaults to the one on PATH, then to one" >&2
  echo "  built from the SwiftReparto this package resolves." >&2
}
die() {
  echo "acceptance: $*" >&2
  exit 2
}

PROJECT="${1:-}"
REF="${2:-}"
[ -n "$REF" ] || REF="dossier/v2-migration"

if [ -z "$PROJECT" ]; then
  usage
  exit 64
fi
if [ ! -d "$PROJECT" ]; then
  echo "acceptance: SKIP: no project at $PROJECT (SD-4). Nothing was run."
  exit 0
fi

export GIT_OPTIONAL_LOCKS=0
git -C "$PROJECT" rev-parse --git-dir >/dev/null 2>&1 || die "$PROJECT isn't a git repository"
COMMIT="$(git -C "$PROJECT" rev-parse --verify --quiet "$REF^{commit}")" || die "no ref $REF in $PROJECT"

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

mkdir "$WORK/copy"
git -C "$PROJECT" archive "$COMMIT" 2>"$WORK/archive.log" | tar -xf - -C "$WORK/copy" \
  || die "git archive of $REF failed. If Git LFS is in use, its objects may not be fetched."

echo "acceptance: building dossier with make release"
if ! make -C "$ROOT" release >"$WORK/release.log" 2>&1; then
  tail -20 "$WORK/release.log" >&2
  die "make release failed"
fi
# The DerivedData directory Xcode says is this checkout's. xcodebuild -showBuildSettings gives
# no settings for a package scheme.
BUILT=""
for DERIVED in "$HOME"/Library/Developer/Xcode/DerivedData/SwiftDossier-*; do
  WORKSPACE="$(plutil -extract WorkspacePath raw "$DERIVED/info.plist" 2>/dev/null)" || continue
  if [ "$(cd "$WORKSPACE" 2>/dev/null && pwd -P)" = "$ROOT" ]; then BUILT="$DERIVED/Build/Products/Release"; fi
done
[ -n "$BUILT" ] && [ -d "$BUILT" ] || die "couldn't find this checkout's build products"
cmp -s "$ROOT/bin/dossier" "$BUILT/dossier" \
  || die "bin/dossier isn't this checkout's build; make release took another DerivedData's. Run make clean."

# The Python below is given the copy, and the project only to read .generations/ from.
ACCEPT_ROOT="$ROOT" ACCEPT_WORK="$WORK" ACCEPT_BUILT="$BUILT" ACCEPT_REF="$REF" \
  ACCEPT_COMMIT="${COMMIT:0:12}" ACCEPT_REPARTO="${REPARTO:-}" ACCEPT_READ_ONLY_SOURCE="$PROJECT" \
  python3 -I -c "$(sed -n '/^# PYTHON BEGIN$/,/^# PYTHON END$/p' "${BASH_SOURCE[0]}")"
exit $?

# PYTHON BEGIN
import collections, datetime, difflib, hashlib, json, os, re, shutil, subprocess, sys

ROOT = os.environ["ACCEPT_ROOT"]
WORK = os.environ["ACCEPT_WORK"]
COPY = os.path.join(WORK, "copy")
BUILT = os.environ["ACCEPT_BUILT"]
READ_ONLY_SOURCE = os.environ["ACCEPT_READ_ONLY_SOURCE"]
DOSSIER = os.path.join(ROOT, "bin", "dossier")
LFS_MAGIC = b"version https://git-lfs"
PROBE = "ZZ ACCEPTANCE PROBE"

rows = {"bundle": collections.Counter(), "item": collections.Counter()}


def row(group, status, text):
    """One result. A status is PASS, FAIL, SKIP, or SKIP(lfs pointer), which is a failure."""
    rows[group][status] += 1
    print(f"{group} {text}" if group == "item" else f"  {text}")


def run_quiet(command, **kwargs):
    """A tool's own text can quote what it read, so it's captured and never printed."""
    # Never from the checkout or the project: a build with coverage leaves a profile in its cwd.
    kwargs.setdefault("cwd", WORK)
    return subprocess.run(command, capture_output=True, text=True, errors="replace", **kwargs)


def dossier(*arguments):
    done = run_quiet([DOSSIER, *arguments, "--json"])
    try:
        return done.returncode, json.loads(done.stdout)
    except ValueError:
        return done.returncode, None


def error_code(result):
    return ((result or {}).get("error") or {}).get("code", "no JSON")


def inside_copy(path):
    real, top = os.path.realpath(path), os.path.realpath(COPY)
    return real == top or real.startswith(top + os.sep)


def is_lfs_pointer(path):
    try:
        if os.path.getsize(path) > 1024:
            return False
        with open(path, "rb") as file:
            return file.read(len(LFS_MAGIC)) == LFS_MAGIC
    except OSError:
        return False


def files_under(path):
    for directory, _, names in os.walk(path):
        for name in names:
            yield os.path.join(directory, name)


def counted(counter):
    return " ".join(f"{code}x{count}" for code, count in sorted(counter.items())) or "none"


def codes(result, level):
    return collections.Counter(
        finding["code"] for finding in (result or {}).get("findings", []) if finding["level"] == level
    )


def read_json(path):
    try:
        with open(path, "rb") as file:
            return json.load(file)
    except (OSError, ValueError):
        return None


def sha256_of(path):
    with open(path, "rb") as file:
        return hashlib.sha256(file.read()).hexdigest()


def reject_links_out_of_the_copy():
    """Every write below goes through a path in the copy. A committed link could lead it away."""
    for directory, names, files in os.walk(COPY):
        for name in names + files:
            path = os.path.join(directory, name)
            if os.path.islink(path) and not inside_copy(path):
                print("acceptance: a committed link leads out of the copy. Nothing was run.", file=sys.stderr)
                sys.exit(2)


# Item 1 ---------------------------------------------------------------------------------------

def item1(members, members_ok):
    """
    `dossier validate <bundle> --cast CAST.md` on each member with a manifest:. The evaluator
    runs on each: Validator.checkSchema is called for every manifest it can read and reports
    E-SCHEMA. It picks the schema by manifestVersion, so manifest-v2 PASS needs version 2 as well.
    """
    print("item 1: bundles from CAST.md")
    if not members_ok:
        row("item", "FAIL", "1 FAIL: CAST.md can't be read, or lists no members")
        return {}
    pre_add_errors, failed, skipped = {}, 0, 0
    pointers_total = 0
    with_bundle = [member for member in members if member["manifest"]]
    for member in with_bundle:
        name, bundle = member["character"], os.path.dirname(member["manifest"])
        if not inside_copy(bundle):
            row("bundle", "FAIL", f"{name}  FAIL  its manifest: leaves the project  manifest-v2: not run")
            failed += 1
            continue
        status, result = dossier("validate", bundle, "--cast", os.path.join(COPY, "CAST.md"))
        errors, warnings = codes(result, "error"), codes(result, "warning")
        manifest = read_json(os.path.join(bundle, "manifest.json"))
        version = manifest.get("manifestVersion") if isinstance(manifest, dict) else None
        if result is None or "findings" not in result:
            schema = "not run"
        elif version != 2:
            schema = f"FAIL(manifestVersion {version})"
        elif "E-SCHEMA" in errors or "E-SCHEMA" in warnings:
            schema = "FAIL"
        else:
            schema = "PASS"
        pointers = sum(is_lfs_pointer(path) for path in files_under(bundle))
        pointers_total += pointers
        if pointers:
            row("bundle", "SKIP(lfs pointer)",
                f"{name}  SKIP(lfs pointer)  {pointers} files are LFS pointers, so their hashes can't be "
                f"checked  manifest-v2: {schema}")
            skipped += 1
            continue
        pre_add_errors[name] = errors
        if result is None or "findings" not in result:
            row("bundle", "FAIL", f"{name}  FAIL  validate didn't run (status {status}, {error_code(result)})  manifest-v2: not run")
            failed += 1
            continue
        passed = not errors and schema == "PASS"
        failed += not passed
        row("bundle", "PASS" if passed else "FAIL",
            f"{name}  {'PASS' if passed else 'FAIL'}  errors: {counted(errors)}  warnings: {counted(warnings)}  manifest-v2: {schema}")

    if pointers_total:
        project = "SKIP(lfs pointer)"
        project_codes = "not judged while LFS pointers remain"
    else:
        _, whole = dossier("validate", "--cast", os.path.join(COPY, "CAST.md"))
        errors = codes(whole, "error")
        project = "FAIL" if errors else "PASS"
        project_codes = f"errors: {counted(errors)}  warnings: {counted(codes(whole, 'warning'))}"
    print(f"  CAST.md as a whole  {project}  {project_codes}")

    if not with_bundle:
        row("item", "FAIL", "1 FAIL: no member has a bundle, so nothing was validated")
    elif skipped:
        row("item", "SKIP(lfs pointer)",
            f"1 SKIP(lfs pointer): {skipped} of {len(with_bundle)} bundles hold LFS pointers ({pointers_total} files), a failure of this check")
    else:
        verdict = "FAIL" if failed or project == "FAIL" else "PASS"
        row("item", verdict,
            f"1 {verdict}: {len(with_bundle)} bundles, {failed} failed, CAST.md as a whole {project}, "
            f"{len(members) - len(with_bundle)} members have no bundle")
    return pre_add_errors


# Item 2 ---------------------------------------------------------------------------------------

def copy_generations_from_working_tree(members):
    """.generations/ is normally ignored, so REF lacks it. Copies PNGs that have a sidecar, reading only."""
    copied = 0
    for member in members:
        if not member["manifest"] or not inside_copy(member["manifest"]):
            continue
        bundle = os.path.dirname(member["manifest"])
        manifest = read_json(os.path.join(bundle, "manifest.json"))
        if not isinstance(manifest, dict) or not isinstance(manifest.get("character"), str):
            continue
        characters = os.path.relpath(os.path.dirname(bundle), COPY)
        relative = os.path.join(characters, ".generations", manifest["character"])
        source = os.path.join(READ_ONLY_SOURCE, relative)
        if not os.path.isdir(source) or os.path.islink(source):
            continue
        for name in sorted(os.listdir(source)):
            stem, extension = os.path.splitext(name)
            if extension != ".png" or os.path.islink(os.path.join(source, name)):
                continue
            for sidecar in (name + ".json", stem + ".json"):
                path = os.path.join(source, sidecar)
                if os.path.isfile(path) and not os.path.islink(path):
                    target = os.path.join(COPY, relative)
                    os.makedirs(target, exist_ok=True)
                    shutil.copyfile(os.path.join(source, name), os.path.join(target, name))
                    shutil.copyfile(path, os.path.join(target, sidecar))
                    copied += 1
                    break
    return copied


def asset_hashes(manifest):
    """Each asset's path, kind and status, by its sha256 in `files`."""
    file_hashes = {entry.get("path"): entry.get("sha256") for entry in manifest.get("files", [])}
    found = collections.defaultdict(list)
    for asset in manifest.get("assets", []):
        found[file_hashes.get(asset.get("path"))].append(asset)
    return found


def sidecar_references(sidecar):
    """The references, or None when they aren't SD-7's shape (objects with a sha256)."""
    references = sidecar.get("references", [])
    if not isinstance(references, list):
        return None
    if not all(isinstance(entry, dict) and isinstance(entry.get("sha256"), str) for entry in references):
        return None
    return references


def choose_candidate(members):
    """The view with the most references whose hash matches an asset, then a view by name."""
    choices, pointer_files, unusable = [], 0, 0
    for member in members:
        if not member["manifest"] or not inside_copy(member["manifest"]):
            continue
        bundle = os.path.dirname(member["manifest"])
        status, result = dossier("candidates", bundle)
        manifest = read_json(os.path.join(bundle, "manifest.json"))
        if status != 0 or result is None or not isinstance(manifest, dict):
            continue
        hashes = asset_hashes(manifest)
        for candidate in result.get("candidates", []):
            if not candidate["sidecar"] or not candidate["path"].endswith(".png"):
                continue
            if candidate["kind"] not in ("view", None):
                continue
            if is_lfs_pointer(candidate["path"]) or is_lfs_pointer(candidate["sidecar"]):
                pointer_files += 1
                continue
            sidecar = read_json(candidate["sidecar"])
            references = sidecar_references(sidecar) if isinstance(sidecar, dict) else None
            if references is None:
                unusable += 1
                continue
            matches = sum(entry["sha256"] in hashes for entry in references)
            is_view = candidate["kind"] == "view" and bool(candidate["variant"])
            choices.append((-matches, not is_view, member["character"], candidate["name"], member, candidate, sidecar))
    choices.sort(key=lambda choice: choice[:4])
    return (choices[0][4:] if choices else None), pointer_files, unusable


def references_with_source(value):
    """How many entries of any `references` in this JSON still have `source`."""
    found = 0
    if isinstance(value, dict):
        for key, item in value.items():
            if key == "references" and isinstance(item, list):
                found += sum(isinstance(entry, dict) and "source" in entry for entry in item)
            found += references_with_source(item)
    elif isinstance(value, list):
        for item in value:
            found += references_with_source(item)
    return found


def same_time(first, second):
    try:
        parse = lambda text: datetime.datetime.fromisoformat(text.replace("Z", "+00:00"))
        return parse(first) == parse(second)
    except (AttributeError, TypeError, ValueError):
        return False


def item2(members, pre_add_errors):
    """`dossier add` of a view and its sidecar. Writes to the copy only, which the choice checks."""
    print("item 2: dossier add of a view with its sidecar")
    origin = "REF"
    chosen, pointer_files, unusable = choose_candidate(members)
    if not chosen and not pointer_files:
        if copy_generations_from_working_tree(members):
            origin = "the working tree, because REF doesn't hold it"
            chosen, pointer_files, unusable = choose_candidate(members)
    if not chosen:
        if pointer_files:
            row("item", "SKIP(lfs pointer)", f"2 SKIP(lfs pointer): {pointer_files} candidates are LFS pointers, a failure of this check")
        else:
            row("item", "FAIL", f"2 FAIL: no member has a view PNG with a sidecar in .generations/ ({unusable} sidecars of the wrong shape)")
        return
    member, candidate, sidecar = chosen
    name, bundle = member["character"], os.path.dirname(member["manifest"])
    print(f"  member: {name}; .generations from {origin}; named as a view: {'yes' if candidate['kind'] == 'view' else 'no'}")

    manifest_path = os.path.join(bundle, "manifest.json")
    variant = candidate["variant"] or "acceptance"
    destination = f"images/view-{variant}-{sha256_of(candidate['path'])[:8]}.png"
    if any(asset.get("path") == destination for asset in read_json(manifest_path).get("assets", [])):
        status, result = dossier("remove", bundle, destination, "--yes")
        if status != 0:
            row("item", "FAIL", f"2 FAIL: the view is already in the bundle, and remove failed ({error_code(result)})")
            return
        print("  the view was already in the bundle, so it was removed from the copy first")

    before = read_json(manifest_path)
    hashes = asset_hashes(before)
    references = sidecar_references(sidecar)
    roles = ["portrait", "face"][: len(references)]
    arguments = ["add", bundle, candidate["path"], "--kind", "view", "--variant", variant, "--sidecar", candidate["sidecar"]]
    if roles:
        arguments += ["--reference-roles", ",".join(roles)]
    status, result = dossier(*arguments)
    if status != 0 or not result or "asset" not in result:
        row("item", "FAIL", f"2 FAIL: dossier add failed ({error_code(result)})")
        return

    manifest = read_json(manifest_path)
    written = next((a for a in manifest.get("assets", []) if a.get("path") == result["asset"].get("path")), None)
    if written is None:
        row("item", "FAIL", "2 FAIL: the manifest doesn't hold the asset add returned")
        return
    provenance = written.get("provenance", {})
    failures = []

    expected = sorted(set(sidecar) - {"generatedAt"})
    missing = [key for key in expected if key not in provenance]
    altered = [key for key in expected if key not in missing and key not in ("references", "loras") and provenance[key] != sidecar[key]]
    print(f"  SD-7 keys: {len(expected) - len(missing)} of {len(expected)} recorded: {', '.join(expected) or 'none'}")
    if missing:
        failures.append(f"missing keys: {', '.join(missing)}")
    if altered:
        failures.append(f"changed keys: {', '.join(altered)}")
    if "generatedAt" in sidecar:
        moved = same_time(sidecar["generatedAt"], written.get("createdAt")) and "generatedAt" not in provenance
        print(f"  generatedAt became createdAt: {'yes' if moved else 'no'}")
        if not moved:
            failures.append("generatedAt didn't become createdAt")

    recorded = provenance.get("references", [])
    matched, with_path, wrong_path, by_kind, wrong_role = 0, 0, 0, collections.Counter(), 0
    if len(recorded) != len(references):
        failures.append("the number of references changed")
    for original, entry in zip(references, recorded):
        assets = hashes.get(original["sha256"], [])
        if entry.get("sha256") != original["sha256"]:
            failures.append("a reference's sha256 changed")
        with_path += "path" in entry
        if assets:
            matched += 1
            if entry.get("path") not in [asset.get("path") for asset in assets]:
                wrong_path += 1
            for kind in {asset.get("kind") for asset in assets} & {"portrait", "face"}:
                by_kind[kind] += 1
                if entry.get("role") != kind:
                    wrong_role += 1
        elif "path" in entry and "path" not in original:
            wrong_path += 1
    print(f"  references: {len(recorded)}; hashes matching an asset: {matched}; with a path: {with_path}; "
          f"mapped to a portrait: {by_kind['portrait']}; mapped to a face: {by_kind['face']}")
    if wrong_path:
        failures.append(f"{wrong_path} references have the wrong path")
    if wrong_role:
        failures.append(f"{wrong_role} references have a role that isn't their asset's kind")

    sources = references_with_source(manifest)
    print(f"  references with source in the manifest: {sources}")
    if sources:
        failures.append("source is in the manifest")

    _, after = dossier("validate", bundle, "--cast", os.path.join(COPY, "CAST.md"))
    new_errors = codes(after, "error") - pre_add_errors.get(name, collections.Counter())
    print(f"  errors the add introduced: {counted(new_errors)}")
    if new_errors:
        failures.append("the bundle has new errors")

    if failures:
        row("item", "FAIL", f"2 FAIL: {'; '.join(failures)}")
    else:
        note = "" if matched else ", but no reference matches an asset, so the mapping wasn't exercised"
        row("item", "PASS", f"2 PASS: {name}, every SD-7 key recorded, {matched} of {len(recorded)} reference hashes match{note}")


# Item 4 ---------------------------------------------------------------------------------------

def package_checkout(name):
    """The checkout of a dependency this build resolves: a sibling, as Package.swift prefers, or Xcode's."""
    sibling = os.path.join(os.path.dirname(ROOT), name)
    if os.path.isdir(sibling) and os.environ.get("CI") != "true":
        return sibling
    checkouts = os.path.join(BUILT, "..", "..", "..", "SourcePackages", "checkouts")
    if os.path.isdir(checkouts):
        for entry in os.listdir(checkouts):
            if entry.lower() == name.lower():
                return os.path.join(checkouts, entry)
    return None


def build_reparto():
    """Returns (path, None), or (None, why not). The build is of a copy: a checkout isn't ours to write in."""
    checkout = package_checkout("SwiftReparto")
    if not checkout:
        return None, "no SwiftReparto checkout resolved for this build"
    source = os.path.join(WORK, "reparto-source")
    shutil.copytree(checkout, source, symlinks=True, ignore=shutil.ignore_patterns(".git", ".build"))
    for directory, _, names in os.walk(source):
        os.chmod(directory, 0o755)
        for name in names:
            path = os.path.join(directory, name)
            if not os.path.islink(path):
                os.chmod(path, 0o644)
    products = os.path.join(WORK, "reparto-build")
    print("  building reparto from the resolved SwiftReparto")
    done = run_quiet(
        ["xcodebuild", "build", "-scheme", "reparto", "-configuration", "Release",
         "-destination", "platform=macOS,arch=arm64", "-derivedDataPath", products,
         "-skipPackagePluginValidation", "-skipMacroValidation", "CODE_SIGNING_ALLOWED=NO",
         "ARCHS=arm64", "ONLY_ACTIVE_ARCH=YES"], cwd=source)
    binary = os.path.join(products, "Build", "Products", "Release", "reparto")
    if done.returncode != 0 or not os.access(binary, os.X_OK):
        return None, f"building it failed (xcodebuild status {done.returncode})"
    return binary, None


def find_reparto():
    """REPARTO=, then PATH, then a build. Returns (path, where from, why not)."""
    given = os.environ.get("ACCEPT_REPARTO", "")
    if given:
        if os.path.isfile(given) and os.access(given, os.X_OK):
            return given, "REPARTO=", None
        return None, None, "REPARTO= isn't an executable file"
    found = shutil.which("reparto")
    if found:
        return found, "PATH", None
    binary, why = build_reparto()
    return binary, "a build of the resolved package", why


def resolved_version(name):
    pins = (read_json(os.path.join(ROOT, "Package.resolved")) or {}).get("pins", [])
    for pin in pins:
        if pin.get("identity") == name:
            return pin.get("state", {}).get("version")
    return None


def member_blocks(lines):
    """Which member each line of a Reparto-written CAST.md is in, or None outside the cast list."""
    owners = [None] * len(lines)
    if not lines or lines[0].rstrip() != "---":
        return owners
    in_cast, current, indent = False, None, None
    for index, line in enumerate(lines[1:], start=1):
        text = line.rstrip()
        if text == "---":
            break
        if re.match(r"^cast:\s*$", text):
            in_cast = True
            continue
        if not in_cast:
            continue
        if text and not text.startswith((" ", "-")):
            in_cast, current = False, None
            continue
        start = re.match(r"^(\s*)- ", text)
        if start and (indent is None or len(start.group(1)) == indent):
            indent = len(start.group(1))
            current = {"name": None}
        if current is not None:
            owners[index] = current
            named = re.match(r"^\s*(?:- )?character:\s*(.+?)\s*$", text)
            if named and current["name"] is None:
                current["name"] = named.group(1).strip("'\"")
    return [owner and owner["name"] for owner in owners]


def member_hashes(cast):
    _, result = dossier("validate", "--cast", cast)
    return [(member["character"], member["hash"]) for member in (result or {}).get("members", [])]


def item4(members_ok):
    print("item 4: CAST.md writes (create; migrate is phase 4)")
    if not members_ok:
        row("item", "FAIL", "4 FAIL: CAST.md can't be read")
        return
    reparto, origin, why = find_reparto()
    if not reparto:
        row("item", "SKIP", f"4 SKIP: reparto is unavailable: {why}")
        return
    version_run = run_quiet([reparto, "--version"])
    version = version_run.stdout.strip()
    wanted = resolved_version("swiftreparto")
    print(f"  reparto {version or 'of unknown version'}, from {origin}")
    if wanted and version != wanted:
        print(f"  WARNING: this package resolves SwiftReparto {wanted}, and dossier writes with that. "
              f"Pass REPARTO= for a matching one.")

    original = os.path.join(COPY, "CAST.md")
    failures = []

    # Written once by Reparto: only the touched member's lines change.
    normalized = os.path.join(WORK, "item4-normalized")
    os.makedirs(os.path.join(normalized, "characters"))
    cast = os.path.join(normalized, "CAST.md")
    shutil.copyfile(original, cast)
    done = run_quiet([reparto, "canonicalize", cast, "--apply"])
    if done.returncode != 0:
        row("item", "FAIL", f"4 FAIL: reparto canonicalize --apply exited {done.returncode}")
        return
    with open(cast, encoding="utf-8") as file:
        before_text = file.read()
    if PROBE in before_text:
        row("item", "FAIL", "4 FAIL: the probe member's name is already in CAST.md")
        return
    hashes_before = member_hashes(cast)
    status, result = dossier("create", PROBE, "--role", "guest", "--in", os.path.join(normalized, "characters"), "--cast", cast)
    if status != 0:
        row("item", "FAIL", f"4 FAIL: create on the normalized copy failed ({error_code(result)})")
        return
    with open(cast, encoding="utf-8") as file:
        after_text = file.read()
    before_lines, after_lines = before_text.splitlines(), after_text.splitlines()
    before_owner, after_owner = member_blocks(before_lines), member_blocks(after_lines)
    added, removed, touched = 0, 0, set()
    matcher = difflib.SequenceMatcher(None, before_lines, after_lines, autojunk=False)
    for tag, first, second, third, fourth in matcher.get_opcodes():
        if tag == "equal":
            continue
        removed += second - first
        added += fourth - third
        touched.update(before_owner[first:second])
        touched.update(after_owner[third:fourth])
    outside = None in touched
    names = sorted(name for name in touched if name)
    print(f"  normalized copy: {added} lines added, {removed} removed; members touched: {', '.join(names) or 'none'}"
          + ("; lines outside any member changed" if outside else ""))
    if outside or names != [PROBE]:
        failures.append("create changed lines beyond its own member")
    hashes_after = [pair for pair in member_hashes(cast) if pair[0] != PROBE]
    if hashes_after != hashes_before:
        failures.append("a hash changed on the normalized copy")

    # As committed: every member keeps its §7 hash, except what SD-12 reports.
    raw = os.path.join(WORK, "item4-unnormalized")
    os.makedirs(os.path.join(raw, "characters"))
    cast = os.path.join(raw, "CAST.md")
    shutil.copyfile(original, cast)
    hashes_before = member_hashes(cast)
    status, result = dossier("create", PROBE, "--role", "guest", "--in", os.path.join(raw, "characters"), "--cast", cast)
    if status != 0:
        row("item", "FAIL", f"4 FAIL: create on the unnormalized copy failed ({error_code(result)})")
        return
    report = result.get("castReport", {})
    exceptions = report.get("exceptions", [])
    hashes_after = [pair for pair in member_hashes(cast) if pair[0] != PROBE]
    if len(hashes_after) != len(hashes_before):
        failures.append("a member was added or lost on the unnormalized copy")
    changed = [first[0] for first, second in zip(hashes_before, hashes_after) if first != second]
    # A hashChanged report is the validator saying nothing explains the change.
    explained = [text for text in exceptions if " hash changes from " not in text]
    unexplained = [name for name in changed if not any(text.startswith(name + ": ") for text in explained)]
    print(f"  unnormalized copy: Reparto had already written it: {'yes' if report.get('isNormalized') else 'no'}; "
          f"{len(hashes_before)} members, {len(hashes_before) - len(changed)} hashes unchanged, {len(changed)} changed: "
          f"{', '.join(changed) or 'none'}; SD-12 exceptions reported: {len(exceptions)}; unexplained: {len(unexplained)}")
    if unexplained:
        failures.append(f"hashes changed with no SD-12 exception: {', '.join(unexplained)}")

    if failures:
        row("item", "FAIL", f"4 FAIL: {'; '.join(failures)}")
    else:
        row("item", "PASS", f"4 PASS: create touched only its member; {len(changed)} of {len(hashes_before)} hashes changed, each one reported")


# Item 5 ---------------------------------------------------------------------------------------

def dump_package(path):
    done = run_quiet(["swift", "package", "--package-path", path, "dump-package"])
    return json.loads(done.stdout) if done.returncode == 0 else None


def target_closure(root_dump, target):
    """Every (package, target) `target` links, across packages, from the manifests. Or raises KeyError."""
    dumps = {root_dump["name"].lower(): root_dump}

    def dump_of(package):
        key = package.lower()
        if key not in dumps:
            checkout = package_checkout(package)
            dumps[key] = dump_package(checkout) if checkout else None
        if not dumps[key]:
            raise KeyError(package)
        return dumps[key]

    seen, stack = set(), [(root_dump["name"], target)]
    while stack:
        package, name = stack.pop()
        if (package.lower(), name) in seen:
            continue
        seen.add((package.lower(), name))
        dump = dump_of(package)
        declared = next(entry for entry in dump["targets"] if entry["name"] == name)
        for dependency in declared.get("dependencies", []):
            if "product" in dependency:
                product, other = dependency["product"][0], dependency["product"][1]
                found = next(entry for entry in dump_of(other)["products"] if entry["name"] == product)
                stack += [(other, item) for item in found["targets"]]
            elif "target" in dependency:
                stack.append((package, dependency["target"][0]))
            elif "byName" in dependency:
                by_name = dependency["byName"][0]
                if any(entry["name"] == by_name for entry in dump["targets"]):
                    stack.append((package, by_name))
                else:
                    stack.append((by_name, by_name))
    return seen


def link_options(obj):
    """What an object's LC_LINKER_OPTION commands ask the linker for, which is what `import` autolinks."""
    text = run_quiet(["otool", "-l", obj]).stdout
    return re.findall(r"^\s*string #\d+ (.+)$", text, re.MULTILINE)


def undefined_symbols(obj):
    return run_quiet(["nm", "-u", obj]).stdout


FORBIDDEN_OPTION = re.compile(r"^(Vision|ImageIO|.*ArgumentParser.*)$")
FORBIDDEN_SYMBOL = re.compile(r"6Vision|5ImageIO|14ArgumentParser|_CGImageSource|_CGImageDestination|_VN[A-Z]")


def item5():
    """
    Proves, for the Release objects `dossier` was built from: DossierCore's dependency closure
    in the manifests has no ArgumentParser; its objects neither autolink nor reference Vision,
    ImageIO or ArgumentParser; and those objects alone link into an executable whose load
    commands name none of them. Dossier.o and DossierCLICore.o must show the same evidence for
    what they do use, so the check can't pass by being blind. ImageIO may still be loaded
    indirectly by a system framework such as CoreGraphics, which no static check can rule out
    and which isn't DossierCore linking it.
    """
    print("item 5: what DossierCore links")
    failures = []
    root_dump = dump_package(ROOT)
    if not root_dump:
        row("item", "FAIL", "5 FAIL: swift package dump-package failed")
        return
    try:
        closure = target_closure(root_dump, "DossierCore")
    except (KeyError, StopIteration) as error:
        row("item", "FAIL", f"5 FAIL: couldn't read the dependency closure ({error})")
        return
    targets = sorted(name for _, name in closure)
    print(f"  manifest closure: {', '.join(targets)}")
    if any("argumentparser" in package or "argumentparser" in name.lower() for package, name in closure):
        failures.append("ArgumentParser is in the closure")

    objects = [os.path.join(BUILT, name + ".o") for name in targets]
    absent = [os.path.basename(path) for path in objects if not os.path.isfile(path)]
    if absent:
        row("item", "FAIL", f"5 FAIL: no object for {', '.join(absent)}")
        return
    options = [option for path in objects for option in link_options(path)]
    bad_options = sorted(option for option in set(options) if FORBIDDEN_OPTION.match(option))
    bad_symbols = sum(bool(FORBIDDEN_SYMBOL.search(undefined_symbols(path))) for path in objects)
    print(f"  autolink entries naming them: {', '.join(bad_options) or 'none'}; objects with undefined symbols from them: {bad_symbols}")
    if bad_options:
        failures.append("an object autolinks one")
    if bad_symbols:
        failures.append("an object references one")

    # The check has to be able to see what it looks for.
    control_options = link_options(os.path.join(BUILT, "Dossier.o"))
    control_symbols = undefined_symbols(os.path.join(BUILT, "DossierCLICore.o"))
    can_see = {"Vision", "ImageIO"} & set(control_options)
    print(f"  control: Dossier.o autolinks {', '.join(sorted(can_see)) or 'neither'}; "
          f"DossierCLICore.o references ArgumentParser: {'yes' if '14ArgumentParser' in control_symbols else 'no'}")
    if not can_see or "14ArgumentParser" not in control_symbols:
        failures.append("the controls show nothing, so this check is blind")

    source = os.path.join(WORK, "probe.swift")
    binary = os.path.join(WORK, "probe")
    with open(source, "w", encoding="utf-8") as file:
        file.write("print(\"linked\")\n")
    macos = next(entry["version"] for entry in root_dump["platforms"] if entry["platformName"] == "macos")
    # -profile-generate: xcodebuild instruments these objects, and they need that runtime.
    linked = run_quiet(["xcrun", "swiftc", "-profile-generate", "-target", f"arm64-apple-macos{macos}", source, *objects, "-o", binary])
    if linked.returncode != 0:
        print(f"  link of the closure's objects alone: failed (status {linked.returncode})")
        failures.append("the closure doesn't link on its own")
    else:
        libraries = run_quiet(["otool", "-L", binary]).stdout
        named = sorted({word for word in ("Vision", "ImageIO", "ArgumentParser") if word in libraries})
        print(f"  link of the closure's objects alone: succeeded; otool -L names of them: {', '.join(named) or 'none'}")
        if named:
            failures.append(f"the probe's load commands name {', '.join(named)}")

    if failures:
        row("item", "FAIL", f"5 FAIL: {'; '.join(failures)}")
    else:
        row("item", "PASS", "5 PASS: DossierCore's closure builds, links and loads without Vision, ImageIO or ArgumentParser")


# ----------------------------------------------------------------------------------------------

def main():
    print(f"acceptance: REF {os.environ['ACCEPT_REF']} at {os.environ['ACCEPT_COMMIT']}")
    reject_links_out_of_the_copy()
    cast = os.path.join(COPY, "CAST.md")
    members = []
    if os.path.isfile(cast):
        _, result = dossier("validate", "--cast", cast)
        members = (result or {}).get("members", [])
    members_ok = bool(members)

    pre_add_errors = item1(members, members_ok)
    item2(members, pre_add_errors)
    print("item 3 not run: rendering is phase 3")
    item4(members_ok)
    item5()

    bundles, items = rows["bundle"], rows["item"]
    pointers = bundles["SKIP(lfs pointer)"] + items["SKIP(lfs pointer)"]
    failed = bundles["FAIL"] + items["FAIL"] + pointers
    summary = (
        f"count: bundles {bundles['PASS']} PASS, {bundles['FAIL']} FAIL, {bundles['SKIP(lfs pointer)']} SKIP(lfs pointer); "
        f"items {items['PASS']} PASS, {items['FAIL']} FAIL, {items['SKIP(lfs pointer)']} SKIP(lfs pointer), {items['SKIP']} SKIP"
    )
    print(summary)
    if items["SKIP"] and not failed:
        print(f"acceptance: INCOMPLETE: {items['SKIP']} item skipped, see above")
    return 1 if failed else 0


sys.exit(main())
# PYTHON END
