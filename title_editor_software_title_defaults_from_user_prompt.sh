#!/usr/bin/env bash
#
# Title Editor Defaults from User Prompt
# Version: 1.0.1
# Revised: 2026.03.11
#
# Prompts for a macOS .app path, derives common Title Editor defaults,
# and runs title_editor_menu.sh for either:
# - creating a new software title + initial patch, or
# - adding a new patch to an existing title.

set -euo pipefail

SCRIPT_VERSION="1.0.1"

trim() {
  local value="$1"
  value="${value#${value%%[![:space:]]*}}"
  value="${value%${value##*[![:space:]]}}"
  printf '%s' "$value"
}

prompt_default() {
  local prompt="$1"
  local def="${2:-}"
  local input=""
  if [[ -n "$def" ]]; then
    read -r -p "${prompt} [${def}]: " input
    input=$(trim "$input")
    [[ -z "$input" ]] && input="$def"
  else
    read -r -p "${prompt}: " input
    input=$(trim "$input")
  fi
  printf '%s' "$input"
}

prompt_required() {
  local prompt="$1"
  local def="${2:-}"
  local value=""
  while true; do
    value=$(prompt_default "$prompt" "$def")
    if [[ -n "$value" ]]; then
      printf '%s' "$value"
      return 0
    fi
    echo "Value is required."
  done
}

is_yes() {
  local v
  v=$(printf '%s' "${1:-}" | tr '[:upper:]' '[:lower:]')
  [[ "$v" == "y" || "$v" == "yes" || "$v" == "true" || "$v" == "1" ]]
}

read_plist_key() {
  local plist="$1"
  local key="$2"
  local value=""

  if [[ -x /usr/libexec/PlistBuddy ]]; then
    value=$(/usr/libexec/PlistBuddy -c "Print :${key}" "$plist" 2>/dev/null || true)
  fi

  if [[ -z "$value" ]]; then
    value=$(defaults read "$plist" "$key" 2>/dev/null || true)
  fi

  printf '%s' "$value"
}

derive_min_os_from_binary() {
  local bin_path="$1"
  [[ -f "$bin_path" ]] || return 0

  otool -l "$bin_path" 2>/dev/null | awk '
    /LC_BUILD_VERSION/ { in_build=1; in_old=0; next }
    /LC_VERSION_MIN_MACOSX/ { in_old=1; in_build=0; next }
    in_build && $1 == "minos" { print $2; exit }
    in_old && $1 == "version" { print $2; exit }
  '
}

derive_publisher_from_copyright() {
  local raw="$1"
  [[ -n "$raw" ]] || return 0

  # Normalize common copyright text to a likely publisher/org name.
  printf '%s' "$raw" | sed -E \
    -e 's/[[:space:]]+/ /g' \
    -e 's/^[[:space:]]*//; s/[[:space:]]*$//' \
    -e 's/^[Cc]opyright[[:space:]]*(\(c\)|©)?[[:space:]]*//' \
    -e 's/^[0-9]{4}([[:space:]]*-[[:space:]]*[0-9]{4})?[[:space:]]*//' \
    -e 's/^[Bb]y[[:space:]]+//' \
    -e 's/[[:space:]]*[Aa]ll[[:space:]]+[Rr]ights[[:space:]]+[Rr]eserved\.?[[:space:]]*$//' \
    -e 's/[[:space:]]*[Ii]nc\.?[[:space:]]*$//' \
    -e 's/[[:space:]]*$//' \
    -e 's/[[:space:]]*[.,;:]$//'
}

print_cmd() {
  local out=""
  local arg
  for arg in "$@"; do
    if [[ -n "$out" ]]; then
      out+=" "
    fi
    out+="$(printf '%q' "$arg")"
  done
  printf '%s\n' "$out"
}

