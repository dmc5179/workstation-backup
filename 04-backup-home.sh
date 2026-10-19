#!/usr/bin/env bash
#
# 04-backup-home.sh -- resumable backup of $HOME to a directory on an external drive.
#
#   ./04-backup-home.sh /run/media/$USER/<DRIVE-UUID>/laptop-2026-10-19
#
# Interrupted? Re-run the EXACT same command. rclone skips anything already
# transferred (matching size + mtime) and picks up where it left off. No state
# file is involved, so Ctrl-C is always safe.
#
set -Eeuo pipefail

PROG=${0##*/}
HERE=$(cd -- "$(dirname -- "$(readlink -f "$0")")" && pwd)
# shellcheck source=lib-common.sh
source "$HERE/lib-common.sh"

SRC="${HOME%/}"
DEST=""
FILTER_OVERRIDE=""
DRY_RUN=0 ASSUME_YES=0 SKIP_SIZE=0 MIRROR=0 NO_TUNE=0 VERIFY=""
TRANSFERS="" CHECKERS=""
# NOTICE keeps the log to stats + problems only. At INFO, rclone writes one
# line per file: ~3.9M lines and ~200 MB for this data set, which also buries
# the periodic stats and makes 'tail -f' useless.
LOG_LEVEL=NOTICE

usage() {
    cat <<EOF
Usage: $PROG <destination-directory> [options]

Copies all of \$HOME -- including hidden files, .ssh, .gnupg, keyrings and
browser profiles -- into <destination-directory>/home/, with a metadata and
bookmark sidecar in <destination-directory>/meta/.

Options:
  --filters FILE   Use FILE instead of the filter list in meta/filters.txt
  --mirror         Use 'rclone sync' (deletes extras at dest) instead of 'copy'
  --transfers N    Parallel file transfers (default: auto from link speed)
  --checkers N     Parallel checkers (default: auto)
  --no-tune        Do not touch the destination disk's I/O scheduler
  --log-info       Log every file copied (~200 MB of log here; default is a
                   compact log of progress stats, warnings and errors only)
  --verify         After copying, verify dest against source by size
  --verify-hash    After copying, verify with MD5 of every file (very slow here)
  --skip-size      Skip the pre-flight free-space estimate
  -n, --dry-run    Show what would happen, transfer nothing
  -y, --yes        Do not prompt for confirmation
  -h, --help       This message
EOF
}

while (( $# )); do
    case $1 in
        --filters)     FILTER_OVERRIDE=${2:?}; shift 2 ;;
        --mirror)      MIRROR=1; shift ;;
        --transfers)   TRANSFERS=${2:?}; shift 2 ;;
        --checkers)    CHECKERS=${2:?}; shift 2 ;;
        --no-tune)     NO_TUNE=1; shift ;;
        --log-info)    LOG_LEVEL=INFO; shift ;;
        --verify)      VERIFY='fast'; shift ;;
        --verify-hash) VERIFY='hash'; shift ;;
        --skip-size)   SKIP_SIZE=1; shift ;;
        -n|--dry-run)  DRY_RUN=1; shift ;;
        -y|--yes)      ASSUME_YES=1; shift ;;
        -h|--help)     usage; exit 0 ;;
        -*)            die "unknown option: $1" ;;
        *)             [[ -z $DEST ]] || die "only one destination may be given"; DEST=${1%/}; shift ;;
    esac
done

[[ -n $DEST ]] || { usage >&2; exit 2; }
command -v rclone >/dev/null || die "rclone is not installed (sudo dnf install rclone)"

mkdir -p "$DEST/home" "$DEST/meta"
[[ -w $DEST ]] || die "destination is not writable: $DEST"

STAMP=$(date +%Y%m%d-%H%M%S)
LOG="$DEST/meta/backup-$STAMP.log"
FILTER_FILE="$DEST/meta/filters.txt"

on_exit() { local rc=$?; io_restore; exit "$rc"; }
trap on_exit EXIT
trap 'echo; echo "Interrupted. Resume by re-running the same command."; exit 130' INT TERM

# --------------------------------------------------------------- filters ---
if [[ -n $FILTER_OVERRIDE ]]; then
    cp -f "$FILTER_OVERRIDE" "$FILTER_FILE"
elif [[ ! -s $FILTER_FILE ]]; then
    cat >"$FILTER_FILE" <<'FILTERS'
# rclone filter rules for the home-directory backup. FIRST MATCH WINS.
# '-' excludes, '+' includes. Patterns are relative to $HOME.
# Edit this file and re-run the backup to change what gets copied.

