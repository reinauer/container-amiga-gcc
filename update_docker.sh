#!/bin/bash

# ---
# This script builds and pushes Docker images with interactive confirmation steps.
# A function `ask_and_run` is defined to prompt the user before executing a command.
# ---

# --- Configuration ---
# Change these variables to match your Docker Hub username and image name.
DOCKER_USER="stefanreinauer"
IMAGE_NAME="amiga-gcc"


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
    read -p "Next step: -> ${cmd} <- Skip? [yN] " -r response

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

# --- Define all the commands to be executed ---
CMD_BUILD="docker build -t ${IMAGE_NAME}:v${DATE} ."
CMD_TAG_LATEST="docker tag ${IMAGE_NAME}:v${DATE} ${DOCKER_USER}/${IMAGE_NAME}:latest"
CMD_TAG_VERSIONED="docker tag ${IMAGE_NAME}:v${DATE} ${DOCKER_USER}/${IMAGE_NAME}:v${DATE}"
CMD_PUSH_LATEST="docker push ${DOCKER_USER}/${IMAGE_NAME}:latest"
CMD_PUSH_VERSIONED="docker push ${DOCKER_USER}/${IMAGE_NAME}:v${DATE}"


# --- Execute each command with the confirmation prompt ---
ask_and_run "${CMD_BUILD}"
ask_and_run "${CMD_TAG_LATEST}"
ask_and_run "${CMD_TAG_VERSIONED}"
ask_and_run "${CMD_PUSH_LATEST}"
ask_and_run "${CMD_PUSH_VERSIONED}"

echo "Script finished."
