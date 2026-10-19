#!/usr/bin/env bash
#
# 01-preflight.sh -- check the backup drive is connected properly before you
# commit to a multi-hour transfer.
#
#   ./01-preflight.sh                 # inspect the default drive, read-only
#   ./01-preflight.sh --speed-test    # add a real throughput measurement (reads only)
#   ./01-preflight.sh /path/to/mount  # inspect a different drive
#
# By default this script makes NO changes and writes NOTHING to the drive.
# --speed-test reads existing files. --write-test is the only mode that
# writes, and it removes its temp file afterwards.
#
set -Eeuo pipefail

PROG=${0##*/}
HERE=$(cd -- "$(dirname -- "$(readlink -f "$0")")" && pwd)
# shellcheck source=lib-common.sh
source "$HERE/lib-common.sh"

# Defaults measured on the author's machine with the standard filter list.
# Override the size with --need; the drive is located automatically.
DEFAULT_NEED_GIB=401
DEFAULT_NEED_FILES=3927573

TARGET="" SPEED_TEST=0 WRITE_TEST=0 NEED_GIB=$DEFAULT_NEED_GIB
WARNINGS=0 BLOCKERS=0

ok()    { printf '  \033[32m[ OK ]\033[0m %s\n' "$*"; }
nope()  { printf '  \033[31m[FAIL]\033[0m %s\n' "$*"; BLOCKERS=$((BLOCKERS+1)); }
meh()   { printf '  \033[33m[WARN]\033[0m %s\n' "$*"; WARNINGS=$((WARNINGS+1)); }
note()  { printf '         %s\n' "$*"; }
hdr()   { printf '\n\033[1m%s\033[0m\n' "$*"; }

usage() {
    cat <<EOF
Usage: $PROG [mount-point|device] [options]

Options:
  --speed-test     Measure real read throughput from files already on the
                   drive (read-only; needs a file >=1 GiB present)
  --write-test     Measure write throughput with a 512 MiB temp file, then
                   delete it. This is the only mode that writes to the drive.
  --need GIB       Space required (default $DEFAULT_NEED_GIB GiB, as measured)
  -h, --help       This message
EOF
}

while (( $# )); do
    case $1 in
        --speed-test) SPEED_TEST=1; shift ;;
        --write-test) WRITE_TEST=1; SPEED_TEST=1; shift ;;
        --need)       NEED_GIB=${2:?}; shift 2 ;;
        -h|--help)    usage; exit 0 ;;
        -*)           die "unknown option: $1" ;;
        *)            TARGET=$1; shift ;;
    esac
done

# ---------------------------------------------------------- locate drive ---
hdr "1. Drive"

# Locate the drive: explicit argument, then $BACKUP_UUID, then the single
# removable filesystem mounted under /run/media/$USER.
if [[ -z $TARGET ]]; then
    if [[ -n ${BACKUP_UUID:-} ]]; then
        TARGET=$(findmnt -nro TARGET -S "UUID=$BACKUP_UUID" 2>/dev/null | head -1 || true)
        [[ -n $TARGET ]] || TARGET="/run/media/$USER/$BACKUP_UUID"
    else
        # -r and --list are mutually exclusive in findmnt; -r alone is enough.
        mapfile -t CANDIDATES < <(findmnt -rno TARGET 2>/dev/null | grep "^/run/media/$USER/" || true)
        case ${#CANDIDATES[@]} in
            1) TARGET=${CANDIDATES[0]} ;;
            0) nope "no removable drive mounted under /run/media/$USER"
               note "Plug the drive in, or name it explicitly:"
               note "    $PROG /path/to/mount"
               note "    BACKUP_UUID=<filesystem-uuid> $PROG"
               exit 2 ;;
            *) nope "more than one drive is mounted under /run/media/$USER:"
               for c in "${CANDIDATES[@]}"; do note "    $c"; done
               note "Name the one you want: $PROG <mount-point>"
               exit 2 ;;
        esac
    fi
fi

if [[ ! -d $TARGET ]]; then
    nope "not mounted: $TARGET"
    note "Plug the drive in and let the desktop mount it, then re-run."
    exit 2
fi

MNT=$(findmnt -nro TARGET --target "$TARGET" | head -1)
SRCDEV=$(findmnt -nro SOURCE --target "$TARGET" | head -1)
FSTYPE=$(findmnt -nro FSTYPE --target "$TARGET" | head -1)
MOPTS=$(findmnt -nro OPTIONS --target "$TARGET" | head -1)
DEV=$(resolve_queue_dev "$MNT" || true)

[[ -n $DEV ]] || { nope "cannot resolve a block device for $MNT"; exit 2; }

