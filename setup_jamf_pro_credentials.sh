#!/usr/bin/env bash
#
# Jamf Pro API Credentials Setup Script
# Version: 1.0.0
# Revised: 2026.03.25
#
# Stores Jamf Pro API URL/client credentials securely in macOS Keychain.
#
# Usage:
#   bash setup_jamf_pro_credentials.sh
#   bash setup_jamf_pro_credentials.sh --verify
#   bash setup_jamf_pro_credentials.sh --verify --debug
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

SCRIPT_VERSION="1.0.0"
KEYCHAIN_SERVICE="JamfProAPI"
KEYCHAIN_ACCOUNT_URL="jamf_pro_url"
KEYCHAIN_ACCOUNT_CLIENT_ID="jamf_client_id"
KEYCHAIN_ACCOUNT_CLIENT_SECRET="jamf_client_secret"
KEYCHAIN_PATH="${HOME}/Library/Keychains/login.keychain-db"
SECURITY_PATH="/usr/bin/security"
DEBUG_MODE=false
VERIFY_MODE=false

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
Jamf Pro Credentials Setup v${SCRIPT_VERSION}

Usage:
  $0                 Store credentials (prompts for URL/client ID/client secret)
  $0 --verify        Verify credentials currently stored in Keychain
  $0 --debug         Enable safe debug output

Options:
  --verify, -v       Verify keychain credentials via /api/oauth/token
  --debug,  -d       Print debug details (no plaintext secrets)
  --help,   -h       Show this help
EOF_USAGE
}

parse_args() {
  local arg
  for arg in "$@"; do
    case "$arg" in
      --verify|-v) VERIFY_MODE=true ;;
      --debug|-d)  DEBUG_MODE=true ;;
      --help|-h)   show_usage; exit 0 ;;
      *)
        log_error "Unknown option: $arg"
        show_usage
        exit 1
        ;;
    esac
  done
}

require_macos_security() {
  command -v security >/dev/null 2>&1 || {
    log_error "macOS security CLI not found. This script must run on macOS."
    exit 1
  }

  [[ -f "$KEYCHAIN_PATH" ]] || {
    log_error "Login keychain not found at: $KEYCHAIN_PATH"
    exit 1
  }
}

normalize_url() {
  local url="$1"
  url="${url%/}"
  if [[ "$url" != http://* && "$url" != https://* ]]; then
    url="https://${url}"
  fi
  printf '%s' "$url"
}

delete_entry_if_exists() {
  local account="$1"
  security delete-generic-password -s "$KEYCHAIN_SERVICE" -a "$account" "$KEYCHAIN_PATH" >/dev/null 2>&1 || true
}

store_value() {
  local account="$1"
  local label="$2"
  local value="$3"

  delete_entry_if_exists "$account"

  security add-generic-password \
    -s "$KEYCHAIN_SERVICE" \
    -a "$account" \
    -l "$label" \
    -D "application password" \
    -T "$SECURITY_PATH" \
    -w "$value" \
    "$KEYCHAIN_PATH" >/dev/null 2>&1
}

get_value() {
  local account="$1"
  security find-generic-password -s "$KEYCHAIN_SERVICE" -a "$account" -w "$KEYCHAIN_PATH" 2>/dev/null || true
}

verify_entries_present() {
  local url client_id client_secret
  url=$(get_value "$KEYCHAIN_ACCOUNT_URL")
  client_id=$(get_value "$KEYCHAIN_ACCOUNT_CLIENT_ID")
  client_secret=$(get_value "$KEYCHAIN_ACCOUNT_CLIENT_SECRET")

  [[ -n "$url" && -n "$client_id" && -n "$client_secret" ]]
}

read_required() {
  local prompt="$1"
  local value
  read -r -p "$prompt" value
  [[ -n "$value" ]] || {
    log_error "Value cannot be empty."
    exit 1
  }
  printf '%s' "$value"
}

read_secret_confirm() {
  local label="$1"
  local s1 s2

  read -r -s -p "$label: " s1
  printf '\n' >&2
  read -r -s -p "Confirm $label: " s2
  printf '\n' >&2

  [[ -n "$s1" ]] || {
    log_error "$label cannot be empty."
    exit 1
  }
  [[ "$s1" == "$s2" ]] || {
    log_error "$label values do not match."
    exit 1
  }
  printf '%s' "$s1"
}

verify_credentials() {
  local url client_id client_secret http_code body

  url=$(get_value "$KEYCHAIN_ACCOUNT_URL")
  client_id=$(get_value "$KEYCHAIN_ACCOUNT_CLIENT_ID")
  client_secret=$(get_value "$KEYCHAIN_ACCOUNT_CLIENT_SECRET")

  [[ -n "$url" && -n "$client_id" && -n "$client_secret" ]] || {
    log_error "Missing one or more keychain values for service: $KEYCHAIN_SERVICE"
    return 2
  }

  debug_log "Testing auth against: ${url}/api/oauth/token"

  body=$(mktemp /tmp/jamf_oauth_verify_body.XXXXXX)
  http_code=$(curl \
    --silent \
    --show-error \
    --output "$body" \
    --write-out '%{http_code}' \
    --request POST \
    --header 'Content-Type: application/x-www-form-urlencoded' \
    --data-urlencode "client_id=${client_id}" \
    --data-urlencode "grant_type=client_credentials" \
    --data-urlencode "client_secret=${client_secret}" \
    "${url}/api/oauth/token" || true)

  if [[ "$http_code" == "200" ]]; then
    log_success "Authentication succeeded against Jamf Pro OAuth endpoint."
    rm -f "$body" >/dev/null 2>&1 || true
    return 0
  fi

  log_error "Authentication failed (HTTP ${http_code:-unknown})."
  if [[ "$DEBUG_MODE" == "true" ]]; then
    debug_log "Response body: $(cat "$body" 2>/dev/null || true)"
  fi
  rm -f "$body" >/dev/null 2>&1 || true
  return 1
}

store_credentials_interactive() {
  local url client_id client_secret

  log_info "Enter Jamf Pro API credentials to store in login keychain"
  url=$(read_required "Jamf Pro URL (e.g. https://your-jamf-server.example.com:8443): ")
  url=$(normalize_url "$url")
  client_id=$(read_required "API Client ID: ")
  client_secret=$(read_secret_confirm "API Client Secret")

  if ! store_value "$KEYCHAIN_ACCOUNT_URL" "Jamf Pro URL" "$url"; then
    log_error "Failed to store Jamf Pro URL in keychain."
    exit 1
  fi
  if ! store_value "$KEYCHAIN_ACCOUNT_CLIENT_ID" "Jamf API Client ID" "$client_id"; then
    log_error "Failed to store Jamf API Client ID in keychain."
    exit 1
  fi
  if ! store_value "$KEYCHAIN_ACCOUNT_CLIENT_SECRET" "Jamf API Client Secret" "$client_secret"; then
    log_error "Failed to store Jamf API Client Secret in keychain."
    exit 1
  fi

  log_success "Credentials stored in keychain service: ${KEYCHAIN_SERVICE}"
}

main() {
  parse_args "$@"
  require_macos_security

  if [[ "$VERIFY_MODE" == "true" ]]; then
    verify_credentials
    exit $?
  fi

  store_credentials_interactive

  if verify_entries_present; then
    log_success "Keychain entries verified."
  else
    log_error "Stored entries could not be read back from keychain."
    exit 1
  fi

  log_info "Running verification test..."
  if ! verify_credentials; then
    log_warn "Credentials were stored, but live verification failed."
    exit 1
  fi
}

main "$@"
