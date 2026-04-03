#!/usr/bin/env bash
#
# Title Editor API Credentials Setup Script
# Version: 1.3.2
# Revised: 2026.03.16
#
# Stores Title Editor API host/username/password securely in macOS Keychain
# for use with title_editor_menu.sh.
#
# Usage:
#   bash setup_title_editor_credentials.sh
#   bash setup_title_editor_credentials.sh --verify
#   bash setup_title_editor_credentials.sh --verify --debug
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

SCRIPT_VERSION="1.3.2"
KEYCHAIN_SERVICE="TitleEditorAPI"
KEYCHAIN_ACCOUNT_HOST="title_editor_host"
KEYCHAIN_ACCOUNT_USER="title_editor_user"
KEYCHAIN_ACCOUNT_PASS="title_editor_password"
KEYCHAIN_PATH="${HOME}/Library/Keychains/login.keychain-db"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TITLE_EDITOR_MENU_PATH="${SCRIPT_DIR}/title_editor_menu.sh"
SECURITY_PATH="/usr/bin/security"
DEBUG_MODE=false
VERIFY_MODE=false
MIGRATE_MODE=false
TITLE_EDITOR_API_CTRL_PATH=""

VERIFY_HTTP_STATUS=""
VERIFY_HTTP_BODY=""
VERIFY_CURL_OUTPUT=""

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

secret_fingerprint() {
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

debug_secret() {
    local label="$1"
    local value="$2"
    debug_log "${label}: len=${#value}, fp=$(secret_fingerprint "$value")"
}

show_usage() {
    cat <<EOF
Title Editor Credentials Setup v${SCRIPT_VERSION}

Usage:
  $0                 Store credentials (prompts for host/user/password)
  $0 --verify        Verify credentials currently stored in Keychain
    $0 --migrate       Migrate existing credentials to login keychain
  $0 --debug         Enable safe debug output (no plaintext secrets)

Options:
  --verify, -v       Verify keychain credentials via live API auth test
    --migrate, -m      Copy existing keychain credentials into login keychain
  --debug,  -d       Print debug details (host/user and password fingerprint/length)
  --help,   -h       Show this help
EOF
}

parse_args() {
    local arg
    for arg in "$@"; do
        case "$arg" in
            --verify|-v) VERIFY_MODE=true ;;
            --migrate|-m) MIGRATE_MODE=true ;;
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

find_api_ctrl_script() {
    local script_dir candidate
    script_dir="$(cd "$(dirname "$0")" && pwd)"

    for candidate in \
        "${script_dir}/title_editor_api_ctrl.sh" \
        "${HOME}/title_editor_api_ctrl.sh" \
        "/usr/local/bin/title_editor_api_ctrl.sh"
    do
        if [[ -f "$candidate" ]]; then
            TITLE_EDITOR_API_CTRL_PATH="$candidate"
            return 0
        fi
    done

    return 1
}

test_api_credentials_via_ctrl() {
    local host="$1"
    local user="$2"
    local pass="$3"
    local output rc

    host=$(normalize_host "$host")
    find_api_ctrl_script || return 10

        output=$({
            source "$TITLE_EDITOR_API_CTRL_PATH"
            TITLE_EDITOR_API_HOST="$host"
            TITLE_EDITOR_API_USER="$user"
            TITLE_EDITOR_API_PW="$pass"
            TITLE_EDITOR_API_KEEP_ALIVE=false
            TITLE_EDITOR_API_PW_FALLBACK=false
            title_editor_api_connect >/dev/null
        } 2>&1)
    rc=$?

    VERIFY_CURL_OUTPUT="$output"

    if [[ $rc -eq 0 ]]; then
        VERIFY_HTTP_STATUS="200"
        VERIFY_HTTP_BODY="Connected via title_editor_api_ctrl.sh"
        return 0
    fi

    if echo "$output" | grep -q "AuthenticationError\|Incorrect user name or password"; then
        VERIFY_HTTP_STATUS="401"
        VERIFY_HTTP_BODY="$output"
        return 2
    fi

    VERIFY_HTTP_STATUS="000"
    VERIFY_HTTP_BODY="$output"
    return 4
}

