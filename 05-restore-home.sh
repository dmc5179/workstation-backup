#!/usr/bin/env bash
#
# 05-restore-home.sh -- resumable restore of a backup made by 04-backup-home.sh.
#
#   ./05-restore-home.sh /run/media/$USER/<DRIVE-UUID>/laptop-2026-10-19
#
# Re-run the same command to resume. Uses 'rclone copy', so it never deletes
# anything on the new machine; it overwrites files whose size/mtime differ.
#
set -Eeuo pipefail

PROG=${0##*/}
HERE=$(cd -- "$(dirname -- "$(readlink -f "$0")")" && pwd)
# shellcheck source=lib-common.sh
source "$HERE/lib-common.sh"

SRCDIR="" TARGET="${HOME%/}"
DRY_RUN=0 ASSUME_YES=0 NO_OVERWRITE=0 RELABEL=0 NO_TUNE=0 VERIFY=""
TRANSFERS="" CHECKERS=""

usage() {
    cat <<EOF
Usage: $PROG <backup-directory> [options]

  <backup-directory> is the directory you passed to 04-backup-home.sh -- the one
  containing home/ and meta/.

Options:
  --into DIR       Restore into DIR instead of \$HOME (useful for a staging run)
  --no-overwrite   Never replace a file that already exists on this machine
  --relabel        Run 'sudo restorecon -R' on the target afterwards (SELinux)
  --no-tune        Do not touch the source disk's I/O scheduler
  --transfers N    Parallel transfers (default: auto from link speed)
  --checkers N     Parallel checkers (default: auto)
  --verify         Verify by size after restoring
  --verify-hash    Verify with MD5 after restoring (very slow at this scale)
  -n, --dry-run    Show what would happen
  -y, --yes        Do not prompt
  -h, --help       This message
EOF
}

while (( $# )); do
    case $1 in
        --into)         TARGET=${2:?}; TARGET=${TARGET%/}; shift 2 ;;
        --no-overwrite) NO_OVERWRITE=1; shift ;;
        --relabel)      RELABEL=1; shift ;;
        --no-tune)      NO_TUNE=1; shift ;;
        --transfers)    TRANSFERS=${2:?}; shift 2 ;;
        --checkers)     CHECKERS=${2:?}; shift 2 ;;
        --verify)       VERIFY='fast'; shift ;;
        --verify-hash)  VERIFY='hash'; shift ;;
        -n|--dry-run)   DRY_RUN=1; shift ;;
        -y|--yes)       ASSUME_YES=1; shift ;;
        -h|--help)      usage; exit 0 ;;
        -*)             die "unknown option: $1" ;;
        *)              [[ -z $SRCDIR ]] || die "only one source may be given"; SRCDIR=${1%/}; shift ;;
    esac
done

[[ -n $SRCDIR ]] || { usage >&2; exit 2; }
command -v rclone >/dev/null || die "rclone is not installed (sudo dnf install rclone)"
[[ -d $SRCDIR/home ]] || die "$SRCDIR/home not found -- is this a 04-backup-home.sh directory?"
[[ -d $TARGET ]]      || die "target directory does not exist: $TARGET"
[[ -w $TARGET ]]      || die "target directory is not writable: $TARGET"

STAMP=$(date +%Y%m%d-%H%M%S)
LOG="$SRCDIR/meta/restore-$STAMP.log"
mkdir -p "$SRCDIR/meta" 2>/dev/null || LOG="/tmp/restore-$STAMP.log"

on_exit() { local rc=$?; io_restore; exit "$rc"; }
trap on_exit EXIT
trap 'echo; echo "Interrupted. Resume by re-running the same command."; exit 130' INT TERM

[[ -f $SRCDIR/meta/backup-info.txt ]] && { echo; cat "$SRCDIR/meta/backup-info.txt"; echo; }

# The USB drive is the READ side during a restore. mq-deadline already
# prioritises reads over writes, so the same tuning applies in this direction.
SRCDEV=$(resolve_queue_dev "$SRCDIR" || true)
if [[ -n $SRCDEV ]]; then
    read -r AUTO_T AUTO_C < <(concurrency_for "$SRCDEV")
    [[ -n $TRANSFERS ]] || TRANSFERS=$AUTO_T
    [[ -n $CHECKERS  ]] || CHECKERS=$AUTO_C
    (( NO_TUNE || DRY_RUN )) || io_tune "$SRCDEV"
fi
: "${TRANSFERS:=8}" "${CHECKERS:=16}"

if pgrep -f 'firefox|google-chrome|chromium|thunderbird' >/dev/null 2>&1; then
    warn "a browser is running. Quit it before restoring, or the running instance"
    warn "will overwrite your restored profile when it exits."
fi