main() {
  local script_dir menu_script
  script_dir="$(cd "$(dirname "$0")" && pwd)"
  menu_script="${script_dir}/title_editor_menu.sh"

  if [[ ! -f "$menu_script" ]]; then
    echo "ERROR: Cannot find title_editor_menu.sh next to this script: $menu_script" >&2
    exit 1
  fi

  echo "================================================"
  echo "  Title Editor Prompt from App v${SCRIPT_VERSION}"
  echo "================================================"
  echo ""

  local app_path
  app_path=$(prompt_required "Path to .app")
  if [[ ! -d "$app_path" ]]; then
    echo "ERROR: App path not found: $app_path" >&2
    exit 1
  fi

  local plist_path
  plist_path="${app_path}/Contents/Info.plist"
  if [[ ! -f "$plist_path" ]]; then
    echo "ERROR: Info.plist not found at: $plist_path" >&2
    exit 1
  fi

  local app_name bundle_id version app_exec min_os bin_path copyright_raw publisher_default

  app_name=$(read_plist_key "$plist_path" "CFBundleDisplayName")
  [[ -z "$app_name" ]] && app_name=$(read_plist_key "$plist_path" "CFBundleName")
  [[ -z "$app_name" ]] && app_name="$(basename "$app_path" .app)"

  bundle_id=$(read_plist_key "$plist_path" "CFBundleIdentifier")
  version=$(read_plist_key "$plist_path" "CFBundleShortVersionString")
  [[ -z "$version" ]] && version=$(read_plist_key "$plist_path" "CFBundleVersion")

  min_os=$(read_plist_key "$plist_path" "LSMinimumSystemVersion")
  app_exec=$(read_plist_key "$plist_path" "CFBundleExecutable")
  copyright_raw=$(read_plist_key "$plist_path" "NSHumanReadableCopyright")
  [[ -z "$copyright_raw" ]] && copyright_raw=$(read_plist_key "$plist_path" "CFBundleGetInfoString")
  publisher_default=$(derive_publisher_from_copyright "$copyright_raw")
  if [[ -z "$min_os" && -n "$app_exec" ]]; then
    bin_path="${app_path}/Contents/MacOS/${app_exec}"
    min_os=$(derive_min_os_from_binary "$bin_path")
  fi

  echo "Detected defaults:"
  echo "  App Name:    ${app_name:-<empty>}"
  echo "  Bundle ID:   ${bundle_id:-<empty>}"
  echo "  Version:     ${version:-<empty>}"
  echo "  Minimum OS:  ${min_os:-<empty>}"
  echo "  Publisher:   ${publisher_default:-<empty>}"
  echo ""

  echo "Choose action:"
  echo "  1) Create new software title + initial patch"
  echo "  2) Add/Update patch for existing title"
  echo ""

  local action
  action=$(prompt_required "Enter number")

  local dry_run_input dry_run_flag
  dry_run_input=$(prompt_default "Dry-run only? (yes/no)" "no")
  dry_run_flag="false"
  if is_yes "$dry_run_input"; then
    dry_run_flag="true"
  fi

  local cmd=(bash "$menu_script")

  if [[ "$action" == "1" ]]; then
    local title_name title_id publisher patch_version patch_min_os patch_bundle patch_app_name

    title_name=$(prompt_required "Title name" "$app_name")
    title_id=$(prompt_default "Title ID string (optional)" "")
    publisher=$(prompt_default "Publisher (optional)" "$publisher_default")

    patch_version=$(prompt_required "Initial patch version" "$version")
    patch_min_os=$(prompt_required "Initial patch minimum OS" "$min_os")
    patch_bundle=$(prompt_required "Initial patch bundle ID" "$bundle_id")
    patch_app_name=$(prompt_required "Initial patch app name" "$app_name")

    cmd+=(--create-title --title-name "$title_name" --version "$patch_version" --min-os "$patch_min_os" --bundle-id "$patch_bundle" --app-name "$patch_app_name" --yes)
    [[ -n "$title_id" ]] && cmd+=(--new-title-id "$title_id")
    [[ -n "$publisher" ]] && cmd+=(--publisher "$publisher")

  elif [[ "$action" == "2" ]]; then
    local target_mode target_value patch_version patch_min_os patch_bundle patch_app_name release_date

    target_mode=$(prompt_required "Target by (id/name)" "name")
    target_mode=$(printf '%s' "$target_mode" | tr '[:upper:]' '[:lower:]')

    if [[ "$target_mode" == "id" ]]; then
      target_value=$(prompt_required "Software title ID")
      cmd+=(--add-patch --title-id "$target_value")
    else
      target_value=$(prompt_required "Software title name" "$app_name")
      cmd+=(--add-patch --title-name "$target_value")
    fi

    patch_version=$(prompt_required "Patch version" "$version")
    patch_min_os=$(prompt_default "Patch minimum OS (optional)" "$min_os")
    patch_bundle=$(prompt_default "Patch bundle ID (optional)" "$bundle_id")
    patch_app_name=$(prompt_default "Patch app name (optional)" "$app_name")
    release_date=$(prompt_default "Release date UTC ISO8601 (optional)" "")

    cmd+=(--version "$patch_version" --yes)
    [[ -n "$patch_min_os" ]] && cmd+=(--min-os "$patch_min_os")
    [[ -n "$patch_bundle" ]] && cmd+=(--bundle-id "$patch_bundle")
    [[ -n "$patch_app_name" ]] && cmd+=(--app-name "$patch_app_name")
    [[ -n "$release_date" ]] && cmd+=(--release-date "$release_date")
  else
    echo "ERROR: Invalid action. Choose 1 or 2." >&2
    exit 1
  fi

  if [[ "$dry_run_flag" == "true" ]]; then
    cmd+=(--dry-run)
  fi

  echo ""
  echo "Command:"
  print_cmd "${cmd[@]}"
  echo ""

  local run_now
  run_now=$(prompt_default "Run this command now? (yes/no)" "yes")
  if ! is_yes "$run_now"; then
    echo "Cancelled."
    exit 0
  fi

  "${cmd[@]}"
}

main "$@"
