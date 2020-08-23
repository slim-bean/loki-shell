
Loki is an Apache 2.0 licensed open source log aggregation framework designed by Grafana Labs and built with tremendous support from a growing community -- as well as the project I work on every day. My goal with this article is to provide an introduction to Loki in a hands-on way. I thought rather than just talking about how Loki works, a concrete use case that solves some real problems would be much more engaging! A special thanks to my peer Jack Baldry for planting the seed for this idea, I had the Loki knowledge to make this happen but if it weren’t for him suggesting this I don’t think we ever would have made it here.

## The Problem: Durable Centralized Shell History

I love my shell history and have always been a fanatical _ctrl-r_ user.  About a year ago my terminal life was forever changed when someone introduced me to the command line fuzzy finder, fzf.

Suddenly my searching through commands went from this:

<insert gif here>

To this:

<insert gif here>

fzf has significantly improved my quality of life, but there are still a few areas where my shell history falls short so today we set out to fix these problems with some help from Loki.

The two big issues I would like to solve:

Losing my shell history because the shell was closed before the history was appended
Not having a shared shell history between terminals on the same machine or different machines.

There are solutions to the first problem however I think we can improve on them as well as solve the second problem. Resulting in something like this:

<insert gif here>

## Background

Loki was built to expand the very successful and intuitive label model used by Prometheus into the world of log aggregation and enable developers and operators to seamlessly pivot between their metrics and logs by using the same set of labels. Not using Prometheus? No worries, there are still plenty of reasons why Loki might be a good fit for your log storage needs.  

* Low overhead: Loki does NOT do full text log indexing; it only creates an index of the labels you put on your logs. Keeping a small index substantially reduces the operating requirements of Loki. In fact, in this guide I will be running Loki on a Raspberry Pi using just a bit over 50MB of memory.
* Low cost: The log content is compressed and stored in object stores like S3, GCS, Azure Blob, or even directly on a filesystem. The goal is to store the logs as cheaply as possible.
* Flexibility: Loki is available in a single binary compiled for many architectures and can be run directly on any machine. It is also provided as a Docker image to unlock any environment that can run Docker containers. If you have a Kubernetes installation, it can be deployed via Helm chart. Finally, if you really demand a lot from your logging application, you can look at the production setup running at Grafana Labs, which uses `tanka` FIXME LINK and ksonnet to take the same binary/Docker image and run it as discrete components. This enables massive horizontal scaling, high availability, replication, separation of read and write paths (for higher reliability and separate scalability), highly parallelizable querying, and more.

In summary, Loki takes the approach of keeping a small index of metadata about your logs (labels) and storing log content itself unindexed and compressed in inexpensive object stores to make operating easier and cheaper. The application is built to run as a single process and easily evolve into a highly available distributed system as needed. High query performance is obtained on larger logging workloads through parallelization and sharding of queries, a bit like MapReduce for your logs.  

The best part? All of this functionality is available for anyone to use, for free, today. Following in the footsteps and success of Grafana, Grafana Labs is committed to making Loki a fully featured, fully open log aggregation software anyone can use.

## The Solution

One of the challenges I’ve had writing this article is narrowing down all the options into something that covers as many people as possible. There are many ways to run Loki with many different storage options, not to mention there are many excellent shells out there! Too many options! I ultimately decided to choose two shells, Bash for its ubiquity and Zsh for its popularity. For running Loki I have chosen Docker because it handles running/upgrading easily, and for storage I’m using an S3-compatible service called Wasabi to have an offsite high-durability backup that is inexpensive. 

**Note:** We will not be changing any existing behaviors around history, **your existing shell history command and history settings will be untouched.** We are hooking command history to duplicate it to Loki via `$PROMPT_COMMAND` in Bash and `precmd` in Zsh, and on the `ctrl-r` side of things we are overloading the function fzf uses to hook the `ctrl-r` command.  It is safe to try this and if you decide you don't like it follow the steps in the Uninstall section and it will be like nothing ever happened!


The config files and some additional instructions can be found in a git repo I made for this project: https://github.com/slim-bean/loki-shell
 
Let's get started! first we need to make a directory to store config files, binaries and some cached data:

```bash
cd ~
mkdir .loki-shell && cd .loki-shell && mkdir data bin config
```

### Step 1: Set up Loki.

