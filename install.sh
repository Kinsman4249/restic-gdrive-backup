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
#   1. Checks that restic, rclone, curl, and systemd are present, and
#      offers to install missing tools with your package manager.
#   2. Loads any existing configuration so your previous answers become
#      the defaults for each question.
#   3. Asks what to back up, where the restic repository lives, and which
#      source and destination email addresses to use for alerts.
#   4. Stores the encryption key and the smtp2go API key in root-only files
#      (hidden input, never echoed to the screen).
#   5. Writes the combined configuration to /etc/restic/backup.conf.
#   6. Checks the Google Drive connection (rclone), with troubleshooting
#      steps if it fails.
#   7. Installs the backup and staleness-check scripts to /usr/local/bin.
#   8. Initializes or verifies the encrypted restic repository.
#   9. Installs and starts systemd timers so everything runs automatically.
#  10. Offers to send a test alert email through the smtp2go API.
#  11. Reminds you to back up your encryption key and offers to test a copy.
#
# Extra modes:
#   sudo bash ./install.sh --test-key    only run the encryption key test
#   sudo bash ./install.sh --restore     guided file restore from a snapshot
#                                        (never touches boot or network files)
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
MANAGED_VARS="BACKUP_PATHS RESTIC_REPOSITORY RESTIC_PASSWORD_FILE EXCLUDE_FILE STATE_FILE LOG_FILE KEEP_DAILY KEEP_WEEKLY KEEP_MONTHLY STALE_MAX_DAYS ALERT_FROM ALERT_TO SMTP2GO_API_KEY_FILE SMTP2GO_API_URL BOOTLOADER_BACKUP_DIR"
# Settings the old SMTP version of this project used. They are retired:
# recognized during upgrades, then dropped when the config is rewritten.
LEGACY_VARS="SMTP2GO_HOST SMTP2GO_PORT SMTP2GO_USER SMTP2GO_PASS_FILE"

# ${1:-} means "the first command-line argument, or empty if there is none"
# (the :- fallback keeps set -u from treating a missing argument as an error).
MODE="install"
if [[ "${1:-}" == "--test-key" ]]; then
    MODE="test-key"
elif [[ "${1:-}" == "--restore" ]]; then
    MODE="restore"
fi

# $EUID is the numeric id of the user running this script; 0 means root.
# Root is required to write to /etc, /usr/local/bin, and systemd, and to
# read the root-only key files.
if [[ $EUID -ne 0 ]]; then
    echo "Run as root (needed for /etc, /usr/local/bin, systemd)." >&2
    exit 1
fi

# =============================================================================
# Helper functions (defined up front so every mode below can use them)
# =============================================================================

manual_install_help() {
    # Print per-tool installation pointers, used when the package manager
    # is unknown, the user declines the automatic install, or a package
    # is not available in the distro's repositories.
    # Usage: manual_install_help TOOL [TOOL...]
    local t
    echo
    echo "Manual installation pointers:"
    for t in "$@"; do
        case "$t" in
            restic)
                cat <<'HELP'
  restic:
    - Debian/Ubuntu:    apt-get install restic
    - RHEL/Alma/Rocky:  enable EPEL first (dnf install epel-release),
                        then: dnf install restic
    - Any distro:       download a static binary from
                        https://github.com/restic/restic/releases
                        and place it at /usr/local/bin/restic (chmod 755)
HELP
                ;;
            rclone)
                cat <<'HELP'
  rclone:
    - Debian/Ubuntu:    apt-get install rclone
    - Distro packages can lag; current builds are at
      https://rclone.org/downloads/ (their install script is at
      https://rclone.org/install.sh, review it before running as root)
HELP
                ;;
            curl)
                cat <<'HELP'
  curl:
    - In every distro's base repository, e.g.
      apt-get install curl  /  dnf install curl
HELP
                ;;
        esac
    done
    echo "Install the missing tools, then re-run this installer."
}

