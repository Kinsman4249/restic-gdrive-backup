# restic-gdrive-backup

Automated daily backups to Google Drive using [restic](https://restic.net/) and [rclone](https://rclone.org/), with email alerts sent through the [smtp2go](https://www.smtp2go.com/) HTTP API when something goes wrong.

## What it does

- Backs up your chosen paths to a restic repository on Google Drive every day
- Prunes old snapshots automatically using a keep-daily / keep-weekly / keep-monthly policy
- Emails you when a backup or prune fails
- Runs a twice-daily watchdog that emails you if no backup has succeeded in N days (the failure mode you would otherwise never notice)

## How it works

Three small bash scripts, wired together by systemd timers:

| Script | Purpose | Schedule |
| ------ | ------- | -------- |
| `install.sh` | Interactive setup: asks questions, writes config, installs everything | Run manually |
| `restic-backup.sh` | Runs the backup and prune, alerts on failure, records success time | Daily (systemd timer) |
| `restic-check-stale.sh` | Alerts if the last successful backup is older than the limit | 09:00 and 21:00 daily |

All configuration lives in `/etc/restic/backup.conf`. Secrets (the restic passphrase and the smtp2go API key) live in separate root-only files with `600` permissions.

Alert emails are sent over HTTPS to the smtp2go API using an API key. No SMTP connection, username, or password is involved.

## Requirements

- A Linux system with systemd
- `restic`, `rclone`, and `curl` installed and in `PATH`
- An rclone remote configured for your Google Drive (run `rclone config`, name it `gdrive` or adjust the repository path during install)
- A free or paid [smtp2go](https://www.smtp2go.com/) account with:
  - An API key (dashboard: Settings, then API Keys)
  - A verified sender address or domain matching the from-address you configure

## Installation

```bash
git clone https://github.com/Kinsman4249/restic-gdrive-backup.git
cd restic-gdrive-backup
sudo bash ./install.sh
```

The installer asks for:

1. Paths to back up and the restic repository location
2. Retention policy (how many daily, weekly, monthly snapshots to keep)
3. The source (from) and destination (to) email addresses for alerts
4. The restic passphrase and the smtp2go API key (hidden input, stored in root-only files)

Re-run `sudo bash ./install.sh` at any time to change settings. Your previous answers are offered as the defaults.

## Configuration reference

Everything is stored in `/etc/restic/backup.conf`:

| Variable | Purpose | Default |
| -------- | ------- | ------- |
| `BACKUP_PATHS` | Space-separated list of paths to back up | `/` |
| `RESTIC_REPOSITORY` | Where backups are stored | `rclone:gdrive:backups/<hostname>` |
| `RESTIC_PASSWORD_FILE` | Root-only file holding the restic passphrase | `/etc/restic/passphrase` |
| `EXCLUDE_FILE` | Paths restic should skip | `/etc/restic/excludes` |
| `STATE_FILE` | Timestamp of the last successful backup | `/var/lib/restic/last_success` |
| `LOG_FILE` | Where backup output is logged | `/var/log/restic-backup.log` |
| `KEEP_DAILY` | Daily snapshots to keep | `7` |
| `KEEP_WEEKLY` | Weekly snapshots to keep | `4` |
| `KEEP_MONTHLY` | Monthly snapshots to keep | `6` |
| `STALE_MAX_DAYS` | Alert if no success in this many days | `3` |
| `ALERT_FROM` | Source (from) address for alert emails | `backup-alerts@<hostname>` |
| `ALERT_TO` | Destination (to) address for alert emails | `root@<hostname>` |
| `SMTP2GO_API_KEY_FILE` | Root-only file holding the smtp2go API key | `/etc/restic/smtp2go_api_key` |
| `SMTP2GO_API_URL` | smtp2go send endpoint | `https://api.smtp2go.com/v3/email/send` |

The file is safe to hand-edit. Changes take effect on the next timer run.

## Email alerts

Alerts are sent by POSTing JSON to the smtp2go `email/send` endpoint with `curl`. The API key is read from `SMTP2GO_API_KEY_FILE` at send time and piped to curl on stdin, so it never appears in the process list or in the config file.

You will get an email when:

- A backup fails (with the full restic output in the body)
- A prune fails
- The watchdog finds no successful backup within `STALE_MAX_DAYS` days

Note: smtp2go only delivers mail from senders you have verified. Verify your from-address (or its whole domain) in the smtp2go dashboard before relying on alerts.

## Testing

To verify a change or a fresh install:

1. Syntax-check the scripts: `bash -n install.sh restic-backup.sh restic-check-stale.sh`
2. Lint them if you have [shellcheck](https://www.shellcheck.net/): `shellcheck *.sh`
3. Run a manual backup and watch the output: `sudo /usr/local/bin/restic-backup.sh`
4. Confirm a snapshot exists: `sudo restic -r <your-repository> snapshots` (or source the config first)
5. Test alert delivery end to end: temporarily set `STALE_MAX_DAYS="0"` in `/etc/restic/backup.conf`, run `sudo /usr/local/bin/restic-check-stale.sh`, confirm the email arrives, then set the value back

## Restoring

Backups you cannot restore are not backups. Periodically run a test restore:

```bash
# List snapshots
sudo restic -r rclone:gdrive:backups/<hostname> --password-file /etc/restic/passphrase snapshots

# Restore the latest snapshot to a scratch directory
sudo restic -r rclone:gdrive:backups/<hostname> --password-file /etc/restic/passphrase \
    restore latest --target /tmp/restore-test
```

## Uninstalling

```bash
sudo systemctl disable --now restic-backup.timer restic-check-stale.timer
sudo rm /etc/systemd/system/restic-backup.{service,timer} /etc/systemd/system/restic-check-stale.{service,timer}
sudo systemctl daemon-reload
sudo rm /usr/local/bin/restic-backup.sh /usr/local/bin/restic-check-stale.sh
sudo rm -r /etc/restic /var/lib/restic   # removes config and secrets; snapshots on Google Drive are untouched
```

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md) for how to report bugs, propose features, and submit changes. This project follows the [Code of Conduct](CODE_OF_CONDUCT.md), and security issues should be reported privately per [SECURITY.md](SECURITY.md).

## License

This project is licensed under the [Business Source License 1.1](LICENSE).

In short: you may use it freely, including in production for backing up systems you own or operate. You may not offer it to third parties as a commercial backup, hosting, or managed service. On 2030-07-08 the license automatically converts to the GNU General Public License, version 3.0.

This summary is not legal advice; the [LICENSE](LICENSE) file is authoritative.
