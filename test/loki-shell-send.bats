#!/usr/bin/env bats
# Tests for loki-shell-send.sh
#
# These tests use a mock curl (test/mock-curl) so no real Loki is needed.
# Each test gets an isolated LOKI_SHELL_DIR under $BATS_TEST_TMPDIR.

SCRIPT_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")" && pwd)"
SEND_SH="$SCRIPT_DIR/../shell/loki-shell-send.sh"

# ── helpers ──────────────────────────────────────────────────────────────────

setup() {
  # Isolated directory per test
  export LOKI_SHELL_DIR="$BATS_TEST_TMPDIR/loki-shell"
  mkdir -p "$LOKI_SHELL_DIR/data" "$LOKI_SHELL_DIR/config"

  # Put mock curl first on PATH
  export PATH="$SCRIPT_DIR:$PATH"
  ln -sf "$SCRIPT_DIR/mock-curl" "$SCRIPT_DIR/curl"

  # Default mock behaviour: success
  export MOCK_CURL_EXIT=0
  export MOCK_CURL_HTTP=204
  export MOCK_CURL_BODY=""
  export MOCK_CURL_LOG="$BATS_TEST_TMPDIR/curl-payloads.log"
  export MOCK_CURL_ARGS="$BATS_TEST_TMPDIR/curl-args.log"

  # Empty drop-patterns
  touch "$LOKI_SHELL_DIR/config/drop-patterns"

  # Source the script under test
  source "$SEND_SH"
}

teardown() {
  rm -f "$SCRIPT_DIR/curl"
}

# Read the last JSON payload sent to curl
last_payload() {
  tail -1 "$MOCK_CURL_LOG" 2>/dev/null
}

payload_values() {
  last_payload | jq -r '.streams[0].values[][] ' 2>/dev/null
}

spool_lines() {
  wc -l < "$_loki_spool" 2>/dev/null | tr -d ' '
}

log_contents() {
  cat "$_loki_log_file" 2>/dev/null
}

# ── _loki_build_payload ─────────────────────────────────────────────────────

@test "build_payload: new command only (no spool)" {
  local p
  p=$(_loki_build_payload "myhost" "1000000000000000000" "echo hello" "")
  # Valid JSON
  echo "$p" | jq . >/dev/null
  # Correct structure
  [ "$(echo "$p" | jq -r '.streams[0].stream.host')" = "myhost" ]
  [ "$(echo "$p" | jq -r '.streams[0].stream.job')" = "shell" ]
  [ "$(echo "$p" | jq -r '.streams[0].values[0][0]')" = "1000000000000000000" ]
  [ "$(echo "$p" | jq -r '.streams[0].values[0][1]')" = "echo hello" ]
  [ "$(echo "$p" | jq '.streams[0].values | length')" = "1" ]
}

@test "build_payload: spool entries + new command" {
  printf '1000000000000000000\tcmd-one\n' > "$_loki_spool"
  printf '2000000000000000000\tcmd-two\n' >> "$_loki_spool"
  local p
  p=$(_loki_build_payload "myhost" "3000000000000000000" "cmd-three" "$_loki_spool")
  echo "$p" | jq . >/dev/null
  [ "$(echo "$p" | jq '.streams[0].values | length')" = "3" ]
  [ "$(echo "$p" | jq -r '.streams[0].values[0][0]')" = "1000000000000000000" ]
  [ "$(echo "$p" | jq -r '.streams[0].values[0][1]')" = "cmd-one" ]
  [ "$(echo "$p" | jq -r '.streams[0].values[1][1]')" = "cmd-two" ]
  [ "$(echo "$p" | jq -r '.streams[0].values[2][1]')" = "cmd-three" ]
}

@test "build_payload: spool entries only (no new command)" {
  printf '1000000000000000000\tcmd-one\n' > "$_loki_spool"
  local p
  p=$(_loki_build_payload "myhost" "" "" "$_loki_spool")
  echo "$p" | jq . >/dev/null
  [ "$(echo "$p" | jq '.streams[0].values | length')" = "1" ]
  [ "$(echo "$p" | jq -r '.streams[0].values[0][1]')" = "cmd-one" ]
}

@test "build_payload: command containing tabs preserved" {
  printf '1000000000000000000\tcmd\twith\ttabs\n' > "$_loki_spool"
  local p
  p=$(_loki_build_payload "myhost" "2000000000000000000" "new" "$_loki_spool")
  echo "$p" | jq . >/dev/null
  # The tab-containing command should be reassembled
  [ "$(echo "$p" | jq -r '.streams[0].values[0][1]')" = "cmd	with	tabs" ]
}

