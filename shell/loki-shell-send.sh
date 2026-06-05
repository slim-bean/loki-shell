#!/bin/sh
# loki-shell-send.sh - Send shell commands to Loki via curl+jq with spool file WAL
# This file is sourced by loki-shell.bash and loki-shell.zsh

_loki_spool="${LOKI_SHELL_DIR:-$HOME/.loki-shell}/data/spool"
_loki_drop_patterns="${LOKI_SHELL_DIR:-$HOME/.loki-shell}/config/drop-patterns"
_loki_log_file="${LOKI_SHELL_DIR:-$HOME/.loki-shell}/data/loki-shell.log"
_loki_log_max_bytes=1048576  # 1MB max log size

# Log a message with timestamp to the log file and stdout (which gets piped
# to the system logger by the caller).  Automatically rotates the log file
# when it exceeds $_loki_log_max_bytes.
_loki_log() {
  local msg="$(date '+%Y-%m-%d %H:%M:%S') $*"
  echo "$msg"
  # Rotate if log file exceeds max size
  if [ -f "$_loki_log_file" ]; then
    local size
    size=$(wc -c < "$_loki_log_file" 2>/dev/null | tr -d ' ')
    if [ "${size:-0}" -gt "$_loki_log_max_bytes" ] 2>/dev/null; then
      mv -f "$_loki_log_file" "${_loki_log_file}.old"
    fi
  fi
  echo "$msg" >> "$_loki_log_file" 2>/dev/null
}

# Find jq: prefer system jq, fall back to bundled copy
if command -v jq > /dev/null 2>&1; then
  _loki_jq="jq"
elif [ -x "${LOKI_SHELL_DIR:-$HOME/.loki-shell}/bin/jq" ]; then
  _loki_jq="${LOKI_SHELL_DIR:-$HOME/.loki-shell}/bin/jq"
else
  echo "loki-shell: jq not found, commands will not be sent to Loki" >&2
  _loki_jq=""
fi

# Unescape a spool command field: \n → newline, \\ → \
# Uses jq filter syntax (applied inside _loki_build_payload).
_loki_jq_unescape='gsub("\\\\\\\\";"")|gsub("\\\\n";"\n")|gsub("";"\\")'  # \\ → RS, \n → NL, RS → \

# Build a Loki push API JSON payload from spool lines and/or a new entry.
# Each line in the spool file is: <nanosecond_timestamp>\t<escaped_command>
# Commands are escaped: \\ → \\\\, newline → \\n  (reversed on read).
# Lines without a tab are silently skipped (malformed).
# Arguments: $1 = host, $2/$3 = new timestamp/command (optional), $4 = spool file
_loki_build_payload() {
  local host="$1" new_ts="$2" new_cmd="$3" spool_file="$4"

  if [ -n "$spool_file" ] && [ -s "$spool_file" ]; then
    if [ -n "$new_ts" ]; then
      # Spool entries + new command
      $_loki_jq -Rc --arg host "$host" --arg new_ts "$new_ts" --arg new_cmd "$new_cmd" '
        if contains("\t") then
          split("\t") | [.[0], (.[1:] | join("\t") | '"$_loki_jq_unescape"')]
        else empty end
      ' "$spool_file" | $_loki_jq -sc --arg host "$host" --arg new_ts "$new_ts" --arg new_cmd "$new_cmd" '
        . + [[$new_ts, $new_cmd]] |
        {"streams":[{"stream":{"job":"shell","host":$host},"values": map([.[0], .[1]])}]}
      '
    else
      # Spool entries only
      $_loki_jq -Rc --arg host "$host" '
        if contains("\t") then
          split("\t") | [.[0], (.[1:] | join("\t") | '"$_loki_jq_unescape"')]
        else empty end
      ' "$spool_file" | $_loki_jq -sc --arg host "$host" '
        {"streams":[{"stream":{"job":"shell","host":$host},"values": map([.[0], .[1]])}]}
      '
    fi
  else
    # New command only
    $_loki_jq -nc --arg host "$host" --arg ts "$new_ts" --arg cmd "$new_cmd" '
      {"streams":[{"stream":{"job":"shell","host":$host},"values":[[$ts,$cmd]]}]}
    '
  fi
}

# Append a command to the spool file
# $1 = nanosecond timestamp, $2 = command
# Escapes backslashes and newlines so each entry is exactly one line.
_loki_spool_append() {
  local escaped="${2//\\/\\\\}"    # \ → \\\\
  escaped="${escaped//$'\n'/\\n}"   # newline → \\n
  printf '%s\t%s\n' "$1" "$escaped" >> "$_loki_spool"
}

