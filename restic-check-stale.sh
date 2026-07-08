#!/usr/bin/env bash
# restic-check-stale.sh - watchdog that emails an alert through the smtp2go
# HTTP API if no successful backup has completed in more than STALE_MAX_DAYS
# days.
#
# restic-backup.sh writes a timestamp to STATE_FILE after every successful
# run. This script only reads that timestamp; it never touches the backup
# repository itself, so it is cheap to run often.

# Shell safety options:
#   -u           treat the use of an unset variable as an error
#   -o pipefail  make a pipeline fail if any command in it fails
set -uo pipefail

# The configuration file that install.sh generates.
CONFIG_FILE="/etc/restic/backup.conf"

# Refuse to run without configuration.
if [[ ! -f "$CONFIG_FILE" ]]; then
    echo "Missing $CONFIG_FILE - run install.sh first." >&2
    exit 1
fi
# Load every VARIABLE="value" line from the config into this shell.
# shellcheck disable=SC1090
source "$CONFIG_FILE"

# Convert the day limit into seconds, because timestamps are compared
# in seconds. 86400 is the number of seconds in one day.
MAX_AGE_SECONDS=$(( STALE_MAX_DAYS * 86400 ))

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

    # Read the API key from its root-only file (created by install.sh
    # with 600 permissions so only root can read it).
    if ! api_key="$(cat "$SMTP2GO_API_KEY_FILE" 2>/dev/null)"; then
        echo "WARNING: cannot read smtp2go API key from $SMTP2GO_API_KEY_FILE - alert not sent." >&2
        return 1
    fi

    # Build the JSON request body the smtp2go "email/send" endpoint expects.
    payload=$(printf '{"api_key":"%s","sender":"%s","to":["%s"],"subject":"%s","text_body":"%s"}' \
        "$(json_escape "$api_key")" \
        "$(json_escape "$ALERT_FROM")" \
        "$(json_escape "$ALERT_TO")" \
        "$(json_escape "$subject")" \
        "$(json_escape "$body")")

    # POST the payload with curl. The body is piped in on standard input
    # (--data @-) so the API key never appears in the process list.
    # --write-out '%{http_code}' captures just the HTTP status code.
    http_code=$(printf '%s' "$payload" | curl --silent --show-error \
        --max-time 30 \
        --request POST "$SMTP2GO_API_URL" \
        --header "Content-Type: application/json" \
        --data @- \
        --output /dev/null \
        --write-out '%{http_code}')

    # smtp2go answers 200 when it accepts the email.
    if [[ "$http_code" != "200" ]]; then
        echo "WARNING: smtp2go API returned HTTP ${http_code:-000} - alert email may not have been sent." >&2
        return 1
    fi
}

# If the state file does not exist at all, no backup has ever succeeded
# (or someone deleted the file). Either way, raise the alarm.
if [[ ! -f "$STATE_FILE" ]]; then
    notify "[ALERT] No restic backup has ever completed on $(hostname)" \
        "State file $STATE_FILE does not exist. Backup job may never have run successfully."
    exit 1
fi

# Work out how old the last successful backup is:
#   LAST  - the saved timestamp, converted to seconds since 1970
#   NOW   - the current time, in the same format
#   AGE   - the difference, in seconds
LAST=$(date -d "$(cat "$STATE_FILE")" +%s)
NOW=$(date +%s)
AGE=$((NOW - LAST))

# Alert if the last success is older than the configured limit.
# The math in the message converts seconds to hours for readability.
if (( AGE > MAX_AGE_SECONDS )); then
    notify "[ALERT] restic backup stale on $(hostname)" \
        "Last successful backup was $(( AGE / 3600 )) hours ago (limit: $((STALE_MAX_DAYS * 24))h). Check the backup service."
fi
