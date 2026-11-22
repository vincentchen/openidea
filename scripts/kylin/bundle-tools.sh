#!/usr/bin/env bash
# Builds the offline language pack for Kylin: the static `openidea-server`
# plus every managed language server, debugger and plugin, a JDK, and the Node
# and Python runtimes those tools need. The result runs on a machine with no
# network and no Node/Python/Java of its own.
#
# Usage: bundle-tools.sh <amd64|arm64> <openidea-server> <output-dir>
#
# Must run on the same architecture as the target (the tools are downloaded for
# this machine). `openidea-server` has to be the musl build: a glibc build from
# a modern runner does not start on Kylin V10 (glibc 2.31).
#
# Output: <output-dir>/OpenIDEA-server_<version>_kylin_<arch>.tar.gz
#         <output-dir>/openidea-server-linux-<x86_64|aarch64>.gz (for the
#           desktop's remote development, which fetches that name)
set -euo pipefail

log() { printf '  %s\n' "$*" >&2; }
die() { printf 'error: %s\n' "$*" >&2; exit 1; }

[ $# -eq 3 ] || die "usage: $0 <amd64|arm64> <openidea-server> <output-dir>"
arch=$1
server=$2
out_dir=$3

case "$arch" in
  amd64)
    node_arch=x64
    pbs_arch=x86_64
    rust_arch=x86_64
    ;;
  arm64)
    node_arch=arm64
    pbs_arch=aarch64
    rust_arch=aarch64
    ;;
  *)
    die "unsupported architecture: $arch"
    ;;
esac

[ -f "$server" ] || die "no such binary: $server"
mkdir -p "$out_dir"
out_dir=$(cd "$out_dir" && pwd)

version=${VERSION:-}
if [ -z "$version" ]; then
  version=$(jq -r .version src-tauri/tauri.conf.json 2>/dev/null || true)
fi
[ -n "$version" ] && [ "$version" != null ] || die "cannot read the version (set VERSION)"

# Pinned so a rebuild of the same tag yields the same runtimes.
node_version=${NODE_VERSION:-22.23.5}
python_version=${PYTHON_VERSION:-3.12.16}
pbs_release=${PBS_RELEASE:-20261110}

top="OpenIDEA-server-${version}-kylin-${arch}"
stage="$out_dir/$top"
rm -rf "$stage"
mkdir -p "$stage/bin" "$stage/runtime" "$stage/scripts"

log "server: $server"
install -m 755 "$server" "$stage/bin/openidea-server"
printf '%s\n' "$version" > "$stage/VERSION"

# The runtimes first: the installer creates the Python virtualenvs with this
# interpreter and runs npm with this Node, so every recorded path points into
# the pack.
# `$1`=url, `$2`=extract root, `$3`=binary to check before reusing the download.
# The archives both wrap their content in a single directory (`node-v…`,
# `python/`); strip it and unpack what is left into the pack.
fetch_runtime() {
  local url=$1 root=$2 check=$3 tmp flags
  if [ -x "$check" ]; then
    return 0
  fi
  case "$url" in
    *.xz) flags=-J ;;
    *.gz) flags=-z ;;
    *) flags= ;;
  esac
  log "downloading $url"
  tmp=$(mktemp -d)
  if ! curl -fsSL "$url" | tar -x $flags -C "$tmp" --strip-components=1; then
    rm -rf "$tmp"
    return 1
  fi
  mkdir -p "$root"
  cp -a "$tmp"/. "$root"/
  rm -rf "$tmp"
}

log "node $node_version"
fetch_runtime "https://nodejs.org/dist/v$node_version/node-v$node_version-linux-$node_arch.tar.xz" \
  "$stage/runtime/node" "$stage/runtime/node/bin/node"
log "python $python_version ($pbs_release)"
fetch_runtime "https://github.com/astral-sh/python-build-standalone/releases/download/$pbs_release/cpython-$python_version+$pbs_release-$pbs_arch-unknown-linux-gnu-install_only_stripped.tar.gz" \
  "$stage/runtime/python" "$stage/runtime/python/bin/python3"

"$stage/runtime/node/bin/node" --version
"$stage/runtime/python/bin/python3" --version

# Installs the tools, the JDK, and writes data/install-report.tsv. One failing
# tool must not hide the others, so the exit code is checked through the report.
log "installing language tools (this downloads a few hundred megabytes)"
export PATH="$stage/runtime/node/bin:$stage/runtime/python/bin:$PATH"
export OPENIDEA_SERVER_HOME="$stage"
export npm_config_update_notifier=false
set +e
"$stage/bin/openidea-server" --install-tools 2>&1 | tee "$out_dir/install-tools.log"
rc=${PIPESTATUS[0]}
set -e
report="$stage/data/install-report.tsv"
[ -f "$report" ] || die "no install report (exit $rc)"
# The report is `status<TAB>name<TAB>detail`.
tab=$'\t'
log "installer exited $rc"

