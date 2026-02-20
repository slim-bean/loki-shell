# loki-shell

This project is all about how to use Loki to store your shell history!

This README picks up where this [article](article/article.md) left off, which covers getting started.

## What's New

### 2022/01/09

* Hitting `ctrl-r` again when the search window is open will search for ALL the shell history (removes the host label from the query) searching up to the last 12 months
* `export PRIVATE=true` will stop sending anything to Loki until you remove the environment variable with `unset PRIVATE`
* `export LS_LOCAL=true` will query the local history instead of Loki until you remove the environment variable with `unset LS_LOCAL`

## Installation

Here are some instructions to get you set up and run Loki yourself, integrated with your shell history.  

This guide is meant to keep things simple, so we will run Loki locally on your computer and store all the files on the filesystem.

**Note:** We will not be changing any existing behaviors around history, so **your existing shell history command and history settings will be untouched.** We are hooking command history to duplicate it to Loki via `$PROMPT_COMMAND` in Bash and `precmd` in Zsh, and on the `ctrl-r` side of things we are overloading the function fzf uses to hook the `ctrl-r` command. It is safe to try this, and if you decide you don't like it, follow the steps in the Uninstall section on the [git repo](https://github.com/slim-bean/loki-shell) to remove all traces. Your shell history will be untouched.


### Step 1: Install fzf

