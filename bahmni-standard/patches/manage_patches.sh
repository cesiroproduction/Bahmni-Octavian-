#!/usr/bin/env bash
set -o pipefail

# --- Portability: Define Paths ---
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &> /dev/null && pwd)"
PATCHES_DIR="$SCRIPT_DIR"
IGNORE_FILE="$PATCHES_DIR/.bahmniignore"

# Unique temp root per run; auto-cleaned on exit
TEMP_ROOT="$(mktemp -d /tmp/bahmni_sync_temp.XXXXXX)" || {
  echo "❌ Error: Could not create temp dir."
  exit 1
}
cleanup() { rm -rf "$TEMP_ROOT"; }
trap cleanup EXIT

# --- Define Your Modules Here ---
declare -A MODULES=(
  ["bahmni-config"]="bahmni-standard-bahmni-config-1:/usr/local/bahmni_config"
  ["bahmni-web"]="bahmni-standard-bahmni-web-1:/usr/local/apache2/htdocs/bahmni"
  ["bahmni-apps-frontend"]="bahmni-standard-bahmni-apps-frontend-1:/usr/local/apache2/htdocs/bahmni-new"
  ["appointments"]="bahmni-standard-appointments-1:/usr/local/apache2/htdocs/appointments"
  ["microfrontend-ipd"]="ipd:/usr/local/apache2/htdocs/ipd"
)

usage() {
  cat <<EOF
Usage: $0 <step> <module_name|all> [options]

Steps:
  copy_all    Copy all files (except ignored) from container -> patches
  copy_json   Copy only *.json files (except ignored) from container -> patches
  replace     Copy files from patches -> container (except ignored, excludes *.incoming)
  clean       Remove *.incoming files under the module's patch folder

Modules:
  ${!MODULES[@]}
  all

Options:
  -d, --dry-run       Show what would change, do not modify patches/containers
  --show-ignored      Print ignored files while scanning (useful for debugging)
  -h, --help          Show this help
EOF
}

# --- Dependency Check (host-side only) ---
for cmd in docker find mktemp cmp; do
  if ! command -v "$cmd" &> /dev/null; then
    echo "❌ Error: '$cmd' is not installed."
    exit 1
  fi
done

# --- Ignore handling (glob-based) ---
declare -a IGNORE_PATTERNS=()

load_ignore_patterns() {
  IGNORE_PATTERNS=()
  [[ -s "$IGNORE_FILE" ]] || return 0

  while IFS= read -r line; do
    # Trim leading/trailing whitespace
    line="${line#"${line%%[![:space:]]*}"}"
    line="${line%"${line##*[![:space:]]}"}"

    # Skip blanks and comments
    [[ -z "$line" ]] && continue
    [[ "$line" == \#* ]] && continue

    IGNORE_PATTERNS+=("$line")
  done < "$IGNORE_FILE"
}

# Returns 0 (true) if relpath should be ignored
# Semantics:
#   - "foo" matches any basename "foo"
#   - "*.js" matches any basename ending .js (does NOT match .json)
#   - "dir/" ignores that directory anywhere
#   - "a/b/c" matches that relative path (or anywhere if not anchored)
#   - "/a/b" anchored match from module root (optional)
should_ignore() {
  local rel="$1"           # e.g. "foo/bar/baz.json"
  local base="${rel##*/}"  # e.g. "baz.json"

  local pat anchored
  for pat in "${IGNORE_PATTERNS[@]}"; do
    anchored=false

    # Optional root anchor: "/something"
    if [[ "$pat" == /* ]]; then
      anchored=true
      pat="${pat#/}"
    fi

    # Directory ignore: "fonts/"
    if [[ "$pat" == */ ]]; then
      local dir="${pat%/}"

      if $anchored; then
        case "$rel" in
          $dir/*) return 0 ;;
        esac
      else
        case "$rel" in
          $dir/*|*/$dir/*) return 0 ;;
        esac
      fi

    # Path glob ignore (contains '/'): "path/to/*.json"
    elif [[ "$pat" == */* ]]; then
      if $anchored; then
        case "$rel" in
          $pat) return 0 ;;
        esac
      else
        case "$rel" in
          $pat|*/$pat) return 0 ;;
        esac
      fi

    # Basename ignore: "*.js" or "app.json"
    else
      case "$base" in
        $pat) return 0 ;;
      esac
    fi
  done

  return 1
}