require_macos_security() {
    if ! command -v security >/dev/null 2>&1; then
        log_error "macOS security CLI not found. This script must run on macOS."
        exit 1
    fi

    if [[ ! -f "$KEYCHAIN_PATH" ]]; then
        log_error "Login keychain not found at: $KEYCHAIN_PATH"
        exit 1
    fi
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

    if security add-generic-password \
        -s "$KEYCHAIN_SERVICE" \
        -a "$account" \
        -l "$label" \
        -D "application password" \
        -T "$SECURITY_PATH" \
        -T "$TITLE_EDITOR_MENU_PATH" \
        -w "$value" \
        "$KEYCHAIN_PATH" >/dev/null 2>&1; then
        return 0
    fi

    return 1
}

read_required() {
    local prompt="$1"
    local value
    read -r -p "$prompt" value
    if [[ -z "$value" ]]; then
        log_error "Value cannot be empty."
        exit 1
    fi
    printf '%s' "$value"
}

read_password_confirm() {
    local pw1 pw2
    read -r -s -p "Title Editor password: " pw1
    printf '\n' >&2
    read -r -s -p "Confirm password: " pw2
    printf '\n' >&2

    if [[ -z "$pw1" ]]; then
        log_error "Password cannot be empty."
        exit 1
    fi
    if [[ "$pw1" != "$pw2" ]]; then
        log_error "Passwords do not match."
        exit 1
    fi

    printf '%s' "$pw1"
}

verify_entries() {
    local host user pass
    host=$(security find-generic-password -s "$KEYCHAIN_SERVICE" -a "$KEYCHAIN_ACCOUNT_HOST" -w "$KEYCHAIN_PATH" 2>/dev/null || true)
    user=$(security find-generic-password -s "$KEYCHAIN_SERVICE" -a "$KEYCHAIN_ACCOUNT_USER" -w "$KEYCHAIN_PATH" 2>/dev/null || true)
    pass=$(security find-generic-password -s "$KEYCHAIN_SERVICE" -a "$KEYCHAIN_ACCOUNT_PASS" -w "$KEYCHAIN_PATH" 2>/dev/null || true)

    [[ -n "$host" && -n "$user" && -n "$pass" ]]
}

normalize_host() {
    local host="$1"
    host="${host#https://}"
    host="${host#http://}"
    host="${host%%/*}"
    printf '%s' "$host"
}

read_stored_credentials() {
    local host user pass
    host=$(security find-generic-password -s "$KEYCHAIN_SERVICE" -a "$KEYCHAIN_ACCOUNT_HOST" -w "$KEYCHAIN_PATH" 2>/dev/null || true)
    user=$(security find-generic-password -s "$KEYCHAIN_SERVICE" -a "$KEYCHAIN_ACCOUNT_USER" -w "$KEYCHAIN_PATH" 2>/dev/null || true)
    pass=$(security find-generic-password -s "$KEYCHAIN_SERVICE" -a "$KEYCHAIN_ACCOUNT_PASS" -w "$KEYCHAIN_PATH" 2>/dev/null || true)

    if [[ -z "$host" || -z "$user" || -z "$pass" ]]; then
        return 1
    fi

    printf '%s\n%s\n%s\n' "$host" "$user" "$pass"
}

read_credentials_from_any_keychain() {
    local host user pass
    host=$(security find-generic-password -s "$KEYCHAIN_SERVICE" -a "$KEYCHAIN_ACCOUNT_HOST" -w 2>/dev/null || true)
    user=$(security find-generic-password -s "$KEYCHAIN_SERVICE" -a "$KEYCHAIN_ACCOUNT_USER" -w 2>/dev/null || true)
    pass=$(security find-generic-password -s "$KEYCHAIN_SERVICE" -a "$KEYCHAIN_ACCOUNT_PASS" -w 2>/dev/null || true)

    if [[ -z "$host" || -z "$user" || -z "$pass" ]]; then
        return 1
    fi

    printf '%s\n%s\n%s\n' "$host" "$user" "$pass"
}

