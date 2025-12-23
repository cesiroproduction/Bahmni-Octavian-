#!/usr/bin/env bash
set -o pipefail
shopt -s globstar 2>/dev/null || true

# --- Portability: Define Paths ---
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &> /dev/null && pwd)"
PATCHES_DIR="$SCRIPT_DIR"
IGNORE_FILE="$PATCHES_DIR/.bahmniignore"

# Path separator for multiple container paths in MODULES entries
PATH_SEP="|"

# Unique temp root per run; auto-cleaned on exit
TEMP_ROOT="$(mktemp -d /tmp/bahmni_sync_temp.XXXXXX)" || {
  echo "❌ Error: Could not create temp dir."
  exit 1
}
cleanup() { rm -rf "$TEMP_ROOT"; }
trap cleanup EXIT

# --- Define Your Modules Here ---
# Format:
#   "container:/path"                              (single path)
#   "container:/path1|/path2|/path3"               (multiple paths)
#   "container:/path1 | /path2 | /path3"           (spaces around | supported)
declare -A MODULES=(
  ["appointments"]="bahmni-standard-appointments-1:/usr/local/apache2/htdocs/appointments/i18n/appointments"
  ["bahmni-apps-frontend"]="bahmni-standard-bahmni-apps-frontend-1:/usr/local/apache2/htdocs/bahmni-new"
  ["bahmni-config"]="bahmni-standard-bahmni-config-1:/usr/local/bahmni_config/openmrs"
  ["bahmni-web"]="bahmni-standard-bahmni-web-1:/usr/local/apache2/htdocs/bahmni"
  ["dcm4chee"]="bahmni-standard-dcm4chee-1:/var/lib/bahmni/dcm4chee/server/default/deploy"
  ["microfrontend-ipd"]="ipd:/usr/local/apache2/htdocs/ipd/i18n"
  ["openelis"]="bahmni-standard-openelis-1:/run/bahmni-lab/bahmni-lab/pages/common | /run/bahmni-lab/bahmni-lab/WEB-INF/classes"
)

usage() {
  cat <<EOF
Usage: $0 <step> <module_name|all> [options]

Steps:
  copy_all    Copy all files (except ignored) from container -> patches
  copy_json   Copy only *.json files (except ignored) from container -> patches
  replace     Copy files from patches -> container (except ignored, excludes *.incoming)
  clean       Remove *.incoming files + remove empty directories (nested)

Modules:
  ${!MODULES[@]}
  all

Options:
  -d, --dry-run       Show what would change, do not modify patches/containers
  --show-ignored      Print ignored files while scanning (useful for debugging)
  -h, --help          Show this help

Ignore file (.bahmniignore):
  - Glob patterns like .gitignore
  - Supports negation with leading '!': last match wins
    Example:
      *.jsp
      !banner.jsp
EOF
}

# --- Dependency Check (host-side only) ---
for cmd in docker find mktemp cmp; do
  if ! command -v "$cmd" &> /dev/null; then
    echo "❌ Error: '$cmd' is not installed."
    exit 1
  fi
done

# --- Helpers ---
flatten_path() { echo "$1" | sed 's#^/##; s#/#-#g'; }

