#!/usr/bin/env bash
#
# Build Title Editor Batch File from Jamf Patch Sources
# Version: 1.1.0
# Revised: 2026.03.25
#
# Generates short-format batch file for title_editor_menu.sh --add-patch-batch.
# Output format:
#   title_name|version
#
# Sources:
# - public   : Jamf public patch catalog
# - jamf-pro : Your Jamf Pro patch title API (/JSSResource/patchsoftwaretitles)
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

SCRIPT_VERSION="1.1.0"
DEBUG_MODE=false

SOURCE_MODE="public"
PUBLIC_CATALOG_URL_DEFAULT="https://jamf-patch.jamfcloud.com/v1/software"
PUBLIC_CATALOG_URL="$PUBLIC_CATALOG_URL_DEFAULT"
CATALOG_FILE=""

JAMF_PRO_URL="${JAMF_PRO_URL:-}"
JAMF_CLIENT_ID="${JAMF_CLIENT_ID:-}"
JAMF_CLIENT_SECRET="${JAMF_CLIENT_SECRET:-}"
JAMF_PATCH_TITLE_ID=""

KEYCHAIN_SERVICE="JamfProAPI"
KEYCHAIN_ACCOUNT_URL="jamf_pro_url"
KEYCHAIN_ACCOUNT_CLIENT_ID="jamf_client_id"
KEYCHAIN_ACCOUNT_CLIENT_SECRET="jamf_client_secret"

SOFTWARE_NAME=""
TITLE_NAME=""
OUTPUT_FILE=""
OUTPUT_JSON_FILE=""
WRITE_JSON=false
PUBLISHER=""
BUNDLE_ID=""
APP_NAME=""
MIN_OS="12.0"
LIMIT="all"
NON_INTERACTIVE=false

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log_info() { echo -e "${BLUE}[INFO]${NC} $1"; }
log_success() { echo -e "${GREEN}[SUCCESS]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1" >&2; }
debug_log() {
  [[ "$DEBUG_MODE" == "true" ]] || return 0
  echo -e "${YELLOW}[DEBUG]${NC} $1"
}

