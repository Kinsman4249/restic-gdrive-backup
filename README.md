# restic-gdrive-backup

Automated daily backups to Google Drive using [restic](https://restic.net/) and [rclone](https://rclone.org/), with email alerts sent through the [smtp2go](https://www.smtp2go.com/) HTTP API when something goes wrong.

Backups are encrypted on your machine before anything is uploaded. Google only ever stores scrambled data it cannot read.

## What it does

- Encrypts every backup locally with a key you choose during install, so Google Drive never sees readable data
- Backs up your chosen paths to a restic repository on Google Drive every day
- Prunes old snapshots automatically using a keep-daily / keep-weekly / keep-monthly policy
- Emails you when a backup or prune fails
- Runs a twice-daily watchdog that emails you if no backup has succeeded in N days (the failure mode you would otherwise never notice)
- Captures the bootloader and disk layout before every backup (partition table, MBR boot code, filesystem UUIDs, GRUB config, boot mode), together with written restore notes that travel inside the backup
- Checks the Google Drive connection, the repository, and alert delivery during install, with plain troubleshooting steps when something fails

## How it works

Three small bash scripts, wired together by systemd timers:

| Script | Purpose | Schedule |
| ------ | ------- | -------- |
| `install.sh` | Interactive setup: asks questions, verifies connections, installs everything | Run manually |
| `restic-backup.sh` | Runs the backup and prune, alerts on failure, records success time | Daily (systemd timer) |
| `restic-check-stale.sh` | Alerts if the last successful backup is older than the limit | 09:00 and 21:00 daily |

All configuration lives in `/etc/restic/backup.conf`. Secrets (the encryption key and the smtp2go API key) live in separate root-only files with `600` permissions.

Alert emails are sent over HTTPS to the smtp2go API using an API key. No SMTP connection, username, or password is involved.

## Encryption and your key

restic encrypts everything (file contents, names, and metadata) with AES-256 on your machine, using the encryption key you enter during install. Encryption happens before upload, so Google Drive only stores ciphertext.

The key is stored in a root-only file, `/etc/restic/passphrase` by default. View it in the console with:

```bash
sudo cat /etc/restic/passphrase; echo
```

(the `; echo` just adds a line break so your shell prompt does not stick to the end of the key)

**Back the key up somewhere off the machine**: a password manager, or a printed copy in a safe place. Without the key the backups are permanently unreadable. There is no reset, and nobody (including Google) can recover the data for you. If the machine dies and the key only lived there, the backups die with it.

To make sure the copy you saved is correct (no copy/paste mistakes), test it at any time:

```bash
sudo bash ./install.sh --test-key
```

Paste your saved copy when prompted. The test compares it against the key file, points out stray whitespace picked up during copying, and then proves the pasted key actually unlocks the repository.

## Bootloader backup

A file-level backup cannot see the partition table, the boot code at the start of the disk, or UEFI firmware entries, so before every backup the script dumps them into `BOOTLOADER_BACKUP_DIR` along with the filesystem UUIDs, GRUB config copies, and the detected boot mode. That folder is always included in the snapshot, even when `BACKUP_PATHS` is a narrow list.

The folder also contains `RESTORE-NOTES.txt`: step-by-step recovery options written for hosting at Infomaniak (snapshot restore, rescue mode repair, and full rebuild), regenerated with the system's current disk names and UUIDs on every run. The notes are intentionally not duplicated in this README; they live inside every backup, next to the data they describe. To read them without doing a restore:

```bash
restic -r <your-repository> --password-file <key-file> dump latest /var/lib/restic/bootloader/RESTORE-NOTES.txt
```

## Requirements

- A Linux system with systemd
- `restic`, `rclone`, and `curl` (the installer checks for them and offers to install any that are missing, using apt, dnf, yum, zypper, or pacman)
- An rclone remote configured for your Google Drive **as root** (run `sudo rclone config`, name it `gdrive` or adjust the repository path during install)
- A free or paid [smtp2go](https://www.smtp2go.com/) account with:
  - An API key (dashboard: Settings, then API Keys)
  - A verified sender address or domain matching the from-address you configure

## Installation

```bash
git clone https://github.com/Kinsman4249/restic-gdrive-backup.git
cd restic-gdrive-backup
sudo bash ./install.sh
```

The installer first checks that `restic`, `rclone`, and `curl` are present. If any are missing, it detects your package manager and offers to install them, re-checking afterward and printing per-tool pointers if a package will not install.

The installer asks for:

1. Paths to back up and the restic repository location
2. Retention policy (how many daily, weekly, monthly snapshots to keep)
3. The source (from) and destination (to) email addresses for alerts
4. The encryption key for your backups and the smtp2go API key (hidden input, stored in root-only files)

It then verifies the whole chain before finishing:

- The rclone remote exists and can reach Google Drive, with interactive fixes when it does not: listing the remotes root can see, copying your user's rclone config to root, running `rclone config` on the spot, or refreshing the Google authorization
- The restic repository can be created, or unlocked with your key if it already exists
- smtp2go accepts a real test alert email (optional, recommended)

Every failed check prints plain troubleshooting steps. The installer ends with a reminder to back up your encryption key and an offer to test your saved copy on the spot.

Re-run `sudo bash ./install.sh` at any time to change settings. Your previous answers are offered as the defaults, and any custom lines you added to the config by hand are preserved.

## Upgrading from the SMTP version

If your `/etc/restic/backup.conf` was created by the old version that sent alerts over SMTP with a username and password, just re-run the installer. It detects the old settings and migrates cleanly:

- Every setting you chose before (paths, repository, retention, addresses) comes back as the default answer, so pressing Enter keeps it
- Custom lines you added to the config by hand are carried over untouched
- The retired SMTP host, port, username, and password entries are dropped from the rewritten config
- An smtp2go API key is required; the installer will not accept an empty one
- The old SMTP password file is no longer used, and the installer offers to delete it securely

## Configuration reference

Everything is stored in `/etc/restic/backup.conf`:

| Variable | Purpose | Default |
| -------- | ------- | ------- |
| `BACKUP_PATHS` | Space-separated list of paths to back up | `/` |
| `RESTIC_REPOSITORY` | Where backups are stored | `rclone:gdrive:backups/<hostname>` |
| `RESTIC_PASSWORD_FILE` | Root-only file holding the encryption key | `/etc/restic/passphrase` |
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
| `BOOTLOADER_BACKUP_DIR` | Folder refreshed before each backup with bootloader dumps and restore notes | `/var/lib/restic/bootloader` |

The file is safe to hand-edit. Changes take effect on the next timer run.

## Email alerts

Alerts are sent by POSTing JSON to the smtp2go `email/send` endpoint with `curl`. The API key is read from `SMTP2GO_API_KEY_FILE` at send time and piped to curl on stdin, so it never appears in the process list or in the config file.

You will get an email when:

- A backup fails (with the full restic output in the body)
- A prune fails
- The watchdog finds no successful backup within `STALE_MAX_DAYS` days

Note: smtp2go only delivers mail from senders you have verified. Verify your from-address (or its whole domain) in the smtp2go dashboard before relying on alerts. The installer's test email catches this early.

## Monitoring a backup

The scheduled backup runs in the background with no terminal attached. Ways to watch it:

```bash
# Is a backup running right now, and when is the next one due?
systemctl status restic-backup.service
systemctl list-timers restic-backup.timer

# Follow the log as the script writes it
sudo tail -f /var/log/restic-backup.log

# The same lines, through systemd's journal
sudo journalctl -fu restic-backup.service

# Watch the bytes actually landing in Google Drive (refreshes every 60 seconds)
sudo watch -n 60 rclone size gdrive:backups/<hostname>

# Inspect the repository between runs
sudo restic -r rclone:gdrive:backups/<hostname> --password-file /etc/restic/passphrase snapshots
sudo restic -r rclone:gdrive:backups/<hostname> --password-file /etc/restic/passphrase stats
```

Two things to know:

- The backup script collects restic's output and writes it to the log when each stage finishes, so `tail -f` shows start and completion lines rather than a live percentage. The `rclone size` watch is the best live view of a scheduled run's transfer.
- For a live progress bar, run a backup by hand in a terminal. Avoid doing this while the scheduled run is active, or restic will complain that the repository is locked:

```bash
sudo bash -c 'source /etc/restic/backup.conf \
  && export RESTIC_REPOSITORY RESTIC_PASSWORD_FILE \
  && restic backup $BACKUP_PATHS --exclude-file="$EXCLUDE_FILE" --verbose'
```

A hand-run backup creates a real snapshot, but it does not update the last-success timestamp, prune old snapshots, or send failure alerts; the scheduled script handles those. The first backup uploads everything and can take hours; later runs only upload changes and are usually quick.

## Troubleshooting

The installer runs these checks itself and prints the same guidance when they fail.

**A dependency will not install.** On RHEL, Alma, or Rocky, `restic` lives in the EPEL repository: `dnf install epel-release` first, then re-run the installer. If your distro's `rclone` is too old for Google Drive, current builds are at https://rclone.org/downloads/. A static `restic` binary from https://github.com/restic/restic/releases dropped into `/usr/local/bin` also works on any distro.

**rclone remote not found.** rclone configs are per user, and the backup runs as root. If you configured the remote as your normal user, root cannot see it. The installer detects this and offers the fixes interactively (copying your user's config to root, or running `rclone config`). By hand: `sudo rclone config` to create it for root, or copy your config: `sudo mkdir -p /root/.config/rclone && sudo cp ~/.config/rclone/rclone.conf /root/.config/rclone/`

**rclone cannot reach Google Drive.** Usually an expired Google authorization. The installer offers to refresh it during the check; by hand, run `sudo rclone config reconnect gdrive:` and confirm basic connectivity with `curl -sI https://www.googleapis.com | head -1`

**Verifying the Google Drive connection / "I cannot see anything".** Prove each layer in order, always with sudo (the rclone config and key belong to root), and always using the exact repository path from your config rather than retyping it (a near-miss path silently lists an empty folder):

```bash
# 1. The authoritative repository path
sudo grep RESTIC_REPOSITORY /etc/restic/backup.conf

# 2. Token and API access: prints your Drive quota only if auth works
sudo rclone about gdrive:

# 3. What is actually in the repository folder
#    (for RESTIC_REPOSITORY="rclone:gdrive:backups/myhost" use gdrive:backups/myhost)
sudo rclone lsf gdrive:backups/<hostname>

# 4. restic can open and decrypt the repository end to end
sudo restic -r rclone:gdrive:backups/<hostname> --password-file /etc/restic/passphrase cat config
```

Right after install, step 3 shows only `config` and `keys/`, `restic snapshots` prints an empty list, and `rclone size` reports a few hundred bytes. That is the expected state: the timer fires once a day (around midnight plus up to 30 minutes of jitter), so no data transfers until the first backup runs. Start one by hand with `sudo /usr/local/bin/restic-backup.sh` and watch it move with the `rclone size` command from the Monitoring section. In the Google Drive web interface the backups live in My Drive under `backups/<hostname>` as encrypted restic files; if rclone lists them but the web interface shows nothing, check `sudo rclone config show gdrive` for a service account or shared drive setting, which stores files outside your personal My Drive.

**restic cannot open the repository.** If the error mentions "already initialized" or "wrong password", the repository exists but your current key does not unlock it; restore the original key file. Otherwise check the repository path for typos and re-check the rclone steps above.

**smtp2go rejects the test email.** Check the API key (smtp2go dashboard: Settings, then API Keys), make sure the from-address is a verified sender or on a verified domain, and confirm the machine can reach `https://api.smtp2go.com`. Backups still run without alerts, but you will not hear about failures.

## Testing

To verify a change or a fresh install:

1. Syntax-check the scripts: `bash -n install.sh restic-backup.sh restic-check-stale.sh`
2. Lint them if you have [shellcheck](https://www.shellcheck.net/): `shellcheck *.sh`
3. Run a manual backup and watch the output: `sudo /usr/local/bin/restic-backup.sh`
4. Confirm a snapshot exists: `sudo restic -r <your-repository> snapshots` (or source the config first)
5. Test alert delivery end to end: temporarily set `STALE_MAX_DAYS="0"` in `/etc/restic/backup.conf`, run `sudo /usr/local/bin/restic-check-stale.sh`, confirm the email arrives, then set the value back
6. Verify your saved copy of the encryption key: `sudo bash ./install.sh --test-key`

## Restoring

The installer includes a guided restore for the common disaster case where the fresh system already boots and you just want your files back:

```bash
sudo bash ./install.sh --restore
```

It is also offered automatically at the end of an install when the repository already contains backups. You pick a snapshot, everything or specific paths, and a destination: straight into place, or a staging folder for review. In-place restores never overwrite boot files, `/etc/fstab`, network settings, the machine identity, the backup configuration, or the bootloader dumps, so a restore cannot break the system it runs on. The staging option restores without restrictions, which is also the way to retrieve reference copies of those protected files.

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

Keep a copy of the encryption key even after uninstalling if the snapshots on Google Drive still exist. You will need it to read them.

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md) for how to report bugs, propose features, and submit changes. This project follows the [Code of Conduct](CODE_OF_CONDUCT.md), and security issues should be reported privately per [SECURITY.md](SECURITY.md).

## License

This project is licensed under the [Business Source License 1.1](LICENSE).

In short: you may use it freely, including in production for backing up systems you own or operate. You may not offer it to third parties as a commercial backup, hosting, or managed service. On 2030-07-08 the license automatically converts to the GNU General Public License, version 3.0.

This summary is not legal advice; the [LICENSE](LICENSE) file is authoritative.
