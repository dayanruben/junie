#!/bin/bash
#
# Junie CLI Shim
#
# This script is the entry point for Junie CLI. It handles:
# 1. Applying pending updates before launching
# 2. Version selection via JUNIE_VERSION env or --use-version flag
# 3. Executing the appropriate version binary
#
# Installation locations:
#   Shim:     ~/.local/bin/junie
#   Data:     ~/.local/share/junie/
#   Versions: ~/.local/share/junie/versions/<version>/junie
#   Updates:  ~/.local/share/junie/updates/

set -euo pipefail

# === Configuration ===
JUNIE_DATA="${JUNIE_DATA:-$HOME/.local/share/junie}"
VERSIONS_DIR="$JUNIE_DATA/versions"
UPDATES_DIR="$JUNIE_DATA/updates"
CURRENT_LINK="$JUNIE_DATA/current"
PENDING_UPDATE="$UPDATES_DIR/pending-update.json"

# === Utility Functions ===

# Log message to stderr
log() {
  echo "[Junie] $*" >&2
}

# Check if a command exists
has_command() {
  command -v "$1" > /dev/null 2>&1
}

# Parse JSON field (basic, works without jq)
# Usage: parse_json "field" < file.json
parse_json_field() {
  local field="$1"
  # Extract value for "field": "value" or "field": number
  grep -o "\"$field\"[[:space:]]*:[[:space:]]*\"[^\"]*\"" | head -1 | sed 's/.*:[[:space:]]*"\([^"]*\)"/\1/' || true
}

# Parse JSON field with jq if available, fallback to grep
get_json_field() {
  local file="$1"
  local field="$2"

  if has_command jq; then
    jq -r ".$field // empty" "$file" 2>/dev/null || true
  else
    parse_json_field "$field" < "$file"
  fi
}

# Calculate SHA-256 checksum
sha256sum_file() {
  local file="$1"
  if has_command shasum; then
    shasum -a 256 "$file" | cut -d' ' -f1
  elif has_command sha256sum; then
    sha256sum "$file" | cut -d' ' -f1
  else
    log "Warning: No SHA-256 tool available, skipping checksum verification"
    echo ""
  fi
}

# Get binary path for an arbitrary version directory.
# Handles different package structures (macOS app bundle, Linux, direct binary).
get_binary_path_in() {
  local version_dir="$1"

  # macOS: look for .app bundle
  if [[ -d "$version_dir/Applications/junie.app" ]]; then
    echo "$version_dir/Applications/junie.app/Contents/MacOS/junie"
  # Linux: look for junie/bin/junie
  elif [[ -f "$version_dir/junie/bin/junie" ]]; then
    echo "$version_dir/junie/bin/junie"
  # Fallback: direct junie binary
  elif [[ -f "$version_dir/junie" ]]; then
    echo "$version_dir/junie"
  else
    echo ""
  fi
}

# Get binary path for a given version (by name).
get_binary_path() {
  local version="$1"
  get_binary_path_in "$VERSIONS_DIR/$version"
}

# Detect the archive type of $1 by extension or magic bytes.
# Echoes "unzip", "tar", or "" if unknown.
detect_archive_type() {
  local file="$1"
  case "$file" in
    *.zip|*.ZIP) echo "unzip"; return 0 ;;
    *.tar.gz|*.tgz|*.TAR.GZ|*.TGZ) echo "tar"; return 0 ;;
  esac
  local magic
  magic=$(head -c 4 "$file" 2>/dev/null | od -An -tx1 | tr -d ' \n' 2>/dev/null || echo "")
  case "$magic" in
    504b0304*|504b0506*|504b0708*) echo "unzip" ;;
    1f8b*)                          echo "tar"   ;;
    *)                              echo ""      ;;
  esac
}

