# Laptop migration: Fedora 43 → new Fedora 43/44 laptop

File-copy backup and restore of `$HOME`, plus a package inventory. No disk
imaging. Resumable at every stage.

## Scripts

Run them in numbered order. 01–04 on the **old** laptop, 05–07 on the **new**
one.

### On the old laptop

| Script | What it does |
|---|---|
| `01-preflight.sh` | Checks the drive, link speed, space and tooling. Read-only by default. |
| `02-capture-packages.sh` | Records RPMs, repos, flatpaks, container images. Read-only, no sudo. |
| `03-capture-claude.sh` | Inventories the Claude CLI + MCP servers. |
| `04-backup-home.sh` | Resumable `$HOME` → USB drive. **The long one.** |

### On the new laptop

| Script | Where it lives | What it does |
|---|---|---|
| `05-restore-home.sh` | this directory | Resumable USB drive → new `$HOME`. |
| `06-reinstall-packages.sh` | *generated* into `meta/packages/` by 02 | Re-adds repos and dnf packages. |
| `07-restore-claude.sh` | *generated* into `meta/claude/` by 03 | Pulls MCP images, pre-caches npm. |

`lib-common.sh` is shared helpers — sourced by the others, never run directly,
so it has no number.

Order matters on the new machine: 06 installs node and podman, which 07 needs.

## Measured facts for this machine

| | |
|---|---|
| `$HOME` total | 598 GB logical across ~4.5M files |
| Estimated after filters | 401 GiB / 3,927,573 files |
| **Actually written** | **693 GB** |
| Source | NVMe → LUKS → btrfs with `compress=zstd:1` |
| Target | Samsung PSSD T7, 931 GB, **XFS** |
| Biggest exclusion | `~/.local/share/containers` (126 GB podman store) |
| Link | USB 3.2 Gen 1, 5000 Mbps, measured 360–427 MB/s |

`df` reports less used than `du` because `/home` is zstd-compressed. rclone
copies *logical* bytes, so size the drive against the `du` figure, not `df`.

### Outcome of the 2026-10-20 run

Completed in 30 minutes as an incremental pass over an existing copy:
0 failed copies, 0 permission denied, 0 chown failures.

`--verify` reported 48 discrepancies, all live state from running processes
— 44 Chrome (IndexedDB, Sessions, LevelDB logs), 2 claude-mem, 2 GNOME
`dconf`/notifications. Zero hits for `Bookmarks`, `.ssh`, `.gnupg`, `.aws`,
`.kube`, keyrings, `Documents/`, `workspace/`, `places.sqlite`,
`logins.json` or `key4.db`. That is the expected shape of a verify run with
browsers open, not a problem.

---

## Steps

### 0. Before anything: save local-only container images

The 126 GB podman store is excluded on purpose — overlay metadata is bound to
the local storage driver and UID mapping and does not survive a move. Images
from registries can be re-pulled. Anything built locally cannot.

```bash
podman images --format '{{.Repository}}:{{.Tag}}' | grep '^localhost/'
podman save --format oci-archive -o /path/to/drive/myimage.tar localhost/myimage:tag
```

### 1. Preflight

```bash
./01-preflight.sh                # read-only checks
./01-preflight.sh --speed-test   # adds a throughput measurement (still read-only)
```

Exit codes: `0` clear, `1` warnings, `2` blockers. Fix blockers first.

> **Known blocker right now:** the T7 is connected through the Dell dock's USB
> 2.0 path and negotiates **480 Mbps** (measured 38 MB/s). Connect it directly
> to a laptop port before the real run — 4.5–9 hours becomes roughly 2–4. The
> mount point does not change; udisks mounts by UUID.

`01-preflight.sh` distinguishes the two causes of a slow link:

- **Port/hub** — every upstream hub is 480 Mbps. Move to a different port.
- **Cable** — the port offers 5000+ Mbps but the drive trained at 480 anyway.
  That means the cable has no SuperSpeed wires. Use the T7's own cable.

