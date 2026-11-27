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
      --release-tag TAG      Build the GCC version of release TAG of
                              AmigaPorts/m68k-amigaos-gcc (such as
                              v16.2-rc21) from that release, as the toolchain
                              archives do: m68k-amigaos at TAG, also tagged
                              without its "v" (16.2-rc21), and ppc-amigaos
                              with gcc and binutils at m68k-amigaos-gcc-TAG.
                              The other versions are built from their branches
      --date YYYYMMDD        Use YYYYMMDD in the dated tags instead of today
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
RELEASE_TAG_GIVEN=false
BUILD_DATE=""
SELECTED_VERSIONS=()

# Exit with the usage unless option $1 has a value after it; $2 is the
# number of arguments left, the option included.
need_value() {
    if [ "$2" -lt 2 ]; then
        echo "Missing value for $1" >&2
        usage >&2
        exit 1
    fi
}

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
            need_value "$1" "$#"
            IMAGE_REPOSITORY="$2"
            shift
            ;;
        --repository=*)
            IMAGE_REPOSITORY="${1#*=}"
            ;;
        --gcc-version)
            need_value "$1" "$#"
            SELECTED_VERSIONS+=("$2")
            shift
            ;;
        --gcc-version=*)
            SELECTED_VERSIONS+=("${1#*=}")
            ;;
        --release-tag)
            need_value "$1" "$#"
            RELEASE_TAG="$2"
            RELEASE_TAG_GIVEN=true
            shift
            ;;
        --release-tag=*)
            RELEASE_TAG="${1#*=}"
            RELEASE_TAG_GIVEN=true
            ;;
        --date)
            need_value "$1" "$#"
            BUILD_DATE="$2"
            shift
            ;;
        --date=*)
            BUILD_DATE="${1#*=}"
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

# A release tag is vVERSION or vVERSION-rcN; an empty one must not fall
# back to the full branch build.
if [ "$RELEASE_TAG_GIVEN" = true ]; then
    release_tag_re='^v[0-9]+(\.[0-9]+)*(-rc[0-9]+)?$'
    if ! [[ "$RELEASE_TAG" =~ $release_tag_re ]]; then
        echo "Not a release tag: '$RELEASE_TAG' (such as v16.2-rc21 or v16.2)" >&2
        exit 1
    fi
    if [ "${#SELECTED_VERSIONS[@]}" -gt 0 ]; then
        echo "--release-tag builds every version; drop --gcc-version" >&2
        exit 1
    fi
fi

# The dated tags, such as gcc-v16.2-20261127. The toolchain archives pass
# the date of their release, so that both carry the same one.
if [ -z "$BUILD_DATE" ]; then
    BUILD_DATE=$(date +%Y%m%d)
elif ! [[ "$BUILD_DATE" =~ ^[0-9]{8}$ ]]; then
    echo "Not a date: '$BUILD_DATE' (expected YYYYMMDD)" >&2
    exit 1
fi

# Define GCC versions and branches. Keep this compatible with macOS
# /bin/bash 3.2, which does not support associative arrays.
GCC_VERSION_SPECS=(
    "13.4:amiga13.4"
    "16.2:amiga16.2"
)

# ppc-amigaos (AmigaOS 4) versions and their AmigaPorts/gcc refs. These are
# tagged gcc-vVERSION-ppc.
PPC_GCC_VERSION_SPECS=(
    "16.2:amiga16.2"
)

LATEST_GCC_VERSION="16.2"

# --gcc-version narrows both lists to the versions given.  latest, an
# m68k-amigaos image, moves only when its version is among those built.
TAG_LATEST=true
if [ "${#SELECTED_VERSIONS[@]}" -gt 0 ]; then
    M68K_SPECS=()
    PPC_SPECS=()
    SEEN=" "
    TAG_LATEST=false
    for VERSION in "${SELECTED_VERSIONS[@]}"; do
        case "$SEEN" in
            *" $VERSION "*) continue ;;
        esac
        SEEN="$SEEN$VERSION "
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

