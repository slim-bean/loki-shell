if hash stdbuf 2>/dev/null; then
    _bufcmd(){
      stdbuf -o0 awk '!seen[$0]++'
    }
else
    _bufcmd(){
      gstdbuf -o0 awk '!seen[$0]++'
    }
fi

_loki_date_iso() {
  # Usage: _loki_date_iso           -> now
  #        _loki_date_iso -720      -> 720 hours ago
  if date --iso-8601=seconds >/dev/null 2>&1; then
    # GNU date
    if [ $# -eq 0 ]; then
      date --iso-8601=seconds
    else
      date -d "$1 hours" --iso-8601=seconds
    fi
  else
    # BSD date (macOS) — sed inserts colon in tz offset (-0500 -> -05:00)
    if [ $# -eq 0 ]; then
      date +%Y-%m-%dT%H:%M:%S%z | sed 's/\(..\)$/:\1/'
    else
      date -v${1}H +%Y-%m-%dT%H:%M:%S%z | sed 's/\(..\)$/:\1/'
    fi
  fi
}

_load_all_cmd(){
  END=$(_loki_date_iso)
  for i in `seq 720 720 8640`
  do
    START=$(_loki_date_iso -$i)
    ${LOKI_SHELL_DIR:-$HOME/.loki-shell}/bin/logcli query "{job=\"shell\", dropped!=\"true\"}" --addr=$LOKI_URL --limit=50000 --batch=1000 --from=$START --to=$END -o raw --quiet
    END=$START
  done
}

_load_all() {
  _load_all_cmd | _bufcmd
}

__fzf_history__() {
  local selected
  if [[ -v LS_LOCAL ]]; then
    # This command is just copied from fzf with the additional header I'll try to keep it updated...
    selected=$(
      builtin fc -lnr -2147483648 |
        last_hist=$(HISTTIMEFORMAT='' builtin history 1) perl -n -l0 -e 'BEGIN { getc; $/ = "\n\t"; $HISTCMD = $ENV{last_hist} + 1 } s/^[ *]//; print $HISTCMD - $. . "\t$_" if !$seen{$_}++' |
        FZF_DEFAULT_OPTS="--height ${FZF_TMUX_HEIGHT:-40%} $FZF_DEFAULT_OPTS -n2..,.. --tiebreak=index --header 'LS_LOCAL is set, querying local history. unset LS_LOCAL to resume.' --bind=ctrl-r:toggle-sort,ctrl-z:ignore $FZF_CTRL_R_OPTS +m --read0" $(__fzfcmd) --query "$READLINE_LINE"
    ) || return
  else
    selected=$(
      ${LOKI_SHELL_DIR:-$HOME/.loki-shell}/bin/logcli query "{job=\"shell\", host=\"$HOSTNAME\", dropped!=\"true\"}" --addr=$LOKI_URL --limit=50000 --batch=1000 --since=720h -o raw --quiet | _bufcmd |
        FZF_DEFAULT_OPTS="--height ${FZF_TMUX_HEIGHT:-40%} $FZF_DEFAULT_OPTS -n2..,.. --tiebreak=index --header 'ctrl-r to load last 1 year for all hosts, export LS_LOCAL=true for querying builtin history, export PRIVATE=true to not send commands to Loki.' --bind 'ctrl-r:reload(source ${LOKI_SHELL_DIR:-$HOME/.loki-shell}/shell/loki-shell.bash && _load_all)' $FZF_CTRL_R_OPTS +m " $(__fzfcmd) --query "$READLINE_LINE"
    ) || return
  fi
  READLINE_LINE=${selected#*$'\t'}
  if [ -z "$READLINE_POINT" ]; then
    echo "$READLINE_LINE"
  else
    READLINE_POINT=0x7fffffff
  fi
}

source "${LOKI_SHELL_DIR:-$HOME/.loki-shell}/shell/loki-shell-send.sh"

function _send_to_loki {
  if [[ -v PRIVATE ]]; then
    echo "PRIVATE set, not sending to loki-shell. 'unset PRIVATE' to resume."
    return 0
  fi
  local cmd
  cmd=$(HISTTIMEFORMAT= builtin history 1 | sed 's/^ *\([0-9]*\)\** *//')
  if [ -n "$cmd" ]; then
    (_loki_send "$LOKI_URL" "$HOSTNAME" "$cmd" 2>&1 | logger -t loki-shell &)
  fi
}
[[ $PROMPT_COMMAND =~ _send_to_loki ]] || PROMPT_COMMAND="_send_to_loki;${PROMPT_COMMAND:-:}"

alias hist="${LOKI_SHELL_DIR:-$HOME/.loki-shell}/bin/logcli --addr=$LOKI_URL --quiet"