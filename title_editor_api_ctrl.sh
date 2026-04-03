#!/usr/bin/env bash
#
# Jamf Title Editor API Control Script
# Version: 1.0.2
# Revised: 2026.03.06
#
# A helper library for connecting to and interacting with the Title Editor API from bash.
#
# This script provides a set of functions to manage API connections, handle authentication tokens,
# and perform API requests with proper error handling. Designed for use in scripts and the command line,
# with a focus on ease of use and minimal dependencies.
#
# Provides functions to connect, authenticate, and perform API actions with proper error handling.
#
# Usage:
#   source title_editor_api_ctrl.sh
#   title_editor_api_connect "https://<user>:<password>@<server-host>"
#   title_editor_api_get "softwaretitles"
#   title_editor_api_post "patches" '{"name": "New Patch", "description": "Details..."}'
#
# Dependencies: curl, base64, openssl (all standard on macOS)
# Optional:     jq (for more robust JSON parsing; falls back to grep/sed)
#
# Example:
#   source title_editor_api_ctrl.sh
#   title_editor_api_connect "https://<user>:<password>@<server-host>"
#   title_editor_api_get "softwaretitles"
#   title_editor_api_disconnect
#
# This script is designed to be sourced, not executed.
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

###############################################################################
# CONSTANTS
###############################################################################

TITLE_EDITOR_API_VERSION="1.0.2"
TITLE_EDITOR_API_HTTPS_SCHEME="https"
TITLE_EDITOR_API_SSL_PORT=443
TITLE_EDITOR_API_DFT_SSL_VERSION="TLSv1_2"
TITLE_EDITOR_API_DFT_OPEN_TIMEOUT=60
TITLE_EDITOR_API_DFT_TIMEOUT=60
TITLE_EDITOR_API_RSRC_VERSION="v2"
TITLE_EDITOR_API_AUTH_RSRC="auth"
TITLE_EDITOR_API_NEW_TOKEN_RSRC="${TITLE_EDITOR_API_AUTH_RSRC}/tokens"
TITLE_EDITOR_API_REFRESH_RSRC="${TITLE_EDITOR_API_AUTH_RSRC}/keepalive"
TITLE_EDITOR_API_CURRENT_STATUS_RSRC="${TITLE_EDITOR_API_AUTH_RSRC}/current"
TITLE_EDITOR_API_TOKEN_REFRESH_BUFFER=300   # seconds before expiry to refresh

# Global config file paths (also defined as variables for use in the script)
TITLE_EDITOR_API_GLOBAL_CONF="/etc/title_editor_api.conf"
TITLE_EDITOR_API_USER_CONF="${HOME}/.title_editor_api.conf"

###############################################################################
# STATE  (module-level variables to track connection and token state)
###############################################################################

_TITLE_EDITOR_API_CONNECTED=false
_TITLE_EDITOR_API_HOST=""
_TITLE_EDITOR_API_PORT=""
_TITLE_EDITOR_API_USER=""
_TITLE_EDITOR_API_BASE_URL=""
_TITLE_EDITOR_API_TOKEN=""
_TITLE_EDITOR_API_TOKEN_EXPIRES=0     # unix timestamp
_TITLE_EDITOR_API_PW=""               # base64-encoded, cleared if pw_fallback=false
_TITLE_EDITOR_API_PW_FALLBACK=true
_TITLE_EDITOR_API_KEEP_ALIVE=true
_TITLE_EDITOR_API_TIMEOUT=${TITLE_EDITOR_API_DFT_TIMEOUT}
_TITLE_EDITOR_API_OPEN_TIMEOUT=${TITLE_EDITOR_API_DFT_OPEN_TIMEOUT}
_TITLE_EDITOR_API_VERIFY_CERT=true
_TITLE_EDITOR_API_SSL_VERSION="${TITLE_EDITOR_API_DFT_SSL_VERSION}"
_TITLE_EDITOR_API_CONNECT_TIME=""
_TITLE_EDITOR_API_NAME=""
_TITLE_EDITOR_API_KEEP_ALIVE_PID=""   # background refresh process PID

###############################################################################
# CONFIGURATION
###############################################################################

# Read a title_editor_api.conf file and apply values to global state.
# Format: one "key: value" pair per line. Lines starting with # are ignored.
#
# @param $1  Path to the config file to read
_title_editor_api_read_config() {
  local file="$1"
  [[ -r "$file" ]] || return 0

  while IFS= read -r line; do
    # skip blank lines and comments
    [[ "$line" =~ ^[[:space:]]*(#|$) ]] && continue
    # parse key: value
    if [[ "$line" =~ ^[[:space:]]*([a-zA-Z_]+):[[:space:]]*(.+)$ ]]; then
      local key="${BASH_REMATCH[1]}"
      local val="${BASH_REMATCH[2]}"
      val="${val%%#*}"   # strip inline comments
      val="${val%"${val##*[![:space:]]}"}"  # rtrim whitespace

      case "$key" in
        title_editor_server_name)  _TITLE_EDITOR_API_HOST="$val" ;;
        title_editor_server_port)  _TITLE_EDITOR_API_PORT="$val" ;;
        title_editor_username)     _TITLE_EDITOR_API_USER="$val" ;;
        title_editor_timeout)      _TITLE_EDITOR_API_TIMEOUT="$val" ;;
        title_editor_open_timeout) _TITLE_EDITOR_API_OPEN_TIMEOUT="$val" ;;
        title_editor_ssl_version)  _TITLE_EDITOR_API_SSL_VERSION="$val" ;;
        title_editor_verify_cert)
          [[ "$val" == "false" ]] && _TITLE_EDITOR_API_VERIFY_CERT=false || _TITLE_EDITOR_API_VERIFY_CERT=true
          ;;
      esac
    fi
  done < "$file"
}