cat <<EOF
  Restore from: $SRCDIR/home
  Restore into: $TARGET
  Overwrite:    $( ((NO_OVERWRITE)) && echo "no (skip existing files)" || echo "yes, when size/mtime differ" )
  Concurrency:  --transfers $TRANSFERS --checkers $CHECKERS
  Log:          $LOG

EOF

if (( ! ASSUME_YES && ! DRY_RUN )); then
    [[ -t 0 ]] || die "not a terminal; pass --yes to run unattended"
    read -r -p "Proceed? [y/N] " a; [[ $a == [Yy]* ]] || exit 1
fi

OPTS=(
    --links --metadata --create-empty-src-dirs
    --transfers "$TRANSFERS" --checkers "$CHECKERS"
    --retries 3 --low-level-retries 10
    --log-file "$LOG" --log-level INFO
    --stats 30s --stats-one-line
)
[[ -t 1 ]]         && OPTS+=( --progress )
(( DRY_RUN ))      && OPTS+=( --dry-run )
(( NO_OVERWRITE )) && OPTS+=( --ignore-existing )

info "Starting rclone copy ..."
rclone copy "$SRCDIR/home" "$TARGET" "${OPTS[@]}"

# ---------------------------------------------- repair sensitive permissions --
# rclone --metadata restores modes on a POSIX filesystem, but this is cheap
# insurance: ssh and gpg refuse to work with loose permissions.
harden() {
    local d
    if [[ -d $TARGET/.ssh ]]; then
        chmod 700 "$TARGET/.ssh"
        find "$TARGET/.ssh" -type f -exec chmod 600 {} +
        find "$TARGET/.ssh" -type f \( -name '*.pub' -o -name 'known_hosts*' \) -exec chmod 644 {} +
        info "fixed permissions on .ssh"
    fi
    for d in .gnupg .local/share/keyrings .aws .password-store .docker; do
        [[ -d $TARGET/$d ]] || continue
        find "$TARGET/$d" -type d -exec chmod 700 {} +
        find "$TARGET/$d" -type f -exec chmod 600 {} +
        info "fixed permissions on $d"
    done
    [[ -f $TARGET/.kube/config ]] && chmod 600 "$TARGET/.kube/config"
    [[ -f $TARGET/.netrc  ]]      && chmod 600 "$TARGET/.netrc"
    [[ -f $TARGET/.pgpass ]]      && chmod 600 "$TARGET/.pgpass"
    return 0
}
(( DRY_RUN )) || harden

if (( RELABEL && ! DRY_RUN )); then
    info "Relabelling SELinux contexts (needs sudo; takes a while over ~4M files)..."
    sudo restorecon -R "$TARGET" || warn "restorecon failed"
elif (( ! DRY_RUN )); then
    echo
    info "SELinux: run this once, or sshd and systemd user units may be denied:"
    echo "    sudo restorecon -R \"$TARGET\""
fi

if [[ -n $VERIFY && $DRY_RUN -eq 0 ]]; then
    info "Verifying ($VERIFY)..."
    CHK=( check "$SRCDIR/home" "$TARGET" --one-way --links --checkers "$CHECKERS"
          --log-file "${LOG%.log}-verify.log" --log-level INFO
          --missing-on-dst "${LOG%.log}-missing.txt"
          --differ         "${LOG%.log}-differ.txt" )
    [[ $VERIFY == fast ]] && CHK+=( --size-only )
    if rclone "${CHK[@]}"; then info "Verify PASSED"
    else warn "Verify reported differences; see ${LOG%.log}-*.txt"; fi
fi

cat <<'POST'

Post-restore checklist
----------------------
 1. Log out and back in (or reboot) so the restored shell and desktop config load.
 2. Install the browsers BEFORE launching them, then start each one once:
      Firefox -- profiles.ini uses relative paths, so profiles are found
                 automatically. If not: firefox --ProfileManager
      Chrome  -- bookmarks are plaintext JSON in each profile's 'Bookmarks'
                 file and restore cleanly. You have three profiles:
                 Default, "Profile 3", and Guest Profile.
 3. Saved browser passwords: Chrome encrypts them against a key in the GNOME
    keyring. They only decrypt if ~/.local/share/keyrings was restored AND your
    login password is the same. Otherwise re-sign-in and let sync repopulate.
    Firefox passwords are key4.db + logins.json and restore as a pair.
 4. Plain-text bookmark dumps are in the backup at meta/bookmarks/*.tsv if
    anything goes wrong with the profile restore.
 5. Containers were deliberately NOT backed up. Re-pull from
    meta/packages/extras/podman-images.txt.
 6. Spot-check: ssh -T git@github.com ; gpg --list-secret-keys ; aws sts get-caller-identity
POST

info "Done. Log: $LOG"
