#!/usr/bin/env bash
#
# Build Title Editor Batch File from Release Notes Web Page
# Version: 1.4.3
# Revised: 2026.03.17
#
# Generates short-format batch file for title_editor_menu.sh --add-patch-batch.
# Output format:
#   title_name|version
#
# Designed for vendor release-notes pages (for example Apple support pages)
# and extracts version numbers from release-note headings.
#
# Example usage:
#   bash build_title_editor_batch_from_release_notes.sh --url "https://support.apple.com/en-us/HT201222" --title-name "macOS Sonoma" --output "./sonoma_releases.txt" --limit 10
#   bash build_title_editor_batch_from_release_notes.sh
#   (then follow prompts for URL, title name, and output file)
#
# Notes:
# - If --title-name is omitted, script tries to infer a title from the page.
# - If --limit is omitted, defaults to "all". Use a positive integer to limit versions or 0/all for no limit.
# - Use --debug for verbose output to help troubleshoot parsing issues.
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

SCRIPT_VERSION="1.4.3"
DEBUG_MODE=false

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
  cat <<EOF
Build Title Editor Batch File from Release Notes v${SCRIPT_VERSION}

Interactive mode:
  bash $(basename "$0")

Optional non-interactive flags:
  --url <release_notes_page_url>
  --mac-app-store
  --mac-app-store-name <n>
  --title-name <n>
  --publisher <publisher>
  --bundle-id <bundle_id>
  --app-name <app_name>
  --min-os <version>
  --output <path>
  --output-json <path>
  --json
  --template-json <path>
  --limit <count|all>
  --debug
  --help

Notes:
  - Fetches a release-notes web page and extracts versions from headings or table rows.
  - Use --mac-app-store to search by app name, pick a listing, and parse App Store version history.
    Bundle ID is automatically populated from the App Store listing.
  - Writes short-format batch file for Title Editor:
      title_name|version
  - JSON output always produces a Jamf Pro Title Editor-importable file.
    Interactive mode prompts for publisher, bundle ID, app name, and min OS if not supplied.
    Use --publisher, --bundle-id, --app-name, --min-os to supply these non-interactively.
  - With --template-json, publisher/bundleId/appName are read from the template
    instead of being prompted (backwards compatible).
  - If --title-name is omitted, script tries to infer a title from the page.
EOF
}

