#!/bin/bash

# ---
# This script builds and pushes Docker images for multiple GCC versions
# with interactive confirmation steps.
# A function `ask_and_run` is defined to prompt the user before executing a command.
# ---

# --- Parse command line arguments ---
NO_SKIP=false
for arg in "$@"; do
    case "$arg" in
        -n|--no-skip)
            NO_SKIP=true
            ;;
        -h|--help)
            echo "Usage: $0 [OPTIONS]"
            echo ""
            echo "Build and push Docker images for multiple GCC versions."
            echo ""
            echo "Options:"
            echo "  -n, --no-skip    Run all steps without prompting"
            echo "  -h, --help       Show this help message"
            exit 0
            ;;
        *)
            echo "Unknown option: $arg"
            echo "Usage: $0 [OPTIONS]"
            echo "Try '$0 --help' for more information."
            exit 1
            ;;
    esac
done

# --- Configuration ---
# Change these variables to match your Docker Hub username and image name.
DOCKER_USER="stefanreinauer"
IMAGE_NAME="amiga-gcc"

# Define GCC versions and their corresponding branches
declare -A GCC_VERSIONS=(
    ["6.5.0b"]="amiga6"
    ["13.3"]="amiga13.3"
    ["15.2"]="amiga15.2"
)


# Function to prompt the user and execute a command based on their input.
#
# @param {string} cmd - The command to be executed.
#
ask_and_run() {
    # The command to be executed is passed as the first argument.
    local cmd="$1"
    local response

    # Prompt the user with the command and ask for confirmation.
    # -p: Display the prompt on the same line without a trailing newline.
    # -r: Prevents backslash from acting as an escape character.
    if [ "$NO_SKIP" = true ]; then
        echo "Next step: -> ${cmd} <-"
        response="N"
    else
        read -p "Next step: -> ${cmd} <- Skip? [yN] " -r response
    fi

    # Use a case statement to check the user's input.
    case "$response" in
        [yY])
            # If the user enters 'y' or 'Y', skip the command.
            echo "Skipping step."
            ;;
        *)
            # For any other input, including just pressing Enter (empty response),
            # execute the command.
            echo "Executing..."
            if eval "${cmd}"; then
                echo "Step completed successfully."
            else
                # If the command fails, print an error and exit the script.
                echo "Error during execution. Aborting."
                exit 1
            fi
            ;;
    esac
    # Add a newline for better readability between steps.
    echo
}

# Get the current date in YYYYMMDD format.
DATE=$(date +%Y%m%d)
# Run sth like 'echo "-4" > .extra' if you would like to add an extra field to the version.
EXTRA=$(cat .extra 2>/dev/null)

# --- Build and push each GCC version ---
for GCC_VERSION in "${!GCC_VERSIONS[@]}"; do
    GCC_BRANCH="${GCC_VERSIONS[$GCC_VERSION]}"

    echo "========================================"
    echo "Building GCC ${GCC_VERSION} (branch: ${GCC_BRANCH})"
    echo "========================================"
    echo

    # Define tags for this version
    LOCAL_TAG="${IMAGE_NAME}:gcc-v${GCC_VERSION}-${DATE}${EXTRA}"
    TAG_GCC_VERSION="${DOCKER_USER}/${IMAGE_NAME}:gcc-v${GCC_VERSION}"
    TAG_GCC_VERSION_DATE="${DOCKER_USER}/${IMAGE_NAME}:gcc-v${GCC_VERSION}-${DATE}${EXTRA}"

    # Build with build arguments
    CMD_BUILD="docker build --build-arg BUILD_GCC_BRANCH=${GCC_BRANCH} --build-arg BUILD_GCC_VERSION=${GCC_VERSION} -t ${LOCAL_TAG} ."
    CMD_TAG_VERSION="docker tag ${LOCAL_TAG} ${TAG_GCC_VERSION}"
    CMD_TAG_VERSION_DATE="docker tag ${LOCAL_TAG} ${TAG_GCC_VERSION_DATE}"
    CMD_PUSH_VERSION="docker push ${TAG_GCC_VERSION}"
    CMD_PUSH_VERSION_DATE="docker push ${TAG_GCC_VERSION_DATE}"

    # Execute commands for this version
    ask_and_run "${CMD_BUILD}"
    ask_and_run "${CMD_TAG_VERSION}"
    ask_and_run "${CMD_TAG_VERSION_DATE}"
    ask_and_run "${CMD_PUSH_VERSION}"
    ask_and_run "${CMD_PUSH_VERSION_DATE}"

    echo
done

#LATEST="13.3"
#LATEST="15.2"
LATEST="6.5.0b"

# Optionally tag one of the currently built GCC versions as 'latest'
echo "========================================"
echo "Tagging GCC ${LATEST} as 'latest'"
echo "========================================"
echo

CMD_TAG_LATEST="docker tag ${IMAGE_NAME}:gcc-v${LATEST}-${DATE}${EXTRA} ${DOCKER_USER}/${IMAGE_NAME}:latest"
CMD_PUSH_LATEST="docker push ${DOCKER_USER}/${IMAGE_NAME}:latest"

ask_and_run "${CMD_TAG_LATEST}"
ask_and_run "${CMD_PUSH_LATEST}"

echo
echo "Script finished."
