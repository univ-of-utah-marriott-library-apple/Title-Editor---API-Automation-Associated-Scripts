#!/usr/bin/env bash
#
# Title Editor API Interactive Menu
# Version: 1.5.6
# Revised: 2026.03.16
#
# Provides an interactive command-line menu to browse and view software titles from the Jamf Title Editor API.
# Also supports programmatic patch creation via CLI flags and batch files.
#
# Designed to be run after sourcing title_editor_api_ctrl.sh, which provides the API connection and request functions.
# Must be connected to a server to use the menu.
#
# The menu allows you to:
# - Search and select software titles
# - View details about a title, including requirements, extension attributes, and patches
# - View details about specific patch versions, including kill apps, components, and capabilities
# - Add a new patch version to a title with pre-populated defaults based on the most
#   recent patch
# - Create new software titles with --create-title
# - Create patches non-interactively with --add-patch
# - Create multiple patches from a file with --add-patch-batch --file
# - In batch mode, skip duplicate versions and process oldest-to-newest per title
# - Resequence existing patch order for consistent web/UI ordering
# - Auto-resequence touched titles after batch create/repair operations (unless disabled)
#
# Usage:
#   source title_editor_api_ctrl.sh   # must be sourced first
#   bash title_editor_menu.sh
#   bash title_editor_menu.sh --create-title --title-name <name> [--new-title-id <id>] [--version <version>] [options]
#   bash title_editor_menu.sh --add-patch --title-id <id>|--title-name <name> --version <version> [options]
#   bash title_editor_menu.sh --add-patch-batch --file <path>
#   bash title_editor_menu.sh --export-title-json --title-id <id>|--title-name <name> [--output <path>]
#   Batch file (pipe-delimited):
#     title_id|title_name|version|release_date|min_os|standalone|reboot|bundle_id|app_name|yes
#     or short format: title_name|version
#     (Required per row: version + title_id OR title_name; lines starting with # are ignored)
#
# Or source both and run the menu function directly:
#   source title_editor_api_ctrl.sh
#   source title_editor_menu.sh
#   tem_main
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

script_version="1.5.6"
TEM_DEBUG_CREDENTIALS="${TITLE_EDITOR_MENU_DEBUG:-false}"
TEM_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

TEM_CLI_MODE=""
TEM_CLI_TITLE_ID=""
TEM_CLI_TITLE_NAME=""
TEM_CLI_VERSION=""
TEM_CLI_RELEASE_DATE=""
TEM_CLI_MIN_OS=""
TEM_CLI_STANDALONE=""
TEM_CLI_REBOOT=""
TEM_CLI_BUNDLE_ID=""
TEM_CLI_APP_NAME=""
TEM_CLI_YES=false
TEM_CLI_BATCH_FILE=""
TEM_CLI_START_LINE=""
TEM_CLI_MAX_ROWS=""
TEM_CLI_DRY_RUN=false
TEM_CLI_VERIFY_ONLY=false
TEM_CLI_REPAIR_BATCH_EXISTING=false
TEM_CLI_REPAIR_RECREATE_EXISTING=false
TEM_CLI_RESEQUENCE_MODE=false
TEM_CLI_CLEANUP_NON_SEMVER=false
TEM_CLI_CREATE_TITLE=false
TEM_CLI_NEW_TITLE_ID_STRING=""
TEM_CLI_TITLE_JSON_FILE=""
TEM_CLI_PUBLISHER=""
TEM_CLI_OUTPUT_FILE=""
TEM_NONINTERACTIVE=false

TEM_KEYCHAIN_SERVICE="TitleEditorAPI"
TEM_KEYCHAIN_ACCOUNT_HOST="title_editor_host"
TEM_KEYCHAIN_ACCOUNT_USER="title_editor_user"
TEM_KEYCHAIN_ACCOUNT_PASS="title_editor_password"
TEM_KEYCHAIN_PATH="${HOME}/Library/Keychains/login.keychain-db"

###############################################################################
# HELPERS
###############################################################################

# Print a section header
_tem_header() {
  echo ""
  echo "=================================================="
  echo "  $1"
  echo "=================================================="
}

# Print a divider
_tem_divider() {
  echo "--------------------------------------------------"
}

# Pause and wait for user to press Enter
_tem_pause() {
  [[ "$TEM_NONINTERACTIVE" == "true" ]] && return 0
  echo ""
  if [[ -r /dev/tty ]]; then
    read -r -p "Press Enter to continue..." < /dev/tty
  else
    read -r -p "Press Enter to continue..."
  fi
}

# Prompt user for input
# @param $1  Prompt text
# @stdout    User input
_tem_prompt() {
  echo -n "$1 " >&2
  if [[ "$TEM_NONINTERACTIVE" == "true" ]]; then
    # Avoid hanging in automation when no interactive input is expected.
    return 1
  fi
  if [[ -r /dev/tty ]]; then
    read -r input < /dev/tty
  else
    read -r input
  fi
  echo "$input"
}

# Numbered menu selector
# @param $@  Menu items
# @stdout    Selected index (1-based)
_tem_menu() {
  local items=("$@")
  local i=1
  for item in "${items[@]}"; do
    echo "  $i) $item"
    (( i++ ))
  done
  echo ""
  local choice
  choice=$(_tem_prompt "Enter number:")
  echo "$choice"
}

_tem_secret_fingerprint() {
  local value="$1"
  if [[ -z "$value" ]]; then
    printf '%s' "empty"
    return 0
  fi

  if command -v shasum >/dev/null 2>&1; then
    printf '%s' "$value" | shasum -a 256 | awk '{print substr($1,1,12)}'
  elif command -v openssl >/dev/null 2>&1; then
    printf '%s' "$value" | openssl dgst -sha256 | awk '{print substr($NF,1,12)}'
  else
    printf '%s' "nohash"
  fi
}

_tem_debug_log() {
  [[ "$TEM_DEBUG_CREDENTIALS" == "true" ]] || return 0
  echo "[DEBUG] $1"
}

# Guard API helper calls so a single request cannot hang the entire batch.
# Uses a subshell process timeout independent of curl internals.
_tem_call_with_guard_timeout() {
  local timeout_s="$1"
  shift
  local cmd_display="$*"
  local status_interval
  status_interval="${TEM_API_STATUS_INTERVAL:-15}"

  local stdout_file stderr_file
  stdout_file=$(mktemp /tmp/tem_api_stdout.XXXXXX)
  stderr_file=$(mktemp /tmp/tem_api_stderr.XXXXXX)

  ( "$@" ) >"$stdout_file" 2>"$stderr_file" &
  local pid=$!
  local elapsed=0

  while kill -0 "$pid" >/dev/null 2>&1; do
    if (( status_interval > 0 )) && (( elapsed > 0 )) && (( elapsed % status_interval == 0 )); then
      printf '%s\n' "INFO: API call still running (${elapsed}s/${timeout_s}s): ${cmd_display}" >&2
    fi

    if (( elapsed >= timeout_s )); then
      kill -TERM "$pid" >/dev/null 2>&1 || true
      sleep 1
      kill -KILL "$pid" >/dev/null 2>&1 || true
      wait "$pid" >/dev/null 2>&1 || true

      printf '%s\n' "ERROR: API call timed out after ${timeout_s}s: $*" >&2
      if [[ -s "$stderr_file" ]]; then
        cat "$stderr_file" >&2
      fi

      rm -f "$stdout_file" "$stderr_file" >/dev/null 2>&1 || true
      return 124
    fi

    sleep 1
    ((elapsed++))
  done

  wait "$pid"
  local rc=$?

  if [[ -s "$stdout_file" ]]; then
    cat "$stdout_file"
  fi

  # Preserve stderr on failures so callers still get diagnostics.
  if [[ "$rc" -ne 0 && -s "$stderr_file" ]]; then
    cat "$stderr_file" >&2
  fi

  rm -f "$stdout_file" "$stderr_file" >/dev/null 2>&1 || true
  return "$rc"
}

_tem_is_token_error() {
  local output="$1"
  [[ "$output" == *"TitleEditorAPI::InvalidTokenError"* ]] || [[ "$output" == *"token has expired"* ]] || [[ "$output" == *"token not found"* ]]
}

_tem_reconnect_api() {
  # Prefer stored credentials for reconnect, and avoid interactive prompts
  # in automation mode where reads can appear as a hang.
  local saved_timeout saved_open_timeout
  local reconnect_timeout reconnect_open_timeout

  saved_timeout="${_TITLE_EDITOR_API_TIMEOUT:-60}"
  saved_open_timeout="${_TITLE_EDITOR_API_OPEN_TIMEOUT:-60}"
  reconnect_timeout="${TEM_RECONNECT_TIMEOUT:-20}"
  reconnect_open_timeout="${TEM_RECONNECT_OPEN_TIMEOUT:-10}"

  _tem_load_keychain_credentials >/dev/null 2>&1 || true
  if [[ "$TEM_NONINTERACTIVE" == "true" && -z "${TITLE_EDITOR_API_PW:-}" ]]; then
    _tem_debug_log "Reconnect aborted in non-interactive mode: no password available."
    return 1
  fi

  _TITLE_EDITOR_API_TIMEOUT="$reconnect_timeout"
  _TITLE_EDITOR_API_OPEN_TIMEOUT="$reconnect_open_timeout"
  local guard_timeout
  guard_timeout="${TEM_API_GUARD_TIMEOUT:-75}"

  if _tem_call_with_guard_timeout "$guard_timeout" title_editor_api_connect >/dev/null && [[ "${_TITLE_EDITOR_API_CONNECTED:-false}" == "true" ]]; then
    _TITLE_EDITOR_API_TIMEOUT="$saved_timeout"
    _TITLE_EDITOR_API_OPEN_TIMEOUT="$saved_open_timeout"
    return 0
  fi

  _TITLE_EDITOR_API_TIMEOUT="$saved_timeout"
  _TITLE_EDITOR_API_OPEN_TIMEOUT="$saved_open_timeout"
  return 1
}

_tem_api_list_titles() {
  local output rc
  local guard_timeout
  guard_timeout="${TEM_API_GUARD_TIMEOUT:-75}"

  output=$(_tem_call_with_guard_timeout "$guard_timeout" title_editor_api_list_titles 2>&1)
  rc=$?
  if [[ "$rc" -eq 0 ]]; then
    printf '%s' "$output"
    return 0
  fi

  if _tem_is_token_error "$output"; then
    echo "INFO: API token expired during list titles; reconnecting (timeout ${TEM_RECONNECT_TIMEOUT:-20}s, connect ${TEM_RECONNECT_OPEN_TIMEOUT:-10}s) and retrying..." >&2
    if _tem_reconnect_api; then
      output=$(_tem_call_with_guard_timeout "$guard_timeout" title_editor_api_list_titles 2>&1)
      rc=$?
      if [[ "$rc" -eq 0 ]]; then
        printf '%s' "$output"
        return 0
      fi
    else
      echo "ERROR: Reconnect attempt failed during list titles." >&2
    fi
  fi

  printf '%s\n' "$output" >&2
  return "$rc"
}

_tem_api_get() {
  local rsrc="$1"
  local output rc
  local guard_timeout
  guard_timeout="${TEM_API_GUARD_TIMEOUT:-75}"

  output=$(_tem_call_with_guard_timeout "$guard_timeout" title_editor_api_get "$rsrc" 2>&1)
  rc=$?
  if [[ "$rc" -eq 0 ]]; then
    printf '%s' "$output"
    return 0
  fi

  if _tem_is_token_error "$output"; then
    echo "INFO: API token expired during GET ${rsrc}; reconnecting (timeout ${TEM_RECONNECT_TIMEOUT:-20}s, connect ${TEM_RECONNECT_OPEN_TIMEOUT:-10}s) and retrying..." >&2
    if _tem_reconnect_api; then
      output=$(_tem_call_with_guard_timeout "$guard_timeout" title_editor_api_get "$rsrc" 2>&1)
      rc=$?
      if [[ "$rc" -eq 0 ]]; then
        printf '%s' "$output"
        return 0
      fi
    else
      echo "ERROR: Reconnect attempt failed during GET ${rsrc}." >&2
    fi
  fi

  printf '%s\n' "$output" >&2
  return "$rc"
}

_tem_api_post() {
  local rsrc="$1"
  local body="$2"
  local output rc
  local guard_timeout
  guard_timeout="${TEM_API_GUARD_TIMEOUT:-75}"

  output=$(_tem_call_with_guard_timeout "$guard_timeout" title_editor_api_post "$rsrc" "$body" 2>&1)
  rc=$?
  if [[ "$rc" -eq 0 ]]; then
    printf '%s' "$output"
    return 0
  fi

  if _tem_is_token_error "$output"; then
    echo "INFO: API token expired during POST ${rsrc}; reconnecting (timeout ${TEM_RECONNECT_TIMEOUT:-20}s, connect ${TEM_RECONNECT_OPEN_TIMEOUT:-10}s) and retrying..." >&2
    if _tem_reconnect_api; then
      output=$(_tem_call_with_guard_timeout "$guard_timeout" title_editor_api_post "$rsrc" "$body" 2>&1)
      rc=$?
      if [[ "$rc" -eq 0 ]]; then
        printf '%s' "$output"
        return 0
      fi
    else
      echo "ERROR: Reconnect attempt failed during POST ${rsrc}." >&2
    fi
  fi

  printf '%s\n' "$output" >&2
  return "$rc"
}

_tem_api_put() {
  local rsrc="$1"
  local body="$2"
  local output rc
  local guard_timeout
  guard_timeout="${TEM_API_GUARD_TIMEOUT:-75}"

  output=$(_tem_call_with_guard_timeout "$guard_timeout" title_editor_api_put "$rsrc" "$body" 2>&1)
  rc=$?
  if [[ "$rc" -eq 0 ]]; then
    printf '%s' "$output"
    return 0
  fi

  if _tem_is_token_error "$output"; then
    echo "INFO: API token expired during PUT ${rsrc}; reconnecting (timeout ${TEM_RECONNECT_TIMEOUT:-20}s, connect ${TEM_RECONNECT_OPEN_TIMEOUT:-10}s) and retrying..." >&2
    if _tem_reconnect_api; then
      output=$(_tem_call_with_guard_timeout "$guard_timeout" title_editor_api_put "$rsrc" "$body" 2>&1)
      rc=$?
      if [[ "$rc" -eq 0 ]]; then
        printf '%s' "$output"
        return 0
      fi
    else
      echo "ERROR: Reconnect attempt failed during PUT ${rsrc}." >&2
    fi
  fi

  printf '%s\n' "$output" >&2
  return "$rc"
}