debug_keychain_presence() {
    [[ "$DEBUG_MODE" == "true" ]] || return 0

    local accounts account value
    accounts=("$KEYCHAIN_ACCOUNT_HOST" "$KEYCHAIN_ACCOUNT_USER" "$KEYCHAIN_ACCOUNT_PASS")

    debug_log "Checking expected entries in keychain: $KEYCHAIN_PATH"
    for account in "${accounts[@]}"; do
        value=$(security find-generic-password -s "$KEYCHAIN_SERVICE" -a "$account" -w "$KEYCHAIN_PATH" 2>/dev/null || true)
        if [[ -n "$value" ]]; then
            if [[ "$account" == "$KEYCHAIN_ACCOUNT_PASS" ]]; then
                debug_secret "Entry '$account' (login keychain)" "$value"
            else
                debug_log "Entry '$account' (login keychain): $value"
            fi
        else
            debug_log "Entry '$account' (login keychain): <missing>"

            # Diagnostic only: check if the same service/account exists in any other keychain
            value=$(security find-generic-password -s "$KEYCHAIN_SERVICE" -a "$account" -w 2>/dev/null || true)
            if [[ -n "$value" ]]; then
                if [[ "$account" == "$KEYCHAIN_ACCOUNT_PASS" ]]; then
                    debug_secret "Entry '$account' found in another keychain" "$value"
                else
                    debug_log "Entry '$account' found in another keychain: $value"
                fi
                debug_log "Tip: re-run setup to store all entries in login.keychain-db for consistency."
            fi
        fi
    done
}

test_api_credentials() {
    local host="$1"
    local user="$2"
    local pass="$3"
    local ctrl_rc
    local tmp_body raw_status status

    # Preferred path: use the same auth flow as title_editor_menu.sh
    if test_api_credentials_via_ctrl "$host" "$user" "$pass"; then
        return 0
    fi
    ctrl_rc=$?
    case "$ctrl_rc" in
        2)
            # Cross-check with direct curl to avoid false negatives from controller path.
            ;;
        4)
            # Fall through to curl fallback for additional diagnostics.
            ;;
        *)
            # Unknown controller failure; try curl fallback.
            ;;
    esac

    host=$(normalize_host "$host")
    tmp_body=$(mktemp /tmp/title_editor_verify.XXXXXX)

    raw_status=$(curl \
        --silent \
        --show-error \
        --location \
        --location-trusted \
        --max-time 60 \
        --connect-timeout 60 \
        --header "Content-Type: application/json" \
        --header "Accept: application/json" \
        --header "User-Agent: title-editor-credentials-verify/${SCRIPT_VERSION}" \
        --output "$tmp_body" \
        --write-out "%{http_code}" \
        --request POST \
        --user "${user}:${pass}" \
        "https://${host}/v2/auth/tokens" 2>&1)

    status=$(printf '%s' "$raw_status" | grep -Eo '[0-9]{3}$' || true)
    [[ -z "$status" ]] && status="000"

    VERIFY_HTTP_STATUS="$status"
    VERIFY_CURL_OUTPUT="$raw_status"
    VERIFY_HTTP_BODY=$(cat "$tmp_body" 2>/dev/null || true)

    rm -f "$tmp_body" >/dev/null 2>&1 || true

    case "$VERIFY_HTTP_STATUS" in
        200|201)
            if [[ "$ctrl_rc" -eq 2 ]]; then
                debug_log "Controller auth returned 401, but direct curl auth succeeded. Proceeding with curl result."
            fi
            return 0
            ;;
        401)
            return 2
            ;;
        000)
            return 4
            ;;
        *)
            return 3
            ;;
    esac
}

