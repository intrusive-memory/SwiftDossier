#!/usr/bin/env bash
# make acceptance PROJECT=<path> [REF=<git ref>] [REPARTO=<path>] [PAGES_OUT=<dir>]
#
# REQUIREMENTS §9 items 1 to 5 against a local project checkout. Not in CI (SD-4).
# Item 4's migrate half belongs to phase 4. Item 3 keeps the rendered pages in PAGES_OUT when set,
# which can't be inside PROJECT.
#
# The files on disk are the source of truth, so by default the project is taken as it is on disk:
# its tree goes into a temporary directory, hidden files included, .git skipped and links kept as
# links, never followed. REF=<ref> takes that commit instead, by `git archive`. The output says which
# (`source: disk`, or `source: ref <ref> at <sha>`). Every command runs on the copy, which is removed
# on exit, and a link leading out of the copy stops the run.
#
# The project is read and never written, apart from what Git LFS's own smudge keeps in its object
# cache under REF. Under REF, the one thing read from the working tree is item 2's .generations/, and
# only when REF doesn't hold it, which is usual since it's ignored; the output says when.
#
# Output holds names, roles, sizes, codes, counts and key names. Never a prompt, a description, a sidecar
# value or a tool's message, which can quote those.
#
# Exit status: 0 no failure, 1 a failure, 2 couldn't run, 64 a bad command line. A project that
# isn't there is 0 with a skip message.
set -euo pipefail

usage() {
  echo "usage: make acceptance PROJECT=<path> [REF=<git ref>] [REPARTO=<path>] [PAGES_OUT=<dir>]" >&2
  echo "  With no REF, the project as it is on disk (its tree, without .git). REF extracts that commit" >&2
  echo "  instead, and has no default. REPARTO defaults to the one on PATH, then to one built from the" >&2
  echo "  SwiftReparto this package resolves. PAGES_OUT keeps item 3's rendered pages." >&2
}
die() {
  echo "acceptance: $*" >&2
  exit 2
}

PROJECT="${1:-}"
REF="${2:-}"

if [ -z "$PROJECT" ]; then
  usage
  exit 64
fi
if [ ! -d "$PROJECT" ]; then
  echo "acceptance: SKIP: no project at $PROJECT (SD-4). Nothing was run."
  exit 0
fi

