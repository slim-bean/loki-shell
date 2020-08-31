# Level up your shell history with Loki and fzf

Loki is an Apache 2.0 licensed open source log aggregation framework designed by Grafana Labs and built with tremendous support from a growing community -- as well as the project I work on every day. My goal with this article is to provide an introduction to Loki in a hands-on way. I thought rather than just talking about how Loki works, a concrete use case that solves some real problems would be much more engaging! A special thanks to my peer Jack Baldry for planting the seed for this idea, I had the Loki knowledge to make this happen but if it weren’t for him suggesting this I don’t think we ever would have made it here.

## The Problem: Durable Centralized Shell History

I love my shell history and have always been a fanatical _ctrl-r_ user.  About a year ago my terminal life was forever changed when my peer Dieter Plaetinck introduced me to the command line fuzzy finder, fzf.

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
* Flexibility: Loki is available in a single binary to be downloaded and run directly. It is also provided as a Docker image to run in any container environment. A Helm chart is available to get started quickly in Kubernetes. If you really demand a lot from your logging tools, look at the [production setup running at Grafana Labs](https://grafana.com/docs/loki/latest/installation/tanka/). Ksonnet and the open source [Tanka](https://tanka.dev/) are used to deploy that same Loki image as discrete building blocks enabling massive horizontal scaling, high availability, replication, separate scaling of read and write paths, highly parallelizable querying, and more.

In summary, Loki takes the approach of keeping a small index of metadata about your logs (labels) and storing log content itself unindexed and compressed in inexpensive object stores to make operating easier and cheaper. The application is built to run as a single process and easily evolve into a highly available distributed system. High query performance can be obtained on larger logging workloads through parallelization and sharding of queries, a bit like MapReduce for your logs.  

The best part? All of this functionality is available for anyone to use, for free, today. Following in the footsteps and success of Grafana, Grafana Labs is committed to making Loki a fully featured, fully open log aggregation software anyone can use.

## The Solution

I'm now running Loki on a Raspberry Pi on my home network which is storing my shell history offsite in an S3 bucket.

When I hit `ctrl-r` [Logcli] is used to make several batching requests which are streamed into fzf, here is an example with the top showing the logs of the Loki server on the Pi.

![example](assets/example_logcli.gif)

Ready to give it a try?

Here are some instructions to get you setup and running Loki yourself, integrated with your shell history.  

This guide is meant to keep things simple so we will run Loki locally on your computer and store all the files on the filesystem.

All of this information as well as ways you can setup a more elaborate installation can be found here: https://github.com/slim-bean/loki-shell

**Note:** We will not be changing any existing behaviors around history, **your existing shell history command and history settings will be untouched.** We are hooking command history to duplicate it to Loki via `$PROMPT_COMMAND` in Bash and `precmd` in Zsh, and on the `ctrl-r` side of things we are overloading the function fzf uses to hook the `ctrl-r` command.  It is safe to try this and if you decide you don't like it follow the steps in the Uninstall section on the [git repo](https://github.com/slim-bean/loki-shell) to remove all traces, your shell history will be untouched.


### Step 1: Install fzf

There are several ways to install fzf but I prefer [the git instructions](https://github.com/junegunn/fzf#using-git) which are:
 
```bash 
git clone --depth 1 https://github.com/junegunn/fzf.git ~/.fzf
~/.fzf/install
```

_Say yes to all the prompted questions._

**NOTE** If you previously had fzf installed, make sure you have the key bindings enabled (make sure when you type ctrl-r fzf pops up). You can re-run the fzf install to enable key bindings if necessary. 


### Step 2: Install loki-shell

Using the same model of installation as fzf, loki shell also has a git repo and install script:

```bash
git clone --depth 1 https://github.com/slim-bean/loki-shell.git ~/.loki-shell
~/.loki-shell/install
```

The first thing the script is going to do is create the `~/.loki-shell` directory where all files will be kept (including Loki data)

Next it will download binaries for Promtail, Logcli, and Loki

Then you will get the first question:

```none
Do you want to install Loki? ([y]/n)
```

If you have a centralized Loki running already for loki-shell you could answer `n` here, however we want to answer `y` or press enter.

There are two options available for running Loki locally, as a docker image (recommended) or as the single binary (with support for adding a systemd service).

I recommend using Docker if it's available as I think it simplifies operations a bit, but both work just fine!

#### Docker

```none
[y] to run Loki in Docker, [n] to run Loki as a binary ([y]/n) y
Error: No such object: loki-shell
Error response from daemon: No such container: loki-shell
Error: No such container: loki-shell
54843ff3392f198f5cac51a6a5071036f67842bbc23452de8c3efa392c0c2e1e
```

If this is the first time running the install you can disregard the Error messages, this script will stop and replace a running Loki container if the version does not match allowing you to re-run this script to upgrade Loki.

This is it! Loki is now running as a Docker container.

Data from Loki will be stored in `~/.loki-shell/data`

The image is run with `--restart=unless-stopped` so it will restart at reboot but will stay stopped if you run `docker stop loki-shell`

You can skip to _Shell integration_

#### Binary

There are many ways to run a binary on a linux system, this script can install a systemd service.  If you don't have systemd you can still use the binary install:

```none
[y] to run Loki in Docker, [n] to run Loki as a binary ([y]/n) n

Run Loki with systemd? ([y]/n) n

This is as far as this script can take you
You will need to setup an auto-start for Loki
It can be run with this command: /home/username/.loki-shell/bin/loki -config.file=/home/username/.loki-shell/config/loki-binary-config.yaml
```

The script will spit out the command you need to use to run Loki and you will be on your own to setup an init script or another method of auto-starting it.

You can just run the command directly if you want and run Loki from your current shell!

If you _DO_ have systemd, you have the option of letting the script install the systemd service or showing you the commands to run yourself:

```none
Run Loki with systemd? ([y]/n) y

Installing the systemd service requires root permissions.
[y] to run these commands with sudo [n] to print out the commands and you can run them yourself. ([y]/n) n
sudo cp /home/ed/.loki-shell/config/loki-shell.service /etc/systemd/system/loki-shell.service
sudo systemctl daemon-reload
sudo systemctl enable loki-shell
sudo systemctl start loki-shell
Copy these commands and run them when the script finishes. (press enter to continue)
```

#### Shell integration

Regardless of how you installed Loki, you should now see a prompt:

```none
Enter the URL for your Loki server or press enter for default (http://localhost:4100)
```

If you had setup a centralized Loki you would enter that URL here, however for this demo we are going to use the default, you can just press enter.

A lot of text will spit out explaining all the entries added to your `~.bashrc` or `~.zshrc` (or both!)

That's it!

```none
Finished. Restart your shell or reload config file.
   source ~/.bashrc  # bash
   source ~/.zshrc   # zsh
```

### Step 4: Try it out!

Start using your shell and use `ctrl-r` to see your commands show up.

Open multiple terminal windows, type a command in one and `ctrl-r` in another and see your commands available immediately.

Also notice that when switching between terminals and entering commands they are available immediately by `ctrl-r` but the operation of the up-arrow is not affected between terminals! (this may not be true with oh-my-zsh installed which automatically appends all commands to the history)

Use `ctrl-r` multiple times to toggle between sorting by time and relevance.

**Note:** The configuration applied here will only show the query history for the current host even if you are sending shell data from multiple hosts to Loki, I think by default this makes the most sense.  There is a lot you can tweak here if you would like this behavior to change, see the [repo](https://github.com/slim-bean/loki-shell) to learn more.


Also installed is a an alias called `hist`:

```bash
alias hist="$HOME/.loki-shell/bin/logcli --addr=$LOKI_URL"
```

Logcli can be used to query and search your history directly in Loki, allowing you to search other hosts

Check out the [getting started guide for logcli](https://grafana.com/docs/loki/latest/getting-started/logcli/) to learn more about querying.

LogQL metric queries can let you do some interesting things like see how many times I issued the `kc` command (my alias for kubectl) in the last 30days:

![count](assets/count_kc.png)

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

Or you can start exploring the world of metrics from logs `rate({job="shell"}[1m])` to see how often you are using your shell:

![last_20_days](assets/last_20.png)

Want to reconstruct a timeline from an incident, filter by a specific command and see when it was run:

![command_history](assets/command_hist.png)

To see what else you can do and learn more about Loki's query language [check out this LogQL guide](https://grafana.com/docs/loki/latest/logql/).

## Final thoughts

For more ideas, troubleshooting and updates follow the [git repo](https://github.com/slim-bean/loki-shell). This is still a work in progress so please report any issues there as well.

To learn more about Loki, check out [the documentation](https://grafana.com/docs/loki/latest/), [blog posts](https://grafana.com/categories/loki/), and [git repo](https://github.com/grafana/loki)