There are several ways to install fzf, but I prefer [the git instructions](https://github.com/junegunn/fzf#using-git), which are:
 
```bash 
git clone --depth 1 https://github.com/junegunn/fzf.git ~/.fzf
~/.fzf/install
```

_Say yes to all the prompted questions._

**NOTE** If you previously had fzf installed, make sure you have the key bindings enabled (make sure when you type ctrl-r, fzf pops up). You can re-run the fzf install to enable key bindings if necessary. 


### Step 2: Install loki-shell

Using the same model of installation as fzf, loki shell also has a git repo and install script:

```bash
git clone --depth 1 https://github.com/slim-bean/loki-shell.git ~/.loki-shell
~/.loki-shell/install
```

The first thing the script is going to do is create the `~/.loki-shell` directory where all files will be kept (including Loki data).

Next it will download binaries for Logcli and Loki, and check for (or download) jq.

Then you will get the first question:

```none
Do you want to install Loki? ([y]/n)
```

**For the best use of this tool, I highly recommend setting up Loki on a server somewhere with a cloud storage providers object storage as the backend**

This way your shell history can be saved from multiple computers and object storage can help protect it for all of time. Personally I run a Raspberry Pi on my home network with Loki running (just make sure it's a 64bit OS!!) and I send my history to Google Cloud Storage (S3 would work fine too!)

If you have a centralized Loki running already for loki-shell, answer `n` here.

If you don't have a central Loki, the script will help you setup Loki locally, it still can be nice to run Loki locally, and you could choose to use a remote object storage to save your shell history for increased durability! 

There are more detailed instructutions for the prompts around installing Loki in the [original article](article/article.md#step-2-install-loki-shell)


#### Shell integration

Regardless of how you installed Loki, you should now see a prompt:

```none
Enter the URL for your Loki server or press enter for default (http://localhost:4100)
```

If you had set up a centralized Loki, you would enter that URL here. However, for this demo we are going to use the default; you can just press enter.

A lot of text will spit out explaining all the entries added to your `~.bashrc` or `~.zshrc` (or both!).

That's it!

```none
Finished. Restart your shell or reload config file.
   source ~/.bashrc  # bash
   source ~/.zshrc   # zsh
```

## Good stuff to know 

When you hit `ctrl-r` the default configuration will query Loki for the last 30 days of logs for the host you are on and pass them to fzf, the line limit is 50,000 lines.

If your shell history for this machine is longer than 50k lines you won't get all the results for 30 days, you will get the 50k most recent.

If you hit `ctrl-r` Loki will be queried for all {job="shell"} logs with no `host` label for the past 12 months.

An alias called `hist` is created which configures `logcli` to connect to loki-shell and allow you to run custom queries.

If you don't need 30 days of shell history every time you hit `ctrl-r` in `~/.loki-shell/shell/loki-shell.xxsh` files change `--since=720h` to something shorter(or longer) and source the file or restart your shell.

If you are using the hist alias or grafana you can get all your shell history with the label `{job="shell"}`, to get a specific host `{job="shell",host="host1"}`, it's possible to use a regex to match multiple hosts too `{job="shell",host=~"host1|host2"}`

For a much more detailed list of query possibilities check out the [LogQL Guide](https://grafana.com/docs/loki/latest/logql/)

## Performance notes

Fastest performance will be using a filesystem and having Loki run locally, however this is probably the least durable.

I run Loki on a Raspberry Pi so I can connect to it from many machines, and the storage is in S3.  This combination is not the best for performance but there are optimizations in place to help with this.

In the Loki config we setup an in memory cache for chunks at 50MB, and we also set the ttl for index queries to 30 days.  
What this means is that once Loki has fetched the data for any query subsequent calls will not need to hit the object store and will be processed very quickly.

This does mean that after a restart of Loki or if you haven't queried it in a while there might be a longer pause if it has to fetch index or chunk files from the object store.

In practice this is usually manageable because logcli batches the requests and streams them to fzf, so the most recent 1000 results are available very quickly for searching while batches are fetched in the background.

## Storage Options

You most likely will want to upgrade from the filesystem config to an object store in the cloud for better durability of your data and easier access.

These are essentialy the same instructions for running with docker but they use a different config file with an `s3` compatible store instead.

I'm using [Wasabi](https://wasabi.com/) because it was cheaper and something new to try, I don't know how good it is yet but so far it's been no problems.

NOTE: This will replace the default local config created by the startup script, but you can always recreate that file by deleting `config/loki-docker-config.yaml` and re-running the install.

```bash
cd ~/.loki-shell/
cp cfg-template/loki-docker-s3-config.yaml config/loki-docker-config.yaml
```

Open the file in your favorite editor and you will need these two lines with your bucket info:

```bash
s3: https://ACCESS_KEY_ID:SECRET_ACCESS_KEY@s3.wasabisys.com/BUCKET_NAME 
region: REGION 
```

Save your changes and restart Loki!

```bash
docker restart loki-shell
```

Migrating existing data is possible but I need to make available a tool to do this which is currently a bit hacked together, more to come here.

## Durability

Loki does not have a Write Ahead Log for in memory data yet, it's coming but it's not here yet. 
What this means is: if you shutdown or kill log without sending a SIGTERM first and letting it shutdown on it's own, **YOU WILL LOSE UP TO 1H OF SHELL COMMANDS**

Always safely shutdown the process.

Or you can `curl http://localhost:4100/flush` to manually force a flush of all streams in memory before shutting down.

If you want an even more durable setup consider running two Loki instances against the same s3 bucket. You can configure loki-shell to send to a second instance by setting `LOKI_URL_2` in your shell config alongside `LOKI_URL`.

This _does_ result in double the data in the object store however Loki will handle and de-duplicate this data at query time.  All of this increases processing time, storage, costs etc but is how I run my setup.

### Spool file (offline WAL)

loki-shell includes a spool file at `~/.loki-shell/data/spool` that acts as a simple write-ahead log. If Loki is unreachable when a command is entered, the command is appended to the spool file. On the next command entry, loki-shell will attempt to drain the spool (in timestamp order) before sending the new command, ensuring Loki always receives entries in chronological order.

## Troubleshooting

Failures to send to Loki are sent to the system log via the `logger` command, search your system log for the tag `loki-shell`.

Loki failures and issues should be visible in the loki log file either with `docker logs loki-shell` or wherever systemd logs depending on how you ran Loki.

If `ctrl-r` doesn't produce any results, you can test the command used in the history function manually:

```
$HOME/.loki-shell/bin/logcli query "{job=\"shell\", host=\"$HOSTNAME\"}" --addr=$LOKI_URL --limit=50000 --batch=1000 --since=720h -o raw --quiet
```

## Uninstalling

An uninstall script is included:

```
~/.loki-shell/uninstall
```


## Updates

If you installed fzf the git install method always gets you the most recent version and also makes updates as simple as:

```bash
cd ~/.fzf
git pull
./install
```

Similarly loki-shell can be updated:

```bash
cd ~/.loki-shell
git pull
./install
```

Note, config files for Loki are in the `~/.loki-shell/config` directory, the initial install copies them from `~/.loki-shell/cfg-template`

Running install again to update will not replace these files once copied so you may want to manually diff any changes in `cfg-template` against the files in `config`