### 2. Capture the package inventory

```bash
DEST=/run/media/$USER/<DRIVE-UUID>/laptop-$(date +%Y-%m-%d)
./02-capture-packages.sh "$DEST/meta/packages"
```

Takes seconds, needs no sudo. Produces `pkglist-userinstalled.txt`,
`rpm-third-party.tsv`, a copy of `/etc/yum.repos.d` and GPG keys, flatpak and
podman image lists, and a generated `06-reinstall-packages.sh`.

### 2b. Capture the Claude CLI / MCP inventory

```bash
./03-capture-claude.sh "$DEST/meta/claude"
```

The *config* comes across in the main home backup. This captures the *runtime*
dependencies that do not: container images to pull, npm packages to pre-cache,
binaries that must exist on PATH, and which servers need interactive re-auth.

### 3. Browsers: quit them, or plan a second pass

Firefox, Chrome, Chromium and Thunderbird keep SQLite databases open, and
rclone copies a `.sqlite` and its `-wal` sidecar seconds apart across a
multi-hour run. The scripts warn but do not block.

Leaving them open is a reasonable trade — bookmarks are safe either way,
because `meta/bookmarks/` is snapshotted through SQLite's backup API, which
is consistent even against a live database. What smears is history,
cookies, open tabs and extension state.

If you want a consistent profile, quit the browsers at the end and run a
targeted second pass. It takes seconds:

```bash
rclone copy "$HOME" "$DEST/home" \
  --filter '- .mozilla/firefox/*/cache2/**' \
  --filter '- .config/*/*/Service Worker/**' \
  --filter '- .config/*/*/Cache/**' \
  --filter '- .config/*/*/Code Cache/**' \
  --filter '- .config/*/*/GPUCache/**' \
  --filter '- .config/*/*/File System/**' \
  --filter '+ .mozilla/**' \
  --filter '+ .config/google-chrome/**' \
  --filter '+ .config/chromium/**' \
  --filter '- *' \
  --links --metadata --local-no-check-updated \
  --transfers 8 --checkers 16 --progress
```

Use `--filter`, not `--exclude` plus `--include`: mixing those two does not
honour command-line order, and the excludes are silently ignored.

### 3b. Check file ownership first

`--metadata` preserves `uid:gid`. A non-root user cannot `chown` a file to
root, and rclone treats that failure as a **failed copy** — the file is
skipped. One sudo-cloned repo cost 942 files on the first attempt.

```bash
find "$HOME" -xdev \
  \( -path "$HOME/.local/share/containers" -o -path "$HOME/.cache" \) -prune -o \
  ! -user "$USER" -print 2>/dev/null | head
```

Fix by chowning the offenders to yourself, or exclude them. **Never** blanket
`chown -R` across `$HOME`: `~/.local/share/containers` holds rootless
podman's UID-mapped overlay store and chowning it corrupts the store.

### 4. Back up

```bash
./04-backup-home.sh "$DEST" --dry-run   # review what would be copied
./04-backup-home.sh "$DEST"             # real run
./04-backup-home.sh "$DEST" --verify -y # confirm afterwards
```

#### Stopping and resuming

**To stop:** press `Ctrl-C`. The script prints
`Interrupted. Resume by re-running the same command.`, restores the drive's
original I/O scheduler, and exits. There is no "pause" flag and none is
needed.

**Before powering off, unmount the drive cleanly:**

```bash
udisksctl unmount -b /dev/sda1      # or eject it in Files
```

Do not just pull the cable. The kernel log shows this drive has already needed
XFS log recovery once after an unclean disconnect.

**To resume:** re-run the identical command. rclone compares size and mtime
per file and transfers only what is missing. There is no state file, so
interrupting is always safe.

Verified by test (20,004 files, interrupted mid-transfer with a real SIGINT):

| | |
|---|---|
| Run 1 before interrupt | 16,315 files copied, 2 `.partial` temp files left |
| Run 2 (same command) | copied only the remaining 3,691, took 2 s |
| Final | 20,004 / 20,004, **0** leftover `.partial` files |
| `rclone check` | **0 differences, 20,004 matching files** |