MODEL=$(cat "/sys/block/$DEV/device/model" 2>/dev/null | tr -s ' ' || echo unknown)
ok "mounted: $MNT"
note "device:  $SRCDEV  (disk /dev/$DEV, model: ${MODEL:-unknown})"

# ------------------------------------------------------------ filesystem ---
hdr "2. Filesystem"

case $FSTYPE in
    ext2|ext3|ext4|xfs|btrfs|f2fs|zfs)
        ok "$FSTYPE -- stores UNIX permissions, ownership and symlinks" ;;
    exfat|ntfs|ntfs3|vfat|msdos)
        nope "$FSTYPE cannot store UNIX permissions, ownership or symlinks"
        note "Your .ssh private keys would restore world-readable and ssh would"
        note "refuse them. Reformat as ext4 or xfs before backing up." ;;
    *)  meh "unrecognised filesystem '$FSTYPE' -- verify it preserves permissions" ;;
esac

if [[ ,$MOPTS, == *,ro,* ]]; then
    nope "mounted read-only"
else
    ok "mounted read-write"
fi

if [[ -w $MNT ]]; then ok "writable by $USER"
else nope "not writable by $USER (owned by $(stat -c '%U' "$MNT"))"; fi

# ----------------------------------------------------------------- space ---
hdr "3. Capacity"

# Portable forms on purpose: the --output field names vary between coreutils
# releases ('ifree' vs 'iavail'), and a failure there is silent under pipefail.
AVAIL_B=$(df -B1 "$MNT" | awk 'NR==2{print $4}')
AVAIL_GIB=$(( AVAIL_B / 1024 / 1024 / 1024 ))
IFREE=$(df -i "$MNT" 2>/dev/null | awk 'NR==2{print $4}')

printf '         free: %s   needed: ~%s GiB\n' "$(numfmt --to=iec "$AVAIL_B")" "$NEED_GIB"
if (( AVAIL_GIB >= NEED_GIB + 20 )); then
    ok "space is sufficient ($(( AVAIL_GIB - NEED_GIB )) GiB headroom)"
elif (( AVAIL_GIB >= NEED_GIB )); then
    meh "fits, but only $(( AVAIL_GIB - NEED_GIB )) GiB spare -- tight"
else
    nope "short by $(( NEED_GIB - AVAIL_GIB )) GiB"
fi

if [[ $IFREE == [0-9]* ]] && (( IFREE > DEFAULT_NEED_FILES )); then
    ok "inodes: $(numfmt --to=si "$IFREE") free for ~$(numfmt --to=si "$DEFAULT_NEED_FILES") files"
else
    meh "inode headroom looks tight (free: $IFREE)"
fi

# ------------------------------------------------------ USB link analysis ---
hdr "4. USB link"

# Climb sysfs collecting every USB device node between the disk and the root
# hub. First entry is the drive itself, last is the root hub.
mapfile -t CHAIN < <(
    p=$(readlink -f "/sys/block/$DEV" 2>/dev/null)
    while [[ -n $p && $p != / ]]; do
        [[ -f $p/speed && -f $p/devnum ]] && printf '%s\n' "$p"
        p=$(dirname "$p")
    done
)

