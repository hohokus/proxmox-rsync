#!/bin/bash
# set -e	    ;# exit on first error
set -u          ;# exit on undefined var
# set -x	    ;# show me what you got
set -o pipefail ;# do not hide pipeline errors

########################################################################
#
# openmediavault had an easy way to take rsync backups to external USB devices.
# proxmox doesn't offer this directly (but that's OK).
#
# with our external USB drive mounted in proxmox, we get a lot of chatter
# and the drive never spins down.  since it's external USB, we can't use 'hdparm'
# or 'smartctl' to control it.
#
# instead: leave the device plugged in but only mount as needed, which keeps
# it quiet.
#
# this assumes:
#   - you have a USB device visible in proxmox under 'disks'
#   - it has a mount point somewhere & appears in 'disks > directory'
#   - you know the systemd mount unit name
#
# install:
#   copy this script to /root/proxmox_rsync.sh
#
#   configure options below as appropriate
#
#   create crontab
#       crontab -e
#       MAILTO="root"
#       # 05:00 am sunday
#       0 5 * * 0 /root/proxmox_rsync.sh
#
#   script output is emailed to root (same as other proxmox notifications)
#
# openmediavault version:
# https://github.com/openmediavault/openmediavault/blob/b37182db9de8988cea343a0cd1dad7a294b03aa1/deb/openmediavault/srv/salt/omv/deploy/rsync/files/cron-rsync-script.j2
#
# systemctl exit status
# https://www.freedesktop.org/software/systemd/man/latest/systemctl.html#Exit%20status
#
# 2025-01-07, hohokus@gmail.com
#
########################################################################

SCRIPTDIR=$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )

# rsync options
RS_SOURCE="/zpool"                                  ;# no trailing slash
RS_DESTINATION="/mnt/pve/usb_external"              ;# no trailing slash
RS_OPTS="--recursive --group --owner --times --perms --links"
RS_OPTS="${RS_OPTS} --delete"                       ;# delete from destination
# RS_OPTS="${RS_OPTS} --dry-run"                    ;# simulate only
# RS_LOG="--verbose --stats --human-readable"       ;# verbose lists every file touched
RS_LOG="--stats --human-readable"

# systemd unit for mount
SYSD_UNIT="mnt-pve-usb_external.mount"

# track errors
ERROR_STATUS=0

########################################################################

function usb_mount () {
    # mount target
    echo "Mounting \"${RS_DESTINATION}\" via \"systemctl start "${SYSD_UNIT}"\" .."
    
    systemctl start "${SYSD_UNIT}"
    RC=$?
    case "$RC" in
        0) echo "Mounted successfully." ;;
        *) echo "ERROR: Mount failed. (${RC})"
           echo "ABORTING. Cannot continue."
           exit ${RC}
           ;;
    esac

    echo

    # display systemd unit status
    systemctl status --lines=2 "${SYSD_UNIT}"
    RC=$?
    case "$RC" in
        0) true ;;
        *) echo "ERROR: \"systemctl status ${SYSD_UNIT}\" failed. How is that possible? (${RC})"
           echo "ABORTING. Cannot continue."
           exit ${RC}
           ;;
    esac

    # confirm mounted
    grep --silent "${RS_DESTINATION}" /proc/mounts
    RC=$?
    case "$RC" in
        0) true ;;
        *) echo "ERROR: \"${RS_DESTINATION}\" was not found in \"/proc/mounts\", but should be mounted. (${RC})"
           echo "ABORTING. Cannot continue."
           exit ${RC}
           ;;
    esac

    echo

    return 0
}


function usb_unmount () {
    # unmount target
    echo
    echo "Unmounting \"${RS_DESTINATION}\" via \"systemctl stop "${SYSD_UNIT}"\" .."

    systemctl stop "${SYSD_UNIT}"
    RC=$?
    case "$RC" in
        0) echo "Unmounted successfully." ;;
        *) echo "ERROR: Unmount failed. (${RC})"
           ERROR_STATUS=1
           ;;
    esac

    echo

    # display systemd unit status
    systemctl status --lines=3 "${SYSD_UNIT}"
    RC=$?
    case "$RC" in
        3) true ;;
        *) echo "ERROR: \"systemctl status ${SYSD_UNIT}\" exited with unexpected status (expected 3). (${RC})"
           ERROR_STATUS=1
           ;;
    esac

    # confirm unmounted
    grep --silent --invert-match "${RS_DESTINATION}" /proc/mounts
    RC=$?
    case "$RC" in
        0) true ;;
        *) echo "ERROR: \"${RS_DESTINATION}\" found in \"/proc/mounts\", but should be unmounted. (${RC})"
           ERROR_STATUS=1
           ;;
    esac

    return 0
}


function do_rsync () {
    # remove any trailing slash
    RS_SOURCE=${RS_SOURCE%/}
    RS_DESTINATION=${RS_DESTINATION%/}

    # rsync
    echo
    echo "Rsyncing \"${RS_SOURCE}\" to \"${RS_DESTINATION}/\" .."

    rsync ${RS_OPTS} ${RS_LOG} ${RS_SOURCE} ${RS_DESTINATION}/
    RC=$?
    case "$RC" in
        0) echo "Rsync completed successfully. (${RC})" ;;
        *) echo "ERROR: Rsync failed. (${RC})"
           ERROR_STATUS=1
           ;;
    esac

    # pause to allow drive time to finish writes
    sleep 5

    echo

    return 0
}


function check_freespace () {
    echo
    echo "Checking free space on \"${RS_DESTINATION}\" .."

    echo
    df -H "${RS_DESTINATION}"
    echo

    return 0
}


function main () {
    # must be run as root
    if [[ ( $(id -un) != root ) ]]; then
        echo "Run me as root!"
        exit 0
    fi

    # log useful details
    echo "script: $(basename $0)"
    echo "scriptdir: ${SCRIPTDIR}"
    echo "hostname: $(hostname)"
    echo "uname: $(uname -a)"
    echo "whoami: $(whoami)"
    echo "now: $(date "+%Y-%m-%d %H:%M:%S")"
    echo "rsync source: ${RS_SOURCE}"
    echo "rsync destination: ${RS_DESTINATION}"
    echo "rsync command: rsync ${RS_OPTS} ${RS_LOG} ${RS_SOURCE} ${RS_DESTINATION}/"
    echo

    # mount external drive
    usb_mount

    # rsync
    do_rsync

    # check free space
    check_freespace

    # unmount external drive
    usb_unmount

    # exit nicely
    echo
    case "${ERROR_STATUS}" in
        0) echo "Done. (0)"
           exit 0
           ;;
        *) echo "Done, errors were encountered. (${ERROR_STATUS})"
           exit ${ERROR_STATUS}
           ;;
    esac
}

########################################################################

if (command -v ts) >/dev/null 2>&1 ; then
    # 'moreutils' is installed -- display timestamps
    # https://unix.stackexchange.com/questions/26728/prepending-a-timestamp-to-each-line-of-output-from-a-command
    main "$@" | ts '[%Y-%m-%d %H:%M:%S]'
else
    # no timestamps
    main "$@"
fi

