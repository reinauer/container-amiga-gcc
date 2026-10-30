#!/usr/bin/env bash

# ---
# This script installs the toolchain archives of a GitHub release for this
# host: each dated installation, such as /opt/amiga-16.2-20261029, and its
# stable symlink, /opt/amiga-16.2, which is pointed at it.
# ---

set -euo pipefail

REPO="reinauer/container-amiga-gcc"
ROOT="/opt"
TAG=""
ONLY=""
FORCE=false
DRY_RUN=false

usage() {
    cat <<EOF
Usage: $0 [OPTIONS]

Download the toolchain archives of the latest release of $REPO for this
host (Linux x86_64 or macOS ARM64), unpack their dated installations into
$ROOT and point the stable symlinks, such as $ROOT/amiga-16.2, at them.
Runs sudo itself when $ROOT is not writable.

Options:
  -t, --tag TAG              Install release TAG, such as v2026-10-29,
                              instead of the latest
  -o, --only NAME            Install only NAME, such as amiga-16.2 or
                              amiga-ppc-16.2; repeat it for more
  -r, --root DIR             Install into DIR instead of $ROOT
  -f, --force                Reinstall dated installations that already exist
  -n, --dry-run              Show what would be installed without installing
  -h, --help                 Show this help message

Set GITHUB_TOKEN to avoid the GitHub API's rate limit for anonymous use.
EOF
}

log() {
    printf '\n==> %s\n' "$*"
}

die() {
    printf 'error: %s\n' "$*" >&2
    exit 1
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        -t|--tag) [[ $# -ge 2 ]] || die "$1 needs an argument"; TAG="$2"; shift 2 ;;
        -o|--only) [[ $# -ge 2 ]] || die "$1 needs an argument"; ONLY="$ONLY $2"; shift 2 ;;
        -r|--root) [[ $# -ge 2 ]] || die "$1 needs an argument"; ROOT="${2%/}"; shift 2 ;;
        -f|--force) FORCE=true; shift ;;
        -n|--dry-run) DRY_RUN=true; shift ;;
        -h|--help) usage; exit 0 ;;
        *) usage >&2; exit 1 ;;
    esac
done

case "$(uname -s)/$(uname -m)" in
    Linux/x86_64) PLATFORM="linux-x86_64" ;;
    Darwin/arm64) PLATFORM="macos-arm64" ;;
    *) die "no toolchain archives for $(uname -s) $(uname -m)" ;;
esac

command -v curl >/dev/null 2>&1 || die "curl not found"

# --- Release ---
if [[ -n "$TAG" ]]; then
    api_url="https://api.github.com/repos/$REPO/releases/tags/$TAG"
else
    api_url="https://api.github.com/repos/$REPO/releases/latest"
fi
curl_args=(-fsSL -H "Accept: application/vnd.github+json")
if [[ -n "${GITHUB_TOKEN:-}" ]]; then
    curl_args+=(-H "Authorization: Bearer $GITHUB_TOKEN")
fi
release_json="$(curl "${curl_args[@]}" "$api_url")" \
    || die "could not read release ${TAG:-latest} of $REPO"

json_strings() {
    printf '%s\n' "$release_json" \
        | grep -o "\"$1\": *\"[^\"]*\"" | sed 's/.*"\([^"]*\)"$/\1/'
}
TAG="$(json_strings tag_name | head -n 1)"
urls="$(json_strings browser_download_url \
    | grep -E -- "-${PLATFORM}\.tar\.xz\$" || true)"
[[ -n "$urls" ]] || die "release $TAG has no $PLATFORM archives"

