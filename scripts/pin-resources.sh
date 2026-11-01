#!/bin/sh
# Regenerates the pinned resource copies and their PINNED.sha256 hash lists
# from .dossier-format/ (run `make fixtures` first). The ref is read from the
# Makefile, the only place it is defined.
set -eu
cd "$(dirname "$0")/.."
REF=$(sed -n 's/^DOSSIER_FORMAT_REF = //p' Makefile)
SRC=.dossier-format
test -d "$SRC" || { echo "run 'make fixtures' first" >&2; exit 1; }

DOSSIER_RES=Sources/Dossier/Resources
SCHEMAS=$DOSSIER_RES/schemas
DATA=Sources/DossierCore/Resources
mkdir -p "$SCHEMAS" "$DATA"

rm -f "$SCHEMAS"/*.json
cp "$SRC"/schemas/*.json "$SCHEMAS"/
cp "$SRC"/data/tiers.json "$SRC"/data/review.json "$DATA"/

# Resources/PINNED.sha256 lists "<sha256>  <path relative to Resources/>" and
# opens with a comment naming the ref.
write_pins() {
  dir=$1
  shift
  {
    echo "# dossier-format $REF"
    (cd "$dir" && shasum -a 256 "$@")
  } > "$dir/PINNED.sha256"
}
write_pins "$DOSSIER_RES" $(cd "$DOSSIER_RES" && ls schemas/*.json)
write_pins "$DATA" tiers.json review.json
echo "Pinned resources regenerated for $REF"