# Load configuration from global then user conf files.
title_editor_api_load_config() {
  _title_editor_api_read_config "$TITLE_EDITOR_API_GLOBAL_CONF"
  _title_editor_api_read_config "$TITLE_EDITOR_API_USER_CONF"
}

# Save current configuration to a file.
# @param $1  Path to write; or "user" for ~/.title_editor_api.conf, "global" for /etc/title_editor_api.conf
title_editor_api_save_config() {
  local target="${1:-user}"
  local path
  case "$target" in
    global) path="$TITLE_EDITOR_API_GLOBAL_CONF" ;;
    user)   path="$TITLE_EDITOR_API_USER_CONF"   ;;
    *)      path="$target"             ;;
  esac

  {
    echo "title_editor_server_name: ${_TITLE_EDITOR_API_HOST}"
    echo "title_editor_server_port: ${_TITLE_EDITOR_API_PORT}"
    echo "title_editor_username: ${_TITLE_EDITOR_API_USER}"
    echo "title_editor_timeout: ${_TITLE_EDITOR_API_TIMEOUT}"
    echo "title_editor_open_timeout: ${_TITLE_EDITOR_API_OPEN_TIMEOUT}"
    echo "title_editor_ssl_version: ${_TITLE_EDITOR_API_SSL_VERSION}"
    echo "title_editor_verify_cert: ${_TITLE_EDITOR_API_VERIFY_CERT}"
  } > "$path"
}

# Print current configuration to stdout.
title_editor_api_print_config() {
  echo "title_editor_server_name: ${_TITLE_EDITOR_API_HOST}"
  echo "title_editor_server_port: ${_TITLE_EDITOR_API_PORT}"
  echo "title_editor_username: ${_TITLE_EDITOR_API_USER}"
  echo "title_editor_timeout: ${_TITLE_EDITOR_API_TIMEOUT}"
  echo "title_editor_open_timeout: ${_TITLE_EDITOR_API_OPEN_TIMEOUT}"
  echo "title_editor_ssl_version: ${_TITLE_EDITOR_API_SSL_VERSION}"
  echo "title_editor_verify_cert: ${_TITLE_EDITOR_API_VERIFY_CERT}"
}

###############################################################################
# EXCEPTIONS / ERROR HANDLING 
###############################################################################

# Error codes
# Guarded so re-sourcing the script does not fail on read-only re-declaration
if [[ -z "${TITLE_EDITOR_API_ERR_CONNECTION:-}" ]]; then
  readonly TITLE_EDITOR_API_ERR_CONNECTION=1
  readonly TITLE_EDITOR_API_ERR_NOT_CONNECTED=2
  readonly TITLE_EDITOR_API_ERR_AUTH=3
  readonly TITLE_EDITOR_API_ERR_PERMISSION=4
  readonly TITLE_EDITOR_API_ERR_INVALID_TOKEN=5
  readonly TITLE_EDITOR_API_ERR_MISSING_DATA=6
  readonly TITLE_EDITOR_API_ERR_INVALID_DATA=7
  readonly TITLE_EDITOR_API_ERR_NO_SUCH_ITEM=8
  readonly TITLE_EDITOR_API_ERR_ALREADY_EXISTS=9
  readonly TITLE_EDITOR_API_ERR_UNSUPPORTED=10
fi

# Print an error message and exit (or return if called with 'return' semantics)
# @param $1  Exit code (one of the TITLE_EDITOR_API_ERR_* values)
# @param $2  Error message
_title_editor_api_raise() {
  local code="$1"
  local msg="$2"
  local errtype
  case "$code" in
    $TITLE_EDITOR_API_ERR_CONNECTION)     errtype="ConnectionError"     ;;
    $TITLE_EDITOR_API_ERR_NOT_CONNECTED)  errtype="NotConnectedError"   ;;
    $TITLE_EDITOR_API_ERR_AUTH)           errtype="AuthenticationError" ;;
    $TITLE_EDITOR_API_ERR_PERMISSION)     errtype="PermissionError"     ;;
    $TITLE_EDITOR_API_ERR_INVALID_TOKEN)  errtype="InvalidTokenError"   ;;
    $TITLE_EDITOR_API_ERR_MISSING_DATA)   errtype="MissingDataError"    ;;
    $TITLE_EDITOR_API_ERR_INVALID_DATA)   errtype="InvalidDataError"    ;;
    $TITLE_EDITOR_API_ERR_NO_SUCH_ITEM)   errtype="NoSuchItemError"     ;;
    $TITLE_EDITOR_API_ERR_ALREADY_EXISTS) errtype="AlreadyExistsError"  ;;
    $TITLE_EDITOR_API_ERR_UNSUPPORTED)    errtype="UnsupportedError"    ;;
    *)                          errtype="Error"               ;;
  esac
  echo "TitleEditorAPI::${errtype}: ${msg}" >&2
  return "$code" 2>/dev/null || exit "$code"
}