# Send command to Loki, managing the spool file for ordering guarantees.
# $1 = Loki URL (e.g. http://localhost:4100)
# $2 = hostname
# $3 = command to send
_loki_send() {
  local loki_url="$1" host="$2" cmd="$3"
  local ts payload

  if [ -z "$_loki_jq" ]; then
    _loki_log "ERROR: jq not found, cannot send command"
    return 1
  fi

  # Drop commands matching any pattern in the drop-patterns file
  if [ -s "$_loki_drop_patterns" ]; then
    local line_num=0 pattern context=""
    while IFS= read -r pattern; do
      line_num=$((line_num + 1))
      # Track comment lines as context for the next pattern
      case "$pattern" in
        '#'*) context="$pattern"; continue ;;
        '')   continue ;;
      esac
      if printf '%s' "$cmd" | grep -qE -- "$pattern" 2>/dev/null; then
        local drop_msg="dropped command matching drop-patterns line $line_num${context:+ $context}"
        _loki_log "$drop_msg"
        local drop_ts="$(date +%s)000000000"
        local drop_payload=$($_loki_jq -nc --arg host "$host" --arg ts "$drop_ts" --arg msg "$drop_msg" \
          '{"streams":[{"stream":{"job":"shell","host":$host,"dropped":"true"},"values":[[$ts,$msg]]}]}')
        curl -sf -o /dev/null -X POST -H "Content-Type: application/json" \
          "$loki_url/loki/api/v1/push" -d "$drop_payload" 2>/dev/null
        return 0
      fi
      context=""
    done < "$_loki_drop_patterns"
  fi

  # Nanosecond timestamp: epoch seconds with 9 zeroes appended
  ts="$(date +%s)000000000"

  local spool_count=0
  if [ -s "$_loki_spool" ]; then
    spool_count=$(wc -l < "$_loki_spool" | tr -d ' ')
    # Spool has entries — must drain in order first, then append new command
    payload=$(_loki_build_payload "$host" "$ts" "$cmd" "$_loki_spool" 2>"${_loki_log_file}.jq_err")
    local jq_err
    jq_err=$(cat "${_loki_log_file}.jq_err" 2>/dev/null)
    rm -f "${_loki_log_file}.jq_err"
    if [ -n "$jq_err" ]; then
      _loki_log "ERROR: jq failed building spool payload: $jq_err"
    fi
    if [ -z "$payload" ]; then
      _loki_log "ERROR: empty payload from spool build (${spool_count} spool entries), appending to spool"
      _loki_spool_append "$ts" "$cmd"
      return 1
    fi
    _loki_log "sending ${spool_count} spooled + 1 new entry to $loki_url"
    local curl_body curl_rc
    curl_body=$(curl -s -w '\n%{http_code}' -X POST -H "Content-Type: application/json" \
        "$loki_url/loki/api/v1/push" -d "$payload" 2>&1)
    curl_rc=$?
    local http_code="${curl_body##*$'\n'}"
    local response_body="${curl_body%$'\n'*}"
    if [ "$curl_rc" -ne 0 ]; then
      _loki_log "ERROR: curl failed (exit $curl_rc) draining spool: $response_body"
      _loki_spool_append "$ts" "$cmd"
      return 1
    elif [ "${http_code:-0}" -ge 400 ] 2>/dev/null; then
      _loki_log "ERROR: Loki returned HTTP $http_code draining spool: $response_body"
      _loki_spool_append "$ts" "$cmd"
      return 1
    else
      # Success — clear spool
      _loki_log "OK: drained ${spool_count} spooled entries + 1 new (HTTP $http_code)"
      rm -f "$_loki_spool"
    fi
  else
    # No spool — send directly
    payload=$(_loki_build_payload "$host" "$ts" "$cmd" "" 2>"${_loki_log_file}.jq_err")
    local jq_err
    jq_err=$(cat "${_loki_log_file}.jq_err" 2>/dev/null)
    rm -f "${_loki_log_file}.jq_err"
    if [ -n "$jq_err" ]; then
      _loki_log "ERROR: jq failed building payload: $jq_err"
    fi
    if [ -z "$payload" ]; then
      _loki_log "ERROR: empty payload, appending to spool"
      _loki_spool_append "$ts" "$cmd"
      return 1
    fi
    local curl_body curl_rc
    curl_body=$(curl -s -w '\n%{http_code}' -X POST -H "Content-Type: application/json" \
        "$loki_url/loki/api/v1/push" -d "$payload" 2>&1)
    curl_rc=$?
    local http_code="${curl_body##*$'\n'}"
    local response_body="${curl_body%$'\n'*}"
    if [ "$curl_rc" -ne 0 ]; then
      _loki_log "ERROR: curl failed (exit $curl_rc): $response_body"
      _loki_spool_append "$ts" "$cmd"
      return 1
    elif [ "${http_code:-0}" -ge 400 ] 2>/dev/null; then
      _loki_log "ERROR: Loki returned HTTP $http_code: $response_body"
      _loki_spool_append "$ts" "$cmd"
      return 1
    fi
  fi
  return 0
}