A file in flight when you interrupt is restarted from scratch, not corrupted —
rclone writes to a `.partial` temp and renames on completion, and cleans up
orphans on the next run. On the real 3.9M-file set, expect a few minutes of
scanning before transfers resume, so avoid stopping and starting repeatedly.

**For a multi-hour run, use tmux** so closing the terminal (or SSH dropping)
does not kill the transfer:

```bash
tmux new -s backup
./04-backup-home.sh "$DEST"
# Ctrl-B then D to detach; 'tmux attach -t backup' to come back
```

Layout produced:

```
$DEST/
├── home/        full copy of $HOME
└── meta/
    ├── filters.txt          exclude rules actually used — edit and re-run
    ├── backup-info.txt      host, uid/gid, OS, rclone version, link speed
    ├── backup-*.log
    ├── bookmarks/           standalone bookmark snapshots (see below)
    └── packages/            output of 02-capture-packages.sh
```

### 5. Restore on the new laptop

Install `rclone`, copy this script directory across, then:

```bash
SRC=/run/media/$USER/<DRIVE-UUID>/laptop-2026-10-19
./05-restore-home.sh "$SRC" --dry-run
./05-restore-home.sh "$SRC"
sudo restorecon -R ~          # or pass --relabel
```

Uses `rclone copy`, so it never deletes anything already on the new machine.
Afterwards it repairs permissions on `.ssh`, `.gnupg`, keyrings, `.aws`,
`.docker` and `.kube/config`, then prints a post-restore checklist.

### 6. Reinstall packages

```bash
cd "$SRC/meta/packages"
less rpm-third-party.tsv      # which third-party repos you actually need
./06-reinstall-packages.sh                # pauses for you to add repo files first
```

Do **not** bulk-copy `repos/yum.repos.d/` — some entries target an older
Fedora release and Fedora's own repo files already exist on the new machine.

---

## What is and is not covered

**Covered.** All of `$HOME` including dotfiles: `.ssh`, `.gnupg`, keyrings,
`.aws`, `.kube`, `.config`, shell history, browser profiles. Symlinks survive
via `--links` (stored as `.rclonelink`). Permissions, ownership and timestamps
survive via `--metadata` — which works because the drive is XFS.

**Browser bookmarks** get belt-and-braces treatment: the full profiles are in
the main copy, *and* `meta/bookmarks/` holds standalone snapshots taken through
SQLite's backup API plus plain-text TSVs. Verified on this machine:

| Profile | Bookmarks |
|---|---|
| Firefox `4xutgg4g.default-release` | 72 |
| Chrome `Default` | 636 |
| Chrome `Profile 3` | 528 |

**Not covered.** Anything outside `$HOME`:

- `/etc` — notably Wi-Fi passwords in `/etc/NetworkManager/system-connections/`
  (root-only). Grab separately if wanted:
  `sudo tar -czf wifi.tar.gz /etc/NetworkManager/system-connections`
- `/opt`, `/usr/local`, system-wide cron
- Podman image data (see step 0)
- Hardlinks are copied as independent files; POSIX ACLs and xattrs are not
  preserved. SELinux labels are fixed by `restorecon` after the restore.

**Chrome and Firefox saved passwords** only decrypt if
`~/.local/share/keyrings` restores *and* your login password is unchanged.
Otherwise sign in again and let sync repopulate. Bookmarks are unaffected.

---

## Claude CLI and MCP servers

Config is covered automatically by the home-directory copy:

| Path | Contents |
|---|---|
| `~/.claude.json` | MCP server definitions, per-project state (mode 600) |
| `~/.claude/settings.json` | Settings, hooks, permissions |
| `~/.claude/{agents,commands,skills,hooks,rules}/` | Custom extensions |
| `~/.claude/plugins/` | Installed plugins and marketplaces (789 MB) |
| `~/.claude/projects/` | Session history (231 MB) |
| `~/.config/claude-personal/` | Second profile |
| `~/.local/share/claude/versions/` | CLI binaries — `~/.local/bin/claude` symlinks here |

