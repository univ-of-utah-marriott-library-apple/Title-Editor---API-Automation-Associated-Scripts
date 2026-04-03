#!/usr/bin/env bash
set -euo pipefail

# update_title_editor_versions.sh
#
# A flexible, scheduler-friendly wrapper to automate Title Editor patch batch updates from various sources.
#
# Revised Date: 2026.03.30
# Version: 1.2.29
#
# Scheduler-friendly wrapper that:
# 1) Builds a Title Editor patch batch file using existing scripts
# 2) Optionally imports it via title_editor_menu.sh --add-patch-batch
# 3) Tracks last seen version in a simple state file
#
# Defaults:
# - item: title-editor
# - channel: stable
# - apply/import: enabled
#
# Examples:
#   bash update_title_editor_versions.sh
#   bash update_title_editor_versions.sh --channel beta --dry-run
#   bash update_title_editor_versions.sh --item title-editor --no-import
#
# Copyright (c) 2026 University of Utah, Marriott Library IT.
# All Rights Reserved.
#
# Permission to use, copy, modify, and distribute this software and
# its documentation for any purpose and without fee is hereby granted,
# provided that the above copyright notice appears in all copies and
# that both that copyright notice and this permission notice appear
# in supporting documentation, and that the name of The University
# of Utah not be used in advertising or publicity pertaining to
# distribution of the software without specific, written prior
# permission. This software is supplied as is without expressed or
# implied warranties of any kind.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

GITHUB_BATCH_SCRIPT="${SCRIPT_DIR}/build_title_editor_batch_from_github.sh"
RELEASE_NOTES_BATCH_SCRIPT="${SCRIPT_DIR}/build_title_editor_batch_from_release_notes.sh"
JAMF_PATCH_BATCH_SCRIPT="${SCRIPT_DIR}/build_title_editor_batch_from_jamf_patch_catalog.sh"
TITLE_EDITOR_MENU_SCRIPT="${SCRIPT_DIR}/title_editor_menu.sh"

STATE_FILE="${STATE_FILE:-${SCRIPT_DIR}/.title_editor_version_state.env}"
OUTPUT_DIR="${OUTPUT_DIR:-/tmp/title_editor_batch_updates}"

ITEM="title-editor"
CHANNEL="stable"
LIMIT="1"
APPLY=1
DO_IMPORT=1
DRY_RUN=0
DEBUG=0
VERBOSE=0
ITEM_EXPLICIT=0
CHECK_MODE="current-only"
RUN_ALL=1
ALLOW_INCOMPLETE_CONFIG=0
LAST_ITEM_STATUS=""
LAST_ITEM_NOTE=""