###############################################################################
# JSON HELPERS 
###############################################################################

# Extract a scalar value from a JSON string.
# Uses jq if available, otherwise a best-effort grep/sed approach.
#
# @param $1  JSON string
# @param $2  Key name (top-level only for the sed fallback)
# @stdout    The extracted value (unquoted)
_title_editor_api_json_get() {
  local json="$1"
  local key="$2"
  if command -v jq &>/dev/null; then
    echo "$json" | jq -r ".${key} // empty"
  else
    # grep-based fallback for simple string/number values
    echo "$json" \
      | grep -o "\"${key}\"[[:space:]]*:[[:space:]]*[^,}]*" \
      | sed 's/^"[^"]*"[[:space:]]*:[[:space:]]*//' \
      | tr -d '"' \
      | tr -d ' '
  fi
}

###############################################################################
# CURL HELPERS
###############################################################################

# Build common curl flags from current connection state.
_title_editor_api_curl_flags() {
  local flags=(
    --silent
    --show-error
    --location
    --location-trusted
    --max-time   "${_TITLE_EDITOR_API_TIMEOUT}"
    --connect-timeout "${_TITLE_EDITOR_API_OPEN_TIMEOUT}"
    --header     "Content-Type: application/json"
    --header     "Accept: application/json"
    --header     "User-Agent: title-editor-api-ctrl/${TITLE_EDITOR_API_VERSION} curl/${CURL_VERSION:-unknown}"
  )

  # SSL verification
  if [[ "${_TITLE_EDITOR_API_VERIFY_CERT}" == "false" ]]; then
    flags+=(--insecure)
  fi

  # Bearer token (if we have one)
  if [[ -n "${_TITLE_EDITOR_API_TOKEN}" ]]; then
    flags+=(--header "Authorization: Bearer ${_TITLE_EDITOR_API_TOKEN}")
  fi

  printf '%s\n' "${flags[@]}"
}

# Internal: run curl and return both the HTTP status code and body.
# Sets _TITLE_EDITOR_API_HTTP_STATUS and _TITLE_EDITOR_API_HTTP_BODY
#
# @param ...  curl arguments (URL must be last or among them)
_title_editor_api_curl() {
  local tmpfile
  tmpfile=$(mktemp)

  local args=()
  while IFS= read -r flag; do
    args+=("$flag")
  done < <(_title_editor_api_curl_flags)
  args+=("$@")

  _TITLE_EDITOR_API_HTTP_STATUS=$(curl "${args[@]}" \
    --output "$tmpfile" \
    --write-out "%{http_code}" \
    2>/dev/null || true)

  _TITLE_EDITOR_API_HTTP_BODY=$(cat "$tmpfile")
  rm -f "$tmpfile"
}

# Map an HTTP status to an error and raise it.
# @param $1  HTTP status code
# @param $2  Response body (JSON)
_title_editor_api_handle_http_error() {
  local status="$1"
  local body="$2"
  local msg

  case "$status" in
    404)
      msg="Not Found (404)"
      _title_editor_api_raise $TITLE_EDITOR_API_ERR_NO_SUCH_ITEM "$msg"
      ;;
    401)
      if echo "$body" | grep -qi "token not found"; then
        _title_editor_api_raise $TITLE_EDITOR_API_ERR_INVALID_TOKEN "Connection Token is not valid."
      elif echo "$body" | grep -qi "expired token"; then
        _title_editor_api_raise $TITLE_EDITOR_API_ERR_INVALID_TOKEN "Connection Token has expired."
      else
        _title_editor_api_raise $TITLE_EDITOR_API_ERR_PERMISSION "You are not authorized to do that."
      fi
      ;;
    5[0-9][0-9])
      _title_editor_api_raise $TITLE_EDITOR_API_ERR_CONNECTION "There was an internal server error (${status}). Body: ${body}"
      ;;
    *)
      _title_editor_api_raise $TITLE_EDITOR_API_ERR_CONNECTION \
        "There was an error processing your request, status: ${status}. Body: ${body}"
      ;;
  esac
}

###############################################################################
# TOKEN MANAGEMENT
###############################################################################

# Parse token status from the server and populate token-related state vars.
# Requires _TITLE_EDITOR_API_TOKEN to be set.
# Sets: _TITLE_EDITOR_API_TOKEN_EXPIRES, _TITLE_EDITOR_API_USER, _TITLE_EDITOR_API_DOMAIN, _TITLE_EDITOR_API_TENANT_ID
_title_editor_api_parse_token_status() {
  # Decode the JWT payload directly (no extra API call needed)
  # JWT format: header.payload.signature — all base64url encoded
  local token="${_TITLE_EDITOR_API_TOKEN}"
  local payload
  payload=$(echo "$token" | cut -d. -f2)

  # base64url -> base64: replace - with + and _ with /
  # pad to multiple of 4
  local padded="${payload}==="
  padded=$(echo "$padded" | sed 's/-/+/g; s/_/\//g')
  local json
  json=$(echo "$padded" | base64 -d 2>/dev/null || echo "$padded" | base64 --decode 2>/dev/null)

  if [[ -z "$json" ]]; then
    _title_editor_api_raise $TITLE_EDITOR_API_ERR_INVALID_TOKEN "Could not decode token payload"
    return
  fi

  local exp
  exp=$(_title_editor_api_json_get "$json" "exp")
  _TITLE_EDITOR_API_TOKEN_EXPIRES="${exp:-0}"
  _TITLE_EDITOR_API_USER=$(_title_editor_api_json_get "$json" "user")
  _TITLE_EDITOR_API_DOMAIN=$(_title_editor_api_json_get "$json" "domain")
  _TITLE_EDITOR_API_TENANT_ID=$(_title_editor_api_json_get "$json" "tenantId")
}