_tem_api_delete() {
  local rsrc="$1"
  local output rc
  local guard_timeout
  guard_timeout="${TEM_API_GUARD_TIMEOUT:-75}"

  output=$(_tem_call_with_guard_timeout "$guard_timeout" title_editor_api_delete "$rsrc" 2>&1)
  rc=$?
  if [[ "$rc" -eq 0 ]]; then
    printf '%s' "$output"
    return 0
  fi

  if _tem_is_token_error "$output"; then
    echo "INFO: API token expired during DELETE ${rsrc}; reconnecting (timeout ${TEM_RECONNECT_TIMEOUT:-20}s, connect ${TEM_RECONNECT_OPEN_TIMEOUT:-10}s) and retrying..." >&2
    if _tem_reconnect_api; then
      output=$(_tem_call_with_guard_timeout "$guard_timeout" title_editor_api_delete "$rsrc" 2>&1)
      rc=$?
      if [[ "$rc" -eq 0 ]]; then
        printf '%s' "$output"
        return 0
      fi
    else
      echo "ERROR: Reconnect attempt failed during DELETE ${rsrc}." >&2
    fi
  fi

  printf '%s\n' "$output" >&2
  return "$rc"
}

_tem_usage() {
  cat <<EOF
Title Editor Menu v${script_version}

Interactive:
  bash title_editor_menu.sh
  bash title_editor_menu.sh --debug

Programmatic add patch:
  bash title_editor_menu.sh --create-title --title-name <name> [--new-title-id <id>] [--version <version>] [options]
  bash title_editor_menu.sh --add-patch --title-id <id> --version <version> [options]
  bash title_editor_menu.sh --add-patch-batch --file <path>
  bash title_editor_menu.sh --export-title-json --title-id <id>|--title-name <name> [--output <path>]
  bash title_editor_menu.sh --resequence-only --title-id <id>|--title-name <name> [--dry-run] [--yes]
  bash title_editor_menu.sh --cleanup-non-semver --title-id <id>|--title-name <name> [--dry-run] [--yes]

Options for --add-patch:
  --create-title           Create a new software title first
  --title-id <id>           Required software title ID
  --title-name <name>       Alternative to --title-id (must resolve uniquely)
  --output <path>           Output path for --export-title-json
  --new-title-id <id>       Optional title string ID for --create-title (default: slugified --title-name)
  --title-json-file <path>  Optional full JSON payload file for --create-title
  --publisher <name>        Optional publisher value for generated --create-title payload
  --version <version>       For --create-title generated payload, sets currentVersion; for --add-patch, required patch version (e.g. 16.82.1)
  --release-date <iso8601>  Optional (default: current UTC timestamp)
  --min-os <version>        Optional (default: from latest patch)
  --standalone <yes|no>     Optional (default: yes)
  --reboot <yes|no>         Optional (default: no)
  --bundle-id <id>          Required for --create-title generated payload; optional for --add-patch (default: latest patch)
  --app-name <name>         Optional (default: from latest patch)
  --yes                     Skip confirmation prompt
  --dry-run                 Validate and preview actions without creating patches
  --verify-only             Validate fields/resolution only (no changes)
  --repair-batch-existing   For existing versions in batch, add missing Application Version criteria
  --repair-recreate-existing If repair does not persist, recreate existing patch (delete + create)
  --resequence-only         Reorder existing patches by version (newest first)
  --cleanup-non-semver      Delete existing patch versions that are not numeric semver-like (n.n / n.n.n / n.n.n.n)
  --file <path>             Batch file path for --add-patch-batch
  --batch-file <path>       Alias for --file
  --start-line <n>          For --add-patch-batch, start processing at file line n (1-based)
  --max-rows <n>            For --add-patch-batch, process at most n data rows
  --debug, -d               Enable debug output
  --help, -h                Show this help

Batch file format (pipe-delimited):
  Header:
    title_id|title_name|version|release_date|min_os|standalone|reboot|bundle_id|app_name|yes
    or: title_name|version
  Notes:
    - For short format, header is optional.
    - Rows are processed oldest-to-newest per title.
    - Existing versions are skipped automatically in batch mode.
    - After non-dry-run batch changes, touched titles are auto-resequenced by semantic version.
    - Set TEM_AUTO_RESEQUENCE_ON_CHANGE=false to disable auto-resequence.
    - Use either title_id or title_name per row.
    - version is required per row.
    - Empty values fall back to defaults from existing patch data.
    - Lines starting with # are ignored.
EOF
}

_tem_trim() {
  local value="$1"
  value="${value#${value%%[![:space:]]*}}"
  value="${value%${value##*[![:space:]]}}"
  printf '%s' "$value"
}

_tem_lower() {
  printf '%s' "$1" | tr '[:upper:]' '[:lower:]'
}

_tem_slugify_title_id() {
  local input="$1"
  printf '%s' "$input" | tr -cd '[:alnum:]'
}

_tem_slugify_filename() {
  local input="$1"
  printf '%s' "$input" | tr '[:upper:]' '[:lower:]' | sed -E 's/[^a-z0-9]+/_/g; s/^_+//; s/_+$//'
}

_tem_find_title_by_exact_name() {
  local title_name="$1"
  _tem_api_list_titles | awk -v term="$title_name" '
    BEGIN { IGNORECASE=1 }
    /"softwareTitleId"/ { id=$0; gsub(/[^0-9]/, "", id) }
    /"name"/ {
      name=$0
      gsub(/.*"name": "|",?.*$/, "", name)
      if (tolower(name) == tolower(term)) {
        print id "|" name
      }
    }
  ' | head -1
}

_tem_extract_numeric_title_id_from_json() {
  local json="$1"
  python3 - "$json" <<'PY'
import json
import sys

raw = sys.argv[1]
try:
    data = json.loads(raw)
except Exception:
    print("")
    sys.exit(0)

for key in ("softwareTitleId", "id"):
    value = data.get(key) if isinstance(data, dict) else None
    if isinstance(value, int):
        print(value)
        sys.exit(0)
    if isinstance(value, str) and value.isdigit():
        print(value)
        sys.exit(0)

print("")
PY
}

_tem_build_create_title_payload() {
  local title_name="$1"
  local title_id_string="$2"
  local publisher="$3"
  local bundle_id="$4"
  local current_version="$5"

  python3 - "$title_name" "$title_id_string" "$publisher" "$bundle_id" "$current_version" <<'PY'
import json
import sys

name = sys.argv[1].strip()
id_string = sys.argv[2].strip()
publisher = sys.argv[3].strip()
bundle_id = sys.argv[4].strip()
current_version = sys.argv[5].strip()

payload = {
    "name": name,
    "id": id_string,
    "enabled": True,
  "requirements": [
    {
      "and": True,
      "name": "Application Bundle ID",
      "operator": "is",
      "value": bundle_id,
      "type": "recon",
    }
  ],
}

if publisher:
    payload["publisher"] = publisher

if current_version:
  payload["currentVersion"] = current_version

print(json.dumps(payload, separators=(",", ":")))
PY
}

_tem_version_sort_key() {
  local version="$1"
  local p1="0" p2="0" p3="0" p4="0" extra=""
  IFS='.' read -r p1 p2 p3 p4 extra <<< "$version"
  [[ "$p1" =~ ^[0-9]+$ ]] || p1=0
  [[ "$p2" =~ ^[0-9]+$ ]] || p2=0
  [[ "$p3" =~ ^[0-9]+$ ]] || p3=0
  [[ "$p4" =~ ^[0-9]+$ ]] || p4=0
  # Force base-10 to avoid octal interpretation of components like 08 or 09.
  printf '%010d.%010d.%010d.%010d' "$((10#$p1))" "$((10#$p2))" "$((10#$p3))" "$((10#$p4))"
}

