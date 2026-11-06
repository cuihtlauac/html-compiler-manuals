#!/usr/bin/env bash
# Lay out odoc_driver output the way dill (the ocaml-docs-ci file server that
# ocaml.org reads package docs from) exposes each package:
#
#   p/<pkg>/<ver>/status.json        files/redirections paths prefixed "doc/"
#   p/<pkg>/<ver>/doc/sidebar.json   urls "p/<pkg>/<ver>/doc/..."
#   p/<pkg>/<ver>/doc/index.js       in-package search index (MiniSearch on
#                                    ocaml.org), urls "/p/<pkg>/<ver>/doc/..."
#   p/<pkg>/<ver>/doc/**             pages (.html, .html.json), sherlodoc_db.js
#
# index.js is produced exactly as odoc_driver_voodoo (the driver docs-ci uses)
# does it: `odoc compile-index --json --simplified-json --wrap-json` over the
# package's .odocl directory. The main odoc_driver hard-codes this off, hence
# this extra step. URL prefixes are rewritten to dill's form because
# odoc_driver roots each package at <pkg>/ instead of p/<pkg>/<ver>/doc/.
#
# Usage: scripts/make-dill-tree.sh <html_dir> <odocl_dir> <dill_dir>
#   Needs `odoc` (same version that produced <odocl_dir>) and `jq` on PATH.
set -euo pipefail

if [ "$#" -ne 3 ]; then
  echo "usage: $0 <html_dir> <odocl_dir> <dill_dir>" >&2
  exit 2
fi
HTML_DIR="$1"; ODOCL_DIR="$2"; DILL_DIR="$3"
OCC="$ODOCL_DIR/occurrences-all.odoc-occurrences"
[ -f "$OCC" ] || { echo "ERROR: $OCC missing (was --odocl-dir passed?)" >&2; exit 1; }

rm -rf "$DILL_DIR"
for status in "$HTML_DIR"/*/status.json; do
  src="$(dirname "$status")"
  pkg_dir="$(basename "$src")"
  pkg="$(jq -r .name "$status")"
  ver="$(jq -r .version "$status")"
  [ "$pkg" = "$pkg_dir" ] || { echo "ERROR: $status names $pkg" >&2; exit 1; }
  dst="$DILL_DIR/p/$pkg/$ver"
  mkdir -p "$dst/doc"

  # Pages and per-package assets, as dill serves them under doc/.
  cp -a "$src/." "$dst/doc/"
  rm "$dst/doc/status.json"

  # status.json: same fields as dill; paths are relative to p/<pkg>/<ver>/.
  jq '.files |= map("doc/" + .)
      | .redirections |= map(.old_path |= "doc/" + . | .new_path |= "doc/" + .)' \
    "$status" > "$dst/status.json"

  # sidebar.json: odoc_driver writes "<pkg>/..." urls; dill has "p/<pkg>/<ver>/doc/...".
  jq -c --arg from "$pkg/" --arg to "p/$pkg/$ver/doc/" '
    walk(if type == "object" and (.url | type) == "string"
           and (.url | startswith($from))
         then .url |= $to + ltrimstr($from) else . end)' \
    "$src/sidebar.json" > "$dst/doc/sidebar.json"

  # index.js, then the same url rewrite ("/<pkg>/..." -> "/p/<pkg>/<ver>/doc/...").
  odoc compile-index --json --simplified-json --wrap-json \
    -o "$dst/doc/index.js" --root "$ODOCL_DIR/$pkg" --occurrences "$OCC"
  sed -i "s#\"url\":\"/$pkg/#\"url\":\"/p/$pkg/$ver/doc/#g" "$dst/doc/index.js"

  echo ">> dill: p/$pkg/$ver ($(jq '.files | length' "$dst/status.json") files)"
done