# === Apply Pending Update ===
#
# Atomic extraction strategy:
#   1. Verify manifest and checksum.
#   2. Extract into a staging directory inside $VERSIONS_DIR (same FS, so `mv` is a rename).
#   3. Validate the resolved binary in the staging tree is executable.
#   4. Swap the staging dir into $VERSIONS_DIR/$version (replacing any previous tree
#      wholesale -- important for macOS .app code-signing consistency).
#   5. Flip the `current` symlink.
#   6. Only then delete the zip + pending manifest.
#
# Failure modes:
#   - Poisoned manifest (missing fields, missing zip, checksum mismatch):
#       drop manifest + zip, return non-zero.
#   - Retryable failure (extraction error, validation failure, missing extractor):
#       preserve manifest + zip so the next launch retries, return non-zero.
# In all failure cases $VERSIONS_DIR/$version is left untouched from before the attempt.
apply_pending_update() {
  if [[ ! -f "$PENDING_UPDATE" ]]; then
    return 0
  fi

  log "Applying pending update..."

  # Parse manifest
  local version zip_path sha256
  version=$(get_json_field "$PENDING_UPDATE" "version")
  zip_path=$(get_json_field "$PENDING_UPDATE" "zipPath")
  sha256=$(get_json_field "$PENDING_UPDATE" "sha256")

  if [[ -z "$version" || -z "$zip_path" ]]; then
    log "Invalid pending update manifest, skipping"
    rm -f "$PENDING_UPDATE"
    return 1
  fi

  if [[ ! -f "$zip_path" ]]; then
    log "Update file not found: $zip_path"
    rm -f "$PENDING_UPDATE"
    return 1
  fi

  # Verify checksum if available
  if [[ -n "$sha256" ]]; then
    local actual_sha256
    actual_sha256=$(sha256sum_file "$zip_path")

    # Case-insensitive comparison (compatible with bash 3.x on macOS)
    if [[ -n "$actual_sha256" ]] && ! echo "$actual_sha256" | grep -qi "^${sha256}$"; then
      log "Checksum mismatch, skipping update"
      log "Expected: $sha256"
      log "Got: $actual_sha256"
      rm -f "$PENDING_UPDATE" "$zip_path"
      return 1
    fi
  fi

  # Pick the right extractor by archive type. No silent wrong-tool fallback
  # (don't run tar on a zip).
  local extractor
  extractor=$(detect_archive_type "$zip_path")
  if [[ -z "$extractor" ]]; then
    log "Error: Unknown archive type for $zip_path; preserving update for retry"
    return 1
  fi
  if ! has_command "$extractor"; then
    log "Error: Required extraction tool '$extractor' not found; install it and retry"
    return 1
  fi

  # Staging path lives inside $VERSIONS_DIR so the final `mv` is a same-filesystem rename.
  local staging="$VERSIONS_DIR/.$version.tmp.$$"
  local old_dir="$VERSIONS_DIR/.$version.old.$$"

  # Catch signals during extraction so Ctrl-C / SIGTERM doesn't leave a partial
  # staging dir behind. (EXIT trap is not reliable for *function* returns, so we
  # also do explicit cleanup before every error return below.)
  # shellcheck disable=SC2064
  trap "rm -rf \"$staging\" \"$old_dir\"; trap - INT TERM; exit 130" INT TERM

  rm -rf "$staging"
  if ! mkdir -p "$staging"; then
    log "Error: Failed to create staging directory $staging"
    trap - INT TERM
    return 1
  fi

  log "Extracting to $staging..."

  if [[ "$extractor" == "unzip" ]]; then
    if ! unzip -q "$zip_path" -d "$staging"; then
      log "Error: Failed to extract $zip_path; preserving update for retry"
      rm -rf "$staging"
      trap - INT TERM
      return 1
    fi
  else
    if ! tar -xzf "$zip_path" -C "$staging"; then
      log "Error: Failed to extract $zip_path; preserving update for retry"
      rm -rf "$staging"
      trap - INT TERM
      return 1
    fi
  fi

  # Resolve the binary against the staging dir and ensure it is executable.
  local staged_binary
  staged_binary=$(get_binary_path_in "$staging")
  if [[ -z "$staged_binary" ]]; then
    log "Error: No junie binary found in extracted payload; preserving update for retry"
    rm -rf "$staging"
    trap - INT TERM
    return 1
  fi
  chmod +x "$staged_binary" 2>/dev/null || true
  if [[ ! -x "$staged_binary" ]]; then
    log "Error: Extracted binary is not executable: $staged_binary"
    rm -rf "$staging"
    trap - INT TERM
    return 1
  fi

  # Remove quarantine on macOS (best-effort)
  xattr -dr com.apple.quarantine "$staging" 2>/dev/null || true

  # Atomic swap: move existing version aside, then rename staging into place.
  # We replace the whole tree so macOS .app bundles stay code-sign-consistent.
  if [[ -e "$VERSIONS_DIR/$version" ]]; then
    rm -rf "$old_dir"
    if ! mv "$VERSIONS_DIR/$version" "$old_dir"; then
      log "Error: Failed to move existing version aside"
      rm -rf "$staging"
      trap - INT TERM
      return 1
    fi
  fi

  if ! mv "$staging" "$VERSIONS_DIR/$version"; then
    log "Error: Failed to install new version into $VERSIONS_DIR/$version"
    # Try to restore previous version if we moved it aside
    if [[ -e "$old_dir" && ! -e "$VERSIONS_DIR/$version" ]]; then
      mv "$old_dir" "$VERSIONS_DIR/$version" 2>/dev/null || true
    fi
    rm -rf "$staging" "$old_dir"
    trap - INT TERM
    return 1
  fi

  # Best-effort cleanup of the previous tree
  rm -rf "$old_dir" 2>/dev/null || true

  # Flip the current symlink atomically.
  ln -sfn "$VERSIONS_DIR/$version" "$CURRENT_LINK"

  # Drop pending artifacts only after a fully successful swap.
  rm -f "$zip_path" "$PENDING_UPDATE"

  trap - INT TERM

  log "Updated to version $version"
  return 0
}