_tem_resolve_title_from_name() {
  local title_name="$1"
  local matches resolved_id resolved_name

  matches=$(_tem_api_list_titles | awk -v term="$title_name" '
    BEGIN { IGNORECASE=1 }
    /"softwareTitleId"/ { id=$0; gsub(/[^0-9]/, "", id) }
    /"name"/ {
      name=$0
      gsub(/.*"name": "|",?.*$/, "", name)
      if (tolower(name) == tolower(term)) {
        print id "|" name
      }
    }
  ')

  if [[ -z "$matches" ]]; then
    matches=$(_tem_api_list_titles | awk -v term="$title_name" '
      BEGIN { IGNORECASE=1 }
      /"softwareTitleId"/ { id=$0; gsub(/[^0-9]/, "", id) }
      /"name"/ {
        name=$0
        gsub(/.*"name": "|",?.*$/, "", name)
        if (tolower(name) ~ tolower(term)) {
          print id "|" name
        }
      }
    ')
  fi

  local match_count
  match_count=$(printf '%s\n' "$matches" | sed '/^$/d' | wc -l | tr -d ' ')
  if [[ "$match_count" -eq 0 ]]; then
    echo "ERROR: No software title found for name: $title_name" >&2
    return 1
  fi
  if [[ "$match_count" -gt 1 ]]; then
    echo "ERROR: Title name is ambiguous. Use --title-id or a more specific --title-name." >&2
    printf '%s\n' "$matches" | head -10 | awk -F'|' '{ printf "  - %s (ID: %s)\n", $2, $1 }'
    return 1
  fi

  resolved_id=$(printf '%s\n' "$matches" | awk -F'|' 'NR==1 {print $1}')
  resolved_name=$(printf '%s\n' "$matches" | awk -F'|' 'NR==1 {print $2}')
  printf '%s|%s\n' "$resolved_id" "$resolved_name"
}

_tem_extract_existing_patch_versions() {
  local data="$1"
  echo "$data" | awk '
    /"patches"/ { in_patches=1; next }
    in_patches && /"extensionAttributes"/ { in_patches=0 }
    in_patches && /"version"/ && !/"Application Version"/ {
      gsub(/^[^\"]*"version": "/, "", $0)
      sub(/".*/, "", $0)
      if ($0 != "") print $0
    }
  ' | awk '!seen[$0]++'
}

_tem_validate_patch_fields() {
  local title_id="$1"
  local title_name="$2"
  local version="$3"
  local release_date="$4"
  local minos="$5"
  local bundle="$6"
  local appname="$7"

  local issues=()

  if [[ -z "$title_id" && -z "$title_name" ]]; then
    issues+=("missing title_id/title_name")
  fi
  if [[ -n "$title_id" && ! "$title_id" =~ ^[0-9]+$ ]]; then
    issues+=("title_id is not numeric")
  fi
  if [[ -z "$version" ]]; then
    issues+=("missing version")
  elif [[ ! "$version" =~ ^[0-9]+(\.[0-9]+){1,3}$ ]]; then
    issues+=("version is not semantic-like (expected n.n or n.n.n)")
  fi
  if [[ -n "$release_date" && ! "$release_date" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T ]]; then
    issues+=("release_date is not ISO8601-like")
  fi
  if [[ -z "$minos" ]]; then
    issues+=("minimumOperatingSystem is empty")
  fi
  if [[ -z "$bundle" ]]; then
    issues+=("killApps.bundleId is empty")
  fi
  if [[ -z "$appname" ]]; then
    issues+=("killApps.appName is empty")
  fi

  if [[ "${#issues[@]}" -gt 0 ]]; then
    printf 'VERIFY: FAIL: %s\n' "$(IFS='; '; echo "${issues[*]}")" >&2
    return 1
  fi

  echo "VERIFY: PASS"
  return 0
}

_tem_prepare_repair_existing_patch_payload() {
  local title_data="$1"
  local version="$2"
  local title_data_file

  title_data_file=$(mktemp /tmp/title_editor_menu_repair_title_data.XXXXXX)
  printf '%s' "$title_data" > "$title_data_file"

  python3 - "$version" "$title_data_file" <<'PY'
import json
import re
import sys

target_version = str(sys.argv[1]).strip()
title_data_file = str(sys.argv[2]).strip()

try:
  with open(title_data_file, 'r', encoding='utf-8', errors='replace') as fh:
    raw = fh.read()
except Exception:
  raw = ""

if not raw:
  print("STATUS\tERROR\tempty-title-data")
  sys.exit(0)

payload = raw.strip()

def load_json_tolerant(text):
  try:
    return json.loads(text), None
  except Exception as exc:
    first_err = exc

  # Common API quirk: trailing commas before } or ]
  cleaned = re.sub(r',\s*([}\]])', r'\1', text)
  try:
    return json.loads(cleaned), None
  except Exception as exc:
    return None, exc if exc else first_err

# Be tolerant of occasional non-JSON noise in the response stream.
if payload and payload[0] not in '{[':
  obj_start = payload.find('{')
  obj_end = payload.rfind('}')
  arr_start = payload.find('[')
  arr_end = payload.rfind(']')

  candidates = []
  if obj_start != -1 and obj_end != -1 and obj_end > obj_start:
    candidates.append(payload[obj_start:obj_end + 1])
  if arr_start != -1 and arr_end != -1 and arr_end > arr_start:
    candidates.append(payload[arr_start:arr_end + 1])

  parsed = None
  parse_err = None
  for candidate in candidates:
    parsed, parse_err = load_json_tolerant(candidate)
    if parsed is not None:
      break

  if parsed is None:
    detail = str(parse_err) if parse_err else "no-json-payload-found"
    print(f"STATUS\tERROR\tinvalid-title-json: {detail}")
    sys.exit(0)
  data = parsed
else:
  data, parse_err = load_json_tolerant(payload)
  if data is None:
    print(f"STATUS\tERROR\tinvalid-title-json: {parse_err}")
    sys.exit(0)

try:
  patches = data.get("patches") if isinstance(data, dict) else None
except Exception:
  print("STATUS\tERROR\tinvalid-title-json: unexpected-data-shape")
  sys.exit(0)

patch = None
for item in (patches or []):
    if str(item.get("version", "")).strip() == target_version:
        patch = item
        break

if patch is None:
    print("STATUS\tNO_PATCH\tversion-not-found")
    sys.exit(0)

patch_id = patch.get("patchId", patch.get("id"))
if patch_id is None:
  patch_id = patch.get("softwarePatchId", patch.get("softwareTitlePatchId"))
if patch_id is None:
    print("STATUS\tERROR\tmissing-patch-id")
    sys.exit(0)

changed = False
for comp in (patch.get("components") or []):
    criteria = comp.get("criteria")
    if not isinstance(criteria, list):
        criteria = []
        comp["criteria"] = criteria

    has_app_version = False
    for c in criteria:
        if not isinstance(c, dict):
            continue
        name = str(c.get("name", "")).strip().lower()
        ctype = str(c.get("type", "")).strip().lower()
        if name == "application version" and ctype == "recon":
            has_app_version = True
            break

    if has_app_version:
        continue

    max_order = -1
    for c in criteria:
        try:
            max_order = max(max_order, int(c.get("absoluteOrderId", -1)))
        except Exception:
            pass

    criteria.append({
        "absoluteOrderId": max_order + 1,
        "and": True,
        "name": "Application Version",
        "operator": "is",
        "value": target_version,
        "type": "recon",
    })
    changed = True

if not changed:
    print(f"STATUS\tNO_CHANGE\t{patch_id}")
    sys.exit(0)

print(f"STATUS\tCHANGED\t{patch_id}")
print("PAYLOAD\t" + json.dumps(patch, separators=(",", ":")))
PY

  rm -f "$title_data_file" >/dev/null 2>&1 || true
}

_tem_patch_has_app_version_criteria() {
  local title_data="$1"
  local version="$2"
  local title_data_file

  title_data_file=$(mktemp /tmp/title_editor_menu_verify_title_data.XXXXXX)
  printf '%s' "$title_data" > "$title_data_file"

  python3 - "$version" "$title_data_file" <<'PY'
import json
import re
import sys

target_version = str(sys.argv[1]).strip()
path = str(sys.argv[2]).strip()

try:
  with open(path, 'r', encoding='utf-8', errors='replace') as fh:
    raw = fh.read()
except Exception:
  print("NO")
  sys.exit(0)

try:
  data = json.loads(raw)
except Exception:
  cleaned = re.sub(r',\s*([}\]])', r'\1', raw)
  try:
    data = json.loads(cleaned)
  except Exception:
    print("NO")
    sys.exit(0)

patch = None
for item in (data.get("patches") or []):
    if str(item.get("version", "")).strip() == target_version:
        patch = item
        break

if patch is None:
    print("NO")
    sys.exit(0)

for comp in (patch.get("components") or []):
    for c in (comp.get("criteria") or []):
        if not isinstance(c, dict):
            continue
        name = str(c.get("name", "")).strip().lower()
        ctype = str(c.get("type", "")).strip().lower()
        if name == "application version" and ctype == "recon":
            print("YES")
            sys.exit(0)

print("NO")
PY

  rm -f "$title_data_file" >/dev/null 2>&1 || true
}

_tem_prepare_recreate_patch_payload() {
  local patch_payload="$1"
  python3 - "$patch_payload" <<'PY'
import json
import sys

try:
    data = json.loads(sys.argv[1])
except Exception:
    print("")
    sys.exit(0)

if isinstance(data, dict):
    for key in ("patchId", "id", "softwarePatchId", "softwareTitlePatchId"):
        data.pop(key, None)

print(json.dumps(data, separators=(",", ":")))
PY
}

_tem_build_resequence_plan() {
  local json_file
  json_file=$(mktemp /tmp/title_editor_resequence_json.XXXXXX)
  cat > "$json_file"

  python3 - "$json_file" <<'PY'
import json
import sys

def parse_int(value, default=0):
    try:
        return int(value)
    except Exception:
        return default

def version_key(version):
    parts = str(version).strip().split('.')
    nums = []
    for i in range(4):
        if i < len(parts):
            p = parts[i]
            if p.isdigit():
                nums.append(int(p))
            else:
                digits = ''.join(ch for ch in p if ch.isdigit())
                nums.append(int(digits) if digits else 0)
        else:
            nums.append(0)
    return tuple(nums)

json_file = sys.argv[1]

try:
  with open(json_file, 'r', encoding='utf-8') as fh:
    raw = fh.read().strip()
except Exception:
  sys.exit(0)

if not raw:
    sys.exit(0)

try:
    data = json.loads(raw)
except Exception:
    sys.exit(0)

if isinstance(data, dict) and isinstance(data.get('patches'), list):
    patches = data['patches']
elif isinstance(data, list):
    patches = data
else:
    patches = []

rows = []
for item in patches:
    if not isinstance(item, dict):
        continue
    patch_id = item.get('patchId', item.get('id'))
    version = str(item.get('version', '')).strip()
    current_order = item.get('absoluteOrderId')
    if patch_id is None or not version:
        continue
    rows.append({
        'patch_id': parse_int(patch_id, -1),
        'version': version,
        'current_order': parse_int(current_order, 10**9),
        'version_key': version_key(version),
    })

rows.sort(key=lambda r: (-r['version_key'][0], -r['version_key'][1], -r['version_key'][2], -r['version_key'][3], r['current_order'], r['patch_id']))

for new_order, row in enumerate(rows):
    print(f"{row['patch_id']}\t{row['version']}\t{row['current_order']}\t{new_order}")
PY

  rm -f "$json_file" >/dev/null 2>&1 || true
}

_tem_run_resequence_cli() {
  if [[ -n "$TEM_CLI_TITLE_ID" && -n "$TEM_CLI_TITLE_NAME" ]]; then
    echo "ERROR: Use either --title-id or --title-name, not both" >&2
    return 1
  fi

  if [[ -z "$TEM_CLI_TITLE_ID" && -z "$TEM_CLI_TITLE_NAME" ]]; then
    echo "ERROR: --resequence-only requires --title-id or --title-name" >&2
    return 1
  fi

  if [[ -n "$TEM_CLI_TITLE_ID" ]] && ! [[ "$TEM_CLI_TITLE_ID" =~ ^[0-9]+$ ]]; then
    echo "ERROR: --title-id must be numeric" >&2
    return 1
  fi

  if [[ -n "$TEM_CLI_TITLE_NAME" ]]; then
    local resolved resolved_id resolved_name
    resolved=$(_tem_resolve_title_from_name "$TEM_CLI_TITLE_NAME") || return 1
    resolved_id=$(printf '%s\n' "$resolved" | awk -F'|' 'NR==1 {print $1}')
    resolved_name=$(printf '%s\n' "$resolved" | awk -F'|' 'NR==1 {print $2}')
    TEM_CLI_TITLE_ID="$resolved_id"
    TEM_CLI_TITLE_NAME="$resolved_name"
  fi

  local title_id="$TEM_CLI_TITLE_ID"
  local title_data title_name
  title_data=$(_tem_api_get "softwaretitles/${title_id}") || return 1
  title_name=$(echo "$title_data" | awk '/"name"/{gsub(/.*"name": "|",?.*$/, "", $0); print; exit}')
  [[ -z "$title_name" ]] && title_name="Title ${title_id}"

  local plan
  plan=$(printf '%s' "$title_data" | _tem_build_resequence_plan)

  local target_current_version
  target_current_version=$(printf '%s\n' "$plan" | awk -F'\t' '$4 == 0 { print $2; exit }')

  if [[ -z "$plan" ]]; then
    echo "No patches found to resequence for ${title_name} (ID: ${title_id})."
    return 0
  fi

  if [[ "$TEM_CLI_DRY_RUN" != "true" && "$TEM_CLI_YES" != "true" ]]; then
    echo ""
    _tem_header "Resequence Patches — ${title_name}"
    echo "This will update patch order to semantic version descending (newest first)."
    local confirm
    confirm=$(_tem_prompt "Proceed? [yes/no]:")
    [[ "$(echo "$confirm" | tr '[:upper:]' '[:lower:]')" != "yes" ]] && {
      echo "Cancelled."
      return 1
    }
  fi

  local total=0
  local unchanged=0
  local updated=0
  local failed=0

  echo ""
  echo "Resequencing patches for ${title_name} (ID: ${title_id})..."

  while IFS=$'\t' read -r patch_id version current_order new_order; do
    [[ -z "$patch_id" ]] && continue
    ((total++))

    if [[ "$current_order" == "$new_order" ]]; then
      ((unchanged++))
      if [[ "$TEM_CLI_DRY_RUN" == "true" ]]; then
        echo "[${total}] keep patchId=${patch_id} version=${version} order=${current_order}"
      fi
      continue
    fi

    if [[ "$TEM_CLI_DRY_RUN" == "true" ]]; then
      ((updated++))
      echo "[${total}] would update patchId=${patch_id} version=${version} order ${current_order} -> ${new_order}"
      continue
    fi

    local payload result
    payload=$(printf '{"absoluteOrderId": %s}' "$new_order")
    if result=$(_tem_api_put "patches/${patch_id}" "$payload" 2>&1); then
      ((updated++))
      echo "[${total}] updated patchId=${patch_id} version=${version} order ${current_order} -> ${new_order}"
    else
      ((failed++))
      echo "[${total}] failed patchId=${patch_id} version=${version} order ${current_order} -> ${new_order}" >&2
      echo "$result" | head -3 | sed 's/^/    /' >&2
    fi
  done <<< "$plan"

  if [[ -n "$target_current_version" ]]; then
    if [[ "$TEM_CLI_DRY_RUN" == "true" ]]; then
      echo "[currentVersion] would set to ${target_current_version}"
    elif [[ "$failed" -eq 0 ]]; then
      local cv_payload cv_result
      cv_payload=$(printf '{"currentVersion":"%s"}' "$target_current_version")
      if cv_result=$(_tem_api_put "softwaretitles/${title_id}" "$cv_payload" 2>&1); then
        echo "[currentVersion] updated to ${target_current_version}"
      else
        ((failed++))
        echo "[currentVersion] failed to update to ${target_current_version}" >&2
        echo "$cv_result" | head -3 | sed 's/^/    /' >&2
      fi
    fi
  fi

  echo ""
  if [[ "$TEM_CLI_DRY_RUN" == "true" ]]; then
    echo "Resequence dry-run complete: total=${total}, would_update=${updated}, unchanged=${unchanged}, failed=${failed}"
  else
    echo "Resequence complete: total=${total}, updated=${updated}, unchanged=${unchanged}, failed=${failed}"
  fi

  [[ "$failed" -eq 0 ]]
}

_tem_export_title_json_write_file() {
  local title_id="$1"
  local title_name="$2"
  local title_data="$3"
  local output_path="${4:-}"
  local prompt_for_path="${5:-false}"
  local slug default_output

  slug=$(_tem_slugify_filename "$title_name")
  [[ -z "$slug" ]] && slug="title_${title_id}"
  default_output="./title_editor_title_${title_id}_${slug}.json"

  if [[ -z "$output_path" ]]; then
    if [[ "$prompt_for_path" == "true" ]]; then
      read -r -p "Output JSON file path [${default_output}]: " output_path
      output_path=$(_tem_trim "$output_path")
      [[ -z "$output_path" ]] && output_path="$default_output"
    else
      output_path="$default_output"
    fi
  fi

  if [[ -d "$output_path" ]]; then
    output_path="${output_path%/}/title_editor_title_${title_id}_${slug}.json"
  fi

  mkdir -p "$(dirname "$output_path")"
  printf '%s\n' "$title_data" > "$output_path"
  echo "Exported software title '${title_name}' (ID: ${title_id}) to: ${output_path}"
}

_tem_run_export_title_json_cli() {
  if [[ -n "$TEM_CLI_TITLE_ID" && -n "$TEM_CLI_TITLE_NAME" ]]; then
    echo "ERROR: Use either --title-id or --title-name, not both" >&2
    return 1
  fi

  if [[ -z "$TEM_CLI_TITLE_ID" && -z "$TEM_CLI_TITLE_NAME" ]]; then
    echo "ERROR: --export-title-json requires --title-id or --title-name" >&2
    return 1
  fi

  if [[ -n "$TEM_CLI_TITLE_ID" ]] && ! [[ "$TEM_CLI_TITLE_ID" =~ ^[0-9]+$ ]]; then
    echo "ERROR: --title-id must be numeric" >&2
    return 1
  fi

  if [[ -n "$TEM_CLI_TITLE_NAME" ]]; then
    local resolved
    resolved=$(_tem_resolve_title_from_name "$TEM_CLI_TITLE_NAME") || return 1
    TEM_CLI_TITLE_ID=$(printf '%s\n' "$resolved" | awk -F'|' 'NR==1 {print $1}')
    TEM_CLI_TITLE_NAME=$(printf '%s\n' "$resolved" | awk -F'|' 'NR==1 {print $2}')
  fi

  local title_id="$TEM_CLI_TITLE_ID"
  local title_data title_name
  title_data=$(_tem_api_get "softwaretitles/${title_id}") || return 1

  title_name=$(echo "$title_data" | awk '/"name"/{gsub(/.*"name": "|",?.*$/, "", $0); print; exit}')
  [[ -z "$title_name" ]] && title_name="${TEM_CLI_TITLE_NAME:-Title_${title_id}}"
  _tem_export_title_json_write_file "$title_id" "$title_name" "$title_data" "$TEM_CLI_OUTPUT_FILE" "false"
}

_tem_export_current_title_json_interactive() {
  local data="$1"
  if [[ -z "${TEM_TITLE_ID:-}" || -z "${TEM_TITLE_NAME:-}" ]]; then
    echo "ERROR: No title selected to export." >&2
    return 1
  fi
  _tem_export_title_json_write_file "$TEM_TITLE_ID" "$TEM_TITLE_NAME" "$data" "" "true"
  _tem_pause
}

_tem_resequence_title_by_id() {
  local title_id="$1"
  local title_data title_name plan target_current_version

  title_data=$(_tem_api_get "softwaretitles/${title_id}") || return 1
  title_name=$(echo "$title_data" | awk '/"name"/{gsub(/.*"name": "|",?.*$/, "", $0); print; exit}')
  [[ -z "$title_name" ]] && title_name="Title ${title_id}"

  plan=$(printf '%s' "$title_data" | _tem_build_resequence_plan)
  [[ -z "$plan" ]] && return 0

  target_current_version=$(printf '%s\n' "$plan" | awk -F'\t' '$4 == 0 { print $2; exit }')

  local failed=0
  while IFS=$'\t' read -r patch_id version current_order new_order; do
    [[ -z "$patch_id" ]] && continue
    [[ "$current_order" == "$new_order" ]] && continue

    local payload
    payload=$(printf '{"absoluteOrderId": %s}' "$new_order")
    if ! _tem_api_put "patches/${patch_id}" "$payload" >/dev/null 2>/dev/null; then
      ((failed++))
    fi
  done <<< "$plan"

  if [[ -n "$target_current_version" ]]; then
    local cv_payload
    cv_payload=$(printf '{"currentVersion":"%s"}' "$target_current_version")
    _tem_api_put "softwaretitles/${title_id}" "$cv_payload" >/dev/null 2>/dev/null || ((failed++))
  fi

  [[ "$failed" -eq 0 ]]
}

_tem_parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --debug|-d)
        TEM_DEBUG_CREDENTIALS="true"
        shift
        ;;
      --create-title)
        TEM_CLI_MODE="create-title"
        TEM_CLI_CREATE_TITLE=true
        TEM_NONINTERACTIVE=true
        shift
        ;;
      --add-patch)
        TEM_CLI_MODE="add-patch"
        TEM_NONINTERACTIVE=true
        shift
        ;;
      --add-patch-batch)
        TEM_CLI_MODE="add-patch-batch"
        TEM_NONINTERACTIVE=true
        shift
        ;;
      --export-title-json)
        TEM_CLI_MODE="export-title-json"
        TEM_NONINTERACTIVE=true
        shift
        ;;
      --resequence-only)
        TEM_CLI_MODE="resequence-only"
        TEM_CLI_RESEQUENCE_MODE=true
        TEM_NONINTERACTIVE=true
        shift
        ;;
      --cleanup-non-semver)
        TEM_CLI_MODE="cleanup-non-semver"
        TEM_CLI_CLEANUP_NON_SEMVER=true
        TEM_NONINTERACTIVE=true
        shift
        ;;
      --title-id)
        TEM_CLI_TITLE_ID="${2:-}"
        shift 2
        ;;
      --title-name)
        TEM_CLI_TITLE_NAME="${2:-}"
        shift 2
        ;;
      --output)
        TEM_CLI_OUTPUT_FILE="${2:-}"
        shift 2
        ;;
      --new-title-id)
        TEM_CLI_NEW_TITLE_ID_STRING="${2:-}"
        shift 2
        ;;
      --title-json-file)
        TEM_CLI_TITLE_JSON_FILE="${2:-}"
        shift 2
        ;;
      --publisher)
        TEM_CLI_PUBLISHER="${2:-}"
        shift 2
        ;;
      --version)
        TEM_CLI_VERSION="${2:-}"
        shift 2
        ;;
      --release-date)
        TEM_CLI_RELEASE_DATE="${2:-}"
        shift 2
        ;;
      --min-os)
        TEM_CLI_MIN_OS="${2:-}"
        shift 2
        ;;
      --standalone)
        TEM_CLI_STANDALONE="${2:-}"
        shift 2
        ;;
      --reboot)
        TEM_CLI_REBOOT="${2:-}"
        shift 2
        ;;
      --bundle-id)
        TEM_CLI_BUNDLE_ID="${2:-}"
        shift 2
        ;;
      --app-name)
        TEM_CLI_APP_NAME="${2:-}"
        shift 2
        ;;
      --yes)
        TEM_CLI_YES=true
        shift
        ;;
      --dry-run)
        TEM_CLI_DRY_RUN=true
        shift
        ;;
      --verify-only)
        TEM_CLI_VERIFY_ONLY=true
        TEM_CLI_DRY_RUN=true
        shift
        ;;
      --repair-batch-existing)
        TEM_CLI_REPAIR_BATCH_EXISTING=true
        shift
        ;;
      --repair-recreate-existing)
        TEM_CLI_REPAIR_RECREATE_EXISTING=true
        shift
        ;;
      --file|--batch-file)
        TEM_CLI_BATCH_FILE="${2:-}"
        shift 2
        ;;
      --start-line)
        TEM_CLI_START_LINE="${2:-}"
        shift 2
        ;;
      --max-rows)
        TEM_CLI_MAX_ROWS="${2:-}"
        shift 2
        ;;
      --help|-h)
        _tem_usage
        exit 0
        ;;
      *)
        echo "ERROR: Unknown argument: $1" >&2
        _tem_usage
        exit 1
        ;;
    esac
  done
}

