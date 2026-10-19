# yoloman.scx_install — the sched_ext schedulers of the scx project, built from upstream.
#
# Fedora 44, AlmaLinux 10 and Ubuntu 26.04 all run kernels with sched_ext, but none ships scx userspace that
# loads into them (Fedora's 2024 packages fail with "Invalid argument"; Alma, EPEL 10 and Ubuntu have none,
# measured — docs/kernel-tuning.md). This module builds a pinned scx release from source instead:
#
#   /opt/yoloman/scx/<version>/bin/scx_<name>      the binaries, plus BUILD-INFO (commit, rustc, date)
#   /usr/local/bin/scx_<name> -> the above          so yoloman.sched_ext (command -v) finds them first
#
# The build runs as its own transient systemd unit (yoloman-scx-build-<version>), niced and on idle I/O, because
# it outlasts a tool call. Named states: built (binaries present and linked), building (the unit runs; calling
# again never starts a second build), absent; a failed build fails the call with its last log lines and the next
# call starts over. The build tools are NOT installed here: a missing one is tool_unavailable with the package
# names for this OS family, installed with the package module. Every refusal happens before anything changes.
# The yoloman links in /usr/local/bin always point at exactly one version, so the rollback is one call.

_ROOT = "/opt/yoloman/scx"
# The agent package carries a build of the default version (scripts/build-scx.sh): linked in seconds, no compiler.
_BUNDLED = "/usr/lib/yoloman/scx"
_LIBPKG = {"debian": "libelf1t64 (libelf1 on older releases), libzstd1, zlib1g",
           "redhat": "elfutils-libelf, libzstd, zlib", "suse": "libelf1, libzstd1, libz1", "archlinux": "libelf, zstd, zlib"}
_LINKDIR = "/usr/local/bin"
_REPO = "https://github.com/sched-ext/scx.git"
_DEFAULT_VERSION = "v1.1.4"
_DEFAULT_SCHEDULERS = ["rusty", "bpfland", "lavd"]
_NAME_CHARS = "abcdefghijklmnopqrstuvwxyz0123456789_"
_VERSION_CHARS = "v0123456789."
_PROXY_CHARS = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789:/.-_@%"
# make: libbpf-sys compiles the vendored libbpf with it (measured: "make is required to compile libbpf-sys").
_TOOLS = ["git", "cargo", "rustc", "clang", "pkg-config", "make"]
_PKGS = {
    "debian": "git make clang llvm libelf-dev pkg-config cargo rustc zlib1g-dev libzstd-dev libseccomp-dev",
    "redhat": "git make clang llvm elfutils-libelf-devel pkgconf-pkg-config cargo rust zlib-devel libzstd-devel libseccomp-devel",
    "suse": "git make clang llvm libelf-devel pkg-config cargo rust zlib-devel libzstd-devel libseccomp-devel",
    "archlinux": "git make clang llvm libelf pkgconf rust zlib zstd libseccomp",
}
# Space under /var/tmp for source + target. Measured for v1.1.4 (rusty, bpfland, lavd) on Ubuntu 26.04, 2 vCPU:
# 1439 MB source and target plus 203 MB crates, 4 min 09 s. 3 GB leaves room for more schedulers.
_NEED_MB = 3072

# Lists the yoloman links: "<link> <target>" per line.
_LINKS = 'for l in "$1"/scx_*; do [ -L "$l" ] && printf "%s %s\\n" "$l" "$(readlink "$l")"; done; true'
# Points the links at one version: drop every link into $ROOT, then link the given schedulers.
_RELINK = ('root=$1; bindir=$2; dir=$3; shift 3; for l in "$dir"/scx_*; do [ -L "$l" ] || continue; ' +
           'case "$(readlink "$l")" in "$root"/*|/usr/lib/yoloman/scx/*) rm -f "$l";; esac; done; ' +
           'for s in "$@"; do ln -sfn "$bindir/scx_$s" "$dir/scx_$s"; done')
