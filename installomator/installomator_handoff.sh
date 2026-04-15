#!/usr/bin/env bash
set -euo pipefail

# installomator_handoff.sh
#
# Version: 1.0.0
# Revised Date: 2026.04.15
#
# Run Installomator for a label, then hand off to update_title_editor_versions.sh
# only when Installomator indicates an install/update action occurred.
#
# Designed for Jamf/root usage without modifying Installomator itself.
# If running as root, the Title Editor handoff is executed as the logged-in console user
# because update_title_editor_versions.sh does not allow root execution.
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
DEFAULT_UPDATE_SCRIPT="${SCRIPT_DIR}/../update_title_editor_versions.sh"
SCRIPT_VERSION="1.0.0"

INSTALL_LABEL=""
TITLE_EDITOR_ITEM=""
INSTALLOMATOR_CMD=""
INSTALLOMATOR_ARGS=""
UPDATE_SCRIPT_PATH="$DEFAULT_UPDATE_SCRIPT"
HANDOFF_MODE="signal-only"    # signal-only | apply-current
ALWAYS_HANDOFF=0               # 0 = only when update detected
SKIP_IF_NO_USER=1              # if root and no console user, skip by default
DEBUG=0
TMP_LOG_FILE=""

log() { printf '%s %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*"; }
warn() { printf '%s WARN: %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" >&2; }
die() { printf '%s ERROR: %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" >&2; exit 1; }

show_help() {
  cat <<EOF
Usage:
  bash installomator/installomator_handoff.sh --label <installomator_label> [options]

Metadata:
  Version: ${SCRIPT_VERSION}
  Revised Date: 2026.04.15

Required:
  --label <label>              Installomator label (example: firefox)

Optional:
  --item <key>                 Title Editor item key (default: same as --label)
  --installomator-cmd <path>   Installomator script/command path
  --installomator-args <args>  Extra Installomator args as one quoted string
  --update-script <path>       Path to update_title_editor_versions.sh
  --handoff-mode <mode>        signal-only|apply-current (default: signal-only)
  --always-handoff             Run Title Editor handoff even if no Installomator update detected
  --fail-if-no-user            If root and no console user exists, fail instead of skip
  --debug                      Verbose diagnostics
  -h, --help                   Show help

Examples:
  # Signal only (no import/state write), only if Installomator updated
  bash installomator/installomator_handoff.sh \
    --label firefox \
    --item firefox \
    --handoff-mode signal-only

  # Apply-current handoff
  bash installomator/installomator_handoff.sh \
    --label firefox \
    --item firefox \
    --handoff-mode apply-current
EOF
}

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --label)
        INSTALL_LABEL="${2:-}"
        shift 2
        ;;
      --item)
        TITLE_EDITOR_ITEM="${2:-}"
        shift 2
        ;;
      --installomator-cmd)
        INSTALLOMATOR_CMD="${2:-}"
        shift 2
        ;;
      --installomator-args)
        INSTALLOMATOR_ARGS="${2:-}"
        shift 2
        ;;
      --update-script)
        UPDATE_SCRIPT_PATH="${2:-}"
        shift 2
        ;;
      --handoff-mode)
        HANDOFF_MODE="${2:-}"
        shift 2
        ;;
      --always-handoff)
        ALWAYS_HANDOFF=1
        shift
        ;;
      --fail-if-no-user)
        SKIP_IF_NO_USER=0
        shift
        ;;
      --debug)
        DEBUG=1
        shift
        ;;
      -h|--help)
        show_help
        exit 0
        ;;
      *)
        die "Unknown argument: $1"
        ;;
    esac
  done

  [[ -n "$INSTALL_LABEL" ]] || die "--label is required"
  [[ -n "$TITLE_EDITOR_ITEM" ]] || TITLE_EDITOR_ITEM="$INSTALL_LABEL"

  case "$HANDOFF_MODE" in
    signal-only|apply-current) ;;
    *) die "--handoff-mode must be signal-only or apply-current" ;;
  esac

  [[ -f "$UPDATE_SCRIPT_PATH" ]] || die "Update script not found: $UPDATE_SCRIPT_PATH"
}

resolve_installomator_cmd() {
  if [[ -n "$INSTALLOMATOR_CMD" ]]; then
    [[ -x "$INSTALLOMATOR_CMD" || -f "$INSTALLOMATOR_CMD" ]] || die "Installomator command not found: $INSTALLOMATOR_CMD"
    echo "$INSTALLOMATOR_CMD"
    return
  fi

  local candidate
  for candidate in Installomator Installomator.sh \
                   /usr/local/Installomator/Installomator.sh \
                   /usr/local/bin/Installomator.sh \
                   /usr/local/bin/Installomator; do
    if command -v "$candidate" >/dev/null 2>&1; then
      command -v "$candidate"
      return
    fi
    if [[ -x "$candidate" ]]; then
      echo "$candidate"
      return
    fi
  done

  die "Could not locate Installomator. Use --installomator-cmd <path>."
}

