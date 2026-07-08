#!/usr/bin/env bash
# install.sh - interactive setup for restic backups with smtp2go email alerts
#
# What this script does, in order:
#   1. Loads any existing configuration so your previous answers become
#      the defaults for each question.
#   2. Asks what to back up, where the restic repository lives, and which
#      source and destination email addresses to use for alerts.
#   3. Stores the restic passphrase and the smtp2go API key in root-only
#      files (never echoed to the screen).
#   4. Writes the combined configuration to /etc/restic/backup.conf.
#   5. Installs the backup and staleness-check scripts to /usr/local/bin.
#   6. Initializes the restic repository if it has never been used.
#   7. Installs and starts systemd timers so everything runs automatically.
#
# Safe to re-run at any time to reconfigure: existing values in CONFIG_FILE
# win over the built-in defaults.

# Shell safety options:
#   -u           treat the use of an unset variable as an error
#   -o pipefail  make a pipeline fail if any command in it fails
set -uo pipefail

# Where the generated configuration file lives. The other scripts read it.
CONFIG_FILE="/etc/restic/backup.conf"
# Where the runnable scripts get installed.
BIN_DIR="/usr/local/bin"
# Where systemd unit files (service and timer definitions) live.
SYSTEMD_DIR="/etc/systemd/system"

# $EUID is the numeric id of the user running this script; 0 means root.
# Root is required to write to /etc, /usr/local/bin, and systemd.
if [[ $EUID -ne 0 ]]; then
    echo "Run as root (needed for /etc, /usr/local/bin, systemd)." >&2
    exit 1
fi

# Make sure the tools this project depends on are installed:
#   restic - the backup program itself
#   rclone - lets restic talk to Google Drive
#   curl   - used to call the smtp2go HTTP API when sending alert emails
# "command -v" prints the path of a command if it exists, or fails if not.
for cmd in restic rclone curl; do
    if ! command -v "$cmd" >/dev/null 2>&1; then
        echo "Required command '$cmd' is not installed or not in PATH." >&2
        echo "Install it and re-run this script." >&2
        exit 1
    fi
done

# Create the config directory (/etc/restic) and state directory
# (/var/lib/restic). -p creates parents and ignores existing directories.
mkdir -p /etc/restic /var/lib/restic

# --- Load existing config as defaults, if present ---
if [[ -f "$CONFIG_FILE" ]]; then
    # "source" executes the config file in this shell, loading all of its
    # VARIABLE="value" lines as shell variables.
    # shellcheck disable=SC1090
    source "$CONFIG_FILE"
    echo "Existing config found at $CONFIG_FILE - its values are offered as defaults."
else
    echo "No existing config - using best-guess defaults."
fi

# --- Best-guess fallbacks (only used if not already set by sourced config) ---
# The ': "${VAR:=value}"' pattern means: if VAR is unset or empty, assign it
# the value; otherwise leave it alone. Values loaded from the config file
# above therefore win over these defaults.
: "${RESTIC_REPOSITORY:=rclone:gdrive:backups/$(hostname)}"
: "${RESTIC_PASSWORD_FILE:=/etc/restic/passphrase}"
: "${EXCLUDE_FILE:=/etc/restic/excludes}"
: "${STATE_FILE:=/var/lib/restic/last_success}"
: "${LOG_FILE:=/var/log/restic-backup.log}"
# Source (from) and destination (to) addresses for alert emails.
# The from-address must be a sender you have verified in your smtp2go
# account, or smtp2go will refuse to send.
: "${ALERT_FROM:=backup-alerts@$(hostname -f 2>/dev/null || hostname)}"
: "${ALERT_TO:=root@$(hostname -f 2>/dev/null || hostname)}"
# smtp2go HTTP API settings. Authentication uses an API key (created in
# the smtp2go dashboard under Settings then API Keys). The key is stored
# in its own root-only file, never in this config.
: "${SMTP2GO_API_KEY_FILE:=/etc/restic/smtp2go_api_key}"
: "${SMTP2GO_API_URL:=https://api.smtp2go.com/v3/email/send}"
# Retention policy: how many daily, weekly, and monthly snapshots to keep.
: "${KEEP_DAILY:=7}"
: "${KEEP_WEEKLY:=4}"
: "${KEEP_MONTHLY:=6}"
# Staleness watchdog: alert if no successful backup in this many days.
: "${STALE_MAX_DAYS:=3}"
: "${BACKUP_PATHS:=/}"

