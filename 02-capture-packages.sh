#!/usr/bin/env bash
#
# 02-capture-packages.sh -- record everything installed on this system so it can
# be reproduced on the new laptop. Read-only; no sudo required.
#
#   ./02-capture-packages.sh /run/media/$USER/<DRIVE-UUID>/laptop-2026-10-19/meta/packages
#
set -Eeuo pipefail

OUT=${1:-"$PWD/packages-$(hostname -s)-$(date +%Y%m%d)"}
mkdir -p "$OUT"/{repos,extras}
info() { printf '==> %s\n' "$*"; }
try()  { "$@" 2>/dev/null || true; }

info "Writing to $OUT"

{ echo "captured:   $(date -Is)"
  echo "hostname:   $(hostname)"
  echo "os:         $(. /etc/os-release && echo "$PRETTY_NAME")"
  echo "releasever: $(. /etc/os-release && echo "$VERSION_ID")"
  echo "arch:       $(uname -m)"
  echo "kernel:     $(uname -r)"
  echo "dnf:        $(dnf --version 2>/dev/null | head -1)"
} >"$OUT/system-info.txt"

# ------------------------------------------------------------------- RPMs ---
info "RPM inventory"
rpm -qa --qf '%{NAME}\n'                             | sort -u >"$OUT/rpm-names.txt"
rpm -qa --qf '%{NAME}-%{EVR}.%{ARCH}\n'              | sort    >"$OUT/rpm-nevra.txt"
rpm -qa --qf '%{NAME}\t%{EVR}\t%{ARCH}\t%{VENDOR}\n' | sort    >"$OUT/rpm-detail.tsv"
rpm -qa --last                                                 >"$OUT/rpm-by-install-date.txt"
rpm -q gpg-pubkey --qf '%{NAME}-%{VERSION}-%{RELEASE}\t%{SUMMARY}\n' \
                                                     | sort    >"$OUT/rpm-gpg-keys.txt"
info "  total packages: $(wc -l <"$OUT/rpm-names.txt")"

# Packages you asked for, as opposed to pulled-in dependencies. This is the
# list to feed back to dnf on the new machine.
if dnf repoquery --userinstalled --queryformat '%{name}' >"$OUT/pkglist-userinstalled.txt" 2>/dev/null \
   && [[ -s $OUT/pkglist-userinstalled.txt ]]; then
    sort -u -o "$OUT/pkglist-userinstalled.txt" "$OUT/pkglist-userinstalled.txt"
else
    try dnf history userinstalled >"$OUT/pkglist-userinstalled.txt"
    [[ -s $OUT/pkglist-userinstalled.txt ]] || cp "$OUT/rpm-names.txt" "$OUT/pkglist-userinstalled.txt"
fi
info "  user-installed: $(wc -l <"$OUT/pkglist-userinstalled.txt")"

# Which repo each package came from -- the fastest way to spot third-party
# bits (rpmfusion, copr, docker-ce, google-chrome, vscode) whose repo must be
# configured on the new machine before the install will succeed.
try dnf repoquery --installed --queryformat '%{name}\t%{from_repo}' | sort >"$OUT/rpm-from-repo.tsv"
if [[ -s $OUT/rpm-from-repo.tsv ]]; then
    awk -F'\t' '$2 !~ /^(fedora|updates|updates-testing|anaconda|@System|@commandline|koji|)$/' \
        "$OUT/rpm-from-repo.tsv" >"$OUT/rpm-third-party.tsv"
    info "  third-party:    $(wc -l <"$OUT/rpm-third-party.tsv")"
fi

# ------------------------------------------------------------------ repos ---
info "Repository configuration"
cp -a /etc/yum.repos.d  "$OUT/repos/" 2>/dev/null || true
cp -a /etc/dnf/dnf.conf "$OUT/repos/" 2>/dev/null || true
cp -a /etc/dnf/vars     "$OUT/repos/" 2>/dev/null || true
cp -a /etc/pki/rpm-gpg  "$OUT/repos/" 2>/dev/null || true
try dnf repolist --all >"$OUT/repos/repolist-all.txt"
try dnf repolist       >"$OUT/repos/repolist-enabled.txt"
try dnf history list --reverse >"$OUT/dnf-history.txt"

# ---------------------------------------------------------------- flatpak ---
if command -v flatpak >/dev/null; then
    info "Flatpak"
    try flatpak remotes --columns=name,url                     >"$OUT/flatpak-remotes.tsv"
    try flatpak list --app --columns=application,origin,branch >"$OUT/flatpak-apps.tsv"
fi