# Obtain a new token from the server using username + password (Basic auth).
# Expects _TITLE_EDITOR_API_USER, _TITLE_EDITOR_API_PW (base64), and _TITLE_EDITOR_API_BASE_URL to be set.
_title_editor_api_init_from_pw() {
  local decoded_pw
  local init_rc=0
  decoded_pw=$(echo "${_TITLE_EDITOR_API_PW}" | base64 --decode)

  _title_editor_api_curl \
    --request POST \
    --user "${_TITLE_EDITOR_API_USER}:${decoded_pw}" \
    "${_TITLE_EDITOR_API_BASE_URL}/${TITLE_EDITOR_API_NEW_TOKEN_RSRC}"

  case "${_TITLE_EDITOR_API_HTTP_STATUS}" in
    200|201)
      _TITLE_EDITOR_API_TOKEN=$(_title_editor_api_json_get "${_TITLE_EDITOR_API_HTTP_BODY}" "token")
      _title_editor_api_parse_token_status
      _TITLE_EDITOR_API_LAST_REFRESH=$(date +%s)
      ;;
    401)
      _title_editor_api_raise $TITLE_EDITOR_API_ERR_AUTH "Incorrect user name or password"
      init_rc=$?
      ;;
    *)
      _title_editor_api_raise $TITLE_EDITOR_API_ERR_CONNECTION \
        "An error occurred while authenticating: ${_TITLE_EDITOR_API_HTTP_BODY}"
      init_rc=$?
      ;;
  esac

  # Clear pw unless pw_fallback is enabled
  [[ "${_TITLE_EDITOR_API_PW_FALLBACK}" == "false" ]] && _TITLE_EDITOR_API_PW=""

  return "$init_rc"
}

# Initialize a connection from an existing token string.
# @param $1  The token string
_title_editor_api_init_from_token_string() {
  _TITLE_EDITOR_API_TOKEN="$1"
  _title_editor_api_parse_token_status  # validates the token and sets expiry/user etc.

  # If we have a pw and pw_fallback, validate the pw by getting a fresh token
  if [[ -n "${_TITLE_EDITOR_API_PW}" && "${_TITLE_EDITOR_API_PW_FALLBACK}" == "true" ]]; then
    _title_editor_api_init_from_pw
    return
  fi

  # Otherwise, refresh to get a full-lifetime token
  _title_editor_api_token_refresh
}

# Refresh the current token.
title_editor_api_token_refresh() { _title_editor_api_token_refresh; }
_title_editor_api_token_refresh() {
  local now
  now=$(date +%s)

  # Already expired?
  if (( now >= _TITLE_EDITOR_API_TOKEN_EXPIRES )); then
    if [[ -n "${_TITLE_EDITOR_API_PW}" ]]; then
      _title_editor_api_init_from_pw
    else
      _title_editor_api_raise $TITLE_EDITOR_API_ERR_INVALID_TOKEN "Token has expired and no pw_fallback available"
    fi
    return
  fi

  # Normal refresh
  _title_editor_api_curl \
    --request POST \
    "${_TITLE_EDITOR_API_BASE_URL}/${TITLE_EDITOR_API_REFRESH_RSRC}"

  if [[ "${_TITLE_EDITOR_API_HTTP_STATUS}" == "200" ]]; then
    _TITLE_EDITOR_API_TOKEN=$(_title_editor_api_json_get "${_TITLE_EDITOR_API_HTTP_BODY}" "token")
    _title_editor_api_parse_token_status
    _TITLE_EDITOR_API_LAST_REFRESH=$(date +%s)
    return
  fi

  # Refresh failed — try the password
  if [[ -n "${_TITLE_EDITOR_API_PW}" ]]; then
    _title_editor_api_init_from_pw
    return
  fi

  _title_editor_api_raise $TITLE_EDITOR_API_ERR_INVALID_TOKEN "An error occurred while refreshing the token"
}

# Seconds until the token should be refreshed.
# @stdout  Integer seconds (0 if already past the refresh point)
title_editor_api_secs_to_refresh() {
  local now
  now=$(date +%s)
  local refresh_at=$(( _TITLE_EDITOR_API_TOKEN_EXPIRES - TITLE_EDITOR_API_TOKEN_REFRESH_BUFFER ))
  local secs=$(( refresh_at - now ))
  (( secs < 0 )) && secs=0
  echo "$secs"
}

# Is the token currently expired?
# @return  0 (true) if expired, 1 (false) if not
title_editor_api_token_expired() {
  local now
  now=$(date +%s)
  (( now >= _TITLE_EDITOR_API_TOKEN_EXPIRES ))
}

