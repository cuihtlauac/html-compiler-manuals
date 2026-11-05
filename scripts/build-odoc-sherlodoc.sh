#!/usr/bin/env bash
# Build native odoc HTML + client-side sherlodoc search AND the .html.json
# fragment tree (the format ocaml-docs-ci emits and ocaml.org consumes) for one
# OCaml minor release, verify the fragments parse with ocaml.org's own reader,
# and package the result as a tarball.
#
# Usage: scripts/build-odoc-sherlodoc.sh <minor> [outdir]
#   <minor>   OCaml minor version, e.g. 5.3  (floor is 5.3 — the odoc toolchain
#             does not support older compilers)
#   [outdir]  HTML output directory (default: _out)
#
# Switch: SWITCH_DIR (default: _switch) names a local opam switch directory.
#   - If $SWITCH_DIR/_opam does not exist, the script resolves <minor> to the
#     newest compiler release and creates the switch itself (local use).
#   - If it exists, it is reused (e.g. a re-run, or a switch from elsewhere):
#     its compiler must be <minor>.x, and the doc tools are installed into it.
#
# Generalized from the verified prototype prototypes/sherlodoc/reproduce_v2.sh.
# One `odoc_driver` run emits both halves; see that script and its README for the
# provenance. Consumer-side RFC: ocaml/ocaml.org#3909, CI companion: issue #14.
set -euo pipefail

if [ "$#" -lt 1 ]; then
  echo "usage: $0 <minor> [outdir]" >&2
  exit 2
fi

MINOR="$1"
OUTDIR="${2:-_out}"

# Repo root, so ci/doccheck and the tarball land in predictable places
# regardless of the caller's cwd.
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

SWITCH_DIR="${SWITCH_DIR:-$REPO_ROOT/_switch}"
TARBALL="${TARBALL:-$REPO_ROOT/ocaml-$MINOR-odoc-sherlodoc-html.tar.gz}"

# yojson + dune are what ci/doccheck needs; listed explicitly rather than relied
# upon as transitive deps of odoc-driver (which pulls odoc, sherlodoc, odoc-md).
TOOLS=(odoc-driver yojson dune)

if [ -d "$SWITCH_DIR/_opam" ]; then
  # 1+2 (reuse). Existing switch: check it really
  #    is <minor>, then make sure the doc tools are in it.
  # opam pinned to $SWITCH_DIR (see the OPAMSWITCH gotcha below)
  in_switch() { env -u OPAM_SWITCH_PREFIX OPAMSWITCH="$SWITCH_DIR" opam "$@"; }
  HAVE="$(in_switch exec -- ocamlc -version)"
  case "$HAVE" in
    "$MINOR".*) ;;
    *) echo "ERROR: switch $SWITCH_DIR has OCaml $HAVE, expected $MINOR.x" >&2
       exit 1 ;;
  esac
  echo ">> OCaml $MINOR -> existing switch $SWITCH_DIR (OCaml $HAVE)"
  in_switch install -y "${TOOLS[@]}"
