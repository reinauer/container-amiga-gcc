#!/usr/bin/env bash
set -euo pipefail

AMISSL_VERSION="5.27"
CODESETS_VERSION="6.22"

usage() {
  echo "Usage: $0 PREFIX" >&2
  exit 2
}

[[ $# -eq 1 ]] || usage

prefix="$1"
target="${prefix}/m68k-amigaos"
workdir="$(mktemp -d "${TMPDIR:-/tmp}/amiga-sdks.XXXXXX")"
trap 'rm -rf "$workdir"' EXIT

install_tree() {
  local source="$1"
  local destination="$2"

  mkdir -p "$destination"
  cp -R "${source}/." "$destination/"
}

download_and_extract() {
  local url="$1"
  local archive="$2"
  local directory="$3"

  curl -LfsS -o "${workdir}/${archive}" "$url"
  mkdir -p "${workdir}/${directory}"
  (
    cd "${workdir}/${directory}"
    lha xq "../${archive}"
  )
}

echo "Installing AmiSSL ${AMISSL_VERSION} SDK into ${prefix}"
download_and_extract \
  "https://github.com/jens-maus/amissl/releases/download/${AMISSL_VERSION}/AmiSSL-${AMISSL_VERSION}-SDK.lha" \
  "AmiSSL-${AMISSL_VERSION}-SDK.lha" amissl
install_tree "${workdir}/amissl/AmiSSL/Developer/include" \
  "${target}/include"
install_tree "${workdir}/amissl/AmiSSL/Developer/fd" \
  "${target}/lib/fd"
install_tree "${workdir}/amissl/AmiSSL/Developer/sfd" \
  "${target}/lib/sfd"
install_tree "${workdir}/amissl/AmiSSL/Developer/lib/AmigaOS3" \
  "${target}/lib"

echo "Installing codesets ${CODESETS_VERSION} SDK into ${prefix}"
download_and_extract \
  "https://github.com/jens-maus/libcodesets/releases/download/${CODESETS_VERSION}/codesets-${CODESETS_VERSION}.lha" \
  "codesets-${CODESETS_VERSION}.lha" codesets
install_tree "${workdir}/codesets/codesets/Developer/include" \
  "${target}/include"
install_tree "${workdir}/codesets/codesets/Developer/fd" \
  "${target}/lib/fd"
install_tree "${workdir}/codesets/codesets/Developer/sfd" \
  "${target}/lib/sfd"
