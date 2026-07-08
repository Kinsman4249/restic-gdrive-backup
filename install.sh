#!/usr/bin/env bash
# install.sh - interactive setup for restic backups with smtp2go email alerts
#
# ENCRYPTION: restic encrypts every backup ON THIS MACHINE, using the
# encryption key you enter below, before anything is uploaded. Google Drive
# only ever stores encrypted data it cannot read. The flip side: if you lose
# the key, the backups are permanently unreadable, by you, by Google, by
# anyone. This installer reminds you to back the key up and lets you test
# your saved copy.
#
# What this script does, in order:
#   1. Loads any existing configuration so your previous answers become
#      the defaults for each question.
#   2. Asks what to back up, where the restic repository lives, and which
#      source and destination email addresses to use for alerts.
#   3. Stores the encryption key and the smtp2go API key in root-only files
#      (hidden input, never echoed to the screen).
#   4. Writes the combined configuration to /etc/restic/backup.conf.
#   5. Checks the Google Drive connection (rclone), with troubleshooting
#      steps if it fails.
#   6. Installs the backup and staleness-check scripts to /usr/local/bin.
#   7. Initializes or verifies the encrypted restic repository.
#   8. Installs and starts systemd timers so everything runs automatically.
#   9. Offers to send a test alert email through the smtp2go API.
#  10. Reminds you to back up your encryption key and offers to test a copy.
#
# Extra modes:
#   sudo bash ./install.sh --test-key    only run the encryption key test
#
# Safe to re-run at any time to reconfigure: existing values in CONFIG_FILE
# win over the built-in defaults, and custom lines you added to the config
# by hand are preserved. Upgrading from the old SMTP version keeps all your
# settings, retires the unused SMTP entries, and requires an smtp2go API key.

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

# The settings this installer manages: it asks about them and writes them
# back out to the config file at the end of every run.
MANAGED_VARS="BACKUP_PATHS RESTIC_REPOSITORY RESTIC_PASSWORD_FILE EXCLUDE_FILE STATE_FILE LOG_FILE KEEP_DAILY KEEP_WEEKLY KEEP_MONTHLY STALE_MAX_DAYS ALERT_FROM ALERT_TO SMTP2GO_API_KEY_FILE SMTP2GO_API_URL"
# Settings the old SMTP version of this project used. They are retired:
# recognized during upgrades, then dropped when the config is rewritten.
LEGACY_VARS="SMTP2GO_HOST SMTP2GO_PORT SMTP2GO_USER SMTP2GO_PASS_FILE"

# ${1:-} means "the first command-line argument, or empty if there is none"
# (the :- fallback keeps set -u from treating a missing argument as an error).
MODE="install"
if [[ "${1:-}" == "--test-key" ]]; then
    MODE="test-key"
fi

# $EUID is the numeric id of the user running this script; 0 means root.
# Root is required to write to /etc, /usr/local/bin, and systemd, and to
# read the root-only key files.
if [[ $EUID -ne 0 ]]; then
    echo "Run as root (needed for /etc, /usr/local/bin, systemd)." >&2
    exit 1
fi

# Make sure the tools this project depends on are installed:
#   restic - the backup program itself (also does the encryption)
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

# =============================================================================
# Helper functions (defined up front so every mode below can use them)
# =============================================================================

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

prompt_secret() {
    # Ask for a secret and store it in a root-only file.
    # Usage: prompt_secret "description of the secret" /path/to/file
    # read -s hides what you type, keeping secrets off the screen and out
    # of your terminal's scrollback. The loop rejects empty input, because
    # an empty key or API key would only fail confusingly later.
    local label="$1" file="$2" value=""
    while [[ -z "$value" ]]; do
        read -rsp "Enter $label: " value
        echo
        if [[ -z "$value" ]]; then
            echo "It cannot be empty. Try again."
        fi
    done
    printf '%s' "$value" > "$file"
    # chmod 600 means only the owner (root) can read or write the file.
    chmod 600 "$file"
}