@test "build_payload: empty spool file treated as no spool" {
  touch "$_loki_spool"   # exists but empty
  local p
  p=$(_loki_build_payload "myhost" "1000000000000000000" "echo hello" "$_loki_spool")
  echo "$p" | jq . >/dev/null
  [ "$(echo "$p" | jq '.streams[0].values | length')" = "1" ]
}

# ── _loki_spool_append ──────────────────────────────────────────────────────

@test "spool_append: creates file and appends" {
  rm -f "$_loki_spool"
  _loki_spool_append "1000000000000000000" "first"
  [ -f "$_loki_spool" ]
  [ "$(spool_lines)" = "1" ]
  _loki_spool_append "2000000000000000000" "second"
  [ "$(spool_lines)" = "2" ]
  # Format: ts<TAB>cmd
  run head -1 "$_loki_spool"
  [[ "$output" == "1000000000000000000	first" ]]
}

# ── _loki_send: direct send ─────────────────────────────────────────────────

@test "send: direct success — no spool created" {
  run _loki_send "http://fake:4100" "myhost" "echo ok"
  [ "$status" -eq 0 ]
  [ ! -f "$_loki_spool" ]
  # Payload was sent
  [ -s "$MOCK_CURL_LOG" ]
  [ "$(last_payload | jq -r '.streams[0].values[0][1]')" = "echo ok" ]
}

@test "send: direct curl failure — command spooled" {
  export MOCK_CURL_EXIT=7
  run _loki_send "http://fake:4100" "myhost" "echo fail"
  [ "$status" -eq 1 ]
  [ -f "$_loki_spool" ]
  [ "$(spool_lines)" = "1" ]
  [[ "$(log_contents)" == *"ERROR: curl failed (exit 7)"* ]]
}

@test "send: direct HTTP 400 — command spooled" {
  export MOCK_CURL_EXIT=0
  export MOCK_CURL_HTTP=400
  export MOCK_CURL_BODY="timestamp too old"
  run _loki_send "http://fake:4100" "myhost" "echo bad"
  [ "$status" -eq 1 ]
  [ -f "$_loki_spool" ]
  [ "$(spool_lines)" = "1" ]
  [[ "$(log_contents)" == *"ERROR: Loki returned HTTP 400"* ]]
  [[ "$(log_contents)" == *"timestamp too old"* ]]
}

@test "send: direct HTTP 500 — command spooled" {
  export MOCK_CURL_EXIT=0
  export MOCK_CURL_HTTP=500
  export MOCK_CURL_BODY="internal error"
  run _loki_send "http://fake:4100" "myhost" "echo 500"
  [ "$status" -eq 1 ]
  [ -f "$_loki_spool" ]
  [[ "$(log_contents)" == *"HTTP 500"* ]]
}

# ── _loki_send: spool drain ─────────────────────────────────────────────────

@test "send: drains spool + new command on success" {
  # Pre-populate spool
  printf '1000000000000000000\tspooled-cmd\n' > "$_loki_spool"
  run _loki_send "http://fake:4100" "myhost" "new-cmd"
  [ "$status" -eq 0 ]
  # Spool cleared
  [ ! -f "$_loki_spool" ]
  # Payload should contain both entries
  local count
  count=$(last_payload | jq '.streams[0].values | length')
  [ "$count" = "2" ]
  [ "$(last_payload | jq -r '.streams[0].values[0][1]')" = "spooled-cmd" ]
  [ "$(last_payload | jq -r '.streams[0].values[1][1]')" = "new-cmd" ]
  [[ "$(log_contents)" == *"OK: drained 1 spooled entries + 1 new"* ]]
}

@test "send: spool drain failure — new command appended to spool" {
  printf '1000000000000000000\tspooled-cmd\n' > "$_loki_spool"
  export MOCK_CURL_EXIT=7
  run _loki_send "http://fake:4100" "myhost" "new-cmd"
  [ "$status" -eq 1 ]
  # Spool should now have 2 entries (original + new)
  [ "$(spool_lines)" = "2" ]
  [[ "$(log_contents)" == *"ERROR: curl failed"* ]]
}