# --- Hard directory prunes ---------------------------------------------------
# A trailing-slash rule excludes the DIRECTORY ITSELF, which stops rclone
# descending into it. The '/**' form further down only excludes the contents,
# so rclone still walks in and trips over unreadable subdirectories. That is
# the entire source of the "permission denied" noise on this machine:
#   .local/share/containers  rootless podman overlay, UID-mapped and unreadable
#                            (36 unreadable dirs, 1,849 unreadable files)
#   .local/share/waydroid    data dir owned by another user
#   sosreport-*/proc, /sys   captured kernel pseudo-files: write-only stubs
#                            (mode --w-------), 577 of them, zero value
- .local/share/containers/
- .local/share/waydroid/
- **/sosreport-*/proc/
- **/sosreport-*/sys/

#
# Measured on 2026-10-19: $HOME is 598G across ~4.5M files. These rules bring
# that down to 401 GiB / 3,927,573 files.

# --- Always keep these, whatever the rules below say -------------------------
+ /.ssh/**
+ /.gnupg/**
+ /.pki/**
+ /.password-store/**
+ /.local/share/keyrings/**
+ /.aws/**
+ /.kube/**
+ /.config/gcloud/**
+ /.mozilla/firefox/*/places.sqlite
+ /.mozilla/firefox/*/bookmarkbackups/**

# Claude CLI: settings, MCP config, agents, skills, plugins and session
# history. These MUST come before the **/node_modules/** rule below --
# ~/.claude/plugins/.../claude-mem/node_modules is 464 MB of plugin runtime
# that the generic rule would otherwise strip, breaking the plugin on restore.
# ~/.local/bin/claude is a symlink into .local/share/claude/versions, so that
# directory has to come across too or the CLI is a dangling link.
+ /.claude/**
+ /.claude.json
+ /.claude.json.backup
+ /.config/claude-personal/**
+ /.local/share/claude/**
+ /.local/bin/**

# --- Podman container storage: 126G, and actively harmful to restore. --------
# Overlay layer metadata is bound to the local storage driver and UID mapping;
# copying it to a new machine produces a broken store rather than working
# images. The image LIST is captured by 02-capture-packages.sh instead; re-pull
# on the new laptop. 'podman save' anything built locally that is not in a
# registry BEFORE wiping this machine.
- .local/share/containers/**
- .local/share/flatpak/**

# --- Caches and other regenerable junk ---------------------------------------
- .cache/**
- .thumbnails/**
- .local/share/Trash/**
- .local/share/gvfs-metadata/**
- .local/share/baloo/**
- .local/share/tracker*/**
- .var/app/*/cache/**
- .mozilla/firefox/*/cache2/**
- .mozilla/firefox/*/storage/default/*/cache/**

# --- Chrome/Chromium: 11G, ~8G of it regenerable web-app cache ---------------
# Bookmarks live in a small per-profile 'Bookmarks' JSON file and are NOT
# affected by any of these rules.
- .config/*/*/Service Worker/**
- .var/app/*/config/*/*/Service Worker/**
- .config/*/Cache/**
- .config/*/Code Cache/**
- .config/*/GPUCache/**
- .config/*/CachedData/**
- .config/*/CachedExtensionVSIXs/**
- .config/*/*/Cache/**
- .config/*/*/Code Cache/**
- .config/*/*/GPUCache/**
- .config/google-chrome/component_crx_cache/**
- .config/google-chrome/*/optimization_guide_prediction_model_downloads/**
# "File System" is the FileSystem API store: ~4G, mostly cache, but a few web
# apps keep real data there. Uncomment to reclaim it.
# - .config/*/*/File System/**

# --- Package-manager / toolchain caches (all re-downloadable) ----------------
- .npm/_cacache/**
- .cargo/registry/**
- .cargo/git/**
- .rustup/toolchains/**
- .gradle/caches/**
- .m2/repository/**
- go/pkg/mod/**
- .nuget/**

# --- Build artefacts. Comment out any you want copied verbatim. --------------
- **/node_modules/**
- **/__pycache__/**
- **/.venv/**
- **/.tox/**

# --- Large, reinstallable, or non-portable ------------------------------------
- .local/share/Steam/**
- .steam/**
- snap/**
- .vagrant.d/boxes/**

# --- Never copyable ----------------------------------------------------------
- .gvfs/**
- .dbus/**
- lost+found/**
- *.sock
FILTERS
    info "Wrote the default filter list to $FILTER_FILE"
    info "Review it before the real run; re-running regenerates nothing."
fi

# -------------------------------------------------------------- preflight ---
FSTYPE=$(findmnt -no FSTYPE --target "$DEST" 2>/dev/null || echo unknown)
case $FSTYPE in
    ext2|ext3|ext4|xfs|btrfs|f2fs|zfs) info "destination filesystem: $FSTYPE (full POSIX metadata)" ;;
    *) warn "destination filesystem is '$FSTYPE'. exFAT/NTFS/FAT cannot store UNIX"
       warn "permissions, ownership or symlinks, and reject filenames containing : ? * \" < > |."
       warn "Your .ssh keys would restore world-readable. Use ext4/xfs/btrfs if at all possible." ;;
esac

DESTDEV=$(resolve_queue_dev "$DEST" || true)
if [[ -n $DESTDEV ]]; then
    read -r AUTO_T AUTO_C < <(concurrency_for "$DESTDEV")
    [[ -n $TRANSFERS ]] || TRANSFERS=$AUTO_T
    [[ -n $CHECKERS  ]] || CHECKERS=$AUTO_C
    (( NO_TUNE || DRY_RUN )) || io_tune "$DESTDEV"
else
    warn "could not resolve the destination block device; using conservative defaults"
fi
: "${TRANSFERS:=8}" "${CHECKERS:=16}"
# concurrency_for's stdout is parsed, so anything stray printed there would be
# passed to rclone as a flag value and fail obscurely. Catch it here instead.
[[ $TRANSFERS =~ ^[0-9]+$ ]] || { warn "non-numeric --transfers ('$TRANSFERS'); using 8";  TRANSFERS=8; }
[[ $CHECKERS  =~ ^[0-9]+$ ]] || { warn "non-numeric --checkers ('$CHECKERS'); using 16";   CHECKERS=16; }

if pgrep -f 'firefox|google-chrome|chromium|thunderbird' >/dev/null 2>&1; then
    warn "a browser or mail client appears to be running."
    warn "Its SQLite databases (bookmarks, history, mail index) may be copied in an"
    warn "inconsistent state. Quit them completely before the real run."
fi

if (( ! SKIP_SIZE )); then
    info "Measuring source size (walks ~4M files; takes a few minutes)..."
    NEED=$(rclone size --json --links --filter-from "$FILTER_FILE" "$SRC" 2>/dev/null | jq -r '.bytes // 0')
    AVAIL=$(df -B1 "$DEST" | awk 'NR==2{print $4}')
    printf '    to copy:      %s\n    free at dest: %s\n' \
        "$(numfmt --to=iec "$NEED")" "$(numfmt --to=iec "$AVAIL")"
    (( NEED < AVAIL )) || warn "destination may not have enough free space!"
fi

cat <<EOF

  Source:      $SRC
  Destination: $DEST/home
  Filters:     $FILTER_FILE
  Mode:        $( ((MIRROR)) && echo "sync (mirror, deletes extras at dest)" || echo "copy (never deletes)" )
  Concurrency: --transfers $TRANSFERS --checkers $CHECKERS
  Log:         $LOG

  Live progress prints here. To watch from another terminal, or after
  detaching from tmux:
      tail -f $LOG

EOF

if (( ! ASSUME_YES && ! DRY_RUN )); then
    [[ -t 0 ]] || die "not a terminal; pass --yes to run unattended"
    read -r -p "Proceed? [y/N] " a; [[ $a == [Yy]* ]] || exit 1
fi

# ------------------------------------------------ browser bookmark sidecar ---
# Belt and braces: the full profiles are copied by the main sync, but these
# standalone snapshots are taken through SQLite's backup API (consistent even
# on a live database) and include a plain-text TSV you can read anywhere.
snapshot_bookmarks() {
    local out="$DEST/meta/bookmarks" root db prof name d latest bm n
    mkdir -p "$out"

    for root in "$HOME/.mozilla/firefox" \
                "$HOME/.var/app/org.mozilla.firefox/.mozilla/firefox" \
                "$HOME/.librewolf"; do
        [[ -d $root ]] || continue
        while IFS= read -r -d '' db; do
            prof=$(basename "$(dirname "$db")"); name="firefox-${prof// /_}"
            if sqlite3 "$db" ".timeout 5000" ".backup '$out/$name-places.sqlite'" 2>/dev/null; then
                sqlite3 -separator $'\t' "$out/$name-places.sqlite" \
                    "SELECT COALESCE(b.title,''), p.url
                       FROM moz_bookmarks b JOIN moz_places p ON b.fk = p.id
                      WHERE b.type = 1 ORDER BY b.id;" >"$out/$name-bookmarks.tsv" 2>/dev/null || true
                n=$(wc -l <"$out/$name-bookmarks.tsv" 2>/dev/null || echo 0)
                info "  firefox profile $prof: $n bookmarks"
            else
                warn "  could not snapshot $db (is Firefox running?)"
            fi
        done < <(find "$root" -maxdepth 2 -name places.sqlite -print0 2>/dev/null)

        while IFS= read -r -d '' d; do
            latest=$(ls -1t "$d"/*.jsonlz4 2>/dev/null | head -1) || true
            [[ -n ${latest:-} ]] && cp -p "$latest" "$out/firefox-$(basename "$(dirname "$d")")-$(basename "$latest")"
        done < <(find "$root" -maxdepth 2 -type d -name bookmarkbackups -print0 2>/dev/null)
    done

    for root in "$HOME/.config/google-chrome" "$HOME/.config/chromium" \
                "$HOME/.config/microsoft-edge" "$HOME/.config/vivaldi" \
                "$HOME/.config/BraveSoftware/Brave-Browser" \
                "$HOME/.var/app/com.google.Chrome/config/google-chrome" \
                "$HOME/.var/app/org.chromium.Chromium/config/chromium"; do
        [[ -d $root ]] || continue
        while IFS= read -r -d '' bm; do
            prof=$(basename "$(dirname "$bm")"); name="$(basename "$root")-${prof// /_}"
            cp -p "$bm" "$out/$name-Bookmarks.json"
            jq -r '.. | objects | select(.type? == "url") | [.name, .url] | @tsv' \
                "$bm" >"$out/$name-bookmarks.tsv" 2>/dev/null || true
            n=$(wc -l <"$out/$name-bookmarks.tsv" 2>/dev/null || echo 0)
            info "  $name: $n bookmarks"
        done < <(find "$root" -maxdepth 2 -name Bookmarks -type f -print0 2>/dev/null)
    done
}

if (( ! DRY_RUN )); then
    info "Snapshotting browser bookmarks into $DEST/meta/bookmarks/"
    snapshot_bookmarks
fi

# ----------------------------------------------------------------- manifest --
if (( ! DRY_RUN )); then
    { echo "backup_started: $(date -Is)"
      echo "hostname:       $(hostname)"
      echo "user:           $USER  uid=$(id -u) gid=$(id -g)"
      echo "source:         $SRC"
      echo "source_fstype:  $(findmnt -no FSTYPE --target "$SRC")"
      echo "os:             $(. /etc/os-release && echo "$PRETTY_NAME")"
      echo "kernel:         $(uname -r)"
      echo "rclone:         $(rclone version | head -1)"
      echo "dest_fstype:    $FSTYPE"
      echo "dest_device:    ${DESTDEV:-unknown}"
      echo "usb_speed_mbps: $(usb_speed_of "${DESTDEV:-none}" 2>/dev/null || echo n/a)"
      echo "concurrency:    transfers=$TRANSFERS checkers=$CHECKERS"
    } >"$DEST/meta/backup-info.txt"
fi

# --------------------------------------------------------------------- copy --
OPTS=(
    --links                   # store symlinks as .rclonelink so they round-trip
    --metadata                # preserve mode, uid/gid, atime/mtime
    --create-empty-src-dirs
    --local-no-check-updated  # do not abort on files that change mid-copy
    --transfers "$TRANSFERS"
    --checkers  "$CHECKERS"
    --retries 3
    --low-level-retries 10
    --filter-from "$FILTER_FILE"
    --log-file "$LOG"
    --log-level "$LOG_LEVEL"
    --stats 30s
    --stats-one-line
    --stats-log-level NOTICE   # stats still reach the log when LOG_LEVEL=NOTICE
)
[[ -t 1 ]]    && OPTS+=( --progress )
(( DRY_RUN )) && OPTS+=( --dry-run )

VERB=copy; (( MIRROR )) && VERB=sync

info "Starting rclone $VERB ..."
rclone "$VERB" "$SRC" "$DEST/home" "${OPTS[@]}"

# ------------------------------------------------------------------- verify --
if [[ -n $VERIFY && $DRY_RUN -eq 0 ]]; then
    info "Verifying ($VERIFY)..."
    CHK=( check "$SRC" "$DEST/home" --one-way --links --filter-from "$FILTER_FILE"
          --checkers "$CHECKERS"
          --log-file "$DEST/meta/verify-$STAMP.log" --log-level INFO
          --missing-on-dst "$DEST/meta/verify-$STAMP-missing.txt"
          --differ          "$DEST/meta/verify-$STAMP-differ.txt" )
    [[ $VERIFY == fast ]] && CHK+=( --size-only )
    if rclone "${CHK[@]}"; then
        info "Verify PASSED"
    else
        warn "Verify reported differences; see $DEST/meta/verify-$STAMP-*.txt"
    fi
fi

(( DRY_RUN )) || echo "backup_finished: $(date -Is)" >>"$DEST/meta/backup-info.txt"
info "Done. Log: $LOG"