# Invalidate the current token and clear all credentials.
title_editor_api_invalidate_token() {
  _title_editor_api_stop_keep_alive
  _TITLE_EDITOR_API_TOKEN=""
  _TITLE_EDITOR_API_PW=""
  _TITLE_EDITOR_API_TOKEN_EXPIRES=0
}

###############################################################################
# KEEP-ALIVE  (mirrors Token#start_keep_alive / stop_keep_alive)
###############################################################################

# Start a background process that refreshes the token before it expires.
_title_editor_api_start_keep_alive() {
  [[ -n "${_TITLE_EDITOR_API_KEEP_ALIVE_PID}" ]] && return  # already running

  # Export state needed by the background process via a temp script
  local state_file
  state_file=$(mktemp /tmp/teac_state.XXXXXX)

  (
    while true; do
      sleep 60
      secs=$(title_editor_api_secs_to_refresh 2>/dev/null || echo 0)
      if (( secs <= 0 )); then
        _title_editor_api_token_refresh 2>/dev/null || true
        # Write updated token to state file so the parent can re-source
        echo "_TITLE_EDITOR_API_TOKEN='${_TITLE_EDITOR_API_TOKEN}'" > "$state_file"
        echo "_TITLE_EDITOR_API_TOKEN_EXPIRES='${_TITLE_EDITOR_API_TOKEN_EXPIRES}'" >> "$state_file"
      fi
    done
  ) &

  _TITLE_EDITOR_API_KEEP_ALIVE_PID=$!
}

# Stop the keep-alive background process.
_title_editor_api_stop_keep_alive() {
  if [[ -n "${_TITLE_EDITOR_API_KEEP_ALIVE_PID}" ]]; then
    kill "${_TITLE_EDITOR_API_KEEP_ALIVE_PID}" 2>/dev/null || true
    _TITLE_EDITOR_API_KEEP_ALIVE_PID=""
  fi
}

###############################################################################
# CONNECTION CONTROL
###############################################################################

# Ensure we are connected; raise an error if not.
title_editor_api_validate_connected() {
  if [[ "${_TITLE_EDITOR_API_CONNECTED}" != "true" ]]; then
    _title_editor_api_raise $TITLE_EDITOR_API_ERR_NOT_CONNECTED \
      "Not connected. Use title_editor_api_connect first."
  fi
}

# Disconnect: tear down the token and clear all state.
# mirrors Connection#disconnect / logout
title_editor_api_disconnect() {
  _title_editor_api_stop_keep_alive
  _TITLE_EDITOR_API_TOKEN=""
  _TITLE_EDITOR_API_PW=""
  _TITLE_EDITOR_API_CONNECTED=false
  _TITLE_EDITOR_API_HOST=""
  _TITLE_EDITOR_API_PORT=""
  _TITLE_EDITOR_API_USER=""
  _TITLE_EDITOR_API_BASE_URL=""
  _TITLE_EDITOR_API_TOKEN_EXPIRES=0
  _TITLE_EDITOR_API_CONNECT_TIME=""
  echo "disconnected"
}
alias title_editor_api_logout=title_editor_api_disconnect

