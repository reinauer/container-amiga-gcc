#!/bin/bash

# ---
# This script copies the compiler image tags published on GHCR to Docker Hub
# without rebuilding them. Tags whose digest already matches are skipped.
# ---

set -euo pipefail

usage() {
    cat <<EOF
Usage: $0 [OPTIONS]

Copy the newest build's tags (gcc-vVERSION, gcc-vVERSION-YYYYMMDD and
latest) from GHCR to Docker Hub.

Options:
  -n, --dry-run              Show what would be copied without copying
  -y, --yes                  Copy without asking for confirmation
  -s, --source REPO          Copy from REPO instead of
                              $GHCR_REPOSITORY
  -d, --destination REPO     Copy to REPO instead of
                              $DOCKERHUB_REPOSITORY
  -h, --help                 Show this help message

Log in to the destination registry first, e.g. 'docker login docker.io'.
EOF
}

# --- Configuration ---
# shellcheck source=registry.conf
. "$(dirname "$0")/registry.conf"
SOURCE_REPOSITORY="$GHCR_REPOSITORY"
DEST_REPOSITORY="$DOCKERHUB_REPOSITORY"
DRY_RUN=false
ASSUME_YES=false

# --- Parse command line arguments ---
while [ "$#" -gt 0 ]; do
    case "$1" in
        -n|--dry-run)
            DRY_RUN=true
            ;;
        -y|--yes)
            ASSUME_YES=true
            ;;
        -s|--source|-d|--destination)
            if [ "$#" -lt 2 ]; then
                echo "Missing value for $1" >&2
                usage >&2
                exit 1
            fi
            case "$1" in
                -s|--source) SOURCE_REPOSITORY="$2" ;;
                *) DEST_REPOSITORY="$2" ;;
            esac
            shift
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            echo "Unknown option: $1" >&2
            usage >&2
            exit 1
            ;;
    esac
    shift
done

if [[ "$SOURCE_REPOSITORY" != ghcr.io/* ]]; then
    echo "Only GHCR source repositories are supported." >&2
    exit 1
fi

# --- List the source tags ---
# GHCR serves public packages with an anonymous pull token.
source_path="${SOURCE_REPOSITORY#ghcr.io/}"
token="$(
    curl -fsS "https://ghcr.io/token?scope=repository:${source_path}:pull" |
        jq -r .token
)"
all_tags="$(
    curl -fsS -H "Authorization: Bearer $token" \
        "https://ghcr.io/v2/${source_path}/tags/list?n=1000" |
        jq -r '.tags[]'
)"

# Only the newest build is copied: its dated tags, the matching floating
# gcc-vVERSION tags and latest. Versions missing from that build (such as a
# retired 16.1) are left alone.
latest_date="$(
    sed -nE 's/^gcc-v.+-([0-9]{8})$/\1/p' <<<"$all_tags" | sort -u | tail -n 1
)"
if [ -z "$latest_date" ]; then
    echo "No dated tags found in $SOURCE_REPOSITORY" >&2
    exit 1
fi

tags=()
while IFS= read -r version; do
    tags+=("gcc-v$version" "gcc-v$version-$latest_date")
done < <(sed -nE "s/^gcc-v(.+)-${latest_date}\$/\\1/p" <<<"$all_tags")
tags+=("latest")
digest_of() {
    docker buildx imagetools inspect "$1" \
        --format '{{.Manifest.Digest}}' 2>/dev/null || true
}

# imagetools create wraps a single-manifest image in a manifest list, so a
# copy's digest differs from its source's.  List the digest of REF and of
# each manifest it lists.
copied_digests() {
    local raw
    raw="$(docker buildx imagetools inspect --raw "$1" 2>/dev/null)" || return 0
    printf '%s\n' "$(digest_of "$1")"
    jq -r '.manifests[]?.digest' <<<"$raw"
}

# --- List what would be copied ---
echo "Latest build on $SOURCE_REPOSITORY: $latest_date"
pending_tags=()
pending_digests=()
for tag in "${tags[@]}"; do
    source_digest="$(digest_of "$SOURCE_REPOSITORY:$tag")"
    if [ -z "$source_digest" ]; then
        echo "Cannot inspect $SOURCE_REPOSITORY:$tag" >&2
        exit 1
    fi
    if grep -qxF "$source_digest" <<<"$(copied_digests "$DEST_REPOSITORY:$tag")"; then
        echo "  = $tag (up to date)"
        continue
    fi
    echo "  + $tag ($source_digest)"
    pending_tags+=("$tag")
    pending_digests+=("$source_digest")
done

if [ "${#pending_tags[@]}" -eq 0 ]; then
    echo "$DEST_REPOSITORY is up to date."
    exit 0
fi
if $DRY_RUN; then
    echo "Would copy ${#pending_tags[@]} tag(s) to $DEST_REPOSITORY."
    exit 0
fi
if ! $ASSUME_YES; then
    read -r -p "Copy ${#pending_tags[@]} tag(s) to $DEST_REPOSITORY? [y/N] " answer
    if [[ ! "$answer" =~ ^[Yy]([Ee][Ss])?$ ]]; then
        echo "Aborted."
        exit 1
    fi
fi

# --- Copy ---
for i in "${!pending_tags[@]}"; do
    docker buildx imagetools create \
        --tag "$DEST_REPOSITORY:${pending_tags[$i]}" \
        "$SOURCE_REPOSITORY@${pending_digests[$i]}"
done
echo "Copied ${#pending_tags[@]} tag(s) to $DEST_REPOSITORY."