_MISSING_LIBS = 'for b in "$@"; do ldd "$b" 2>/dev/null | grep "not found"; done; true'
_BUILD = """set -eu
root=$1; ver=$2; repo=$3; dir=$4; shift 4
prefix="$root/$ver"; src="/var/tmp/yoloman-scx-$ver"
echo "yoloman.scx_install: building scx $ver ($*) $(date -u +%FT%TZ)"
rm -rf "$src"
git clone --depth 1 --branch "$ver" "$repo" "$src"
cd "$src"
pk=""; for s in "$@"; do pk="$pk -p scx_$s"; done
cargo build --release --locked $pk
mkdir -p "$prefix"; rm -rf "$prefix/bin.new"; mkdir "$prefix/bin.new"
for s in "$@"; do install -m 0755 "target/release/scx_$s" "$prefix/bin.new/scx_$s"; done
{ echo "version=$ver"; echo "commit=$(git rev-parse HEAD)"; echo "schedulers=$*"; echo "rustc=$(rustc --version)"; echo "built=$(date -u +%FT%TZ)"; } > "$prefix/bin.new/BUILD-INFO"
rm -rf "$prefix/bin"; mv "$prefix/bin.new" "$prefix/bin"
for l in "$dir"/scx_*; do [ -L "$l" ] || continue; case "$(readlink "$l")" in "$root"/*) rm -f "$l";; esac; done
for s in "$@"; do ln -sfn "$prefix/bin/scx_$s" "$dir/scx_$s"; done
cd /; rm -rf "$src"
echo "yoloman.scx_install: built $(date -u +%FT%TZ)"
"""
_WAIT_UNIT = ('u=$1; while :; do a=$(systemctl show -p ActiveState --value "$u"); ' +
              's=$(systemctl show -p SubState --value "$u"); ' +
              '[ "$a" = failed ] && break; [ "$s" = exited ] && break; [ "$a" = inactive ] && break; sleep 2; done')