else
  # 1. Resolve <minor> to a concrete compiler package. opam needs an exact version
  #    (`5.3` is not a package version). Prefer the newest released
  #    ocaml-base-compiler patch for this minor; fall back to ocaml-variants.
  #    Final releases win over ~alpha/~beta/~rc; a prerelease is only picked when
  #    the minor has no final release yet. (GNU sort -V orders 5.5.0~rc1 < 5.5.0.)
  pick_newest() {
    local all finals
    all="$(tr ' ' '\n' | grep -E "^${MINOR//./\\.}\\." || true)"
    finals="$(printf '%s\n' "$all" | grep -v '~' || true)"
    if [ -n "$finals" ]; then printf '%s\n' "$finals"; else printf '%s\n' "$all"; fi \
      | grep -v '^$' | sort -V | tail -n1
  }

  BASE_VERSIONS="$(opam show -f all-versions ocaml-base-compiler 2>/dev/null || true)"
  COMPILER_VERSION="$(printf '%s' "$BASE_VERSIONS" | pick_newest || true)"
  COMPILER_PKG=""
  if [ -n "$COMPILER_VERSION" ]; then
    COMPILER_PKG="ocaml-base-compiler.$COMPILER_VERSION"
  else
    VARIANT_VERSIONS="$(opam show -f all-versions ocaml-variants 2>/dev/null || true)"
    COMPILER_VERSION="$(printf '%s' "$VARIANT_VERSIONS" | pick_newest || true)"
    if [ -n "$COMPILER_VERSION" ]; then
      COMPILER_PKG="ocaml-variants.$COMPILER_VERSION"
    fi
  fi

  if [ -z "$COMPILER_PKG" ]; then
    echo "ERROR: no ocaml-base-compiler or ocaml-variants package for OCaml $MINOR" \
         "found in the current opam repositories." >&2
    echo "       (A manual/ dir can exist here before the compiler is released on" \
         "opam; that version cannot get odoc docs yet.)" >&2
    exit 1
  fi
  echo ">> OCaml $MINOR -> $COMPILER_PKG"

  # 2. Isolated switch.
  mkdir -p "$SWITCH_DIR"
  opam switch create "$SWITCH_DIR" "$COMPILER_PKG" "${TOOLS[@]}" -y
fi

# GOTCHA (from reproduce_v2.sh): pin the switch via OPAMSWITCH, not
# `opam exec --switch` alone. `opam exec --switch=` puts the switch's binaries on
# PATH but does NOT override an inherited OPAMSWITCH/OPAM_SWITCH_PREFIX (e.g. set
# by direnv). odoc_driver makes its own opam queries, which then resolve the
# WRONG switch: odoc reads another compiler's .cmt files and crashes in
# Cmt_format.read (magic mismatch) under `odoc classify`.
export OPAMSWITCH="$SWITCH_DIR"
unset OPAM_SWITCH_PREFIX
RUN() { opam exec -- "$@"; }

# Record the toolchain: the .html.json format is unstable, so consumers need to
# know which odoc produced a given artifact. Written next to the tarball (the
# workflow puts it in the release notes) and echoed to the log.
TOOLCHAIN_FILE="${TOOLCHAIN_FILE:-$REPO_ROOT/ocaml-$MINOR-toolchain.txt}"
RUN opam list --columns=name,installed-version --short \
  ocaml-base-compiler ocaml-variants odoc odoc-driver odoc-md sherlodoc yojson 2>/dev/null \
  | awk 'NF==2 && $2!="--"' > "$TOOLCHAIN_FILE"
echo ">> toolchain:"; sed 's/^/   /' "$TOOLCHAIN_FILE"

# 3. The whole pipeline in one command: odoc for every package in the switch
#    (`ocaml` selects its dependency closure; the real content lands under
#    ocaml-compiler/<library>/), sherlodoc DBs, search assets wired in the
#    correct order. --json-output additionally emits one .html.json per page
#    plus per-package sidebar.json and status.json.
rm -rf "$OUTDIR"
RUN odoc_driver ocaml --json-output --html-dir "$OUTDIR"

N_HTML="$(find "$OUTDIR" -name '*.html' | wc -l)"
N_JSON="$(find "$OUTDIR" -name '*.html.json' | wc -l)"
echo ">> pages (html):      $N_HTML"
echo ">> pages (html.json): $N_JSON"

# 4. Parser-fidelity check: ci/doccheck/check.ml is a verbatim copy of
#    doc_from_string and helpers from ocaml.org. Every .html.json must parse, or
#    the exit status is non-zero. (See ci/doccheck/README.md for lockstep rules.)
RUN dune build --root ci/doccheck
find "$OUTDIR" -name '*.html.json' -print0 \
  | xargs -0 ci/doccheck/_build/default/check.exe

# 5. Package the standalone tree (both halves plus search assets).
tar czf "$TARBALL" -C "$OUTDIR" .
echo ">> wrote $TARBALL"
