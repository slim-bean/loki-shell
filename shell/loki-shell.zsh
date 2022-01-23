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

fzf-history-widget() {
  local selected
  if [[ -v LS_LOCAL ]]; then
    # This command is just copied from fzf with the additional header I'll try to keep it updated...
    selected=( $(fc -rl 1 | perl -ne 'print if !$seen{(/^\s*[0-9]+\**\s+(.*)/, $1)}++' |
      FZF_DEFAULT_OPTS="--height ${FZF_TMUX_HEIGHT:-40%} $FZF_DEFAULT_OPTS -n2..,.. --tiebreak=index --header 'LS_LOCAL is set, querying local history. unset LS_LOCAL to resume.' --bind=ctrl-r:toggle-sort,ctrl-z:ignore $FZF_CTRL_R_OPTS --query=${(qqq)LBUFFER} +m" $(__fzfcmd)) )
  else
    selected=( $($HOME/.loki-shell/bin/logcli query "{job=\"shell\", host=\"$HOST\"}" --addr=$LOKI_URL --limit=50000 --batch=1000 --since=720h -o raw --quiet | _bufcmd |
      FZF_DEFAULT_OPTS="--height ${FZF_TMUX_HEIGHT:-40%} $FZF_DEFAULT_OPTS -n2..,.. --tiebreak=index --header 'ctrl-r to load ALL history, export LS_LOCAL=true for querying builtin history, export PRIVATE=true to not send commands to Loki.' --bind 'ctrl-r:reload(source $HOME/.loki-shell/shell/loki-shell.zsh && _load_all)' $FZF_CTRL_R_OPTS --query=${(qqq)LBUFFER} +m" $(__fzfcmd)) )
  fi
  local ret=$?
  if [ -n "$selected" ]; then
    selected=$(echo $selected | tr -d '\n')
    zle -U $selected
  fi
  zle reset-prompt
  return $ret
}

function _send_to_loki() {
        if [[ -v PRIVATE ]]; then
          echo "PRIVATE set, not sending to loki-shell. 'unset PRIVATE' to resume."
          return 0
        fi
        (HISTTIMEFORMAT= builtin history -1 |
        sed 's/^ *\([0-9]*\)\** *//' |
        $HOME/.loki-shell/bin/promtail \
        -config.file=$HOME/.loki-shell/config/promtail-logging-config.yaml \
        --stdin -server.disable=true -log.level=error \
        --client.external-labels=host=$HOST 2>&1 | logger -t loki-shell-promtail &)
}
[[ -z $precmd_functions ]] && precmd_functions=()
[[ $precmd_functions =~ _send_to_loki ]] || precmd_functions=($precmd_functions _send_to_loki)

alias hist="$HOME/.loki-shell/bin/logcli --addr=$LOKI_URL --quiet"