# Connect to a Title Editor server.
# mirrors Connection#connect
#
# Usage:
#   title_editor_api_connect [URL] [options]
#
# URL (optional):
#   https://[user[:password]@]host[:port]
#   If provided, host/port/user/pw are extracted from it.
#
# Options (as environment variables or keyword-style args):
#   TITLE_EDITOR_API_HOST, TITLE_EDITOR_API_PORT, TITLE_EDITOR_API_USER, TITLE_EDITOR_API_PW
#   TITLE_EDITOR_API_TOKEN_STRING (use instead of user+pw)
#   TITLE_EDITOR_API_TIMEOUT, TITLE_EDITOR_API_OPEN_TIMEOUT
#   TITLE_EDITOR_API_VERIFY_CERT (true/false)
#   TITLE_EDITOR_API_KEEP_ALIVE  (true/false)
#   TITLE_EDITOR_API_PW_FALLBACK (true/false)
#   TITLE_EDITOR_API_NAME
#
# All of the above fall back to values in title_editor_api.conf if not provided.
#
title_editor_api_connect() {
  local url="${1:-}"

  # Reset state
  title_editor_api_disconnect 2>/dev/null || true

  # Load config defaults first
  title_editor_api_load_config

  # --- Parse URL if provided ---
  if [[ -n "$url" ]]; then
    # Must be https
    if [[ "$url" != https://* ]]; then
      _title_editor_api_raise $TITLE_EDITOR_API_ERR_MISSING_DATA "Invalid url, scheme must be https"
    fi

    # Extract user:pw@host:port/path from URL
    # Strip scheme
    local stripped="${url#https://}"
    local userinfo="" hostpart=""

    if [[ "$stripped" == *@* ]]; then
      userinfo="${stripped%%@*}"
      hostpart="${stripped#*@}"
    else
      hostpart="$stripped"
    fi

    # Remove any path component after host:port
    hostpart="${hostpart%%/*}"

    if [[ -n "$userinfo" ]]; then
      TITLE_EDITOR_API_USER="${userinfo%%:*}"
      local urlpw="${userinfo#*:}"
      [[ "$urlpw" != "$userinfo" ]] && TITLE_EDITOR_API_PW="${urlpw}"
    fi

    if [[ "$hostpart" == *:* ]]; then
      TITLE_EDITOR_API_HOST="${hostpart%%:*}"
      TITLE_EDITOR_API_PORT="${hostpart##*:}"
    else
      TITLE_EDITOR_API_HOST="$hostpart"
    fi
  fi

  # --- Apply overrides from env/caller vars to state ---
  [[ -n "${TITLE_EDITOR_API_HOST:-}"         ]] && _TITLE_EDITOR_API_HOST="${TITLE_EDITOR_API_HOST}"
  [[ -n "${TITLE_EDITOR_API_PORT:-}"         ]] && _TITLE_EDITOR_API_PORT="${TITLE_EDITOR_API_PORT}"
  [[ -n "${TITLE_EDITOR_API_USER:-}"         ]] && _TITLE_EDITOR_API_USER="${TITLE_EDITOR_API_USER}"
  [[ -n "${TITLE_EDITOR_API_TIMEOUT:-}"      ]] && _TITLE_EDITOR_API_TIMEOUT="${TITLE_EDITOR_API_TIMEOUT}"
  [[ -n "${TITLE_EDITOR_API_OPEN_TIMEOUT:-}" ]] && _TITLE_EDITOR_API_OPEN_TIMEOUT="${TITLE_EDITOR_API_OPEN_TIMEOUT}"
  [[ -n "${TITLE_EDITOR_API_SSL_VERSION:-}"  ]] && _TITLE_EDITOR_API_SSL_VERSION="${TITLE_EDITOR_API_SSL_VERSION}"
  [[ -n "${TITLE_EDITOR_API_NAME:-}"         ]] && _TITLE_EDITOR_API_NAME="${TITLE_EDITOR_API_NAME}"

  if [[ "${TITLE_EDITOR_API_VERIFY_CERT:-true}" == "false" ]]; then
    _TITLE_EDITOR_API_VERIFY_CERT=false
  fi
  if [[ "${TITLE_EDITOR_API_KEEP_ALIVE:-true}" == "false" ]]; then
    _TITLE_EDITOR_API_KEEP_ALIVE=false
  fi
  if [[ "${TITLE_EDITOR_API_PW_FALLBACK:-true}" == "false" ]]; then
    _TITLE_EDITOR_API_PW_FALLBACK=false
  fi

  # --- Apply module defaults ---
  _TITLE_EDITOR_API_PORT="${_TITLE_EDITOR_API_PORT:-${TITLE_EDITOR_API_SSL_PORT}}"
  _TITLE_EDITOR_API_TIMEOUT="${_TITLE_EDITOR_API_TIMEOUT:-${TITLE_EDITOR_API_DFT_TIMEOUT}}"
  _TITLE_EDITOR_API_OPEN_TIMEOUT="${_TITLE_EDITOR_API_OPEN_TIMEOUT:-${TITLE_EDITOR_API_DFT_OPEN_TIMEOUT}}"
  _TITLE_EDITOR_API_SSL_VERSION="${_TITLE_EDITOR_API_SSL_VERSION:-${TITLE_EDITOR_API_DFT_SSL_VERSION}}"

  # --- Validate required params ---
  if [[ -z "${_TITLE_EDITOR_API_HOST}" ]]; then
    _title_editor_api_raise $TITLE_EDITOR_API_ERR_MISSING_DATA \
      "No host specified in params, URL, or configuration."
  fi

  local token_string="${TITLE_EDITOR_API_TOKEN_STRING:-}"

  if [[ -z "$token_string" ]]; then
    if [[ -z "${_TITLE_EDITOR_API_USER}" ]]; then
      _title_editor_api_raise $TITLE_EDITOR_API_ERR_MISSING_DATA \
        "No user or token_string specified in params or configuration."
    fi

    # Get password: from env, or prompt if connected to a TTY
    local pw="${TITLE_EDITOR_API_PW:-}"
    if [[ -z "$pw" ]]; then
      if [[ -t 0 ]]; then
        stty -echo 2>/dev/null
        echo -n "Enter the password for ${_TITLE_EDITOR_API_USER}@${_TITLE_EDITOR_API_HOST}: " >&2
        read -r pw
        stty echo 2>/dev/null
        echo >&2
      else
        _title_editor_api_raise $TITLE_EDITOR_API_ERR_MISSING_DATA \
          "No password specified for user '${_TITLE_EDITOR_API_USER}'"
      fi
    fi
    _TITLE_EDITOR_API_PW=$(echo -n "$pw" | base64)
  fi

  # --- Build base URL ---
  _TITLE_EDITOR_API_BASE_URL="${TITLE_EDITOR_API_HTTPS_SCHEME}://${_TITLE_EDITOR_API_HOST}"
  [[ -n "${_TITLE_EDITOR_API_PORT}" && "${_TITLE_EDITOR_API_PORT}" != "${TITLE_EDITOR_API_SSL_PORT}" ]] \
    && _TITLE_EDITOR_API_BASE_URL="${_TITLE_EDITOR_API_BASE_URL}:${_TITLE_EDITOR_API_PORT}"
  _TITLE_EDITOR_API_BASE_URL="${_TITLE_EDITOR_API_BASE_URL}/${TITLE_EDITOR_API_RSRC_VERSION}"

  # --- Obtain token ---
  if [[ -n "$token_string" ]]; then
    _title_editor_api_init_from_token_string "$token_string" || return $?
  else
    _title_editor_api_init_from_pw || return $?
  fi

  # --- Finalise ---
  _TITLE_EDITOR_API_CONNECTED=true
  _TITLE_EDITOR_API_CONNECT_TIME=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
  _TITLE_EDITOR_API_NAME="${_TITLE_EDITOR_API_NAME:-${_TITLE_EDITOR_API_USER}@${_TITLE_EDITOR_API_HOST}:${_TITLE_EDITOR_API_PORT}}"

  [[ "${_TITLE_EDITOR_API_KEEP_ALIVE}" == "true" ]] && _title_editor_api_start_keep_alive

  title_editor_api_to_s
}
alias title_editor_api_login=title_editor_api_connect

# Return a human-readable description of the current connection.
title_editor_api_to_s() {
  if [[ "${_TITLE_EDITOR_API_CONNECTED}" != "true" ]]; then
    echo "not connected"
  else
    echo "${_TITLE_EDITOR_API_NAME} (connected ${_TITLE_EDITOR_API_CONNECT_TIME})"
  fi
}

###############################################################################
# API ACTIONS
###############################################################################

# GET a resource.
# @param $1   Resource path (e.g. "softwaretitles" or "patches/42")
# @stdout     Response body (JSON)
title_editor_api_get() {
  local rsrc="$1"
  title_editor_api_validate_connected

  _title_editor_api_curl --request GET "${_TITLE_EDITOR_API_BASE_URL}/${rsrc}"

  if [[ "${_TITLE_EDITOR_API_HTTP_STATUS}" =~ ^2 ]]; then
    echo "${_TITLE_EDITOR_API_HTTP_BODY}"
  else
    _title_editor_api_handle_http_error "${_TITLE_EDITOR_API_HTTP_STATUS}" "${_TITLE_EDITOR_API_HTTP_BODY}"
  fi
}

# POST (create) a resource.
# @param $1   Resource path
# @param $2   JSON body
# @stdout     Response body (JSON)
title_editor_api_post() {
  local rsrc="$1"
  local body="$2"
  title_editor_api_validate_connected

  _title_editor_api_curl \
    --request POST \
    --data "$body" \
    "${_TITLE_EDITOR_API_BASE_URL}/${rsrc}"

  if [[ "${_TITLE_EDITOR_API_HTTP_STATUS}" =~ ^2 ]]; then
    echo "${_TITLE_EDITOR_API_HTTP_BODY}"
  else
    _title_editor_api_handle_http_error "${_TITLE_EDITOR_API_HTTP_STATUS}" "${_TITLE_EDITOR_API_HTTP_BODY}"
  fi
}

# PUT (update) a resource.
# @param $1   Resource path
# @param $2   JSON body
# @stdout     Response body (JSON)
title_editor_api_put() {
  local rsrc="$1"
  local body="$2"
  title_editor_api_validate_connected

  _title_editor_api_curl \
    --request PUT \
    --data "$body" \
    "${_TITLE_EDITOR_API_BASE_URL}/${rsrc}"

  if [[ "${_TITLE_EDITOR_API_HTTP_STATUS}" =~ ^2 ]]; then
    echo "${_TITLE_EDITOR_API_HTTP_BODY}"
  else
    _title_editor_api_handle_http_error "${_TITLE_EDITOR_API_HTTP_STATUS}" "${_TITLE_EDITOR_API_HTTP_BODY}"
  fi
}

# DELETE a resource.
# @param $1   Resource path
# @stdout     Response body (JSON)
title_editor_api_delete() {
  local rsrc="$1"
  title_editor_api_validate_connected

  _title_editor_api_curl \
    --request DELETE \
    "${_TITLE_EDITOR_API_BASE_URL}/${rsrc}"

  if [[ "${_TITLE_EDITOR_API_HTTP_STATUS}" =~ ^2 ]]; then
    echo "${_TITLE_EDITOR_API_HTTP_BODY}"
  else
    _title_editor_api_handle_http_error "${_TITLE_EDITOR_API_HTTP_STATUS}" "${_TITLE_EDITOR_API_HTTP_BODY}"
  fi
}

###############################################################################
# CONVERTERS  (misc helpers for converting between API formats and more convenient forms)
###############################################################################

# Convert a unix timestamp to an ISO8601 UTC string.
# @param $1  Unix timestamp
# @stdout    ISO8601 string, e.g. "2025-03-05T12:00:00Z"
title_editor_api_time_to_api() {
  date -u -r "$1" +"%Y-%m-%dT%H:%M:%SZ" 2>/dev/null \
    || date -u -d "@$1" +"%Y-%m-%dT%H:%M:%SZ"  # Linux fallback
}

# Convert an ISO8601 string to a unix timestamp.
# @param $1  ISO8601 date string
# @stdout    Unix timestamp
title_editor_api_to_time() {
  if date -j -f "%Y-%m-%dT%H:%M:%SZ" "$1" +%s 2>/dev/null; then
    :  # macOS
  else
    date -d "$1" +%s  # Linux
  fi
}

###############################################################################
# CRITERIA HELPERS
###############################################################################

# Get the list of available criterion names from the server.
# @stdout  JSON array of criterion names
title_editor_api_criteria_available_names() {
  title_editor_api_get "valuelists/criteria/names"
}

# Get the list of available criterion types from the server.
# @stdout  JSON array of criterion types
title_editor_api_criteria_available_types() {
  title_editor_api_get "valuelists/criteria/types"
}

# Get the list of available operators for a given criterion name.
# @param $1  Criterion name, e.g. "Application Title"
# @stdout    JSON array of operator strings
title_editor_api_criteria_operators_for() {
  local name="$1"
  title_editor_api_post "valuelists/criteria/operators" "{\"name\": \"${name}\"}"
}

###############################################################################
# SOFTWARE TITLE CONVENIENCE WRAPPERS
# (mirrors common usage patterns from the Ruby library)
###############################################################################

# Fetch all software titles (list view).
# @stdout  JSON
title_editor_api_list_titles() {
  title_editor_api_get "softwaretitles"
}

# Fetch a single software title by its string id or name.
# The API requires the numeric softwareTitleId, so we look it up first.
# @param $1  String id (e.g. "PaloAltoNetworksGlobalProtect") or partial name
# @stdout    JSON
title_editor_api_fetch_title() {
  local ident="$1"
  local list
  list=$(title_editor_api_list_titles)

  # The JSON structure per entry is:
  #   "softwareTitleId": <number>,   <- line 1
  #   ...
  #   "name": "...",                 <- a few lines later
  #   ...
  #   "id": "PaloAltoNetworks...",   <- near the end of the entry
  #
  # Strategy: find the line number of the matching id or name,
  # then search backwards for the softwareTitleId

  local numeric_id
  # Try exact string id match first
  numeric_id=$(echo "$list" | awk -v id=""${ident}"" '
    /softwareTitleId/ { last_id=$0; gsub(/[^0-9]/, "", last_id) }
    /"id":/ && index($0, id) { print last_id; exit }
  ')

  # If not found, try case-insensitive name match
  if [[ -z "$numeric_id" ]]; then
    local lower_ident
    lower_ident=$(echo "$ident" | tr '[:upper:]' '[:lower:]')
    numeric_id=$(echo "$list" | awk -v name="${lower_ident}" '
      /softwareTitleId/ { last_id=$0; gsub(/[^0-9]/, "", last_id) }
      /"name":/ {
        line=$0
        gsub(/.*"name": "/, "", line)
        gsub(/".*/, "", line)
        # lowercase
        cmd = "echo " line " | tr [:upper:] [:lower:]"
        cmd | getline lline
        close(cmd)
        if (index(lline, name)) { print last_id; exit }
      }
    ')
  fi

  if [[ -z "$numeric_id" ]]; then
    echo "TitleEditorAPI::NoSuchItemError: No title found matching '${ident}'" >&2
    return $TITLE_EDITOR_API_ERR_NO_SUCH_ITEM
  fi

  title_editor_api_get "softwaretitles/${numeric_id}"
}

# Delete a software title by ID.
# @param $1  Title ID
title_editor_api_delete_title() {
  local id="$1"
  title_editor_api_delete "softwaretitles/${id}"
}

# Fetch all patches for a software title.
# @param $1  Software title ID
# @stdout    JSON
title_editor_api_list_patches() {
  local title_id="$1"
  title_editor_api_get "softwaretitles/${title_id}/patches"
}

# Fetch a single patch.
# @param $1  Patch ID
# @stdout    JSON
title_editor_api_fetch_patch() {
  local patch_id="$1"
  title_editor_api_get "patches/${patch_id}"
}

# Delete a patch.
# @param $1  Patch ID
title_editor_api_delete_patch() {
  local patch_id="$1"
  title_editor_api_delete "patches/${patch_id}"
}

###############################################################################
# MAIN (only runs if executed directly, not sourced)
###############################################################################
if [[ "${BASH_SOURCE[0]:-}" == "${0}" ]]; then
  cat <<'EOF'
title_editor_api_ctrl.sh  - A bash script for connecting to the Title Editor API and making requests.

Usage:
  source title_editor_api_ctrl.sh

  # Connect
  title_editor_api_connect "https://<user>:<password>@<server-host>"

  # Or use export variables (required when sourced in zsh/bash):
  export TITLE_EDITOR_API_HOST=<server-host>
  export TITLE_EDITOR_API_USER=<user>
  export TITLE_EDITOR_API_PW=<password>  # omit to be prompted securely
  title_editor_api_connect

  # API calls
  title_editor_api_get "softwaretitles"
  title_editor_api_post "softwaretitles" '{"name":"MyApp",...}'
  title_editor_api_put  "patches/42"     '{"version":"1.2.3"}'
  title_editor_api_delete "patches/42"

  # Token management
  title_editor_api_token_refresh
  title_editor_api_secs_to_refresh
  title_editor_api_token_expired && echo "Token is expired"

  # Configuration
  title_editor_api_load_config
  title_editor_api_save_config user
  title_editor_api_print_config

  # Disconnect
  title_editor_api_disconnect

See inline comments for full documentation of each function.
EOF
fi