**Three filter rules exist specifically for this** (see the protected block at
the top of `meta/filters.txt`):

- `+ .claude/**` must precede `**/node_modules/**`, or the 464 MB
  `~/.claude/plugins/cache/thedotmack/claude-mem/13.29.0/node_modules` is
  stripped and the plugin breaks on restore.
- `+ .local/share/claude/**` — `~/.local/bin/claude` is a symlink into
  `versions/2.1.303`; drop the target and the CLI is a dangling link.
- `+ .local/bin/**` — holds `codebase-memory-mcp` and the `claude` symlink.

What does **not** come across automatically, and is why `03-capture-claude.sh`
exists — measured on this machine, 16 servers:

| Type | Count | Why it needs work |
|---|---|---|
| Podman images | 4 | In the excluded 126 GB container store; must be re-pulled |
| `npx` packages | 5 | Cached in excluded `~/.npm/_cacache`; re-downloaded on first use |
| HTTP / remote | 3 | Need interactive OAuth again via `/mcp` |
| Local binaries | 4 | 3 inside `$HOME` (restored); 1 already broken |

Restore with:

```bash
cd "$SRC/meta/claude"
./07-restore-claude.sh      # pulls images, pre-caches npm, lists re-auth targets
claude mcp list          # every server should report Connected
```

Two things flagged on this machine:

- **`notebooklm-mcp` is already missing from PATH** — that server is broken
  here, not just after the move.
- **`localhost/redhat-security-data-mcp:latest`** is a locally built image.
  `07-restore-claude.sh` detects `localhost/` images and tells you to
  `podman load` them, but you must `podman save` them *before* wiping. A
  `quay.io/danclark/redhat-security-data-mcp:latest` of identical size exists,
  so the pull will probably work — verify rather than assume.

## Security: the backup drive holds live credentials

`/home` on this laptop is LUKS-encrypted. **The T7 is not.** The backup will
contain, in cleartext on a portable drive:

- SSH and GPG private keys
- `~/.local/share/keyrings` (GNOME keyring), browser password databases
- `~/.aws`, `~/.kube`, `~/.config/gcloud` credentials
- `~/.claude/.credentials.json` and the env values in `~/.claude.json`

That is the correct trade-off only if the drive stays under your physical
control and is wiped after the migration. If it will not, encrypt it — and
note that `03-capture-claude.sh` writes a *redacted* copy of the MCP config
(`config/claude.json.redacted`) precisely so the convenience copy is not a
second place secrets leak to.

---

## Tuning notes

**Concurrency** is chosen automatically from the negotiated link speed:
`--transfers 16 --checkers 32` at 5 Gbps or better, `8/16` on USB 2.0, `4/8` on
rotational media. Override with `--transfers` / `--checkers`.

**I/O scheduler — opt-in via `--tune`, and probably not worth it.**
`--tune` switches the external drive to `mq-deadline` with
`nr_requests=256` and restores the original values on exit. The T7 defaults
to `bfq`, which optimises interactive fairness and throttles single-stream
bulk transfer; `mq-deadline` suits both directions, batching sequential
writes and already prioritising reads (500 ms expiry vs 5 s).

It is off by default because the benefit was never measured, the workload
is metadata-bound rather than bandwidth-bound, it costs a sudo prompt, and
the revert can fail: `sudo`'s timestamp expires after five minutes while
these runs last hours, so on exit the script may be unable to restore the
setting. It now says so explicitly and prints the manual commands rather
than silently claiming success. The change is not persistent — a reboot
clears it.

The internal NVMe is deliberately left alone: `none` with 12 hardware
queues is already correct for it.

**Verification.** Use `--verify` (size-based). `--verify-hash` MD5s every file
and at this scale takes longer than the backup did.
