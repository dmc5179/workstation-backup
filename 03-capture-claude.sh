#!/usr/bin/env bash
#
# 03-capture-claude.sh -- inventory the Claude CLI setup so MCP servers can be
# brought back up quickly on the new laptop.
#
#   ./03-capture-claude.sh /run/media/$USER/<DRIVE-UUID>/laptop-2026-10-19/meta/claude
#
# The config files themselves ride along in the main home-directory backup.
# What this adds is the *runtime* side: which container images to pull, which
# npm packages to install, which binaries must exist on PATH, and which
# servers need an interactive re-auth. Read-only; no sudo.
#
set -Eeuo pipefail

OUT=${1:-"$PWD/claude-$(hostname -s)-$(date +%Y%m%d)"}
mkdir -p "$OUT/config"
info() { printf '==> %s\n' "$*"; }
warn() { printf '    WARNING: %s\n' "$*" >&2; }
try()  { "$@" 2>/dev/null || true; }

CJ="$HOME/.claude.json"
[[ -f $CJ ]] || { echo "no ~/.claude.json found; nothing to capture" >&2; exit 1; }

info "Writing to $OUT"

# ------------------------------------------------------- small config copies -
# Convenience duplicates of the files that matter, so they can be eyeballed or
# cherry-picked without unpacking the full home backup. Secrets are NOT copied.
info "Copying small config files (credentials deliberately excluded)"
for f in "$HOME/.claude/settings.json" "$HOME/.claude/CLAUDE.md" \
         "$HOME/.claude/settings.local.json"; do
    [[ -f $f ]] && cp -p "$f" "$OUT/config/" 2>/dev/null || true
done
for d in agents commands skills hooks rules; do
    [[ -d $HOME/.claude/$d ]] && cp -a "$HOME/.claude/$d" "$OUT/config/" 2>/dev/null || true