ask() {
    # Ask an interactive question with a default value.
    # Usage: ask VAR_NAME "prompt text"
    # ${!var} is indirect expansion: it reads the value of the variable
    # whose NAME is stored in var. Pressing Enter keeps the default.
    # printf -v stores the result back into that same named variable.
    local var="$1" prompt="$2" current answer
    current="${!var}"
    read -rp "$prompt [$current]: " answer
    printf -v "$var" '%s' "${answer:-$current}"
}

echo
echo "=== Backup source & repository ==="
ask BACKUP_PATHS "Path(s) to back up (space-separated)"
ask RESTIC_REPOSITORY "restic repository (rclone remote:path)"
ask RESTIC_PASSWORD_FILE "Path to restic passphrase file"
ask EXCLUDE_FILE "Path to exclude file"

echo
echo "=== State & logging ==="
ask STATE_FILE "Last-success state file path"
ask LOG_FILE "Log file path"

echo
echo "=== Retention (prune policy) ==="
ask KEEP_DAILY "Keep daily snapshots"
ask KEEP_WEEKLY "Keep weekly snapshots"
ask KEEP_MONTHLY "Keep monthly snapshots"
ask STALE_MAX_DAYS "Alert if no successful backup in N days"

echo
echo "=== Email alerting (smtp2go HTTP API) ==="
# Only the two addresses and an API key are needed. There are no SMTP
# host, port, username, or password questions because alerts are sent
# over HTTPS to the smtp2go API instead of through an SMTP connection.
ask ALERT_FROM "Source (from) email address for alerts (must be a verified smtp2go sender)"
ask ALERT_TO "Destination (to) email address for alerts"
ask SMTP2GO_API_KEY_FILE "Path to store the smtp2go API key"

# --- Secrets: only prompt to change if empty/missing, never echo ---
# read -s hides what you type, keeping secrets off the screen and out of
# your terminal's scrollback. Files are locked down with chmod 600, which
# means only the owner (root) can read or write them.

# The restic passphrase encrypts every backup. Losing it means losing
# access to the backups, so store a copy somewhere safe.
if [[ ! -s "$RESTIC_PASSWORD_FILE" ]]; then
    read -rsp "Enter restic repository passphrase (will be created at $RESTIC_PASSWORD_FILE): " pw
    echo
    printf '%s' "$pw" > "$RESTIC_PASSWORD_FILE"
    chmod 600 "$RESTIC_PASSWORD_FILE"
else
    read -rp "restic passphrase file already exists at $RESTIC_PASSWORD_FILE - replace it? [y/N]: " yn
    if [[ "$yn" =~ ^[Yy]$ ]]; then
        read -rsp "Enter new restic passphrase: " pw
        echo
        printf '%s' "$pw" > "$RESTIC_PASSWORD_FILE"
        chmod 600 "$RESTIC_PASSWORD_FILE"
    fi
fi

# The smtp2go API key authorizes sending email from your account.
# Create one in the smtp2go dashboard: Settings -> API Keys.
if [[ ! -s "$SMTP2GO_API_KEY_FILE" ]]; then
    read -rsp "Enter smtp2go API key (will be created at $SMTP2GO_API_KEY_FILE): " key
    echo
    printf '%s' "$key" > "$SMTP2GO_API_KEY_FILE"
    chmod 600 "$SMTP2GO_API_KEY_FILE"
else
    read -rp "smtp2go API key file already exists at $SMTP2GO_API_KEY_FILE - replace it? [y/N]: " yn
    if [[ "$yn" =~ ^[Yy]$ ]]; then
        read -rsp "Enter new smtp2go API key: " key
        echo
        printf '%s' "$key" > "$SMTP2GO_API_KEY_FILE"
        chmod 600 "$SMTP2GO_API_KEY_FILE"
    fi
fi

# --- Exclude file: create a sane default if missing ---
# These paths hold virtual, temporary, or mount-point data that either
# cannot be backed up or should not be.
if [[ ! -f "$EXCLUDE_FILE" ]]; then
    cat > "$EXCLUDE_FILE" <<'EOF'
/proc
/sys
/tmp
/mnt
/dev
/run
/var/cache
/var/tmp
EOF
    echo "Created default exclude file at $EXCLUDE_FILE - review it."
fi