@test "send: spool drain HTTP 400 — new command appended" {
  printf '1000000000000000000\tspooled-cmd\n' > "$_loki_spool"
  export MOCK_CURL_EXIT=0
  export MOCK_CURL_HTTP=400
  export MOCK_CURL_BODY="bad request"
  run _loki_send "http://fake:4100" "myhost" "new-cmd"
  [ "$status" -eq 1 ]
  [ "$(spool_lines)" = "2" ]
  [[ "$(log_contents)" == *"HTTP 400"* ]]
}

@test "send: multiple spool entries drain in order" {
  printf '1000000000000000000\tfirst\n' > "$_loki_spool"
  printf '2000000000000000000\tsecond\n' >> "$_loki_spool"
  printf '3000000000000000000\tthird\n' >> "$_loki_spool"
  run _loki_send "http://fake:4100" "myhost" "fourth"
  [ "$status" -eq 0 ]
  [ ! -f "$_loki_spool" ]
  local count
  count=$(last_payload | jq '.streams[0].values | length')
  [ "$count" = "4" ]
  [ "$(last_payload | jq -r '.streams[0].values[0][1]')" = "first" ]
  [ "$(last_payload | jq -r '.streams[0].values[1][1]')" = "second" ]
  [ "$(last_payload | jq -r '.streams[0].values[2][1]')" = "third" ]
  [ "$(last_payload | jq -r '.streams[0].values[3][1]')" = "fourth" ]
}

# ── _loki_send: drop patterns ───────────────────────────────────────────────

@test "send: command matching drop pattern is dropped" {
  printf '%s\n%s\n' '# Drop password args' '--password[= ].+' > "$LOKI_SHELL_DIR/config/drop-patterns"
  run _loki_send "http://fake:4100" "myhost" "mysql --password=secret123 -u root"
  [ "$status" -eq 0 ]
  [ ! -f "$_loki_spool" ]
  [[ "$(log_contents)" == *"dropped command matching drop-patterns"* ]]
}

@test "send: command not matching drop pattern is sent normally" {
  printf '%s\n' '--password[= ].+' > "$LOKI_SHELL_DIR/config/drop-patterns"
  run _loki_send "http://fake:4100" "myhost" "echo hello world"
  [ "$status" -eq 0 ]
  [ "$(last_payload | jq -r '.streams[0].values[0][1]')" = "echo hello world" ]
}

@test "send: drop pattern with comment context" {
  printf '# Sensitive export\nexport .*(PASSWORD|SECRET)=.+\n' > "$LOKI_SHELL_DIR/config/drop-patterns"
  run _loki_send "http://fake:4100" "myhost" "export MY_PASSWORD=hunter2"
  [ "$status" -eq 0 ]
  [[ "$(log_contents)" == *"# Sensitive export"* ]]
}

@test "send: empty drop-patterns file does not interfere" {
  > "$LOKI_SHELL_DIR/config/drop-patterns"
  run _loki_send "http://fake:4100" "myhost" "echo fine"
  [ "$status" -eq 0 ]
  [ "$(last_payload | jq -r '.streams[0].values[0][1]')" = "echo fine" ]
}

# ── _loki_send: jq missing ──────────────────────────────────────────────────

@test "send: fails gracefully when jq is missing" {
  local saved="$_loki_jq"
  _loki_jq=""
  run _loki_send "http://fake:4100" "myhost" "echo no-jq"
  [ "$status" -eq 1 ]
  [ ! -f "$_loki_spool" ]
  [[ "$(log_contents)" == *"jq not found"* ]]
  _loki_jq="$saved"
}

# ── _loki_log ────────────────────────────────────────────────────────────────

@test "log: writes to log file with timestamp" {
  _loki_log "test message"
  [ -f "$_loki_log_file" ]
  [[ "$(cat "$_loki_log_file")" == *"test message"* ]]
  # Has a timestamp prefix (YYYY-MM-DD HH:MM:SS)
  [[ "$(cat "$_loki_log_file")" =~ [0-9]{4}-[0-9]{2}-[0-9]{2}\ [0-9]{2}:[0-9]{2}:[0-9]{2} ]]
}