trim_ws() {
  local s="$1"
  s="${s#"${s%%[![:space:]]*}"}"
  s="${s%"${s##*[![:space:]]}"}"
  printf '%s' "$s"
}

# --- Ignore handling (glob + negation, gitignore-ish) ---
# We store patterns as-is (including possible leading '!').
declare -a IGNORE_PATTERNS=()

load_ignore_patterns() {
  IGNORE_PATTERNS=()
  [[ -s "$IGNORE_FILE" ]] || return 0

  while IFS= read -r line; do
    line="$(trim_ws "$line")"
    [[ -z "$line" ]] && continue
    [[ "$line" == \#* ]] && continue
    IGNORE_PATTERNS+=("$line")
  done < "$IGNORE_FILE"
}

# Internal: does a single (non-negated) pattern match a given relpath?
# - Supports:
#   - "foo" (basename)
#   - "*.jsp" (basename glob)
#   - "dir/" (directory anywhere)
#   - "a/b/c" (path glob)
#   - "/a/b" (anchored to module root)
pattern_matches() {
  local pat="$1"
  local rel="$2"
  local base="${rel##*/}"
  local anchored=false

  if [[ "$pat" == /* ]]; then
    anchored=true
    pat="${pat#/}"
  fi

  # Directory pattern
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
    return 1
  fi

  # Path pattern
  if [[ "$pat" == */* ]]; then
    if $anchored; then
      case "$rel" in
        $pat) return 0 ;;
      esac
    else
      case "$rel" in
        $pat|*/$pat) return 0 ;;
      esac
    fi
    return 1
  fi

  # Basename pattern
  case "$base" in
    $pat) return 0 ;;
  esac
  return 1
}