# A pack that silently lost a major language server is worse than no pack.
# clangd publishes no Linux aarch64 build, so it is only required on amd64.
required="jdk-21 jdtls vtsls gopls kotlin-lsp java-debug debugpy lombok codelldb js-debug"
if [ "$arch" = amd64 ]; then
  required="$required clangd"
fi
# Test knob: a partial build (missing toolchains) can pass its own list.
required=${OPENIDEA_PACK_REQUIRED:-$required}
missing=""
for tool in $required; do
  grep -qE "^[a-z0-9-]+${tab}${tool}${tab}" "$report" || missing="$missing $tool"
done
if [ -n "$missing" ]; then
  printf '::error::the pack is missing:%s\n' "$missing" >&2
  exit 1
fi
log "all required tools are present"

# The server prepends tools/node_modules/.bin to PATH, which is how the
# desktop-launched binary (no wrapper, no shell profile) finds Node and Python.
bin="$stage/data/tools/node_modules/.bin"
mkdir -p "$bin"
for exe in node npm npx; do
  [ -e "$stage/runtime/node/bin/$exe" ] && ln -sfn "../../../../runtime/node/bin/$exe" "$bin/$exe"
done
for exe in python3 python3.12 python; do
  [ -e "$stage/runtime/python/bin/$exe" ] && ln -sfn "../../../../runtime/python/bin/$exe" "$bin/$exe"
done

# Byte-compiled files only bloat the archive.
find "$stage/data" -name __pycache__ -type d -prune -exec rm -rf {} + 2>/dev/null || true
find "$stage/data" -name '*.pyc' -delete 2>/dev/null || true

# Where the tree was built; `repair-tools-paths.sh` rewrites it after a move.
printf '%s\n' "$stage" > "$stage/data/.openidea-pack-root"
cp scripts/kylin/repair-tools-paths.sh "$stage/scripts/"
chmod +x "$stage/scripts/repair-tools-paths.sh"

# ---------------------------------------------------------------- launcher --
cat > "$stage/openidea-server" <<'LAUNCHER'
#!/bin/sh
# Runs the bundled server with this directory as its home, so the pack works
# wherever it was unpacked and needs no installation.
set -e
dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd -P)
home=${OPENIDEA_SERVER_HOME:-$dir}
OPENIDEA_SERVER_HOME=$home
export OPENIDEA_SERVER_HOME
PATH="$home/runtime/node/bin:$dir/runtime/node/bin:$home/runtime/python/bin:$dir/runtime/python/bin:$home/data/tools/node_modules/.bin:$PATH"
export PATH
# A moved tree remembers the path it was built at; fix that once per location.
if [ -f "$home/data/.openidea-pack-root" ]; then
  "$dir/scripts/repair-tools-paths.sh" "$home" >&2 || true
fi
exec "$dir/bin/openidea-server" "$@"
LAUNCHER
chmod +x "$stage/openidea-server"

# ---------------------------------------------------------------- install ---
cat > "$stage/install.sh" <<'INSTALL'
#!/bin/sh
# Installs the pack into ~/.openidea (or $OPENIDEA_SERVER_HOME), where the
# desktop app looks for the remote development server's tools.
set -eu
dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd -P)
dest=${OPENIDEA_SERVER_HOME:-$HOME/.openidea}
profile=1
while [ $# -gt 0 ]; do
  case "$1" in
    --prefix) [ $# -ge 2 ] || { echo "--prefix needs a directory" >&2; exit 2; }; dest=$2; shift 2 ;;
    --no-profile) profile=0; shift ;;
    -h|--help) sed -n '2,6p' "$0"; exit 0 ;;
    *) echo "unknown option: $1" >&2; exit 2 ;;
  esac
done
mkdir -p "$dest/data"
if [ -d "$dest/data/tools" ] && [ -n "$(ls -A "$dest/data/tools" 2>/dev/null)" ]; then
  backup="$dest/data/tools.bak.$(date +%Y%m%d%H%M%S)"
  echo "existing tools moved to $backup"
  mv "$dest/data/tools" "$backup"
fi
echo "copying tools to $dest (about 1.5 GB)…"
cp -a "$dir/data/." "$dest/data/"
rm -rf "$dest/runtime"
cp -a "$dir/runtime" "$dest/runtime"
# The server binary, for people who want to run the server themselves
# (`$dest/bin/openidea-server`); the desktop keeps downloading its own copy.
mkdir -p "$dest/bin"
cp -a "$dir/bin/openidea-server" "$dest/bin/"
mkdir -p "$dest/scripts"
cp "$dir/scripts/repair-tools-paths.sh" "$dest/scripts/"
chmod +x "$dest/scripts/repair-tools-paths.sh"
"$dest/scripts/repair-tools-paths.sh" "$dest"

