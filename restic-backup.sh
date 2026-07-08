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

# Folder refreshed before every backup with bootloader and disk layout
# data plus restore notes. Older configs may not define it yet, so fall
# back to the default (the := pattern assigns only when unset or empty).
: "${BOOTLOADER_BACKUP_DIR:=/var/lib/restic/bootloader}"

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

write_restore_notes() {
    # Generate RESTORE-NOTES.txt: live system facts at the top, recovery
    # walkthroughs below. Regenerated on every backup so the details
    # (disk names, UUIDs, repository) never go stale.
    # Arguments: $1 = folder to write into, $2 = boot disk name (may be
    # empty), $3 = "BIOS" or "UEFI"
    local dir="$1" disk="${2:-}" mode="$3"
    local notes="$dir/RESTORE-NOTES.txt" disk_display
    if [[ -n "$disk" ]]; then
        disk_display="/dev/$disk"
    else
        disk_display="unknown (no plain block device found)"
    fi

    # Part 1: live facts. Variables ARE expanded in this block because
    # the HEADER delimiter is unquoted.
    cat > "$notes" <<HEADER
RESTORE NOTES for $(hostname) - generated $(date -Is) by restic-backup.sh
=========================================================================

Facts about this system at the time of this backup:
  Boot disk:         $disk_display
  Boot mode:         $mode
  restic repository: $RESTIC_REPOSITORY
  Encryption key file (on the live system): $RESTIC_PASSWORD_FILE
  This folder's path in the backup: $dir

You need TWO things for any restore after a total loss:
  1. A copy of the encryption key, stored OFF this machine.
  2. Access to the Google Drive behind the rclone remote.
Without the key these backups cannot be read by anyone.
HEADER

    # Part 2: instructions. The 'BODY' delimiter is quoted, so nothing
    # below is expanded and every $ lands in the file exactly as written.
    cat >> "$notes" <<'BODY'

WHAT IS IN THIS FOLDER
----------------------
  partition-table.sfdisk  Full partition table dump (works for MBR and GPT).
                          Recreate the layout on a same-size blank disk:
                            sfdisk /dev/DISK < partition-table.sfdisk
                          WARNING: that command replaces the target disk's
                          partition table.
  first-1MiB.bin          Byte copy of the start of the boot disk: the MBR
                          (boot code plus old-style partition table) and the
                          gap where BIOS GRUB embeds itself. A last-resort
                          copy; reinstalling GRUB (below) is always cleaner.
                          To restore only the 446 bytes of boot code without
                          touching the partition table:
                            dd if=first-1MiB.bin of=/dev/DISK bs=446 count=1
  blkid.txt, lsblk.txt    The filesystem UUIDs and disk layout this system
                          had. fstab and grub.cfg refer to these UUIDs.
  fstab, grub-default,    Convenience copies of the boot-relevant config
  grub.cfg                files (also present in the main file backup).
  boot-mode.txt           Whether this system boots with BIOS or UEFI.
  efibootmgr.txt          UEFI only: the firmware boot entries.
  os-release, uname.txt   Which OS and kernel this system ran.
  WARNINGS.txt            Only present if some of the above could not be
                          collected on the last run.

READ THESE NOTES WITHOUT DOING A FULL RESTORE
---------------------------------------------
From any machine with restic, the key, and rclone access to the drive:
  restic -r REPO --password-file KEYFILE dump latest THIS-FILES-PATH
(substitute the repository, a file containing your key, and the path
shown in the facts section above)

OPTION 1: INFOMANIAK SNAPSHOT (easiest, if you enabled snapshots)
-----------------------------------------------------------------
A VPS Cloud snapshot restores the whole disk, bootloader included, to
the exact state at the snapshot date.
  Manager (manager.infomaniak.com) -> your VPS -> restore the snapshot.
  Guide: https://www.infomaniak.com/en/support/faq/2297
Restoring the system disk is irreversible and discards anything newer
on that disk, but files can be pulled back afterwards from this restic
backup. Snapshots complement restic; they do not replace it (they live
at the same provider, on the same infrastructure).

OPTION 2: RESCUE MODE REPAIR (system exists but will not boot)
--------------------------------------------------------------
Typical causes: broken GRUB update, bad fstab edit, failed kernel.

On a VPS Cloud / VPS Lite (Infomaniak Manager):
  1. Manager -> click the VPS name -> Manage -> Restart (safe mode).
     This boots a rescue system; your real system disk shows up as an
     extra disk (often vdb, sometimes sdb; check with: lsblk).
     Guide: https://www.infomaniak.com/en/support/faq/1106
  2. SSH in with your key, or with the temporary password shown in the
     Manager.
  3. Mount your system and enter it (adjust partition names to lsblk):
       mount /dev/vdb1 /mnt
       mount --bind /dev  /mnt/dev
       mount --bind /proc /mnt/proc
       mount --bind /sys  /mnt/sys
       chroot /mnt
       export PATH="$PATH:/usr/sbin:/sbin:/bin"
     UEFI systems: also mount the EFI partition before entering, e.g.
       mount /dev/vdb15 /mnt/boot/efi   (real name is in lsblk.txt)
  4. Repair. The usual fixes, run inside the chroot:
       BIOS:  grub-install /dev/vdb        (the disk, not a partition)
              update-grub
       UEFI:  grub-install --target=x86_64-efi --efi-directory=/boot/efi
              update-grub
       (RHEL-family systems use grub2-install and
        grub2-mkconfig -o /boot/grub2/grub.cfg)
     Damaged or missing files? Install restic and rclone in the rescue
     system, write your saved encryption key to a file, and restore just
     what you need, for example:
       restic -r REPO --password-file KEYFILE restore latest \
         --target /mnt --include /etc/default/grub
  5. Exit the chroot, then deactivate safe mode in the Manager so the
     VPS boots from your repaired disk again.

On Public Cloud (OpenStack CLI):
  openstack server rescue INSTANCE      (old disk appears as vdb)
  ...mount, chroot, and repair exactly as above...
  openstack server unrescue INSTANCE
  Lost SSH access? Use the Infomaniak rescue image with a password:
    openstack server set --property rescue_pass=SOMEPASS INSTANCE
    openstack server rescue --image "Infomaniak Rescue Image" INSTANCE
    then SSH as user "infomaniak" with that password. Instances booted
    from a volume need: --os-compute-api-version 2.87
  Guide: https://docs.infomaniak.cloud/compute/instances/lifecyle_and_rescue/

Watching the boot screen / reaching the GRUB menu:
  Manager -> the VPS -> Open VNC console, restart the server, refresh
  the console early and press a key when GRUB appears.
  Guide: https://www.infomaniak.com/en/support/faq/2182

OPTION 3: FULL REBUILD ON A FRESH VPS OR DISK (total loss)
----------------------------------------------------------
  1. Create a fresh VPS at Infomaniak, ideally the same distro and
     version as recorded in os-release. A fresh install already boots,
     which makes this the low-drama path: you restore your DATA into a
     working system instead of rebuilding the bootloader byte by byte.
  2. Install restic and rclone, reconnect the Google Drive remote
     (rclone config), and write your saved encryption key to a file.
  3. Sanity-check access:
       restic -r REPO --password-file KEYFILE snapshots
  4. Restore files. Two approaches:
       a) Selective (recommended): restore /home, /etc, /root, /srv,
          /var and friends into place while keeping the fresh system's
          /boot and bootloader. Before rebooting, re-check that the
          UUIDs in /etc/fstab match the NEW disk (compare blkid output
          against the restored fstab; the old values are in blkid.txt).
       b) Full clone: from rescue mode, give the new same-size disk the
          old layout (sfdisk /dev/vda < partition-table.sfdisk), make
          filesystems, restore everything with restic into them, give
          the partitions their OLD UUIDs so fstab and grub.cfg match
          (ext4 example: tune2fs -U OLD-UUID /dev/vdaX, values in
          blkid.txt), then reinstall GRUB from a chroot as in option 2.
  5. Reboot with the VNC console open, then run a manual backup to
     confirm the cycle works again:
       /usr/local/bin/restic-backup.sh