@test "log: rotates when exceeding max size" {
  _loki_log_max_bytes=20
  # First write creates the file (~25 bytes with timestamp)
  _loki_log "aaaa"
  [ -f "$_loki_log_file" ]
  [ ! -f "${_loki_log_file}.old" ]
  # Second write sees file > 20 bytes, rotates, then writes new entry
  _loki_log "bbbb"
  [ -f "${_loki_log_file}.old" ]
  # Current log has only the latest entry
  local lines
  lines=$(wc -l < "$_loki_log_file" | tr -d ' ')
  [ "$lines" = "1" ]
  [[ "$(cat "$_loki_log_file")" == *"bbbb"* ]]
  [[ "$(cat "${_loki_log_file}.old")" == *"aaaa"* ]]
}

# ── end-to-end scenario ─────────────────────────────────────────────────────

@test "e2e: offline → offline → online drains everything" {
  # Simulate two failures then a success
  export MOCK_CURL_EXIT=7
  run _loki_send "http://fake:4100" "myhost" "offline-1"
  [ "$status" -eq 1 ]
  run _loki_send "http://fake:4100" "myhost" "offline-2"
  [ "$status" -eq 1 ]
  [ "$(spool_lines)" = "2" ]

  # Now succeed
  export MOCK_CURL_EXIT=0
  export MOCK_CURL_HTTP=204
  run _loki_send "http://fake:4100" "myhost" "online-3"
  [ "$status" -eq 0 ]
  [ ! -f "$_loki_spool" ]

  # All three should be in the payload
  local count
  count=$(last_payload | jq '.streams[0].values | length')
  [ "$count" = "3" ]
  [ "$(last_payload | jq -r '.streams[0].values[0][1]')" = "offline-1" ]
  [ "$(last_payload | jq -r '.streams[0].values[1][1]')" = "offline-2" ]
  [ "$(last_payload | jq -r '.streams[0].values[2][1]')" = "online-3" ]
}

@test "e2e: commands with special characters" {
  run _loki_send "http://fake:4100" "myhost" 'echo "hello world" | grep -E "h(e|a)llo" && echo $HOME'
  [ "$status" -eq 0 ]
  [ "$(last_payload | jq -r '.streams[0].values[0][1]')" = 'echo "hello world" | grep -E "h(e|a)llo" && echo $HOME' ]
}

@test "spool_append: escapes newlines in commands" {
  rm -f "$_loki_spool"
  _loki_spool_append "1000000000000000000" $'line one\nline two\nline three'
  # Should be exactly 1 line in the spool file
  [ "$(spool_lines)" = "1" ]
  # Should contain escaped \n, not actual newlines
  [[ "$(cat "$_loki_spool")" == *'line one\nline two\nline three'* ]]
}

@test "spool_append: escapes backslashes before newlines" {
  rm -f "$_loki_spool"
  _loki_spool_append "1000000000000000000" $'echo "hello\\nworld"\nls -la'
  [ "$(spool_lines)" = "1" ]
  # Backslash should be doubled, newline escaped
  [[ "$(cat "$_loki_spool")" == *'hello\\nworld'* ]]
}

@test "build_payload: unescapes newlines from spool" {
  printf '1000000000000000000\tline one\\nline two\\nline three\n' > "$_loki_spool"
  local p
  p=$(_loki_build_payload "myhost" "" "" "$_loki_spool")
  # Command should have actual newlines restored
  local cmd
  cmd=$(echo "$p" | jq -r '.streams[0].values[0][1]')
  [ "$(echo "$cmd" | wc -l | tr -d ' ')" = "3" ]
  [ "$(echo "$cmd" | head -1)" = "line one" ]
  [ "$(echo "$cmd" | tail -1)" = "line three" ]
}

@test "build_payload: round-trips backslash + newline" {
  rm -f "$_loki_spool"
  local original=$'echo "hello\\nworld"\nls -la'
  _loki_spool_append "1000000000000000000" "$original"
  local p
  p=$(_loki_build_payload "myhost" "" "" "$_loki_spool")
  local restored
  restored=$(echo "$p" | jq -r '.streams[0].values[0][1]')
  [ "$restored" = "$original" ]
}

@test "build_payload: skips malformed spool lines (no tab)" {
  printf '1000000000000000000\tgood-cmd\n' > "$_loki_spool"
  printf 'bare line with no tab\n' >> "$_loki_spool"
  printf '2000000000000000000\talso-good\n' >> "$_loki_spool"
  printf 'another bare line\n' >> "$_loki_spool"
  local p
  p=$(_loki_build_payload "myhost" "3000000000000000000" "new" "$_loki_spool")
  # Should have 3 entries: 2 good spool + 1 new (bare lines skipped)
  [ "$(echo "$p" | jq '.streams[0].values | length')" = "3" ]
  [ "$(echo "$p" | jq -r '.streams[0].values[0][1]')" = "good-cmd" ]
  [ "$(echo "$p" | jq -r '.streams[0].values[1][1]')" = "also-good" ]
  [ "$(echo "$p" | jq -r '.streams[0].values[2][1]')" = "new" ]
}

