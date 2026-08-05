#!/usr/bin/env bash
set -euo pipefail

FLEXCAT_VERSION="2.18"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

usage() {
  echo "Usage: $0 PREFIX" >&2
  exit 2
}

[[ $# -eq 1 ]] || usage

prefix="$1"
workdir="$(mktemp -d "${TMPDIR:-/tmp}/flexcat.XXXXXX")"
trap 'rm -rf "$workdir"' EXIT
make_args=(HOST=Linux OS=unix CC="${CC:-cc}" DEBUG= DEBUGSYM=)

if [[ "$(uname -s)" == "Darwin" ]]; then
  make_args+=(LDLIBS=-liconv)
fi

echo "Building FlexCat ${FLEXCAT_VERSION} for the host"
git -c advice.detachedHead=false clone --quiet --depth 1 \
  --branch "$FLEXCAT_VERSION" \
  https://github.com/adtools/flexcat.git "${workdir}/flexcat"
patch --batch --forward -d "${workdir}/flexcat" -p1 \
  -i "${SCRIPT_DIR}/patches/flexcat-portable-host-build.patch"
make -C "${workdir}/flexcat/src" "${make_args[@]}"

mkdir -p "${prefix}/bin"
install -m 755 "${workdir}/flexcat/src/bin_unix/flexcat" \
  "${prefix}/bin/flexcat"