# === Resolve Version ===
resolve_version() {
  local version=""

  # Priority 1: --use-version flag
  for arg in "$@"; do
    case "$arg" in
      --use-version=*)
        version="${arg#--use-version=}"
        break
        ;;
    esac
  done

  # Priority 2: JUNIE_VERSION environment variable
  if [[ -z "$version" && -n "${JUNIE_VERSION:-}" ]]; then
    version="$JUNIE_VERSION"
  fi

  # Priority 3: current symlink
  if [[ -z "$version" ]]; then
    if [[ -L "$CURRENT_LINK" ]]; then
      version=$(basename "$(readlink "$CURRENT_LINK")")
    elif [[ -d "$CURRENT_LINK" ]]; then
      # current might be a directory in some setups
      version=$(basename "$CURRENT_LINK")
    fi
  fi

  if [[ -z "$version" ]]; then
    log "Error: No version found. Please reinstall Junie."
    log "Run: curl -fsSL https://junie.jetbrains.com/install.sh | bash"
    exit 1
  fi

  # Verify version exists
  if [[ ! -d "$VERSIONS_DIR/$version" ]]; then
    log "Error: Version $version not found in $VERSIONS_DIR"
    log "Available versions:"
    ls -1 "$VERSIONS_DIR" 2>/dev/null || log "  (none)"
    exit 1
  fi

  echo "$version"
}

# === Filter Shim-Specific Arguments ===
# Global array to store filtered args (needed because bash can't return arrays)
FILTERED_ARGS=()

filter_args() {
  FILTERED_ARGS=()
  for arg in "$@"; do
    case "$arg" in
      --use-version=*) ;; # Skip shim-specific flag
      *) FILTERED_ARGS+=("$arg") ;;
    esac
  done
}

# === Handle Shim Commands ===
handle_shim_commands() {
  case "${1:-}" in
    --shim-version)
      echo "junie-shim 1.0.0"
      exit 0
      ;;
    --list-versions)
      echo "Installed versions:"
      if [[ -d "$VERSIONS_DIR" ]]; then
        local current_version=""
        if [[ -L "$CURRENT_LINK" ]]; then
          current_version=$(basename "$(readlink "$CURRENT_LINK")")
        fi
        for v in "$VERSIONS_DIR"/*/; do
          local vname
          vname=$(basename "$v")
          # Skip transient staging dirs (.<v>.tmp.<pid>, .<v>.old.<pid>) defensively.
          case "$vname" in .*) continue ;; esac
          if [[ "$vname" == "$current_version" ]]; then
            echo "  $vname (current)"
          else
            echo "  $vname"
          fi
        done
      else
        echo "  (none)"
      fi
      exit 0
      ;;
    --switch-version=*)
      local new_version="${1#--switch-version=}"
      if [[ ! -d "$VERSIONS_DIR/$new_version" ]]; then
        log "Error: Version $new_version not found"
        exit 1
      fi
      ln -sfn "$VERSIONS_DIR/$new_version" "$CURRENT_LINK"
      log "Switched to version $new_version"
      exit 0
      ;;
  esac
}

# === Main ===
main() {
  # Handle shim-specific commands
  handle_shim_commands "$@"

  # Apply pending update if present. On failure we deliberately do NOT abort:
  # the previous version is still on disk (via the `current` symlink) and should run.
  if ! apply_pending_update; then
    log "Update not applied; continuing with current version"
  fi

  # Resolve which version to run
  local version
  version=$(resolve_version "$@")

  # Get binary path (handles macOS app bundle, Linux, direct binary)
  local binary
  binary=$(get_binary_path "$version")

  if [[ -z "$binary" || ! -x "$binary" ]]; then
    log "Error: Binary not found or not executable for version $version"
    log "Looked in: $VERSIONS_DIR/$version"
    exit 1
  fi

  # Set required environment variable for Junie
  export EJ_RUNNER_PWD="${EJ_RUNNER_PWD:-$(pwd)}"

  # Set JUNIE_DATA for the app to know where data is stored
  export JUNIE_DATA="$JUNIE_DATA"

  # Filter out shim-specific args and execute
  filter_args "$@"
  exec "$binary" ${FILTERED_ARGS[@]+"${FILTERED_ARGS[@]}"}
}

main "$@"
