#!/usr/bin/env bash
#
# Build Title Editor Batch File from GitHub Repository
# Version: 1.8.5
# Revised: 2026.03.25
#
# Generates short-format batch file for title_editor_menu.sh --add-patch-batch.
# Output format:
#   title_name|version
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

set -euo pipefail

SCRIPT_VERSION="1.8.5"
DEBUG_MODE=false
INCLUDE_PRERELEASE=false
GITHUB_CONNECT_TIMEOUT="${GITHUB_CONNECT_TIMEOUT:-15}"
GITHUB_MAX_TIME="${GITHUB_MAX_TIME:-90}"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log_info() { echo -e "${BLUE}[INFO]${NC} $1" >&2; }
log_success() { echo -e "${GREEN}[SUCCESS]${NC} $1" >&2; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $1" >&2; }
log_error() { echo -e "${RED}[ERROR]${NC} $1" >&2; }
debug_log() {
  [[ "$DEBUG_MODE" == "true" ]] || return 0
  echo -e "${YELLOW}[DEBUG]${NC} $1" >&2
}

show_usage() {
  cat <<EOF
Build Title Editor Batch File from GitHub v${SCRIPT_VERSION}

Interactive mode:
  bash $(basename "$0")

Optional non-interactive flags:
  --repo <owner/repo|repo_url>
  --non-interactive
  --title-name <name>
  --publisher <publisher>
  --bundle-id <bundle_id>
  --app-name <app_name>
  --min-os <version>
  --output <path>
  --output-json <path>
  --json
  --template-json <path>
  --source <auto|releases|tags>
  --limit <count|all>
  --include-prerelease
  --debug
  --help

Notes:
  - Uses GitHub API releases first by default (auto), falls back to tags.
  - Prefers mac-only tags (versions starting with "mac-").
  - If no mac-prefixed tags exist, falls back to plain tag names.
  - By default excludes prerelease versions (GitHub Releases prerelease/draft tags, and beta/alpha/dev/rc style labels).
  - Use --include-prerelease to keep prerelease versions.
  - If selected versions are not numeric semantic versions (n.n or n.n.n...),
    interactive mode prompts to continue or abort.
  - Writes short-format batch file for Title Editor:
      title_name|version
  - JSON output always produces a Jamf Pro Title Editor-importable file.
    Interactive mode prompts for publisher, bundle ID, and app name if not supplied.
    Use --publisher, --bundle-id, --app-name to supply these non-interactively.
  - With --template-json, publisher/bundleId/appName are read from the template
    instead of being prompted (backwards compatible).
  - Set GH_TOKEN in env for higher GitHub API rate limits.
EOF
}

print_banner() {
  echo -e "${BLUE}================================================${NC}"
  echo -e "${BLUE}  Build Title Editor Batch from GitHub v${SCRIPT_VERSION}${NC}"
  echo -e "${BLUE}================================================${NC}"
  echo ""
}

require_command() {
  local cmd="$1"
  if ! command -v "$cmd" >/dev/null 2>&1; then
    log_error "Required command not found: $cmd"
    exit 1
  fi
}

trim() {
  local value="$1"
  value="${value#${value%%[![:space:]]*}}"
  value="${value%${value##*[![:space:]]}}"
  printf '%s' "$value"
}

default_json_output_file_for_title() {
  local directory="$1"
  local title_name="$2"
  local slug

  slug=$(echo "$title_name" | tr '[:upper:]' '[:lower:]' | sed -E 's/[^a-z0-9]+/_/g; s/^_+//; s/_+$//')
  [[ -z "$slug" ]] && slug="software"

  printf '%s/title_editor_batch_%s.json' "${directory%/}" "$slug"
}

json_array_length() {
  local json_file
  json_file=$(mktemp /tmp/title_editor_github_json_len.XXXXXX)
  cat > "$json_file"

  python3 - "$json_file" <<'PY'
import json
import sys

json_file = sys.argv[1]

try:
  with open(json_file, 'r', encoding='utf-8') as fh:
    raw = fh.read().strip()
except Exception:
  print(0)
  sys.exit(0)

if not raw:
  print(0)
  sys.exit(0)

try:
  data = json.loads(raw)
except Exception:
  print(0)
  sys.exit(0)

if isinstance(data, list):
  print(len(data))
else:
  print(0)
PY

  rm -f "$json_file" >/dev/null 2>&1 || true
}

fetch_versions_paginated() {
  local repo="$1"
  local endpoint="$2"
  local key="$3"

  local page=1
  local per_page=100
  local max_pages=50
  local all_versions=""

  while [[ "$page" -le "$max_pages" ]]; do
    local url
    url="https://api.github.com/repos/${repo}/${endpoint}?per_page=${per_page}&page=${page}"

    local page_json
    if ! page_json=$(github_get "$url"); then
      if [[ "$page" -eq 1 ]]; then
        return 1
      fi
      break
    fi

    local page_count
    page_count=$(printf '%s' "$page_json" | json_array_length)
    debug_log "${endpoint} page ${page}: items=${page_count} bytes=${#page_json}"

    [[ "$page_count" -eq 0 ]] && break

    local page_versions
    page_versions=$(printf '%s' "$page_json" | extract_versions_from_json "$key" "$endpoint" || true)
    if [[ -n "$page_versions" ]]; then
      if [[ -n "$all_versions" ]]; then
        all_versions+=$'\n'
      fi
      all_versions+="$page_versions"
    fi

    [[ "$page_count" -lt "$per_page" ]] && break
    ((page++))
  done

  if [[ -n "$all_versions" ]]; then
    printf '%s\n' "$all_versions" | awk 'NF && !seen[$0]++'
  fi
}

prompt_required() {
  local prompt="$1"
  local value
  read -r -p "$prompt" value
  value=$(trim "$value")
  if [[ -z "$value" ]]; then
    log_error "Value is required."
    exit 1
  fi
  printf '%s' "$value"
}

validate_repo() {
  local repo="$1"
  [[ "$repo" =~ ^[A-Za-z0-9._-]+/[A-Za-z0-9._-]+$ ]]
}

normalize_repo_input() {
  local input
  input=$(trim "$1")

  if [[ -z "$input" ]]; then
    printf '%s' ""
    return 0
  fi

  # Remove trailing slash
  input="${input%/}"

  # Drop query/fragment so URL path parsing is stable.
  input="${input%%\?*}"
  input="${input%%\#*}"

  # URL forms
  if [[ "$input" =~ ^https?://github\.com/ ]]; then
    input="${input#http://github.com/}"
    input="${input#https://github.com/}"
  elif [[ "$input" =~ ^github\.com/ ]]; then
    input="${input#github.com/}"
  elif [[ "$input" =~ ^git@github\.com: ]]; then
    input="${input#git@github.com:}"
  fi

  # Strip optional .git suffix
  input="${input%.git}"

  # Keep only owner/repo when full GitHub URLs include extra path segments
  # such as /releases, /tags, /tree/main, etc.
  if [[ "$input" == */* ]]; then
    local owner repo rest
    owner="${input%%/*}"
    rest="${input#*/}"
    repo="${rest%%/*}"
    if [[ -n "$owner" && -n "$repo" ]]; then
      input="${owner}/${repo}"
    fi
  fi

  printf '%s' "$input"
}

github_get() {
  local url="$1"
  if [[ -n "${GH_TOKEN:-}" ]]; then
    curl \
      --silent \
      --show-error \
      --fail \
      --location \
      --connect-timeout "${GITHUB_CONNECT_TIMEOUT}" \
      --max-time "${GITHUB_MAX_TIME}" \
      --header "Accept: application/vnd.github+json" \
      --header "X-GitHub-Api-Version: 2022-11-28" \
      --header "Authorization: Bearer ${GH_TOKEN}" \
      "$url"
  else
    curl \
      --silent \
      --show-error \
      --fail \
      --location \
      --connect-timeout "${GITHUB_CONNECT_TIMEOUT}" \
      --max-time "${GITHUB_MAX_TIME}" \
      --header "Accept: application/vnd.github+json" \
      --header "X-GitHub-Api-Version: 2022-11-28" \
      "$url"
  fi
}

extract_versions_from_json() {
  local key="$1"
  local source_kind="${2:-unknown}"
  local json_file
  json_file=$(mktemp /tmp/title_editor_github_json.XXXXXX)
  cat > "$json_file"

  python3 - "$key" "$source_kind" "$json_file" <<'PY'
import json
import sys

key = sys.argv[1]
source_kind = sys.argv[2]
json_file = sys.argv[3]

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

out = []
seen = set()

if isinstance(data, dict):
    data = [data]

for item in data:
    if not isinstance(item, dict):
        continue
    tag = str(item.get(key, "")).strip()
    if not tag:
        continue
    # Normalize common version prefixes safely.
    # - Strip v/V only when followed by a digit (e.g. v1.2.3 -> 1.2.3)
    # - Strip "version-" prefix (e.g. Version-3.14.1 -> 3.14.1)
    if re.match(r'^[vV]\d', tag):
        tag = tag[1:]
    tag = re.sub(r'^(?i:version)[\s._-]*', '', tag)
    tag = tag.strip()
    if not tag or tag in seen:
        continue
    seen.add(tag)
    prerelease = False
    if source_kind == "releases":
        prerelease = bool(item.get("prerelease", False) or item.get("draft", False))
    out.append((tag, prerelease))

for version, prerelease in out:
    print(f"{version}\t{1 if prerelease else 0}")
PY

  rm -f "$json_file" >/dev/null 2>&1 || true
}

fetch_versions_from_git_tags() {
  local repo="$1"
  command -v git >/dev/null 2>&1 || return 1

  GIT_TERMINAL_PROMPT=0 git \
    -c credential.helper= \
    -c core.askPass= \
    -c http.lowSpeedLimit=1 \
    -c http.lowSpeedTime=30 \
    ls-remote --tags "https://github.com/${repo}.git" 2>/dev/null \
    | awk '{print $2}' \
    | sed 's#refs/tags/##' \
    | sed 's/\^{}$//' \
    | sed '/^$/d' \
    | awk '!seen[$0]++' \
    | sed -E 's/^[vV]([0-9])/\1/'
}

filter_versions() {
  local include_prerelease="$1"
  local require_mac_prefix="$2"
  local versions_file
  versions_file=$(mktemp /tmp/title_editor_github_versions_filter.XXXXXX)
  cat > "$versions_file"

  python3 - "$include_prerelease" "$require_mac_prefix" "$versions_file" <<'PY'
import re
import sys

include_prerelease = (sys.argv[1].strip().lower() == "true")
require_mac_prefix = (sys.argv[2].strip().lower() == "true")
path = sys.argv[3]

try:
    with open(path, "r", encoding="utf-8", errors="replace") as fh:
        rows = [line.strip() for line in fh if line.strip()]
except Exception:
    rows = []

seen = set()
for raw in rows:
    if "\t" in raw:
        version, preflag = raw.split("\t", 1)
        gh_prerelease = (preflag.strip() == "1")
    else:
        version = raw
        gh_prerelease = False

    vlow = version.lower()

    if require_mac_prefix and not vlow.startswith("mac-"):
      continue

    if not include_prerelease:
        if gh_prerelease:
            continue
        # Exclude common prerelease tokens and shorthand forms.
        if (
            "alpha" in vlow
            or "beta" in vlow
            or "dev" in vlow
            or "rc" in vlow
            or re.search(r'\bb\d+\b', vlow)
            or re.search(r'\bd\d+\b', vlow)
            or re.search(r'\d+b\d+$', vlow)
            or re.search(r'\d+d\d+$', vlow)
        ):
            continue

    normalized = version[4:] if vlow.startswith("mac-") else version
    normalized = re.sub(r'^(?i:version)[\s._-]*', '', normalized).strip()
    if re.match(r'^[vV]\d', normalized):
        normalized = normalized[1:]

    match = re.search(r'([0-9]+(?:\.[0-9]+){1,3})', normalized)
    if not match:
        continue
    normalized = match.group(1)

    if normalized in seen:
        continue
    seen.add(normalized)
    print(normalized)
PY

  rm -f "$versions_file" >/dev/null 2>&1 || true
}

is_numeric_semver_like() {
  local version="$1"
  [[ "$version" =~ ^[0-9]+(\.[0-9]+){1,3}$ ]]
}

collect_non_semver_versions() {
  local out=""
  local v
  for v in "$@"; do
    if ! is_numeric_semver_like "$v"; then
      if [[ -n "$out" ]]; then
        out+=$'\n'
      fi
      out+="$v"
    fi
  done
  printf '%s' "$out"
}

confirm_continue_non_semver() {
  local non_semver_text="$1"

  log_warn "Found versions that do not look like numeric semantic versions:"
  printf '%s\n' "$non_semver_text" | awk '{print "  - " $0}'

  if [[ -r /dev/tty ]]; then
    local reply
    read -r -p "Continue anyway? [yes/no]: " reply < /dev/tty
    reply=$(trim "$reply")
    reply=$(printf '%s' "$reply" | tr '[:upper:]' '[:lower:]')
    [[ "$reply" == "yes" ]]
    return
  fi

  log_error "Non-interactive mode detected and non-semver versions were found."
  log_info "Tip: remove prerelease tags or run interactively and confirm continuation."
  return 1
}

generate_batch_file() {
  local title_name="$1"
  local output_file="$2"
  shift 2
  local versions=("$@")

  local safe_title
  safe_title="${title_name//|//}"

  {
    echo "title_name|version"
    local version
    for version in "${versions[@]}"; do
      echo "${safe_title}|${version}"
    done
  } > "$output_file"
}

fetch_repo_metadata() {
  local repo="$1"
  local owner="${repo%%/*}"

  local repo_json owner_json
  repo_json=$(github_get "https://api.github.com/repos/${repo}" 2>/dev/null || true)
  owner_json=$(github_get "https://api.github.com/orgs/${owner}" 2>/dev/null ||                github_get "https://api.github.com/users/${owner}" 2>/dev/null || true)

  python3 - "$repo_json" "$owner_json" <<'PY'
import json
import sys

repo_raw  = sys.argv[1].strip()
owner_raw = sys.argv[2].strip()

repo_data  = {}
owner_data = {}

try:
  repo_data = json.loads(repo_raw) if repo_raw else {}
except Exception:
  pass

try:
  owner_data = json.loads(owner_raw) if owner_raw else {}
except Exception:
  pass

# Publisher: prefer org/user display name, fall back to login
publisher = (
  str(owner_data.get("name") or "").strip()
  or str(owner_data.get("login") or "").strip()
  or str(repo_data.get("owner", {}).get("login") or "").strip()
)

# App name: repo description if short and clean, otherwise repo name
description = str(repo_data.get("description") or "").strip()
repo_name   = str(repo_data.get("name") or "").strip()
app_name = description if (description and len(description) <= 40 and "\n" not in description) else repo_name

print(f"{publisher}\t{app_name}")
PY
}

generate_jamf_import_json_file() {
  local title_name="$1"
  local publisher="$2"
  local bundle_id="$3"
  local app_name="$4"
  local min_os="$5"
  local output_file="$6"
  local source_ref="$7"
  shift 7
  local versions=("$@")

  python3 - "$title_name" "$publisher" "$bundle_id" "$app_name" "$min_os" "$source_ref" "$output_file" "${versions[@]}" <<'PY'
import datetime
import json
import pathlib
import re
import sys

title_name  = sys.argv[1]
publisher   = sys.argv[2]
bundle_id   = sys.argv[3]
app_name    = sys.argv[4]
min_os      = sys.argv[5] or "12.0"
source_ref  = sys.argv[6]
output_file = pathlib.Path(sys.argv[7])
versions    = sys.argv[8:]

if not versions:
  raise SystemExit("No versions to write")

# Generate a human-readable ID from the title name (e.g. "ThoriumReader")
def make_id(name):
  return re.sub(r"[^A-Za-z0-9]", "", name)

now_iso = datetime.datetime.now(datetime.timezone.utc).replace(microsecond=0).isoformat().replace("+00:00", "Z")

# appName should include .app suffix per Jamf convention
app_name_app = app_name if app_name.endswith(".app") else app_name + ".app"

def build_patch(version):
  return {
    "version": str(version),
    "releaseDate": now_iso,
    "standalone": True,
    "minimumOperatingSystem": min_os,
    "reboot": False,
    "killApps": [
      {"bundleId": bundle_id, "appName": app_name_app}
    ] if bundle_id else [],
    "components": [
      {
        "name": app_name,
        "version": str(version),
        "criteria": [
          {
            "and": True,
            "name": "Application Bundle ID",
            "operator": "is",
            "value": bundle_id,
            "type": "recon",
          },
          {
            "and": True,
            "name": "Application Version",
            "operator": "is",
            "value": str(version),
            "type": "recon",
          },
        ],
      }
    ] if bundle_id else [],
    "capabilities": [
      {
        "and": True,
        "name": "Operating System Version",
        "operator": "greater than or equal",
        "value": min_os,
        "type": "recon",
      }
    ],
  }

requirements = []
if bundle_id:
  requirements = [
    {
      "and": True,
      "name": "Application Bundle ID",
      "operator": "is",
      "value": bundle_id,
      "type": "recon",
    }
  ]

payload = {
  "name": title_name,
  "publisher": publisher,
  "appName": app_name_app,
  "bundleId": bundle_id,
  "lastModified": now_iso,
  "currentVersion": str(versions[0]),
  "id": make_id(title_name),
  "requirements": requirements,
  "patches": [build_patch(v) for v in versions],
}

output_file.write_text(json.dumps(payload, indent=2) + "\n", encoding="utf-8")
PY
}

generate_title_editor_import_json_file() {
  local title_name="$1"
  local output_file="$2"
  local source_ref="$3"
  local template_json_file="$4"
  shift 4
  local versions=("$@")

  python3 - "$title_name" "$source_ref" "$output_file" "$template_json_file" "${versions[@]}" <<'PY'
import copy
import datetime
import json
import pathlib
import sys

title_name = sys.argv[1]
source_ref = sys.argv[2]
output_file = pathlib.Path(sys.argv[3])
template_path = pathlib.Path(sys.argv[4])
versions = sys.argv[5:]

if not versions:
  raise SystemExit("No versions to write")

template = json.loads(template_path.read_text(encoding="utf-8"))
if not isinstance(template, dict):
  raise SystemExit("Template JSON must be an object")

template_patches = template.get("patches") or []
if not isinstance(template_patches, list) or not template_patches:
  raise SystemExit("Template JSON must contain at least one patch in 'patches'")

def strip_ids(obj):
  if isinstance(obj, dict):
    cleaned = {}
    for k, v in obj.items():
      key_l = str(k).lower()
      # Preserve keys that are meaningful identifiers in the output schema.
      if k in ("id", "bundleId", "trackId"):
        cleaned[k] = strip_ids(v)
        continue
      # Drop server-side IDs and timestamps that should not be re-imported.
      if k in ("softwareTitleId", "sourceId", "lastModified", "lastModifiedTest"):
        continue
      # Drop any remaining keys whose name ends with "id" (e.g. patchId, packageId).
      if key_l.endswith("id"):
        continue
      cleaned[k] = strip_ids(v)
    return cleaned
  if isinstance(obj, list):
    return [strip_ids(i) for i in obj]
  return obj

def pick_latest_patch(patches):
  sortable = []
  for idx, p in enumerate(patches):
    ao = p.get("absoluteOrderId")
    try:
      ao_i = int(ao)
    except Exception:
      ao_i = 10**9
    sortable.append((ao_i, idx, p))
  sortable.sort(key=lambda r: (r[0], r[1]))
  return sortable[0][2]

base_patch = strip_ids(pick_latest_patch(template_patches))
base_requirements = strip_ids(template.get("requirements") or [])

template_min_os = str(base_patch.get("minimumOperatingSystem") or "10.11")
template_standalone = bool(base_patch.get("standalone", True))
template_reboot = bool(base_patch.get("reboot", False))
template_components = base_patch.get("components") or []
template_kill_apps = base_patch.get("killApps") or []
template_capabilities = base_patch.get("capabilities") or []

if not isinstance(template_components, list):
  template_components = []
if not isinstance(template_kill_apps, list):
  template_kill_apps = []
if not isinstance(template_capabilities, list):
  template_capabilities = []

def build_patch(version, order_id):
  patch = {
    "absoluteOrderId": order_id,
    "enabled": True,
    "version": str(version),
    "releaseDate": datetime.datetime.now(datetime.timezone.utc).replace(microsecond=0).isoformat().replace("+00:00", "Z"),
    "standalone": template_standalone,
    "minimumOperatingSystem": template_min_os,
    "reboot": template_reboot,
    "killApps": copy.deepcopy(template_kill_apps),
    "components": copy.deepcopy(template_components),
    "capabilities": copy.deepcopy(template_capabilities),
  }

  for comp in patch.get("components", []):
    if isinstance(comp, dict):
      comp["version"] = str(version)
      criteria = comp.get("criteria") or []
      if isinstance(criteria, list):
        for criterion in criteria:
          if not isinstance(criterion, dict):
            continue
          name = str(criterion.get("name") or "").strip().lower()
          ctype = str(criterion.get("type") or "").strip().lower()
          if name == "application version" and ctype == "recon":
            criterion["value"] = str(version)
  return patch

payload = {
  "enabled": bool(template.get("enabled", True)),
  "name": title_name if title_name else str(template.get("name") or ""),
  "publisher": str(template.get("publisher") or ""),
  "appName": str(template.get("appName") or ""),
  "bundleId": str(template.get("bundleId") or ""),
  "currentVersion": str(versions[0]),
  "id": str(template.get("id") or ""),
  "type": str(template.get("type") or "default"),
  "requirements": base_requirements,
  "patches": [build_patch(v, i) for i, v in enumerate(versions)],
  "_meta": {
    "source": source_ref,
    "generated_at_utc": datetime.datetime.now(datetime.timezone.utc).replace(microsecond=0).isoformat().replace("+00:00", "Z"),
    "template_file": str(template_path),
    "count": len(versions),
  },
}

output_file.write_text(json.dumps(payload, indent=2) + "\n", encoding="utf-8")
PY
}

main() {
  require_command curl
  require_command python3

  local repo=""
  local title_name=""
  local output_file=""
  local output_json_file=""
  local write_json_companion=false
  local template_json_file=""
  local publisher=""
  local bundle_id=""
  local app_name=""
  local min_os=""
  local create_batch_output=true
  local create_json_output=false
  local source_mode="auto"
  local limit="all"
  local non_interactive=false

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --repo)
        repo="${2:-}"
        shift 2
        ;;
      --non-interactive)
        non_interactive=true
        shift
        ;;
      --title-name)
        title_name="${2:-}"
        shift 2
        ;;
      --output)
        output_file="${2:-}"
        shift 2
        ;;
      --output-json)
        output_json_file="${2:-}"
        shift 2
        ;;
      --json)
        write_json_companion=true
        shift
        ;;
      --template-json)
        template_json_file="${2:-}"
        shift 2
        ;;
      --publisher)
        publisher="${2:-}"
        shift 2
        ;;
      --bundle-id)
        bundle_id="${2:-}"
        shift 2
        ;;
      --app-name)
        app_name="${2:-}"
        shift 2
        ;;
      --min-os)
        min_os="${2:-}"
        shift 2
        ;;
      --source)
        source_mode="${2:-}"
        shift 2
        ;;
      --limit)
        limit="${2:-}"
        shift 2
        ;;
      --include-prerelease)
        INCLUDE_PRERELEASE=true
        shift
        ;;
      --help|-h)
        show_usage
        exit 0
        ;;
      --debug|-d)
        DEBUG_MODE=true
        shift
        ;;
      *)
        log_error "Unknown argument: $1"
        show_usage
        exit 1
        ;;
    esac
  done

  print_banner

  if [[ -z "$repo" ]]; then
    repo=$(prompt_required "GitHub repository (owner/repo or GitHub URL): ")
  fi
  repo=$(normalize_repo_input "$repo")
  debug_log "Normalized repository input: ${repo}"
  if ! validate_repo "$repo"; then
    log_error "Invalid repository format. Expected owner/repo or GitHub URL"
    exit 1
  fi

  local default_title default_output
  default_title="${repo##*/}"
  default_output="${PWD}/title_editor_batch_${default_title}.txt"
  local default_json_output
  default_json_output="${PWD}/title_editor_batch_${default_title}.json"

  if [[ -z "$title_name" ]]; then
    read -r -p "Title name for batch rows [${default_title}]: " title_name
    title_name=$(trim "$title_name")
    [[ -z "$title_name" ]] && title_name="$default_title"
  fi

  if [[ -z "$output_json_file" && "$write_json_companion" != "true" && -z "$template_json_file" && -r /dev/tty && "$non_interactive" != "true" ]]; then
    echo ""
    echo "Select output mode:"
    echo "  1) API Batch Import (.txt)"
    echo "  2) JSON file (.json)"
    echo "  3) Both (.txt + .json)"
    local output_mode_choice
    read -r -p "Enter number [1]: " output_mode_choice < /dev/tty
    output_mode_choice=$(trim "$output_mode_choice")
    [[ -z "$output_mode_choice" ]] && output_mode_choice="1"

    case "$output_mode_choice" in
      1)
        create_batch_output=true
        create_json_output=false
        ;;
      2)
        create_batch_output=false
        create_json_output=true
        ;;
      3)
        create_batch_output=true
        create_json_output=true
        write_json_companion=true
        ;;
      *)
        log_warn "Invalid output mode selection '${output_mode_choice}'. Using API Batch Import (.txt)."
        create_batch_output=true
        create_json_output=false
        ;;
    esac
  fi

  if [[ -n "$output_json_file" || "$write_json_companion" == "true" || -n "$template_json_file" ]]; then
    create_json_output=true
  fi

  # Prompt for Jamf-required fields when producing JSON without a template
  if [[ "$create_json_output" == "true" && -z "$template_json_file" ]]; then
    # Fetch publisher and app name suggestions from GitHub
    local gh_publisher="" gh_app_name=""
    local meta_line
    if meta_line=$(fetch_repo_metadata "$repo" 2>/dev/null) && [[ -n "$meta_line" ]]; then
      gh_publisher="${meta_line%%$'\t'*}"
      gh_app_name="${meta_line##*$'\t'}"
      debug_log "GitHub metadata: publisher=${gh_publisher} app_name=${gh_app_name}"
    fi

    if [[ -r /dev/tty ]]; then
      echo ""
      log_info "JSON output requires a few fields for Jamf Pro import."
      if [[ -z "$publisher" ]]; then
        local publisher_prompt="Publisher"
        [[ -n "$gh_publisher" ]] && publisher_prompt="Publisher [${gh_publisher}]"
        read -r -p "${publisher_prompt}: " publisher < /dev/tty
        publisher=$(trim "$publisher")
        [[ -z "$publisher" && -n "$gh_publisher" ]] && publisher="$gh_publisher"
      fi
      if [[ -z "$bundle_id" ]]; then
        read -r -p "Bundle ID (e.g. org.edrlab.thorium, leave blank to skip): " bundle_id < /dev/tty
        bundle_id=$(trim "$bundle_id")
      fi
      if [[ -z "$app_name" ]]; then
        local app_name_default="${gh_app_name:-${title_name}}"
        read -r -p "App name [${app_name_default}]: " app_name < /dev/tty
        app_name=$(trim "$app_name")
        [[ -z "$app_name" ]] && app_name="$app_name_default"
      fi
      if [[ -z "$min_os" ]]; then
        read -r -p "Minimum macOS version [12.0]: " min_os < /dev/tty
        min_os=$(trim "$min_os")
        [[ -z "$min_os" ]] && min_os="12.0"
      fi
    else
      # Non-interactive: use GitHub-fetched values as fallback
      [[ -z "$publisher" && -n "$gh_publisher" ]] && publisher="$gh_publisher"
      [[ -z "$app_name"  && -n "$gh_app_name"  ]] && app_name="$gh_app_name"
      [[ -z "$app_name"  ]] && app_name="$title_name"
      [[ -z "$min_os"    ]] && min_os="12.0"
    fi
  fi

  if [[ "$create_batch_output" == "true" && -z "$output_file" ]]; then
    read -r -p "Output file path [${default_output}]: " output_file
    output_file=$(trim "$output_file")
    [[ -z "$output_file" ]] && output_file="$default_output"
  fi

  if [[ "$create_batch_output" == "true" && -d "$output_file" ]]; then
    output_file="${output_file%/}/title_editor_batch_${default_title}.txt"
    log_info "Output path is a directory; using file: ${output_file}"
  fi

  if [[ "$create_json_output" == "true" && "$write_json_companion" == "true" && -z "$output_json_file" ]]; then
    if [[ "$output_file" == *.txt ]]; then
      output_json_file="${output_file%.txt}.json"
    else
      output_json_file="${output_file}.json"
    fi
  fi

  if [[ "$create_json_output" == "true" && -z "$output_json_file" ]]; then
    if [[ -r /dev/tty ]]; then
      read -r -p "Output JSON file path [${default_json_output}]: " output_json_file < /dev/tty
      output_json_file=$(trim "$output_json_file")
      [[ -z "$output_json_file" ]] && output_json_file="$default_json_output"
    else
      output_json_file="$default_json_output"
    fi
  fi

  if [[ -n "$output_json_file" && -d "$output_json_file" ]]; then
    output_json_file=$(default_json_output_file_for_title "$output_json_file" "$title_name")
    log_info "JSON output path is a directory; using file: ${output_json_file}"
  fi

  if [[ -n "$template_json_file" && ! -f "$template_json_file" ]]; then
    log_error "--template-json file not found: ${template_json_file}"
    exit 1
  fi

  if [[ -z "${limit// }" ]]; then
    limit="all"
  fi
  local limit_all=false
  if [[ "$limit" == "all" || "$limit" == "ALL" || "$limit" == "0" ]]; then
    limit_all=true
  elif ! [[ "$limit" =~ ^[0-9]+$ ]] || [[ "$limit" -eq 0 ]]; then
    log_error "--limit must be a positive integer, 0, or all"
    exit 1
  fi

  case "$source_mode" in
    auto|releases|tags) ;;
    *)
      log_error "--source must be one of: auto, releases, tags"
      exit 1
      ;;
  esac

  log_info "Repository: ${repo}"
  log_info "Title name: ${title_name}"
  log_info "Source mode: ${source_mode}"
  if [[ "$INCLUDE_PRERELEASE" == "true" ]]; then
    log_info "Prerelease filter: included"
  else
    log_info "Prerelease filter: excluded (default)"
  fi
  if [[ "$limit_all" == "true" ]]; then
    log_info "Limit: all"
  else
    log_info "Limit: ${limit}"
  fi

  local versions_text=""
  local err_file
  err_file=$(mktemp /tmp/title_editor_github_fetch.XXXXXX)

  if [[ "$source_mode" == "releases" || "$source_mode" == "auto" ]]; then
    log_info "Fetching GitHub releases..."
    : > "$err_file"
    if versions_text=$(fetch_versions_paginated "$repo" "releases" "tag_name" 2>"$err_file"); then
      if [[ -z "$versions_text" ]]; then
        debug_log "releases contained no usable versions"
      fi
    else
      log_warn "Could not fetch releases for ${repo}."
      if [[ -s "$err_file" ]]; then
        while IFS= read -r line; do
          debug_log "releases: $line"
        done < "$err_file"
      fi
    fi
  fi

  if [[ -z "$versions_text" && ( "$source_mode" == "tags" || "$source_mode" == "auto" ) ]]; then
    log_info "Fetching GitHub tags..."
    : > "$err_file"
    if versions_text=$(fetch_versions_paginated "$repo" "tags" "name" 2>"$err_file"); then
      if [[ -z "$versions_text" ]]; then
        debug_log "tags contained no usable versions"
      fi
    else
      log_warn "Could not fetch tags for ${repo}."
      if [[ -s "$err_file" ]]; then
        while IFS= read -r line; do
          debug_log "tags: $line"
        done < "$err_file"
      fi
    fi
  fi

  if [[ -z "$versions_text" ]]; then
    log_info "Falling back to git tag discovery..."
    if versions_text=$(fetch_versions_from_git_tags "$repo" || true); then
      if [[ -n "$versions_text" ]]; then
        debug_log "git tags produced usable versions"
      else
        debug_log "git tags returned no versions"
      fi
    fi
  fi

  rm -f "$err_file" >/dev/null 2>&1 || true

  if [[ -z "$versions_text" ]]; then
    log_error "No versions found from releases/tags for ${repo}."
    log_info "Tip: check repo visibility, name, or set GH_TOKEN for private repos/rate limits."
    exit 1
  fi

  local has_mac_prefix="false"
  if printf '%s\n' "$versions_text" | awk -F'\t' '{print tolower($1)}' | grep -q '^mac-'; then
    has_mac_prefix="true"
    log_info "Tag filter: using mac-prefixed tags."
  else
    log_warn "Tag filter: no mac-prefixed tags found; falling back to plain tags."
  fi

  local raw_versions_text="$versions_text"
  versions_text=$(printf '%s\n' "$raw_versions_text" | filter_versions "$INCLUDE_PRERELEASE" "$has_mac_prefix" || true)

  # Some repositories include mac-* tags that are not version-bearing markers
  # (for example mac-fixed). If mac-only filtering produces no versions, fall
  # back to plain tag filtering instead of failing hard.
  if [[ "$has_mac_prefix" == "true" && -z "$versions_text" ]]; then
    log_warn "Tag filter: mac-prefixed tags yielded no usable versions; retrying with plain tags."
    versions_text=$(printf '%s\n' "$raw_versions_text" | filter_versions "$INCLUDE_PRERELEASE" "false" || true)
  fi

  local versions=()
  while IFS= read -r v; do
    [[ -n "$v" ]] && versions+=("$v")
  done <<< "$versions_text"

  local total_found="${#versions[@]}"
  if [[ "$limit_all" != "true" && "${#versions[@]}" -gt "$limit" ]]; then
    versions=("${versions[@]:0:$limit}")
    log_info "Truncated versions to ${#versions[@]} due to --limit ${limit} (found ${total_found})."
  fi

  if [[ "${#versions[@]}" -eq 0 ]]; then
    log_error "No usable versions found after filtering."
    log_info "Tip: pass --include-prerelease if this repository only uses beta/alpha/dev tags."
    exit 1
  fi

  local non_semver_versions
  non_semver_versions=$(collect_non_semver_versions "${versions[@]}" || true)
  if [[ -n "$non_semver_versions" ]]; then
    if ! confirm_continue_non_semver "$non_semver_versions"; then
      log_error "Aborted due to non-semver versions."
      exit 1
    fi
  fi

  if [[ "$create_batch_output" == "true" ]]; then
    mkdir -p "$(dirname "$output_file")"
    generate_batch_file "$title_name" "$output_file" "${versions[@]}"
  fi

  if [[ "$create_json_output" == "true" && -n "$output_json_file" ]]; then
    mkdir -p "$(dirname "$output_json_file")"
    if [[ -n "$template_json_file" ]]; then
      generate_title_editor_import_json_file "$title_name" "$output_json_file" "github:${repo}" "$template_json_file" "${versions[@]}"
    else
      generate_jamf_import_json_file "$title_name" "$publisher" "$bundle_id" "$app_name" "$min_os" "$output_json_file" "github:${repo}" "${versions[@]}"
    fi
  fi

  if [[ "$create_batch_output" == "true" ]]; then
    log_success "Batch file created: ${output_file}"
  fi
  if [[ "$create_json_output" == "true" && -n "$output_json_file" ]]; then
    log_success "JSON file created: ${output_json_file}"
  fi
  log_info "Rows written: ${#versions[@]}"
  if [[ "$create_batch_output" == "true" ]]; then
    log_info "Use with:"
    log_info "  bash title_editor_menu.sh --add-patch-batch --file ${output_file} --yes"
  fi
  if [[ "$create_json_output" == "true" && -n "$output_json_file" ]]; then
    if [[ -n "$template_json_file" ]]; then
      log_info "JSON mode: Title Editor template-based import structure (template: ${template_json_file})"
    else
      log_info "JSON mode: Jamf Pro Title Editor importable structure"
    fi
  fi
}

main "$@"
