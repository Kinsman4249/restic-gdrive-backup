#!/usr/bin/env bash
# restic-backup.sh - run a backup, prune old snapshots, and email an alert
# through the smtp2go HTTP API if anything fails.
#
# All settings come from /etc/restic/backup.conf, which is written by
# install.sh. Run install.sh first if that file does not exist yet.

# Shell safety options:
#   -u           treat the use of an unset variable as an error
#   -o pipefail  make a pipeline fail if any command in it fails,
#                not just the last one
set -uo pipefail

# The configuration file that install.sh generates.
CONFIG_FILE="/etc/restic/backup.conf"

# Refuse to run without configuration, because every setting below
# (repository, passphrase, email addresses, and so on) comes from it.
if [[ ! -f "$CONFIG_FILE" ]]; then
    echo "Missing $CONFIG_FILE - run install.sh first." >&2
    exit 1
fi
# "source" reads the config file and executes it in this shell, which
# loads all of its VARIABLE="value" lines as shell variables.
# shellcheck disable=SC1090
source "$CONFIG_FILE"

# restic reads these two variables from the environment to know which
# repository to talk to and where the encryption passphrase lives.
# "export" makes them visible to the restic child processes we launch.
export RESTIC_REPOSITORY RESTIC_PASSWORD_FILE

# Make sure the directory that holds the state file exists.
# $(dirname ...) strips the filename and leaves just the directory part.
mkdir -p "$(dirname "$STATE_FILE")"

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

notify() {
    # Send an alert email through the smtp2go HTTP API.
    # Usage: notify "subject line" "message body"
    local subject="$1" body="$2"
    local api_key payload http_code

    # Read the API key from its root-only file. Keeping the key in a file
    # (instead of the config) means a casual look at backup.conf never
    # reveals it, and the file's 600 permissions keep other users out.
    if ! api_key="$(cat "$SMTP2GO_API_KEY_FILE" 2>/dev/null)"; then
        echo "WARNING: cannot read smtp2go API key from $SMTP2GO_API_KEY_FILE - alert not sent." >&2
        return 1
    fi

    # Build the JSON request body the smtp2go "email/send" endpoint expects:
    #   api_key   - authenticates the request
    #   sender    - the source (from) address
    #   to        - a list of destination addresses (we send to one)
    #   subject   - the subject line
    #   text_body - the plain-text message body
    payload=$(printf '{"api_key":"%s","sender":"%s","to":["%s"],"subject":"%s","text_body":"%s"}' \
        "$(json_escape "$api_key")" \
        "$(json_escape "$ALERT_FROM")" \
        "$(json_escape "$ALERT_TO")" \
        "$(json_escape "$subject")" \
        "$(json_escape "$body")")

    # POST the payload to the smtp2go API using curl:
    #   --silent --show-error  no progress bar, but still print real errors
    #   --max-time 30          give up after 30 seconds so we never hang
    #   --header               declare that we are sending JSON
    #   --data @-              read the request body from standard input;
    #                          piping it in keeps the API key out of the
    #                          process list, where command arguments are
    #                          visible to every user on the system
    #   --output /dev/null     discard the response body
    #   --write-out            print just the numeric HTTP status code,
    #                          which we capture in http_code
    http_code=$(printf '%s' "$payload" | curl --silent --show-error \
        --max-time 30 \
        --request POST "$SMTP2GO_API_URL" \
        --header "Content-Type: application/json" \
        --data @- \
        --output /dev/null \
        --write-out '%{http_code}')

    # smtp2go answers 200 when it accepts the email. Anything else means
    # the alert probably did not go out, so leave a note in the log.
    if [[ "$http_code" != "200" ]]; then
        echo "WARNING: smtp2go API returned HTTP ${http_code:-000} - alert email may not have been sent." >&2
        return 1
    fi
}

log() {
    # Write a timestamped line to both the terminal and the log file.
    # date -Is prints an ISO timestamp like 2026-07-08T16:20:00+00:00.
    # tee -a appends to the log file while also echoing to the screen.
    echo "$(date -Is) $*" | tee -a "$LOG_FILE"
}

# --- Backup ---
log "Starting backup of: $BACKUP_PATHS"
# BACKUP_PATHS is intentionally unquoted so that a space-separated list
# like "/home /etc" expands into multiple arguments for restic.
# The command's combined output (stdout and stderr, merged by 2>&1) is
# captured into BACKUP_OUT so we can log it and email it on failure.
# shellcheck disable=SC2086
if ! BACKUP_OUT=$(restic backup $BACKUP_PATHS --exclude-file="$EXCLUDE_FILE" 2>&1); then
    log "BACKUP FAILED"
    echo "$BACKUP_OUT" >> "$LOG_FILE"
    notify "[FAIL] restic backup on $(hostname)" "$BACKUP_OUT"
    exit 1
fi
log "Backup OK"
echo "$BACKUP_OUT" >> "$LOG_FILE"

# --- Prune (repack and drop chunks no snapshot references anymore) ---
# "restic forget" removes old snapshots according to the retention policy,
# and --prune then deletes the underlying data that is no longer needed.
log "Starting prune"
if ! PRUNE_OUT=$(restic forget --keep-daily "$KEEP_DAILY" --keep-weekly "$KEEP_WEEKLY" \
        --keep-monthly "$KEEP_MONTHLY" --prune 2>&1); then
    log "PRUNE FAILED"
    echo "$PRUNE_OUT" >> "$LOG_FILE"
    notify "[FAIL] restic prune on $(hostname)" "$PRUNE_OUT"
    exit 1
fi
log "Prune OK"

# --- Record success timestamp for the staleness check ---
# restic-check-stale.sh compares this timestamp against the current time
# and raises an alert if backups stop succeeding for too long.
date -Is > "$STATE_FILE"
log "Backup cycle complete"