run_installomator() {
  local install_cmd="$1"
  local log_file="$2"
  local -a cmd

  cmd=("$install_cmd" "$INSTALL_LABEL")
  if [[ -n "$INSTALLOMATOR_ARGS" ]]; then
    # shellcheck disable=SC2206
    local extra=( $INSTALLOMATOR_ARGS )
    cmd+=("${extra[@]}")
  fi

  log "Running Installomator label: $INSTALL_LABEL"
  log "Command: ${cmd[*]}"

  set +e
  "${cmd[@]}" >"$log_file" 2>&1
  local rc=$?
  set -e

  # Replay captured output for logs/MDM policy output.
  if [[ -s "$log_file" ]]; then
    cat "$log_file"
  fi

  if [[ $rc -ne 0 ]]; then
    die "Installomator failed with exit code $rc"
  fi
}

installomator_did_update() {
  local log_file="$1"
  # Heuristic markers indicating real update/install activity.
  grep -Eq ': REQ\s*:.*:\s*(Downloading|Installing)\b|: REQ\s*:.*:\s*Running updateTool\b' "$log_file"
}

extract_updated_version() {
  local log_file="$1"
  local version=""

  version="$(sed -nE 's/.*appNewVersion[:[:space:]]+([^[:space:]]+).*/\1/p' "$log_file" | tail -n1)"
  if [[ -z "$version" ]]; then
    version="$(sed -nE 's/.*Latest version[^0-9]*([0-9]+(\.[0-9A-Za-z-]+)+).*/\1/p' "$log_file" | tail -n1)"
  fi

  [[ -n "$version" ]] && echo "$version" || true
}

console_user() {
  local user
  user="$(/usr/sbin/scutil <<< "show State:/Users/ConsoleUser" | awk '/Name :/ {print $3}')"
  if [[ -z "$user" || "$user" == "loginwindow" || "$user" == "root" ]]; then
    return 1
  fi
  echo "$user"
}

run_handoff() {
  local -a handoff_cmd
  handoff_cmd=("bash" "$UPDATE_SCRIPT_PATH" "--item" "$TITLE_EDITOR_ITEM" "--current-only")

  if [[ "$HANDOFF_MODE" == "signal-only" ]]; then
    handoff_cmd+=("--no-import" "--no-apply")
  fi

  if [[ "${EUID:-$(id -u)}" -eq 0 ]]; then
    local user uid
    if ! user="$(console_user)"; then
      if [[ "$SKIP_IF_NO_USER" -eq 1 ]]; then
        warn "No logged-in console user found; skipping Title Editor handoff."
        return 0
      fi
      die "No logged-in console user found and --fail-if-no-user is set."
    fi

    uid="$(id -u "$user")"
    log "Running handoff as console user: $user (uid: $uid)"
    launchctl asuser "$uid" sudo -u "$user" "${handoff_cmd[@]}"
  else
    log "Running handoff as current user: $(id -un)"
    "${handoff_cmd[@]}"
  fi
}

main() {
  parse_args "$@"

  local install_cmd
  install_cmd="$(resolve_installomator_cmd)"

  TMP_LOG_FILE="$(mktemp /tmp/installomator_handoff.XXXXXX)"
  trap 'rm -f "$TMP_LOG_FILE" >/dev/null 2>&1 || true' EXIT

  run_installomator "$install_cmd" "$TMP_LOG_FILE"

  local updated=0
  if installomator_did_update "$TMP_LOG_FILE"; then
    updated=1
    log "Installomator indicates update/install activity."
  else
    log "Installomator did not report update/install activity."
  fi

  local detected_version
  detected_version="$(extract_updated_version "$TMP_LOG_FILE" || true)"
  if [[ -n "$detected_version" ]]; then
    log "Detected version from Installomator output: $detected_version"
  elif [[ "$DEBUG" -eq 1 ]]; then
    warn "Could not extract a version string from Installomator output."
  fi

  if [[ "$ALWAYS_HANDOFF" -eq 1 || "$updated" -eq 1 ]]; then
    run_handoff
    log "Title Editor handoff completed."
  else
    log "Skipping Title Editor handoff (no update detected). Use --always-handoff to override."
  fi
}

main "$@"