# Read one value from Keychain (generic password)
# @param $1 Keychain account name
# @stdout   Stored value (empty if not found)
_tem_keychain_read() {
  local account="$1"
  security find-generic-password -s "$TEM_KEYCHAIN_SERVICE" -a "$account" -w "$TEM_KEYCHAIN_PATH" 2>/dev/null || true
}

# Load host/user/password from keychain into TITLE_EDITOR_API_* env vars.
# @return 0 when all values are present, 1 otherwise
_tem_load_keychain_credentials() {
  local host user pw
  host=$(_tem_keychain_read "$TEM_KEYCHAIN_ACCOUNT_HOST")
  user=$(_tem_keychain_read "$TEM_KEYCHAIN_ACCOUNT_USER")
  pw=$(_tem_keychain_read "$TEM_KEYCHAIN_ACCOUNT_PASS")

  _tem_debug_log "Keychain path: $TEM_KEYCHAIN_PATH"
  _tem_debug_log "Keychain host: ${host:-<empty>}"
  _tem_debug_log "Keychain user: ${user:-<empty>}"
  _tem_debug_log "Keychain password: len=${#pw}, fp=$(_tem_secret_fingerprint "$pw")"

  if [[ -n "$host" && -n "$user" && -n "$pw" ]]; then
    export TITLE_EDITOR_API_HOST="$host"
    export TITLE_EDITOR_API_USER="$user"
    export TITLE_EDITOR_API_PW="$pw"
    _tem_debug_log "Exported TITLE_EDITOR_API_HOST=${TITLE_EDITOR_API_HOST}"
    _tem_debug_log "Exported TITLE_EDITOR_API_USER=${TITLE_EDITOR_API_USER}"
    _tem_debug_log "Exported TITLE_EDITOR_API_PW len=${#TITLE_EDITOR_API_PW}, fp=$(_tem_secret_fingerprint "$TITLE_EDITOR_API_PW")"
    return 0
  fi

  return 1
}

# Check that title_editor_api_ctrl.sh has been sourced
_tem_check_sourced() {
  if ! declare -f title_editor_api_connect &>/dev/null; then
    echo "ERROR: title_editor_api_ctrl.sh must be sourced first." >&2
    echo "  source /path/to/title_editor_api_ctrl.sh" >&2
    exit 1
  fi
}

# Check that we are connected
_tem_check_connected() {
  # Check token variable directly - the connected flag may not be visible
  # if the menu script is running in a subshell
  if [[ -z "${_TITLE_EDITOR_API_TOKEN:-}" ]]; then
    if _tem_load_keychain_credentials; then
      echo "Found Title Editor credentials in Keychain. Connecting..."
      if title_editor_api_connect >/dev/null && [[ "${_TITLE_EDITOR_API_CONNECTED:-false}" == "true" ]]; then
        echo "Connected using Keychain credentials."
        return 0
      fi
      _tem_header "Not Connected"
      echo "You are not connected to a Title Editor server."
      echo ""
      echo "Could not connect using Keychain credentials."
      echo "You can update saved credentials with:"
      echo "  bash ${TEM_SCRIPT_DIR}/setup_title_editor_credentials.sh"
      echo "Or verify saved credentials with:"
      echo "  bash ${TEM_SCRIPT_DIR}/setup_title_editor_credentials.sh --verify"
      echo ""

      echo "Retrying with saved host/user and prompting for password..."
      unset TITLE_EDITOR_API_PW
      if title_editor_api_connect >/dev/null && [[ "${_TITLE_EDITOR_API_CONNECTED:-false}" == "true" ]]; then
        echo "Connected using saved host/user and prompted password."
        return 0
      fi
      echo "Password retry failed."
      echo ""
    else
      _tem_header "Not Connected"
      echo "You are not connected to a Title Editor server."
      echo ""
      echo "No complete Title Editor credential set found in Keychain."
      echo "To set up credentials securely, run:"
      echo "  bash ${TEM_SCRIPT_DIR}/setup_title_editor_credentials.sh"
      echo ""
    fi

    if [[ "$TEM_NONINTERACTIVE" == "true" ]]; then
      echo "ERROR: Not connected and no usable saved credentials in non-interactive mode." >&2
      echo "Set credentials first with setup_title_editor_credentials.sh, or export TITLE_EDITOR_API_HOST/USER/PW." >&2
      return 1
    fi

    local host user
    host=$(_tem_prompt "Server hostname:") || {
      echo "ERROR: Failed to read server hostname." >&2
      return 1
    }
    user=$(_tem_prompt "Username:") || {
      echo "ERROR: Failed to read username." >&2
      return 1
    }
    export TITLE_EDITOR_API_HOST="$host"
    export TITLE_EDITOR_API_USER="$user"
    echo "Password will be prompted securely by title_editor_api_connect."
    echo "Tip: use setup_title_editor_credentials.sh to avoid future prompts."
    if ! title_editor_api_connect >/dev/null || [[ "${_TITLE_EDITOR_API_CONNECTED:-false}" != "true" ]]; then
      echo "ERROR: Could not connect to Title Editor API."
      return 1
    fi
  fi

  [[ "${_TITLE_EDITOR_API_CONNECTED:-false}" == "true" ]]
}

###############################################################################
# SOFTWARE TITLE SELECTION
###############################################################################