done
# ~/.claude.json carries MCP env values and OAuth state. Keep only the
# structure, with every env VALUE replaced by a placeholder.
jq '
  def scrub: if type == "object" then with_entries(
      if .key == "env" and (.value|type) == "object"
      then .value |= with_entries(.value = "<REDACTED - re-enter on new machine>")
      else .value |= scrub end)
    elif type == "array" then map(scrub) else . end;
  {mcpServers: (.mcpServers // {}), projects: ((.projects // {}) | with_entries(.value |= {mcpServers: (.mcpServers // {})}))} | scrub
' "$CJ" >"$OUT/config/claude.json.redacted" 2>/dev/null || warn "could not redact ~/.claude.json"

# ------------------------------------------------------------ MCP inventory --
info "Building MCP server inventory"

jq -r '
  def row(scope):
    to_entries[] |
    [ scope,
      .key,
      (.value.type // (if .value.command then "stdio" else "?" end)),
      (.value.command // .value.url // ""),
      ((.value.args // []) | join(" ")),
      ((.value.env // {}) | keys | join(";"))
    ] | @tsv;
  (.mcpServers // {} | row("global")),
  ((.projects // {}) | to_entries[] | .key as $p | (.value.mcpServers // {}) | row($p))
' "$CJ" >"$OUT/mcp-servers.tsv"

{
  printf 'scope\tname\ttype\tcommand/url\targs\tenv-var-names\n'
  cat "$OUT/mcp-servers.tsv"
} | column -t -s$'\t' >"$OUT/mcp-servers.txt" 2>/dev/null || cp "$OUT/mcp-servers.tsv" "$OUT/mcp-servers.txt"

TOTAL=$(wc -l <"$OUT/mcp-servers.tsv")
info "  $TOTAL MCP server definitions found"

# Container-based servers -> images to pull.
awk -F'\t' '$4=="podman"||$4=="docker"{
    for(i=1;i<=NF;i++){}
    n=split($5,a," ");
    for(j=1;j<=n;j++) if(a[j] ~ /\//) {print a[j]; break}
}' "$OUT/mcp-servers.tsv" | sort -u >"$OUT/mcp-podman-images.txt"

# npx-based servers -> npm packages to pre-cache.
awk -F'\t' '$4=="npx"{
    n=split($5,a," ");
    for(j=1;j<=n;j++) if(a[j] !~ /^-/) {print a[j]; break}
}' "$OUT/mcp-servers.tsv" | sort -u >"$OUT/mcp-npm-packages.txt"

# HTTP/SSE servers -> need interactive re-auth, no local dependency.
awk -F'\t' '$3=="http"||$3=="sse"{printf "%s\t%s\n",$2,$4}' "$OUT/mcp-servers.tsv" \
    | sort -u >"$OUT/mcp-http-servers.tsv"

# Everything else -> a binary that must exist on PATH.
awk -F'\t' '$3=="stdio" && $4!="npx" && $4!="podman" && $4!="docker" && $4!="uvx" {print $4}' \
    "$OUT/mcp-servers.tsv" | sort -u >"$OUT/mcp-local-binaries.txt"

info "  $(wc -l <"$OUT/mcp-podman-images.txt") container images, $(wc -l <"$OUT/mcp-npm-packages.txt") npm packages, $(wc -l <"$OUT/mcp-http-servers.tsv") remote, $(wc -l <"$OUT/mcp-local-binaries.txt") local binaries"

# Resolve each local binary now, and flag ones that are already broken or that
# live outside $HOME (and so will NOT arrive with the home-directory backup).
{
    printf '%-32s %-50s %s\n' BINARY RESOLVED NOTE
    while read -r b; do
        [[ -n $b ]] || continue
        p=$(command -v "$b" 2>/dev/null || true)
        if [[ -z $p ]]; then
            note="MISSING ON PATH ALREADY - this server is broken here too"
        elif [[ $p == "$HOME"/* ]]; then
            note="inside \$HOME - restored by 04-backup-home.sh"
        else
            note="OUTSIDE \$HOME - must be reinstalled separately"
        fi
        printf '%-32s %-50s %s\n' "$b" "${p:--}" "$note"
    done <"$OUT/mcp-local-binaries.txt"
} >"$OUT/mcp-local-binaries-resolved.txt"

# ------------------------------------------------------------- environment ---
info "Recording toolchain versions"
{
  echo "captured:  $(date -Is)"
  echo "hostname:  $(hostname)"
  for b in claude node npm npx podman uv uvx go; do
      printf '%-8s %s\n' "$b:" "$({ $b --version 2>/dev/null || echo 'not installed'; } | head -1)"
  done
  echo
  echo "claude binary: $(command -v claude || echo 'not on PATH')"
  echo "resolves to:   $(readlink -f "$(command -v claude 2>/dev/null)" 2>/dev/null || echo n/a)"
} >"$OUT/toolchain-versions.txt"

try npm ls -g --depth=0 --parseable >"$OUT/npm-global-paths.txt"
try npm ls -g --depth=0            >"$OUT/npm-global.txt"

# Plugins and marketplaces, so they can be re-added if the directory is lost.
try jq -r '.marketplaces // {} | keys[]' "$HOME/.claude/plugins/config.json" >"$OUT/claude-plugin-marketplaces.txt"
[[ -d $HOME/.claude/plugins/marketplaces ]] && \
    ls -1 "$HOME/.claude/plugins/marketplaces" >"$OUT/claude-plugin-marketplaces-dirs.txt" 2>/dev/null || true

# --------------------------------------------------------- restore bootstrap -
cat >"$OUT/07-restore-claude.sh" <<'RESTORE'
#!/usr/bin/env bash
#
# 07-restore-claude.sh -- bring the Claude CLI MCP servers back up on a new
# machine. Run AFTER 05-restore-home.sh, from inside this directory.
#
set -Eeuo pipefail
cd "$(dirname "$(readlink -f "$0")")"
info() { printf '==> %s\n' "$*"; }
warn() { printf '    WARNING: %s\n' "$*" >&2; }

info "Checking prerequisites"
MISSING=()
for b in node npm npx podman; do command -v "$b" >/dev/null || MISSING+=("$b"); done
if (( ${#MISSING[@]} )); then
    warn "missing: ${MISSING[*]}"
    warn "install them first:  sudo dnf install nodejs npm podman"
    exit 1
fi
printf '    node %s / npm %s / podman %s\n' \
    "$(node --version)" "$(npm --version)" "$(podman --version | awk '{print $3}')"

if [[ -s mcp-podman-images.txt ]]; then
    info "Pulling MCP container images"
    while read -r img; do
        [[ -n $img ]] || continue
        if [[ $img == localhost/* ]]; then
            warn "$img is a LOCAL-ONLY image - it cannot be pulled."
            warn "  Load it from the archive you made with 'podman save', e.g.:"
            warn "    podman load -i /path/to/${img##*/}.tar"
            continue
        fi
        echo "    $img"
        podman pull "$img" || warn "failed to pull $img"
    done <mcp-podman-images.txt
fi

if [[ -s mcp-npm-packages.txt ]]; then
    info "Pre-caching npx packages (so first MCP start is not a cold download)"
    while read -r pkg; do
        [[ -n $pkg ]] || continue
        echo "    $pkg"
        npm cache add "$pkg" 2>/dev/null || warn "could not pre-cache $pkg"
    done <mcp-npm-packages.txt
fi

if [[ -s npm-global-paths.txt ]]; then
    info "Global npm packages that were installed on the old machine"
    sed 's|.*/node_modules/||' npm-global-paths.txt | grep -v '^$' | sed 's/^/    /'
    echo
    read -r -p "Reinstall these globally with npm i -g? [y/N] " a
    if [[ $a == [Yy]* ]]; then
        mapfile -t PKGS < <(sed 's|.*/node_modules/||' npm-global-paths.txt | grep -v '^$')
        (( ${#PKGS[@]} )) && sudo npm i -g "${PKGS[@]}"
    fi
fi

if [[ -s mcp-local-binaries-resolved.txt ]]; then
    info "Local binaries these MCP servers need"
    cat mcp-local-binaries-resolved.txt | sed 's/^/    /'
    echo "    (anything marked OUTSIDE \$HOME or MISSING needs manual reinstall)"
fi

if [[ -s mcp-http-servers.tsv ]]; then
    info "Remote servers requiring interactive re-authentication"
    while IFS=$'\t' read -r name url; do printf '    %-28s %s\n' "$name" "$url"; done <mcp-http-servers.tsv
    echo
    echo "    In Claude Code run:  /mcp     then authenticate each one."
fi

cat <<'DONE'

Next:
  1. claude mcp list            -- every server should report Connected
  2. Anything still failing: check its env vars. Values were REDACTED from
     config/claude.json.redacted on purpose; the real ones are in the restored
     ~/.claude.json, but tokens may have expired and need re-issuing.
  3. Plugins live in ~/.claude/plugins and are restored by 04-backup-home.sh.
     If one misbehaves, re-add its marketplace from
     claude-plugin-marketplaces.txt and reinstall.
DONE
RESTORE
chmod +x "$OUT/07-restore-claude.sh"

info "Done. Files written:"
ls -1 "$OUT" | sed 's/^/    /'
