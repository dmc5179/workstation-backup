#!/usr/bin/env bash
# lib-common.sh — shared helpers for 04-backup-home.sh and 05-restore-home.sh.
# Sourced, not executed.

die()  { printf '%s: error: %s\n'   "${PROG:-$0}" "$*" >&2; exit 1; }
warn() { printf '%s: WARNING: %s\n' "${PROG:-$0}" "$*" >&2; }
info() { printf '==> %s\n' "$*"; }

# ---------------------------------------------------------------------------
# resolve_queue_dev PATH_OR_DEV
#   Walk up from a path or device to the whole-disk kernel device that owns a
#   /sys/block/<dev>/queue directory. Handles partitions and dm/LUKS stacks.
#   Resolves at run time on purpose: the T7 may enumerate as sdb or sdc when
#   plugged into a different port.
# ---------------------------------------------------------------------------
#   Walks sysfs rather than 'lsblk -o PKNAME': lsblk reports no PKNAME at all
#   for device-mapper nodes, and reports a partition's child instead of its
#   parent when the partition is itself a LUKS holder. sysfs is unambiguous.
resolve_queue_dev() {
    local in=$1 devpath dev parent guard=0
    if [[ -b $in ]]; then
        devpath=$in
    else
        devpath=$(findmnt -no SOURCE --target "$in" 2>/dev/null) || return 1
        devpath=${devpath%%\[*}            # strip btrfs "[/subvol]" suffix
        [[ -b $devpath ]] || return 1      # tmpfs, nfs, overlay: no block dev
    fi
    dev=$(basename "$(readlink -f "$devpath")")   # /dev/mapper/luks-x -> dm-0

    while (( ++guard <= 10 )); do
        [[ -e /sys/class/block/$dev ]] || return 1
        # dm / md stacks: descend into the first backing device.
        parent=$(ls -1 "/sys/class/block/$dev/slaves" 2>/dev/null | head -1)
        if [[ -n $parent ]]; then dev=$parent; continue; fi
        # A partition's sysfs parent directory is its whole disk.
        if [[ -f /sys/class/block/$dev/partition ]]; then
            dev=$(basename "$(dirname "$(readlink -f "/sys/class/block/$dev")")"); continue
        fi
        break
    done

    [[ -d /sys/block/$dev/queue ]] || return 1
    printf '%s\n' "$dev"
}

# ---------------------------------------------------------------------------
# usb_speed_of KERNEL_DEV  ->  negotiated link speed in Mbps, or nothing.
#   Climbs the sysfs tree to the nearest USB device node carrying a 'speed'.
# ---------------------------------------------------------------------------
usb_speed_of() {
    local p
    p=$(readlink -f "/sys/block/$1" 2>/dev/null) || return 1
    while [[ -n $p && $p != / ]]; do
        [[ -f $p/speed ]] && { cat "$p/speed"; return 0; }
        p=$(dirname "$p")
    done
    return 1
}

# ---------------------------------------------------------------------------
# I/O scheduler tuning, with automatic restore of the original values.
#
#   The T7 lands on bfq by default (Fedora's udev rule for single-queue
#   devices). bfq optimises interactive fairness and throttles single-stream
#   bulk transfer. mq-deadline is the better fit in BOTH directions: it
#   batches sequential writes for the backup, and already prioritises reads
#   (500ms expiry vs 5s for writes) for the restore.
#
#   The internal NVMe is deliberately left alone -- 'none' with 12 hardware
#   queues is already correct for it.
#
#   Expect a few percent, not a transformation. The real limits are the USB
#   link rate and per-file metadata overhead.
# ---------------------------------------------------------------------------
IO_TUNED_DEV="" IO_SAVED_SCHED="" IO_SAVED_NRREQ=""
IO_WANT_SCHED=${IO_WANT_SCHED:-mq-deadline}
IO_WANT_NRREQ=${IO_WANT_NRREQ:-256}

_sched_current() { sed -n 's/.*\[\(.*\)\].*/\1/p' "/sys/block/$1/queue/scheduler" 2>/dev/null; }
_sched_has()     { grep -qw -- "$2" "/sys/block/$1/queue/scheduler" 2>/dev/null; }

io_tune() {
    local dev=$1 cur
    [[ -n $dev && -d /sys/block/$dev/queue ]] || { warn "io_tune: no queue for '$dev'"; return 0; }

    cur=$(_sched_current "$dev")
    if [[ $cur == "$IO_WANT_SCHED" ]]; then
        info "I/O scheduler on $dev is already $cur; leaving it alone"
        return 0
    fi
    if ! _sched_has "$dev" "$IO_WANT_SCHED"; then
        warn "$dev does not offer $IO_WANT_SCHED (has: $(cat /sys/block/$dev/queue/scheduler)); skipping"
        return 0
    fi
    if ! sudo -n true 2>/dev/null; then
        if [[ -t 0 ]]; then
            info "I/O tuning on /dev/$dev needs sudo (it is reverted when this script exits)"
            sudo -v || { warn "no sudo; skipping I/O tuning"; return 0; }
        else
            warn "no cached sudo credentials; skipping I/O tuning"
            return 0
        fi
    fi

    IO_SAVED_SCHED=$cur
    IO_SAVED_NRREQ=$(cat "/sys/block/$dev/queue/nr_requests" 2>/dev/null)
    IO_TUNED_DEV=$dev

    # Order matters: changing the scheduler resets nr_requests.
    printf '%s\n' "$IO_WANT_SCHED" | sudo tee "/sys/block/$dev/queue/scheduler"   >/dev/null 2>&1 || true
    printf '%s\n' "$IO_WANT_NRREQ" | sudo tee "/sys/block/$dev/queue/nr_requests" >/dev/null 2>&1 || true

    info "I/O tuning on /dev/$dev: scheduler $IO_SAVED_SCHED -> $(_sched_current "$dev"), nr_requests $IO_SAVED_NRREQ -> $(cat /sys/block/$dev/queue/nr_requests 2>/dev/null)"
    info "   (original values are restored automatically when this script exits)"
}

io_restore() {
    [[ -n $IO_TUNED_DEV ]] || return 0
    local dev=$IO_TUNED_DEV
    IO_TUNED_DEV=""      # guard against re-entry from nested traps
    [[ -n $IO_SAVED_SCHED ]] && printf '%s\n' "$IO_SAVED_SCHED" | sudo -n tee "/sys/block/$dev/queue/scheduler"   >/dev/null 2>&1 || true
    [[ -n $IO_SAVED_NRREQ ]] && printf '%s\n' "$IO_SAVED_NRREQ" | sudo -n tee "/sys/block/$dev/queue/nr_requests" >/dev/null 2>&1 || true
    info "restored I/O settings on /dev/$dev (scheduler=$(_sched_current "$dev"), nr_requests=$(cat /sys/block/$dev/queue/nr_requests 2>/dev/null))"
}

# ---------------------------------------------------------------------------
# concurrency_for KERNEL_DEV
#   Echo "TRANSFERS CHECKERS" appropriate to the link, and warn loudly if the
#   drive has come up on a USB 2.0 port. This is the single biggest factor in
#   how long the transfer takes -- 20x between 480 Mbps and 10 Gbps.
# ---------------------------------------------------------------------------
concurrency_for() {
    local dev=$1 spd rota
    rota=$(cat "/sys/block/$dev/queue/rotational" 2>/dev/null || echo 1)
    if [[ $rota == 1 ]]; then
        warn "/dev/$dev reports rotational media; keeping concurrency low to avoid seek thrashing"
        echo "4 8"; return
    fi
    if spd=$(usb_speed_of "$dev"); then
        if (( spd >= 5000 )); then
            # MUST go to stderr: this function's stdout is parsed by the
            # caller. 'warn' is already stderr; plain 'info' is not.
            info "USB link: ${spd} Mbps - good" >&2
            echo "16 32"; return
        fi
        warn "========================================================================"
        warn " USB link negotiated at only ${spd} Mbps (USB 2.0)."
        warn " That caps you near 40 MB/s and will stretch this transfer to 8-14 hours"
        warn " instead of 2-4. The Samsung T7 is a 10 Gbps drive."
        warn ""
        warn " Unplug it from the Dell dock and connect it DIRECTLY to a laptop"
        warn " USB-C port using the T7's own cable, then re-run. The mount point"
        warn " does not change (udisks mounts by UUID)."
        warn "========================================================================"
        echo "8 16"; return
    fi
    echo "8 16"
}
