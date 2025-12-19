#!/bin/bash

# --- Portability: Define Paths based on Script Location ---
# This finds the absolute path of the script's directory
SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &> /dev/null && pwd)

# Adjust this based on where your script sits relative to the patches folder.
# If script is in patches/bahmni-config/bin/, use "$(realpath "$SCRIPT_DIR/../..")"
PATCHES_DIR=$(realpath "$SCRIPT_DIR/..")

CONTAINER_NAME="bahmni-standard-bahmni-config-1"
HOST_DIR="$PATCHES_DIR/bahmni-config/usr-local-bahmni_config"
CONTAINER_DIR="/usr/local/bahmni_config"
TEMP_DIR="/tmp/bahmni_sync_temp"
IGNORE_FILE="$PATCHES_DIR/.bahmniignore"

# --- Dependency Check ---
echo "Checking dependencies..."
for cmd in docker tar; do
    if ! command -v $cmd &> /dev/null; then
        echo "❌ Error: '$cmd' is not installed. Please install it to continue."
        exit 1
    fi
done

HAS_JQ=true
if ! command -v jq &> /dev/null; then
    echo "⚠️  Warning: 'jq' is not installed. JSON syntax validation will be skipped."
    HAS_JQ=false
fi

# --- Initialization ---
mkdir -p "$HOST_DIR"
[ ! -f "$IGNORE_FILE" ] && touch "$IGNORE_FILE"

# --- Usage Check ---
if [ "$#" -lt 1 ]; then
    echo "Usage: $0 <step>"
    echo "Steps:"
    echo "  copy_all   : Pull all files (respects .bahmniignore)"
    echo "  copy_json  : Pull JSON files (respects .bahmniignore)"
    echo "  replace    : Validate and push local files TO container"
    echo "  clean      : Delete all .incoming files"
    exit 1
fi

# Function to generate regex pattern from ignore file
get_ignore_regex() {
    if [ -s "$IGNORE_FILE" ]; then
        # Remove comments/empty lines, escape dots, convert * to .*, join with |
        grep -v '^#' "$IGNORE_FILE" | grep -v '^$' | sed 's/\./\\./g; s/\*/.*/g' | tr '\n' '|' | sed 's/|$//'
    else
        echo "NON_EXISTENT_PATTERN_MATCH"
    fi
}

STEP="$1"

case $STEP in
    copy_all|copy_json)
        IGNORE_PATTERN=$(get_ignore_regex)
        echo "Step: $STEP | Filtering with .bahmniignore..."
        rm -rf "$TEMP_DIR" && mkdir -p "$TEMP_DIR"

        FIND_CMD="find . -type f"
        [ "$STEP" == "copy_json" ] && FIND_CMD="find . -name '*.json'"

        # Remote find -> Grep filter -> Remote Tar -> Local Untar
        docker exec "$CONTAINER_NAME" sh -c "cd $CONTAINER_DIR && $FIND_CMD -print0" | \
        grep -zvE "$IGNORE_PATTERN" | \
        docker exec -i "$CONTAINER_NAME" sh -c "cd $CONTAINER_DIR && xargs -0 tar cf - 2>/dev/null" | \
        tar xf - -C "$TEMP_DIR" 2>/dev/null

        echo "Merging to $HOST_DIR..."
        if [ ! -d "$TEMP_DIR" ] || [ -z "$(ls -A "$TEMP_DIR" 2>/dev/null)" ]; then
             echo "No new files to copy."
        else
            cd "$TEMP_DIR"
            find . -type f | while read -r file; do
                relative_path="${file#./}"
                dest_file="$HOST_DIR/$relative_path"

                mkdir -p "$(dirname "$dest_file")"

                if [ -f "$dest_file" ]; then
                    if ! cmp -s "$file" "$dest_file"; then
                        cp "$file" "${dest_file}.incoming"
                        echo "⚠️  Preserved local: $relative_path (.incoming created)"
                    fi
                else
                    cp "$file" "$dest_file"
                    echo "✅ Added new: $relative_path"
                fi
            done
        fi
        rm -rf "$TEMP_DIR"
        ;;

    replace)
        echo "Validating local files..."
        ERROR_FOUND=0
        while IFS= read -r -d '' file; do
            if [ ! -s "$file" ]; then
                echo "❌ Empty file found: $file"
                ERROR_FOUND=1
            fi
            if [ "$HAS_JQ" = true ]; then
                if ! jq . "$file" >/dev/null 2>&1; then
                    echo "❌ Syntax error in: $file"
                    ERROR_FOUND=1
                fi
            fi
        done < <(find "$HOST_DIR" -name "*.json" -print0)

        [ $ERROR_FOUND -ne 0 ] && echo "Aborting replace due to errors." && exit 1

        echo "✅ Validation passed. Uploading..."
        docker cp "${HOST_DIR}/." "${CONTAINER_NAME}:${CONTAINER_DIR}"
        echo "Success!"
        ;;

    clean)
        echo "Cleaning up .incoming files..."
        find "$HOST_DIR" -name "*.incoming" -delete
        echo "Done."
        ;;

    *)
        echo "Invalid step. Options: copy_all, copy_json, replace, clean"
        exit 1
        ;;
esac