log() { printf '%s %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*"; }
warn() { printf '%s WARN: %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" >&2; }
die() { printf '%s ERROR: %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" >&2; exit 1; }
vlog() { [[ "$VERBOSE" -eq 1 || "$DEBUG" -eq 1 ]] && log "$*" || true; }

run_cmd_with_output_control() {
  local label="$1"
  shift
  local -a cmd=("$@")

  if [[ "$VERBOSE" -eq 1 || "$DEBUG" -eq 1 ]]; then
    "${cmd[@]}"
    return $?
  fi

  local tmp_out
  tmp_out=$(mktemp /tmp/update_title_editor_versions.XXXXXX)

  if "${cmd[@]}" >"$tmp_out" 2>&1; then
    rm -f "$tmp_out" >/dev/null 2>&1 || true
    return 0
  fi

  if [[ "$DEBUG" -eq 1 ]]; then
    warn "${label} failed. Showing recent output:"
    tail -n 40 "$tmp_out" >&2 || true
  else
    warn "${label} failed. Re-run with --debug for details."
  fi
  rm -f "$tmp_out" >/dev/null 2>&1 || true
  return 1
}

list_available_items() {
  echo "Available --item values:"
  while IFS= read -r k; do
    [[ -n "$k" ]] && echo "  $k"
  done < <(list_all_items)
}

list_all_items() {
  awk '
    /^configure_item\(\)/ { in_fn=1; next }
    in_fn && /^}/ { in_fn=0 }
    in_fn && /case "\$key" in/ { in_case=1; next }
    in_case && /^[[:space:]]*esac[[:space:]]*$/ { in_case=0; next }
    in_case {
      if ($0 ~ /^[[:space:]]*#/) next
      if ($0 ~ /^[[:space:]]*[a-z0-9][a-z0-9-]*\)[[:space:]]*$/) {
        key=$0
        sub(/^[[:space:]]*/, "", key)
        sub(/\)[[:space:]]*$/, "", key)
        if (key != "*") print key
      }
    }
  ' "$0"
}

require_file() {
  local file_path="$1"
  [[ -f "$file_path" ]] || die "Required file not found: $file_path"
}

normalize_key_part() {
  echo "$1" | tr '[:lower:]' '[:upper:]' | sed -E 's/[^A-Z0-9]+/_/g; s/^_+//; s/_+$//'
}

build_current_version_key() {
  local item_part channel_part
  item_part="$(normalize_key_part "$ITEM")"
  channel_part="$(normalize_key_part "$CHANNEL")"
  echo "${item_part}_${channel_part}_VERSION"
}

build_version_key_for() {
  local item="$1"
  local channel="$2"
  local item_part channel_part
  item_part="$(normalize_key_part "$item")"
  channel_part="$(normalize_key_part "$channel")"
  echo "${item_part}_${channel_part}_VERSION"
}

load_state() {
  if [[ -f "$STATE_FILE" ]]; then
    # shellcheck disable=SC1090
    source "$STATE_FILE"
  fi
}

save_state_kv() {
  local key="$1"
  local value="$2"

  mkdir -p "$(dirname "$STATE_FILE")"
  touch "$STATE_FILE"

  if grep -qE "^${key}=" "$STATE_FILE"; then
    sed -i '' -E "s|^${key}=.*|${key}=${value}|" "$STATE_FILE"
  else
    printf '%s=%s\n' "$key" "$value" >> "$STATE_FILE"
  fi
}

delete_state_kv() {
  local key="$1"
  [[ -f "$STATE_FILE" ]] || return 0
  sed -i '' -E "/^${key}=/d" "$STATE_FILE"
}

show_help() {
  cat <<'EOF'
Usage:
  bash update_title_editor_versions.sh [options]

Options:
  --all                   Run all configured items (this is the default)
  --item <key>            Run only one item key (default behavior runs all items)
  --channel <name>        stable|beta|nightly (default: stable)
  --limit <n|all>         Max versions to include in batch (default: 1)
  --current-only          Only process the latest version (equivalent to --limit 1)
  --full-check            Process all discovered versions (equivalent to --limit all)
  --verbose               Show detailed output from wrapper and child scripts
  --debug                 Enable debug output (implies --verbose)
  --state-file <path>     Override state file path
  --output-dir <path>     Override output dir for batch files
  --no-apply              Do not update state file
  --no-import             Build batch only (skip title_editor_menu import)
  --dry-run               Show actions but do not run builder/import/state write
  --help                  Show this help

Notes:
  - This wrapper reuses existing scripts:
    - build_title_editor_batch_from_github.sh
    - build_title_editor_batch_from_release_notes.sh
    - title_editor_menu.sh
  - Channel handling:
    - stable  : excludes prerelease
    - beta    : includes prerelease
    - nightly : includes prerelease
EOF
}

# Per-item config section. Add new software items here.
configure_item() {
  local key="$1"

  ITEM_NAME=""
  TITLE_NAME=""
  VERSION_METHOD=""
  SOURCE_REPO=""
  SOURCE_URL=""
  SOURCE_URL_FALLBACK=""
  SOURCE_VERSION_REGEX=""
  MAC_APP_STORE_NAME=""
  JAMF_PATCH_TITLE_ID=""
  JAMF_PATCH_SOFTWARE_NAME=""
  JAMF_PATCH_SOURCE_MODE="${JAMF_PATCH_SOURCE_MODE:-jamf-pro}"
  SOURCE_MODE="auto"
  EXAMPLE_ONLY=false

  case "$key" in
      amphetamine)
      ITEM_NAME="Amphetamine"
      TITLE_NAME="Amphetamine"
      VERSION_METHOD="MAC_APP_STORE"
      MAC_APP_STORE_NAME="Amphetamine"
      ;;

    apple-remote-desktop)
      ITEM_NAME="Apple Remote Desktop"
      TITLE_NAME="Apple Remote Desktop"
      VERSION_METHOD="MAC_APP_STORE"
      MAC_APP_STORE_NAME="Apple Remote Desktop"
      ;;

    archaeology)
      ITEM_NAME="Archaeology"
      TITLE_NAME="Archaeology"
      VERSION_METHOD="RELEASE_NOTES"
      SOURCE_URL="https://mothersruin.com/software/Archaeology/relnotes.html"
      ;;

    cmake)
      ITEM_NAME="CMake"
      TITLE_NAME="CMake"
      VERSION_METHOD="GITHUB"
      SOURCE_REPO="Kitware/CMake"
      SOURCE_MODE="auto"
      ;;

    compressor)
      ITEM_NAME="Compressor"
      TITLE_NAME="Compressor"
      VERSION_METHOD="MAC_APP_STORE"
      MAC_APP_STORE_NAME="Compressor"
      ;;

    download-shuttle)
      ITEM_NAME="Download Shuttle"
      TITLE_NAME="Download Shuttle"
      VERSION_METHOD="MAC_APP_STORE"
      MAC_APP_STORE_NAME="Download Shuttle"
      ;;

    draw-io)
      ITEM_NAME="draw.io"
      TITLE_NAME="draw.io"
      VERSION_METHOD="GITHUB"
      SOURCE_REPO="jgraph/drawio-desktop"
      SOURCE_MODE="auto"
      ;;

    eclipse-ide-java)
      ITEM_NAME="Eclipse IDE for Java Developers"
      TITLE_NAME="Eclipse IDE for Java Developers"
      VERSION_METHOD="RELEASE_NOTES"
      SOURCE_URL="https://www.eclipse.org/downloads/packages/"
      SOURCE_URL_FALLBACK="https://archive.eclipse.org/eclipse/downloads/"
      ;;

    espanso)
      ITEM_NAME="Espanso"
      TITLE_NAME="Espanso"
      VERSION_METHOD="GITHUB"
      SOURCE_REPO="espanso/espanso"
      SOURCE_MODE="auto"
      ;;

    final-cut-pro)
      ITEM_NAME="Final Cut Pro"
      TITLE_NAME="Final Cut Pro"
      VERSION_METHOD="MAC_APP_STORE"
      MAC_APP_STORE_NAME="Final Cut Pro"
      ;;

    firefox)
      ITEM_NAME="Firefox"
      TITLE_NAME="Firefox"
      VERSION_METHOD="RELEASE_NOTES"
      SOURCE_URL="https://www.mozilla.org/en-US/firefox/releases/"
      ;;

    google-drive)
      ITEM_NAME="Google Drive"
      TITLE_NAME="Google Drive"
      VERSION_METHOD="JAMF_PATCH"
      JAMF_PATCH_TITLE_ID="${GOOGLE_DRIVE_JAMF_PATCH_ID:-}"
      JAMF_PATCH_SOFTWARE_NAME="${GOOGLE_DRIVE_JAMF_PATCH_SOFTWARE_NAME:-Google Drive (Jamf)}"
      ;;

    google-earth-pro)
      ITEM_NAME="Google Earth Pro"
      TITLE_NAME="Google Earth Pro"
      VERSION_METHOD="JAMF_PATCH"
      JAMF_PATCH_TITLE_ID="${GOOGLE_EARTH_PRO_JAMF_PATCH_ID:-}"
      JAMF_PATCH_SOFTWARE_NAME="${GOOGLE_EARTH_PRO_JAMF_PATCH_SOFTWARE_NAME:-Google Earth Pro (Jamf)}"
      ;;

    goodnotes)
      ITEM_NAME="Goodnotes"
      TITLE_NAME="Goodnotes"
      VERSION_METHOD="MAC_APP_STORE"
      MAC_APP_STORE_NAME="Goodnotes"
      ;;

    horos)
      ITEM_NAME="Horos"
      TITLE_NAME="Horos"
      VERSION_METHOD="GITHUB"
      SOURCE_REPO="horosproject/horos"
      SOURCE_MODE="auto"
      ;;

    ice)
      ITEM_NAME="Ice"
      TITLE_NAME="Ice"
      VERSION_METHOD="GITHUB"
      SOURCE_REPO="jordanbaird/Ice"
      SOURCE_MODE="auto"
      ;;

    iina)
      ITEM_NAME="IINA"
      TITLE_NAME="IINA"
      VERSION_METHOD="GITHUB"
      SOURCE_REPO="iina/iina"
      SOURCE_MODE="auto"
      ;;

    keyaccess)
      ITEM_NAME="KeyAccess"
      TITLE_NAME="KeyAccess"
      VERSION_METHOD="HTML_REGEX"
      SOURCE_URL="https://solutions.teamdynamix.com/TDClient/1965/Portal/KB/ArticleDet?ID=169236"
      SOURCE_VERSION_REGEX='[0-9]+\.[0-9]+(\.[0-9]+)+'
      ;;

    mist)
      ITEM_NAME="Mist"
      TITLE_NAME="Mist"
      VERSION_METHOD="GITHUB"
      SOURCE_REPO="ninxsoft/Mist"
      SOURCE_MODE="auto"
      ;;

    low-profile)
      ITEM_NAME="Low Profile"
      TITLE_NAME="Low Profile"
      VERSION_METHOD="GITHUB"
      SOURCE_REPO="ninxsoft/LowProfile"
      SOURCE_MODE="auto"
      ;;

    keyboard-maestro)
      ITEM_NAME="Keyboard Maestro"
      TITLE_NAME="Keyboard Maestro"
      VERSION_METHOD="RELEASE_NOTES"
      SOURCE_URL="https://wiki.keyboardmaestro.com/manual/Whats_New"
      ;;

    logic-pro)
      ITEM_NAME="Logic Pro"
      TITLE_NAME="Logic Pro"
      VERSION_METHOD="MAC_APP_STORE"
      MAC_APP_STORE_NAME="Logic Pro"
      ;;

    motion)
      ITEM_NAME="Motion"
      TITLE_NAME="Motion"
      VERSION_METHOD="MAC_APP_STORE"
      MAC_APP_STORE_NAME="Motion"
      ;;

    opera)
      ITEM_NAME="Opera"
      TITLE_NAME="Opera"
      VERSION_METHOD="JAMF_PATCH"
      JAMF_PATCH_TITLE_ID="${OPERA_JAMF_PATCH_ID:-501}"
      JAMF_PATCH_SOFTWARE_NAME="${OPERA_JAMF_PATCH_SOFTWARE_NAME:-Opera (Jamf)}"
      ;;

    plistedit-pro)
      ITEM_NAME="PlistEdit Pro"
      TITLE_NAME="PlistEdit Pro"
      VERSION_METHOD="RELEASE_NOTES"
      SOURCE_URL="https://www.fatcatsoftware.com/plisteditpro/Docs/releasenotes.html"
      ;;

    praat)
      ITEM_NAME="Praat"
      TITLE_NAME="Praat"
      VERSION_METHOD="GITHUB"
      SOURCE_REPO="praat/praat.github.io"
      SOURCE_MODE="auto"
      ;;

    pycharm-ce)
      ITEM_NAME="PyCharm CE"
      TITLE_NAME="PyCharm CE"
      VERSION_METHOD="RELEASE_NOTES"
      SOURCE_URL="https://www.jetbrains.com/pycharm/download/other/"
      ;;

    supercollider)
      ITEM_NAME="SuperCollider"
      TITLE_NAME="SuperCollider"
      VERSION_METHOD="GITHUB"
      SOURCE_REPO="supercollider/supercollider"
      SOURCE_MODE="auto"
      ;;

    terminus)
      ITEM_NAME="Termius"
      TITLE_NAME="Termius"
      VERSION_METHOD="MAC_APP_STORE"
      MAC_APP_STORE_NAME="Termius"
      ;;

    xcode)
      ITEM_NAME="Xcode"
      TITLE_NAME="Xcode"
      VERSION_METHOD="MAC_APP_STORE"
      MAC_APP_STORE_NAME="Xcode"
      ;;

    # Example for release notes mode:
    # my-release-notes-item)
    #   ITEM_NAME="My Software"
    #   TITLE_NAME="My Software"
    #   VERSION_METHOD="RELEASE_NOTES"
    #   SOURCE_URL="https://vendor.example.com/release-notes"
    #   ;;

    # Example for Mac App Store mode:
    # my-mas-item)
    #   ITEM_NAME="My MAS App"
    #   TITLE_NAME="My MAS App"
    #   VERSION_METHOD="MAC_APP_STORE"
    #   MAC_APP_STORE_NAME="My MAS App"
    #   ;;

    *)
      die "Unknown item: ${key}"
      ;;
  esac

  if [[ "$EXAMPLE_ONLY" == "true" ]]; then
    warn "Skipping item '${key}': marked as EXAMPLE_ONLY. Set SOURCE_REPO and remove EXAMPLE_ONLY to activate."
    LAST_ITEM_NOTE="example only"
    return 2
  fi

  if [[ "$VERSION_METHOD" == "GITHUB" && -z "$SOURCE_REPO" ]]; then
    if [[ "$ALLOW_INCOMPLETE_CONFIG" -eq 1 ]]; then
      warn "Skipping item '${key}': SOURCE_REPO required for VERSION_METHOD=GITHUB (set TITLE_EDITOR_SOURCE_REPO or hardcode owner/repo)."
      LAST_ITEM_NOTE="incomplete config"
      return 2
    fi
    die "SOURCE_REPO is required for item '${key}' when VERSION_METHOD=GITHUB. Set TITLE_EDITOR_SOURCE_REPO or hardcode owner/repo in configure_item()."
  fi

  if [[ "$VERSION_METHOD" == "HTML_REGEX" ]]; then
    [[ -n "$SOURCE_URL" ]] || die "SOURCE_URL is required for HTML_REGEX"
    [[ -n "$SOURCE_VERSION_REGEX" ]] || die "SOURCE_VERSION_REGEX is required for HTML_REGEX"
  fi
}