# Item 3 writes here, and nothing writes to the project: judged by the nearest directory that
# exists, before anything is made.
if [ -n "${PAGES_OUT:-}" ]; then
  EXISTING="$PAGES_OUT"
  while [ ! -d "$EXISTING" ]; do EXISTING="$(dirname "$EXISTING")"; done
  case "$(cd "$EXISTING" && pwd -P)/" in
    "$(cd "$PROJECT" && pwd -P)"/*) die "PAGES_OUT is inside PROJECT, which is never written" ;;
  esac
  mkdir -p "$PAGES_OUT" || die "can't make PAGES_OUT"
fi

COMMIT=""
if [ -n "$REF" ]; then
  export GIT_OPTIONAL_LOCKS=0
  git -C "$PROJECT" rev-parse --git-dir >/dev/null 2>&1 || die "$PROJECT isn't a git repository"
  COMMIT="$(git -C "$PROJECT" rev-parse --verify --quiet "$REF^{commit}")" || die "no ref $REF in $PROJECT"
fi

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# Copying a tree into itself wouldn't end, and would write to the project.
case "$(cd "$WORK" && pwd -P)/" in
  "$(cd "$PROJECT" && pwd -P)"/*) die "the temporary directory is inside PROJECT, which is never written" ;;
esac

mkdir "$WORK/copy"
if [ -n "$REF" ]; then
  git -C "$PROJECT" archive "$COMMIT" 2>"$WORK/archive.log" | tar -xf - -C "$WORK/copy" \
    || die "git archive of $REF failed. If Git LFS is in use, its objects may not be fetched."
fi

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

# The Python below is given the copy, and the project only to read from: its tree with no REF, and
# .generations/ with one.
ACCEPT_ROOT="$ROOT" ACCEPT_WORK="$WORK" ACCEPT_BUILT="$BUILT" ACCEPT_REF="$REF" \
  ACCEPT_COMMIT="$COMMIT" ACCEPT_REPARTO="${REPARTO:-}" ACCEPT_READ_ONLY_SOURCE="$PROJECT" \
  ACCEPT_PAGES_OUT="${PAGES_OUT:-}" \
  python3 -I -c "$(sed -n '/^# PYTHON BEGIN$/,/^# PYTHON END$/p' "${BASH_SOURCE[0]}")"
exit $?

# PYTHON BEGIN
import collections, ctypes, datetime, difflib, hashlib, json, os, re, shutil, stat, subprocess, sys

ROOT = os.environ["ACCEPT_ROOT"]
WORK = os.environ["ACCEPT_WORK"]
COPY = os.path.join(WORK, "copy")
BUILT = os.environ["ACCEPT_BUILT"]
READ_ONLY_SOURCE = os.environ["ACCEPT_READ_ONLY_SOURCE"]
REF = os.environ["ACCEPT_REF"]  # Empty when the source is the disk.
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


def clone_or_copy(source, target):
    """A copy-on-write clone where the volume has them, so a large tree costs little and the two
    never share a change. Otherwise the bytes, with the file's times and mode."""
    try:
        if ctypes.CDLL(None).clonefile(os.fsencode(source), os.fsencode(target), 0) == 0:
            return
    except (AttributeError, OSError):
        pass
    shutil.copy2(source, target, follow_symlinks=False)


def copy_project_from_disk():
    """The project's tree as it is now, into the copy, reading only. `.git` is skipped at any depth,
    as a submodule has one too, and a link stays a link, so nothing outside the tree is read.
    Returns (files, links, others skipped: a FIFO or socket isn't a file a bundle can hold)."""
    def stop(error):
        raise error

    copied, links, others = 0, 0, 0
    for directory, names, files in os.walk(READ_ONLY_SOURCE, onerror=stop):
        names[:] = [name for name in names if name != ".git"]
        relative = os.path.relpath(directory, READ_ONLY_SOURCE)
        for name in names + files:
            if name == ".git":
                continue
            source = os.path.join(directory, name)
            target = os.path.normpath(os.path.join(COPY, relative, name))
            mode = os.lstat(source).st_mode
            if stat.S_ISLNK(mode):
                os.symlink(os.readlink(source), target)
                links += 1
            elif stat.S_ISDIR(mode):
                os.mkdir(target)
            elif stat.S_ISREG(mode):
                clone_or_copy(source, target)
                copied += 1
            else:
                others += 1
    return copied, links, others


def reject_links_out_of_the_copy():
    """Every write below goes through a path in the copy. A link could lead it away."""
    for directory, names, files in os.walk(COPY):
        for name in names + files:
            path = os.path.join(directory, name)
            if os.path.islink(path) and not inside_copy(path):
                print("acceptance: a link leads out of the copy. Nothing was run.", file=sys.stderr)
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
        # Before the skip below: item 2 counts only the errors its add introduces.
        pre_add_errors[name] = errors
        pointers = sum(is_lfs_pointer(path) for path in files_under(bundle))
        pointers_total += pointers
        if pointers:
            row("bundle", "SKIP(lfs pointer)",
                f"{name}  SKIP(lfs pointer)  {pointers} files are LFS pointers, so their hashes can't be "
                f"checked  manifest-v2: {schema}")
            skipped += 1
            continue
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
    """.generations/ is normally ignored, so REF lacks it. Copies PNGs that have a sidecar, reading only.
    With the disk as the source the copy already has it, so this is only for REF."""
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


def stripped_sha256(path):
    """The hash `dossier add` stores for a PNG (SD-6): without its metadata chunks, or None if malformed."""
    with open(path, "rb") as file:
        data = file.read()
    if data[:8] != b"\x89PNG\r\n\x1a\n":
        return None
    kept, offset = [data[:8]], 8
    while offset + 12 <= len(data):
        end = offset + 12 + int.from_bytes(data[offset:offset + 4], "big")
        kind = data[offset + 4:offset + 8]
        if kind not in (b"tEXt", b"zTXt", b"iTXt", b"eXIf", b"tIME"):
            kept.append(data[offset:end])
        offset = end
        if kind == b"IEND":
            return hashlib.sha256(b"".join(kept)).hexdigest() if offset == len(data) else None
    return None


def current_selection(manifest, role):
    """The path of the selected asset a reference's role names (§6), or None."""
    kind, _, variant = role.partition(":") if isinstance(role, str) else ("", "", "")
    for asset in manifest.get("assets", []):
        if asset.get("status") == "selected" and asset.get("kind") == kind and asset.get("variant") == (variant or None):
            return asset.get("path")
    return None


def same_time(first, second):
    try:
        parse = lambda text: datetime.datetime.fromisoformat(text.replace("Z", "+00:00"))
        return parse(first) == parse(second)
    except (AttributeError, TypeError, ValueError):
        return False


def item2(members, pre_add_errors):
    """`dossier add` of a view and its sidecar. Writes to the copy only, which the choice checks."""
    print("item 2: dossier add of a view with its sidecar")
    origin = "REF" if REF else "disk"
    chosen, pointer_files, unusable = choose_candidate(members)
    if REF and not chosen and not pointer_files:
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
    # Named for the bytes it will have: a PNG loses its metadata as it's copied in (SD-6).
    destination = f"images/view-{variant}-{(stripped_sha256(candidate['path']) or sha256_of(candidate['path']))[:8]}.png"
    if any(asset.get("path") == destination for asset in read_json(manifest_path).get("assets", [])):
        status, result = dossier("remove", bundle, destination, "--yes")
        if status != 0:
            row("item", "FAIL", f"2 FAIL: the view is already in the bundle, and remove failed ({error_code(result)})")
            return
        print("  the view was already in the bundle, so it was removed from the copy first")

    before = read_json(manifest_path)
    hashes = asset_hashes(before)
    references = sidecar_references(sidecar)
    # §7 refuses a role with no selection when its bytes aren't in the bundle, so only those it has.
    roles = [role for role in ("portrait", "face") if current_selection(before, role)][: len(references)]
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
    matched, at_selection, wrong_path, by_kind = 0, 0, 0, collections.Counter()
    if len(recorded) != len(references):
        failures.append("the number of references changed")
    for original, entry in zip(references, recorded):
        assets = hashes.get(original["sha256"], [])
        if entry.get("sha256") != original["sha256"]:
            failures.append("a reference's sha256 changed")
        if assets:
            matched += 1
            if entry.get("path") not in [asset.get("path") for asset in assets]:
                wrong_path += 1
            for kind in {asset.get("kind") for asset in assets} & {"portrait", "face"}:
                by_kind[kind] += 1
        elif "path" not in original:
            selection = current_selection(before, entry.get("role"))
            if entry.get("path") != selection:
                wrong_path += 1
            elif selection:
                at_selection += 1
    print(f"  references: {len(recorded)}; hashes matching an asset: {matched}; "
          f"recorded with the current selection's path: {at_selection}; "
          f"mapped to a portrait: {by_kind['portrait']}; mapped to a face: {by_kind['face']}")
    print(f"  face mapping occurred: {'yes' if by_kind['face'] else 'no'}")
    if recorded and not matched:
        print("  0 hashes match: a stripped portrait's hash won't match a reference taken from an unstripped copy")
    if wrong_path:
        failures.append(f"{wrong_path} references have the wrong path")

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
        row("item", "PASS",
            f"2 PASS: {name}, every SD-7 key recorded, {matched} of {len(recorded)} reference hashes match and are mapped, "
            f"{at_selection} recorded with the current selection's path, face mapping: {'yes' if by_kind['face'] else 'no'}")


# Item 3 ---------------------------------------------------------------------------------------

LEAD_TARGET = 3_000_000  # DF-53: a "should".
PAGE_LIMIT = 10_000_000  # W-PAGE-SIZE.


def prepare_item3():
    """A copy of the copy made before item 2 changes it, so the pages are of the source's bundles."""
    target = os.path.join(WORK, "item3-copy")
    shutil.copytree(COPY, target, symlinks=True, copy_function=clone_or_copy)
    return target


def page_text_check(page, description):
    """Each list item, paragraph and quote of CHARACTER.md's body, whole in one element of the page:
    what a person reads, against what was written, by template rule 3. A quote is looked for in the
    <blockquote>s, and everything else in the other elements, with those quotes taken out.

    Returns (blocks, blocks not whole, literal ** shown, literal --- shown, literal leading > shown).
    The last two leave out what the source itself has as text: `- > x`, `> > x`, `- ---`, `> ---`."""
    import html
    import re
    def plain(text):
        text = re.sub(r"\[\^[^\]]+\]", "", text).replace("*", "")
        return " ".join(html.unescape(text).split())
    with open(description, encoding="utf-8") as handle:
        body = handle.read().split("---\n", 2)[-1]
    found, current, open_kind = [], None, None  # open_kind: "text", or "quote" when a line continues one.
    written_rules, written_quotes = 0, 0
    def note(text):
        nonlocal written_rules, written_quotes
        written_rules += text == "---"
        written_quotes += text.startswith(">")
    def close():
        nonlocal current, open_kind
        if current is not None:
            found.append((open_kind, current))
        current, open_kind = None, None
    for line in body.split("\n"):
        stripped = line.strip(" ")
        if re.match(r" {0,3}\[\^[^\]]+\]:", line) or line.startswith("#") or not line.strip() or stripped == "---":
            close()
        elif line.startswith("- "):
            close()
            current, open_kind = line[2:], "text"
            note(current.strip())
        elif stripped.startswith(">"):
            content = stripped[1:].strip()
            note(content)
            if open_kind == "quote":
                current += " " + content
            else:
                close()
                current, open_kind = content, "quote"
        elif current is not None:
            current += " " + line.strip()
        else:
            current, open_kind = line.strip(), "text"
    close()
    with open(page, encoding="utf-8") as handle:
        document = handle.read()
    document = re.sub(r"<script.*?</script>|<style.*?</style>", "", document, flags=re.S)
    document = re.sub(r'<sup class="mark">.*?</sup>', "", document, flags=re.S)
    quote_element = r"<blockquote[^>]*>(.*?)</blockquote>"
    quotes = re.findall(quote_element, document, flags=re.S)
    document = re.sub(quote_element, "", document, flags=re.S)
    without_tags = lambda inner: re.sub(r"<[^>]+>", "", inner)
    shown = [plain(without_tags(inner)) for inner in re.findall(r"<(?:li|p|span)[^>]*>(.*?)</(?:li|p|span)>", document, flags=re.S)]
    shown_quotes = [plain(without_tags(inner)) for inner in quotes]
    blocks = [(kind, plain(block)) for kind, block in found if plain(block)]
    lost = 0
    for kind, block in blocks:
        pool = shown_quotes if kind == "quote" else shown
        lost += block not in pool and not any(block in text for text in pool)
    read = [without_tags(inner) for inner in re.findall(r"<(?:li|p)[^>]*>(.*?)</(?:li|p)>", document, flags=re.S)] + [without_tags(inner) for inner in quotes]
    literal = sum(text.count("**") for text in read)
    read_lines = [line.strip() for text in read for line in html.unescape(text).split("\n")]
    rules = max(0, sum(line == "---" for line in read_lines) - written_rules)
    leading = max(0, sum(line.startswith(">") for line in read_lines) - written_quotes)
    return len(blocks), lost, literal, rules, leading


def item3(members, members_ok, copy):
    """Each member's bundle rendered twice on its own scratch copy, and validated after."""
    print("item 3: render every member's bundle, twice")
    if not members_ok:
        row("item", "FAIL", "3 FAIL: CAST.md can't be read, or lists no members")
        return
    pages_out = os.environ.get("ACCEPT_PAGES_OUT", "")
    cast = os.path.join(copy, "CAST.md")
    with_bundle = [member for member in members if member["manifest"]]
    failed, pointers, over_target = 0, 0, 0
    for member in with_bundle:
        name = member["character"]
        if not inside_copy(member["manifest"]):
            print(f"  {name}  FAIL  its manifest: leaves the project")
            failed += 1
            continue
        bundle = os.path.dirname(os.path.join(copy, os.path.relpath(member["manifest"], COPY)))
        if any(is_lfs_pointer(path) for path in files_under(bundle)):
            print(f"  {name}  SKIP(lfs pointer)")
            pointers += 1
            continue
        _, before = dossier("validate", bundle, "--cast", cast)
        status, result = dossier("render", bundle, "--cast", cast)
        if status != 0 or not result or "page" not in result:
            print(f"  {name}  FAIL  render failed ({error_code(result)})")
            failed += 1
            continue
        page = result["page"]
        first = sha256_of(page)
        status, again = dossier("render", bundle, "--cast", cast)
        same = status == 0 and sha256_of(page) == first
        size = os.path.getsize(page)
        role = result.get("role")
        _, after = dossier("validate", bundle, "--cast", cast)
        new_errors = codes(after, "error") - codes(before, "error")
        problems = []
        if not same:
            problems.append("the second render differs" if status == 0 else f"the second render failed ({error_code(again)})")
        if new_errors:
            problems.append(f"new errors: {counted(new_errors)}")
        if size > PAGE_LIMIT:
            problems.append(f"OVER 10 MB (W-PAGE-SIZE, limit {PAGE_LIMIT})")
        notes = ""
        if role == "lead":
            if size > LEAD_TARGET:
                over_target += 1
                notes = f"  OVER 3 MB TARGET (DF-53, {LEAD_TARGET})"
            else:
                notes = f"  within the 3 MB target (DF-53, {LEAD_TARGET})"
        blocks, lost, literal, rules, leading = page_text_check(page, os.path.join(bundle, "CHARACTER.md"))
        notes += f"  text: {blocks - lost} of {blocks} source blocks whole, literal ** {literal}, literal --- {rules}, literal leading > {leading}"
        if lost:
            problems.append(f"{lost} source blocks aren't whole in one element")
        if rules:
            problems.append(f"{rules} literal --- shown")
        if leading:
            problems.append(f"{leading} literal leading > shown")
        print(f"  {name}  {size} bytes  role {role or 'none'}{notes}  {'FAIL  ' + '; '.join(problems) if problems else 'PASS'}")
        failed += bool(problems)
        if pages_out:
            shutil.copyfile(page, os.path.join(pages_out, os.path.basename(page)))

    if pages_out:
        print(f"  rendered pages kept in {pages_out}")
    summary = f"{len(with_bundle)} bundles, {failed} failed, {over_target} leads over the 3 MB target, which doesn't fail this item"
    if not with_bundle:
        row("item", "FAIL", "3 FAIL: no member has a bundle, so nothing was rendered")
    elif pointers:
        row("item", "SKIP(lfs pointer)", f"3 SKIP(lfs pointer): {pointers} of {len(with_bundle)} bundles hold LFS pointers, a failure of this check")
    else:
        verdict = "FAIL" if failed else "PASS"
        row("item", verdict, f"3 {verdict}: {summary}")


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

    # As the source has it: every member keeps its §7 hash, except what SD-12 reports.
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
    linked = run_quiet(["xcrun", "swiftc", "-target", f"arm64-apple-macos{macos}", source, *objects, "-o", binary])
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
    if REF:
        print(f"acceptance: source: ref {REF} at {os.environ['ACCEPT_COMMIT']}")
    else:
        try:
            copied, links, others = copy_project_from_disk()
        except OSError as error:
            print(f"acceptance: couldn't copy the project: {type(error).__name__} on {error.filename}. Nothing was run.",
                  file=sys.stderr)
            sys.exit(2)
        print(f"acceptance: source: disk ({copied} files, {links} links, {others} special files skipped; .git left out)")
    reject_links_out_of_the_copy()
    cast = os.path.join(COPY, "CAST.md")
    members = []
    if os.path.isfile(cast):
        _, result = dossier("validate", "--cast", cast)
        members = (result or {}).get("members", [])
    members_ok = bool(members)

    pre_add_errors = item1(members, members_ok)
    item3_copy = prepare_item3()
    item2(members, pre_add_errors)
    item3(members, members_ok, item3_copy)
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