json_escape() {
    # Turn an arbitrary string into a safe JSON string value.
    # JSON requires certain characters inside quoted strings to be escaped,
    # otherwise the request body would be malformed and rejected.
    # The ${variable//pattern/replacement} syntax replaces every occurrence.
    local s="$1"
    s="${s//\\/\\\\}"    # backslash becomes \\  (must be done first)
    s="${s//\"/\\\"}"    # double quote becomes \"
    s="${s//$'\n'/\\n}"  # newline becomes \n
    s="${s//$'\r'/\\r}"  # carriage return becomes \r
    s="${s//$'\t'/\\t}"  # tab becomes \t
    printf '%s' "$s"
}

inspect_previous_config() {
    # Look at the just-loaded previous config and work out, into globals:
    #   LEGACY_SMTP_FOUND - "yes" if it still has old SMTP alert settings
    #   PRESERVED_LINES   - custom lines to carry into the rewritten config
    #   PRESERVED_COUNT   - how many such lines were found
    # Re-running the installer must never lose what you set up before:
    # managed settings come back as default answers, custom lines are
    # carried over verbatim, and only the retired SMTP settings are dropped.
    LEGACY_SMTP_FOUND="no"
    PRESERVED_LINES=""
    PRESERVED_COUNT=0

    # Concatenating the four values gives an empty string only when ALL of
    # them are unset or empty, so this reads "if any legacy value is set".
    # ${VAR:-} means "the value, or empty if unset" (keeps set -u happy).
    if [[ -n "${SMTP2GO_HOST:-}${SMTP2GO_PORT:-}${SMTP2GO_USER:-}${SMTP2GO_PASS_FILE:-}" ]]; then
        LEGACY_SMTP_FOUND="yes"
    fi

    # Nothing to preserve if there is no config file yet.
    [[ -f "$CONFIG_FILE" ]] || return 0

    local line name
    while IFS= read -r line; do
        # Only consider lines that assign a variable, like NAME="value"
        # (an optional "export " prefix is tolerated). Comments and blank
        # lines are regenerated by the installer, so they are skipped.
        if [[ "$line" =~ ^(export[[:space:]]+)?([A-Za-z_][A-Za-z0-9_]*)= ]]; then
            name="${BASH_REMATCH[2]}"
            # Keep the line only when the installer neither manages nor
            # retires that name. The surrounding spaces make the substring
            # match whole words instead of partial names.
            if [[ " $MANAGED_VARS $LEGACY_VARS " != *" $name "* ]]; then
                PRESERVED_LINES+="$line"$'\n'
                PRESERVED_COUNT=$((PRESERVED_COUNT + 1))
            fi
        fi
    done < "$CONFIG_FILE"
}

test_encryption_key() {
    # Interactive check that a saved copy of the encryption key is correct,
    # so you can be sure you copy/pasted it right BEFORE you ever need it.
    # Two levels of proof:
    #   1. Compare the pasted text with the key file on this machine.
    #   2. Try to actually unlock the backup repository using ONLY the
    #      pasted text (the strongest possible test).
    echo
    echo "--- Encryption key test ---"
    echo "Paste the copy of the key you saved. Input is hidden; press Enter when done."
    local candidate stored trimmed key_to_try tmp
    read -rsp "> " candidate
    echo

    stored="$(cat "$RESTIC_PASSWORD_FILE")"

    # Level 1: exact text comparison against the key file.
    if [[ "$candidate" == "$stored" ]]; then
        echo "MATCH: your copy is identical to the key stored on this machine."
        key_to_try="$candidate"
    else
        # People often pick up an extra space or line break when copying.
        # Strip leading and trailing whitespace and compare once more.
        trimmed="$(printf '%s' "$candidate" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"
        if [[ "$trimmed" == "$stored" ]]; then
            echo "MATCH, but your copy has extra spaces or line breaks around it."
            echo "Consider re-saving a clean copy without them."
            key_to_try="$trimmed"
        else
            echo "NO MATCH: your copy is NOT the key stored on this machine."
            echo "Re-copy it with:  sudo cat $RESTIC_PASSWORD_FILE; echo"
            echo "(the '; echo' just adds a line break so your prompt does not stick to the key)"
            return 1
        fi
    fi

    # Level 2: prove the pasted key unlocks the real repository.
    # First confirm the repository is reachable using the known-good key
    # file, so a network problem is not mistaken for a bad key.
    if ! restic cat config >/dev/null 2>&1; then
        echo "NOTE: the repository is not reachable right now, so the unlock test was skipped."
        echo "The text comparison above already confirms your copy matches the key file."
        return 0
    fi
    # Write the pasted key to a private temporary file (mktemp creates it
    # readable by root only) and point restic at that file instead of the
    # real one, for this single command.
    tmp="$(mktemp)"
    printf '%s' "$key_to_try" > "$tmp"
    if RESTIC_PASSWORD_FILE="$tmp" restic cat config >/dev/null 2>&1; then
        echo "VERIFIED: the pasted key unlocks the backup repository."
        rm -f "$tmp"
        return 0
    else
        echo "PROBLEM: the pasted key matches the key file but did NOT unlock the repository."
        echo "This can happen if the key file was changed after the repository was created."
        rm -f "$tmp"
        return 1
    fi
}