# Build batch by delegating to existing scripts.
run_batch_builder() {
  local output_file="$1"

  case "$VERSION_METHOD" in
    GITHUB)
      local cmd=(
        bash "$GITHUB_BATCH_SCRIPT"
        --non-interactive
        --repo "$SOURCE_REPO"
        --title-name "$TITLE_NAME"
        --output "$output_file"
        --source "$SOURCE_MODE"
        --limit "$LIMIT"
      )

      if [[ "$CHANNEL" == "beta" || "$CHANNEL" == "nightly" ]]; then
        cmd+=(--include-prerelease)
      fi

      [[ "$DEBUG" -eq 1 ]] && cmd+=(--debug)

      if [[ "$DRY_RUN" -eq 1 ]]; then
        vlog "DRY-RUN build: ${cmd[*]}"
      else
        run_cmd_with_output_control "GitHub batch build" "${cmd[@]}"
      fi
      ;;

    RELEASE_NOTES)
      [[ -n "$SOURCE_URL" ]] || die "SOURCE_URL is required for RELEASE_NOTES"

      local cmd=(
        bash "$RELEASE_NOTES_BATCH_SCRIPT"
        --non-interactive
        --url "$SOURCE_URL"
        --title-name "$TITLE_NAME"
        --output "$output_file"
        --limit "$LIMIT"
      )

      [[ "$DEBUG" -eq 1 ]] && cmd+=(--debug)

      if [[ "$DRY_RUN" -eq 1 ]]; then
        vlog "DRY-RUN build: ${cmd[*]}"
      else
        run_cmd_with_output_control "Release-notes batch build" "${cmd[@]}"
      fi
      ;;

    MAC_APP_STORE)
      [[ -n "$MAC_APP_STORE_NAME" ]] || die "MAC_APP_STORE_NAME is required for MAC_APP_STORE"

      local cmd=(
        bash "$RELEASE_NOTES_BATCH_SCRIPT"
        --non-interactive
        --mac-app-store
        --mac-app-store-name "$MAC_APP_STORE_NAME"
        --title-name "$TITLE_NAME"
        --output "$output_file"
        --limit "$LIMIT"
      )

      [[ "$DEBUG" -eq 1 ]] && cmd+=(--debug)

      if [[ "$DRY_RUN" -eq 1 ]]; then
        vlog "DRY-RUN build: ${cmd[*]}"
      else
        run_cmd_with_output_control "Mac App Store batch build" "${cmd[@]}"
      fi
      ;;

    JAMF_PATCH)
      local cmd=(
        bash "$JAMF_PATCH_BATCH_SCRIPT"
        --source "$JAMF_PATCH_SOURCE_MODE"
        --title-name "$TITLE_NAME"
        --output "$output_file"
        --limit "$LIMIT"
      )
      if [[ -n "$JAMF_PATCH_TITLE_ID" ]]; then
        cmd+=(--jamf-pro-title-id "$JAMF_PATCH_TITLE_ID")
      else
        [[ -n "$JAMF_PATCH_SOFTWARE_NAME" ]] || die "Set JAMF_PATCH_TITLE_ID or JAMF_PATCH_SOFTWARE_NAME for JAMF_PATCH"
        cmd+=(--software-name "$JAMF_PATCH_SOFTWARE_NAME")
      fi

      [[ "$DEBUG" -eq 1 ]] && cmd+=(--debug)

      if [[ "$DRY_RUN" -eq 1 ]]; then
        vlog "DRY-RUN build: ${cmd[*]}"
      else
        run_cmd_with_output_control "Jamf Patch batch build" "${cmd[@]}"
      fi
      ;;

    HTML_REGEX)
      [[ -n "$SOURCE_URL" ]] || die "SOURCE_URL is required for HTML_REGEX"
      [[ -n "$SOURCE_VERSION_REGEX" ]] || die "SOURCE_VERSION_REGEX is required for HTML_REGEX"

      if [[ "$DRY_RUN" -eq 1 ]]; then
        vlog "DRY-RUN build: curl -sL '$SOURCE_URL' | grep -Eo '$SOURCE_VERSION_REGEX' | sort -V"
        return 0
      fi

      local html_file versions_asc_file versions_desc_file
      html_file=$(mktemp /tmp/update_title_editor_versions_html.XXXXXX)
      versions_asc_file=$(mktemp /tmp/update_title_editor_versions_versions_asc.XXXXXX)
      versions_desc_file=$(mktemp /tmp/update_title_editor_versions_versions_desc.XXXXXX)

      if ! curl --silent --show-error --fail --location --max-time 60 --connect-timeout 15 "$SOURCE_URL" >"$html_file"; then
        rm -f "$html_file" "$versions_asc_file" "$versions_desc_file" >/dev/null 2>&1 || true
        warn "Failed to fetch URL: $SOURCE_URL"
        return 1
      fi

      if ! grep -Eo "$SOURCE_VERSION_REGEX" "$html_file" | awk 'NF && !seen[$0]++' | sort -V > "$versions_asc_file"; then
        rm -f "$html_file" "$versions_asc_file" "$versions_desc_file" >/dev/null 2>&1 || true
        warn "Failed to parse versions from URL: $SOURCE_URL"
        return 1
      fi

      if [[ ! -s "$versions_asc_file" ]]; then
        rm -f "$html_file" "$versions_asc_file" "$versions_desc_file" >/dev/null 2>&1 || true
        warn "No versions found at URL: $SOURCE_URL"
        return 1
      fi

      awk 'NF{a[++n]=$0} END{for(i=n;i>=1;i--) print a[i]}' "$versions_asc_file" > "$versions_desc_file"

      local max_rows=""
      if [[ "$LIMIT" != "all" ]]; then
        if ! [[ "$LIMIT" =~ ^[0-9]+$ ]] || [[ "$LIMIT" -lt 1 ]]; then
          rm -f "$html_file" "$versions_asc_file" "$versions_desc_file" >/dev/null 2>&1 || true
          die "LIMIT must be a positive integer or all (current value: $LIMIT)"
        fi
        max_rows="$LIMIT"
      fi

      {
        echo "title_name|version"
        local count=0
        local parsed_version=""
        while IFS= read -r parsed_version; do
          [[ -z "$parsed_version" ]] && continue
          echo "${TITLE_NAME}|${parsed_version}"
          count=$((count + 1))
          if [[ -n "$max_rows" && "$count" -ge "$max_rows" ]]; then
            break
          fi
        done < "$versions_desc_file"
      } > "$output_file"

      rm -f "$html_file" "$versions_asc_file" "$versions_desc_file" >/dev/null 2>&1 || true

      if ! awk -F'|' 'NR>1 && NF>=2 { found=1; exit } END { exit(found ? 0 : 1) }' "$output_file"; then
        warn "Built batch file has no version rows: $output_file"
        return 1
      fi
      ;;

    *)
      die "Unsupported VERSION_METHOD: $VERSION_METHOD"
      ;;
  esac
}