show_usage() {
  cat <<EOF_USAGE
Build Title Editor Batch File from Jamf Patch Sources v${SCRIPT_VERSION}

Usage:
  bash $(basename "$0") [options]

Core options:
  --source <public|jamf-pro>      Data source (default: public)
  --software-name <name>          Software name match (required unless --jamf-pro-title-id used)
  --title-name <name>             Title name written to batch rows (defaults to discovered name)
  --output <path>                 Output batch file path
  --output-json <path>            Output Jamf Pro import JSON file
  --json                          Also write JSON output (auto path if --output-json not provided)
  --publisher <name>              Publisher for JSON output
  --bundle-id <id>                Bundle ID for JSON output
  --app-name <name>               App name for JSON output (defaults to title name)
  --min-os <version>              Minimum macOS version for JSON output (default: 12.0)
  --limit <count|all>             Versions to include (default: all)
  --non-interactive               Fail instead of prompting

Public source options:
  --catalog-url <url>             Public catalog URL (default: ${PUBLIC_CATALOG_URL_DEFAULT})
  --catalog-file <path>           Read public catalog JSON from local file

Jamf Pro source options:
  --jamf-pro-title-id <id>        Patch title ID (skips title lookup)
  --jamf-pro-url <url>            Jamf Pro URL (can also come from keychain/env)
  --jamf-client-id <id>           API client ID (can also come from keychain/env)
  --jamf-client-secret <secret>   API client secret (can also come from keychain/env)

Examples:
  bash $(basename "$0") --source jamf-pro --jamf-pro-title-id 501 --title-name Opera --limit all --output /tmp/opera.txt
  bash $(basename "$0") --source public --software-name "Opera (Jamf)" --title-name Opera --limit all --output /tmp/opera.txt
EOF_USAGE
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

default_output_file_for_title() {
  local directory="$1"
  local title_name="$2"
  local slug

  slug=$(echo "$title_name" | tr '[:upper:]' '[:lower:]' | sed -E 's/[^a-z0-9]+/_/g; s/^_+//; s/_+$//')
  [[ -z "$slug" ]] && slug="software"

  printf '%s/title_editor_batch_%s.txt' "${directory%/}" "$slug"
}

default_json_output_file_for_title() {
  local directory="$1"
  local title_name="$2"
  local slug

  slug=$(echo "$title_name" | tr '[:upper:]' '[:lower:]' | sed -E 's/[^a-z0-9]+/_/g; s/^_+//; s/_+$//')
  [[ -z "$slug" ]] && slug="software"

  printf '%s/title_editor_batch_%s.json' "${directory%/}" "$slug"
}

keychain_get() {
  local account="$1"
  security find-generic-password -s "$KEYCHAIN_SERVICE" -a "$account" -w 2>/dev/null || true
}

load_jamf_pro_credentials() {
  [[ -n "$JAMF_PRO_URL" ]] || JAMF_PRO_URL="$(keychain_get "$KEYCHAIN_ACCOUNT_URL")"
  [[ -n "$JAMF_CLIENT_ID" ]] || JAMF_CLIENT_ID="$(keychain_get "$KEYCHAIN_ACCOUNT_CLIENT_ID")"
  [[ -n "$JAMF_CLIENT_SECRET" ]] || JAMF_CLIENT_SECRET="$(keychain_get "$KEYCHAIN_ACCOUNT_CLIENT_SECRET")"

  [[ -n "$JAMF_PRO_URL" && -n "$JAMF_CLIENT_ID" && -n "$JAMF_CLIENT_SECRET" ]] || {
    log_error "Jamf Pro credentials missing. Provide args/env or run setup_jamf_pro_credentials.sh"
    return 1
  }

  JAMF_PRO_URL="${JAMF_PRO_URL%/}"
}

fetch_public_catalog_json() {
  if [[ -n "$CATALOG_FILE" ]]; then
    [[ -f "$CATALOG_FILE" ]] || {
      log_error "Catalog file not found: $CATALOG_FILE"
      return 1
    }
    cat "$CATALOG_FILE"
    return 0
  fi

  curl --silent --show-error --fail --location --max-time 90 --connect-timeout 20 "$PUBLIC_CATALOG_URL"
}

extract_versions_from_public_catalog() {
  local software_name="$1"
  local json_file="$2"

  python3 - "$software_name" "$json_file" <<'PY'
import json
import re
import sys

software_name = sys.argv[1].strip().lower()
json_file = sys.argv[2]

with open(json_file, "r", encoding="utf-8") as fh:
    data = json.load(fh)

if isinstance(data, dict):
    if isinstance(data.get("software"), list):
        items = data["software"]
    elif isinstance(data.get("results"), list):
        items = data["results"]
    else:
        items = [data]
elif isinstance(data, list):
    items = data
else:
    items = []

def get_name(item):
    for key in ("name", "title", "softwareTitle", "displayName"):
        v = item.get(key)
        if isinstance(v, str) and v.strip():
            return v.strip()
    return ""

def get_versions(item):
    versions = []

    def push(v):
        if isinstance(v, str):
            s = v.strip()
            if s:
                versions.append(s)

    for key in ("versions", "software_versions", "patches", "history"):
        arr = item.get(key)
        if not isinstance(arr, list):
            continue
        for entry in arr:
            if isinstance(entry, str):
                push(entry)
            elif isinstance(entry, dict):
                for vk in ("version", "softwareVersion", "software_version", "name"):
                    if vk in entry:
                        push(entry.get(vk))
                        break

    for key in ("currentVersion", "latestVersion", "version"):
        if key in item:
            push(item.get(key))

    dedup = []
    seen = set()
    for v in versions:
        if v not in seen:
            seen.add(v)
            dedup.append(v)
    return dedup

def normalize_name(n):
    return re.sub(r"\s+", " ", n or "").strip().lower()

candidates = []
for item in items:
    if not isinstance(item, dict):
        continue
    n = get_name(item)
    if not n:
        continue
    n_norm = normalize_name(n)
    if n_norm == software_name:
        candidates.append((0, n, item))
    elif software_name in n_norm or n_norm in software_name:
        candidates.append((1, n, item))

if not candidates:
    sys.exit(2)

candidates.sort(key=lambda t: (t[0], t[1].lower()))
selected_name = candidates[0][1]
selected_item = candidates[0][2]
versions = get_versions(selected_item)

if not versions:
    sys.exit(3)

chunk_re = re.compile(r"\d+|[A-Za-z]+")
def key(v):
    parts = []
    for p in chunk_re.findall(v):
        if p.isdigit():
            parts.append((0, int(p)))
        else:
            parts.append((1, p.lower()))
    return parts

versions = sorted(set(versions), key=key, reverse=True)
print(f"TITLE\t{selected_name}")
for v in versions:
    print(f"VERSION\t{v}")
PY
}

get_jamf_oauth_token() {
  local token_json token

  token_json=$(curl \
    --silent \
    --show-error \
    --fail \
    --location \
    --request POST \
    --header 'Content-Type: application/x-www-form-urlencoded' \
    --data-urlencode "client_id=${JAMF_CLIENT_ID}" \
    --data-urlencode "grant_type=client_credentials" \
    --data-urlencode "client_secret=${JAMF_CLIENT_SECRET}" \
    "${JAMF_PRO_URL}/api/oauth/token")

  token=$(python3 - <<'PY' "$token_json"
import json
import sys
obj = json.loads(sys.argv[1])
print(obj.get("access_token", ""))
PY
)

  [[ -n "$token" ]] || {
    log_error "Unable to obtain Jamf OAuth access token"
    return 1
  }

  printf '%s' "$token"
}

fetch_jamf_patch_title_xml_by_id() {
  local token="$1"
  local title_id="$2"
  local url="${JAMF_PRO_URL}/JSSResource/patchsoftwaretitles/id/${title_id}"
  local body http_code
  body=$(mktemp /tmp/jamf_patch_title_xml.XXXXXX)

  http_code=$(curl \
    --silent \
    --show-error \
    --location \
    --output "$body" \
    --write-out '%{http_code}' \
    --header "Authorization: Bearer ${token}" \
    --header 'Accept: application/xml' \
    "$url" || true)

  if [[ "$http_code" == "200" ]]; then
    cat "$body"
    rm -f "$body" >/dev/null 2>&1 || true
    return 0
  fi

  if [[ "$http_code" == "401" || "$http_code" == "403" ]]; then
    rm -f "$body" >/dev/null 2>&1 || true
    log_error "Jamf Pro denied access to patch title ID ${title_id} (HTTP ${http_code})."
    log_error "Check API client role permissions for Patch Management read access."
    return 41
  fi

  rm -f "$body" >/dev/null 2>&1 || true
  log_error "Failed to fetch Jamf patch title id ${title_id} (HTTP ${http_code:-unknown})."
  return 1
}

lookup_jamf_patch_title_id_by_name() {
  local token="$1"
  local software_name="$2"
  local list_xml body http_code
  local url="${JAMF_PRO_URL}/JSSResource/patchsoftwaretitles"
  body=$(mktemp /tmp/jamf_patch_titles.XXXXXX)

  http_code=$(curl \
    --silent \
    --show-error \
    --location \
    --output "$body" \
    --write-out '%{http_code}' \
    --header "Authorization: Bearer ${token}" \
    --header 'Accept: application/xml' \
    "$url" || true)

  if [[ "$http_code" == "401" || "$http_code" == "403" ]]; then
    rm -f "$body" >/dev/null 2>&1 || true
    log_error "Jamf Pro denied patch title list access (HTTP ${http_code})."
    log_error "Suggestion: rerun with --jamf-pro-title-id <id> (for example, --jamf-pro-title-id 501)."
    log_error "Also verify API client role permissions for Patch Management read access."
    return 41
  fi

  if [[ "$http_code" != "200" ]]; then
    rm -f "$body" >/dev/null 2>&1 || true
    log_error "Failed to list Jamf patch titles (HTTP ${http_code:-unknown})."
    return 1
  fi

  list_xml="$(cat "$body")"
  rm -f "$body" >/dev/null 2>&1 || true

  python3 - "$software_name" <<'PY' "$list_xml"
import re
import sys
import xml.etree.ElementTree as ET

needle = (sys.argv[1] or "").strip().lower()
xml_text = sys.stdin.read() if len(sys.argv) < 3 else sys.argv[2]

try:
    root = ET.fromstring(xml_text)
except Exception:
    sys.exit(2)

candidates = []
for item in root.findall('.//patch_software_title'):
    i = (item.findtext('id') or '').strip()
    n = (item.findtext('name') or '').strip()
    if not i or not n:
        continue
    n_norm = re.sub(r'\s+', ' ', n).strip().lower()
    if n_norm == needle:
        candidates.append((0, i, n))
    elif needle in n_norm or n_norm in needle:
        candidates.append((1, i, n))

if not candidates:
    sys.exit(1)

candidates.sort(key=lambda x: (x[0], x[2].lower()))
print(candidates[0][1])
PY
}

extract_versions_from_jamf_patch_xml() {
  local xml_file="$1"

  python3 - "$xml_file" <<'PY'
import re
import sys
import xml.etree.ElementTree as ET

xml_file = sys.argv[1]
root = ET.parse(xml_file).getroot()

title = (root.findtext('.//name') or 'Software Title').strip()
title = re.sub(r'\s*\(Jamf\)\s*$', '', title, flags=re.I).strip()

versions = []
seen = set()
for node in root.findall('.//software_version'):
    v = (node.text or '').strip()
    if v and v not in seen:
        seen.add(v)
        versions.append(v)

if not versions:
    sys.exit(3)

# Sort descending semantic-like
chunk_re = re.compile(r"\d+|[A-Za-z]+")
def key(v):
    out = []
    for p in chunk_re.findall(v):
        if p.isdigit():
            out.append((0, int(p)))
        else:
            out.append((1, p.lower()))
    return out

versions = sorted(versions, key=key, reverse=True)
print(f"TITLE\t{title}")
for v in versions:
    print(f"VERSION\t{v}")
PY
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

def make_id(name):
  return re.sub(r"[^A-Za-z0-9]", "", name)

now_iso = datetime.datetime.now(datetime.timezone.utc).replace(microsecond=0).isoformat().replace("+00:00", "Z")

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
  "_source": source_ref,
}

output_file.write_text(json.dumps(payload, indent=2) + "\n", encoding="utf-8")
PY
}

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --source)
        SOURCE_MODE="${2:-}"
        shift 2
        ;;
      --software-name)
        SOFTWARE_NAME="${2:-}"
        shift 2
        ;;
      --title-name)
        TITLE_NAME="${2:-}"
        shift 2
        ;;
      --catalog-url)
        PUBLIC_CATALOG_URL="${2:-}"
        shift 2
        ;;
      --catalog-file)
        CATALOG_FILE="${2:-}"
        shift 2
        ;;
      --jamf-pro-title-id)
        JAMF_PATCH_TITLE_ID="${2:-}"
        shift 2
        ;;
      --jamf-pro-url)
        JAMF_PRO_URL="${2:-}"
        shift 2
        ;;
      --jamf-client-id)
        JAMF_CLIENT_ID="${2:-}"
        shift 2
        ;;
      --jamf-client-secret)
        JAMF_CLIENT_SECRET="${2:-}"
        shift 2
        ;;
      --output)
        OUTPUT_FILE="${2:-}"
        shift 2
        ;;
      --output-json)
        OUTPUT_JSON_FILE="${2:-}"
        WRITE_JSON=true
        shift 2
        ;;
      --json)
        WRITE_JSON=true
        shift
        ;;
      --publisher)
        PUBLISHER="${2:-}"
        shift 2
        ;;
      --bundle-id)
        BUNDLE_ID="${2:-}"
        shift 2
        ;;
      --app-name)
        APP_NAME="${2:-}"
        shift 2
        ;;
      --min-os)
        MIN_OS="${2:-}"
        shift 2
        ;;
      --limit)
        LIMIT="${2:-}"
        shift 2
        ;;
      --non-interactive)
        NON_INTERACTIVE=true
        shift
        ;;
      --debug|-d)
        DEBUG_MODE=true
        shift
        ;;
      --help|-h)
        show_usage
        exit 0
        ;;
      *)
        log_error "Unknown argument: $1"
        show_usage
        exit 1
        ;;
    esac
  done
}