# =============================================================================
# Key-test-only mode: sudo bash ./install.sh --test-key
# =============================================================================
if [[ "$MODE" == "test-key" ]]; then
    if [[ ! -f "$CONFIG_FILE" ]]; then
        echo "Missing $CONFIG_FILE - run the installer first." >&2
        exit 1
    fi
    # Load the saved settings, then run only the key test and exit.
    # shellcheck disable=SC1090
    source "$CONFIG_FILE"
    export RESTIC_REPOSITORY RESTIC_PASSWORD_FILE
    test_encryption_key
    exit $?
fi

# =============================================================================
# Normal install / reconfigure flow starts here
# =============================================================================

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

# Detect old SMTP settings and collect custom lines before anything
# rewrites the config file.
inspect_previous_config

if [[ "$LEGACY_SMTP_FOUND" == "yes" ]]; then
    cat <<'NOTICE'

---------------------------------------------------------------------
NOTICE: your existing config is from the old SMTP version.
Alerts are now sent through the smtp2go HTTP API instead of an SMTP
login, so an smtp2go API key is REQUIRED to finish this setup
(create one in the smtp2go dashboard: Settings -> API Keys).
  - Every other setting you chose before is kept and offered as the
    default answer below.
  - The old SMTP host/port/username/password entries are retired and
    will be dropped when the config is rewritten.
---------------------------------------------------------------------
NOTICE
fi

# --- Best-guess fallbacks (only used if not already set by sourced config) ---
# The ': "${VAR:=value}"' pattern means: if VAR is unset or empty, assign it
# the value; otherwise leave it alone. Values loaded from the config file
# above therefore win over these defaults.
: "${RESTIC_REPOSITORY:=rclone:gdrive:backups/$(hostname)}"
# The encryption key for all backups lives in this root-only file.
# restic calls it a "password file"; it is the key that encrypts your data.
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

echo
echo "=== Backup source & repository ==="
ask BACKUP_PATHS "Path(s) to back up (space-separated)"
ask RESTIC_REPOSITORY "restic repository (rclone remote:path)"
ask RESTIC_PASSWORD_FILE "Path to the encryption key file"
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

# The encryption key protects every backup. restic derives the actual
# encryption from this value, so "key" and "passphrase" mean the same
# thing here. Pick something long and random, then BACK IT UP somewhere
# off this machine (you will be reminded again at the end).
echo
if [[ ! -s "$RESTIC_PASSWORD_FILE" ]]; then
    echo "Choose the encryption key for your backups (it will be created at $RESTIC_PASSWORD_FILE)."
    prompt_secret "encryption key" "$RESTIC_PASSWORD_FILE"