I’m going to run Loki on localhost to keep the URL’s compatible for everyone to get started quickly. However ultimately you will want Loki running somewhere accessible from all your machines. My current setup I’m running Loki on a Raspberry Pi (still within docker). More options and details can be found in the [git repo](https://github.com/slim-bean/loki-shell).

At the time of this article 1.6.0 was the most recent Loki version but check [the Loki release page](https://github.com/grafana/loki/releases) to see if there is a newer version available!

The Loki process in the Docker image runs as user 10001:10001 so to be able to write to the data directory we created we need to change the owner:

```bash
cd ~/.loki-shell
sudo chown 10001:10001 data/
 ```

If you can’t run sudo commands to change the directory, there are a few other options in the git repo FIXME link, one other option would be to make the directory writable for everyone.

Now you need to make a decision, Loki supports many backend stores I would suggest using a cloud storage option like s3.  It provides durability offsite for your command history as well as makes it very easy to move where you are running Loki without having to copy any data files.

However if you don’t want to create an s3 bucket and you want to just get started quickly you can keep all the files on the local filesystem. It will still be possible to move to an s3 bucket later, directions [here](FIXME).

Choose your adventure:

#### Filesystem

```bash
cd ~/.loki-shell/config
curl -O -L "https://raw.githubusercontent.com/slim-bean/loki-shell/master/cfg/loki-docker-local-config.yaml"
```
You shouldn’t need to change anything other than perhaps the port you wish Loki to run on and you can run Loki!

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

#### Cloud

```bash
cd ~/.loki-shell/config
curl -O -L "https://raw.githubusercontent.com/slim-bean/loki-shell/master/cfg/loki-docker-s3-config.yaml"
```

Open the file in your favorite editor and you will need these two lines with your bucket info:

```bash
s3: https://ACCESS_KEY_ID:SECRET_ACCESS_KEY@s3.wasabisys.com/BUCKET_NAME 
region: REGION 
```

Save your changes and Run Loki!

```bash
docker run -d --restart=unless-stopped --name=loki-shell \
--mount type=bind,source=$HOME/.loki-shell/config/loki-docker-s3-config.yaml,target=/etc/loki/local-config.yaml \
--mount type=bind,source=$HOME/.loki-shell/data,target=/loki \
-p 4100:4100 grafana/loki:1.6.0
```

Check the logs and you should see something like this:

```bash
docker logs loki-shell
```

```none
level=info ts=2020-08-23T13:06:21.1927609Z caller=loki.go:210 msg="Loki started"
level=info ts=2020-08-23T13:06:21.1929967Z caller=lifecycler.go:370 msg="auto-joining cluster after timeout" ring=ingester
```

**NOTE:** Putting the files in a remote store does increase the latency for queries, this will be most noticeable on the first query in a long period of time or after a Loki restart. However the Loki config has some aggressive cache settings enabled such that subsequent queries should only take a few milliseconds if Loki is running on the localhost.  See [performance notes](FIXME) for more information.

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

**Note:** Promtail and logcli have binaries for several operating systems and architectures. In this example I’m using the fairly common linux-amd64, but please check [the Loki release page](https://github.com/grafana/loki/releases) for other binaries and adjust the following commands accordingly.

```bash
cd ~/.loki-shell/bin
curl -O -L "https://github.com/grafana/loki/releases/download/v1.6.0/promtail-linux-amd64.zip"
unzip promtail-linux-amd64.zip && mv promtail-linux-amd64 promtail
curl -O -L "https://github.com/grafana/loki/releases/download/v1.6.0/logcli-linux-amd64.zip"
unzip logcli-linux-amd64.zip && mv logcli-linux-amd64 logcli
```

#### Bash

First we will configure bash to send the history commands to Loki, starting by downloading a promtail config:

```bash
cd ~/.loki-shell/config
curl -O -L "https://raw.githubusercontent.com/slim-bean/loki-shell/master/cfg/promtail-logging-config.yaml"
```

Next open `~/.bashrc` in your favorite editor, and put this at or near the bottom.

```bash
function _send_to_loki {
	(HISTTIMEFORMAT= builtin history 1 | sed 's/^ *\([0-9]*\)\** *//' | 
    $HOME/.loki-shell/bin/promtail \
    -config.file=$HOME/.loki-shell/config/promtail-logging-config.yaml \
    --stdin -server.disable=true -log.level=error \
    --client.external-labels=host=$HOSTNAME 2>/dev/null &)
}
[[ $PROMPT_COMMAND =~ _send_to_loki ]] || PROMPT_COMMAND="_send_to_loki;${PROMPT_COMMAND:-:}"
```

Next find this line that fzf installed:

```bash
[ -f ~/.fzf.bash ] && source ~/.fzf.bash
```

Immediately after this we are going to overload the function fzf uses for showing the history with our own function that uses logcli to get the logs from Loki:

NOTE: If you are running Loki on a different host or port change `--addr=http://localhost:4100` accordingly.

```bash
[ -f ~/.fzf.bash ] && source ~/.fzf.bash

__fzf_history__() {
  local output
  output=$(
    $HOME/.loki-shell/bin/logcli query '{job="shell"}' --addr=http://localhost:4100 --limit=50000 --batch=1000 --since=720h -o raw --quiet | stdbuf -o0 awk '!seen[$0]++' |
      FZF_DEFAULT_OPTS="--height ${FZF_TMUX_HEIGHT:-40%} $FZF_DEFAULT_OPTS -n2..,.. --tiebreak=index --bind=ctrl-r:toggle-sort $FZF_CTRL_R_OPTS +m " $(__fzfcmd) --query "$READLINE_LINE" 
      ) || return
  READLINE_LINE=${output#*$'\t'}
  if [ -z "$READLINE_POINT" ]; then
    echo "$READLINE_LINE"
  else
    READLINE_POINT=0x7fffffff
  fi
}
```

Optional, but I also recommend adding an alias to logcli so you can query Loki directly for your history:

```bash
alias hist="$HOME/.loki-shell/bin/logcli --addr=http://localhost:4100"
```

Check out the [getting started guide for logcli](https://grafana.com/docs/loki/latest/getting-started/logcli/) to learn more about querying.


Save your `.bashrc` file and reload it with `source ~/.bashrc` or restart your shell!


#### Zsh

First we will configure zsh to send the history commands to Loki, starting by downloading a promtail config:

```bash
cd ~/.loki-shell/config
curl -O -L "https://raw.githubusercontent.com/slim-bean/loki-shell/master/cfg/promtail-logging-config.yaml"
```

Next open `~/.zshrc` in your favorite editor, and put this at or near the bottom.

```bash
function _send_to_loki() {
        (HISTTIMEFORMAT= builtin history -1 | 
        sed 's/^ *\([0-9]*\)\** *//' | 
        $HOME/.loki-shell/bin/promtail \
        -config.file=$HOME/.loki-shell/config/promtail-logging-config.yaml \
        --stdin -server.disable=true -log.level=error \
        --client.external-labels=host=$HOST 2>/dev/null &)
}
[[ -z $precmd_functions ]] && precmd_functions=()
[[ $precmd_functions =~ _send_to_loki ]] || precmd_functions=($precmd_functions _send_to_loki)
```

Next find this line that fzf installed:

```bash
[ -f ~/.fzf.zsh ] && source ~/.fzf.zsh
```

Immediately after this we are going to overload the function fzf uses for showing the history with our own function that uses logcli to get the logs from Loki:

NOTE: If you are running Loki on a different host or port change `--addr=http://localhost:4100` accordingly.

```bash
[ -f ~/.fzf.zsh ] && source ~/.fzf.zsh

fzf-history-widget() {
  local selected num
  setopt localoptions noglobsubst noposixbuiltins pipefail no_aliases 2> /dev/null
  selected=( $($HOME/.loki-shell/bin/logcli query '{job="shell"}' --addr=http://localhost:4100 --limit=50000 --batch=1000 --since=720h -o raw --quiet | stdbuf -o0 awk '!seen[$0]++' |
    FZF_DEFAULT_OPTS="--height ${FZF_TMUX_HEIGHT:-40%} $FZF_DEFAULT_OPTS -n2..,.. --tiebreak=index --bind=ctrl-r:toggle-sort $FZF_CTRL_R_OPTS --query=${(qqq)LBUFFER} +m" $(__fzfcmd)) )
  local ret=$?
  if [ -n "$selected" ]; then
    selected=$(echo $selected | tr -d '\n')
    zle -U $selected
  fi
  zle reset-prompt
  return $ret
}
```

Optional, but I also recommend adding an alias to logcli so you can query Loki directly for your history:

```bash
alias hist="$HOME/.loki-shell/bin/logcli --addr=http://localhost:4100"
```

Check out the [getting started guide for logcli](https://grafana.com/docs/loki/latest/getting-started/logcli/) to learn more about querying.

Save your `.zshrc` file and reload it with `source ~/.zshrc` or restart your shell!

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

Remove all the download files and data files:

```
sudo rm -rf ~/.loki-shell
```

Uninstall fzf (optional, you can still keep and use fzf if you like it)

```
~/.fzf/uninstall
rm -rf ~/.fzf
```






