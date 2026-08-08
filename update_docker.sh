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
  -r, --repository REPO      Publish to REPO instead of
                              docker.io/stefanreinauer/amiga-gcc
  -h, --help                 Show this help message
EOF
}

# --- Configuration ---
IMAGE_REPOSITORY="docker.io/stefanreinauer/amiga-gcc"
LOCAL_IMAGE_NAME="amiga-gcc"
DOCKER_CLI="${DOCKER_CLI:-docker}"
NO_SKIP=false

# --- Parse command line arguments ---
while [ "$#" -gt 0 ]; do
    case "$1" in
        -n|--no-skip)
            NO_SKIP=true
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

# Define GCC versions, branches, and whether to enable Amiga LTO.  Keep this
# compatible with macOS /bin/bash 3.2, which does not support associative
# arrays.
GCC_VERSION_SPECS=(
    "6.5.0b:amiga6:1"
    "13.4:amiga13.4:1"
    "16.1:amiga16.1:1"
)

LATEST_GCC_VERSION="6.5.0b"

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

# Get the current date in YYYYMMDD format.
BUILD_DATE=$(date +%Y%m%d)
# Write a value such as "-4" to .extra to append it to dated tags.
EXTRA=""
if [ -f .extra ]; then
    IFS= read -r EXTRA < .extra || true
fi

# --- Build and push each GCC version ---
for GCC_VERSION_SPEC in "${GCC_VERSION_SPECS[@]}"; do
    GCC_VERSION="${GCC_VERSION_SPEC%%:*}"
    GCC_REST="${GCC_VERSION_SPEC#*:}"
    GCC_BRANCH="${GCC_REST%%:*}"
    BUILD_AMIGA_LTO="${GCC_REST#*:}"

    echo "========================================"
    echo "Building GCC ${GCC_VERSION} (branch: ${GCC_BRANCH}, LTO: ${BUILD_AMIGA_LTO})"
    echo "========================================"
    echo

    # Define tags for this version
    LOCAL_TAG="${LOCAL_IMAGE_NAME}:gcc-v${GCC_VERSION}-${BUILD_DATE}${EXTRA}"
    TAG_GCC_VERSION="${IMAGE_REPOSITORY}:gcc-v${GCC_VERSION}"
    TAG_GCC_VERSION_DATE="${IMAGE_REPOSITORY}:gcc-v${GCC_VERSION}-${BUILD_DATE}${EXTRA}"

    # Execute commands for this version
    ask_and_run "$DOCKER_CLI" build \
        --build-arg "BUILD_GCC_BRANCH=${GCC_BRANCH}" \
        --build-arg "BUILD_GCC_VERSION=${GCC_VERSION}" \
        --build-arg "BUILD_AMIGA_LTO=${BUILD_AMIGA_LTO}" \
        -t "$LOCAL_TAG" .
    ask_and_run "$DOCKER_CLI" tag "$LOCAL_TAG" "$TAG_GCC_VERSION"
    ask_and_run "$DOCKER_CLI" tag "$LOCAL_TAG" "$TAG_GCC_VERSION_DATE"
    ask_and_run "$DOCKER_CLI" push "$TAG_GCC_VERSION"
    ask_and_run "$DOCKER_CLI" push "$TAG_GCC_VERSION_DATE"

    echo
done

# Optionally tag one of the currently built GCC versions as 'latest'
echo "========================================"
echo "Tagging GCC ${LATEST_GCC_VERSION} as 'latest'"
echo "========================================"
echo

LOCAL_LATEST_TAG="${LOCAL_IMAGE_NAME}:gcc-v${LATEST_GCC_VERSION}-${BUILD_DATE}${EXTRA}"
LATEST_TAG="${IMAGE_REPOSITORY}:latest"

ask_and_run "$DOCKER_CLI" tag "$LOCAL_LATEST_TAG" "$LATEST_TAG"
ask_and_run "$DOCKER_CLI" push "$LATEST_TAG"

echo
echo "Script finished."