def main(ctx, params):
    want = params.get("state", "present")
    ver = params.get("version", _DEFAULT_VERSION) or _DEFAULT_VERSION
    if not ver.startswith("v") or not _all_in(ver, _VERSION_CHARS) or ver.count(".") != 2:
        fail("version must be a release tag like %s, got %r (no 'latest': a build must be reproducible)" % (_DEFAULT_VERSION, ver))
    scheds = [str(s) for s in (params.get("schedulers") or _DEFAULT_SCHEDULERS)]
    for s in scheds:
        if not s or not _all_in(s, _NAME_CHARS):
            fail("scheduler names are [a-z0-9_] without the scx_ prefix, got %r" % s)
    proxy = params.get("proxy", "") or ""
    if proxy and not _all_in(proxy, _PROXY_CHARS):
        fail("proxy %r has characters outside a URL" % proxy)
    wait = int(params.get("wait", 600))
    kc = ctx.facts().get("kernel_caps") or {}
    if (kc.get("init_system") or {}).get("state") != "systemd":
        fail("unsupported: the build runs as a transient systemd unit; init system is %s" % (kc.get("init_system") or {}).get("state", "unknown"))

    source = params.get("source", "auto") or "auto"
    if source not in ("auto", "bundled", "upstream"):
        fail("source must be auto, bundled or upstream, got %r" % source)

    prefix = "%s/%s" % (_ROOT, ver)
    bundled = "%s/%s" % (_BUNDLED, ver)
    unit = "yoloman-scx-build-%s.service" % ver.replace(".", "-")
    links = _links(ctx)
    for s in scheds:
        p = "%s/scx_%s" % (_LINKDIR, s)
        if p not in links and ctx.file_exists(p):
            fail("conflict: %s exists and is not a yoloman link; remove it or install scx elsewhere" % p)

    if want == "absent":
        return _absent(ctx, ver, prefix, bundled, links, _state(ctx, prefix, scheds, links, unit))

    have_bundled = len([s for s in scheds if ctx.file_exists("%s/scx_%s" % (bundled, s))]) == len(scheds)
    if source == "bundled" and not have_bundled:
        fail("tool_unavailable: this agent package carries no scx %s build of %s (look in %s); use source=upstream to build it" % (
            ver, ", ".join(scheds), _BUNDLED))
    if have_bundled and source != "upstream":
        return _link_bundled(ctx, ver, scheds, bundled, links)

    before = _state(ctx, prefix, scheds, links, unit)

    if before["state"] == "built" and before["linked"]:
        return _result(ctx, False, "scx %s built and linked" % ver, before, before, ver, scheds, prefix, unit, links)
    if before["state"] == "built":
        if ctx.check_mode:
            return _result(ctx, True, "would link scx %s" % ver, before, dict(before, linked = True), ver, scheds, prefix, unit, links)
        _ok(ctx.run(["sh", "-c", _RELINK, "sh", _ROOT, prefix + "/bin", _LINKDIR] + scheds, mutates = True), "linking")
        return _result(ctx, True, "linked scx %s" % ver, before, _state(ctx, prefix, scheds, _links(ctx), unit), ver, scheds, prefix, unit, links)

    if before["state"] == "failed":
        log = _log_tail(ctx, unit)
        ctx.run(["systemctl", "stop", unit], mutates = True)
        ctx.run(["systemctl", "reset-failed", unit], mutates = True, ok_codes = [0, 1])
        fail("the scx %s build failed (exit %s); call again to start over. Last log lines:\n%s" % (ver, before.get("exit", "?"), log))

    if before["state"] != "building":
        missing = [t for t in _TOOLS if ctx.run(["sh", "-c", 'command -v "$1"', "sh", t]).rc != 0]
        if missing:
            family = ctx.facts().get("os_family", "")
            fail("tool_unavailable: %s missing for the build (on %s install: %s)" % (
                ", ".join(missing), family or "this family", _PKGS.get(family, "git, make, clang, llvm, libelf, pkg-config, cargo, rustc")))
        free = _free_mb(ctx, "/var/tmp")
        if free >= 0 and free < _NEED_MB:
            fail("unsupported: /var/tmp has %d MB free; building scx needs about %d MB" % (free, _NEED_MB))
        if ctx.check_mode:
            return _result(ctx, True, "would build scx %s (%s)" % (ver, ", ".join(scheds)), before,
                           {"state": "built", "linked": True}, ver, scheds, prefix, unit, links)
        argv = ["systemd-run", "--no-block", "--quiet", "--unit=" + unit, "-p", "RemainAfterExit=yes",
                "-p", "Nice=10", "-p", "IOSchedulingClass=idle", "-p", "CPUWeight=20",
                "-p", "StandardOutput=file:/run/%s.log" % unit, "-p", "StandardError=file:/run/%s.log" % unit,
                "--setenv=HOME=/root", "--setenv=CARGO_HOME=/var/cache/yoloman/cargo",
                "--description=yoloman.scx_install " + ver]
        if proxy:
            for k in ("http_proxy", "https_proxy", "HTTP_PROXY", "HTTPS_PROXY"):
                argv.append("--setenv=%s=%s" % (k, proxy))
        start = ctx.run(argv + ["sh", "-c", _BUILD, "sh", _ROOT, ver, _REPO, _LINKDIR] + scheds, mutates = True)
        if start.rc != 0:
            fail("starting the build unit failed: %s" % start.stderr)
    elif ctx.check_mode:
        return _result(ctx, False, "scx %s is being built" % ver, before, before, ver, scheds, prefix, unit, links)

    if wait > 0:
        ctx.run(["timeout", str(wait), "sh", "-c", _WAIT_UNIT, "sh", unit])
    after = _state(ctx, prefix, scheds, _links(ctx), unit)
    if after["state"] == "failed":
        log = _log_tail(ctx, unit)
        ctx.run(["systemctl", "stop", unit], mutates = True)
        ctx.run(["systemctl", "reset-failed", unit], mutates = True, ok_codes = [0, 1])
        fail("the scx %s build failed (exit %s); call again to start over. Last log lines:\n%s" % (ver, after.get("exit", "?"), log))
    if after["state"] == "built":
        ctx.run(["systemctl", "stop", unit], mutates = True)
        return _result(ctx, True, "built scx %s (%s)" % (ver, ", ".join(scheds)), before, after, ver, scheds, prefix, unit, links)
    return _result(ctx, before["state"] != "building", "scx %s is being built (unit %s); call again to follow it" % (ver, unit),
                   before, after, ver, scheds, prefix, unit, links)


