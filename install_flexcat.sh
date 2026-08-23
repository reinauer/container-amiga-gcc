#!/usr/bin/env bash
set -euo pipefail

# The adtools upstream is unmaintained and its last tag (2.18) predates
# the Linux/host build fixes in the AmigaPorts fork. The pinned commit
# is AmigaPorts master plus the host build fixes proposed as
# AmigaPorts/flexcat#4; repoint to AmigaPorts once that PR merges.
FLEXCAT_REPO="https://github.com/codewiz/flexcat.git"
FLEXCAT_COMMIT="91783ef24c45af01bbc0efd9409e71a655e3585b"

usage() {
  echo "Usage: $0 PREFIX" >&2
  exit 2
}

[[ $# -eq 1 ]] || usage

prefix="$1"
workdir="$(mktemp -d "${TMPDIR:-/tmp}/flexcat.XXXXXX")"
trap 'rm -rf "$workdir"' EXIT
make_args=(OS=unix CC="${CC:-cc}" DEBUG= DEBUGSYM=)

echo "Building FlexCat ${FLEXCAT_COMMIT} for the host"
git init --quiet "${workdir}/flexcat"
git -C "${workdir}/flexcat" fetch --quiet --depth 1 \
  "$FLEXCAT_REPO" "$FLEXCAT_COMMIT"
git -C "${workdir}/flexcat" -c advice.detachedHead=false \
  checkout --quiet FETCH_HEAD
make -C "${workdir}/flexcat/src" "${make_args[@]}" bootstrap
make -C "${workdir}/flexcat/src" "${make_args[@]}"

mkdir -p "${prefix}/bin"
install -m 755 "${workdir}/flexcat/src/bin_unix/flexcat" \
  "${prefix}/bin/flexcat"
