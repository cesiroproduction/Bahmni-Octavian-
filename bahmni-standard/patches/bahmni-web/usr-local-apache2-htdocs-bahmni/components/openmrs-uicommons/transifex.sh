#!/bin/bash

# Constants
TX_CONFIG_FILE=".tx/config"

# Function to check if a command exists
command_exists() {
    command -v "$1" >/dev/null 2>&1
}

# Function to exit with error message
exit_with_error() {
    echo "Error: $1"
    exit 1
}

# Function to install Transifex CLI
install_transifex_cli() {
    echo "Transifex CLI is not installed. Installing..."
    curl -o- https://raw.githubusercontent.com/transifex/cli/master/install.sh | bash
    mv tx /usr/local/bin/tx
}

# Check if Transifex CLI is installed
if ! command_exists tx; then
    install_transifex_cli
fi

# Check if Transifex config file exists
if [ ! -f "$TX_CONFIG_FILE" ]; then
    exit_with_error "Transifex config file ($TX_CONFIG_FILE) not found in the repository."
fi

# Perform Transifex operation based on input argument
if [ "$1" == "push" ]; then
    echo "Pushing translation source file to Transifex..."
    tx push -s
elif [ "$1" == "pull" ]; then
    echo "Pulling translations from Transifex..."
    tx pull -t -s --use-git-timestamps
else
    exit_with_error "Invalid operation. Please specify either 'push' or 'pull'."
fi

# Check if the operation was successful
if [ $? -ne 0 ]; then
    exit_with_error "Transifex operation failed. Please check the error message above."
else
    echo "Transifex operation completed successfully."
fi