# --- Parse args (options can be anywhere) ---
DRY_RUN=false
SHOW_IGNORED=false
POSITIONAL=()

for arg in "$@"; do
  case "$arg" in
    -d|--dry-run) DRY_RUN=true ;;
    --show-ignored) SHOW_IGNORED=true ;;
    -h|--help) usage; exit 0 ;;
    *) POSITIONAL+=("$arg") ;;
  esac
done
set -- "${POSITIONAL[@]}"

if [ "$#" -lt 2 ]; then
  usage
  exit 1
fi

STEP="$1"
TARGET_MODULE="$2"

load_ignore_patterns
echo "🧹 Loaded ${#IGNORE_PATTERNS[@]} ignore patterns from: $IGNORE_FILE"
$DRY_RUN && echo "🔍 DRY RUN MODE ACTIVATED - No changes will be made."

process_module() {
  local mod_name="$1"
  local config="${MODULES[$mod_name]}"

  # Parse "container:path"
  local container="${config%%:*}"
  local container_path="${config#*:}"

  local flattened_folder
  flattened_folder="$(echo "$container_path" | sed 's/^\///; s/\//-/g')"
  local host_path="$PATCHES_DIR/$mod_name/$flattened_folder"

  echo -e "\n----------------------------------------------------------"
  echo "🚀 Module: [$mod_name]"
  echo "📂 Local Path: $host_path"
  echo "📦 Remote: $container:$container_path"
  echo "----------------------------------------------------------"

  # Check container running
  if [ "$(docker inspect -f '{{.State.Running}}' "$container" 2>/dev/null)" != "true" ]; then
    echo "❌ Error: Container '$container' is not running. Skipping."
    return 0
  fi

  case "$STEP" in
    copy_all|copy_json)
      # Validate path exists in container
      if ! docker exec "$container" sh -c "test -e '$container_path'" >/dev/null 2>&1; then
        echo "❌ Error: Path does not exist in container: $container_path"
        return 0
      fi

      local module_temp="$TEMP_ROOT/$mod_name"
      rm -rf "$module_temp" && mkdir -p "$module_temp" || {
        echo "❌ Error: Could not create temp dir for module."
        return 0
      }

      # Copy contents of container_path into module temp
      if ! docker cp "${container}:${container_path}/." "$module_temp" >/dev/null 2>&1; then
        echo "❌ Error: docker cp failed for ${container}:${container_path}"
        return 0
      fi

      mkdir -p "$host_path"

      local scanned=0 ignored=0 selected=0
      local would_sync=0 would_incoming=0
      local did_sync=0 did_incoming=0

      pushd "$module_temp" >/dev/null || return 0

      if [[ "$STEP" == "copy_json" ]]; then
        FIND_CMD=(find . -type f -name '*.json' -print0)
      else
        FIND_CMD=(find . -type f -print0)
      fi

      while IFS= read -r -d '' file; do
        scanned=$((scanned + 1))
        local relative_path="${file#./}"

        if should_ignore "$relative_path"; then
          ignored=$((ignored + 1))
          $SHOW_IGNORED && echo "🙈 Ignored: $relative_path"
          continue
        fi

        selected=$((selected + 1))
        local dest_file="$host_path/$relative_path"

        if $DRY_RUN; then
          if [[ -f "$dest_file" ]] && ! cmp -s "$file" "$dest_file"; then
            echo "⚠️  Would update: $relative_path (.incoming)"
            would_incoming=$((would_incoming + 1))
          else
            echo "✅ Would sync: $relative_path"
            would_sync=$((would_sync + 1))
          fi
        else
          mkdir -p "$(dirname "$dest_file")"
          if [[ -f "$dest_file" ]] && ! cmp -s "$file" "$dest_file"; then
            cp "$file" "${dest_file}.incoming"
            echo "⚠️  Update: $relative_path (.incoming created)"
            did_incoming=$((did_incoming + 1))
          else
            cp "$file" "$dest_file"
            echo "✅ Synced: $relative_path"
            did_sync=$((did_sync + 1))
          fi
        fi
      done < <("${FIND_CMD[@]}")

      popd >/dev/null || true

      if $DRY_RUN; then
        echo "📊 Summary: scanned=$scanned ignored=$ignored selected=$selected would_sync=$would_sync would_incoming=$would_incoming"
      else
        echo "📊 Summary: scanned=$scanned ignored=$ignored selected=$selected synced=$did_sync incoming=$did_incoming"
      fi
      ;;

    replace)
      if [[ ! -d "$host_path" ]]; then
        echo "ℹ️  Nothing to replace: local patch path does not exist: $host_path"
        return 0
      fi

      # Stage only non-ignored, non-.incoming files into a temp deploy folder
      local deploy_temp="$TEMP_ROOT/${mod_name}_deploy"
      rm -rf "$deploy_temp" && mkdir -p "$deploy_temp" || {
        echo "❌ Error: Could not create deploy temp dir."
        return 0
      }

      local scanned=0 ignored=0 staged=0 skipped_incoming=0

      pushd "$host_path" >/dev/null || return 0
      while IFS= read -r -d '' file; do
        scanned=$((scanned + 1))
        local relative_path="${file#./}"

        # Never deploy *.incoming by default
        if [[ "$relative_path" == *.incoming ]]; then
          skipped_incoming=$((skipped_incoming + 1))
          continue
        fi

        if should_ignore "$relative_path"; then
          ignored=$((ignored + 1))
          $SHOW_IGNORED && echo "🙈 Ignored (deploy): $relative_path"
          continue
        fi

        local out="$deploy_temp/$relative_path"
        mkdir -p "$(dirname "$out")"
        cp "$file" "$out"
        staged=$((staged + 1))
      done < <(find . -type f -print0)
      popd >/dev/null || true

      if [[ "$staged" -eq 0 ]]; then
        echo "ℹ️  No files to deploy after filtering (ignored=$ignored, skipped_incoming=$skipped_incoming)."
        return 0
      fi

      if $DRY_RUN; then
        echo "🔁 Would deploy $staged file(s) to $container:$container_path"
        echo "📊 Summary: scanned=$scanned ignored=$ignored skipped_incoming=$skipped_incoming staged=$staged"
      else
        # Ensure destination exists
        if ! docker exec "$container" sh -c "mkdir -p '$container_path'" >/dev/null 2>&1; then
          echo "❌ Error: Could not create destination dir in container: $container_path"
          return 0
        fi

        if ! docker cp "$deploy_temp/." "${container}:${container_path}" >/dev/null 2>&1; then
          echo "❌ Error: docker cp deploy failed to ${container}:${container_path}"
          return 0
        fi

        echo "✅ Deployed $staged file(s) to $container:$container_path"
        echo "📊 Summary: scanned=$scanned ignored=$ignored skipped_incoming=$skipped_incoming staged=$staged"
      fi
      ;;

    clean)
      if [[ ! -d "$host_path" ]]; then
        echo "ℹ️  Nothing to clean: local patch path does not exist: $host_path"
        return 0
      fi

      if $DRY_RUN; then
        echo "🧽 [DRY RUN] Would remove these *.incoming files under: $host_path"
        find "$host_path" -type f -name '*.incoming' -print | sed 's/^/  - /'
      else
        local count
        count="$(find "$host_path" -type f -name '*.incoming' -print | wc -l | tr -d ' ')"
        find "$host_path" -type f -name '*.incoming' -delete
        echo "🧽 Removed $count *.incoming file(s) under: $host_path"
      fi
      ;;

    *)
      echo "❌ Unknown step: $STEP"
      usage
      return 1
      ;;
  esac
}

# --- Execution ---
if [[ "$TARGET_MODULE" == "all" ]]; then
  for mod in "${!MODULES[@]}"; do
    process_module "$mod"
  done
else
  if [[ -n "${MODULES[$TARGET_MODULE]:-}" ]]; then
    process_module "$TARGET_MODULE"
  else
    echo "❌ Module '$TARGET_MODULE' not found."
    usage
    exit 1
  fi
fi
