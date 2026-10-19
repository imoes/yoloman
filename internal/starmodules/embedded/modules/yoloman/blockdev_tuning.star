# yoloman.blockdev_tuning — readahead and I/O scheduler as kernel-tuning tunables.
#
# Live: /sys/block/<dev>/queue/{read_ahead_kb,scheduler}, written with
# `sh -c 'printf'` (sysfs cannot take an atomic rename); value and path are
# positional arguments, never part of the script.
#
# Persistent: a udev rule matching the device by its stable identity. A
# kernel name like sdb can move to another disk after a reboot; when nothing
# stabler exists the rule uses it and the result says so ("match_stable": false).

_WRITE = 'v=$1; shift; for f in "$@"; do printf "%s" "$v" > "$f" || exit 1; done'


def main(ctx, params):
    dev = params.get("device", "")
    if dev.startswith("/dev/"):
        dev = dev[len("/dev/"):]
    if not _safe_name(dev):
        fail("device must be a kernel block device name ([a-z0-9]), got %r" % params.get("device"))
    state = params.get("state", "present")
    persistent = params.get("persistent", True)
    queue = "/sys/block/%s/queue" % dev
    if not ctx.file_exists(queue):
        fail("unsupported: %s missing (no such block device)" % queue)
    backend = _backend(ctx)
    rule = _rule_path(backend, dev)

    ra = params.get("read_ahead_kb")
    sched = params.get("scheduler")
    had_rule = rule != None and ctx.file_exists(rule)
    removed = False
    if state == "absent":
        # Remove yoloman's rule; values given alongside are set live (a rollback of a first,
        # persistent change: no rule before, the old values running).
        if had_rule:
            rm = ctx.run(["rm", "-f", rule], mutates = True)
            if not rm.skipped and rm.rc != 0:
                fail("removing %s failed: %s" % (rule, rm.stderr))
            removed = True
        if ra == None and sched == None:
            return {"changed": removed, "msg": (("would remove " if ctx.check_mode else "removed ") + rule) if removed else "no yoloman rule for " + dev,
                    "data": {"tunable": "blockdev_tuning", "target": dev, "persistence": "live", "backend": rule}}
        persistent = False
    if ra == None and sched == None:
        fail("read_ahead_kb or scheduler is required")
    if ra != None and (int(ra) < 0 or int(ra) > 65536):
        fail("read_ahead_kb must be within 0..65536, got %s" % ra)
    if persistent and rule == None:
        fail("unsupported: neither udevadm nor OpenRC local.d available for a persistent setting")

    before = {}
    after = {}
    changed = removed
    if ra != None:
        cur = ctx.file_read(queue + "/read_ahead_kb").strip()
        before["read_ahead_kb"] = int(cur)
        after["read_ahead_kb"] = int(ra)
        if cur != str(int(ra)):
            changed = True
            _write(ctx, str(int(ra)), queue + "/read_ahead_kb")
    if sched != None:
        offered, cur = _schedulers(ctx.file_read(queue + "/scheduler"))
        if sched not in offered:
            fail("unsupported: scheduler %s not offered by %s (available: %s)" % (sched, dev, " ".join(offered)))
        before["scheduler"] = cur
        after["scheduler"] = sched
        if cur != sched:
            changed = True
            _write(ctx, sched, queue + "/scheduler")

    data = {
        "tunable": "blockdev_tuning",
        "target": dev,
        "before": before,
        "after": after,
        "persistence": "live",
        "backend": "sysfs",
        # One call restores the state before this one: old values, and the rule only if it existed.
        "rollback": dict(before, device = dev, persistent = True) if had_rule else dict(before, device = dev, state = "absent"),
    }
    if persistent:
        match, stable = _match(ctx, backend, dev)
        content = _rule_content(backend, dev, match, ra, sched)
        if ctx.file_write(rule, content, mode = "0755" if backend == "openrc" else "0644"):
            changed = True
        data["persistence"] = "persistent"
        data["backend"] = rule
        data["match"] = match
        data["match_stable"] = stable
    if not changed:
        return {"changed": False, "msg": dev + " already as requested", "data": data}
    return {"changed": True, "msg": ("would tune " if ctx.check_mode else "tuned ") + dev, "data": data}


def _safe_name(name):
    if not name:
        return False
    for i in range(len(name)):
        if name[i] not in "abcdefghijklmnopqrstuvwxyz0123456789":
            return False
    return True


def _write(ctx, value, path):
    w = ctx.run(["sh", "-c", _WRITE, "sh", value, path], mutates = True)
    if not w.skipped and w.rc != 0:
        fail("writing %s=%s failed: %s" % (path, value, w.stderr))


def _schedulers(line):
    offered = []
    cur = ""
    for tok in line.split():
        if tok.startswith("[") and tok.endswith("]"):
            tok = tok[1:-1]
            cur = tok
        offered.append(tok)
    return offered, cur


def _backend(ctx):
    if ctx.run(["sh", "-c", "command -v udevadm"]).rc == 0:
        return "udev"
    init = ((ctx.facts().get("kernel_caps") or {}).get("init_system") or {}).get("state")
    if init == "openrc":
        return "openrc"
    return None


def _rule_path(backend, dev):
    if backend == "udev":
        return "/etc/udev/rules.d/60-yoloman-blockdev-%s.rules" % dev
    if backend == "openrc":
        return "/etc/local.d/yoloman-blockdev-%s.start" % dev
    return None


def _match(ctx, backend, dev):
    if backend != "udev":
        return 'KERNEL=="%s"' % dev, False
    info = ctx.run(["udevadm", "info", "--query=property", "--name=/dev/" + dev])
    props = {}
    if info.rc == 0:
        for line in info.stdout.splitlines():
            k, _, v = line.partition("=")
            props[k] = v
    for key in ["ID_WWN", "ID_SERIAL"]:
        v = props.get(key, "")
        if v and '"' not in v:
            return 'ENV{%s}=="%s"' % (key, v), True
    return 'KERNEL=="%s"' % dev, False


def _rule_content(backend, dev, match, ra, sched):
    head = "# Managed by yoloman.blockdev_tuning for %s (docs/kernel-tuning.md). Remove with state=absent." % dev
    if backend == "openrc":
        lines = ["#!/bin/sh", head]
        if ra != None:
            lines.append("printf %%s %d > /sys/block/%s/queue/read_ahead_kb" % (int(ra), dev))
        if sched != None:
            lines.append("printf %%s %s > /sys/block/%s/queue/scheduler" % (sched, dev))
        return "\n".join(lines) + "\n"
    attrs = []
    if ra != None:
        attrs.append('ATTR{queue/read_ahead_kb}="%d"' % int(ra))
    if sched != None:
        attrs.append('ATTR{queue/scheduler}="%s"' % sched)
    rule = 'ACTION=="add|change", SUBSYSTEM=="block", ENV{DEVTYPE}=="disk", %s, %s' % (match, ", ".join(attrs))
    return head + "\n" + rule + "\n"