# A release, such as v16.2-rc21, pins its GCC version: 16.2.
RELEASE_VERSION=""
if [ "$RELEASE_TAG_GIVEN" = true ]; then
    RELEASE_VERSION="${RELEASE_TAG#v}"
    RELEASE_VERSION="${RELEASE_VERSION%%-*}"
    FOUND=false
    for GCC_VERSION_SPEC in "${GCC_VERSION_SPECS[@]}"; do
        if [ "${GCC_VERSION_SPEC%%:*}" = "$RELEASE_VERSION" ]; then
            FOUND=true
        fi
    done
    if [ "$FOUND" != true ]; then
        echo "No m68k-amigaos GCC ${RELEASE_VERSION} for release ${RELEASE_TAG}" >&2
        exit 1
    fi
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

# Write a value such as "-4" to .extra to append it to dated tags.
EXTRA=""
if [ -f .extra ]; then
    IFS= read -r EXTRA < .extra || true
fi

# Build, tag and push one image, tagged gcc-vVERSION and
# gcc-vVERSION-DATE. TARGET is m68k-amigaos or ppc-amigaos; SUFFIX is
# appended to the version in the tags; BRANCH is the AmigaPorts/gcc ref.
# With RELEASE_TAG, such as v16.2-rc21, an m68k-amigaos image is built from
# that release and also tagged with it without its "v" (16.2-rc21).
# BINUTILS_REF is the ppc-amigaos AmigaPorts/binutils-gdb ref, if not the
# default one.
build_image() {
    local target="$1" version="$2" branch="$3" suffix="$4" release_tag="${5:-}"
    local binutils_ref="${6:-}"
    local local_tag tag
    local tags=()
    local build_args=(
        --build-arg "BUILD_TARGET=${target}"
        --build-arg "BUILD_GCC_BRANCH=${branch}"
        --build-arg "BUILD_GCC_VERSION=${version}"
    )

    local_tag="${LOCAL_IMAGE_NAME}:gcc-v${version}${suffix}-${BUILD_DATE}${EXTRA}"
    tags+=("${IMAGE_REPOSITORY}:gcc-v${version}${suffix}")
    tags+=("${IMAGE_REPOSITORY}:gcc-v${version}${suffix}-${BUILD_DATE}${EXTRA}")

    echo "========================================"
    if [ -n "$release_tag" ]; then
        echo "Building ${target} GCC ${version} (release: ${release_tag})"
        tags+=("${IMAGE_REPOSITORY}:${release_tag#v}")
        build_args+=(--build-arg "BUILD_RELEASE_TAG=${release_tag}")
    else
        echo "Building ${target} GCC ${version} (branch: ${branch})"
    fi
    if [ -n "$binutils_ref" ]; then
        build_args+=(--build-arg "BUILD_BINUTILS_REF=${binutils_ref}")
    fi
    echo "========================================"
    echo

    ask_and_run "$DOCKER_CLI" build \
        --pull \
        --no-cache \
        "${build_args[@]}" \
        -f Containerfile \
        -t "$local_tag" .
    for tag in "${tags[@]}"; do
        ask_and_run "$DOCKER_CLI" tag "$local_tag" "$tag"
    done
    for tag in "${tags[@]}"; do
        push_image "$tag"
    done

    echo
}

# --- Build and push each GCC version ---
# The version of a release is built from it, the way the toolchain archives
# build it: m68k-amigaos at the release (the branch only fills the gcc.branch
# label), ppc-amigaos with gcc and binutils at its m68k-amigaos-gcc-TAG tags.
for GCC_VERSION_SPEC in "${GCC_VERSION_SPECS[@]}"; do
    VERSION="${GCC_VERSION_SPEC%%:*}"
    if [ "$VERSION" = "$RELEASE_VERSION" ]; then
        build_image m68k-amigaos "$VERSION" "${GCC_VERSION_SPEC#*:}" "" "$RELEASE_TAG"
    else
        build_image m68k-amigaos "$VERSION" "${GCC_VERSION_SPEC#*:}" ""
    fi
done
for GCC_VERSION_SPEC in "${PPC_GCC_VERSION_SPECS[@]}"; do
    VERSION="${GCC_VERSION_SPEC%%:*}"
    if [ "$VERSION" = "$RELEASE_VERSION" ]; then
        REF="m68k-amigaos-gcc-${RELEASE_TAG}"
        build_image ppc-amigaos "$VERSION" "$REF" "-ppc" "" "$REF"
    else
        build_image ppc-amigaos "$VERSION" "${GCC_VERSION_SPEC#*:}" "-ppc"
    fi
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