verify_mode() {
    require_macos_security
    print_banner
    log_info "Verifying Title Editor credentials from Keychain..."

    local creds host user pass
    if ! creds=$(read_stored_credentials); then
        log_error "Missing one or more Keychain entries for service '${KEYCHAIN_SERVICE}'."
        debug_keychain_presence
        log_info "Run setup to store credentials:"
        log_info "  bash ${SCRIPT_DIR}/setup_title_editor_credentials.sh"
        log_info "Or migrate existing entries from another keychain:"
        log_info "  bash ${SCRIPT_DIR}/setup_title_editor_credentials.sh --migrate"
        exit 1
    fi

    host=$(printf '%s\n' "$creds" | sed -n '1p')
    user=$(printf '%s\n' "$creds" | sed -n '2p')
    pass=$(printf '%s\n' "$creds" | sed -n '3p')

    debug_log "Using keychain path: $KEYCHAIN_PATH"
    debug_secret "Stored password" "$pass"

    log_info "Host: $(normalize_host "$host")"
    log_info "User: $user"
    log_info "Testing API authentication..."

    if test_api_credentials "$host" "$user" "$pass"; then
        log_success "Credentials are valid (API authentication succeeded)."
        exit 0
    fi

    case "$VERIFY_HTTP_STATUS" in
        401)
            log_error "Credentials found in Keychain but authentication failed (401)."
            log_info "Update credentials with:"
            log_info "  bash ${SCRIPT_DIR}/setup_title_editor_credentials.sh"
            ;;
        000)
            log_error "Could not verify credentials due to curl/network failure (HTTP 000)."
            log_info "Host checked: $(normalize_host "$host")"
            if [[ -n "$VERIFY_CURL_OUTPUT" ]]; then
                log_info "curl output: ${VERIFY_CURL_OUTPUT}"
            fi
            ;;
        *)
            log_error "Could not verify credentials (HTTP status: ${VERIFY_HTTP_STATUS:-unknown})."
            if [[ -n "$VERIFY_HTTP_BODY" ]]; then
                log_info "Response excerpt:"
                printf '%s\n' "$VERIFY_HTTP_BODY" | head -5 | sed 's/^/[INFO] /'
            fi
            log_info "Check host/network and try again."
            ;;
    esac
    exit 1
}

migrate_mode() {
    require_macos_security
    print_banner
    log_info "Migrating Title Editor credentials into login keychain..."

    if verify_entries; then
        log_success "Entries already exist in login keychain. No migration needed."
        exit 0
    fi

    local creds host user pass
    if ! creds=$(read_credentials_from_any_keychain); then
        log_error "No complete '${KEYCHAIN_SERVICE}' credentials found in other keychains."
        log_info "Run setup to enter and save credentials:"
        log_info "  bash ${SCRIPT_DIR}/setup_title_editor_credentials.sh"
        exit 1
    fi

    host=$(printf '%s\n' "$creds" | sed -n '1p')
    user=$(printf '%s\n' "$creds" | sed -n '2p')
    pass=$(printf '%s\n' "$creds" | sed -n '3p')

    debug_log "Migrating host: $host"
    debug_log "Migrating user: $user"
    debug_secret "Migrating password" "$pass"

    if ! store_value "$KEYCHAIN_ACCOUNT_HOST" "Title Editor API Host" "$host"; then
        log_error "Failed to store host during migration."
        exit 1
    fi
    if ! store_value "$KEYCHAIN_ACCOUNT_USER" "Title Editor API Username" "$user"; then
        log_error "Failed to store username during migration."
        exit 1
    fi
    if ! store_value "$KEYCHAIN_ACCOUNT_PASS" "Title Editor API Password" "$pass"; then
        log_error "Failed to store password during migration."
        exit 1
    fi

    if verify_entries; then
        log_success "Migration completed. Entries are now stored in login keychain."
        log_info "Next: verify with:"
        log_info "  bash ${SCRIPT_DIR}/setup_title_editor_credentials.sh --verify --debug"
        exit 0
    fi

    log_error "Migration did not verify in login keychain."
    exit 1
}