PARSED_TITLE=""
PARSED_VERSIONS=()
collect_title_and_versions() {
  local parse_file="$1"
  PARSED_TITLE=""
  PARSED_VERSIONS=()

  local kind value
  while IFS=$'\t' read -r kind value; do
    case "$kind" in
      TITLE)
        PARSED_TITLE="$value"
        ;;
      VERSION)
        [[ -n "$value" ]] && PARSED_VERSIONS+=("$value")
        ;;
    esac
  done < "$parse_file"
}

main() {
  require_command curl
  require_command python3
  parse_args "$@"

  case "$SOURCE_MODE" in
    public|jamf-pro) ;;
    *)
      log_error "--source must be one of: public|jamf-pro"
      exit 1
      ;;
  esac

  if [[ -z "${LIMIT// }" ]]; then
    LIMIT="all"
  fi

  local limit_all=false
  if [[ "$LIMIT" == "all" || "$LIMIT" == "ALL" || "$LIMIT" == "0" ]]; then
    limit_all=true
  elif ! [[ "$LIMIT" =~ ^[0-9]+$ ]] || [[ "$LIMIT" -eq 0 ]]; then
    log_error "--limit must be a positive integer, 0, or all"
    exit 1
  fi

  local parse_file
  parse_file=$(mktemp /tmp/title_editor_jamf_patch_parse.XXXXXX)

  if [[ "$SOURCE_MODE" == "public" ]]; then
    [[ -n "$SOFTWARE_NAME" ]] || {
      log_error "--software-name is required for --source public"
      exit 1
    }

    local tmp_json
    tmp_json=$(mktemp /tmp/title_editor_jamf_patch_catalog.XXXXXX)

    log_info "Fetching Jamf public patch catalog..."
    if ! fetch_public_catalog_json > "$tmp_json"; then
      rm -f "$tmp_json" "$parse_file" >/dev/null 2>&1 || true
      log_error "Failed to fetch catalog from: ${CATALOG_FILE:-$PUBLIC_CATALOG_URL}"
      exit 1
    fi

    if ! extract_versions_from_public_catalog "$SOFTWARE_NAME" "$tmp_json" > "$parse_file"; then
      local rc=$?
      rm -f "$tmp_json" "$parse_file" >/dev/null 2>&1 || true
      if [[ "$rc" -eq 2 ]]; then
        log_error "Software not found in public catalog: $SOFTWARE_NAME"
      elif [[ "$rc" -eq 3 ]]; then
        log_error "No versions found in public catalog: $SOFTWARE_NAME"
      else
        log_error "Failed parsing public catalog data for: $SOFTWARE_NAME"
      fi
      exit 1
    fi

    rm -f "$tmp_json" >/dev/null 2>&1 || true
  else
    load_jamf_pro_credentials

    local token
    log_info "Requesting Jamf Pro OAuth token..."
    token="$(get_jamf_oauth_token)"

    if [[ -z "$JAMF_PATCH_TITLE_ID" ]]; then
      [[ -n "$SOFTWARE_NAME" ]] || {
        rm -f "$parse_file" >/dev/null 2>&1 || true
        log_error "For --source jamf-pro, provide --jamf-pro-title-id or --software-name"
        exit 1
      }
      log_info "Looking up Jamf patch title ID for: $SOFTWARE_NAME"
      if ! JAMF_PATCH_TITLE_ID="$(lookup_jamf_patch_title_id_by_name "$token" "$SOFTWARE_NAME")"; then
        rm -f "$parse_file" >/dev/null 2>&1 || true
        rc=$?
        if [[ "$rc" -ne 41 ]]; then
          log_error "Unable to find Jamf patch title ID for: $SOFTWARE_NAME"
          log_error "Suggestion: rerun with --jamf-pro-title-id <id> if you already know the patch title ID."
        fi
        exit 1
      fi
      log_info "Matched Jamf patch title ID: $JAMF_PATCH_TITLE_ID"
    fi

    local xml_file
    xml_file=$(mktemp /tmp/title_editor_jamf_patch_title.XXXXXX)

    log_info "Fetching Jamf Pro patch title XML (id=${JAMF_PATCH_TITLE_ID})..."
    if ! fetch_jamf_patch_title_xml_by_id "$token" "$JAMF_PATCH_TITLE_ID" > "$xml_file"; then
      rm -f "$xml_file" "$parse_file" >/dev/null 2>&1 || true
      log_error "Failed to fetch Jamf patch title id ${JAMF_PATCH_TITLE_ID}"
      exit 1
    fi

    if ! extract_versions_from_jamf_patch_xml "$xml_file" > "$parse_file"; then
      rm -f "$xml_file" "$parse_file" >/dev/null 2>&1 || true
      log_error "No versions found in Jamf Pro patch title XML (id=${JAMF_PATCH_TITLE_ID})"
      exit 1
    fi

    rm -f "$xml_file" >/dev/null 2>&1 || true
  fi

  local inferred_title=""
  local versions=()
  collect_title_and_versions "$parse_file"
  inferred_title="$PARSED_TITLE"
  versions=("${PARSED_VERSIONS[@]}")
  rm -f "$parse_file" >/dev/null 2>&1 || true

  if [[ "${#versions[@]}" -eq 0 ]]; then
    log_error "No versions discovered"
    exit 1
  fi

  if [[ "$limit_all" != "true" && "${#versions[@]}" -gt "$LIMIT" ]]; then
    versions=("${versions[@]:0:$LIMIT}")
  fi

  if [[ -z "$TITLE_NAME" ]]; then
    TITLE_NAME="${inferred_title:-${SOFTWARE_NAME:-Software}}"
  fi

  if [[ -z "$OUTPUT_FILE" ]]; then
    OUTPUT_FILE="$(default_output_file_for_title "$PWD" "$TITLE_NAME")"
  fi

  if [[ "$WRITE_JSON" == "true" ]]; then
    if [[ -z "$OUTPUT_JSON_FILE" ]]; then
      OUTPUT_JSON_FILE="$(default_json_output_file_for_title "$PWD" "$TITLE_NAME")"
    fi
    if [[ -z "$APP_NAME" ]]; then
      APP_NAME="$TITLE_NAME"
    fi
  fi

  mkdir -p "$(dirname "$OUTPUT_FILE")"
  generate_batch_file "$TITLE_NAME" "$OUTPUT_FILE" "${versions[@]}"

  if [[ "$WRITE_JSON" == "true" ]]; then
    mkdir -p "$(dirname "$OUTPUT_JSON_FILE")"
    generate_jamf_import_json_file "$TITLE_NAME" "$PUBLISHER" "$BUNDLE_ID" "$APP_NAME" "$MIN_OS" "$OUTPUT_JSON_FILE" "$SOURCE_MODE" "${versions[@]}"
  fi

  log_success "Batch file created: $OUTPUT_FILE"
  log_info "Source mode: $SOURCE_MODE"
  [[ -n "$JAMF_PATCH_TITLE_ID" ]] && log_info "Jamf patch title ID: $JAMF_PATCH_TITLE_ID"
  log_info "Title name: $TITLE_NAME"
  log_info "Versions written: ${#versions[@]}"
  if [[ "$WRITE_JSON" == "true" ]]; then
    log_success "JSON file created: $OUTPUT_JSON_FILE"
  fi
  log_info "Use with:"
  log_info "  bash title_editor_menu.sh --add-patch-batch --file $OUTPUT_FILE --yes"
}

main "$@"
