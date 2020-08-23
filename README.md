# loki-shell-history

One of the first things I always do when setting up a new computer is `vi ~/.bashrc` and change the shell history settings.

Adding a few zeros to the `HISTSIZE` and `HISTFILESIZE` variables as well as setting `HISTTIMEFORMAT`:

```
HISTSIZE=10000000
HISTFILESIZE=20000000
HISTTIMEFORMAT="%F %T "
```

The next thing I do is install fzf https://github.com/junegunn/fzf with key bindings so that `ctrl -r` shows my history with fzf.

I'm a very heavy user of searching my bash history when working from a terminal, and this combination works very well for me.

With a few exceptions...

* I often have many terminal windows open and very often they are closed in a way they don't persist the history.
* I use separate VM's and machines a lot, it would be nice if I could centralize that history.

I've seen suggestions to solve the first problem by setting something like this in your `~/.bashrc` file:

```
export PROMPT_COMMAND="history -a; history -c; history -r; ${PROMPT_COMMAND}"
```

However this has one big drawback, it interferes with the operation of the up arrow when bringing up previous commands, you can remove the `-c` and `-r` flags but then you won't get updates from other shells.

This repo contains instructions on how I used Grafana Loki to solve both of these problems.

## Some background on Loki

[Grafana Loki](https://github.com/grafana/loki) is a log aggregation application built to store both small and extremely large volumes of logs in an easy to operate way.

**Full Disclosure** I work on the Loki project so this is either a really clever use of Loki or it's one of those cases when you have a hammer, everything looks like a nail.

The good news is you don't have to trust me because it's very easy to try this yourself, so let's look at how to set things up.

For starters, Loki can run as a relatively compact single binary either directly on your computer, consuming under 100MB of RAM.

For persistent storage you have a wide variety of options from the local filesystem to a number of object stores like S3, GCS, or Azure Blob. You can also use any of the S3 compatible services such as Wasabi (which I'm using), or something local like MinIO

If it turns out you generate a lot of command history Loki can also be horizontally scaled to handle terabytes of logs a day or more :)

NOTE: Loki is built on the concept of only indexing a small amount of metadata around your logs (labels), and storing the content unindexed and highly compressed.

If you are familiar with Prometheus, Loki uses the same label concept which is why it's like Prometheus but for logs.
Keeping a small index is the secret to Loki's success, for this setup we will only be using a couple labels

```nohighlight
job
host
``` 

the `job` label will be set to `shell` and the `host` label will be set to the `$HOSTNAME` of the computer.

This allows us to query our shell command history for all our hosts:

```nohighlight
logcli --addr=http://localhost:4100 query '{job="shell"}'
``` 

or a single host or multiple hosts using regex:

```nohighlight
logcli --addr=http://localhost:4100 query '{job="shell", host="host1"}'
logcli --addr=http://localhost:4100 query '{job="shell", host=~"host1|host2"}'
``` 

This is just a few examples, in fact there is a lot of querying you can do on your command history but we'll get to that at the end.

If you find yourself experimenting more with Loki after this check out these blog posts for more information on how to use labels successfully within loki


## Setting it up

### Initial Housekeeping

To start lets make a directory where we can store configs and our tooling:

```bash
cd ~
mkdir .loki-shell
cd .loki-shell/
git clone https://github.com/slim-bean/loki-shell-history.git
cp -r loki-shell-history/cfg/ .
```

The last command copies the config files out of the git repo and into `~/.loki-shell/cfg`.
This is optional, if you want you could fork my repo and keep your configs in source control, just be mindful with access keys and public git repos.

Other configs and settings in this guide will reference the config files in `~/.loki-shell/cfg`

In the future you can `git pull` this repo to see if there are changes or improvements made to the config file.

### Download

```bash
cd ~/.loki-shell
mkdir bin
cd bin
wget
wget
wget
```

If you are going to run Loki in docker you can skip the last download.



### fzf

I have a fork of fzf in which I changed the history command to query Loki when `ctrl-r` is pressed, in the future I would like to come up with a better way to handle this part and eliminate the need for a fork.

If you already have fzf installed it may be best to uninstall it and follow these steps, or you can try to find the `key-bindings.bash` file and replace it with the one from my fork in the `loki` branch.

My apologies, I only updated the bash keybindings, if you are using a different shell you can probably make similar changes based on what I did in `key-bindings.bash`.

#### Installing from git

```bash
cd ~
git clone https://github.com/slim-bean/fzf.git ~/.fzf
cd .fzf
git checkout loki
./install
``` 


### Setting up Loki

download config example and configure:

setup wasabi

create a bucket

no versioning, no logging

create a user

select `Programmatic (create API key)`

download or save the credentials

give the `WasabiFullAccess` permission

setup config file

#### Docker

docker run

#### Standalone

systemd

### Modify .bashrc

There are 2 changes we need to make to `.bashrc` the first is to make sure every command gets sent to Loki.

```shell
# Send all bash commands to Loki with promtail
function _send_to_loki {
        (HISTTIMEFORMAT= builtin history 1 | sed 's/^ *\([0-9]*\)\** *//' | promtail -config.file=/home/ed/projects/loki/cmd/promtail/promtail-logging-config.yaml --stdin -server.disable=true -log.level=warn --client.external-labels=host=$HOSTNAME 1>&2 &)
}
[[ $PROMPT_COMMAND =~ _send_to_loki ]] || PROMPT_COMMAND="_send_to_loki;${PROMPT_COMMAND:-:}"

# Put Promtail/Loki/Logcli binaries on the path
[[ $PATH =~ .loki-shell ]] || PATH="$HOME/.loki-shell/bin:${PATH:-:}"
```

## Extras

Running Loki remotely



TO 

Now you need to make a decision, Loki supports many backend stores I would suggest using a cloud storage option like s3.  It provides durability offsite for your command history as well as makes it very easy to move where you are running Loki without having to copy any data files.

However if you don’t want to create an s3 bucket and you want to just get started quickly you can keep all the files on the local filesystem. It will still be possible to move to an s3 bucket later, directions [here](FIXME).

Choose your adventure:


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