@test "e2e: multi-line command survives spool round-trip" {
  local cmd=$'for i in 1 2 3; do\n  echo $i\ndone'
  export MOCK_CURL_EXIT=7
  run _loki_send "http://fake:4100" "myhost" "$cmd"
  [ "$status" -eq 1 ]
  # Spool should have exactly 1 line (newlines escaped)
  [ "$(spool_lines)" = "1" ]

  export MOCK_CURL_EXIT=0
  export MOCK_CURL_HTTP=204
  run _loki_send "http://fake:4100" "myhost" "echo done"
  [ "$status" -eq 0 ]
  [ ! -f "$_loki_spool" ]
  # The multi-line command should be restored in the payload
  [ "$(last_payload | jq -r '.streams[0].values[0][1]')" = "$cmd" ]
}

@test "e2e: spool survives commands with special chars" {
  local cmd='echo "hello world" | awk '"'"'{print $1}'"'"' && rm -rf /'
  export MOCK_CURL_EXIT=7
  run _loki_send "http://fake:4100" "myhost" "$cmd"
  [ "$(spool_lines)" = "1" ]

  export MOCK_CURL_EXIT=0
  export MOCK_CURL_HTTP=204
  run _loki_send "http://fake:4100" "myhost" "echo done"
  [ "$status" -eq 0 ]
  [ ! -f "$_loki_spool" ]
  [ "$(last_payload | jq -r '.streams[0].values[0][1]')" = "$cmd" ]
}

# ── proxy support ────────────────────────────────────────────────────────────

last_args() {
  tail -1 "$MOCK_CURL_ARGS" 2>/dev/null
}

@test "proxy: none configured — curl called without --proxy" {
  run _loki_send "http://fake:4100" "myhost" "echo hi"
  [ "$status" -eq 0 ]
  [[ "$(last_args)" == *"proxy=" ]]
}

@test "proxy: LOKI_SHELL_PROXY env var passed to curl" {
  export LOKI_SHELL_PROXY="socks5h://127.0.0.1:1055"
  run _loki_send "http://fake:4100" "myhost" "echo hi"
  [ "$status" -eq 0 ]
  [[ "$(last_args)" == *"proxy=socks5h://127.0.0.1:1055" ]]
}

@test "proxy: config/proxy file passed to curl" {
  echo "socks5h://127.0.0.1:2233" > "$LOKI_SHELL_DIR/config/proxy"
  run _loki_send "http://fake:4100" "myhost" "echo hi"
  [ "$status" -eq 0 ]
  [[ "$(last_args)" == *"proxy=socks5h://127.0.0.1:2233" ]]
}

@test "proxy: env var takes precedence over file" {
  export LOKI_SHELL_PROXY="socks5h://127.0.0.1:1055"
  echo "socks5h://127.0.0.1:2233" > "$LOKI_SHELL_DIR/config/proxy"
  run _loki_send "http://fake:4100" "myhost" "echo hi"
  [[ "$(last_args)" == *"proxy=socks5h://127.0.0.1:1055" ]]
}

@test "proxy: file contents are trimmed of whitespace" {
  printf '  socks5h://127.0.0.1:2233 \n' > "$LOKI_SHELL_DIR/config/proxy"
  run _loki_proxy
  [ "$output" = "socks5h://127.0.0.1:2233" ]
}

@test "proxy: toggling the file mid-session changes behavior without re-sourcing" {
  run _loki_send "http://fake:4100" "myhost" "echo direct"
  [[ "$(last_args)" == *"proxy=" ]]

  echo "socks5h://127.0.0.1:2233" > "$LOKI_SHELL_DIR/config/proxy"
  run _loki_send "http://fake:4100" "myhost" "echo proxied"
  [[ "$(last_args)" == *"proxy=socks5h://127.0.0.1:2233" ]]

  rm "$LOKI_SHELL_DIR/config/proxy"
  run _loki_send "http://fake:4100" "myhost" "echo direct again"
  [[ "$(last_args)" == *"proxy=" ]]
}
