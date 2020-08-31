# loki-shell

This project is all about how to use Loki to store your shell history!

This README picks up where this [article](article/article.md) left off, which covers getting started.

## Good stuff to know 

When you hit `ctrl-r` the default configuration will query Loki for the last 30 days of logs for the host you are on and pass them to fzf, the line limit is 50,000 lines.

If your shell history for this machine is longer than 50k lines you won't get all the results for 30 days, you will get the 50k most recent.

If you want to query more than 30days use logcli via the `hist` command alias, likewise if you want to query multiple hosts use the `hist` alias or Grafana.

If you don't need 30 days of shell history every time you hit `ctrl-r` in `~/.loki-shell/shell/loki-shell.xxsh` files change `--since=720h` to something shorter and source the file or restart your shell.

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

If you want an even more durable setup consider running two Loki instances against the same s3 bucket and configuring promtail to send to both:

```yaml
clients:
  - url: http://localhost:4100/loki/api/v1/push   # Make sure this port matches your Loki http port
    backoff_config:
      max_period: 5s    
      max_retries: 3
  - url: https://some.other.host:4100/loki/api/v1/push
    backoff_config:
      max_period: 5s
      max_retries: 3
```

Please note the short retry times and period, this is to keep the promtail processes running for a short time in the background. If your network or Loki instances are down promtail will give up rather quickly, 15s at most, before abandoning your shell commands. 
You can increase these timeouts just be aware if a remote endpoint is slow or unavailable the promtail process will stay running in the background trying to send logs until it times out, you could end up with a lot of them if you keep entering commands.

This _does_ result in double the data in the object store however Loki will handle and de-duplicate this data at query time.  All of this increases processing time, storage, costs etc but is how I run my setup.

## Troubleshooting

Failures to send to loki via the promtail instances are sent to the system log via the `logger` command, search your system log for the tag `loki-shell-promtail`.

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

Note, config files for Loki and Promtail are in the `~/.loki-shell/config` directory, the initial install copies them from `~/.loki-shell/cfg-template`

Running install again to update will not replace these files once copied so you may want to manually diff any changes in `cfg-template` against the files in `config`