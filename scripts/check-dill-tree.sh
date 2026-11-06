#!/usr/bin/env bash
# Check a tree produced by make-dill-tree.sh against what ocaml.org reads from
# dill for a package (src/ocamlorg_package/lib/documentation.ml and
# src/ocamlorg_frontend/layouts/package_layout.eml):
#   - status.json has name/version/files/failed/redirections; files exist;
#   - doc/index.js is `let documents = [...]` + the Fuse trailer, every entry
#     has name/prefixname/kind/url/comment, every url is under
#     /p/<pkg>/<ver>/doc/ and resolves to a file in the tree;
#   - doc/sidebar.json urls are under p/<pkg>/<ver>/doc/ and resolve.
# .html.json pages are checked separately by ci/doccheck.
#
# Usage: scripts/check-dill-tree.sh <dill_dir>
set -euo pipefail

DILL_DIR="${1:?usage: $0 <dill_dir>}"
fail=0
err() { echo "FAIL $*"; fail=1; }

# Resolve a url (leading "/" optional, "#frag" dropped) relative to DILL_DIR.
missing_urls() { sed -e 's#^/##' -e 's/#.*$//' | sort -u | while IFS= read -r u; do
  [ -e "$DILL_DIR/$u" ] || echo "$u"; done; }

n_pkgs=0
for dst in "$DILL_DIR"/p/*/*; do
  [ -d "$dst" ] || continue
  n_pkgs=$((n_pkgs + 1))
  ver="$(basename "$dst")"; pkg="$(basename "$(dirname "$dst")")"
  prefix="p/$pkg/$ver/doc/"
  tag="p/$pkg/$ver"

  # status.json
  s="$dst/status.json"
  jq -e --arg p "$pkg" --arg v "$ver" '
      .name == $p and .version == $v and (.files | type) == "array"
      and (.failed | type) == "boolean" and (.redirections | type) == "array"' \
    "$s" >/dev/null || err "$tag/status.json: bad shape"
  m="$(jq -r '.files[]' "$s" | sed "s#^#$tag/#" | missing_urls | awk 'NR<=3')"
  [ -z "$m" ] || err "$tag/status.json: missing files: $m"

  # index.js
  ix="$dst/doc/index.js"
  [ -f "$ix" ] || { err "$tag: no doc/index.js"; continue; }
  head -c 17 "$ix" | grep -qx 'let documents = \[' || err "$tag/doc/index.js: bad header"
  tail -n 2 "$ix" | grep -q '^var idx_fuse = new Fuse(documents, options);$' \
    || err "$tag/doc/index.js: bad trailer"
  # odoc writes the whole array on line 1: `let documents = [...];`
  docs="$(head -n 1 "$ix" | sed -e 's/^let documents = //' -e 's/;$//')"
  n="$(jq -e 'length' <<<"$docs" 2>/dev/null)" || { err "$tag/doc/index.js: array is not JSON"; continue; }
  bad="$(jq -r '
      map(select((has("name") and has("prefixname") and has("kind") and has("url")
                  and has("comment")) | not)) | length' <<<"$docs")"
  [ "$bad" = 0 ] || err "$tag/doc/index.js: $bad entries lack a field"
  out="$(jq -r --arg pre "/$prefix" '.[].url | select(startswith($pre) | not)' <<<"$docs" | awk 'NR<=3')"
  [ -z "$out" ] || err "$tag/doc/index.js: urls outside /$prefix: $out"
  # Warning only: odoc's own index lists some modules that it renders inline on
  # the parent page (e.g. aliases) rather than on a page of their own, so a few
  # urls dangle. That comes from `odoc compile-index` (the same command docs-ci
  # runs), not from this repo's url rewriting.
  m="$(jq -r '.[].url' <<<"$docs" | missing_urls)"
  [ -z "$m" ] || echo "WARN $tag/doc/index.js: $(wc -l <<<"$m") urls without a page," \
    "e.g. $(awk 'NR==1' <<<"$m")"

  # sidebar.json
  sb="$dst/doc/sidebar.json"
  urls="$(jq -r '.. | objects | .url? | strings' "$sb")"
  out="$(grep -v "^$prefix" <<<"$urls" | awk 'NR<=3' || true)"
  [ -z "$out" ] || err "$tag/doc/sidebar.json: urls outside $prefix: $out"
  m="$(missing_urls <<<"$urls" | awk 'NR<=3')"
  [ -z "$m" ] || err "$tag/doc/sidebar.json: dangling urls: $m"

  echo "ok   $tag: index.js $n entries, sidebar $(wc -l <<<"$urls") urls"
done

[ "$n_pkgs" -gt 0 ] || err "no p/<pkg>/<ver> directories in $DILL_DIR"
exit "$fail"
