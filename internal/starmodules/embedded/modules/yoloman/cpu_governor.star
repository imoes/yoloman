# yoloman.cpu_governor — CPU frequency governor as a kernel-tuning tunable.
#
# Live value: /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor (and
# energy_performance_preference). sysfs cannot be written atomically (rename
# into sysfs fails), so values are written with `sh -c 'printf'`, with the
# value and the paths passed as positional arguments, never spliced into the
# script.
#
# Persistence by init system (ctx.facts().kernel_caps.init_system):
#   systemd → /etc/tmpfiles.d/yoloman-cpufreq.conf  ("w" lines accept globs)
#   openrc  → /etc/local.d/yoloman-cpufreq.start    (run by the "local" service)
# Anything else is "unsupported:" for persistent=true.

_CPU = "/sys/devices/system/cpu"
_TMPFILES = "/etc/tmpfiles.d/yoloman-cpufreq.conf"
_LOCALD = "/etc/local.d/yoloman-cpufreq.start"
_WRITE = 'v=$1; shift; for f in "$@"; do printf "%s" "$v" > "$f" || exit 1; done'


def main(ctx, params):
    state = params.get("state", "present")
    persistent = params.get("persistent", True)
    governor = params.get("governor")
    epp = params.get("energy_performance_preference")
    facts = ctx.facts()
    init = _init_system(facts)
    target = _persist_path(init)

    had_file = target != None and ctx.file_exists(target)
    removed = False
    if state == "absent":
        # Remove yoloman's persistence; values given alongside are set live (that is what a rollback
        # of a first, persistent change looks like: no file before, the old values running).
        if had_file:
            rm = ctx.run(["rm", "-f", target], mutates = True)
            if not rm.skipped and rm.rc != 0:
                fail("removing %s failed: %s" % (target, rm.stderr))
            removed = True
        if governor == None and epp == None:
            return {"changed": removed, "msg": (("would remove " if ctx.check_mode else "removed ") + target) if removed else "no yoloman cpufreq persistence file",
                    "data": {"tunable": "cpu_governor", "persistence": "live", "backend": target}}
        persistent = False

    if governor == None and epp == None:
        fail("governor or energy_performance_preference is required")
    # Refuse BEFORE touching anything: a live change followed by a failed persist is a half-applied state.
    if persistent and target == None:
        fail("unsupported: no persistence path for init system %s" % init)
    cpus = _cpus(ctx)
    if not cpus:
        fail("unsupported: no cpufreq driver (%s/cpu0/cpufreq missing; typical for a VM)" % _CPU)

    before = {}
    after = {}
    changed = removed
    for attr, want, avail_file in [
        ("scaling_governor", governor, "scaling_available_governors"),
        ("energy_performance_preference", epp, "energy_performance_available_preferences"),
    ]:
        if want == None:
            continue
        avail_path = "%s/%s/cpufreq/%s" % (_CPU, cpus[0], avail_file)
        if ctx.file_exists(avail_path):
            avail = ctx.file_read(avail_path).split()
            if want not in avail:
                fail("unsupported: %s=%s not offered by this driver (available: %s)" % (attr, want, " ".join(avail)))
        paths = ["%s/%s/cpufreq/%s" % (_CPU, c, attr) for c in cpus]
        if not ctx.file_exists(paths[0]):
            fail("unsupported: %s missing (the cpufreq driver does not expose it)" % paths[0])
        values = {}
        stale = []
        for p in paths:
            v = ctx.file_read(p).strip()
            values[v] = values.get(v, 0) + 1
            if v != want:
                stale.append(p)
        before[attr] = values
        after[attr] = {want: len(paths)}
        if stale:
            changed = True
            w = ctx.run(["sh", "-c", _WRITE, "sh", want] + stale, mutates=True)
            if not w.skipped and w.rc != 0:
                fail("writing %s=%s failed: %s" % (attr, want, w.stderr))

    persistence = "live"
    persisted_differs = False
    if had_file and not removed:
        persisted_differs = ctx.file_read(target) != _persist_content(init, governor, epp)
    if persistent:
        if ctx.file_write(target, _persist_content(init, governor, epp), mode = "0755" if init == "openrc" else "0644"):
            changed = True
        persistence = "persistent"
        persisted_differs = False

    # One call restores the state before this one: the old values, and the persistence file only if it existed.
    rollback = {"persistent": True} if had_file else {"state": "absent"}
    for attr, key in [("scaling_governor", "governor"), ("energy_performance_preference", "energy_performance_preference")]:
        vals = before.get(attr)
        if vals and len(vals) == 1:
            rollback[key] = list(vals.keys())[0]
    data = {
        "tunable": "cpu_governor",
        "target": "%d CPUs" % len(cpus),
        "before": before,
        "after": after,
        "persistence": persistence,
        "backend": target if persistent else "sysfs",
        "rollback": rollback,
    }
    if persisted_differs:
        data["persisted_differs"] = target + " holds other values; they apply again at the next boot"
    if not changed:
        return {"changed": False, "msg": "cpufreq already as requested", "data": data}
    return {"changed": True, "msg": ("would set " if ctx.check_mode else "set ") + _describe(governor, epp), "data": data}


def _init_system(facts):
    kc = facts.get("kernel_caps") or {}
    return (kc.get("init_system") or {}).get("state", "unknown")


def _persist_path(init):
    if init == "systemd":
        return _TMPFILES
    if init == "openrc":
        return _LOCALD
    return None


def _persist_content(init, governor, epp):
    lines = ["# Managed by yoloman.cpu_governor (docs/kernel-tuning.md). Remove with state=absent."]
    pairs = []
    if governor != None:
        pairs.append(("scaling_governor", governor))
    if epp != None:
        pairs.append(("energy_performance_preference", epp))
    if init == "openrc":
        lines = ["#!/bin/sh"] + lines
        for attr, v in pairs:
            lines.append('for f in %s/cpu[0-9]*/cpufreq/%s; do [ -w "$f" ] && printf "%%s" "%s" > "$f"; done' % (_CPU, attr, v))
    else:
        for attr, v in pairs:
            lines.append("w %s/cpu*/cpufreq/%s - - - - %s" % (_CPU, attr, v))
    return "\n".join(lines) + "\n"


def _cpus(ctx):
    ls = ctx.run(["ls", _CPU])
    if ls.rc != 0:
        return []
    out = []
    for name in ls.stdout.split():
        if name.startswith("cpu") and name[3:].isdigit() and ctx.file_exists("%s/%s/cpufreq/scaling_governor" % (_CPU, name)):
            out.append(name)
    return sorted(out, key = _cpu_index)


def _cpu_index(name):
    return int(name[3:])


def _describe(governor, epp):
    parts = []
    if governor != None:
        parts.append("governor=" + governor)
    if epp != None:
        parts.append("epp=" + epp)
    return ", ".join(parts)