# should_ignore:
# - Evaluates patterns IN ORDER.
# - Each matching pattern sets the decision:
#     normal pattern => ignore=true
#     !pattern       => ignore=false
# - Last match wins.
should_ignore() {
  local rel="$1"
  local ignore=false

  local raw pat neg=false
  for raw in "${IGNORE_PATTERNS[@]}"; do
    neg=false
    pat="$raw"

    if [[ "$pat" == "!"* ]]; then
      neg=true
      pat="${pat:1}"
      pat="$(trim_ws "$pat")"
      [[ -z "$pat" ]] && continue
    fi

    if pattern_matches "$pat" "$rel"; then
      if $neg; then
        ignore=false
      else
        ignore=true
      fi
    fi
  done

  $ignore && return 0 || return 1
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

process_path_copy() {
  local container="$1"
  local container_path="$2"
  local host_path="$3"
  local module_temp="$4"

  if ! docker exec "$container" sh -c "test -e '$container_path'" >/dev/null 2>&1; then
    echo "❌ Error: Path does not exist in container: $container_path"
    return 0
  fi

  rm -rf "$module_temp" && mkdir -p "$module_temp" || {
    echo "❌ Error: Could not create temp dir: $module_temp"
    return 0
  }

  if ! docker cp "${container}:${container_path}/." "$module_temp" >/dev/null 2>&1; then
    echo "❌ Error: docker cp failed for ${container}:${container_path}"
    return 0
  fi

  mkdir -p "$host_path"

  local scanned=0 ignored=0 selected=0
  local would_sync=0 would_incoming=0
  local did_sync=0 did_incoming=0

  pushd "$module_temp" >/dev/null || return 0

  local FIND_CMD=()
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
}

process_path_replace() {
  local container="$1"
  local container_path="$2"
  local host_path="$3"
  local deploy_temp="$4"

  if [[ ! -d "$host_path" ]]; then
    echo "ℹ️  Nothing to replace: local patch path does not exist: $host_path"
    return 0
  fi

  rm -rf "$deploy_temp" && mkdir -p "$deploy_temp" || {
    echo "❌ Error: Could not create deploy temp dir: $deploy_temp"
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
}

process_path_clean() {
  local host_path="$1"

  if [[ ! -d "$host_path" ]]; then
    echo "ℹ️  Nothing to clean: local patch path does not exist: $host_path"
    return 0
  fi

  if $DRY_RUN; then
    echo "🧽 [DRY RUN] Would remove these *.incoming files under: $host_path"
    local incoming_list
    incoming_list="$(find "$host_path" -type f -name '*.incoming' -print 2>/dev/null)"
    if [[ -n "$incoming_list" ]]; then
      echo "$incoming_list" | sed 's/^/  - /'
    else
      echo "  (none)"
    fi

    echo "🧽 [DRY RUN] Would remove these empty directories AFTER deleting *.incoming (nested empties included):"

    local -A KEEP_DIRS=()

    while IFS= read -r -d '' f; do
      local d cur
      d="$(dirname "$f")"
      cur="$d"
      while true; do
        KEEP_DIRS["$cur"]=1
        [[ "$cur" == "$host_path" ]] && break
        cur="$(dirname "$cur")"
        [[ "$cur" == "/" ]] && break
      done
    done < <(find "$host_path" -type f ! -name '*.incoming' -print0 2>/dev/null)

    local printed=false
    while IFS= read -r -d '' d; do
      if [[ -z "${KEEP_DIRS[$d]:-}" ]]; then
        echo "  - ${d#"$host_path"/}"
        printed=true
      fi
    done < <(find "$host_path" -mindepth 1 -type d -print0 2>/dev/null)

    $printed || echo "  (none)"

  else
    local incoming_count dir_count

    incoming_count="$(find "$host_path" -type f -name '*.incoming' -print 2>/dev/null | wc -l | tr -d ' ')"
    find "$host_path" -type f -name '*.incoming' -delete 2>/dev/null

    # Remove empty directories (nested empties included). -depth ensures children first.
    # -mindepth 1 ensures we don't delete the host_path root itself.
    dir_count="$(find "$host_path" -mindepth 1 -depth -type d -empty -print -delete 2>/dev/null | wc -l | tr -d ' ')"

    echo "🧽 Removed $incoming_count *.incoming file(s) and $dir_count empty directorie(s) under: $host_path"
  fi
}

process_module() {
  local mod_name="$1"
  local config="${MODULES[$mod_name]}"

  local container="${config%%:*}"
  local paths_blob="${config#*:}"

  # Split paths by PATH_SEP, then trim whitespace around each path
  local -a paths=()
  IFS="$PATH_SEP" read -r -a paths <<< "$paths_blob"
  for i in "${!paths[@]}"; do
    paths[$i]="$(trim_ws "${paths[$i]}")"
  done

  echo -e "\n=========================================================="
  echo "🚀 Module: [$mod_name]"
  echo "📦 Container: $container"
  echo "📌 Paths:"
  for p in "${paths[@]}"; do
    [[ -n "$p" ]] && echo "  - $p"
  done
  echo "=========================================================="

  if [ "$(docker inspect -f '{{.State.Running}}' "$container" 2>/dev/null)" != "true" ]; then
    echo "❌ Error: Container '$container' is not running. Skipping module."
    return 0
  fi

  case "$STEP" in
    copy_all|copy_json)
      for container_path in "${paths[@]}"; do
        [[ -z "$container_path" ]] && continue

        local flattened_folder host_path module_temp
        flattened_folder="$(flatten_path "$container_path")"
        host_path="$PATCHES_DIR/$mod_name/$flattened_folder"
        module_temp="$TEMP_ROOT/$mod_name/$flattened_folder"

        echo -e "\n----------------------------------------------------------"
        echo "📂 Local Path: $host_path"
        echo "📦 Remote: $container:$container_path"
        echo "----------------------------------------------------------"

        process_path_copy "$container" "$container_path" "$host_path" "$module_temp"
      done
      ;;

    replace)
      for container_path in "${paths[@]}"; do
        [[ -z "$container_path" ]] && continue

        local flattened_folder host_path deploy_temp
        flattened_folder="$(flatten_path "$container_path")"
        host_path="$PATCHES_DIR/$mod_name/$flattened_folder"
        deploy_temp="$TEMP_ROOT/${mod_name}_deploy/$flattened_folder"

        echo -e "\n----------------------------------------------------------"
        echo "📂 Local Path: $host_path"
        echo "📦 Remote: $container:$container_path"
        echo "----------------------------------------------------------"

        process_path_replace "$container" "$container_path" "$host_path" "$deploy_temp"
      done
      ;;

    clean)
      for container_path in "${paths[@]}"; do
        [[ -z "$container_path" ]] && continue

        local flattened_folder host_path
        flattened_folder="$(flatten_path "$container_path")"
        host_path="$PATCHES_DIR/$mod_name/$flattened_folder"

        echo -e "\n----------------------------------------------------------"
        echo "📂 Clean Local Path: $host_path"
        echo "----------------------------------------------------------"

        process_path_clean "$host_path"
      done
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