print_banner() {
  echo -e "${BLUE}=========================================================${NC}"
  echo -e "${BLUE}  Build Title Editor Batch from Release Notes v${SCRIPT_VERSION}${NC}"
  echo -e "${BLUE}=========================================================${NC}"
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

infer_software_title() {
  local listing_name="$1"
  local inferred

  inferred="$listing_name"
  # Prefer the leading product token in names like
  # "Goodnotes: AI Notes, Docs, PDF".
  inferred="${inferred%%:*}"
  inferred="${inferred%% - *}"
  inferred=$(trim "$inferred")

  if [[ -z "$inferred" ]]; then
    inferred="$listing_name"
  fi

  printf '%s' "$inferred"
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

extract_first_app_store_url() {
  local html_file="$1"

  # Extract first canonical App Store app URL from page content.
  sed -nE 's/.*(https:\/\/apps\.apple\.com\/[A-Za-z0-9\/_\-]+\/id[0-9]+).*/\1/p' "$html_file" | head -n 1
}

search_mac_app_store_listings() {
  local app_name="$1"
  local search_url search_json

  # URL-encode via Python to avoid dependency on jq/perl.
  search_url=$(python3 - "$app_name" <<'PY'
import sys
import urllib.parse

name = sys.argv[1]
print("https://itunes.apple.com/search?entity=macSoftware&country=us&limit=25&term=" + urllib.parse.quote(name))
PY
)

  if ! search_json=$(curl \
  --silent \
  --show-error \
  --fail \
  --location \
  --max-time 30 \
  --connect-timeout 10 \
  "$search_url"); then
  return 1
  fi

  python3 - "$app_name" "$search_json" <<'PY'
import json
import re
import sys

query = str(sys.argv[1] or "")
payload = json.loads(sys.argv[2])
results = payload.get("results") or []

def norm(text):
  return re.sub(r'[^a-z0-9]+', '', (text or '').lower())

def classify(name_norm, query_norm):
  if not query_norm:
    return 9
  if name_norm == query_norm:
    return 0
  if name_norm.startswith(query_norm):
    return 1
  if query_norm in name_norm:
    return 2
  return 9

query_norm = norm(query)

rows = []
best_tier = 9

for item in results:
  track_id = item.get("trackId")
  if not track_id:
    continue

  name = str(item.get("trackName") or "")
  version = str(item.get("version") or "")
  release_date = str(item.get("currentVersionReleaseDate") or "")
  bundle_id = str(item.get("bundleId") or "")
  track_url = str(item.get("trackViewUrl") or f"https://apps.apple.com/us/app/id{track_id}")
  rating_count = int(item.get("userRatingCount") or 0)

  name_norm = norm(name)
  tier = classify(name_norm, query_norm)
  best_tier = min(best_tier, tier)
  rows.append((tier, -rating_count, name.lower(), track_id, name, version, release_date, bundle_id, track_url))

if not rows:
  sys.exit(0)

# Keep only strongest tier matches; if none classified strongly, keep all.
filtered = [r for r in rows if r[0] == best_tier] if best_tier < 9 else rows
filtered.sort()

for r in filtered:
  _, _, _, track_id, name, version, release_date, bundle_id, track_url = r
  print("\t".join([str(track_id), name, version, release_date, bundle_id, track_url]))
PY
}

select_mac_app_store_listing() {
  local app_name="$1"
  local -a listings=()
  local i row idx name version release_date bundle_id track_url

  while IFS= read -r row; do
    [[ -n "$row" ]] && listings+=("$row")
  done < <(search_mac_app_store_listings "$app_name")

  if [[ "${#listings[@]}" -eq 0 ]]; then
    return 1
  fi

  echo -e "${BLUE}[INFO]${NC} Found ${#listings[@]} Mac App Store listing(s):" >&2
  for ((i=0; i<${#listings[@]}; i++)); do
    IFS=$'\t' read -r _track_id name version release_date bundle_id track_url <<< "${listings[$i]}"
    printf '  %2d) %s (v%s)\n' "$((i+1))" "${name}" "${version:-n/a}" >&2
  done

  if [[ "${#listings[@]}" -eq 1 ]]; then
    IFS=$'\t' read -r _track_id name _version _release_date _bundle_id track_url <<< "${listings[0]}"
    echo -e "${BLUE}[INFO]${NC} Only one listing found; using: ${name}" >&2
    printf '%s\t%s' "$track_url" "$name"
    return 0
  fi

  while true; do
    read -r -p "Select listing number [1-${#listings[@]}]: " idx
    idx=$(trim "$idx")

    if [[ "$idx" =~ ^[0-9]+$ ]] && (( idx >= 1 && idx <= ${#listings[@]} )); then
      row="${listings[$((idx-1))]}"
      IFS=$'\t' read -r _track_id name _version _release_date _bundle_id track_url <<< "$row"
      printf '%s\t%s' "$track_url" "$name"
      return 0
    fi

    echo -e "${YELLOW}[WARN]${NC} Invalid selection. Enter a number between 1 and ${#listings[@]}." >&2
  done
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

fetch_page() {
  local url="$1"
  if curl \
    --silent \
    --fail \
    --location \
    --max-time 60 \
    --connect-timeout 15 \
    "$url" 2>/dev/null; then
    return 0
  fi

  # Fallback for Zendesk-hosted help-center article pages that can return
  # bot-challenge responses to non-browser clients.
  if [[ "$url" =~ ^https?://([^/]+)/hc/([^/]+)/articles/([0-9]+)(-[^/?#]+)?/?$ ]]; then
    local host="${BASH_REMATCH[1]}"
    local locale="${BASH_REMATCH[2]}"
    local article_id="${BASH_REMATCH[3]}"
    local api_url="https://${host}/api/v2/help_center/${locale}/articles/${article_id}.json"
    local api_json

    if api_json=$(curl \
      --silent \
      --show-error \
      --fail \
      --location \
      --max-time 60 \
      --connect-timeout 15 \
      "$api_url"); then
      debug_log "Primary URL blocked; using Zendesk API fallback: ${api_url}"

      if ! python3 - "$api_json" <<'PY'; then
import html
import json
import sys

try:
    payload = json.loads(sys.argv[1])
except Exception:
    sys.exit(1)

article = payload.get("article") or {}
title = str(article.get("title") or "")
body = str(article.get("body") or "")

if not body:
    sys.exit(1)

safe_title = html.escape(title)
print("<html><head><meta charset=\"utf-8\"><title>{}</title></head><body>".format(safe_title))
if safe_title:
    print("<h1>{}</h1>".format(safe_title))
print(body)
print("</body></html>")
PY
        return 1
      fi

      return 0
    fi
  fi

  return 1
}

extract_title_and_versions() {
  local html_file="$1"

  python3 - "$html_file" <<'PY'
import html as html_mod
import re
import sys
from collections import Counter

html_file = sys.argv[1]

try:
    raw = open(html_file, 'r', encoding='utf-8', errors='replace').read()
except Exception:
    sys.exit(1)

# Remove scripts/styles that can contain noise.
raw = re.sub(r'<script\b[^>]*>.*?</script>', ' ', raw, flags=re.I | re.S)
raw = re.sub(r'<style\b[^>]*>.*?</style>', ' ', raw, flags=re.I | re.S)

# Collect heading text first (highest signal for versions).
heading_chunks = re.findall(r'<h[1-6][^>]*>(.*?)</h[1-6]>', raw, flags=re.I | re.S)
headings = []
for chunk in heading_chunks:
    text = re.sub(r'<[^>]+>', ' ', chunk)
    text = html_mod.unescape(text)
    text = re.sub(r'\s+', ' ', text).strip()
    if text:
        headings.append(text)

h1_chunks = re.findall(r'<h1[^>]*>(.*?)</h1>', raw, flags=re.I | re.S)
h1_titles = []
for chunk in h1_chunks:
    text = re.sub(r'<[^>]+>', ' ', chunk)
    text = html_mod.unescape(text)
    text = re.sub(r'\s+', ' ', text).strip()
    if text:
        h1_titles.append(text)

# Some vendor pages (including Mothers Ruin release history pages) put versions
# in table rows rather than headings. Capture first cells as fallback candidates.
table_first_cells = []
for row in re.findall(r'<tr\b[^>]*>(.*?)</tr>', raw, flags=re.I | re.S):
    cells = re.findall(r'<t[dh]\b[^>]*>(.*?)</t[dh]>', row, flags=re.I | re.S)
    if not cells:
        continue
    first = re.sub(r'<[^>]+>', ' ', cells[0])
    first = html_mod.unescape(first)
    first = re.sub(r'\s+', ' ', first).strip()
    if first:
        table_first_cells.append(first)

# Also capture the document title as fallback for product/title inference.
title_match = re.search(r'<title[^>]*>(.*?)</title>', raw, flags=re.I | re.S)
page_title = ""
if title_match:
    page_title = re.sub(r'<[^>]+>', ' ', title_match.group(1))
    page_title = html_mod.unescape(page_title)
    page_title = re.sub(r'\s+', ' ', page_title).strip()

# Find versions from heading lines like:
# - New in Logic Pro 12.0.1
# - Logic Pro 12.0
# - Logic 11.2
pattern = re.compile(r'(?i)\b(?:new\s+in\s+)?([A-Za-z][A-Za-z0-9 +./\-]{1,80}?)\s+(\d+(?:\.\d+){1,3})\b')

pairs = []
for line in headings:
    for m in pattern.finditer(line):
        product = re.sub(r'\s+', ' ', m.group(1)).strip(' -:')
        version = m.group(2)
        low_product = product.lower()

        # Exclude obvious non-product matches.
        if low_product in {"version", "versions", "new", "previous"}:
            continue
        if low_product.startswith("published date"):
            continue

        pairs.append((product, version))

# Deduplicate versions while preserving order.
seen_versions = set()
versions = []
for _, version in pairs:
    if version not in seen_versions:
        seen_versions.add(version)
        versions.append(version)

# Fallback for pages where headings are bare versions (e.g. "8.1.1").
if not versions:
  heading_version_pattern = re.compile(r'(?i)^v?(\d+(?:\.\d+){1,3})$')
  for line in headings:
    m = heading_version_pattern.match(line.strip())
    if not m:
      continue
    version = m.group(1)
    if version not in seen_versions:
      seen_versions.add(version)
      versions.append(version)

# Fallback for table-driven release history pages where versions appear as
# first-column entries such as: "3.1 (795)".
if not versions:
    table_version_pattern = re.compile(r'\b(\d+(?:\.\d+){1,3})(?:\s*\([^)]+\))?\b')
    for cell_text in table_first_cells:
        m = table_version_pattern.search(cell_text)
        if not m:
            continue
        version = m.group(1)
        if version not in seen_versions:
            seen_versions.add(version)
            versions.append(version)

    # Fallback for pages that provide a version index as links to release notes.
    # Examples:
    # - /firefox/148.0/releasenotes/
    # - /firefox/releases/1.0.8.html
    if not versions:
      link_pattern = re.compile(r'<a\b[^>]*href=["\']([^"\']+)["\'][^>]*>(.*?)</a>', flags=re.I | re.S)
      anchor_version_pattern = re.compile(r'^v?(\d+(?:\.\d+){1,3})$')
      href_version_pattern = re.compile(r'(?i)/(\d+(?:\.\d+){1,3})(?:\.html)?(?:[/?#]|$)')

      for href, anchor_html in link_pattern.findall(raw):
        href_low = href.lower()

        is_release_notes_href = (
          '/releasenotes/' in href_low
          or '/release-notes/' in href_low
          or '/firefox/releases/' in href_low
        )
        if not is_release_notes_href:
          continue

        anchor_text = re.sub(r'<[^>]+>', ' ', anchor_html)
        anchor_text = html_mod.unescape(anchor_text)
        anchor_text = re.sub(r'\s+', ' ', anchor_text).strip()

        version = ""
        m_anchor = anchor_version_pattern.match(anchor_text)
        if m_anchor:
          version = m_anchor.group(1)
        else:
          m_href = href_version_pattern.search(href)
          if m_href:
            version = m_href.group(1)

        if version and version not in seen_versions:
          seen_versions.add(version)
          versions.append(version)

    # Fallback for pages where versions are embedded in body text lines, for example:
    # "Version v7.0.18 (Dec 2, 2025)".
    if not versions:
      text_source = raw
      text_source = re.sub(r'(?i)<br\s*/?>', '\n', text_source)
      text_source = re.sub(r'(?i)</(?:p|div|li|tr|h[1-6])>', '\n', text_source)
      text_source = re.sub(r'<[^>]+>', ' ', text_source)
      text_source = html_mod.unescape(text_source)

      version_line_pattern = re.compile(r'(?i)\bversion\s*v?(\d+(?:\.\d+){1,3})\b')
      for raw_line in text_source.splitlines():
        line = re.sub(r'\s+', ' ', raw_line).strip()
        if not line:
          continue
        for match in version_line_pattern.finditer(line):
          version = match.group(1)
          if version not in seen_versions:
            seen_versions.add(version)
            versions.append(version)

# Infer title from most frequent product in version headings.
inferred_title = ""
if pairs:
    counts = Counter([p for p, _ in pairs])
    inferred_title = counts.most_common(1)[0][0]

# If no inferred title yet, try h1/title patterns around "release notes".
def normalize_release_notes_title(text):
    t = re.sub(r'\s+', ' ', text).strip()
    t = re.sub(r'(?i)\brelease\s+notes?\b', ' ', t)
    t = re.sub(r'(?i)\s*release\s+notes\s*$', '', t).strip(' -:')
    t = re.sub(r'(?i)\s*for\s+mac\s*$', '', t).strip(' -:')
    t = re.sub(r'\s+', ' ', t).strip(' -:|')

    # Collapse duplicate fragments split by common separators,
    # e.g. "Firefox - Firefox" -> "Firefox".
    parts = [p.strip() for p in re.split(r'\s*(?:\||-|\u2013|\u2014|:)\s*', t) if p.strip()]
    if len(parts) >= 2 and parts[0].lower() == parts[-1].lower():
        t = parts[0]

    return t

if not inferred_title and headings:
    for line in headings:
        if re.search(r'(?i)release\s+notes', line):
            inferred_title = normalize_release_notes_title(line)
            if inferred_title:
                break

if not inferred_title and page_title:
    inferred_title = normalize_release_notes_title(page_title)

if not inferred_title and h1_titles:
    inferred_title = h1_titles[0]

# Final normalization for common suffixes.
inferred_title = normalize_release_notes_title(inferred_title)

print(f"TITLE\t{inferred_title}")
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

generate_json_file() {
  local title_name="$1"
  local output_file="$2"
  local source_url="$3"
  shift 3
  local versions=("$@")

  python3 - "$title_name" "$source_url" "$output_file" "${versions[@]}" <<'PY'
import datetime
import json
import pathlib
import sys

title_name = sys.argv[1]
source_url = sys.argv[2]
output_file = pathlib.Path(sys.argv[3])
versions = sys.argv[4:]

payload = {
  "title_name": title_name,
  "source_url": source_url,
  "generated_at_utc": datetime.datetime.now(datetime.timezone.utc).isoformat(),
  "count": len(versions),
  "versions": versions,
  "batch_rows": [{"title_name": title_name, "version": v} for v in versions],
}

output_file.write_text(json.dumps(payload, indent=2) + "\n", encoding="utf-8")
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
}

output_file.write_text(json.dumps(payload, indent=2) + "\n", encoding="utf-8")
PY
}

generate_title_editor_import_json_file() {
  local title_name="$1"
  local output_file="$2"
  local source_url="$3"
  local template_json_file="$4"
  shift 4
  local versions=("$@")

  python3 - "$title_name" "$source_url" "$output_file" "$template_json_file" "${versions[@]}" <<'PY'
import copy
import datetime
import json
import pathlib
import sys

title_name = sys.argv[1]
source_url = sys.argv[2]
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
      if key_l.endswith("id") and k not in ("id",):
        continue
      if k in ("softwareTitleId", "sourceId", "lastModified", "lastModifiedTest"):
        continue
      cleaned[k] = strip_ids(v)
    return cleaned
  if isinstance(obj, list):
    return [strip_ids(i) for i in obj]
  return obj

def pick_latest_patch(patches):
  # Prefer lowest absoluteOrderId (newest in exported payload), fallback first.
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

if not isinstance(base_patch, dict):
  raise SystemExit("Template patch is invalid")

template_min_os = str(base_patch.get("minimumOperatingSystem") or "10.11")
template_standalone = bool(base_patch.get("standalone", True))
template_reboot = bool(base_patch.get("reboot", False))

template_components = base_patch.get("components") or []
if not isinstance(template_components, list):
  template_components = []

template_kill_apps = base_patch.get("killApps") or []
if not isinstance(template_kill_apps, list):
  template_kill_apps = []

template_capabilities = base_patch.get("capabilities") or []
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
    "source_url": source_url,
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

  local url=""
  local title_name=""
  local output_file=""
  local output_json_file=""
  local write_json_companion=false
  local template_json_file=""
  local publisher=""
  local bundle_id=""
  local app_name=""
  local min_os=""
  local limit="all"
  local mac_app_store_mode=false
  local mac_app_store_name=""

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --url)
        url="${2:-}"
        shift 2
        ;;
      --mac-app-store)
        mac_app_store_mode=true
        shift
        ;;
      --mac-app-store-name)
        mac_app_store_name="${2:-}"
        mac_app_store_mode=true
        shift 2
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
      --limit)
        limit="${2:-}"
        shift 2
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

  if [[ -z "$url" && "$mac_app_store_mode" != "true" && -r /dev/tty ]]; then
    echo ""
    echo "Select source type:"
    echo "  1) Release notes URL (web page)"
    echo "  2) Mac App Store (search by app name)"
    local source_choice
    read -r -p "Enter number [1]: " source_choice < /dev/tty
    source_choice=$(trim "$source_choice")
    [[ -z "$source_choice" ]] && source_choice="1"

    case "$source_choice" in
      2)
        mac_app_store_mode=true
        ;;
      *)
        ;;
    esac
  fi

  if [[ "$mac_app_store_mode" == "true" ]]; then
    if [[ -z "$mac_app_store_name" ]]; then
      mac_app_store_name=$(prompt_required "Mac App Store app name: ")
    fi

    log_info "Searching Mac App Store for: ${mac_app_store_name}"
    local app_store_selection selected_listing_name
    if ! app_store_selection=$(select_mac_app_store_listing "$mac_app_store_name"); then
      log_error "Failed to find a Mac App Store app for: ${mac_app_store_name}"
      exit 1
    fi

    IFS=$'\t' read -r url selected_listing_name <<< "$app_store_selection"

    # Extract bundle_id from App Store listing if not already set
    if [[ -z "$bundle_id" ]]; then
      local _meta_line _track_id _name _version _release_date _track_url
      # Search again to get the structured listing data including bundle_id
      _meta_line=$(search_mac_app_store_listings "$selected_listing_name" | head -1 || true)
      if [[ -n "$_meta_line" ]]; then
        IFS=$'\t' read -r _track_id _name _version _release_date bundle_id _track_url <<< "$_meta_line"
        [[ -n "$bundle_id" ]] && log_info "Bundle ID from App Store: ${bundle_id}"
      fi
    fi

    log_info "Using App Store URL: ${url}"
    if [[ -z "$title_name" ]]; then
      local default_software_title
      default_software_title=$(infer_software_title "$selected_listing_name")
      read -r -p "Software title for batch rows [${default_software_title}]: " title_name
      title_name=$(trim "$title_name")
      [[ -z "$title_name" ]] && title_name="$default_software_title"
    fi

    if [[ -z "$output_file" ]]; then
      local output_dir default_dir
      default_dir="$PWD"
      read -r -p "Output directory [${default_dir}]: " output_dir
      output_dir=$(trim "$output_dir")
      [[ -z "$output_dir" ]] && output_dir="$default_dir"
      output_file=$(default_output_file_for_title "$output_dir" "$title_name")
    fi
  fi

  if [[ "$mac_app_store_mode" != "true" && -z "$url" ]]; then
    url=$(prompt_required "Release notes page URL: ")
  fi

  if [[ "$mac_app_store_mode" != "true" && ! "$url" =~ ^https?:// ]]; then
    log_error "URL must start with http:// or https://"
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

  log_info "Fetching release notes page..."
  local html_file parse_file
  html_file=$(mktemp /tmp/title_editor_release_notes_html.XXXXXX)
  parse_file=$(mktemp /tmp/title_editor_release_notes_parse.XXXXXX)

  if ! fetch_page "$url" > "$html_file"; then
    rm -f "$html_file" "$parse_file" >/dev/null 2>&1 || true
    log_error "Failed to fetch URL: $url"
    exit 1
  fi

  local page_bytes
  page_bytes=$(wc -c < "$html_file" | tr -d ' ')
  debug_log "Fetched bytes: ${page_bytes}"

  if ! extract_title_and_versions "$html_file" > "$parse_file"; then
    rm -f "$html_file" "$parse_file" >/dev/null 2>&1 || true
    log_error "Failed to parse release notes page."
    exit 1
  fi

  local inferred_title=""
  local versions=()
  while IFS=$'\t' read -r kind value; do
    case "$kind" in
      TITLE)
        inferred_title="$value"
        ;;
      VERSION)
        [[ -n "$value" ]] && versions+=("$value")
        ;;
    esac
  done < "$parse_file"

  # Some vendor support pages are not updated as often as their App Store
  # listing. If we detect a linked App Store page on Goodnotes support, fetch
  # App Store version history and prefer it when it is richer/newer.
  if [[ "$url" == *"support.goodnotes.com"* ]]; then
    local app_store_url=""
    app_store_url=$(extract_first_app_store_url "$html_file" || true)
    app_store_url=$(trim "$app_store_url")

    if [[ -n "$app_store_url" ]]; then
      debug_log "Detected linked App Store URL: ${app_store_url}"

      local app_html_file app_parse_file
      app_html_file=$(mktemp /tmp/title_editor_release_notes_app_html.XXXXXX)
      app_parse_file=$(mktemp /tmp/title_editor_release_notes_app_parse.XXXXXX)

      if fetch_page "$app_store_url" > "$app_html_file" 2>/dev/null; then
        if extract_title_and_versions "$app_html_file" > "$app_parse_file" 2>/dev/null; then
          local app_versions=()
          while IFS=$'\t' read -r app_kind app_value; do
            if [[ "$app_kind" == "VERSION" && -n "$app_value" ]]; then
              app_versions+=("$app_value")
            fi
          done < "$app_parse_file"

          if [[ "${#app_versions[@]}" -gt 0 ]]; then
            if [[ "${#app_versions[@]}" -gt "${#versions[@]}" || "${app_versions[0]}" != "${versions[0]:-}" ]]; then
              log_info "Using App Store version history from linked page: ${app_store_url}"
              versions=("${app_versions[@]}")
            fi
          fi
        fi
      fi

      rm -f "$app_html_file" "$app_parse_file" >/dev/null 2>&1 || true
    fi
  fi

  rm -f "$html_file" "$parse_file" >/dev/null 2>&1 || true

  if [[ "${#versions[@]}" -eq 0 ]]; then
    log_error "No versions found on page."
    log_info "Tip: use --debug and verify the page exposes explicit versions in headings or table rows."
    exit 1
  fi

  local default_title
  default_title="${inferred_title:-Software Title}"

  if [[ "$default_title" =~ [Rr]elease[[:space:]]+[Nn]otes ]]; then
    log_warn "Inferred title looks like a page title: '${default_title}'"
    log_warn "Use the exact software title used in Title Editor (for example: Firefox)."
  fi

  if [[ -z "$title_name" ]]; then
    read -r -p "Title name for batch rows [${default_title}]: " title_name
    title_name=$(trim "$title_name")
    [[ -z "$title_name" ]] && title_name="$default_title"
  fi

  if [[ "$title_name" =~ [Rr]elease[[:space:]]+[Nn]otes ]]; then
    log_warn "Title name contains 'Release Notes' and may not match a software title in Title Editor."
  fi

  if [[ -z "$output_json_file" && "$write_json_companion" != "true" && -z "$template_json_file" && -r /dev/tty ]]; then
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
        ;;
      2)
        output_file=""
        write_json_companion=false
        ;;
      3)
        write_json_companion=true
        ;;
      *)
        log_warn "Invalid selection '${output_mode_choice}'. Using API Batch Import (.txt)."
        ;;
    esac
  fi

  # Prompt for Jamf-required fields when producing JSON without a template
  if [[ ( -n "$output_json_file" || "$write_json_companion" == "true" ) && -z "$template_json_file" ]]; then
    if [[ -r /dev/tty ]]; then
      echo ""
      log_info "JSON output requires a few fields for Jamf Pro import."
      if [[ -z "$publisher" ]]; then
        read -r -p "Publisher: " publisher < /dev/tty
        publisher=$(trim "$publisher")
      fi
      if [[ -z "$bundle_id" ]]; then
        read -r -p "Bundle ID (e.g. com.example.app, leave blank to skip): " bundle_id < /dev/tty
        bundle_id=$(trim "$bundle_id")
      fi
      if [[ -z "$app_name" ]]; then
        read -r -p "App name [${title_name}]: " app_name < /dev/tty
        app_name=$(trim "$app_name")
        [[ -z "$app_name" ]] && app_name="$title_name"
      fi
      if [[ -z "$min_os" ]]; then
        read -r -p "Minimum macOS version [12.0]: " min_os < /dev/tty
        min_os=$(trim "$min_os")
        [[ -z "$min_os" ]] && min_os="12.0"
      fi
    else
      [[ -z "$app_name" ]] && app_name="$title_name"
      [[ -z "$min_os"   ]] && min_os="12.0"
    fi
  fi

  local default_output
  default_output=$(default_output_file_for_title "$PWD" "$title_name")
  if [[ -z "$output_file" ]]; then
    read -r -p "Output file path [${default_output}]: " output_file
    output_file=$(trim "$output_file")
    [[ -z "$output_file" ]] && output_file="$default_output"
  fi

  if [[ -d "$output_file" ]]; then
    output_file="${output_file%/}/title_editor_batch_$(echo "$title_name" | tr '[:upper:]' '[:lower:]' | tr ' /' '__').txt"
    log_info "Output path is a directory; using file: ${output_file}"
  fi

  if [[ "$write_json_companion" == "true" && -z "$output_json_file" ]]; then
    if [[ "$output_file" == *.txt ]]; then
      output_json_file="${output_file%.txt}.json"
    else
      output_json_file="${output_file}.json"
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

  local total_found="${#versions[@]}"
  if [[ "$limit_all" != "true" && "${#versions[@]}" -gt "$limit" ]]; then
    versions=("${versions[@]:0:$limit}")
    log_info "Truncated versions to ${#versions[@]} due to --limit ${limit} (found ${total_found})."
  fi

  mkdir -p "$(dirname "$output_file")"
  generate_batch_file "$title_name" "$output_file" "${versions[@]}"

  if [[ -n "$output_json_file" ]]; then
    mkdir -p "$(dirname "$output_json_file")"
    if [[ -n "$template_json_file" ]]; then
      generate_title_editor_import_json_file "$title_name" "$output_json_file" "$url" "$template_json_file" "${versions[@]}"
    else
      generate_jamf_import_json_file "$title_name" "$publisher" "$bundle_id" "$app_name" "$min_os" "$output_json_file" "$url" "${versions[@]}"
    fi
  fi

  log_success "Batch file created: ${output_file}"
  if [[ -n "$output_json_file" ]]; then
    log_success "JSON file created: ${output_json_file}"
  fi
  log_info "Title name: ${title_name}"
  log_info "Versions written: ${#versions[@]}"
  log_info "Use with:"
  log_info "  bash /Users/u0105821/git/gitlab/general-scripts/title_editor_menu.sh --add-patch-batch --file ${output_file} --yes"
  if [[ -n "$output_json_file" ]]; then
    if [[ -n "$template_json_file" ]]; then
      log_info "JSON mode: Title Editor template-based import structure (template: ${template_json_file})"
    else
      log_info "JSON mode: Jamf Pro Title Editor importable structure"
    fi
  fi
}

main "$@"