extract_latest_version_from_batch() {
  local batch_file="$1"
  awk -F'|' 'NR==2 {print $2; exit}' "$batch_file"
}

import_batch_into_title_editor() {
  local batch_file="$1"
  local cmd=(
    bash "$TITLE_EDITOR_MENU_SCRIPT"
    --add-patch-batch
    --file "$batch_file"
    --yes
  )

  if [[ "$DRY_RUN" -eq 1 ]]; then
    vlog "DRY-RUN import: ${cmd[*]}"
  else
    run_cmd_with_output_control "Title Editor import" "${cmd[@]}"
  fi
}

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --all)
        RUN_ALL=1
        ITEM_EXPLICIT=0
        shift
        ;;
      --item)
        ITEM="${2:-}"
        ITEM_EXPLICIT=1
        RUN_ALL=0
        shift 2
        ;;
      --channel)
        CHANNEL="${2:-}"
        shift 2
        ;;
      --limit)
        LIMIT="${2:-}"
        CHECK_MODE="custom"
        shift 2
        ;;
      --current-only)
        LIMIT="1"
        CHECK_MODE="current-only"
        shift
        ;;
      --full-check)
        LIMIT="all"
        CHECK_MODE="full-check"
        shift
        ;;
      --state-file)
        STATE_FILE="${2:-}"
        shift 2
        ;;
      --output-dir)
        OUTPUT_DIR="${2:-}"
        shift 2
        ;;
      --no-apply)
        APPLY=0
        shift
        ;;
      --no-import)
        DO_IMPORT=0
        shift
        ;;
      --dry-run)
        DRY_RUN=1
        shift
        ;;
      --debug)
        DEBUG=1
        VERBOSE=1
        shift
        ;;
      --verbose)
        VERBOSE=1
        shift
        ;;
      --help|-h)
        show_help
        exit 0
        ;;
      *)
        die "Unknown argument: $1"
        ;;
    esac
  done
}