# ----------------------------------------------------------------- extras ---
info "Non-RPM package managers and system state"
try bash -lc 'pip list --user --format=freeze' >"$OUT/extras/pip-user.txt"
try bash -lc 'pipx list --short'               >"$OUT/extras/pipx.txt"
try bash -lc 'npm ls -g --depth=0 --parseable' >"$OUT/extras/npm-global.txt"
try bash -lc 'cargo install --list'            >"$OUT/extras/cargo.txt"
try bash -lc 'gem list --local'                >"$OUT/extras/gem.txt"
try toolbox list                               >"$OUT/extras/toolbox.txt"
try distrobox list                             >"$OUT/extras/distrobox.txt"
try code --list-extensions                     >"$OUT/extras/vscode-extensions.txt"
try systemctl list-unit-files --state=enabled --no-pager        >"$OUT/extras/systemd-enabled-system.txt"
try systemctl --user list-unit-files --state=enabled --no-pager >"$OUT/extras/systemd-enabled-user.txt"
try nmcli -g NAME,TYPE connection show         >"$OUT/extras/network-connections.tsv"
try crontab -l                                 >"$OUT/extras/crontab-user.txt"
try groups                                     >"$OUT/extras/user-groups.txt"
printf '%s\n' "$SHELL"                         >"$OUT/extras/login-shell.txt"

# Container images. The 126G podman store is deliberately excluded from the
# file backup -- overlay metadata does not survive a move between machines --
# so this list is how you get your images back.
if command -v podman >/dev/null; then
    info "Podman images (storage itself is NOT backed up -- re-pull from this list)"
    try podman images --format '{{.Repository}}:{{.Tag}}'  >"$OUT/extras/podman-images.txt"
    try podman images --format '{{.Repository}}:{{.Tag}}' \
        | grep -c . >/dev/null
    {
      echo "# Images that exist only locally (no registry to pull from)."
      echo "# 'podman save --format oci-archive -o <file>.tar <image>' these"
      echo "# BEFORE wiping this laptop, or they are gone."
      try podman images --format '{{.Repository}}:{{.Tag}}' | grep -E '^(localhost/|<none>)'
    } >"$OUT/extras/podman-images-local-only.txt"
fi

# -------------------------------------------------------- reinstall helper ---
cat >"$OUT/06-reinstall-packages.sh" <<'REINSTALL'
#!/usr/bin/env bash
#
# 06-reinstall-packages.sh -- rebuild the package set on the NEW laptop.
# Run from inside this directory. Read every step before letting it proceed.
#
set -Eeuo pipefail
cd "$(dirname "$(readlink -f "$0")")"

cat <<'NOTE'
STEP 1 -- repositories.
  repos/yum.repos.d/ holds the repo files from the old machine. Do NOT copy
  them in blindly: some will target an older Fedora release, some you may no
  longer want, and Fedora's own repo files already exist on the new machine.
  Review, then install only the third-party ones you still need:

    ls repos/yum.repos.d/
    sudo install -m0644 repos/yum.repos.d/<name>.repo /etc/yum.repos.d/
    sudo install -m0644 repos/rpm-gpg/<key>           /etc/pki/rpm-gpg/

  rpm-third-party.tsv lists which packages came from which non-Fedora repo.
NOTE
read -r -p "Repositories configured? Enter to continue, Ctrl-C to stop. "

echo "STEP 2 -- refreshing metadata"
sudo dnf makecache

echo "STEP 3 -- installing user-installed packages"
mapfile -t PKGS < <(grep -Ev '^\s*(#|$)' pkglist-userinstalled.txt)
echo "  ${#PKGS[@]} packages requested"
sudo dnf install --skip-unavailable "${PKGS[@]}"

if [[ -s flatpak-apps.tsv ]] && command -v flatpak >/dev/null; then
    echo "STEP 4 -- flatpaks"
    while IFS=$'\t' read -r name url; do
        [[ -n ${name:-} ]] && sudo flatpak remote-add --if-not-exists "$name" "$url" || true
    done < flatpak-remotes.tsv
    while IFS=$'\t' read -r app origin _branch; do
        [[ -n ${app:-} ]] && flatpak install -y "${origin:-flathub}" "$app" || true
    done < flatpak-apps.tsv
fi

cat <<'DONE'

Done. Anything dnf could not find was skipped (--skip-unavailable) -- check the
output above against rpm-third-party.tsv for packages whose repo is still
missing. Non-RPM tooling (pip, npm, cargo, gem, VS Code extensions) is listed
under extras/ for manual reinstall. Container images: extras/podman-images.txt.
DONE
REINSTALL
chmod +x "$OUT/06-reinstall-packages.sh"

info "Done. $(du -sh "$OUT" | cut -f1) written to $OUT"
ls -1 "$OUT"