REMEMBER
--------
These notes exist inside every backup snapshot and on the live system.
They are only readable with the encryption key. Keep an off-machine
copy of the key and test it with:  sudo bash ./install.sh --test-key
BODY
}

backup_bootloader() {
    # Capture the pieces of the boot setup that a file-level backup
    # cannot see, then drop them in BOOTLOADER_BACKUP_DIR, which is
    # always included in the backup:
    #   - the partition table (file backups only see inside filesystems)
    #   - the boot code at the start of the disk (lives outside any file)
    #   - the filesystem UUIDs that fstab and grub.cfg point at
    # Every step is best-effort: a problem is recorded in WARNINGS.txt
    # and the backup itself still runs.
    local dir="$BOOTLOADER_BACKUP_DIR"
    mkdir -p "$dir"
    # Root-only: the dumps reveal disk layout details.
    chmod 700 "$dir"
    # Start each run with a clean warnings file so old problems do not
    # linger after they are fixed.
    rm -f "$dir/WARNINGS.txt"

    # --- Work out which disk the system boots from ---
    # findmnt prints the device behind /, e.g. /dev/vda1. lsblk's PKNAME
    # column turns a partition into its parent disk name, e.g. vda.
    local root_src root_disk=""
    root_src="$(findmnt -no SOURCE / 2>/dev/null || true)"
    if [[ -n "$root_src" && -b "$root_src" ]]; then
        root_disk="$(lsblk -no PKNAME "$root_src" 2>/dev/null | head -1 || true)"
    fi

    if [[ -n "$root_disk" && -b "/dev/$root_disk" ]]; then
        # Partition table dump, restorable with sfdisk (see the notes).
        sfdisk --dump "/dev/$root_disk" > "$dir/partition-table.sfdisk" 2>/dev/null \
            || echo "could not dump the partition table of /dev/$root_disk" >> "$dir/WARNINGS.txt"
        # First 1 MiB of the disk: the MBR and the embedding gap BIOS
        # GRUB uses. status=none keeps dd quiet on success.
        dd if="/dev/$root_disk" of="$dir/first-1MiB.bin" bs=1M count=1 status=none 2>/dev/null \
            || echo "could not copy the first 1MiB of /dev/$root_disk" >> "$dir/WARNINGS.txt"
    else
        echo "could not identify the boot disk (container or unusual root device?)" >> "$dir/WARNINGS.txt"
    fi

    # Filesystem UUIDs and layout: fstab and grub.cfg refer to these.
    blkid > "$dir/blkid.txt" 2>/dev/null || true
    lsblk -f > "$dir/lsblk.txt" 2>/dev/null || true

    # Convenience copies of boot-related config. They are also in the
    # main file backup; duplicating them here keeps this folder usable
    # on its own.
    cp /etc/fstab "$dir/fstab" 2>/dev/null || true
    cp /etc/default/grub "$dir/grub-default" 2>/dev/null || true
    local g
    for g in /boot/grub/grub.cfg /boot/grub2/grub.cfg; do
        if [[ -f "$g" ]]; then
            cp "$g" "$dir/grub.cfg" 2>/dev/null || true
            break
        fi
    done

    # Boot mode. The directory /sys/firmware/efi only exists when the
    # system was booted through UEFI firmware.
    local boot_mode="BIOS"
    if [[ -d /sys/firmware/efi ]]; then
        boot_mode="UEFI"
        # Firmware boot entries live in NVRAM, not on disk, so they are
        # invisible to file backups; record them here.
        if command -v efibootmgr >/dev/null 2>&1; then
            efibootmgr -v > "$dir/efibootmgr.txt" 2>/dev/null || true
        fi
        findmnt /boot/efi > "$dir/esp-mount.txt" 2>/dev/null || true
    fi
    echo "$boot_mode" > "$dir/boot-mode.txt"

    # What ran here, for picking a matching image during a rebuild.
    uname -a > "$dir/uname.txt" 2>/dev/null || true
    cp /etc/os-release "$dir/os-release" 2>/dev/null || true

    write_restore_notes "$dir" "$root_disk" "$boot_mode"

    if [[ -f "$dir/WARNINGS.txt" ]]; then
        log "Bootloader backup completed with warnings: $(tr '\n' '; ' < "$dir/WARNINGS.txt")"
    fi
}

# --- Bootloader backup ---
# Refresh the bootloader dumps and restore notes so every snapshot
# carries current copies.
log "Refreshing bootloader backup in $BOOTLOADER_BACKUP_DIR"
backup_bootloader

# --- Backup ---
log "Starting backup of: $BACKUP_PATHS"
# BACKUP_PATHS is intentionally unquoted so that a space-separated list
# like "/home /etc" expands into multiple arguments for restic.
# The bootloader folder is passed as an extra path so it is included in
# every snapshot even when BACKUP_PATHS is a narrow list that does not
# cover it.
# The command's combined output (stdout and stderr, merged by 2>&1) is
# captured into BACKUP_OUT so we can log it and email it on failure.
# shellcheck disable=SC2086
if ! BACKUP_OUT=$(restic backup $BACKUP_PATHS "$BOOTLOADER_BACKUP_DIR" --exclude-file="$EXCLUDE_FILE" 2>&1); then
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