print_banner() {
    echo -e "${BLUE}================================================${NC}"
    echo -e "${BLUE}  Title Editor Credentials Setup v${SCRIPT_VERSION}${NC}"
    echo -e "${BLUE}================================================${NC}"
    echo ""
}

main() {
    parse_args "$@"

    if [[ "$MIGRATE_MODE" == "true" ]]; then
        migrate_mode
    fi

    if [[ "$VERIFY_MODE" == "true" ]]; then
        verify_mode
    fi

    require_macos_security
    print_banner

    if [[ ! -f "$TITLE_EDITOR_MENU_PATH" ]]; then
        log_warn "title_editor_menu.sh not found at: $TITLE_EDITOR_MENU_PATH"
        log_warn "Keychain ACL will still be set to this path; ensure the menu script exists there."
    else
        log_info "Keychain ACL trusted applications:"
        log_info "  $SECURITY_PATH"
        log_info "  $TITLE_EDITOR_MENU_PATH"
    fi

    log_info "Credentials will be stored in your login Keychain"
    log_info "Service: ${KEYCHAIN_SERVICE}"
    echo ""

    local host user password
    host=$(read_required "Title Editor server hostname (e.g. yourtenant.appcatalog.jamfcloud.com): ")
    host=$(normalize_host "$host")
    user=$(read_required "Title Editor username: ")
    password=$(read_password_confirm)

    debug_log "Using keychain path: $KEYCHAIN_PATH"
    debug_log "Entered host: $host"
    debug_log "Entered user: $user"
    debug_secret "Entered password" "$password"

    log_info "Testing API authentication with provided credentials..."
    if ! test_api_credentials "$host" "$user" "$password"; then
        case "$VERIFY_HTTP_STATUS" in
            401)
                log_error "Authentication failed (401). Username/password are not valid for Title Editor API."
                ;;
            000)
                log_error "Could not contact API endpoint (HTTP 000)."
                if [[ -n "$VERIFY_CURL_OUTPUT" ]]; then
                    log_info "curl output: ${VERIFY_CURL_OUTPUT}"
                fi
                ;;
            *)
                log_error "Authentication test failed (HTTP ${VERIFY_HTTP_STATUS:-unknown})."
                if [[ -n "$VERIFY_HTTP_BODY" ]]; then
                    log_info "Response excerpt:"
                    printf '%s\n' "$VERIFY_HTTP_BODY" | head -5 | sed 's/^/[INFO] /'
                fi
                ;;
        esac
        log_info "Credentials were not saved. Re-run setup with correct values."
        exit 1
    fi

    log_info "Saving credentials to Keychain..."

    if ! store_value "$KEYCHAIN_ACCOUNT_HOST" "Title Editor API Host" "$host"; then
        log_error "Failed to store host."
        exit 1
    fi
    if ! store_value "$KEYCHAIN_ACCOUNT_USER" "Title Editor API Username" "$user"; then
        log_error "Failed to store username."
        exit 1
    fi
    if ! store_value "$KEYCHAIN_ACCOUNT_PASS" "Title Editor API Password" "$password"; then
        log_error "Failed to store password."
        exit 1
    fi

    if verify_entries; then
        local stored
        if stored=$(read_stored_credentials); then
            local shost suser spass
            shost=$(printf '%s\n' "$stored" | sed -n '1p')
            suser=$(printf '%s\n' "$stored" | sed -n '2p')
            spass=$(printf '%s\n' "$stored" | sed -n '3p')
            debug_log "Stored host: $shost"
            debug_log "Stored user: $suser"
            debug_secret "Stored password" "$spass"
        fi
        log_success "Title Editor credentials saved and verified."
        echo ""
        echo "Next step: run title_editor_menu.sh — it will auto-use Keychain credentials."
    else
        log_error "Verification failed after saving credentials."
        exit 1
    fi
}

main "$@"