else
    read -rp "Encryption key file already exists at $RESTIC_PASSWORD_FILE - replace it? [y/N]: " yn
    if [[ "$yn" =~ ^[Yy]$ ]]; then
        echo "WARNING: existing backups can only be read with the key that created them."
        echo "Only replace the key if you are starting a NEW repository."
        prompt_secret "new encryption key" "$RESTIC_PASSWORD_FILE"
    fi
fi

# The smtp2go API key authorizes sending email from your account.
# Create one in the smtp2go dashboard: Settings -> API Keys.
if [[ ! -s "$SMTP2GO_API_KEY_FILE" ]]; then
    if [[ "$LEGACY_SMTP_FOUND" == "yes" ]]; then
        # Upgraders from the SMTP version have credentials that no longer
        # work here; the prompt below will not accept an empty answer.
        echo "Your old SMTP username/password are no longer used - an smtp2go API key is required."
    fi
    prompt_secret "smtp2go API key (will be created at $SMTP2GO_API_KEY_FILE)" "$SMTP2GO_API_KEY_FILE"
else
    read -rp "smtp2go API key file already exists at $SMTP2GO_API_KEY_FILE - replace it? [y/N]: " yn
    if [[ "$yn" =~ ^[Yy]$ ]]; then
        prompt_secret "new smtp2go API key" "$SMTP2GO_API_KEY_FILE"
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

# Carry over any custom lines from the previous config, so a re-run of
# this installer never loses settings you added by hand.
if [[ -n "$PRESERVED_LINES" ]]; then
    {
        echo ""
        echo "# --- Preserved from your previous config (not managed by install.sh) ---"
        printf '%s' "$PRESERVED_LINES"
    } >> "$CONFIG_FILE"
fi
chmod 600 "$CONFIG_FILE"
echo
echo "Config written to $CONFIG_FILE"
if [[ "$PRESERVED_COUNT" -gt 0 ]]; then
    echo "Preserved $PRESERVED_COUNT custom line(s) from your previous config."
fi

# The old SMTP version stored an SMTP password on disk. Nothing uses it
# anymore, so offer to remove it rather than leave a stale secret behind.
if [[ "$LEGACY_SMTP_FOUND" == "yes" && -n "${SMTP2GO_PASS_FILE:-}" && -f "${SMTP2GO_PASS_FILE:-}" ]]; then
    read -rp "Old SMTP password file found at $SMTP2GO_PASS_FILE - delete it? [Y/n]: " yn
    if [[ ! "$yn" =~ ^[Nn]$ ]]; then
        # shred overwrites the contents before removing the file, where
        # available; plain rm is the fallback.
        shred -u "$SMTP2GO_PASS_FILE" 2>/dev/null || rm -f "$SMTP2GO_PASS_FILE"
        echo "Deleted $SMTP2GO_PASS_FILE"
    fi
fi

# =============================================================================
# Connectivity checks
# Each check verifies one link in the chain and prints plain troubleshooting
# steps if it fails, so problems surface NOW instead of at 3am.
# =============================================================================
echo
echo "=== Connectivity checks ==="

# --- Check 1: the rclone remote behind the repository ---
# Repository strings like rclone:gdrive:backups/host reach Google Drive
# through an rclone "remote" (here: gdrive). Verify the remote exists and
# can actually reach Google Drive before anything depends on it.
if [[ "$RESTIC_REPOSITORY" == rclone:* ]]; then
    RCLONE_REMOTE="${RESTIC_REPOSITORY#rclone:}"  # drop the leading "rclone:"
    RCLONE_REMOTE="${RCLONE_REMOTE%%:*}"          # keep only the remote name

    printf 'Checking rclone remote "%s" is configured... ' "$RCLONE_REMOTE"
    # rclone listremotes prints one remote per line, each ending in ":".
    # grep -qx matches a whole line quietly (exit code only, no output).
    if rclone listremotes 2>/dev/null | grep -qx "${RCLONE_REMOTE}:"; then
        echo "OK"
    else
        echo "FAIL"
        cat <<TROUBLE