process_item() {
  local item_key="$1"
  ITEM="$item_key"

  LAST_ITEM_STATUS="FAILED"
  LAST_ITEM_NOTE=""

  configure_item "$ITEM"
  local cfg_rc=$?
  if [[ "$cfg_rc" -ne 0 ]]; then
    if [[ "$cfg_rc" -eq 2 ]]; then
      LAST_ITEM_STATUS="SKIPPED"
      # LAST_ITEM_NOTE is set by configure_item's warn message path; use it if present
      [[ -z "$LAST_ITEM_NOTE" ]] && LAST_ITEM_NOTE="incomplete config"
    fi
    return "$cfg_rc"
  fi

  # Jamf patch workflows often rely on user-scoped Keychain credentials.
  # When running as root (for example via Jamf policy), fail fast unless
  # explicit root-safe env credentials are provided.
  if [[ "$VERSION_METHOD" == "JAMF_PATCH" && "${EUID:-$(id -u)}" -eq 0 ]]; then
    if [[ -z "${JAMF_PRO_URL:-}" || -z "${JAMF_CLIENT_ID:-}" || -z "${JAMF_CLIENT_SECRET:-}" ]]; then
      echo "ERROR: JAMF_PATCH item '${ITEM}' cannot run as root with user-saved credentials." >&2
      echo "ERROR: Run as the credentialed user OR set env vars for root context:" >&2
      echo "ERROR:   JAMF_PRO_URL, JAMF_CLIENT_ID, JAMF_CLIENT_SECRET" >&2
      LAST_ITEM_STATUS="FAILED"
      LAST_ITEM_NOTE="root-context jamf credentials missing"
      return 1
    fi
  fi

  mkdir -p "$OUTPUT_DIR"
  local output_file="${OUTPUT_DIR%/}/${ITEM}_${CHANNEL}_batch.txt"
  rm -f "$output_file"

  local CURRENT_VERSION_KEY
  CURRENT_VERSION_KEY="$(build_current_version_key)"
  local FORCE_RESYNC=0
  local LEGACY_VERSION_KEY=""

  load_state
  local current_version latest_version
  current_version="${!CURRENT_VERSION_KEY:-}"

  # One-time Firefox migration:
  # Older runs used mozilla-firefox as the item key and may have left stale state.
  # If that legacy key exists, force one import pass and then clean the old key.
  if [[ "$ITEM" == "firefox" ]]; then
    LEGACY_VERSION_KEY="$(build_version_key_for "mozilla-firefox" "$CHANNEL")"
    if [[ -n "${!LEGACY_VERSION_KEY:-}" ]]; then
      FORCE_RESYNC=1
      log "Legacy state key detected (${LEGACY_VERSION_KEY}); forcing one-time Firefox resync."
    fi
  fi

  vlog "Item: ${ITEM_NAME}"
  vlog "Method: ${VERSION_METHOD}"
  vlog "Channel: ${CHANNEL}"
  vlog "Check mode: ${CHECK_MODE} (limit=${LIMIT})"
  vlog "Current key: ${CURRENT_VERSION_KEY}"
  vlog "Current version: ${current_version:-<none>}"

  if ! run_batch_builder "$output_file"; then
    if [[ "$VERSION_METHOD" == "RELEASE_NOTES" && -n "$SOURCE_URL_FALLBACK" ]]; then
      local primary_url="$SOURCE_URL"
      warn "Primary release-notes source failed for '${ITEM}'. Retrying fallback URL: ${SOURCE_URL_FALLBACK}"
      SOURCE_URL="$SOURCE_URL_FALLBACK"
      if ! run_batch_builder "$output_file"; then
        SOURCE_URL="$primary_url"
        LAST_ITEM_STATUS="FAILED"
        LAST_ITEM_NOTE="batch build failed"
        return 1
      fi
      SOURCE_URL="$primary_url"
    else
      LAST_ITEM_STATUS="FAILED"
      LAST_ITEM_NOTE="batch build failed"
      return 1
    fi
  fi

  if [[ "$DRY_RUN" -eq 1 ]]; then
    LAST_ITEM_STATUS="DRY_RUN"
    LAST_ITEM_NOTE="no changes applied"
    log "DRY-RUN complete. No state changes and no import performed."
    return 0
  fi

  [[ -s "$output_file" ]] || die "Batch file missing/empty: $output_file"

  latest_version="$(extract_latest_version_from_batch "$output_file")"
  [[ -n "$latest_version" ]] || die "Could not extract latest version from: $output_file"

  log "Latest version from batch: ${latest_version}"

  if [[ "$latest_version" == "$current_version" && "$FORCE_RESYNC" -eq 0 ]]; then
    LAST_ITEM_STATUS="LATEST_VERSION"
    LAST_ITEM_NOTE="$latest_version"
    log "No change detected. Skipping import/state update."
    return 0
  fi

  log "Update detected: ${current_version:-<none>} -> ${latest_version}"

  if [[ "$DO_IMPORT" -eq 1 ]]; then
    if ! import_batch_into_title_editor "$output_file"; then
      LAST_ITEM_STATUS="FAILED"
      LAST_ITEM_NOTE="import failed"
      return 1
    fi
    log "Import completed via title_editor_menu.sh"
  else
    log "Import skipped (--no-import). Batch file ready: $output_file"
  fi

  if [[ "$APPLY" -eq 1 ]]; then
    save_state_kv "$CURRENT_VERSION_KEY" "$latest_version"
    log "State updated: ${CURRENT_VERSION_KEY}=${latest_version}"
    if [[ -n "$LEGACY_VERSION_KEY" ]]; then
      delete_state_kv "$LEGACY_VERSION_KEY"
      log "Removed legacy state key: ${LEGACY_VERSION_KEY}"
    fi
  else
    log "State update skipped (--no-apply)."
  fi

  LAST_ITEM_STATUS="UPDATED"
  LAST_ITEM_NOTE="${current_version:-<none>} -> ${latest_version}"

  return 0
}

