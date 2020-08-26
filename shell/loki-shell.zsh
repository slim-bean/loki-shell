if hash stdbuf 2>/dev/null; then
    _bufcmd=stdbuf
else
    _bufcmd=gstdbuf
fi

fzf-history-widget() {
  local selected num
  selected=( $($HOME/.loki-shell/bin/logcli query "{job=\"shell\", host=\"$HOST\"}" --addr=$LOKI_URL --limit=50000 --batch=1000 --since=720h -o raw --quiet | $(eval _bufcmd) -o0 awk '!seen[$0]++' |
    FZF_DEFAULT_OPTS="--height ${FZF_TMUX_HEIGHT:-40%} $FZF_DEFAULT_OPTS -n2..,.. --tiebreak=index --bind=ctrl-r:toggle-sort $FZF_CTRL_R_OPTS --query=${(qqq)LBUFFER} +m" $(__fzfcmd)) )
  local ret=$?
  if [ -n "$selected" ]; then
    selected=$(echo $selected | tr -d '\n')
    zle -U $selected
  fi
  zle reset-prompt
  return $ret
}

function _send_to_loki() {
        (HISTTIMEFORMAT= builtin history -1 |
        sed 's/^ *\([0-9]*\)\** *//' |
        $HOME/.loki-shell/bin/promtail \
        -config.file=$HOME/.loki-shell/config/promtail-logging-config.yaml \
        --stdin -server.disable=true -log.level=error \
        --client.external-labels=host=$HOST 2>&1 | logger -t loki-shell-promtail &)
}
[[ -z $precmd_functions ]] && precmd_functions=()
[[ $precmd_functions =~ _send_to_loki ]] || precmd_functions=($precmd_functions _send_to_loki)

alias hist="$HOME/.loki-shell/bin/logcli --addr=$LOKI_URL"