if [ "$profile" = 1 ]; then
  block_start='# >>> OpenIDEA language tools >>>'
  block_end='# <<< OpenIDEA language tools <<<'
  for file in "$HOME/.profile" "$HOME/.bash_profile" "$HOME/.bashrc"; do
    [ -e "$file" ] || continue
    sed -i "/^$block_start\$/,/^$block_end\$/d" "$file"
    cat >> "$file" <<EOF
$block_start
# Node, Python and the language servers of the OpenIDEA offline pack.
PATH="$dest/runtime/node/bin:$dest/runtime/python/bin:$dest/data/tools/node_modules/.bin:\$PATH"
export PATH
$block_end
EOF
    echo "PATH added to $file"
  done
  if [ ! -e "$HOME/.profile" ] && [ ! -e "$HOME/.bash_profile" ] && [ ! -e "$HOME/.bashrc" ]; then
    cat > "$HOME/.profile" <<EOF
$block_start
PATH="$dest/runtime/node/bin:$dest/runtime/python/bin:$dest/data/tools/node_modules/.bin:\$PATH"
export PATH
$block_end
EOF
    echo "PATH added to $HOME/.profile"
  fi
fi

echo
echo "installed to $dest"
echo "  re-login (or start a new shell) so the PATH applies to remote sessions"
echo "  then run: $dest/bin/openidea-server --version"
INSTALL
chmod +x "$stage/install.sh"

# ------------------------------------------------------------------ readme ---
tools_ok=$(grep -cE "^(ok|present)${tab}" "$report" || true)
cat > "$stage/README.txt" <<README
OpenIDEA server $version for Kylin (${arch}) — offline language pack
====================================================================

The remote development backend of OpenIDEA, with the language servers,
debuggers and Java tooling it normally downloads on demand, plus the Node and
Python runtimes those tools need. It runs on a machine with no network and no
Node, Python or Java installed: everything it needs is in this directory.

Target: Kylin V10 SP1 / domestic Linux, glibc 2.28 or newer. The server binary
is static (musl); the bundled Node and Python are built for glibc 2.17+.

Contents
--------
  bin/openidea-server      static server binary
  openidea-server          launcher: uses this directory as its home
  data/tools/              $tools_ok tools (language servers, debuggers, plugins)
  data/tools/jdks/         Eclipse Temurin 21
  runtime/node/            Node.js $node_version
  runtime/python/          CPython $python_version
  data/install-report.tsv  what was installed, one line per tool

Use it without installing
-------------------------
  tar -xzf OpenIDEA-server_${version}_kylin_${arch}.tar.gz
  cd $top
  ./openidea-server --version

The directory can be moved or renamed; the launcher fixes the recorded paths
on first start. Disk use is about $(du -sh "$stage" | cut -f1).

Use it for the desktop's remote development
-------------------------------------------
  ./install.sh

This copies everything into ~/.openidea (or \$OPENIDEA_SERVER_HOME), where the
desktop looks for the remote host's tools, and adds the bundled Node and Python
to PATH in your shell profile. Re-login, then connect over SSH as usual.

Notes
-----
  * rust-analyzer is not included: it is a rustup component and must be
    installed with rustup on the host.
  * solargraph needs Ruby; csharp-ls and fsautocomplete need the .NET runtime.
    They are installed, but those runtimes are not bundled.
  * Refresh or add tools later (needs network):
      ./openidea-server --install-tools
    or pick names with OPENIDEA_INSTALL_TOOLS_ONLY=jdtls,gopls.

Checksums: see SHA256SUMS in the release.
README

# ------------------------------------------------------------------- archive --
asset="OpenIDEA-server_${version}_kylin_${arch}.tar.gz"
log "packing $asset ($(du -sh "$stage" | cut -f1))"
if command -v pigz >/dev/null; then
  tar -C "$out_dir" -I 'pigz -9 -p 4' -cf "$out_dir/$asset" "$top"
else
  tar -C "$out_dir" -I 'gzip -9' -cf "$out_dir/$asset" "$top"
fi
gzip -9 -c "$stage/bin/openidea-server" > "$out_dir/openidea-server-linux-$rust_arch.gz"
(cd "$out_dir" && sha256sum "$asset" "openidea-server-linux-$rust_arch.gz" > "$asset.sha256")
ls -lh "$out_dir/$asset" "$out_dir/openidea-server-linux-$rust_arch.gz"