def _link_bundled(ctx, ver, scheds, bundled, links):
    """The build the agent package carries: link it, after checking its libraries resolve on this host."""
    paths = ["%s/scx_%s" % (bundled, s) for s in scheds]
    missing = ctx.run(["sh", "-c", _MISSING_LIBS, "sh"] + paths).stdout.strip()
    if missing:
        family = ctx.facts().get("os_family", "")
        libs = []
        for l in missing.splitlines():
            name = l.strip().split(" ")[0]
            if name and name not in libs:
                libs.append(name)
        fail("tool_unavailable: the bundled scx %s needs libraries this host lacks (%s); install %s" % (
            ver, " ".join(sorted(libs)), _LIBPKG.get(family, "libelf, zstd and zlib")))
    linked = len([s for s in scheds if links.get("%s/scx_%s" % (_LINKDIR, s)) == "%s/scx_%s" % (bundled, s)]) == len(scheds)
    info = {}
    if ctx.file_exists(bundled + "/BUILD-INFO"):
        for line in ctx.file_read(bundled + "/BUILD-INFO").splitlines():
            k, _, v = line.partition("=")
            if k in ("commit", "rustc", "built"):
                info[k] = v
    before = dict(info, state = "built", linked = linked, source = "bundled")
    if linked:
        return _result(ctx, False, "bundled scx %s linked" % ver, before, before, ver, scheds, bundled, "", links)
    after = dict(before, linked = True)
    if ctx.check_mode:
        return _result(ctx, True, "would link the bundled scx %s" % ver, before, after, ver, scheds, bundled, "", links)
    _ok(ctx.run(["sh", "-c", _RELINK, "sh", _ROOT, bundled, _LINKDIR] + scheds, mutates = True), "linking")
    return _result(ctx, True, "linked the bundled scx %s (%s) — no build needed" % (ver, ", ".join(scheds)), before, after,
                   ver, scheds, bundled, "", links)


def _absent(ctx, ver, prefix, bundled, links, before):
    ours = [l for l, t in links.items() if t.startswith(prefix + "/") or t.startswith(bundled + "/")]
    if not ours and (before["state"] == "absent" or not ctx.file_exists(prefix)):
        return _result(ctx, False, "scx %s not installed" % ver, before, before, ver, [], prefix, "", links)
    # A scheduler yoloman.sched_ext runs from this build must be stopped first.
    unitf = "/etc/systemd/system/yoloman-sched-ext.service"
    if ctx.file_exists(unitf) and ctx.run(["systemctl", "is-active", "--quiet", "yoloman-sched-ext.service"]).rc == 0:
        for line in ctx.file_read(unitf).splitlines():
            if line.startswith("ExecStart="):
                b = line[len("ExecStart="):].split(" ")[0]
                if b.startswith(prefix + "/") or links.get(b, "").startswith(prefix + "/"):
                    fail("conflict: yoloman.sched_ext runs %s from scx %s; stop it first (yoloman.sched_ext state=disabled)" % (b, ver))
    if ctx.check_mode:
        return _result(ctx, True, "would remove scx %s" % ver, before, {"state": "absent", "linked": False}, ver, [], prefix, "", links)
    ctx.run(["rm", "-f"] + ours, mutates = True)
    ctx.run(["rm", "-rf", prefix], mutates = True)
    return _result(ctx, True, "removed scx %s" % ver, before, {"state": "absent", "linked": False}, ver, [], prefix, "", links)


def _all_in(s, chars):
    for i in range(len(s)):
        if s[i] not in chars:
            return False
    return True