# Let user pick a software title interactively.
# Prompts for a name/search term, shows matches, returns the numeric ID and name.
# Sets TEM_TITLE_ID and TEM_TITLE_NAME
_tem_select_title() {
  _tem_header "Select Software Title"

  local search
  search=$(_tem_prompt "Enter title name to search (or press Enter to list all):")

  echo ""
  echo "Fetching titles..."
  local list
  list=$(_tem_api_list_titles)

  # Filter by search term if provided
  local matches
  if [[ -n "$search" ]]; then
    matches=$(echo "$list" | awk -v term="${search}" '
      BEGIN { IGNORECASE=1 }
      /"softwareTitleId"/ { id=$0; gsub(/[^0-9]/, "", id) }
      /"name"/ {
        name=$0
        gsub(/.*"name": "|",?.*$/, "", name)
        if (tolower(name) ~ tolower(term)) {
          print id "|" name
        }
      }
    ' | sort -t'|' -k2f)
  else
    matches=$(echo "$list" | awk '
      /"softwareTitleId"/ { id=$0; gsub(/[^0-9]/, "", id) }
      /"name"/ {
        name=$0
        gsub(/.*"name": "|",?.*$/, "", name)
        print id "|" name
      }
    ' | sort -t'|' -k2f)
  fi

  if [[ -z "$matches" ]]; then
    echo "No titles found matching '${search}'."
    _tem_pause
    return 1
  fi

  # Build arrays of IDs and names
  local ids=()
  local names=()
  while IFS='|' read -r id name; do
    ids+=("$id")
    names+=("$name")
  done <<< "$matches"

  # If only one match, select it automatically
  if [[ "${#ids[@]}" -eq 1 ]]; then
    TEM_TITLE_ID="${ids[0]}"
    TEM_TITLE_NAME="${names[0]}"
    echo "Selected: ${TEM_TITLE_NAME} (ID: ${TEM_TITLE_ID})"
    return 0
  fi

  # Show numbered list
  echo "Matching titles:"
  echo ""
  local i=1
  for name in "${names[@]}"; do
    echo "  $i) $name"
    (( i++ ))
  done
  echo ""

  local choice
  choice=$(_tem_prompt "Enter number:")

  if ! [[ "$choice" =~ ^[0-9]+$ ]] || (( choice < 1 || choice > ${#ids[@]} )); then
    echo "Invalid selection."
    return 1
  fi

  TEM_TITLE_ID="${ids[$((choice-1))]}"
  TEM_TITLE_NAME="${names[$((choice-1))]}"
  echo ""
  echo "Selected: ${TEM_TITLE_NAME} (ID: ${TEM_TITLE_ID})"
}

###############################################################################
# TITLE DETAIL VIEWS
###############################################################################

# Show extension attributes for a title
_tem_show_extension_attributes() {
  local data="$1"
  _tem_header "Extension Attributes — ${TEM_TITLE_NAME}"

  local ea
  ea=$(echo "$data" | awk '
    /"extensionAttributes"/ { in_ea=1 }
    in_ea { print }
  ')

  if echo "$ea" | grep -q '\[\]'; then
    echo "  No extension attributes defined."
  else
    echo "$ea" | grep -E '"name"|"value"|"type"' | sed 's/^[[:space:]]*/  /'
  fi
  _tem_pause
}

# Show requirements for a title
_tem_show_requirements() {
  local data="$1"
  _tem_header "Requirements — ${TEM_TITLE_NAME}"
  echo "  (Criteria defining which computers have this title installed)"
  echo ""

  echo "$data" | awk '
    /"requirements"/ { in_req=1; next }
    in_req && /\]/ { in_req=0 }
    in_req && /"name"|"operator"|"value"|"type"/ {
      gsub(/^[[:space:]]*/, "  ")
      print
    }
  '
  _tem_pause
}

# Show patches summary for a title
_tem_show_patches_summary() {
  local data="$1"
  _tem_header "Patches — ${TEM_TITLE_NAME}"
  echo "  Version               Min OS     Release Date"
  _tem_divider

  echo "$data" | awk '
    /"patches"/ { in_patches=1; next }
    in_patches && /"extensionAttributes"/ { in_patches=0 }
    in_patches && /"version"/ && !/"Application Version"/ {
      gsub(/.*"version": "|",?$/, ""); ver=$0
    }
    in_patches && /"releaseDate"/ {
      gsub(/.*"releaseDate": "|",?$/, ""); rel=$0
      gsub(/T.*/, "", rel)
    }
    in_patches && /"minimumOperatingSystem"/ {
      gsub(/.*"minimumOperatingSystem": "|",?$/, ""); minos=$0
      split(ver, parts, ".")
      p1 = (parts[1] ~ /^[0-9]+$/) ? parts[1] : 0
      p2 = (parts[2] ~ /^[0-9]+$/) ? parts[2] : 0
      p3 = (parts[3] ~ /^[0-9]+$/) ? parts[3] : 0
      p4 = (parts[4] ~ /^[0-9]+$/) ? parts[4] : 0
      printf "%010d.%010d.%010d.%010d|%s|%s|%s\n", p1, p2, p3, p4, ver, minos, rel
    }
  ' | sort -t'|' -k1,1r | awk -F'|' '{ printf "  %-22s %-10s %s\n", $2, $3, $4 }'
  _tem_pause
}

###############################################################################
# PATCH DETAIL VIEWS
###############################################################################

# Let user pick a specific patch version
# Sets TEM_PATCH_VERSION and TEM_PATCH_DATA
_tem_select_patch() {
  local data="$1"
  _tem_header "Select Patch Version — ${TEM_TITLE_NAME}"

  # Extract versions
  local versions=()
  while IFS= read -r ver; do
    versions+=("$ver")
  done < <(echo "$data" | awk '
    /"patches"/ { in_patches=1; next }
    in_patches && /"extensionAttributes"/ { in_patches=0 }
    in_patches && /"version"/ && !/"Application Version"/ {
      gsub(/.*"version": "|",?$/, ""); print
    }
  ' | sort -u | sort -t. -k1,1rn -k2,2rn -k3,3rn -k4,4rn)

  if [[ "${#versions[@]}" -eq 0 ]]; then
    echo "No patches found."
    _tem_pause
    return 1
  fi

  local i=1
  for ver in "${versions[@]}"; do
    echo "  $i) $ver"
    (( i++ ))
  done
  echo ""

  local choice
  choice=$(_tem_prompt "Enter number:")

  if ! [[ "$choice" =~ ^[0-9]+$ ]] || (( choice < 1 || choice > ${#versions[@]} )); then
    echo "Invalid selection."
    return 1
  fi

  TEM_PATCH_VERSION="${versions[$((choice-1))]}"
}

# Show kill apps for a patch version
_tem_show_kill_apps() {
  local data="$1"
  local version="$2"
  _tem_header "Kill Apps — ${TEM_TITLE_NAME} ${version}"

  # Extract just the killApps block for the matching version using Python-style
  # multi-line approach: find the patch block, then extract killApps from it
  # Find the patch block for this version, then extract killApps until components
  echo "$data" | awk -v ver="$version" '
    # Enter patch block when we see this exact version at patch level (not in value/criteria)
    !in_patch && /"version":/ && index($0, "\"" ver "\"") { in_patch=1; next }
    # Once in the right patch, start collecting when we hit killApps
    in_patch && /"killApps"/ { in_kill=1; next }
    # Stop at components - we are done with killApps
    in_patch && in_kill && /"components"/ { exit }
    # Print bundleId and appName lines
    in_patch && in_kill && (/"bundleId"/ || /"appName"/) {
      gsub(/^[[:space:]]*/, "  "); print
    }
    # Stop if we hit another patchId (next patch block) without having matched
    in_patch && !in_kill && /"patchId"/ { exit }
  '
  _tem_pause
}

# Show components for a patch version
_tem_show_components() {
  local data="$1"
  local version="$2"
  _tem_header "Components — ${TEM_TITLE_NAME} ${version}"

  echo "$data" | awk -v ver="$version" '
    /"version":/ && $0 ~ "\"" ver "\"" { in_patch=1 }
    in_patch && /"components"/ { in_comp=1 }
    in_patch && in_comp && /"name"|"version"|"operator"|"value"/ {
      gsub(/^[[:space:]]*/, "  "); print
    }
    in_patch && in_comp && /"capabilities"/ { in_comp=0; in_patch=0 }
  '
  _tem_pause
}

# Show capabilities for a patch version
_tem_show_capabilities() {
  local data="$1"
  local version="$2"
  _tem_header "Capabilities — ${TEM_TITLE_NAME} ${version}"

  echo "$data" | awk -v ver="$version" '
    /"version":/ && $0 ~ "\"" ver "\"" { in_patch=1 }
    in_patch && /"capabilities"/ { in_cap=1 }
    in_patch && in_cap && /"name"|"operator"|"value"/ {
      gsub(/^[[:space:]]*/, "  "); print
    }
    in_patch && in_cap && /\],?$/ { in_cap=0; in_patch=0 }
  '
  _tem_pause
}

###############################################################################
# MENUS
###############################################################################


###############################################################################
# ADD NEW PATCH VERSION
###############################################################################

# Prompt user to add a new patch version to the current software title.
# Uses the existing patches to pre-populate bundleId, appName, component name,
# and extension attribute criterion name from the most recent patch.
_tem_submit_patch() {
  local data="$1"
  local version="$2"
  local release_date="$3"
  local minos="$4"
  local standalone="$5"
  local reboot="$6"
  local bundle="$7"
  local appname="$8"
  local skip_confirm="$9"

  local default_ea_name compname ea_name ea_type
  default_ea_name=$(echo "$data" | awk '/"extensionAttribute"/{f=1} f&&/"name"/{gsub(/.*"name": "|",?$/,"",$0); print; exit}')
  compname="${TEM_TITLE_NAME}"

  # If the source title has no extension-attribute criterion configured,
  # use Application Version so criteria are still complete and usable.
  if [[ -n "$default_ea_name" ]]; then
    ea_name="$default_ea_name"
    ea_type="extensionAttribute"
  else
    ea_name="Application Version"
    ea_type="recon"
  fi

  local json
  json=$(cat <<ENDJSON
{
    "absoluteOrderId": 0,
    "enabled": true,
    "version": "${version}",
    "releaseDate": "${release_date}",
    "standalone": ${standalone},
    "minimumOperatingSystem": "${minos}",
    "reboot": ${reboot},
    "killApps": [
        {
            "bundleId": "${bundle}",
            "appName": "${appname}"
        }
    ],
    "components": [
        {
            "name": "${compname}",
            "version": "${version}",
            "criteria": [
                {
                    "absoluteOrderId": 0,
                    "and": true,
                    "name": "${ea_name}",
                    "operator": "is",
                    "value": "${version}",
                  "type": "${ea_type}"
                },
                {
                    "absoluteOrderId": 1,
                    "and": true,
                    "name": "Application Bundle ID",
                    "operator": "is",
                    "value": "${bundle}",
                    "type": "recon"
                }
            ]
        }
    ],
    "capabilities": [
        {
            "absoluteOrderId": 0,
            "and": true,
            "name": "Operating System Version",
            "operator": "greater than or equal",
            "value": "${minos}",
            "type": "recon"
        }
    ]
}
ENDJSON
)

  echo ""
  _tem_header "Review New Patch — ${TEM_TITLE_NAME}"
  echo ""
  echo "  Software Title:  ${TEM_TITLE_NAME}"
  echo "  Version:         ${version}"
  echo "  Release Date:    ${release_date}"
  echo "  Min OS:          ${minos}"
  echo "  Standalone:      ${standalone}"
  echo "  Reboot:          ${reboot}"
  echo ""
  echo "  Kill Apps:"
  echo "    Bundle ID:     ${bundle}"
  echo "    App Name:      ${appname}"
  echo ""
  echo "  Components:"
  echo "    Name:          ${compname}"
  echo "    Version:       ${version}"
  echo "    (Criteria auto-populated from existing patches)"
  echo ""
  echo "  Capability:"
  echo "    Min OS:        ${minos} or greater"
  echo ""

  if [[ "$skip_confirm" != "true" ]]; then
    if [[ "$TEM_NONINTERACTIVE" == "true" ]]; then
      echo "ERROR: Confirmation required in non-interactive mode. Re-run with --yes." >&2
      return 1
    fi
    _tem_divider
    local confirm
    confirm=$(_tem_prompt "  Create this patch? [yes/no]:") || {
      echo "ERROR: Could not read confirmation response." >&2
      return 1
    }
    [[ "$(echo "$confirm" | tr "[:upper:]" "[:lower:]")" != "yes" ]] && {
      echo "Cancelled."
      _tem_pause
      return 1
    }
  fi

  echo ""
  echo "  Submitting new patch..."
  local result
  if ! result=$(_tem_api_post "softwaretitles/${TEM_TITLE_ID}/patches" "$json" 2>&1); then
    echo ""
    echo "  ERROR: Patch creation failed:"
    echo "$result" | head -5 | sed 's/^/    /'
    [[ "$skip_confirm" != "true" ]] && _tem_pause
    return 1
  fi

  if echo "$result" | grep -q '"errors"'; then
    echo ""
    echo "  ERROR: Patch creation failed:"
    echo "$result" | grep '"description"' | sed 's/^/    /'
    [[ "$skip_confirm" != "true" ]] && _tem_pause
    return 1
  elif echo "$result" | grep -q '"patchId"'; then
    echo ""
    echo "  Patch ${version} created successfully!"

    echo ""
    echo "  Updating software title currentVersion to ${version}..."
    local update_json update_result
    local saved_timeout saved_open_timeout
    local title_update_timeout title_update_open_timeout
    update_json=$(cat <<ENDJSON
{
  "currentVersion": "${version}"
}
ENDJSON
)

    # Bound this call so a slow/unresponsive server does not look like a hang.
    saved_timeout="${_TITLE_EDITOR_API_TIMEOUT:-60}"
    saved_open_timeout="${_TITLE_EDITOR_API_OPEN_TIMEOUT:-60}"
    title_update_timeout="${TEM_TITLE_UPDATE_TIMEOUT:-20}"
    title_update_open_timeout="${TEM_TITLE_UPDATE_OPEN_TIMEOUT:-15}"
    _TITLE_EDITOR_API_TIMEOUT="$title_update_timeout"
    _TITLE_EDITOR_API_OPEN_TIMEOUT="$title_update_open_timeout"

    if update_result=$(_tem_api_put "softwaretitles/${TEM_TITLE_ID}" "$update_json" 2>&1); then
      _TITLE_EDITOR_API_TIMEOUT="$saved_timeout"
      _TITLE_EDITOR_API_OPEN_TIMEOUT="$saved_open_timeout"
      echo "  currentVersion updated to ${version}."
      [[ "$skip_confirm" != "true" ]] && _tem_pause
      return 0
    else
      _TITLE_EDITOR_API_TIMEOUT="$saved_timeout"
      _TITLE_EDITOR_API_OPEN_TIMEOUT="$saved_open_timeout"
      echo "  WARN: Patch was created, but currentVersion update failed."
      echo "  Details:"
      echo "$update_result" | head -5 | sed 's/^/    /'
      [[ "$skip_confirm" != "true" ]] && _tem_pause
      return 1
    fi
  else
    echo ""
    echo "  Unexpected response:"
    echo "$result" | head -5 | sed 's/^/    /'
    [[ "$skip_confirm" != "true" ]] && _tem_pause
    return 1
  fi
}

_tem_add_patch() {
  local data="$1"

  _tem_header "Add New Patch Version — ${TEM_TITLE_NAME}"

  # --- Pre-populate defaults from the most recent patch ---
  local default_bundle default_appname default_compname default_ea_name
  default_bundle=$(echo "$data" | awk '/"killApps"/{f=1} f&&/"bundleId"/{gsub(/.*"bundleId": "|",?$/,"",$0); print; exit}')
  default_appname=$(echo "$data" | awk '/"killApps"/{f=1} f&&/"appName"/{gsub(/.*"appName": "|",?$/,"",$0); print; exit}')
  default_compname=$(echo "$data" | awk '/"components"/{f=1} f&&/"name"/{gsub(/.*"name": "|",?$/,"",$0); print; exit}')
  default_ea_name=$(echo "$data" | awk '/"extensionAttribute"/{f=1} f&&/"name"/{gsub(/.*"name": "|",?$/,"",$0); print; exit}')
  local default_minos
  default_minos=$(echo "$data" | awk '/"minimumOperatingSystem"/{gsub(/.*"minimumOperatingSystem": "|",?$/,"",$0); print; exit}')

  echo ""
  echo "  (Press Enter to accept defaults shown in brackets)"
  echo ""

  # --- Prompt for each field ---
  local version
  version=$(_tem_prompt "  Version:")
  [[ -z "$version" ]] && { echo "Version is required."; _tem_pause; return; }

  local release_date
  release_date=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
  local release_input
  release_input=$(_tem_prompt "  Release Date [${release_date}]:")
  [[ -n "$release_input" ]] && release_date="$release_input"

  local minos_input
  minos_input=$(_tem_prompt "  Minimum OS [${default_minos}]:")
  local minos="${minos_input:-$default_minos}"

  local standalone_input
  standalone_input=$(_tem_prompt "  Standalone [yes]:")
  local standalone="true"
  [[ "$(echo "$standalone_input" | tr "[:upper:]" "[:lower:]")" == "no" ]] && standalone="false"

  local reboot_input
  reboot_input=$(_tem_prompt "  Reboot [no]:")
  local reboot="false"
  [[ "$(echo "$reboot_input" | tr "[:upper:]" "[:lower:]")" == "yes" ]] && reboot="true"

  local bundle_input
  bundle_input=$(_tem_prompt "  Kill App Bundle ID [${default_bundle}]:")
  local bundle="${bundle_input:-$default_bundle}"

  local appname_input
  appname_input=$(_tem_prompt "  Kill App Name [${default_appname}]:")
  local appname="${appname_input:-$default_appname}"

  _tem_submit_patch "$data" "$version" "$release_date" "$minos" "$standalone" "$reboot" "$bundle" "$appname" "false"
}

_tem_run_add_patch_cli() {
  if [[ -z "$TEM_CLI_VERSION" ]]; then
    echo "ERROR: --add-patch requires --version" >&2
    _tem_usage
    return 1
  fi

  if [[ -n "$TEM_CLI_TITLE_ID" && -n "$TEM_CLI_TITLE_NAME" ]]; then
    echo "ERROR: Use either --title-id or --title-name, not both" >&2
    return 1
  fi

  if [[ -z "$TEM_CLI_TITLE_ID" && -z "$TEM_CLI_TITLE_NAME" ]]; then
    echo "ERROR: --add-patch requires --title-id or --title-name" >&2
    _tem_usage
    return 1
  fi

  if [[ -n "$TEM_CLI_TITLE_ID" ]] && ! [[ "$TEM_CLI_TITLE_ID" =~ ^[0-9]+$ ]]; then
    echo "ERROR: --title-id must be numeric" >&2
    return 1
  fi

  if [[ -n "$TEM_CLI_TITLE_NAME" ]]; then
    local resolved resolved_id resolved_name
    resolved=$(_tem_resolve_title_from_name "$TEM_CLI_TITLE_NAME") || return 1
    resolved_id=$(printf '%s\n' "$resolved" | awk -F'|' 'NR==1 {print $1}')
    resolved_name=$(printf '%s\n' "$resolved" | awk -F'|' 'NR==1 {print $2}')
    TEM_CLI_TITLE_ID="$resolved_id"
    _tem_debug_log "Resolved --title-name '${TEM_CLI_TITLE_NAME}' to ID ${TEM_CLI_TITLE_ID} (${resolved_name})"
  fi

  TEM_TITLE_ID="$TEM_CLI_TITLE_ID"
  local data
  data=$(_tem_api_get "softwaretitles/${TEM_TITLE_ID}") || return 1

  local detected_name
  detected_name=$(echo "$data" | awk '/"name"/{gsub(/.*"name": "|",?.*$/, "", $0); print; exit}')
  TEM_TITLE_NAME="${detected_name:-Title ${TEM_TITLE_ID}}"

  local default_bundle default_appname default_minos
  default_bundle=$(echo "$data" | awk '/"killApps"/{f=1} f&&/"bundleId"/{gsub(/.*"bundleId": "|",?$/,"",$0); print; exit}')
  default_appname=$(echo "$data" | awk '/"killApps"/{f=1} f&&/"appName"/{gsub(/.*"appName": "|",?$/,"",$0); print; exit}')
  default_minos=$(echo "$data" | awk '/"minimumOperatingSystem"/{gsub(/.*"minimumOperatingSystem": "|",?$/,"",$0); print; exit}')

  local release_date minos standalone reboot bundle appname
  release_date="${TEM_CLI_RELEASE_DATE:-$(date -u +"%Y-%m-%dT%H:%M:%SZ")}" 
  minos="${TEM_CLI_MIN_OS:-$default_minos}"
  bundle="${TEM_CLI_BUNDLE_ID:-$default_bundle}"
  appname="${TEM_CLI_APP_NAME:-$default_appname}"

  standalone="true"
  if [[ -n "$TEM_CLI_STANDALONE" ]]; then
    if [[ "$(echo "$TEM_CLI_STANDALONE" | tr "[:upper:]" "[:lower:]")" == "no" ]]; then
      standalone="false"
    fi
  fi

  reboot="false"
  if [[ -n "$TEM_CLI_REBOOT" ]]; then
    if [[ "$(echo "$TEM_CLI_REBOOT" | tr "[:upper:]" "[:lower:]")" == "yes" ]]; then
      reboot="true"
    fi
  fi

  if [[ "$TEM_CLI_DRY_RUN" == "true" ]]; then
    local verify_result
    verify_result=$(_tem_validate_patch_fields "$TEM_TITLE_ID" "$TEM_TITLE_NAME" "$TEM_CLI_VERSION" "$release_date" "$minos" "$bundle" "$appname") || return 1
    if [[ "$TEM_CLI_VERIFY_ONLY" == "true" ]]; then
      echo "VERIFY-ONLY: title ID ${TEM_TITLE_ID} (${TEM_TITLE_NAME}) version ${TEM_CLI_VERSION} -> ${verify_result}"
    else
      echo "DRY-RUN: would create patch '${TEM_CLI_VERSION}' for title ID ${TEM_TITLE_ID} (${TEM_TITLE_NAME}) (${verify_result})"
    fi
    return 0
  fi

  _tem_submit_patch "$data" "$TEM_CLI_VERSION" "$release_date" "$minos" "$standalone" "$reboot" "$bundle" "$appname" "$TEM_CLI_YES"
}

_tem_run_add_patch_batch_cli() {
  if [[ -z "$TEM_CLI_BATCH_FILE" ]]; then
    echo "ERROR: --add-patch-batch requires --file <path>" >&2
    _tem_usage
    return 1
  fi

  if [[ ! -f "$TEM_CLI_BATCH_FILE" ]]; then
    echo "ERROR: Batch file not found: $TEM_CLI_BATCH_FILE" >&2
    return 1
  fi

  local expected_header
  expected_header="title_id|title_name|version|release_date|min_os|standalone|reboot|bundle_id|app_name|yes"
  local expected_short_header
  expected_short_header="title_name|version"
  local batch_format=""
  local start_line max_rows selected_rows

  start_line="${TEM_CLI_START_LINE:-1}"
  max_rows="${TEM_CLI_MAX_ROWS:-}"
  selected_rows=0

  if ! [[ "$start_line" =~ ^[0-9]+$ ]] || [[ "$start_line" -lt 1 ]]; then
    echo "ERROR: --start-line must be an integer >= 1" >&2
    return 1
  fi

  if [[ -n "$max_rows" ]]; then
    if ! [[ "$max_rows" =~ ^[0-9]+$ ]] || [[ "$max_rows" -lt 1 ]]; then
      echo "ERROR: --max-rows must be an integer >= 1" >&2
      return 1
    fi
  fi

  local line_no=0
  local header_seen=false
  local total=0
  local success=0
  local skipped=0
  local dry_run_adds=0
  local verified=0
  local repaired=0
  local repair_would=0
  local failed=0

  local staged_rows=0
  local staging_file sorted_file
  local resolved_cache_file
  local touched_titles_file
  local stage_sep
  local unresolved_title_keys=""
  local resolve_error_prompted=false
  local continue_after_resolve_error=false
  local aborted=false
  local abort_reason=""
  staging_file=$(mktemp /tmp/title_editor_menu_batch_stage.XXXXXX)
  sorted_file=$(mktemp /tmp/title_editor_menu_batch_sorted.XXXXXX)
  resolved_cache_file=$(mktemp /tmp/title_editor_menu_batch_resolved.XXXXXX)
  touched_titles_file=$(mktemp /tmp/title_editor_menu_batch_touched_titles.XXXXXX)
  stage_sep=$'\x1f'

  local base_release_date="$TEM_CLI_RELEASE_DATE"
  local base_min_os="$TEM_CLI_MIN_OS"
  local base_standalone="$TEM_CLI_STANDALONE"
  local base_reboot="$TEM_CLI_REBOOT"
  local base_bundle_id="$TEM_CLI_BUNDLE_ID"
  local base_app_name="$TEM_CLI_APP_NAME"
  local base_yes="$TEM_CLI_YES"
  local auto_resequence_on_change="${TEM_AUTO_RESEQUENCE_ON_CHANGE:-true}"

  while IFS= read -r raw_line || [[ -n "$raw_line" ]]; do
    ((line_no++))

    raw_line="${raw_line%$'\r'}"
    [[ -z "${raw_line//[[:space:]]/}" ]] && continue
    [[ "$raw_line" =~ ^[[:space:]]*# ]] && continue

    if [[ "$header_seen" != "true" ]]; then
      local normalized_header
      normalized_header=$(_tem_trim "$raw_line")
      if [[ "$normalized_header" == "$expected_header" ]]; then
        batch_format="full"
        header_seen=true
        continue
      elif [[ "$normalized_header" == "$expected_short_header" ]]; then
        batch_format="short"
        header_seen=true
        continue
      else
        local first_col second_col third_col
        IFS='|' read -r first_col second_col third_col <<< "$raw_line"
        first_col=$(_tem_trim "${first_col:-}")
        second_col=$(_tem_trim "${second_col:-}")
        third_col=$(_tem_trim "${third_col:-}")

        if [[ -n "$first_col" && -n "$second_col" && -z "$third_col" ]]; then
          batch_format="short"
          header_seen=true
        else
          echo "ERROR: Invalid batch header at line ${line_no}." >&2
          echo "Expected one of:" >&2
          echo "  $expected_header" >&2
          echo "  $expected_short_header" >&2
          echo "Or provide headerless short rows in the form: title_name|version" >&2
          return 1
        fi
      fi
    fi

    local row_title_id row_title_name row_version row_release_date row_min_os
    local row_standalone row_reboot row_bundle_id row_app_name row_yes extra

    if [[ "$batch_format" == "short" ]]; then
      IFS='|' read -r row_title_name row_version extra <<< "$raw_line"
      row_title_id=""
      row_release_date=""
      row_min_os=""
      row_standalone=""
      row_reboot=""
      row_bundle_id=""
      row_app_name=""
      row_yes=""
    else
      IFS='|' read -r row_title_id row_title_name row_version row_release_date row_min_os row_standalone row_reboot row_bundle_id row_app_name row_yes extra <<< "$raw_line"
    fi

    row_title_id=$(_tem_trim "${row_title_id:-}")
    row_title_name=$(_tem_trim "${row_title_name:-}")
    row_version=$(_tem_trim "${row_version:-}")
    row_release_date=$(_tem_trim "${row_release_date:-}")
    row_min_os=$(_tem_trim "${row_min_os:-}")
    row_standalone=$(_tem_trim "${row_standalone:-}")
    row_reboot=$(_tem_trim "${row_reboot:-}")
    row_bundle_id=$(_tem_trim "${row_bundle_id:-}")
    row_app_name=$(_tem_trim "${row_app_name:-}")
    row_yes=$(_tem_trim "${row_yes:-}")

    if [[ "$line_no" -lt "$start_line" ]]; then
      continue
    fi

    if [[ -n "$max_rows" && "$selected_rows" -ge "$max_rows" ]]; then
      break
    fi

    local title_sort_key version_sort_key
    if [[ -n "$row_title_id" ]]; then
      title_sort_key="id:${row_title_id}"
    else
      title_sort_key="name:$(_tem_lower "$row_title_name")"
    fi
    version_sort_key=$(_tem_version_sort_key "$row_version")

    printf '%s%s%s%s%s%s%s%s%s%s%s%s%s%s%s%s%s%s%s%s%s%s%s%s%s\n' \
      "$title_sort_key" "$stage_sep" "$version_sort_key" "$stage_sep" "$line_no" "$stage_sep" \
      "$row_title_id" "$stage_sep" "$row_title_name" "$stage_sep" "$row_version" "$stage_sep" "$row_release_date" "$stage_sep" "$row_min_os" "$stage_sep" \
      "$row_standalone" "$stage_sep" "$row_reboot" "$stage_sep" "$row_bundle_id" "$stage_sep" "$row_app_name" "$stage_sep" "$row_yes" >> "$staging_file"
    ((staged_rows++))
    ((selected_rows++))
  done < "$TEM_CLI_BATCH_FILE"

  if [[ "$header_seen" != "true" ]]; then
    rm -f "$staging_file" "$sorted_file" >/dev/null 2>&1 || true
    echo "ERROR: Batch file has no header row or valid short-format rows." >&2
    return 1
  fi

  sort -t "$stage_sep" -k1,1 -k2,2 -k3,3n "$staging_file" > "$sorted_file"

  local current_title_key=""
  local current_existing_versions=""
  local current_title_data=""
  local batch_start_time
  batch_start_time=$(date +%s)

  while IFS="$stage_sep" read -r staged_title_key staged_version_key staged_line_no row_title_id row_title_name row_version row_release_date row_min_os row_standalone row_reboot row_bundle_id row_app_name row_yes; do
    ((total++))
    local now elapsed avg_per_batch pct remaining eta_seconds
    now=$(date +%s)
    elapsed=$((now - batch_start_time))
    if (( total > 0 )); then
      avg_per_batch=$((elapsed / total))
    else
      avg_per_batch=0
    fi
    if (( staged_rows > 0 )); then
      pct=$(( (total * 100) / staged_rows ))
      remaining=$((staged_rows - total))
      eta_seconds=$((remaining * avg_per_batch))
    else
      pct=0
      remaining=0
      eta_seconds=0
    fi

    echo ""
    echo "[Batch ${total}/${staged_rows} ${pct}%] Line ${staged_line_no}: starting (elapsed ${elapsed}s, est ${eta_seconds}s left)"

    TEM_CLI_TITLE_ID="$row_title_id"
    TEM_CLI_TITLE_NAME="$row_title_name"
    TEM_CLI_VERSION="$row_version"
    TEM_CLI_RELEASE_DATE="${row_release_date:-$base_release_date}"
    TEM_CLI_MIN_OS="${row_min_os:-$base_min_os}"
    TEM_CLI_STANDALONE="${row_standalone:-$base_standalone}"
    TEM_CLI_REBOOT="${row_reboot:-$base_reboot}"
    TEM_CLI_BUNDLE_ID="${row_bundle_id:-$base_bundle_id}"
    TEM_CLI_APP_NAME="${row_app_name:-$base_app_name}"

    if [[ -n "$row_yes" ]]; then
      if [[ "$(echo "$row_yes" | tr '[:upper:]' '[:lower:]')" == "yes" || "$(echo "$row_yes" | tr '[:upper:]' '[:lower:]')" == "true" ]]; then
        TEM_CLI_YES=true
      else
        TEM_CLI_YES=false
      fi
    else
      TEM_CLI_YES="$base_yes"
    fi

    if [[ -z "$TEM_CLI_TITLE_ID" && -n "$TEM_CLI_TITLE_NAME" ]]; then
      local cached_resolved cached_id cached_name
      cached_resolved=$(awk -F "$stage_sep" -v key="$staged_title_key" '$1 == key { print $2 "|" $3; exit }' "$resolved_cache_file")
      if [[ -n "$cached_resolved" ]]; then
        cached_id=$(printf '%s\n' "$cached_resolved" | awk -F'|' 'NR==1 {print $1}')
        cached_name=$(printf '%s\n' "$cached_resolved" | awk -F'|' 'NR==1 {print $2}')
        TEM_CLI_TITLE_ID="$cached_id"
        TEM_CLI_TITLE_NAME="$cached_name"
      fi

      if [[ -n "$TEM_CLI_TITLE_ID" ]]; then
        :
      else
      if printf '%s\n' "$unresolved_title_keys" | sed '/^$/d' | grep -Fqx "$staged_title_key"; then
        ((failed++))
        echo "[Batch ${total}] Line ${staged_line_no}: failed (title previously unresolved for '${TEM_CLI_TITLE_NAME}')"
        continue
      fi

      local resolved resolved_id resolved_name
      resolved=$(_tem_resolve_title_from_name "$TEM_CLI_TITLE_NAME")
      if [[ $? -ne 0 ]]; then
        ((failed++))
        echo "[Batch ${total}] Line ${staged_line_no}: failed (could not resolve title)"

        unresolved_title_keys+=$'\n'
        unresolved_title_keys+="$staged_title_key"

        if [[ "$TEM_CLI_YES" != "true" && -r /dev/tty ]]; then
          if [[ "$resolve_error_prompted" != "true" ]]; then
            local continue_input
            read -r -p "A title name could not be resolved. Continue processing remaining rows? [yes/no]: " continue_input < /dev/tty
            if [[ "$(echo "$continue_input" | tr '[:upper:]' '[:lower:]')" == "yes" ]]; then
              continue_after_resolve_error=true
            else
              continue_after_resolve_error=false
            fi
            resolve_error_prompted=true
          fi

          if [[ "$continue_after_resolve_error" == "true" ]]; then
            continue
          fi
        fi

        aborted=true
        abort_reason="title-name resolution failed for '${TEM_CLI_TITLE_NAME}'"
        echo "[Batch ${total}] Aborting batch: ${abort_reason}"
        break
      fi
      resolved_id=$(printf '%s\n' "$resolved" | awk -F'|' 'NR==1 {print $1}')
      resolved_name=$(printf '%s\n' "$resolved" | awk -F'|' 'NR==1 {print $2}')
      TEM_CLI_TITLE_ID="$resolved_id"
      TEM_CLI_TITLE_NAME="$resolved_name"
      printf '%s%s%s%s%s\n' "$staged_title_key" "$stage_sep" "$resolved_id" "$stage_sep" "$resolved_name" >> "$resolved_cache_file"
      fi
    fi

    if [[ "$staged_title_key" != "$current_title_key" ]]; then
      current_title_key="$staged_title_key"
      local title_data
      if ! title_data=$(_tem_api_get "softwaretitles/${TEM_CLI_TITLE_ID}"); then
        ((failed++))
        echo "[Batch ${total}] Line ${staged_line_no}: failed (could not fetch existing patches for title ID ${TEM_CLI_TITLE_ID})"
        continue
      fi
      current_title_data="$title_data"
      current_existing_versions=$(_tem_extract_existing_patch_versions "$title_data")
    fi

    if printf '%s\n' "$current_existing_versions" | grep -Fqx "$TEM_CLI_VERSION"; then
      if [[ "$TEM_CLI_REPAIR_BATCH_EXISTING" == "true" ]]; then
        local repair_plan repair_status repair_patch_id repair_payload
        repair_plan=$(_tem_prepare_repair_existing_patch_payload "$current_title_data" "$TEM_CLI_VERSION")
        repair_status=$(printf '%s\n' "$repair_plan" | awk -F'\t' 'NR==1 {print $2}')
        repair_patch_id=$(printf '%s\n' "$repair_plan" | awk -F'\t' 'NR==1 {print $3}')
        repair_payload=$(printf '%s\n' "$repair_plan" | awk -F'\t' 'NR==2 {sub(/^PAYLOAD\t/, ""); print}')

        case "$repair_status" in
          NO_CHANGE)
            ((skipped++))
            echo "[Batch ${total}] Line ${staged_line_no}: skipped (version ${TEM_CLI_VERSION} already exists; criteria already OK)"
            ;;
          CHANGED)
            if [[ "$TEM_CLI_DRY_RUN" == "true" ]]; then
              ((repair_would++))
              echo "[Batch ${total}] Line ${staged_line_no}: dry-run would repair existing version ${TEM_CLI_VERSION} (patchId ${repair_patch_id})"
            else
              local repaired_ok=false
              echo "[Batch ${total}] Line ${staged_line_no}: repairing existing version ${TEM_CLI_VERSION} (patchId ${repair_patch_id})"

              if _tem_api_put "patches/${repair_patch_id}" "$repair_payload" >/dev/null 2>/dev/null; then
                current_title_data=$(_tem_api_get "softwaretitles/${TEM_CLI_TITLE_ID}" 2>/dev/null || printf '%s' "$current_title_data")
                if [[ "$(_tem_patch_has_app_version_criteria "$current_title_data" "$TEM_CLI_VERSION")" == "YES" ]]; then
                  repaired_ok=true
                fi
              fi

              if [[ "$repaired_ok" != "true" ]]; then
                if _tem_api_put "softwaretitles/${TEM_CLI_TITLE_ID}/patches/${repair_patch_id}" "$repair_payload" >/dev/null 2>/dev/null; then
                  current_title_data=$(_tem_api_get "softwaretitles/${TEM_CLI_TITLE_ID}" 2>/dev/null || printf '%s' "$current_title_data")
                  if [[ "$(_tem_patch_has_app_version_criteria "$current_title_data" "$TEM_CLI_VERSION")" == "YES" ]]; then
                    repaired_ok=true
                  fi
                fi
              fi

              if [[ "$repaired_ok" != "true" && "$TEM_CLI_REPAIR_RECREATE_EXISTING" == "true" ]]; then
                local recreate_payload
                local recreate_error=""
                recreate_payload=$(_tem_prepare_recreate_patch_payload "$repair_payload")
                if [[ -n "$recreate_payload" ]]; then
                  local delete_ok=false
                  local delete_out
                  if delete_out=$(_tem_api_delete "patches/${repair_patch_id}" 2>&1); then
                    delete_ok=true
                  else
                    recreate_error="delete patches/${repair_patch_id} failed: ${delete_out}"
                    if delete_out=$(_tem_api_delete "softwaretitles/${TEM_CLI_TITLE_ID}/patches/${repair_patch_id}" 2>&1); then
                      delete_ok=true
                      recreate_error=""
                    else
                      recreate_error="delete fallback softwaretitles/${TEM_CLI_TITLE_ID}/patches/${repair_patch_id} failed: ${delete_out}"
                    fi
                  fi

                  if [[ "$delete_ok" == "true" ]]; then
                    local create_out
                    if create_out=$(_tem_api_post "softwaretitles/${TEM_CLI_TITLE_ID}/patches" "$recreate_payload" 2>&1); then
                      current_title_data=$(_tem_api_get "softwaretitles/${TEM_CLI_TITLE_ID}" 2>/dev/null || printf '%s' "$current_title_data")
                      if [[ "$(_tem_patch_has_app_version_criteria "$current_title_data" "$TEM_CLI_VERSION")" == "YES" ]]; then
                        repaired_ok=true
                        echo "[Batch ${total}] Line ${staged_line_no}: repair fallback used recreate for version ${TEM_CLI_VERSION}"
                        printf '%s\n' "$TEM_CLI_TITLE_ID" >> "$touched_titles_file"
                      else
                        recreate_error="recreate succeeded but verification still failed"
                      fi
                    else
                      recreate_error="recreate post failed: ${create_out}"
                    fi
                  fi
                else
                  recreate_error="could not build recreate payload"
                fi

                if [[ "$repaired_ok" != "true" && -n "$recreate_error" ]]; then
                  echo "[Batch ${total}] Line ${staged_line_no}: repair fallback detail: ${recreate_error}"
                fi
              fi

              if [[ "$repaired_ok" == "true" ]]; then
                ((repaired++))
                echo "[Batch ${total}] Line ${staged_line_no}: repaired existing version ${TEM_CLI_VERSION} (patchId ${repair_patch_id})"
                printf '%s\n' "$TEM_CLI_TITLE_ID" >> "$touched_titles_file"
              else
                ((failed++))
                echo "[Batch ${total}] Line ${staged_line_no}: failed repair (update did not persist Application Version criteria for ${TEM_CLI_VERSION})"
              fi
            fi
            ;;
          NO_PATCH)
            ((failed++))
            echo "[Batch ${total}] Line ${staged_line_no}: failed repair (existing version not found in title payload: ${repair_patch_id})"
            ;;
          ERROR)
            ((failed++))
            echo "[Batch ${total}] Line ${staged_line_no}: failed repair (${repair_patch_id})"
            ;;
          *)
            ((failed++))
            echo "[Batch ${total}] Line ${staged_line_no}: failed repair (${repair_status:-unknown}${repair_patch_id:+: ${repair_patch_id}})"
            ;;
        esac
      else
        ((skipped++))
        echo "[Batch ${total}] Line ${staged_line_no}: skipped (version ${TEM_CLI_VERSION} already exists)"
      fi
      continue
    fi

    if [[ "$TEM_CLI_DRY_RUN" == "true" ]]; then
      local title_data_for_verify
      local verify_title_name="${TEM_CLI_TITLE_NAME}"
      if ! title_data_for_verify=$(_tem_api_get "softwaretitles/${TEM_CLI_TITLE_ID}"); then
        ((failed++))
        echo "[Batch ${total}] Line ${staged_line_no}: failed (could not fetch title data for verification)"
        continue
      fi

      local verify_default_bundle verify_default_appname verify_default_minos
      verify_default_bundle=$(echo "$title_data_for_verify" | awk '/"killApps"/{f=1} f&&/"bundleId"/{gsub(/.*"bundleId": "|",?$/,"",$0); print; exit}')
      verify_default_appname=$(echo "$title_data_for_verify" | awk '/"killApps"/{f=1} f&&/"appName"/{gsub(/.*"appName": "|",?$/,"",$0); print; exit}')
      verify_default_minos=$(echo "$title_data_for_verify" | awk '/"minimumOperatingSystem"/{gsub(/.*"minimumOperatingSystem": "|",?$/,"",$0); print; exit}')

      local verify_release_date verify_minos verify_bundle verify_appname
      verify_release_date="${TEM_CLI_RELEASE_DATE:-$(date -u +"%Y-%m-%dT%H:%M:%SZ")}" 
      verify_minos="${TEM_CLI_MIN_OS:-$verify_default_minos}"
      verify_bundle="${TEM_CLI_BUNDLE_ID:-$verify_default_bundle}"
      verify_appname="${TEM_CLI_APP_NAME:-$verify_default_appname}"

      if _tem_validate_patch_fields "$TEM_CLI_TITLE_ID" "$verify_title_name" "$TEM_CLI_VERSION" "$verify_release_date" "$verify_minos" "$verify_bundle" "$verify_appname" >/dev/null; then
        if [[ "$TEM_CLI_VERIFY_ONLY" == "true" ]]; then
          ((verified++))
          echo "[Batch ${total}] Line ${staged_line_no}: verified"
        else
          ((dry_run_adds++))
          echo "[Batch ${total}] Line ${staged_line_no}: dry-run would add version ${TEM_CLI_VERSION}"
        fi
      else
        ((failed++))
        echo "[Batch ${total}] Line ${staged_line_no}: failed verification"
      fi

      if [[ -n "$current_existing_versions" ]]; then
        current_existing_versions+=$'\n'
      fi
      current_existing_versions+="$TEM_CLI_VERSION"
      continue
    fi

    local saved_title_name="$TEM_CLI_TITLE_NAME"
    TEM_CLI_TITLE_NAME=""
    if _tem_run_add_patch_cli; then
      ((success++))
      echo "[Batch ${total}] Line ${staged_line_no}: success"
      printf '%s\n' "$TEM_CLI_TITLE_ID" >> "$touched_titles_file"
      if [[ -n "$current_existing_versions" ]]; then
        current_existing_versions+=$'\n'
      fi
      current_existing_versions+="$TEM_CLI_VERSION"
    else
      ((failed++))
      echo "[Batch ${total}] Line ${staged_line_no}: failed"
    fi
    TEM_CLI_TITLE_NAME="$saved_title_name"
  done < "$sorted_file"

  if [[ "$TEM_CLI_DRY_RUN" != "true" && "$auto_resequence_on_change" == "true" ]]; then
    local touched_count reseq_ok reseq_fail
    touched_count=0
    reseq_ok=0
    reseq_fail=0
    while IFS= read -r tid; do
      [[ -z "$tid" ]] && continue
      ((touched_count++))
      if _tem_resequence_title_by_id "$tid"; then
        ((reseq_ok++))
        echo "[Resequence] Title ID ${tid}: semantic order restored"
      else
        ((reseq_fail++))
        echo "[Resequence] Title ID ${tid}: failed" >&2
      fi
    done < <(sort -u "$touched_titles_file")

    if [[ "$touched_count" -gt 0 ]]; then
      echo "[Resequence] complete: touched=${touched_count}, success=${reseq_ok}, failed=${reseq_fail}"
      if [[ "$reseq_fail" -gt 0 ]]; then
        failed=$((failed + reseq_fail))
      fi
    fi
  fi

  rm -f "$staging_file" "$sorted_file" "$resolved_cache_file" "$touched_titles_file" >/dev/null 2>&1 || true

  echo ""
  if [[ "$aborted" == "true" ]]; then
    echo "Batch aborted: ${abort_reason}"
  fi

  if [[ "$TEM_CLI_DRY_RUN" == "true" ]]; then
    if [[ "$TEM_CLI_VERIFY_ONLY" == "true" ]]; then
      echo "Batch verify-only complete: total=${total}, verified=${verified}, skipped=${skipped}, failed=${failed}, repair_would=${repair_would}"
    else
      echo "Batch dry-run complete: total=${total}, would_add=${dry_run_adds}, skipped=${skipped}, failed=${failed}, repair_would=${repair_would}"
    fi
  else
    echo "Batch complete: total=${total}, success=${success}, repaired=${repaired}, skipped=${skipped}, failed=${failed}"
  fi
  [[ "$failed" -eq 0 ]]
}

_tem_run_create_title_cli() {
  if [[ -z "$TEM_CLI_TITLE_NAME" ]]; then
    echo "ERROR: --create-title requires --title-name" >&2
    return 1
  fi

  if [[ -n "$TEM_CLI_TITLE_ID" ]]; then
    echo "ERROR: --create-title does not accept --title-id (numeric ID is assigned by server)" >&2
    return 1
  fi

  local existing
  existing=$(_tem_find_title_by_exact_name "$TEM_CLI_TITLE_NAME" || true)
  if [[ -n "$existing" ]]; then
    local existing_id existing_name
    existing_id=$(printf '%s\n' "$existing" | awk -F'|' 'NR==1 {print $1}')
    existing_name=$(printf '%s\n' "$existing" | awk -F'|' 'NR==1 {print $2}')
    echo "ERROR: A title with this name already exists: ${existing_name} (ID: ${existing_id})" >&2
    return 1
  fi

  local title_id_string
  title_id_string="$TEM_CLI_NEW_TITLE_ID_STRING"
  if [[ -z "$title_id_string" ]]; then
    title_id_string=$(_tem_slugify_title_id "$TEM_CLI_TITLE_NAME")
  fi
  if [[ -z "$title_id_string" ]]; then
    echo "ERROR: Could not derive a valid title ID string. Use --new-title-id." >&2
    return 1
  fi

  local payload
  if [[ -n "$TEM_CLI_TITLE_JSON_FILE" ]]; then
    if [[ ! -f "$TEM_CLI_TITLE_JSON_FILE" ]]; then
      echo "ERROR: --title-json-file not found: $TEM_CLI_TITLE_JSON_FILE" >&2
      return 1
    fi
    payload=$(cat "$TEM_CLI_TITLE_JSON_FILE")
  else
    if [[ -z "$TEM_CLI_BUNDLE_ID" ]]; then
      echo "ERROR: --create-title requires --bundle-id unless --title-json-file is provided." >&2
      return 1
    fi
    payload=$(_tem_build_create_title_payload "$TEM_CLI_TITLE_NAME" "$title_id_string" "$TEM_CLI_PUBLISHER" "$TEM_CLI_BUNDLE_ID" "$TEM_CLI_VERSION")
  fi

  if [[ "$TEM_CLI_DRY_RUN" == "true" ]]; then
    echo "DRY-RUN: would create software title '${TEM_CLI_TITLE_NAME}' (id='${title_id_string}')."
    echo "DRY-RUN: payload preview:"
    printf '%s\n' "$payload"
    if [[ -n "$TEM_CLI_VERSION" ]]; then
      echo "DRY-RUN: would then create initial patch version '${TEM_CLI_VERSION}'."
    fi
    if [[ -n "$TEM_CLI_BATCH_FILE" ]]; then
      echo "DRY-RUN: would then run batch patch import from '${TEM_CLI_BATCH_FILE}'."
    fi
    return 0
  fi

  local create_result
  if ! create_result=$(_tem_api_post "softwaretitles" "$payload" 2>&1); then
    echo "ERROR: Software title creation failed." >&2
    echo "$create_result" | head -10 | sed 's/^/  /' >&2
    return 1
  fi

  local created_title_id
  created_title_id=$(_tem_extract_numeric_title_id_from_json "$create_result")
  if [[ -z "$created_title_id" ]]; then
    local resolved
    resolved=$(_tem_find_title_by_exact_name "$TEM_CLI_TITLE_NAME" || true)
    created_title_id=$(printf '%s\n' "$resolved" | awk -F'|' 'NR==1 {print $1}')
  fi

  if [[ -z "$created_title_id" ]]; then
    echo "ERROR: Title may have been created, but could not resolve numeric softwareTitleId from response." >&2
    return 1
  fi

  TEM_CLI_TITLE_ID="$created_title_id"
  echo "Created software title: ${TEM_CLI_TITLE_NAME} (ID: ${TEM_CLI_TITLE_ID}, id: ${title_id_string})"

  # Some API versions may ignore enabled=true on create.
  # Enforce enabled state explicitly so new titles are usable immediately.
  local enable_payload enable_result
  enable_payload='{"enabled":true}'
  if enable_result=$(_tem_api_put "softwaretitles/${TEM_CLI_TITLE_ID}" "$enable_payload" 2>&1); then
    echo "Enabled software title: ${TEM_CLI_TITLE_NAME} (ID: ${TEM_CLI_TITLE_ID})"
  else
    echo "WARN: Title was created, but enabling it failed." >&2
    echo "$enable_result" | head -5 | sed 's/^/  /' >&2
  fi

  local rc=0
  if [[ -n "$TEM_CLI_VERSION" ]]; then
    if [[ -z "$TEM_CLI_MIN_OS" ]]; then
      echo "ERROR: --create-title with --version requires --min-os for the initial patch." >&2
      rc=1
    fi

    if [[ -z "$TEM_CLI_BUNDLE_ID" ]]; then
      echo "ERROR: --create-title with --version requires --bundle-id for the initial patch." >&2
      rc=1
    fi

    if [[ -z "$TEM_CLI_APP_NAME" ]]; then
      # New titles do not have existing killApps defaults; use title name.
      TEM_CLI_APP_NAME="$TEM_CLI_TITLE_NAME"
    fi

    if [[ "$rc" -ne 0 ]]; then
      return "$rc"
    fi

    echo "Creating initial patch version ${TEM_CLI_VERSION}..."
    local saved_create_title_name
    saved_create_title_name="$TEM_CLI_TITLE_NAME"
    TEM_CLI_TITLE_NAME=""
    if ! _tem_run_add_patch_cli; then
      rc=1
    fi
    TEM_CLI_TITLE_NAME="$saved_create_title_name"
  fi

  if [[ -n "$TEM_CLI_BATCH_FILE" ]]; then
    echo "Running initial batch import from ${TEM_CLI_BATCH_FILE}..."
    if ! _tem_run_add_patch_batch_cli; then
      rc=1
    fi
  fi

  return "$rc"
}

_tem_run_cleanup_non_semver_cli() {
  if [[ -n "$TEM_CLI_TITLE_ID" && -n "$TEM_CLI_TITLE_NAME" ]]; then
    echo "ERROR: Use either --title-id or --title-name, not both" >&2
    return 1
  fi

  if [[ -z "$TEM_CLI_TITLE_ID" && -z "$TEM_CLI_TITLE_NAME" ]]; then
    echo "ERROR: --cleanup-non-semver requires --title-id or --title-name" >&2
    return 1
  fi

  if [[ -n "$TEM_CLI_TITLE_ID" ]] && ! [[ "$TEM_CLI_TITLE_ID" =~ ^[0-9]+$ ]]; then
    echo "ERROR: --title-id must be numeric" >&2
    return 1
  fi

  if [[ -n "$TEM_CLI_TITLE_NAME" ]]; then
    local resolved resolved_id resolved_name
    resolved=$(_tem_resolve_title_from_name "$TEM_CLI_TITLE_NAME") || return 1
    resolved_id=$(printf '%s\n' "$resolved" | awk -F'|' 'NR==1 {print $1}')
    resolved_name=$(printf '%s\n' "$resolved" | awk -F'|' 'NR==1 {print $2}')
    TEM_CLI_TITLE_ID="$resolved_id"
    TEM_CLI_TITLE_NAME="$resolved_name"
  fi

  local title_id="$TEM_CLI_TITLE_ID"
  local title_data title_name
  title_data=$(_tem_api_get "softwaretitles/${title_id}") || return 1
  title_name=$(echo "$title_data" | awk '/"name"/{gsub(/.*"name": "|",?.*$/, "", $0); print; exit}')
  [[ -z "$title_name" ]] && title_name="Title ${title_id}"

  local bad_list
  bad_list=$(python3 - <<'PY' "$title_data"
import json
import re
import sys

raw = sys.argv[1]
try:
    data = json.loads(raw)
except Exception:
    sys.exit(0)

for patch in (data.get("patches") or []):
    if not isinstance(patch, dict):
        continue
    version = str(patch.get("version") or "").strip()
    patch_id = patch.get("patchId") or patch.get("id") or patch.get("softwarePatchId")
    if not version or patch_id is None:
        continue
    if not re.fullmatch(r'\d+(?:\.\d+){1,3}', version):
        print(f"{patch_id}\t{version}")
PY
)

  if [[ -z "$bad_list" ]]; then
    echo "No non-semver patch versions found for ${title_name} (ID: ${title_id})."
    return 0
  fi

  echo ""
  _tem_header "Cleanup Non-SemVer Patches — ${title_name}"
  echo "The following patches will be deleted:"
  printf '%s\n' "$bad_list" | awk -F'\t' '{ printf "  - patchId=%s version=%s\n", $1, $2 }'

  local delete_count
  delete_count=$(printf '%s\n' "$bad_list" | sed '/^$/d' | wc -l | tr -d ' ')

  if [[ "$TEM_CLI_DRY_RUN" == "true" ]]; then
    echo ""
    echo "DRY-RUN: would delete ${delete_count} patch(es) and resequence title ID ${title_id}."
    return 0
  fi

  if [[ "$TEM_CLI_YES" != "true" ]]; then
    if [[ ! -r /dev/tty ]]; then
      echo "ERROR: Confirmation required but no interactive TTY available. Re-run with --yes." >&2
      return 1
    fi
    local confirm
    read -r -p "Delete these ${delete_count} patch(es)? [yes/no]: " confirm < /dev/tty
    if [[ "$(echo "$confirm" | tr '[:upper:]' '[:lower:]')" != "yes" ]]; then
      echo "Cancelled."
      return 1
    fi
  fi

  local deleted=0
  local failed=0
  while IFS=$'\t' read -r patch_id version; do
    [[ -z "$patch_id" ]] && continue
    if _tem_api_delete "patches/${patch_id}" >/dev/null 2>/dev/null; then
      ((deleted++))
      echo "Deleted patchId=${patch_id} version=${version}"
    else
      ((failed++))
      echo "Failed delete patchId=${patch_id} version=${version}" >&2
    fi
  done <<< "$bad_list"

  if [[ "$deleted" -gt 0 ]]; then
    if _tem_resequence_title_by_id "$title_id"; then
      echo "Resequence complete for title ID ${title_id}."
    else
      ((failed++))
      echo "Resequence failed for title ID ${title_id}." >&2
    fi
  fi

  echo "Cleanup complete: deleted=${deleted}, failed=${failed}"
  [[ "$failed" -eq 0 ]]
}

# Patch detail submenu
_tem_patch_menu() {
  local data="$1"

  while true; do
    _tem_select_patch "$data" || return
    local version="$TEM_PATCH_VERSION"

    while true; do
      _tem_header "Patch Options — ${TEM_TITLE_NAME} ${version}"
      echo "  1) Kill Apps"
      echo "  2) Components"
      echo "  3) Capabilities"
      echo "  4) Select different version"
      echo "  5) Back"
      echo ""
      local choice
      choice=$(_tem_prompt "Enter number:")

      case "$choice" in
        1) _tem_show_kill_apps "$data" "$version" ;;
        2) _tem_show_components "$data" "$version" ;;
        3) _tem_show_capabilities "$data" "$version" ;;
        4) break ;;
        5) return ;;
        *) echo "Invalid selection." ;;
      esac
    done
  done
}