# --- Write config ---
# Everything the backup and staleness scripts need, in VARIABLE="value"
# form so they can load it with "source". chmod 600 keeps it root-only.
cat > "$CONFIG_FILE" <<EOF
# Generated/updated by install.sh - safe to hand-edit, re-running install.sh will offer these as defaults
BACKUP_PATHS="$BACKUP_PATHS"
RESTIC_REPOSITORY="$RESTIC_REPOSITORY"
RESTIC_PASSWORD_FILE="$RESTIC_PASSWORD_FILE"
EXCLUDE_FILE="$EXCLUDE_FILE"
STATE_FILE="$STATE_FILE"
LOG_FILE="$LOG_FILE"
KEEP_DAILY="$KEEP_DAILY"
KEEP_WEEKLY="$KEEP_WEEKLY"
KEEP_MONTHLY="$KEEP_MONTHLY"
STALE_MAX_DAYS="$STALE_MAX_DAYS"
ALERT_FROM="$ALERT_FROM"
ALERT_TO="$ALERT_TO"
SMTP2GO_API_KEY_FILE="$SMTP2GO_API_KEY_FILE"
SMTP2GO_API_URL="$SMTP2GO_API_URL"
EOF
chmod 600 "$CONFIG_FILE"
echo
echo "Config written to $CONFIG_FILE"

# --- Install scripts ---
# BASH_SOURCE[0] is the path of this script; the cd/pwd combination turns
# it into an absolute directory so the copies work no matter where you
# ran install.sh from. "install -m 755" copies the file and makes it
# executable in one step.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
install -m 755 "$SCRIPT_DIR/restic-backup.sh" "$BIN_DIR/restic-backup.sh"
install -m 755 "$SCRIPT_DIR/restic-check-stale.sh" "$BIN_DIR/restic-check-stale.sh"
echo "Scripts installed to $BIN_DIR"

# --- Init restic repo if not already initialized ---
# "restic snapshots" succeeds only against an initialized repository, so
# a failure here means the repository is brand new and needs "restic init".
export RESTIC_REPOSITORY RESTIC_PASSWORD_FILE
if ! restic snapshots >/dev/null 2>&1; then
    echo "Repository not yet initialized - running restic init..."
    restic init
fi

# --- Install systemd units ---
# A systemd "service" describes WHAT to run; a "timer" describes WHEN.
# Type=oneshot means the service runs to completion and exits rather
# than staying alive in the background.

# Backup service: Nice=19 and IOSchedulingClass=idle tell the kernel to
# give the backup the lowest CPU and disk priority, so it does not slow
# down whatever else the machine is doing.
cat > "$SYSTEMD_DIR/restic-backup.service" <<EOF
[Unit]
Description=restic backup + prune

[Service]
Type=oneshot
ExecStart=$BIN_DIR/restic-backup.sh
Nice=19
IOSchedulingClass=idle
EOF

# Backup timer: runs once a day. RandomizedDelaySec spreads the start
# time over 30 minutes so many machines do not hit the network at the
# exact same moment. Persistent=true runs a missed backup at the next
# boot if the machine was off when the timer would have fired.
cat > "$SYSTEMD_DIR/restic-backup.timer" <<EOF
[Unit]
Description=Daily restic backup

[Timer]
OnCalendar=daily
RandomizedDelaySec=1800
Persistent=true

[Install]
WantedBy=timers.target
EOF

# Staleness-check service: just runs the watchdog script.
cat > "$SYSTEMD_DIR/restic-check-stale.service" <<EOF
[Unit]
Description=Check restic backup staleness

[Service]
Type=oneshot
ExecStart=$BIN_DIR/restic-check-stale.sh
EOF

# Staleness-check timer: fires at 09:00 and 21:00 every day.
cat > "$SYSTEMD_DIR/restic-check-stale.timer" <<EOF
[Unit]
Description=Twice-daily staleness check

[Timer]
OnCalendar=*-*-* 09,21:00:00
Persistent=true

[Install]
WantedBy=timers.target
EOF

# Tell systemd to re-read its unit files, then enable and start both
# timers so they survive reboots and begin counting down immediately.
systemctl daemon-reload
systemctl enable --now restic-backup.timer restic-check-stale.timer

echo
echo "Done. Timers active:"
systemctl list-timers restic-backup.timer restic-check-stale.timer --no-pager
echo
echo "Run a manual test with: $BIN_DIR/restic-backup.sh"
