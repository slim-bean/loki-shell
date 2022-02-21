if hash stdbuf 2>/dev/null; then
    _bufcmd(){
      stdbuf -o0 awk '!seen[$0]++'
    }
else
    _bufcmd(){
      gstdbuf -o0 awk '!seen[$0]++'
    }
fi

_load_all_cmd(){
  END=$(date --iso-8601=seconds)
  for i in `seq 720 720 8640`
  do
    START=$(date -d "-$i hours" --iso-8601=seconds)
    $HOME/.loki-shell/bin/logcli query "{job=\"shell\"}" --addr=$LOKI_URL --limit=50000 --batch=1000 --from=$START --to=$END -o raw --quiet
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
      $HOME/.loki-shell/bin/logcli query "{job=\"shell\", host=\"$HOSTNAME\"}" --addr=$LOKI_URL --limit=50000 --batch=1000 --since=720h -o raw --quiet | _bufcmd |
        FZF_DEFAULT_OPTS="--height ${FZF_TMUX_HEIGHT:-40%} $FZF_DEFAULT_OPTS -n2..,.. --tiebreak=index --header 'ctrl-r to load ALL history, export LS_LOCAL=true for querying builtin history, export PRIVATE=true to not send commands to Loki.' --bind 'ctrl-r:reload(source $HOME/.loki-shell/shell/loki-shell.bash && _load_all)' $FZF_CTRL_R_OPTS +m " $(__fzfcmd) --query "$READLINE_LINE"
    ) || return
  fi
  READLINE_LINE=${selected#*$'\t'}
  if [ -z "$READLINE_POINT" ]; then
    echo "$READLINE_LINE"
  else
    READLINE_POINT=0x7fffffff
  fi
}

function _send_to_loki {
  if [[ -v PRIVATE ]]; then
    echo "PRIVATE set, not sending to loki-shell. 'unset PRIVATE' to resume."
    return 0
  fi
	(HISTTIMEFORMAT= builtin history 1 | sed 's/^ *\([0-9]*\)\** *//' |
    $HOME/.loki-shell/bin/promtail \
    -config.file=$HOME/.loki-shell/config/promtail-logging-config.yaml \
    --stdin -server.disable=true -log.level=error \
    --client.external-labels=host=$HOSTNAME 2>&1 | logger -t loki-shell-promtail &)
}
[[ $PROMPT_COMMAND =~ _send_to_loki ]] || PROMPT_COMMAND="_send_to_loki;${PROMPT_COMMAND:-:}"

alias hist="$HOME/.loki-shell/bin/logcli --addr=$LOKI_URL --quiet"