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
    ${LOKI_SHELL_DIR:-$HOME/.loki-shell}/bin/logcli query "{job=\"shell\"}" --addr=$LOKI_URL --limit=50000 --batch=1000 --from=$START --to=$END -o raw --quiet
    END=$START
  done
}

_load_all() {
  _load_all_cmd | _bufcmd
}

fzf-history-widget() {
  local selected
  if [[ -v LS_LOCAL ]]; then
    # This command is just copied from fzf with the additional header I'll try to keep it updated...
    selected=( $(fc -rl 1 | perl -ne 'print if !$seen{(/^\s*[0-9]+\**\s+(.*)/, $1)}++' |
      FZF_DEFAULT_OPTS="--height ${FZF_TMUX_HEIGHT:-40%} $FZF_DEFAULT_OPTS -n2..,.. --tiebreak=index --header 'LS_LOCAL is set, querying local history. unset LS_LOCAL to resume.' --bind=ctrl-r:toggle-sort,ctrl-z:ignore $FZF_CTRL_R_OPTS --query=${(qqq)LBUFFER} +m" $(__fzfcmd)) )
  else
    selected=( $(${LOKI_SHELL_DIR:-$HOME/.loki-shell}/bin/logcli query "{job=\"shell\", host=\"$HOST\"}" --addr=$LOKI_URL --limit=50000 --batch=1000 --since=720h -o raw --quiet | _bufcmd |
      FZF_DEFAULT_OPTS="--height ${FZF_TMUX_HEIGHT:-40%} $FZF_DEFAULT_OPTS -n2..,.. --tiebreak=index --header 'ctrl-r to load last 1 year for all hosts, export LS_LOCAL=true for querying builtin history, export PRIVATE=true to not send commands to Loki.' --bind 'ctrl-r:reload(source ${LOKI_SHELL_DIR:-$HOME/.loki-shell}/shell/loki-shell.zsh && _load_all)' $FZF_CTRL_R_OPTS --query=${(qqq)LBUFFER} +m" $(__fzfcmd)) )
  fi
  local ret=$?
  if [ -n "$selected" ]; then
    selected=$(echo $selected | tr -d '\n')
    zle -U $selected
  fi
  zle reset-prompt
  return $ret
}

source "${LOKI_SHELL_DIR:-$HOME/.loki-shell}/shell/loki-shell-send.sh"

function _send_to_loki() {
  if [[ -v PRIVATE ]]; then
    echo "PRIVATE set, not sending to loki-shell. 'unset PRIVATE' to resume."
    return 0
  fi
  local cmd
  cmd=$(HISTTIMEFORMAT= builtin history -1 | sed 's/^ *\([0-9]*\)\** *//')
  if [ -n "$cmd" ]; then
    (_loki_send "$LOKI_URL" "$HOST" "$cmd" 2>&1 | logger -t loki-shell &)
  fi
}
[[ -z $precmd_functions ]] && precmd_functions=()
[[ $precmd_functions =~ _send_to_loki ]] || precmd_functions=($precmd_functions _send_to_loki)

alias hist="${LOKI_SHELL_DIR:-$HOME/.loki-shell}/bin/logcli --addr=$LOKI_URL --quiet"
