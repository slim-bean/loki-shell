# loki-shell

This project is all about how to use Loki to store your shell history!

This README picks up where this [article](article/article.md) left off, which covers getting started.


## Good stuff to know 

When you hit `ctrl-r` the default configuration will query Loki for the last 30 days of logs for the host you are on and pass them to fzf, the line limit is 50,000 lines.

If your shell history for this machine is longer than 50k lines you won't get all the results for 30 days, you will get the 50k most recent.

If you want to query more than 30days use logcli via the `hist` command alias we setup, likewise if you want to query multiple hosts use the `hist` alias or Grafana.

If you don't need 30 days of shell history every time you hit `ctrl-r` in the .xxxxrc file change `--since=720h` to something shorter and source the file or restart your shell.

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
      max_period: 5s    # Keep retries short such that terminal is still usable if Loki is unavailable
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

Loki failures and issues should be visible in the loki log file.

## Tweaking



## Extras

Running Loki remotely



TO 

Now you need to make a decision, Loki supports many backend stores I would suggest using a cloud storage option like s3.  It provides durability offsite for your command history as well as makes it very easy to move where you are running Loki without having to copy any data files.

However if you don’t want to create an s3 bucket and you want to just get started quickly you can keep all the files on the local filesystem. It will still be possible to move to an s3 bucket later, directions [here](FIXME).

Choose your adventure:




Check the logs and you should see something like this:

```bash
docker logs loki-shell
```

```none
level=info ts=2020-08-23T13:06:21.1927609Z caller=loki.go:210 msg="Loki started"
level=info ts=2020-08-23T13:06:21.1929967Z caller=lifecycler.go:370 msg="auto-joining cluster after timeout" ring=ingester
```

