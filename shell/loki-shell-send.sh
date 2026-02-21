#!/bin/sh
# loki-shell-send.sh - Send shell commands to Loki via curl+jq with spool file WAL
# This file is sourced by loki-shell.bash and loki-shell.zsh

_loki_spool="${LOKI_SHELL_DIR:-$HOME/.loki-shell}/data/spool"
_loki_drop_patterns="${LOKI_SHELL_DIR:-$HOME/.loki-shell}/config/drop-patterns"

# Find jq: prefer system jq, fall back to bundled copy
if command -v jq > /dev/null 2>&1; then
  _loki_jq="jq"
elif [ -x "${LOKI_SHELL_DIR:-$HOME/.loki-shell}/bin/jq" ]; then
  _loki_jq="${LOKI_SHELL_DIR:-$HOME/.loki-shell}/bin/jq"
else
  echo "loki-shell: jq not found, commands will not be sent to Loki" >&2
  _loki_jq=""
fi

# Build a Loki push API JSON payload from spool lines and/or a new entry.
# Each line in the spool file is: <nanosecond_timestamp>\t<command>
# Arguments: $1 = host, remaining args via stdin (spool lines) + $2/$3 for new entry
_loki_build_payload() {
  local host="$1" new_ts="$2" new_cmd="$3" spool_file="$4"

  if [ -n "$spool_file" ] && [ -s "$spool_file" ]; then
    if [ -n "$new_ts" ]; then
      # Spool entries + new command
      $_loki_jq -Rc --arg host "$host" --arg new_ts "$new_ts" --arg new_cmd "$new_cmd" '
        # Collect all spool lines as [ts, cmd] pairs
        split("\t") | [.[0], .[1:] | join("\t")]
      ' "$spool_file" | $_loki_jq -sc --arg host "$host" --arg new_ts "$new_ts" --arg new_cmd "$new_cmd" '
        . + [[$new_ts, $new_cmd]] |
        {"streams":[{"stream":{"job":"shell","host":$host},"values": map([.[0], .[1]])}]}
      '
    else
      # Spool entries only
      $_loki_jq -Rc --arg host "$host" '
        split("\t") | [.[0], .[1:] | join("\t")]
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
_loki_spool_append() {
  printf '%s\t%s\n' "$1" "$2" >> "$_loki_spool"
}

# Send command to Loki, managing the spool file for ordering guarantees.
# $1 = Loki URL (e.g. http://localhost:4100)
# $2 = hostname
# $3 = command to send
_loki_send() {
  local loki_url="$1" host="$2" cmd="$3"
  local ts payload

  [ -z "$_loki_jq" ] && return 1

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
      if printf '%s' "$cmd" | grep -qE "$pattern" 2>/dev/null; then
        local drop_msg="dropped command matching drop-patterns line $line_num${context:+ $context}"
        echo "$drop_msg"
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

  if [ -s "$_loki_spool" ]; then
    # Spool has entries — must drain in order first, then append new command
    payload=$(_loki_build_payload "$host" "$ts" "$cmd" "$_loki_spool")
    if [ -z "$payload" ]; then
      _loki_spool_append "$ts" "$cmd"
      return 1
    fi
    if curl -sf -o /dev/null -X POST -H "Content-Type: application/json" \
        "$loki_url/loki/api/v1/push" -d "$payload" 2>/dev/null; then
      # Success — clear spool
      rm -f "$_loki_spool"
    else
      # Loki still down — add new command to end of spool
      _loki_spool_append "$ts" "$cmd"
      return 1
    fi
  else
    # No spool — send directly
    payload=$(_loki_build_payload "$host" "$ts" "$cmd" "")
    if [ -z "$payload" ]; then
      _loki_spool_append "$ts" "$cmd"
      return 1
    fi
    if ! curl -sf -o /dev/null -X POST -H "Content-Type: application/json" \
        "$loki_url/loki/api/v1/push" -d "$payload" 2>/dev/null; then
      # Failed — start spooling
      _loki_spool_append "$ts" "$cmd"
      return 1
    fi
  fi
  return 0
}