# Title detail submenu
_tem_title_menu() {
  local data="$1"

  while true; do
    _tem_header "Title Options — ${TEM_TITLE_NAME}"
    echo "  1) Requirements"
    echo "  2) Extension Attributes"
    echo "  3) Patches (summary)"
    echo "  4) Patch details (kill apps, components, capabilities)"
    echo "  5) Add new patch version"
    echo "  6) Export current title to JSON"
    echo "  7) Select different title"
    echo "  8) Main menu"
    echo ""
    local choice
    choice=$(_tem_prompt "Enter number:")

    case "$choice" in
      1) _tem_show_requirements "$data" ;;
      2) _tem_show_extension_attributes "$data" ;;
      3) _tem_show_patches_summary "$data" ;;
      4) _tem_patch_menu "$data" ;;
      5) _tem_add_patch "$data"; data=$(_tem_api_get "softwaretitles/${TEM_TITLE_ID}") ;;
      6) _tem_export_current_title_json_interactive "$data" ;;
      7) return 1 ;;
      8) return 0 ;;
      *) echo "Invalid selection." ;;
    esac
  done
}

# Main menu
_tem_main_menu() {
  while true; do
    _tem_header "Title Editor Menu"
    echo "  Connected as: $(title_editor_api_to_s)"
    echo ""
    echo "  1) Browse software titles"
    echo "  2) Disconnect"
    echo "  3) Quit"
    echo ""
    local choice
    choice=$(_tem_prompt "Enter number:")

    case "$choice" in
      1)
        while true; do
          _tem_select_title || continue
          local data
          echo ""
          echo "Fetching title data..."
          data=$(_tem_api_get "softwaretitles/${TEM_TITLE_ID}")
          _tem_title_menu "$data"
          local rc=$?
          # rc=0 means go back to main menu, rc=1 means select another title
          [[ $rc -eq 0 ]] && break
        done
        ;;
      2)
        title_editor_api_disconnect
        echo "Disconnected."
        ;;
      3)
        echo "Goodbye."
        exit 0
        ;;
      *)
        echo "Invalid selection."
        ;;
    esac
  done
}

