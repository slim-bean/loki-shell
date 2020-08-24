# Level up your shell history with Loki and fzf

Loki is an Apache 2.0 licensed open source log aggregation framework designed by Grafana Labs and built with tremendous support from a growing community -- as well as the project I work on every day. My goal with this article is to provide an introduction to Loki in a hands-on way. I thought rather than just talking about how Loki works, a concrete use case that solves some real problems would be much more engaging! A special thanks to my peer Jack Baldry for planting the seed for this idea, I had the Loki knowledge to make this happen but if it weren’t for him suggesting this I don’t think we ever would have made it here.

## The Problem: Durable Centralized Shell History

I love my shell history and have always been a fanatical _ctrl-r_ user.  About a year ago my terminal life was forever changed when someone introduced me to the command line fuzzy finder, fzf.

Suddenly my searching through commands went from this:

![before](assets/before.gif)

To this:

![after](assets/with_fzf.gif)

fzf has significantly improved my quality of life, but there are still some missing pieces around my shell history:

* Losing shell history when terminals close abruptly, computers crash, computers die, whole disk encryption keys are forgotten...
* Access to my shell history _from_ all my computers _on_ all my computers. 

I think of my shell history as documentation, it's an important story I don't want to lose. Combining Loki with my shell history will help solve these problems and more!

## Background