main() {
  parse_args "$@"

  if [[ "${EUID:-$(id -u)}" -eq 0 ]]; then
    echo "ERROR: Do not run update_title_editor_versions.sh as root/administrator." >&2
    echo "ERROR: This workflow requires a standard user context (for user-scoped credentials)." >&2
    echo "ERROR: Re-run as the credentialed standard user." >&2
    exit 1
  fi

  if [[ "$CHECK_MODE" == "current-only" && "$LIMIT" != "1" ]]; then
    die "--current-only cannot be combined with a different --limit value"
  fi
  if [[ "$CHECK_MODE" == "full-check" && "$LIMIT" != "all" ]]; then
    die "--full-check cannot be combined with a different --limit value"
  fi

  case "$CHANNEL" in
    stable|beta|nightly) ;;
    *) die "--channel must be one of: stable|beta|nightly" ;;
  esac

  require_file "$GITHUB_BATCH_SCRIPT"
  require_file "$RELEASE_NOTES_BATCH_SCRIPT"
  require_file "$JAMF_PATCH_BATCH_SCRIPT"
  require_file "$TITLE_EDITOR_MENU_SCRIPT"

  if [[ "$RUN_ALL" -eq 1 ]]; then
    ALLOW_INCOMPLETE_CONFIG=1

    local total=0
    local ok=0
    local skipped=0
    local failed=0
    local item_key rc
    local -a ok_items=()
    local -a skipped_items=()
    local -a failed_items=()
    local -a status_lines=()

    while IFS= read -r item_key; do
      [[ -z "$item_key" ]] && continue
      total=$((total + 1))
      log "Processing ${total}: ${item_key}"
      if process_item "$item_key"; then
        ok=$((ok + 1))
        ok_items+=("$item_key")
        status_lines+=("${item_key}=${LAST_ITEM_STATUS}${LAST_ITEM_NOTE:+ (${LAST_ITEM_NOTE})}")
      else
        rc=$?
        if [[ "$rc" -eq 2 ]]; then
          skipped=$((skipped + 1))
          skipped_items+=("$item_key")
          status_lines+=("${item_key}=SKIPPED (${LAST_ITEM_NOTE:-incomplete config})")
        else
          failed=$((failed + 1))
          failed_items+=("$item_key")
          status_lines+=("${item_key}=FAILED")
        fi
      fi
    done < <(list_all_items)

    log ""
    log "================ Run Summary ================"
    log "Items discovered: ${total}"
    log "Processed successfully: ${ok}"
    if [[ "${#ok_items[@]}" -gt 0 ]]; then
      log "Successful items: ${ok_items[*]}"
    fi
    log "Skipped: ${skipped}"
    if [[ "${#skipped_items[@]}" -gt 0 ]]; then
      log "Skipped items: ${skipped_items[*]}"
    fi
    log "Failed: ${failed}"
    if [[ "${#failed_items[@]}" -gt 0 ]]; then
      log "Failed items: ${failed_items[*]}"
    fi
    if [[ "${#status_lines[@]}" -gt 0 ]]; then
      log "Per-item status:"
      local status_line
      for status_line in "${status_lines[@]}"; do
        log "  ${status_line}"
      done
    fi
    log "============================================"
    [[ "$failed" -eq 0 ]]
    return
  fi

  process_item "$ITEM"
}

main "$@"
