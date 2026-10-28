#!/bin/bash

# ---
# This script builds and pushes Docker images for multiple GCC versions
# with interactive confirmation steps.
# ---

usage() {
    cat <<EOF
Usage: $0 [OPTIONS]

Build and push Docker images for multiple GCC versions.

Options:
  -n, --no-skip              Run all steps without prompting
      --no-push              Build and tag the images, but do not push them
      --gcc-version VER      Build only the images of GCC version VER, such as
                              16.2; repeat for more
      --release-tag TAG      Build only the m68k-amigaos release TAG of
                              AmigaPorts/m68k-amigaos-gcc (such as
                              v16.2-rc21), tagged without its "v" (16.2-rc21);
                              latest is left alone
  -r, --repository REPO      Publish to REPO instead of
                              $DOCKERHUB_REPOSITORY
  -h, --help                 Show this help message
EOF
}

# --- Configuration ---
# shellcheck source=registry.conf
. "$(dirname "$0")/registry.conf"
IMAGE_REPOSITORY="$DOCKERHUB_REPOSITORY"
LOCAL_IMAGE_NAME="amiga-gcc"
DOCKER_CLI="${DOCKER_CLI:-docker}"
NO_SKIP=false
NO_PUSH=false
RELEASE_TAG=""
SELECTED_VERSIONS=()

# --- Parse command line arguments ---
while [ "$#" -gt 0 ]; do
    case "$1" in
        -n|--no-skip)
            NO_SKIP=true
            ;;
        --no-push)
            NO_PUSH=true
            ;;
        -r|--repository)
            if [ "$#" -lt 2 ]; then
                echo "Missing value for $1" >&2
                usage >&2
                exit 1
            fi
            IMAGE_REPOSITORY="$2"
            shift
            ;;
        --repository=*)
            IMAGE_REPOSITORY="${1#*=}"
            ;;
        --gcc-version)
            if [ "$#" -lt 2 ]; then
                echo "Missing value for $1" >&2
                usage >&2
                exit 1
            fi
            SELECTED_VERSIONS+=("$2")
            shift
            ;;
        --gcc-version=*)
            SELECTED_VERSIONS+=("${1#*=}")
            ;;
        --release-tag)
            if [ "$#" -lt 2 ]; then
                echo "Missing value for $1" >&2
                usage >&2
                exit 1
            fi
            RELEASE_TAG="$2"
            shift
            ;;
        --release-tag=*)
            RELEASE_TAG="${1#*=}"
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

if [ -z "$IMAGE_REPOSITORY" ]; then
    echo "Image repository must not be empty." >&2
    exit 1
fi

# Define GCC versions and branches. Keep this compatible with macOS
# /bin/bash 3.2, which does not support associative arrays.
GCC_VERSION_SPECS=(
    "6.5.0b:amiga6"
    "13.4:amiga13.4"
    "16.2:amiga16.2"
)

# ppc-amigaos (AmigaOS 4) versions and their AmigaPorts/gcc refs. These are
# tagged gcc-vVERSION-ppc.
PPC_GCC_VERSION_SPECS=(
    "16.2:amiga16.2"
)

LATEST_GCC_VERSION="6.5.0b"

# --gcc-version narrows both lists to the versions given.  latest, an
# m68k-amigaos image, moves only when its version is among those built.
TAG_LATEST=true
if [ "${#SELECTED_VERSIONS[@]}" -gt 0 ]; then
    M68K_SPECS=()
    PPC_SPECS=()
    TAG_LATEST=false
    for VERSION in "${SELECTED_VERSIONS[@]}"; do
        FOUND=false
        for GCC_VERSION_SPEC in "${GCC_VERSION_SPECS[@]}"; do
            if [ "${GCC_VERSION_SPEC%%:*}" = "$VERSION" ]; then
                M68K_SPECS+=("$GCC_VERSION_SPEC")
                FOUND=true
                if [ "$VERSION" = "$LATEST_GCC_VERSION" ]; then
                    TAG_LATEST=true
                fi
            fi
        done
        for GCC_VERSION_SPEC in "${PPC_GCC_VERSION_SPECS[@]}"; do
            if [ "${GCC_VERSION_SPEC%%:*}" = "$VERSION" ]; then
                PPC_SPECS+=("$GCC_VERSION_SPEC")
                FOUND=true
            fi
        done
        if [ "$FOUND" != true ]; then
            echo "Unknown GCC version: $VERSION" >&2
            exit 1
        fi
    done
    GCC_VERSION_SPECS=("${M68K_SPECS[@]}")
    PPC_GCC_VERSION_SPECS=("${PPC_SPECS[@]}")
fi

