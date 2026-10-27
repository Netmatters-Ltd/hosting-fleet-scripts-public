# Bootstrapping a server

Do this once per server. After that the agent keeps itself and everything else up to date through releases.

## Before you start

- A new server is given a temporary rollout order on its first check-in. Review it on the Status page.
- You need the n8n address and the fleet token from our password manager.
- You need the current release number and its approved checksum from the n8n **Fleet Status** page.
- The server needs `curl`, `sha256sum`, `tar`, `flock` and `timeout`. All our supported Ubuntu, CentOS and CloudLinux versions have them.

## Steps (as root)

```bash
curl -fsSLO https://raw.githubusercontent.com/Netmatters-Ltd/hosting-fleet-scripts-public/main/bootstrap.sh
less bootstrap.sh            # read it
 N8N_BASE=<n8n address> FLEET_TOKEN=<token> bash bootstrap.sh <release> <sha256-from-n8n-status-page>
```

Both values are in our password manager. Start the line with a space so the token stays out of shell history. `--token` and `--n8n` work too, and anything you leave out is asked for.

The script:
1. Downloads the release and checks it against both GitHub's checksum and the one you typed in. If either differs, it stops.
2. Takes the n8n address and fleet token (from the options, or asks), and writes `/netmatters/fleet-agent/fleet-agent.conf` (root only, mode 0600). An existing file is left alone.
3. Installs the agent and its 15-minute timer (a cron fallback is used if there's no systemd).
4. Runs the agent once. The agent then asks n8n and installs the full release through the normal route.

Check it worked with `nm-fleet-agent --status`, and on the n8n Fleet Status page.

## Per-server settings

Add these to `/netmatters/fleet-agent/fleet-agent.conf` as needed. Components don't need their own webhook settings: they post to `N8N_BASE` plus a fixed path, with the fleet token.

| Setting | Used by | Example |
|---|---|---|
| `FLEET_SKIP_COMPONENTS` | Agent | `"disk-space lynis-audit"` to never apply those components here |
| `DISK_PATHS` | `disk-space` | `"/block_storage/home/*"` to override folder discovery |

## Useful commands

```bash
nm-fleet-agent --status          # installed release, next check
nm-fleet-agent --now             # check now, ignoring any wait
tail -50 /netmatters/fleet-agent/state/agent.log
ls /netmatters/fleet-agent/state/logs/
nm-run --name lynis-audit --monthly --show   # when a scheduled job runs on this server
```