ensure_dependencies() {
    # Check that the tools this project needs are present, and offer to
    # install any that are missing using the system's package manager:
    #   restic - the backup program itself (also does the encryption)
    #   rclone - lets restic talk to Google Drive
    #   curl   - used to call the smtp2go HTTP API when sending alert emails
    # systemd is required too, but a script cannot sensibly install it,
    # so it is only checked.
    # "command -v" prints the path of a command if it exists, or fails.
    if ! command -v systemctl >/dev/null 2>&1; then
        echo "This project schedules backups with systemd, but systemctl was not found." >&2
        echo "Use a Linux distribution that runs systemd (standard Infomaniak images do)." >&2
        exit 1
    fi

    local cmd missing=()
    for cmd in restic rclone curl; do
        if ! command -v "$cmd" >/dev/null 2>&1; then
            missing+=("$cmd")
        fi
    done

    if [[ ${#missing[@]} -eq 0 ]]; then
        # Everything is already here; show exactly what will be used.
        echo "Dependencies found:"
        echo "  restic: $(restic version 2>/dev/null | head -1)"
        echo "  rclone: $(rclone version 2>/dev/null | head -1)"
        echo "  curl:   $(curl --version 2>/dev/null | head -1)"
        return 0
    fi

    echo "Missing required tools: ${missing[*]}"

    # Detect the system's package manager. Conveniently, the command
    # names double as the package names for restic, rclone, and curl on
    # every package manager listed here.
    local pm=""
    for cmd in apt-get dnf yum zypper pacman; do
        if command -v "$cmd" >/dev/null 2>&1; then
            pm="$cmd"
            break
        fi
    done

    if [[ -z "$pm" ]]; then
        echo "No supported package manager found (looked for apt-get, dnf, yum, zypper, pacman)."
        manual_install_help "${missing[@]}"
        exit 1
    fi

    local yn
    read -rp "Install ${missing[*]} now with $pm? [Y/n]: " yn
    if [[ "$yn" =~ ^[Nn]$ ]]; then
        manual_install_help "${missing[@]}"
        exit 1
    fi

    # Run the right install command. Every branch is non-interactive so
    # the installer cannot stall on a hidden package-manager prompt.
    case "$pm" in
        apt-get)
            # Refresh package lists first; fresh servers often have none.
            apt-get update -qq
            DEBIAN_FRONTEND=noninteractive apt-get install -y "${missing[@]}"
            ;;
        dnf)    dnf install -y "${missing[@]}" ;;
        yum)    yum install -y "${missing[@]}" ;;
        zypper) zypper --non-interactive install "${missing[@]}" ;;
        pacman) pacman -Sy --noconfirm --needed "${missing[@]}" ;;
    esac

    # Trust nothing: re-check that every tool is now actually usable.
    local still_missing=()
    for cmd in "${missing[@]}"; do
        if ! command -v "$cmd" >/dev/null 2>&1; then
            still_missing+=("$cmd")
        fi
    done
    if [[ ${#still_missing[@]} -gt 0 ]]; then
        echo
        echo "FAIL - still missing after the install attempt: ${still_missing[*]}"
        echo "(on RHEL-family systems restic usually needs the EPEL repository first)"
        manual_install_help "${still_missing[@]}"
        exit 1
    fi

    echo "Dependencies installed:"
    echo "  restic: $(restic version 2>/dev/null | head -1)"
    echo "  rclone: $(rclone version 2>/dev/null | head -1)"
    echo "  curl:   $(curl --version 2>/dev/null | head -1)"
}

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

rclone_remote_exists() {
    # True when the named rclone remote is configured for the CURRENT
    # user (which is root, since this installer runs under sudo).
    # rclone listremotes prints one remote per line, each ending in ":".
    # grep -qx matches a whole line quietly (exit code only, no output).
    rclone listremotes 2>/dev/null | grep -qx "$1:"
}

find_user_rclone_configs() {
    # Print candidate rclone.conf files belonging to normal users, one
    # path per line. rclone configurations are per user, so a remote
    # created before running "sudo bash ./install.sh" usually lives in
    # the invoking user's home, not root's.
    # $SUDO_USER is set by sudo to the name of the user who invoked it;
    # their config is the most likely candidate, so it is printed first.
    local seen="" home_dir conf
    if [[ -n "${SUDO_USER:-}" && "$SUDO_USER" != "root" ]]; then
        # getent looks the user up in the password database; field 6 of
        # the colon-separated record is their home directory.
        home_dir="$(getent passwd "$SUDO_USER" 2>/dev/null | cut -d: -f6)"
        conf="$home_dir/.config/rclone/rclone.conf"
        if [[ -n "$home_dir" && -s "$conf" ]]; then
            echo "$conf"
            seen="$conf"
        fi
    fi
    # Also scan every home directory, in case the remote was set up by
    # a different user. -s is true for files that exist and are not
    # empty, so an unmatched glob pattern simply tests false.
    for conf in /home/*/.config/rclone/rclone.conf; do
        if [[ -s "$conf" && "$conf" != "$seen" ]]; then
            echo "$conf"
        fi
    done
}

offer_rclone_remote_fixes() {
    # Interactive repair loop for a missing rclone remote. Keeps offering
    # fixes and re-checking until the remote exists (returns 0) or the
    # user gives up (returns 1).
    # Usage: offer_rclone_remote_fixes REMOTE_NAME
    local remote="$1" choice pick n i remotes conf
    local conf_list=()
    while true; do
        echo
        echo "rclone remotes visible to root right now:"
        remotes="$(rclone listremotes 2>/dev/null)"
        if [[ -n "$remotes" ]]; then
            echo "$remotes" | sed 's/^/    /'
        else
            echo "    (none)"
        fi
        echo
        # Rebuild the candidate list on every pass, since a fix attempt
        # may have created or copied a config. A plain read loop is used
        # instead of process substitution, which minimal environments
        # can lack.
        conf_list=()
        while IFS= read -r conf; do
            if [[ -n "$conf" ]]; then
                conf_list+=("$conf")
            fi
        done <<< "$(find_user_rclone_configs)"
        echo "How do you want to fix the missing remote \"$remote\"?"
        if [[ ${#conf_list[@]} -gt 0 ]]; then
            echo "  1) Copy an existing user's rclone config to root. Found:"
            for i in "${!conf_list[@]}"; do
                echo "       $((i+1))) ${conf_list[$i]}"
            done
        else
            echo "  1) Copy an existing user's rclone config to root (none found under /home)"
        fi
        echo "  2) Run 'rclone config' now to create it"
        echo "     (choose: n for new remote, name it exactly \"$remote\", storage type \"drive\")"
        echo "  3) Give up for now"
        read -rp "Choose [1/2/3]: " choice
        case "$choice" in
            1)
                if [[ ${#conf_list[@]} -eq 0 ]]; then
                    echo "There is no user rclone.conf to copy. Try option 2 instead."
                    continue
                fi
                if [[ ${#conf_list[@]} -eq 1 ]]; then
                    pick="${conf_list[0]}"
                else
                    read -rp "Copy which one? [1-${#conf_list[@]}]: " n
                    if ! [[ "$n" =~ ^[0-9]+$ ]] || (( n < 1 || n > ${#conf_list[@]} )); then
                        echo "Invalid choice."
                        continue
                    fi
                    pick="${conf_list[$((n-1))]}"
                fi
                # Never clobber an existing root config silently: it may
                # hold other remotes that would be lost.
                if [[ -s /root/.config/rclone/rclone.conf ]]; then
                    read -rp "root already has an rclone config; REPLACE it (its current remotes are lost)? [y/N]: " n
                    if [[ ! "$n" =~ ^[Yy]$ ]]; then
                        continue
                    fi
                fi
                # chmod 600 because the copied file contains the Google
                # authorization tokens.
                if mkdir -p /root/.config/rclone \
                    && cp "$pick" /root/.config/rclone/rclone.conf \
                    && chmod 600 /root/.config/rclone/rclone.conf; then
                    echo "Copied $pick to /root/.config/rclone/rclone.conf"
                else
                    echo "Copy failed (see the error above)."
                    continue
                fi
                ;;
            2)
                # rclone config is its own interactive tool; hand the
                # terminal over to it and re-check when it exits.
                rclone config || true
                ;;
            3)
                return 1
                ;;
            *)
                echo "Please answer 1, 2, or 3."
                continue
                ;;
        esac
        if rclone_remote_exists "$remote"; then
            echo "Remote \"$remote\" is now configured."
            return 0
        fi
        echo "Remote \"$remote\" is still not configured; let's try again."
    done
}

verify_rclone_reachability() {
    # Prove the rclone remote can actually reach Google Drive, offering
    # fixes in a loop when it cannot. Returns 0 on success, 1 on give-up.
    # Usage: verify_rclone_reachability REMOTE_NAME
    local remote="$1" out choice
    while true; do
        printf 'Checking "%s" can reach Google Drive... ' "$remote"
        # rclone lsd lists top-level folders. Only success matters, so
        # the listing is discarded and errors are captured. The redirect
        # order matters: 2>&1 first points errors at the capture, then
        # 1>/dev/null discards the normal listing.
        if out=$(rclone lsd "${remote}:" 2>&1 1>/dev/null); then
            echo "OK"
            return 0
        fi
        echo "FAIL"
        echo "rclone said:"
        echo "$out" | head -5 | sed 's/^/    /'
        echo
        echo "How do you want to proceed?"
        echo "  1) Refresh the Google authorization (runs: rclone config reconnect ${remote}:)"
        echo "  2) Open the rclone configuration tool (runs: rclone config)"
        echo "  3) Just test again"
        echo "  4) Give up for now"
        read -rp "Choose [1/2/3/4]: " choice
        case "$choice" in
            1) rclone config reconnect "${remote}:" || true ;;
            2) rclone config || true ;;
            3) : ;;
            4) return 1 ;;
            *) echo "Please answer 1, 2, 3, or 4." ;;
        esac
    done
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

restore_files() {
    # Guided file restore from the restic repository, built to be SAFE on
    # a freshly installed system: when restoring straight into place, a
    # set of protected paths is never overwritten, so the restore cannot
    # break the machine's boot setup, network access, identity, or the
    # backup configuration this installer just created.
    # Use this when the fresh system already boots fine and you just want
    # the data back (the case where a bootloader restore is not possible
    # or not worth the trouble).
    local snap choice target_mode target_dir yn include_paths p
    local protected=() args=()

    echo
    echo "--- Restore files from backup ---"

    # Bail out gracefully when the repository has no snapshots yet.
    # "restic snapshots latest" only succeeds when at least one exists.
    if ! restic snapshots latest >/dev/null 2>&1; then
        echo "No snapshots found in $RESTIC_REPOSITORY - nothing to restore yet."
        return 1
    fi

    echo "Snapshots in the repository (newest last):"
    restic snapshots 2>/dev/null | tail -n 12 | sed 's/^/    /'
    echo
    read -rp "Snapshot to restore [latest]: " snap
    snap="${snap:-latest}"

    # Paths an IN-PLACE restore must never overwrite, and why:
    protected=(
        "$BOOTLOADER_BACKUP_DIR"          # bootloader dumps and notes for THIS machine
        "/etc/restic"                     # the current backup config and keys
        "/boot"                           # kernels and bootloader of the running system
        "/etc/fstab"                      # mount table matching the CURRENT disk UUIDs
        "/etc/crypttab"                   # encrypted-disk mappings for the current disk
        "/etc/machine-id"                 # unique identity of this installation
        "/etc/netplan"                    # network settings: restoring another
        "/etc/network"                    # machine's addresses onto this one can
        "/etc/systemd/network"            # cut off your SSH access
        "/etc/NetworkManager/system-connections"
    )

    echo
    echo "What do you want restored?"
    echo "  1) Everything in the snapshot"
    echo "  2) Specific paths only (you type them)"
    read -rp "Choose [1/2]: " choice
    include_paths=""
    if [[ "$choice" == "2" ]]; then
        read -rp "Paths to restore (space-separated, e.g. /home /var/www): " include_paths
        if [[ -z "$include_paths" ]]; then
            echo "Nothing typed; restoring everything instead."
        fi
    fi

    echo
    echo "Where should the files go?"
    echo "  1) Straight into place on this system."
    echo "     Overwrites matching files, never deletes extra ones, and always"
    echo "     skips the protected paths (boot files, fstab, network settings,"
    echo "     machine identity, current backup config, bootloader dumps)."
    echo "  2) A staging folder to review first."
    echo "     Nothing on the live system changes, and nothing is skipped, so"
    echo "     this is also how to grab reference copies of protected files"
    echo "     like the old fstab."
    read -rp "Choose [1/2]: " target_mode
    if [[ "$target_mode" == "2" ]]; then
        target_dir="/root/restore-$(date +%Y%m%d-%H%M%S)"
        read -rp "Staging folder [$target_dir]: " choice
        target_dir="${choice:-$target_dir}"
        if ! mkdir -p "$target_dir"; then
            echo "Could not create $target_dir - restore cancelled."
            return 1
        fi
    else
        target_dir="/"
    fi

    # Build the restic command as an array so every argument stays intact.
    args=(restore "$snap" --target "$target_dir" --verbose)
    if [[ "$target_dir" == "/" ]]; then
        # Protective excludes only apply in place. In restic, excludes win
        # over includes, so even an explicitly typed protected path stays
        # safe (use the staging folder to retrieve those).
        for p in "${protected[@]}"; do
            args+=(--exclude "$p")
        done
    fi
    if [[ -n "$include_paths" ]]; then
        # Intentional word splitting: each typed path becomes an include.
        # shellcheck disable=SC2086
        for p in $include_paths; do
            args+=(--include "$p")
        done
    fi

    echo
    echo "About to run:"
    echo "    restic ${args[*]}"
    if [[ "$target_dir" == "/" ]]; then
        echo "This restores INTO THE LIVE SYSTEM (protected paths excluded)."
    fi
    read -rp "Proceed? [y/N]: " yn
    if [[ ! "$yn" =~ ^[Yy]$ ]]; then
        echo "Restore cancelled - nothing was changed."
        return 1
    fi

    # Run restic directly (not captured) so its progress is visible.
    if restic "${args[@]}"; then
        echo
        echo "Restore finished."
        if [[ "$target_dir" == "/" ]]; then
            cat <<'AFTER'
After an in-place restore:
  - Restored service configs are on disk, but running services still
    use their old settings. Run: systemctl daemon-reload, restart the
    affected services, or reboot once you have looked things over.
  - The protected paths were NOT touched: boot files, fstab, network
    settings, machine identity, the backup config, and the bootloader
    dumps are all exactly as the installer left them.
  - Old copies of protected files remain readable from the snapshot,
    for example:  restic dump latest /etc/fstab
AFTER
        else
            echo "Files are staged under $target_dir (snapshot paths mirrored inside)."
            echo "Review them and move what you need, for example:"
            echo "    rsync -a $target_dir/home/ /home/"
        fi
        return 0
    else
        echo "Restore FAILED - review the restic output above."
        return 1
    fi
}

# Make sure every required tool is present (offering to install missing
# ones) before either mode below does any real work.
ensure_dependencies

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
# Restore-only mode: sudo bash ./install.sh --restore
# =============================================================================
if [[ "$MODE" == "restore" ]]; then
    if [[ ! -f "$CONFIG_FILE" ]]; then
        echo "Missing $CONFIG_FILE - run the installer first." >&2
        exit 1
    fi
    # Load the saved settings, then run only the guided restore and exit.
    # shellcheck disable=SC1090
    source "$CONFIG_FILE"
    # Older configs may predate this setting; fall back to the default.
    : "${BOOTLOADER_BACKUP_DIR:=/var/lib/restic/bootloader}"
    export RESTIC_REPOSITORY RESTIC_PASSWORD_FILE
    restore_files
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
# Folder the backup script refreshes before every run with bootloader
# and disk layout dumps plus restore notes. It is always included in
# the backup, even when BACKUP_PATHS does not cover it.
: "${BOOTLOADER_BACKUP_DIR:=/var/lib/restic/bootloader}"
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
BOOTLOADER_BACKUP_DIR="$BOOTLOADER_BACKUP_DIR"
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
    if rclone_remote_exists "$RCLONE_REMOTE"; then
        echo "OK"
    else
        echo "FAIL"
        echo "No rclone remote named \"$RCLONE_REMOTE\" is configured for the root user."
        echo "(rclone configurations are per user, so a remote created as your normal user is invisible to root)"
        # Offer to fix it right here: copy a user's config to root, or
        # run rclone config interactively, re-checking after each try.
        if ! offer_rclone_remote_fixes "$RCLONE_REMOTE"; then
            cat <<TROUBLE

To fix it by hand later:
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
    fi

    # Now prove the remote actually reaches Google Drive, again with
    # interactive fixes on failure.
    if ! verify_rclone_reachability "$RCLONE_REMOTE"; then
        cat <<TROUBLE

To fix it by hand later:
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

# --- Offer a guided restore when the repository already has history ---
# This is the rebuild-after-disaster path: on a fresh system pointed at
# an existing repository, the natural next step is pulling files back.
if restic snapshots latest >/dev/null 2>&1; then
    echo
    echo "This repository already contains backups from before."
    read -rp "Restore files from a snapshot now? [y/N]: " yn
    if [[ "$yn" =~ ^[Yy]$ ]]; then
        restore_files
    else
        echo "You can restore anytime with: sudo bash ./install.sh --restore"
    fi
fi

echo
echo "Done. Run a manual backup test with: $BIN_DIR/restic-backup.sh"