def _links(ctx):
    out = {}
    r = ctx.run(["sh", "-c", _LINKS, "sh", _LINKDIR])
    for line in r.stdout.splitlines():
        parts = line.strip().split(" ")
        if len(parts) == 2 and (parts[1].startswith(_ROOT + "/") or parts[1].startswith(_BUNDLED + "/")):
            out[parts[0]] = parts[1]
    return out


def _unit_state(ctx, unit):
    r = ctx.run(["systemctl", "show", "-p", "ActiveState", "-p", "SubState", "-p", "ExecMainStatus", unit])
    kv = {}
    for line in r.stdout.splitlines():
        k, _, v = line.partition("=")
        kv[k.strip()] = v.strip()
    return kv


# built | building | failed | absent, from the files and the build unit.
def _state(ctx, prefix, scheds, links, unit):
    have = [s for s in scheds if ctx.file_exists("%s/bin/scx_%s" % (prefix, s))]
    linked = len(scheds) > 0
    for s in scheds:
        if links.get("%s/scx_%s" % (_LINKDIR, s)) != "%s/bin/scx_%s" % (prefix, s):
            linked = False
    u = _unit_state(ctx, unit)
    if u.get("ActiveState") in ("active", "activating") and u.get("SubState") not in ("exited", ""):
        return {"state": "building", "linked": False}
    if u.get("ActiveState") == "failed" or (u.get("SubState") == "exited" and u.get("ExecMainStatus", "0") not in ("0", "")):
        return {"state": "failed", "linked": False, "exit": u.get("ExecMainStatus", "?")}
    if len(have) == len(scheds) and scheds:
        out = {"state": "built", "linked": linked}
        info = "%s/bin/BUILD-INFO" % prefix
        if ctx.file_exists(info):
            for line in ctx.file_read(info).splitlines():
                k, _, v = line.partition("=")
                if k in ("commit", "rustc", "built"):
                    out[k] = v
        return out
    return {"state": "absent", "linked": False}


def _free_mb(ctx, path):
    r = ctx.run(["df", "-Pk", path])
    lines = r.stdout.strip().splitlines()
    if r.rc != 0 or len(lines) < 2:
        return -1
    cols = lines[-1].split()
    return int(cols[3]) // 1024 if len(cols) > 3 and cols[3].isdigit() else -1


def _log_tail(ctx, unit):
    f = "/run/%s.log" % unit
    if not ctx.file_exists(f):
        return "(no build log)"
    lines = ctx.file_read(f).strip().splitlines()
    return "\n".join(lines[-15:])


def _ok(r, what):
    if not r.skipped and r.rc != 0:
        fail("%s failed: %s" % (what, r.stderr))


def _result(ctx, changed, msg, before, after, ver, scheds, prefix, unit, links):
    prev, prev_root = "", ""
    for t in links.values():
        prev_root = _BUNDLED if t.startswith(_BUNDLED + "/") else _ROOT
        prev = t[len(prev_root) + 1:].split("/")[0]
        break
    here = _BUNDLED if prefix.startswith(_BUNDLED) else _ROOT
    if prev and (prev != ver or prev_root != here):
        prev_scheds = sorted([l.rsplit("/scx_", 1)[-1] for l, t in links.items() if t.startswith("%s/%s/" % (prev_root, prev))])
        rollback = {"state": "present", "version": prev, "schedulers": prev_scheds,
                    "source": "bundled" if prev_root == _BUNDLED else "upstream"}
    elif before.get("state") == "built" and before.get("linked"):
        rollback = {"state": "present", "version": ver, "schedulers": scheds}
    else:
        rollback = {"state": "absent", "version": ver}
    data = {
        "tool": "scx",
        "version": ver,
        "schedulers": scheds,
        "prefix": prefix,
        "binaries": {s: "%s/scx_%s" % (_LINKDIR, s) for s in scheds},
        "before": before,
        "after": after,
        "persistence": "persistent",
        "backend": "%s/<version>/bin, linked from %s" % (_ROOT, _LINKDIR),
        "rollback": rollback,
    }
    if unit:
        data["build_unit"] = unit
        data["build_log"] = "/run/%s.log" % unit
    return {"changed": changed, "msg": msg, "data": data}
