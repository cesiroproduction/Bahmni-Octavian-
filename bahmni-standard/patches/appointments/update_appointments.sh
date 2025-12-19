#!/bin/bash

# --- Configuration ---
CONTAINER_NAME="bahmni-standard-appointments-1"
HOST_DIR="/home/sam/Downloads/bahmni-docker/bahmni-standard/patches/appointments/usr-local-apache2-htdocs-appointments"
CONTAINER_DIR="/usr/local/apache2/htdocs/appointments"
TEMP_DIR="/tmp/bahmni_sync_temp"

# --- Ignore List ---
# Add files you want to skip. Format: "pattern1|pattern2|pattern3"
IGNORE_PATTERN="locale_de.json|locale_es.json|locale_km.json|locale_fr.json|locale_pt.json|locale_pt_BR.json|locale_lo.json|locale_ru.json|locale_zh.json|locale_vi.json|locale_ar.json|locale_el.json|locale_hi.json|locale_te.json|locale_ko.json|locale_it.json|locale_hr.json"

# --- Initialization ---
mkdir -p "$HOST_DIR"

# --- Usage Check ---
if [ "$#" -lt 1 ]; then
    echo "Usage: $0 <step>"
    echo "Steps:"
    echo "  copy_all   : Pull all files (excluding ignored ones)"
    echo "  copy_json  : Pull JSON files (excluding ignored ones)"
    echo "  replace    : Validate and push local files TO container"
    echo "  clean      : Delete all .incoming files"
    exit 1
fi

STEP="$1"

case $STEP in
    copy_all|copy_json)
        echo "Step: $STEP | Fetching from container (filtering ignored files)..."
        rm -rf "$TEMP_DIR" && mkdir -p "$TEMP_DIR"

        # Determine the find command based on the step
        if [ "$STEP" == "copy_all" ]; then
            FIND_CMD="find . -type f"
        else
            FIND_CMD="find . -name '*.json'"
        fi

        # We pull files via tar, but we use 'grep' to exclude the ignore patterns
        docker exec "$CONTAINER_NAME" sh -c "cd $CONTAINER_DIR && $FIND_CMD -print0" | \
        grep -zvE "$IGNORE_PATTERN" | \
        docker exec -i "$CONTAINER_NAME" sh -c "cd $CONTAINER_DIR && xargs -0 tar cf -" | \
        tar xf - -C "$TEMP_DIR"

        echo "Merging to $HOST_DIR..."
        if [ -z "$(ls -A "$TEMP_DIR" 2>/dev/null)" ]; then
             echo "No files found to copy (or all were ignored)."
        else
            cd "$TEMP_DIR"
            find . -type f | while read -r file; do
                relative_path="${file#./}"
                dest_file="$HOST_DIR/$relative_path"
                dest_dir=$(dirname "$dest_file")

                mkdir -p "$dest_dir"

                if [ -f "$dest_file" ]; then
                    if ! cmp -s "$file" "$dest_file"; then
                        cp "$file" "${dest_file}.incoming"
                        echo "⚠️  Kept local version: $relative_path (New version saved as .incoming)"
                    fi
                else
                    cp "$file" "$dest_file"
                    echo "✅ Added new file: $relative_path"
                fi
            done
        fi
        rm -rf "$TEMP_DIR"
        echo "Sync complete."
        ;;

    replace)
        echo "Validating JSON syntax before replacing..."

        if [ -z "$(ls -A "$HOST_DIR" 2>/dev/null)" ]; then
            echo "Error: Host directory is empty."
            exit 1
        fi

        ERROR_FOUND=0
        while IFS= read -r -d '' file; do
            if [ ! -s "$file" ]; then
                echo "❌ Error: File is empty: $file"
                ERROR_FOUND=1
            fi
            if command -v jq >/dev/null 2>&1; then
                if ! jq . "$file" >/dev/null 2>&1; then
                    echo "❌ Error: Syntax error in $file"
                    ERROR_FOUND=1
                fi
            fi
        done < <(find "$HOST_DIR" -name "*.json" -print0)

        if [ $ERROR_FOUND -ne 0 ]; then
            echo "Validation failed. Push aborted."
            exit 1
        fi

        echo "✅ Validation passed. Uploading to container..."
        # Note: This copies everything currently in your HOST_DIR.
        # If you previously copied a file and now it's in the ignore list,
        # it will still be uploaded IF it exists on your host.
        docker cp "${HOST_DIR}/." "${CONTAINER_NAME}:${CONTAINER_DIR}"
        echo "Success!"
        ;;

    clean)
        echo "Cleaning up .incoming files..."
        find "$HOST_DIR" -name "*.incoming" -delete
        echo "Cleanup done."
        ;;

    *)
        echo "Invalid step. Options: copy_all, copy_json, replace, clean"
        exit 1
        ;;
esac