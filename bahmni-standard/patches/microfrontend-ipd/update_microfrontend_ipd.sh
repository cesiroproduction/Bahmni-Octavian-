#!/bin/bash

# Define your variables here
CONTAINER_NAME="ipd"
HOST_DIR="/home/sam/Downloads/bahmni-docker/bahmni-standard/patches/microfrontend-ipd"
CONTAINER_DIR="/usr/local/apache2/htdocs/ipd"

# Check if at least one argument for the step is provided
if [ "$#" -lt 1 ]; then
    echo "Usage: $0 <step>"
    echo "Steps:"
    echo "  copy_from  : Copy files from container to host"
    echo "  copy_to    : Copy modified files from host to container"
    echo "  replace     : Replace files in container with local modified files"
    exit 1
fi

STEP="$1"

# Check if host directory exists and is not empty
if [ ! -d "$HOST_DIR" ] || [ -z "$(ls -A "$HOST_DIR")" ]; then
    echo "Error: Host directory \"$HOST_DIR\" does not exist or is empty."
    exit 1
fi

case $STEP in
    copy_from)
        echo "Copying files from container..."
        docker cp "${CONTAINER_NAME}:${CONTAINER_DIR}/." "${HOST_DIR}"
        echo "Files copied to ${HOST_DIR}. You can edit them as needed."
        ;;
    copy_to)
        echo "Copying edited files back to the container..."
        docker cp "${HOST_DIR}/." "${CONTAINER_NAME}:${CONTAINER_DIR}"
        echo "Files updated successfully in the container!"
        ;;
    replace)
        echo "Replacing files in the container with local modified files..."
        docker cp "${HOST_DIR}/." "${CONTAINER_NAME}:${CONTAINER_DIR}" || {
            echo "Error: Failed to replace files."
            exit 1
        }
        echo "Files replaced successfully in the container!"
        ;;
    *)
        echo "Invalid step. Use 'copy_from', 'copy_to', or 'replace'."
        exit 1
        ;;
esac
