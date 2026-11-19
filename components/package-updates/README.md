# package-updates

`files/netmatters/updates/nm-safe-update.sh` upgrades one family of packages (`--profile php` or `--profile nginx`) on an Ubuntu/Debian nginx server, without breaking the sites on it. Read the header of the script for the full sequence and exit codes.

It can be run by hand over SSH (below). As a component, it never changes packages by itself:

- `applies.sh`: Ubuntu/Debian servers running nginx, without cPanel, unless `fleet-agent.conf` has `FLEET_UPDATES=0` (opt-out, since updates only run when someone asks).
- `install.sh`: sets permissions and makes `/netmatters/updates`. It doesn't install `dpkg-repack`, so an update is refused where the old packages can't be found in the apt cache or downloaded.
- On-demand requests `update-php` and `update-nginx` run the script with `--yes --max-sites 25`. They're offered on Fleet Status (On demand dropdown) and on the CVE check page (Fleet column, on nginx and PHP rows only).
- No clear-down for now: no cron, and runs don't prune. Old rollback copies stay until someone runs `--prune`.

Still to come: campaigns that update many servers in rollout steps and pause on the first failure.

## Running it by hand

```bash
scp nm-safe-update.sh root@SERVER:/root/
ssh root@SERVER
apt-get install -y dpkg-repack          # optional, so a rollback copy can always be made
bash /root/nm-safe-update.sh --profile php --dry-run
bash /root/nm-safe-update.sh --profile php
```

- Start with one canary server, then the rest a few at a time.
- Log: `/netmatters/logs/safe-update-<profile>.log`
- Rollback copies: `/netmatters/updates/rollback/<profile>-<time>/`. This holds the old packages, `configs.tar` (all of `/etc/nginx` and `/etc/php` from before the upgrade) and `manifest.sha256`. After a rollback, the config the upgrade left behind is in `changed-config/`, for comparing.
- After a rollback (exit 2) the packages are held. Once fixed: `apt-mark unhold <packages>`.
- Exit 3 means the rollback didn't work. Look at the server straight away.
- After an upgrade or a rollback it runs `/netmatters/patches/report-patch-versions.sh`, so the asset data shows the new versions straight away. Servers without the fleet agent skip this, and a failed send doesn't change the result.

## Tidying up

Off for now: runs don't prune and there's no cron. `nm-safe-update.sh --prune` tidies up by hand:

- Rollback copies are kept for 30 days, or 90 days for runs that rolled back.
- The newest 3 per profile are always kept, whatever their age.
- A log over 5 MB is cut down to its last 2,000 lines.
- Only folders named exactly as the script creates them (`php-<time>`, `nginx-<time>`) are ever removed.

Not supported yet, and refused: cPanel (ea-php), yum servers, servers without nginx, and any server with Apache installed.