###############################################################################
# ENTRY POINT
###############################################################################

tem_main() {
  _tem_check_sourced
  _tem_check_connected || return 1
  _tem_main_menu
}

# Run automatically if executed directly
if [[ "${BASH_SOURCE[0]:-}" == "${0}" ]]; then
  _tem_parse_args "$@"

  # Auto-source the API library if not already loaded.
  # Look for it next to this script first, then in common locations.
  if ! declare -f title_editor_api_connect &>/dev/null; then
    SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
    API_SCRIPT=""
    for candidate in       "${SCRIPT_DIR}/title_editor_api_ctrl.sh"       "${HOME}/title_editor_api_ctrl.sh"       "/usr/local/bin/title_editor_api_ctrl.sh"
    do
      if [[ -f "$candidate" ]]; then
        API_SCRIPT="$candidate"
        break
      fi
    done

    if [[ -z "$API_SCRIPT" ]]; then
      echo "ERROR: Cannot find title_editor_api_ctrl.sh" >&2
      echo "Place it in the same directory as this script or source it manually first." >&2
      exit 1
    fi

    # shellcheck source=/dev/null
    source "$API_SCRIPT"
  fi

  if ! _tem_check_connected; then
    exit 1
  fi

  if [[ "$TEM_CLI_MODE" == "create-title" ]]; then
    _tem_run_create_title_cli
    exit $?
  fi

  if [[ "$TEM_CLI_MODE" == "add-patch" ]]; then
    _tem_run_add_patch_cli
    exit $?
  fi

  if [[ "$TEM_CLI_MODE" == "add-patch-batch" ]]; then
    _tem_run_add_patch_batch_cli
    exit $?
  fi

  if [[ "$TEM_CLI_MODE" == "export-title-json" ]]; then
    _tem_run_export_title_json_cli
    exit $?
  fi

  if [[ "$TEM_CLI_MODE" == "resequence-only" ]]; then
    _tem_run_resequence_cli
    exit $?
  fi

  if [[ "$TEM_CLI_MODE" == "cleanup-non-semver" ]]; then
    _tem_run_cleanup_non_semver_cli
    exit $?
  fi

  _tem_main_menu
fi