# Archives are named NAME-gcc-VERSION-YYYYMMDD-PLATFORM.tar.xz and contain
# opt/NAME-VERSION-YYYYMMDD and the opt/NAME-VERSION symlink to it.
names=()
dated=()
assets=()
while IFS= read -r url; do
    asset="${url##*/}"
    if [[ ! "$asset" =~ ^(amiga(-ppc)?)-gcc-(.+)-([0-9]{8})-${PLATFORM}\.tar\.xz$ ]]; then
        printf 'warning: skipping unexpected archive %s\n' "$asset" >&2
        continue
    fi
    name="${BASH_REMATCH[1]}-${BASH_REMATCH[3]}"
    if [[ -n "$ONLY" && " $ONLY " != *" $name "* ]]; then
        continue
    fi
    names+=("$name")
    dated+=("$name-${BASH_REMATCH[4]}")
    assets+=("$url")
done <<< "$urls"

for name in $ONLY; do
    [[ " ${names[*]-} " == *" $name "* ]] || die "release $TAG has no $name for $PLATFORM"
done
[[ ${#names[@]} -gt 0 ]] || die "release $TAG has no matching $PLATFORM archives"

log "Release $TAG for $PLATFORM"
for i in "${!names[@]}"; do
    if [[ -d "$ROOT/${dated[$i]}" && "$FORCE" == false ]]; then
        state="installed"
    else
        state="to install"
    fi
    printf '  %-28s %s\n' "$ROOT/${dated[$i]}" "$state"
done

if [[ "$DRY_RUN" == true ]]; then
    exit 0
fi

# --- Privileges ---
if [[ $EUID -eq 0 ]] || { [[ -d "$ROOT" && -w "$ROOT" ]]; }; then
    as_root() { "$@"; }
else
    as_root() { sudo "$@"; }
    log "sudo is needed to install into $ROOT"
    sudo -v
fi

tmpdir="$(mktemp -d)"
stage=""
cleanup() {
    rm -rf -- "$tmpdir"
    if [[ -n "$stage" ]]; then
        as_root rm -rf -- "$stage"
    fi
}
trap cleanup EXIT

as_root mkdir -p "$ROOT"

# --- Install ---
for i in "${!names[@]}"; do
    name="${names[$i]}"
    prefix="${dated[$i]}"
    url="${assets[$i]}"
    archive="$tmpdir/${url##*/}"
    link="$ROOT/$name"

    if [[ -e "$link" && ! -L "$link" ]]; then
        die "$link exists and is not a symlink; move it out of the way first"
    fi

    if [[ ! -d "$ROOT/$prefix" || "$FORCE" == true ]]; then
        log "Downloading ${url##*/}"
        curl -fL --retry 3 -# -o "$archive" "$url"

        # Unpack next to the final location, so that an interrupted install
        # leaves no partial installation behind.
        log "Unpacking $ROOT/$prefix"
        stage="$(as_root mktemp -d "$ROOT/.install-$prefix.XXXXXX")"
        as_root tar -C "$stage" --strip-components=1 -xJf "$archive" "opt/$prefix"
        case "$name" in
            amiga-ppc-*) target="ppc-amigaos" ;;
            *) target="m68k-amigaos" ;;
        esac
        [[ -x "$stage/$prefix/bin/$target-gcc" ]] \
            || die "${url##*/} has no $prefix/bin/$target-gcc"

        if [[ -d "$ROOT/$prefix" ]]; then
            as_root rm -rf -- "${ROOT:?}/$prefix"
        fi
        as_root mv "$stage/$prefix" "$ROOT/$prefix"
        as_root rm -rf -- "$stage"
        stage=""
        rm -f -- "$archive"
    fi

    # Archives downloaded with a browser carry the quarantine flag, which
    # makes macOS refuse every executable in them.
    if [[ "$PLATFORM" == macos-* ]]; then
        as_root /usr/bin/xattr -rd com.apple.quarantine "$ROOT/$prefix"
    fi

    as_root ln -sfn "$prefix" "$link"
    printf '  %s -> %s\n' "$link" "$prefix"
done

log "Done"
printf 'Add a toolchain to PATH with, for example:\n'
printf "  export PATH=%s/%s/bin:\$PATH\n" "$ROOT" "${names[0]}"
