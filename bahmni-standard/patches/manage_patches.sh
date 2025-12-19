#!/bin/bash

# --- Portability: Define Paths ---
SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &> /dev/null && pwd)
PATCHES_DIR="$SCRIPT_DIR"
IGNORE_FILE="$PATCHES_DIR/.bahmniignore"
TEMP_DIR="/tmp/bahmni_sync_temp"

# --- Define Your Modules Here ---
declare -A MODULES
MODULES=(
    ["bahmni-config"]="bahmni-standard-bahmni-config-1:/usr/local/bahmni_config"
    ["bahmni-web"]="bahmni-standard-bahmni-web-1:/usr/local/apache2/htdocs/bahmni"
    ["appointments"]="bahmni-standard-appointments-1:/usr/local/apache2/htdocs/appointments"
)

# --- Argument Parsing for Dry Run ---
DRY_RUN=false
for arg in "$@"; do
    if [[ "$arg" == "-d" || "$arg" == "--dry-run" ]]; then
        DRY_RUN=true
        echo "🔍 DRY RUN MODE ACTIVATED - No changes will be made."
    fi
done

# --- Dependency Check ---
for cmd in docker tar jq; do
    if ! command -v $cmd &> /dev/null; then
        [ "$cmd" == "jq" ] && echo "⚠️  Warning: 'jq' missing, skipping syntax checks." && HAS_JQ=false && continue
        echo "❌ Error: '$cmd' is not installed." && exit 1
    fi
    HAS_JQ=true
done

# --- Usage Check ---
if [ "$#" -lt 2 ]; then
    echo "Usage: $0 <step> <module_name|all> [-d|--dry-run]"
    echo "Steps: copy_all, copy_json, replace, clean"
    echo "Modules: ${!MODULES[@]} (or use 'all')"
    exit 1
fi

STEP="$1"
TARGET_MODULE="$2"

get_ignore_regex() {
    [ -s "$IGNORE_FILE" ] && grep -v '^#' "$IGNORE_FILE" | grep -v '^$' | sed 's/\./\\./g; s/\*/.*/g' | tr '\n' '|' | sed 's/|$//' || echo "NON_EXISTENT_PATTERN"
}

process_module() {
    local mod_name=$1
    local config=${MODULES[$mod_name]}
    local container=$(echo $config | cut -d':' -f1)
    local container_path=$(echo $config | cut -d':' -f2)

    local flattened_folder=$(echo "$container_path" | sed 's/^\///; s/\//-/g')
    local host_path="$PATCHES_DIR/$mod_name/$flattened_folder"

    echo -e "\n----------------------------------------------------------"
    echo "🚀 Module: [$mod_name]"
    echo "📂 Local Path: $host_path"
    echo "📦 Remote: $container:$container_path"
    echo "----------------------------------------------------------"

    # Check if container is running
    if [ "$(docker inspect -f '{{.State.Running}}' "$container" 2>/dev/null)" != "true" ]; then
        echo "❌ Error: Container '$container' is not running. Skipping."
        return
    fi

    case $STEP in
        copy_all|copy_json)
            IGNORE_PATTERN=$(get_ignore_regex)
            # Clean and recreate Temp Dir for EVERY module
            rm -rf "$TEMP_DIR" && mkdir -p "$TEMP_DIR"

            FIND_CMD="find . -type f"
            [ "$STEP" == "copy_json" ] && FIND_CMD="find . -name '*.json'"

            if $DRY_RUN; then
                echo "[DRY RUN] Would fetch files from $container..."
                docker exec "$container" sh -c "cd $container_path && $FIND_CMD -print0" | grep -zvE "$IGNORE_PATTERN" | tr '\0' '\n' | sed 's/^/  - /'
            else
                # Pull files
                docker exec "$container" sh -c "cd $container_path && $FIND_CMD -print0" | \
                grep -zvE "$IGNORE_PATTERN" | \
                docker exec -i "$container" sh -c "cd $container_path && xargs -0 tar cf - 2>/dev/null" | \
                tar xf - -C "$TEMP_DIR" 2>/dev/null

                if [ ! -d "$TEMP_DIR" ] || [ -z "$(ls -A "$TEMP_DIR" 2>/dev/null)" ]; then
                    echo "ℹ️  No files found matching criteria in this container."
                else
                    # CRITICAL FIX: Use an absolute path or subshell to prevent directory drift
                    (
                        cd "$TEMP_DIR"
                        find . -type f | while read -r file; do
                            relative_path="${file#./}"
                            dest_file="$host_path/$relative_path"
                            mkdir -p "$(dirname "$dest_file")"
                            if [ -f "$dest_file" ] && ! cmp -s "$file" "$dest_file"; then
                                cp "$file" "${dest_file}.incoming"
                                echo "⚠️  Update: $relative_path (.incoming created)"
                            else
                                cp "$file" "$dest_file"
                                echo "✅ Synced: $relative_path"
                            fi
                        done
                    )
                fi
            fi
            # Return to SCRIPT_DIR just to be safe for the next iteration
            cd "$SCRIPT_DIR"
            ;;

        replace)
            # ... (replace logic remains the same)
            ;;

        clean)
            # ... (clean logic remains the same)
            ;;
    esac
}

# --- Execution ---
if [ "$TARGET_MODULE" == "all" ]; then
    for mod in "${!MODULES[@]}"; do
        process_module "$mod"
    done
else
    [[ -n "${MODULES[$TARGET_MODULE]}" ]] && process_module "$TARGET_MODULE" || (echo "❌ Module '$TARGET_MODULE' not found." && exit 1)
fi