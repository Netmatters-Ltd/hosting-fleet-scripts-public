# Netmatters fleet releases

Scripts, config and cron jobs installed on Netmatters-managed servers by the fleet agent (`nm-fleet-agent`). This repository is public, so **nothing secret goes in it**: no tokens, passwords, webhook UUIDs, customer names or hostnames. Per-server settings live in `/netmatters/fleet-agent/fleet-agent.conf` on each server (see `bootstrap.md`).

## How a release reaches a server

1. A change is merged to `main` through a reviewed pull request, with `LATEST` and `release.json` bumped to the new release number.
2. Tagging that commit `r<N>` makes GitHub Actions build `release-<N>.tar` with `make-release.sh` and publish it with its `.sha256`.
3. An approver checks out the same commit, runs `./make-release.sh` themselves, and enters the checksum they got, plus the rollout plan, in the n8n **Approve Release** form. Never copy the checksum from GitHub.
4. Every 15 minutes each server reads `LATEST`. If it's newer than what's installed, the agent asks n8n whether this server's rollout step is open, downloads the tarball, and installs it only if its checksum matches both GitHub's and n8n's.
5. Each server reports the result to n8n. Failures past the threshold pause the release automatically.

## Layout

```
LATEST                 release number servers compare against
release.json           {"release": N, "notes": "..."}; must match LATEST
make-release.sh        reproducible build (GNU tar, Linux or WSL)
check-release.sh       Ubuntu/CentOS and destructive-command checks, run by make-release.sh
bootstrap.sh / .md     first-time install of the agent on a server
components/<name>/     shipped in the next release
staged/<name>/         ready but not shipped yet; git mv into components/ to release
```

A component can have:

| Path | Purpose |
|---|---|
| `applies.sh` | Optional. Exit 0 if the component belongs on this server, anything else to skip it (its cron files are then removed). |
| `files/` | Copied onto `/` at the same paths, owned by root. Everything arrives as mode 0644; set real modes in `install.sh`. |
| `install.sh` | Optional. Runs after the files are copied, as root, with a 10 minute limit. Must be safe to run again and again, and exit non-zero on failure. |
| `cron/<name>` | Installed as `/etc/cron.d/netmatters-<name>`. Names: lower case letters, digits and dashes only. |
| `files/netmatters/fleet-agent/on-demand/<name>` | Optional. Lets n8n ask for this job to run now (see below). |

Each release is the **complete** set of components. Anything not in a release is removed where the agent manages it (its `netmatters-*` cron files), so dropping a component from `components/` stops its jobs everywhere.

## Scheduling jobs

Cron files are identical on every server, so use `nm-run` to spread the estate out. It picks a day and delay for each server from its hostname, and they stay the same between runs:

```
0 2 * * * root /netmatters/fleet-agent/bin/nm-run --name disk-space --monthly --spread 14400 -- /netmatters/disk-space/report-disk-space.sh
```

`--daily`, `--weekly`, `--twice-monthly` or `--monthly`, plus `--spread <seconds>` of random-looking but fixed delay. The output of the last run is in `/netmatters/logs/<name>.log`. On a server, `nm-run --name <job> --monthly --show` prints when it runs there.

## On-demand requests

From agent 1.1.0, every run (every 15 minutes) also asks n8n whether anything has been requested for this server, such as **Refresh packages** on the Status page. n8n only ever sends a request ID and a name. The agent runs a name only if this server has a definition file for it, `/netmatters/fleet-agent/on-demand/<name>`, which a component ships under its `files/`, so it only exists where that component applies.

The definition's first line that isn't blank or a comment is the command: an absolute path under `/netmatters`, then optional fixed arguments. For example, `patch-versions` ships:

```
/netmatters/patches/report-patch-versions.sh
```

The agent runs it directly (never through a shell), only if root alone can change the definition and the command, with nothing from n8n passed to it. So n8n still can't make a server run anything that didn't arrive in an approved release. Each request:

- runs while the agent holds its lock, so never alongside a release install
- runs at most once every 15 minutes per name, and for at most 15 minutes
- logs to `/netmatters/logs/<name>-on-demand.log`
- reports `done`, `failed`, `refused` or `skipped` back to n8n.

To offer a new request, add the definition to a component, release it, and add the name and button label to `REQUESTS` in the Status page code (`n8n/code/status-request.js` and `status-page.js`). `nm-fleet-agent --status` lists the requests a server can run.

## Making a release

```bash
# on a branch
git mv staged/disk-space components/disk-space      # or edit components
echo 2 > LATEST                                      # and release.json
./make-release.sh                                    # check it builds
# open a pull request, get it reviewed, merge, then on main:
git tag r2 && git push origin r2
```

`make-release.sh` runs `check-release.sh` first, which fails the build if any component would break on Ubuntu 14.04+ or CentOS 7+, or does anything destructive (deleting or overwriting files, `crontab -`, stopping or restarting services, removing packages or accounts). If a flagged line is intended, end it with `# release-check: destructive-ok (why)` or `# release-check: portable-ok (why)`, so the reviewer sees exactly what was waved through.

Then approve it in n8n with the checksum from your own `./make-release.sh` run on the merged commit.

To roll back, release the old content again under a new, higher number. Servers never install a lower number than they have.