No rclone remote named "$RCLONE_REMOTE" is configured for the root user.
Troubleshooting:
  1. List the remotes root can see:  sudo rclone listremotes
  2. rclone configs are PER USER. If you configured the remote as your
     normal user, root cannot see it. Either create it for root with
     "sudo rclone config", or copy your user config to root:
       sudo mkdir -p /root/.config/rclone
       sudo cp ~/.config/rclone/rclone.conf /root/.config/rclone/
  3. To create the remote from scratch:  sudo rclone config
     (choose "drive" for Google Drive and follow the prompts)
Fix the remote, then re-run this installer.
TROUBLE
        exit 1
    fi

    printf 'Checking "%s" can reach Google Drive... ' "$RCLONE_REMOTE"
    # rclone lsd lists top-level folders. We only care whether it works,
    # so stdout is discarded and stderr is captured for the error message.
    # The redirect order matters: 2>&1 first sends errors to the capture,
    # then 1>/dev/null discards the normal listing.
    if RCLONE_OUT=$(rclone lsd "${RCLONE_REMOTE}:" 2>&1 1>/dev/null); then
        echo "OK"
    else
        echo "FAIL"
        echo "rclone said:"
        echo "$RCLONE_OUT" | head -5 | sed 's/^/    /'
        cat <<TROUBLE

Troubleshooting:
  1. Expired or revoked Google authorization is the most common cause.
     Refresh it with:  sudo rclone config reconnect ${RCLONE_REMOTE}:
  2. Try the listing yourself to see the full error:
       sudo rclone lsd ${RCLONE_REMOTE}:
  3. Confirm this machine can reach Google at all:
       curl -sI https://www.googleapis.com | head -1
     (expect an HTTP status line; no output means a network/DNS problem)
  4. Review the remote's settings (team drive, service account, scopes):
       sudo rclone config show ${RCLONE_REMOTE}
Fix the connection, then re-run this installer.
TROUBLE
        exit 1
    fi
else
    echo "Repository does not start with rclone: - skipping Google Drive checks."
fi

# --- Install scripts ---
# BASH_SOURCE[0] is the path of this script; the cd/pwd combination turns
# it into an absolute directory so the copies work no matter where you
# ran install.sh from. "install -m 755" copies the file and makes it
# executable in one step.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
install -m 755 "$SCRIPT_DIR/restic-backup.sh" "$BIN_DIR/restic-backup.sh"
install -m 755 "$SCRIPT_DIR/restic-check-stale.sh" "$BIN_DIR/restic-check-stale.sh"
echo "Scripts installed to $BIN_DIR"

# --- Check 2: the encrypted restic repository ---
# restic reads these two variables from the environment to know which
# repository to talk to and where the encryption key lives.
export RESTIC_REPOSITORY RESTIC_PASSWORD_FILE
printf 'Checking restic repository access... '
# "restic cat config" is a cheap command that only succeeds when the
# repository exists AND the encryption key unlocks it.
if restic cat config >/dev/null 2>&1; then
    echo "OK (repository exists and your encryption key unlocks it)"
else
    echo "not yet - trying to initialize a new repository"
    if INIT_OUT=$(restic init 2>&1); then
        echo "Repository created at $RESTIC_REPOSITORY, encrypted with your key."
    else
        echo "FAIL - restic could not open or create the repository."
        echo "restic said:"
        echo "$INIT_OUT" | head -8 | sed 's/^/    /'
        cat <<TROUBLE

Troubleshooting:
  1. "already initialized" or "wrong password": the repository exists but
     your current key does not unlock it. If you replaced the key file
     during this run, restore the original key to $RESTIC_PASSWORD_FILE.
  2. Path errors: double-check the repository value for typos:
       $RESTIC_REPOSITORY
  3. Network or rclone errors: re-check the Google Drive steps above.
Fix the problem, then re-run this installer.
TROUBLE
        exit 1
    fi
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
echo "Timers active:"
systemctl list-timers restic-backup.timer restic-check-stale.timer --no-pager