if (( ${#CHAIN[@]} == 0 )); then
    ok "not a USB device (internal bus) -- link analysis not applicable"
    DEV_SPEED=""
else
    DEV_SPEED=$(cat "${CHAIN[0]}/speed")
    USBVER=$(tr -d ' ' <"${CHAIN[0]}/version" 2>/dev/null || echo '?')

    # Fastest speed anywhere upstream of the drive.
    UPSTREAM_MAX=0
    for ((i=1; i<${#CHAIN[@]}; i++)); do
        s=$(cat "${CHAIN[i]}/speed" 2>/dev/null || echo 0)
        (( s > UPSTREAM_MAX )) && UPSTREAM_MAX=$s
    done

    # Fastest root hub present anywhere on the machine.
    SYS_MAX=0
    for h in /sys/bus/usb/devices/usb*/speed; do
        s=$(cat "$h" 2>/dev/null || echo 0); (( s > SYS_MAX )) && SYS_MAX=$s
    done

    # Transport driver: uas does command queueing, usb-storage (BOT) does not
    # and is markedly worse with large numbers of small files.
    UDRIVER=unknown
    for intf in "${CHAIN[0]}"/*:*; do
        [[ -e $intf/driver ]] && { UDRIVER=$(basename "$(readlink -f "$intf/driver")"); break; }
    done

    printf '         negotiated: %s Mbps   USB spec reported by device: %s\n' "$DEV_SPEED" "${USBVER:-?}"
    printf '         upstream hub max: %s Mbps   fastest port on this machine: %s Mbps\n' "$UPSTREAM_MAX" "$SYS_MAX"
    printf '         path: %s\n' "$(for c in "${CHAIN[@]}"; do printf '%s(%s) <- ' "$(basename "$c")" "$(cat "$c/speed")"; done | sed 's/ <- $//')"

    if (( DEV_SPEED >= 10000 )); then
        ok "SuperSpeed+ 10 Gbps -- optimal for this drive"
    elif (( DEV_SPEED >= 5000 )); then
        ok "SuperSpeed 5 Gbps -- good (T7 can do 10 Gbps, but this is plenty)"
    else
        nope "running at $DEV_SPEED Mbps -- USB 2.0 speed"
        echo
        if (( UPSTREAM_MAX >= 5000 )); then
            printf '  \033[1;31m>>> LIKELY CAUSE: THE CABLE <<<\033[0m\n'
            note "The port you are plugged into offers $UPSTREAM_MAX Mbps, but the drive"
            note "only trained at $DEV_SPEED Mbps. A SuperSpeed path exists and was not used."
            note "That almost always means the cable has no SuperSpeed wires -- a charge-only"
            note "or USB 2.0 cable. Swap in the cable that shipped with the T7."
            note "Less likely: debris in the connector, or a damaged cable end."
        else
            printf '  \033[1;31m>>> LIKELY CAUSE: THE PORT OR HUB <<<\033[0m\n'
            note "Every hub between the drive and the host tops out at $UPSTREAM_MAX Mbps,"
            note "so this is a USB 2.0 port or a USB 2.0 path through a dock."
            if (( SYS_MAX >= 5000 )); then
                note "This machine does have a $SYS_MAX Mbps port available. Move the drive"
                note "to a port directly on the laptop and re-run this check."
            else
                note "No faster port was detected on this machine."
            fi
            note "The mount point will not change -- udisks mounts by UUID."
        fi
        echo
        note "Impact: ~40 MB/s instead of ~450-1000 MB/s. That is the difference"
        note "between roughly 8-14 hours and 2-4 hours for this backup."
    fi

    case $UDRIVER in
        uas)         ok "transport driver: uas (command queueing enabled)" ;;
        usb-storage) meh "transport driver: usb-storage (BOT, no queueing)"
                     note "Noticeably slower with millions of small files. Often caused by a"
                     note "usb-storage quirk entry or an enclosure that mis-reports UAS support." ;;
        *)           meh "transport driver: $UDRIVER" ;;
    esac
fi

# ------------------------------------------------------- I/O scheduler ---
hdr "5. I/O scheduler"

CUR_SCHED=$(sed -n 's/.*\[\(.*\)\].*/\1/p' "/sys/block/$DEV/queue/scheduler" 2>/dev/null)
NRREQ=$(cat "/sys/block/$DEV/queue/nr_requests" 2>/dev/null)
printf '         current: scheduler=%s nr_requests=%s\n' "$CUR_SCHED" "$NRREQ"
if [[ $CUR_SCHED == mq-deadline ]]; then
    ok "already mq-deadline"
elif [[ $CUR_SCHED == bfq ]]; then
    ok "bfq now; 04-backup-home.sh will switch to mq-deadline and revert on exit"
else
    note "04-backup-home.sh will set mq-deadline for the transfer and revert on exit"
fi
if sudo -n true 2>/dev/null; then
    ok "passwordless sudo available (tuning will apply silently)"
else
    note "sudo will prompt once for the scheduler change (or use --no-tune)"
fi

# -------------------------------------------------------------- tooling ---
hdr "6. Tooling"
for c in rclone jq sqlite3 findmnt numfmt; do
    if command -v "$c" >/dev/null; then ok "$c: $(command -v "$c")"
    else nope "$c is missing (sudo dnf install $c)"; fi
done

if pgrep -f 'firefox|google-chrome|chromium|thunderbird' >/dev/null 2>&1; then
    meh "a browser or mail client is running"
    note "Quit them before the backup so SQLite databases copy consistently."
else
    ok "no browsers running"
fi

# ----------------------------------------------------------- speed test ---
if (( SPEED_TEST )); then
    hdr "7. Measured throughput"

    measure() {  # measure <bytes> <dd-args...>  -> echoes MB/s
        local bytes=$1; shift
        local t0 t1
        t0=$(date +%s.%N)
        dd "$@" bs=8M status=none 2>/dev/null || return 1
        t1=$(date +%s.%N)
        awk -v b="$bytes" -v t0="$t0" -v t1="$t1" \
            'BEGIN{d=t1-t0; if(d<=0){print 0}else{printf "%.0f", b/d/1048576}}'
    }

    BIG=$(find "$MNT" -xdev -type f -size +1G -print -quit 2>/dev/null || true)
    if [[ -n $BIG ]]; then
        note "reading 512 MiB from an existing file (no writes, cache bypassed)"
        if RMBPS=$(measure $((512*1024*1024)) if="$BIG" of=/dev/null count=64 iflag=direct) && [[ ${RMBPS:-0} -gt 0 ]]; then
            printf '         read: %s MB/s\n' "$RMBPS"
        else
            meh "read test failed (O_DIRECT unsupported?)"; RMBPS=0
        fi
    else
        meh "no file >=1 GiB on the drive to read from; skipping read test"
        note "Use --write-test to measure with a temporary file instead."
        RMBPS=0
    fi

    WMBPS=0
    if (( WRITE_TEST )); then
        TMPF="$MNT/.preflight-write-test.$$"
        trap 'rm -f "$TMPF" 2>/dev/null || true' EXIT
        note "writing 512 MiB to $TMPF (removed afterwards)"
        if WMBPS=$(measure $((512*1024*1024)) if=/dev/zero of="$TMPF" count=64 oflag=direct conv=fsync) && [[ ${WMBPS:-0} -gt 0 ]]; then
            printf '         write: %s MB/s\n' "$WMBPS"
        else
            meh "write test failed"; WMBPS=0
        fi
        rm -f "$TMPF" 2>/dev/null || true
        trap - EXIT
    fi

    BEST=$(( RMBPS > WMBPS ? RMBPS : WMBPS ))
    if (( BEST > 0 && ${DEV_SPEED:-0} > 0 )); then
        EXPECT=$(( DEV_SPEED * 100 / 1000 ))   # ~80% of line rate, in MB/s
        printf '         expected for a %s Mbps link: ~%s MB/s\n' "$DEV_SPEED" "$EXPECT"
        if (( BEST * 2 < EXPECT )); then
            meh "measured throughput is less than half of what this link should give"
            note "Suspect the cable, a failing enclosure, or thermal throttling."
        else
            ok "throughput is consistent with the negotiated link speed"
        fi
    fi

    if (( BEST > 0 )); then
        hdr "   Projected backup time"
        # Two independent costs: moving the bytes, and creating the files.
        # Whichever is larger governs; they overlap only partially, so the
        # smaller one is counted at half weight. A flat multiplier on the
        # bulk term alone is badly wrong once the link is fast, because then
        # metadata -- not bandwidth -- is the binding constraint.
        awk -v mbps="$BEST" -v gib="$NEED_GIB" -v files="$DEFAULT_NEED_FILES" \
            -v fps_lo=400 -v fps_hi=1500 'BEGIN{
            bulk    = gib*1024/mbps/3600;
            meta_lo = files/fps_hi/3600;
            meta_hi = files/fps_lo/3600;
            lo = (bulk>meta_lo? bulk+0.5*meta_lo : meta_lo+0.5*bulk);
            hi = (bulk>meta_hi? bulk+0.5*meta_hi : meta_hi+0.5*bulk);
            printf "         bulk data:      %.1f h   (%d GiB at %d MB/s)\n", bulk, gib, mbps;
            printf "         file metadata:  %.1f - %.1f h   (%d files at %d-%d files/s)\n", meta_lo, meta_hi, files, fps_hi, fps_lo;
            printf "         ESTIMATE:       %.1f - %.1f hours\n", lo, hi;
            if (meta_hi > bulk)
                printf "         Metadata-bound: a faster link would barely help.\n";
            else
                printf "         Bandwidth-bound: a faster link would help directly.\n";
        }'
    fi
fi

# --------------------------------------------------------------- verdict ---
hdr "Verdict"
if (( BLOCKERS > 0 )); then
    printf '  \033[31m%d blocker(s)\033[0m and %d warning(s). Fix the blockers before backing up.\n' "$BLOCKERS" "$WARNINGS"
    exit 2
elif (( WARNINGS > 0 )); then
    printf '  \033[33m%d warning(s)\033[0m, no blockers. Review them, then you are clear to run:\n' "$WARNINGS"
    printf '    ./04-backup-home.sh %s/laptop-$(date +%%Y-%%m-%%d) --dry-run\n' "$MNT"
    exit 1
else
    printf '  \033[32mAll checks passed.\033[0m Ready to run:\n'
    printf '    ./04-backup-home.sh %s/laptop-$(date +%%Y-%%m-%%d) --dry-run\n' "$MNT"
    exit 0
fi
