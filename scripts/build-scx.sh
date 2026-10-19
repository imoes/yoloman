#!/usr/bin/env bash
# Build the sched_ext schedulers of the scx project once, for the agent package (docs/kernel-tuning.md, "scx in the
# agent"). No distribution ships scx userspace that loads into its own kernel (Fedora 44's packages fail with
# "Invalid argument"; AlmaLinux 10, EPEL 10 and Ubuntu 26.04 have none), so the agent carries a pinned build and
# yoloman.scx_install links it in seconds instead of compiling for minutes on every host.
#
#   scripts/build-scx.sh            → deploy-artifacts/scx/<version>/scx_<name> + BUILD-INFO
#
# The version and the scheduler set come from yoloman.scx_install itself (_DEFAULT_VERSION, _DEFAULT_SCHEDULERS),
# so the package and the module can never disagree. The build runs in the official Rust image (Debian trixie);
# the result must not need a glibc newer than GLIBC_MAX (AlmaLinux 10's 2.39, the oldest supported target) — the
# script fails rather than ship a binary that would not start there. Set http_proxy/https_proxy to build behind
# a proxy. Measured: on Ubuntu 26.04 (glibc 2.42) the v1.1.4 binaries needed at most GLIBC_2.39.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
MOD="$ROOT/internal/starmodules/embedded/modules/yoloman/scx_install.star"
VERSION="$(sed -n 's/^_DEFAULT_VERSION = "\(v[0-9.]*\)"$/\1/p' "$MOD")"
SCHEDS="$(sed -n 's/^_DEFAULT_SCHEDULERS = \[\(.*\)\]$/\1/p' "$MOD" | tr -d '" ' | tr ',' ' ')"
GLIBC_MAX="${GLIBC_MAX:-2.39}"
IMAGE="${SCX_BUILD_IMAGE:-rust:1.93-trixie}"
OUT="$ROOT/deploy-artifacts/scx/$VERSION"

[ -n "$VERSION" ] && [ -n "$SCHEDS" ] || { echo "build-scx: could not read the version/schedulers from $MOD" >&2; exit 1; }
if [ -f "$OUT/BUILD-INFO" ] && [ "${FORCE:-0}" != 1 ]; then
    echo ">> scx $VERSION already built in $OUT (FORCE=1 rebuilds)"; exit 0
fi
echo ">> building scx $VERSION ($SCHEDS) in $IMAGE, glibc ceiling $GLIBC_MAX"
mkdir -p "$OUT"
docker run --rm --network host -e http_proxy -e https_proxy -e HTTP_PROXY -e HTTPS_PROXY \
    -e VERSION="$VERSION" -e SCHEDS="$SCHEDS" -e GLIBC_MAX="$GLIBC_MAX" -e HOST_UID="$(id -u)" \
    -v "$OUT:/out" "$IMAGE" bash -euc '
        apt-get -o Acquire::Retries=3 update -qq
        DEBIAN_FRONTEND=noninteractive apt-get install -y -qq --no-install-recommends \
            git make clang llvm libelf-dev pkg-config zlib1g-dev libzstd-dev libseccomp-dev ca-certificates >/dev/null
        git clone -q --depth 1 --branch "$VERSION" https://github.com/sched-ext/scx.git /src
        cd /src
        pk=""; for s in $SCHEDS; do pk="$pk -p scx_$s"; done
        cargo build --release --locked $pk
        for s in $SCHEDS; do
            b="target/release/scx_$s"
            need="$(objdump -T "$b" | grep -o "GLIBC_[0-9.]*" | sed s/GLIBC_// | sort -V | tail -1)"
            if [ "$(printf "%s\n%s\n" "$need" "$GLIBC_MAX" | sort -V | tail -1)" != "$GLIBC_MAX" ]; then
                echo "build-scx: scx_$s needs GLIBC_$need, newer than $GLIBC_MAX" >&2; exit 1
            fi
            strip "$b"; install -m 0755 "$b" "/out/scx_$s"
        done
        { echo "version=$VERSION"; echo "commit=$(git rev-parse HEAD)"; echo "schedulers=$SCHEDS"
          echo "rustc=$(rustc --version)"; echo "glibc_max=$GLIBC_MAX"; echo "built=$(date -u +%FT%TZ)"
          echo "source=bundled (scripts/build-scx.sh, $(cat /etc/debian_version))"; } > /out/BUILD-INFO
        chown -R "$HOST_UID" /out'
ls -la "$OUT"