Loki is built to take the very successful and intuitive label model used by the open source [Prometheus](https://prometheus.io/) project and expand it into the world of log aggregation. This enables developers and operators to seamlessly pivot between their metrics and logs by using the same set of labels. Not using Prometheus? No worries, there are still plenty of reasons why Loki might be a good fit for your log storage needs.  

* Low overhead: Loki does NOT do full text log indexing; it only creates an index of the labels you put on your logs. Keeping a small index substantially reduces the operating requirements of Loki. I'm running my loki-shell project on a Raspberry Pi using just a little over 50MB of memory.
* Low cost: The log content is compressed and stored in object stores like S3, GCS, Azure Blob, or even directly on a filesystem. The goal is to use storage which is inexpensive and durable.
* Flexibility: Loki is available in a single binary to be downloaded and run directly. It is also provided as a Docker image to run in any container environment. A Helm chart is available to get started quickly in Kubernetes. If you really demand a lot from your logging tools, look at the [production setup running at Grafana Labs](https://grafana.com/docs/loki/latest/installation/tanka/).  The open source tools [Jsonnet](https://jsonnet.org) and [Tanka](https://tanka.dev/) are used to deploy that same Loki image as discrete building blocks enabling massive horizontal scaling, high availability, replication, separate scaling of read and write paths, highly parallelizable querying, and more.

In summary, Loki takes the approach of keeping a small index of metadata about your logs (labels) and storing log content itself unindexed and compressed in inexpensive object stores to make operating easier and cheaper. The application is built to run as a single process and easily evolve into a highly available distributed system. High query performance can be obtained on larger logging workloads through parallelization and sharding of queries, a bit like MapReduce for your logs.  

The best part? All of this functionality is available for anyone to use, for free, today. Following in the footsteps and success of Grafana, Grafana Labs is committed to making Loki a fully featured, fully open log aggregation software anyone can use.

## The Solution

**Note:** We will not be changing any existing behaviors around history, **your existing shell history command and history settings will be untouched.** We are hooking command history to duplicate it to Loki via `$PROMPT_COMMAND` in Bash and `precmd` in Zsh, and on the `ctrl-r` side of things we are overloading the function fzf uses to hook the `ctrl-r` command.  It is safe to try this and if you decide you don't like it follow the steps in the Uninstall section to remove all traces, your shell history will be untouched.

The config files and some additional instructions and information to take this project even further can be found at: https://github.com/slim-bean/loki-shell
 
Let's get started! first we need to make a directory to store config files, binaries and some cached data:

```bash
cd ~
mkdir .loki-shell && cd .loki-shell && mkdir data bin config
```

### Step 1: Set up Loki.

At the time of this article 1.6.0 was the most recent Loki version but check [the Loki release page](https://github.com/grafana/loki/releases) to see if there is a newer version available!

You can choose between running Loki in Docker or the Binary direcctly. Docker is easier and quicker, but certainly isn't necessary, if you prefer you can run Loki as easily as `./loki -config.file=loki-local-config.yaml`

#### Docker

If you have Docker running, using it to run Loki simplifies some of the operational steps as Docker can handle automatic start/restart and makes changing versions simple.

The Loki process in the Docker image runs as user 10001:10001 so to be able to write to the data directory we created we need to change the owner:

```bash
cd ~/.loki-shell
sudo chown 10001:10001 data/
 ```

Next we need to download a config file

```bash
cd ~/.loki-shell/config
curl -O -L "https://raw.githubusercontent.com/slim-bean/loki-shell/master/cfg/loki-docker-local-config.yaml"
```

The defaults in this config file were tuned for this application with some comments explaining why, feel free to check it out.

Now that Loki has a place to store files and a config file we can run it!

```bash
docker run -d --restart=unless-stopped --name=loki-shell \
--mount type=bind,source=$HOME/.loki-shell/config/loki-docker-local-config.yaml,target=/etc/loki/local-config.yaml \
--mount type=bind,source=$HOME/.loki-shell/data,target=/loki \
-p 4100:4100 grafana/loki:1.6.0
```

Check the logs and you should see something like this:

```bash
docker logs loki-shell
```

```bash
level=info ts=2020-08-23T13:06:21.1927609Z caller=loki.go:210 msg="Loki started"
level=info ts=2020-08-23T13:06:21.1929967Z caller=lifecycler.go:370 msg="auto-joining cluster after timeout" ring=ingester
```

#### Binary

If you don't have or don't want to use Docker you can run Loki as a binary! In this example I’m using the fairly common linux-amd64, but please check [the Loki release page](https://github.com/grafana/loki/releases) for other architectures and adjust the following commands accordingly.

```bash
cd ~/.loki-shell/bin
curl -O -L "https://github.com/grafana/loki/releases/download/v1.6.0/loki-linux-amd64.zip"
unzip loki-linux-amd64.zip && mv loki-linux-amd64 loki
```

Next download a configuration file:

```bash
cd ~/.loki-shell/config
curl -O -L "https://raw.githubusercontent.com/slim-bean/loki-shell/master/cfg/loki-local-config.yaml"
```

There are a few paths which need to be set, all the FIXME's need to become absolute paths:

```bash
sed -i "s|FIXME|$HOME|g" loki-local-config.yaml
```

TIL you can use any character in sed it doesn't have to be a `/` and if you want to substitute and env variable that has paths in it this is a convenient feature!

If you wanted, you could now run Loki:

```bash
~/.loki-shell/bin/loki -config.file=ABSOLUTE_PATH_TO/.loki-shell/config/loki-local-config.yaml
```

However if you want Loki to run in the background and enable it across reboots we can create a systemd service for it. 

Now we will download a systemd service file:

```bash
curl -O -L "https://raw.githubusercontent.com/slim-bean/loki-shell/master/cfg/loki.service"
```

This time we need to update the path as well as the user who will run Loki

```bash
sed -i "s|FIXME|$HOME|g" loki.service
sed -i "s|USER|$USER|g" loki.service
```

Enable the systemd service and start it

```
sudo cp loki.service /etc/systemd/system/loki.service
sudo systemctl daemon-reload
sudo systemctl enable loki
sudo systemctl start loki
```


### Step 2: Install fzf

There are several ways to install fzf but I prefer [the git instructions](https://github.com/junegunn/fzf#using-git) which are:
 
```bash 
git clone --depth 1 https://github.com/junegunn/fzf.git ~/.fzf
~/.fzf/install
```

the git install method always gets you the most recent version and also makes updates as simple as

```bash
cd ~/.fzf
git pull
./install
```

Say yes to all the prompted questions.

### Step 3: Configure your shell

**Note:** Promtail and logcli have binaries for several operating systems and architectures. In this example I’m using the fairly common linux-amd64, but please check [the Loki release page](https://github.com/grafana/loki/releases) for other architectures and adjust the following commands accordingly.

```bash
cd ~/.loki-shell/bin
curl -O -L "https://github.com/grafana/loki/releases/download/v1.6.0/promtail-linux-amd64.zip"
unzip promtail-linux-amd64.zip && mv promtail-linux-amd64 promtail
curl -O -L "https://github.com/grafana/loki/releases/download/v1.6.0/logcli-linux-amd64.zip"
unzip logcli-linux-amd64.zip && mv logcli-linux-amd64 logcli
```

We also need a promtail config file:

```bash
cd ~/.loki-shell/config
curl -O -L "https://raw.githubusercontent.com/slim-bean/loki-shell/master/cfg/promtail-logging-config.yaml"
```

#### Bash

Open `~/.bashrc` in your favorite editor

Find this line that fzf installed:

```bash
[ -f ~/.fzf.bash ] && source ~/.fzf.bash
```

Immediately after this we are going to overload the function fzf uses for showing the history as well as use PROMPT_COMMAND to add a function for intercepting commands to send to Loki:

```bash
[ -f ~/.fzf.bash ] && source ~/.fzf.bash

# NOTE when changing the Loki URL, also remember to change the promtail config: ~/.loki-shell/config/promtail-logging-config.yaml
export LOKI_URL="http://localhost:4100"

__fzf_history__() {
  local output
  output=$(
    $HOME/.loki-shell/bin/logcli query "{job=\"shell\", host=\"$HOSTNAME\"}" --addr=$LOKI_URL --limit=50000 --batch=1000 --since=720h -o raw --quiet | stdbuf -o0 awk '!seen[$0]++' |
      FZF_DEFAULT_OPTS="--height ${FZF_TMUX_HEIGHT:-40%} $FZF_DEFAULT_OPTS -n2..,.. --tiebreak=index --bind=ctrl-r:toggle-sort $FZF_CTRL_R_OPTS +m " $(__fzfcmd) --query "$READLINE_LINE" 
      ) || return
  READLINE_LINE=${output#*$'\t'}
  if [ -z "$READLINE_POINT" ]; then
    echo "$READLINE_LINE"
  else
    READLINE_POINT=0x7fffffff
  fi
}

function _send_to_loki {
	(HISTTIMEFORMAT= builtin history 1 | sed 's/^ *\([0-9]*\)\** *//' | 
    $HOME/.loki-shell/bin/promtail \
    -config.file=$HOME/.loki-shell/config/promtail-logging-config.yaml \
    --stdin -server.disable=true -log.level=error \
    --client.external-labels=host=$HOSTNAME 2>&1 | logger -t loki-shell-promtail &)
}
[[ $PROMPT_COMMAND =~ _send_to_loki ]] || PROMPT_COMMAND="_send_to_loki;${PROMPT_COMMAND:-}"

alias hist="$HOME/.loki-shell/bin/logcli --addr=$LOKI_URL"
```

The alias at the end is optional but will make it easier to query Loki directly for your shell history.

Check out the [getting started guide for logcli](https://grafana.com/docs/loki/latest/getting-started/logcli/) to learn more about querying.


Save your `.bashrc` file and reload it with `source ~/.bashrc` or restart your shell!


#### Zsh

Open `~/.zshrc` in your favorite editor

Find this line that fzf installed:

```bash
[ -f ~/.fzf.zsh ] && source ~/.fzf.zsh
```

Immediately after this we are going to overload the function fzf uses for showing the history as well as use precmd to add a function for intercepting commands to send to Loki:

```bash
[ -f ~/.fzf.zsh ] && source ~/.fzf.zsh

# NOTE when changing the Loki URL, also remember to change the promtail config: ~/.loki-shell/config/promtail-logging-config.yaml
export LOKI_URL="http://localhost:4100"

fzf-history-widget() {
  local selected num
  selected=( $($HOME/.loki-shell/bin/logcli query "{job=\"shell\", host=\"$HOST\"}" --addr=$LOKI_URL --limit=50000 --batch=1000 --since=720h -o raw --quiet | stdbuf -o0 awk '!seen[$0]++' |
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
```

The alias at the end is optional but will make it easier to query Loki directly for your shell history.

Check out the [getting started guide for logcli](https://grafana.com/docs/loki/latest/getting-started/logcli/) to learn more about querying.

Save your `.zshrc` file and reload it with `source ~/.zshrc` or restart your shell!

### Step 4: Try it out!

Start using your shell and use `ctrl-r` to see your commands show up.

Open multiple terminal windows, type a command in one and `ctrl-r` in another and see your commands available immediately.

Also notice that when switching between terminals and entering commands they are available immediately by `ctrl-r` but the operation of the up-arrow is not affected between terminals! (this may not be true with oh-my-zsh installed which automatically appends all commands to the history)

Use `ctrl-r` multiple times to toggle between sorting by time and relevance.

**Note:** The configuration applied here will only show the query history for the current host even if you are sending shell data from multiple hosts to Loki, I think by default this makes the most sense.  There is a lot you can tweak here if you would like this behavior to change, see the [repo](https://github.com/slim-bean/loki-shell) to learn more.

## Extra Credit

Install Grafana and play around with your shell history.

```bash
docker run -d -p 3000:3000 --name=grafana grafana/grafana
```

Open up a web browser at `http://localhost:3000` login using the default admin/admin user and password.

On the left navigate to `Configuration -> Datasources` click `Add Datasource` button and select `Loki`

For the url you should be able to use `http://localhost:4100` (however on my WSL2 machine I had to use the IP of the computer itself)

Click `Save and Test` you should see `Data source connected and labels found.`

Click on the `Explore` icon on the left, make sure the `Loki` datasource is selected and try out a query: `{job="shell"}`

When you have more hosts sending shell commands you can limit the results to a certain host using the `hostname` label which is being added: `{job="shell", hostname="myhost"}`

You can also look for specific commands with filter expressions `{job="shell"} |= "docker"`

Or you can start exploring the world of metrics from logs `rate({job="shell"}[1m])`!

For a better understanding of Loki's query language [check out this LogQL guide](https://grafana.com/docs/loki/latest/logql/)

## Troubleshooting

A troubleshooting guide is available on the [repo](https://github.com/slim-bean/loki-shell)

## Improvements

I think there is still a lot that can be improved and expanded on this idea, so please stay connected with the git repo and feel free to send any issues or PRs with your ideas!  this is the best place to 
Query examples, rate queries
Note taking?
powershell


## Uninstalling

Uninstalling is fairly straightforward:

First remove the entries made in `~/.bashrc` or `~/.zshrc`

Restart your shell

Stop and remove Loki:

```
docker rm -f loki-shell
```

or

```
sudo systemctl stop loki
sudo systemctl disable loki
sudo rm /etc/systemd/system/loki.service
sudo systemctl daemon-reload
```

Remove all the download files and data files:

```
sudo rm -rf ~/.loki-shell
```

Uninstall fzf (optional, you can still keep and use fzf if you like it)

```
~/.fzf/uninstall
rm -rf ~/.fzf
```






