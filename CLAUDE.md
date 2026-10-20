# Working in this repo

Resumable file-copy migration tooling for a Fedora workstation, built around
rclone. Scripts are numbered in execution order: `01`–`04` run on the old
machine, `05`–`07` on the new one. `06` and `07` are *generated* at capture
time by `02` and `03`. `lib-common.sh` is sourced, never executed, so it has
no number.

## Conventions

- `set -Eeuo pipefail` in every script; `shellcheck -S warning ./*.sh` must
  pass clean before committing.
- User-facing output goes through `info` / `warn` / `die` in `lib-common.sh`.
- The filter list lives in a heredoc inside `04-backup-home.sh` and is
  written to `$DEST/meta/filters.txt` **only if that file is absent**. After
  changing the heredoc you must delete the copy on the drive, or the stale
  one keeps being used. That has silently invalidated test results before.

## Safety rules

- **Never put `rm -rf` in a diagnostic or verification command.** A stray one
  aimed at `$DEST` fired an hour later, after its command had been abandoned,
  and deleted `meta/` out from under a live backup.
- **Kill background jobs you abandon.** A slow check left running will
  execute its tail end long after you have moved on.
- Prefer read-only probes (`rclone lsf`, `find`, `stat`) over anything that
  writes. `--dry-run` writes no data but still creates `$DEST/{home,meta}`
  and the filter file.
- Don't blanket `chown -R` across `$HOME`: `~/.local/share/containers` is
  rootless podman's UID-mapped overlay store and chowning it corrupts it.

## rclone filter semantics — all of these cost real debugging time

1. **`- dir/**` excludes contents; `- dir/` excludes the directory.** Only
   the trailing-slash form prunes the walk. With `/**`, rclone still descends
   to evaluate the pattern and trips over unreadable subdirectories.
2. **Rule position matters, not just rule form.** Identical prune rules
   placed after the `+` protected block did not prune; moved to the top of
   the file they did. Put hard prunes first.
3. **Patterns without a leading `/` match at any depth.** `+ .aws/**`
   resurrected AWS SDK test fixtures buried in the Go module cache, past a
   later `- go/pkg/mod/**`. Protected rules are anchored (`+ /.ssh/**`) for
   this reason; prune rules are deliberately unanchored so they catch every
   GOPATH.
4. **`--exclude` and `--include` do not honour command-line order.** Mixing
   them silently ignored the excludes — 29,119 cache files slipped through.
   Use `--filter '- ...'` / `--filter '+ ...'`, which is ordered.
5. **Metadata filters select objects, not keys.** `--metadata-filter '- uid=*'`
   drops the whole file rather than the uid field. There is no way to keep
   `mode` while discarding `uid`/`gid`.

## `--metadata` failure modes

Both of these abort the file copy, so the file is **missing** from the backup:

- **Root-owned files.** Preserving `uid:gid` needs `chown`, which a non-root
  user cannot do to root. Cost 942 files on one run. Check with
  `find "$HOME" -xdev ! -user "$USER"` before a long run.
- **Read-only directories** (`dr-xr-xr-x`, e.g. Go module caches). rclone
  recreates the mode on the destination and then cannot write inside. Only
  reproduces at high concurrency on deep trees — `--transfers 4` on a shallow
  tree will not show it.

Dropping `--metadata` is not an acceptable workaround: it loses the
executable bit on every script.

## Shell gotchas hit here

- A function whose stdout is parsed must send human-readable messages to
  **stderr**. `concurrency_for` printed one `info` line to stdout and the
  caller read it as `--transfers`, so rclone died before opening its log.
  `warn` already goes to stderr; `info` does not.
- `(( cond )) && cmd` returns non-zero when the condition is false, which
  terminates the script under `set -e`. Use `if (( cond )); then cmd; fi`.
- `df --output=` field names vary across coreutils (`ifree` vs `iavail`).
  Combined with `pipefail`, an unknown field killed a script *with exit 0*.
  Parse `df -i` with awk instead.
- `df -i` and `--output` are mutually exclusive, as are `findmnt -r` and
  `--list`.
- `pkill -f 'rclone lsf'` matches your own shell's command string. So does
  `pgrep -af 'rclone copy'` — it reported a phantom running backup.

## Testing discipline

The recurring failure mode in this repo was **believing a synthetic test over
the real tree**. Filter behaviour changed with the real 113-line filter file
and the real directory layout in ways a 4-line test did not reproduce. Twice
a fix was reported as working when it was not.

- Verify filter changes against a replica built from the *actual* paths
  involved, or against `$HOME` itself.
- Prefer deterministic checks over timing-sensitive ones. `rclone lsf
  --dirs-only --max-depth 3 | grep <path>` answers "is this pruned" in
  seconds; counting errors during a timed scan is noisy, because rclone walks
  concurrently and error counts vary run to run.
- `rclone lsf` only *lists*, so it surfaces unreadable **directories**.
  `rclone copy` also *opens* files, so it additionally surfaces unreadable
  **files**. A clean `lsf` does not imply a clean `copy`.
- Success signal for a run is `backup_finished` in `meta/backup-info.txt`.
  Its absence is how a failed run was caught; rclone's own tail can look
  plausible while the overall run failed.

## Interpreting `--verify`

Discrepancies from running applications are expected, not failures. The
reference run produced 48: 44 Chrome (IndexedDB, Sessions, LevelDB logs), 2
claude-mem, 2 GNOME `dconf`/notifications. Judge a verify by whether
irreplaceable paths appear — `Bookmarks`, `.ssh`, `.gnupg`, `.aws`, `.kube`,
keyrings, `Documents/`, `workspace/`, `places.sqlite`, `logins.json`,
`key4.db` — not by the raw count.