# Prompt the user, then execute the command without reparsing its arguments.
ask_and_run() {
    local response

    printf 'Next step: ->'
    printf ' %q' "$@"
    printf ' <-'

    if [ "$NO_SKIP" = true ]; then
        echo
        response="N"
    else
        printf ' Skip? [yN] '
        IFS= read -r response
    fi

    case "$response" in
        [yY])
            echo "Skipping step."
            ;;
        *)
            echo "Executing..."
            if "$@"; then
                echo "Step completed successfully."
            else
                echo "Error during execution. Aborting."
                exit 1
            fi
            ;;
    esac
    echo
}

# Push an image unless --no-push was given.
push_image() {
    if [ "$NO_PUSH" = true ]; then
        echo "Not pushing $1 (--no-push)."
        echo
        return
    fi
    ask_and_run "$DOCKER_CLI" push "$1"
}

# Get the current date in YYYYMMDD format.
BUILD_DATE=$(date +%Y%m%d)
# Write a value such as "-4" to .extra to append it to dated tags.
EXTRA=""
if [ -f .extra ]; then
    IFS= read -r EXTRA < .extra || true
fi

# Build, tag and push one image. TARGET is m68k-amigaos or ppc-amigaos;
# SUFFIX is appended to the version in the tags.
build_image() {
    local target="$1" version="$2" branch="$3" suffix="$4"
    local local_tag tag_version tag_version_date

    echo "========================================"
    echo "Building ${target} GCC ${version} (branch: ${branch})"
    echo "========================================"
    echo

    local_tag="${LOCAL_IMAGE_NAME}:gcc-v${version}${suffix}-${BUILD_DATE}${EXTRA}"
    tag_version="${IMAGE_REPOSITORY}:gcc-v${version}${suffix}"
    tag_version_date="${IMAGE_REPOSITORY}:gcc-v${version}${suffix}-${BUILD_DATE}${EXTRA}"

    ask_and_run "$DOCKER_CLI" build \
        --pull \
        --no-cache \
        --build-arg "BUILD_TARGET=${target}" \
        --build-arg "BUILD_GCC_BRANCH=${branch}" \
        --build-arg "BUILD_GCC_VERSION=${version}" \
        -f Containerfile \
        -t "$local_tag" .
    ask_and_run "$DOCKER_CLI" tag "$local_tag" "$tag_version"
    ask_and_run "$DOCKER_CLI" tag "$local_tag" "$tag_version_date"
    push_image "$tag_version"
    push_image "$tag_version_date"

    echo
}

# Build, tag and push the image of one release tag, such as v16.2-rc21.
# The GCC version is the tag without its "v" and its "-rcN" suffix.
build_release_image() {
    local tag="$1" version local_tag image_tag

    version="${tag#v}"
    version="${version%%-*}"

    echo "========================================"
    echo "Building m68k-amigaos release ${tag} (GCC ${version})"
    echo "========================================"
    echo

    local_tag="${LOCAL_IMAGE_NAME}:${tag#v}"
    image_tag="${IMAGE_REPOSITORY}:${tag#v}"

    ask_and_run "$DOCKER_CLI" build \
        --pull \
        --no-cache \
        --build-arg "BUILD_TARGET=m68k-amigaos" \
        --build-arg "BUILD_GCC_BRANCH=${tag}" \
        --build-arg "BUILD_GCC_VERSION=${version}" \
        --build-arg "BUILD_RELEASE_TAG=${tag}" \
        -f Containerfile \
        -t "$local_tag" .
    ask_and_run "$DOCKER_CLI" tag "$local_tag" "$image_tag"
    push_image "$image_tag"
}

if [ -n "$RELEASE_TAG" ]; then
    build_release_image "$RELEASE_TAG"
    echo "Script finished."
    exit 0
fi

# --- Build and push each GCC version ---
for GCC_VERSION_SPEC in "${GCC_VERSION_SPECS[@]}"; do
    build_image m68k-amigaos "${GCC_VERSION_SPEC%%:*}" "${GCC_VERSION_SPEC#*:}" ""
done
for GCC_VERSION_SPEC in "${PPC_GCC_VERSION_SPECS[@]}"; do
    build_image ppc-amigaos "${GCC_VERSION_SPEC%%:*}" "${GCC_VERSION_SPEC#*:}" "-ppc"
done

if [ "$TAG_LATEST" != true ]; then
    echo "Script finished."
    exit 0
fi

# Optionally tag one of the currently built GCC versions as 'latest'
echo "========================================"
echo "Tagging GCC ${LATEST_GCC_VERSION} as 'latest'"
echo "========================================"
echo

LOCAL_LATEST_TAG="${LOCAL_IMAGE_NAME}:gcc-v${LATEST_GCC_VERSION}-${BUILD_DATE}${EXTRA}"
LATEST_TAG="${IMAGE_REPOSITORY}:latest"

ask_and_run "$DOCKER_CLI" tag "$LOCAL_LATEST_TAG" "$LATEST_TAG"
push_image "$LATEST_TAG"

echo
echo "Script finished."