# --- Check 3: smtp2go alert delivery (optional but recommended) ---
# Sends a real email through the exact same API call the alert scripts
# use, which proves the API key, the verified sender, and the network
# path all work end to end.
echo
read -rp "Send a test alert email to $ALERT_TO now to verify smtp2go? [Y/n]: " yn
if [[ ! "$yn" =~ ^[Nn]$ ]]; then
    api_key="$(cat "$SMTP2GO_API_KEY_FILE")"
    payload=$(printf '{"api_key":"%s","sender":"%s","to":["%s"],"subject":"%s","text_body":"%s"}' \
        "$(json_escape "$api_key")" \
        "$(json_escape "$ALERT_FROM")" \
        "$(json_escape "$ALERT_TO")" \
        "$(json_escape "[TEST] restic backup alerts on $(hostname)")" \
        "$(json_escape "This is a test email from install.sh. If you are reading it, alert delivery works.")")
    # The body is piped to curl on standard input (--data @-) so the API
    # key never appears in the process list. --write-out appends the HTTP
    # status code on its own line after the response body; the two are
    # split apart below.
    response=$(printf '%s' "$payload" | curl --silent --show-error \
        --max-time 30 \
        --request POST "$SMTP2GO_API_URL" \
        --header "Content-Type: application/json" \
        --data @- \
        --write-out $'\n%{http_code}')
    http_code="${response##*$'\n'}"   # the text after the last line break
    body="${response%$'\n'*}"         # everything before it
    if [[ "$http_code" == "200" ]]; then
        echo "OK - smtp2go accepted the test email. Check the inbox (and spam folder) of $ALERT_TO."
    else
        echo "FAIL - smtp2go returned HTTP ${http_code:-000}."
        echo "smtp2go said:"
        echo "$body" | head -5 | sed 's/^/    /'
        cat <<TROUBLE

Troubleshooting:
  1. Invalid or revoked API key: log in to smtp2go, open Settings -> API
     Keys, and compare with what is stored here:
       sudo cat $SMTP2GO_API_KEY_FILE; echo
  2. Unverified sender: smtp2go only sends from addresses or domains you
     have verified (look for Verified Senders / Sender Domains in the
     smtp2go dashboard). "$ALERT_FROM" must be covered by one of them.
  3. API key restrictions: if the key limits allowed senders or IP
     addresses, loosen the restriction or create a new key.
  4. Confirm this machine can reach the API at all:
       curl -sI https://api.smtp2go.com | head -1
Backups still run without alerts, but you will not hear about failures.
Re-run this installer to test again after fixing the problem.
TROUBLE
    fi
fi

# =============================================================================
# Final reminder: BACK UP YOUR ENCRYPTION KEY
# =============================================================================
cat <<REMINDER

=======================================================================
 IMPORTANT: BACK UP YOUR ENCRYPTION KEY NOW
=======================================================================
 Your backups are encrypted on this machine before upload. Google
 Drive only ever stores scrambled data it cannot read.

 That protection cuts both ways: WITHOUT THE KEY, THE BACKUPS ARE
 PERMANENTLY UNREADABLE. There is no reset, and nobody can recover
 them for you. If this machine dies and the key only lived here, the
 backups die with it.

 View the key in the console with:

     sudo cat $RESTIC_PASSWORD_FILE; echo

 (the '; echo' just adds a line break after the key)

 Store a copy somewhere OFF this machine: a password manager, or a
 printed copy in a safe place.
=======================================================================

REMINDER

# Offer to verify a saved copy right away, while it is fresh. The same
# test can be run again later with:  sudo bash ./install.sh --test-key
read -rp "Have you saved a copy and want to test it now? [y/N]: " yn
if [[ "$yn" =~ ^[Yy]$ ]]; then
    test_encryption_key
fi
echo
echo "You can re-run the key test anytime with: sudo bash ./install.sh --test-key"
echo
echo "Done. Run a manual backup test with: $BIN_DIR/restic-backup.sh"
