# yoloman.systemd_resource — cgroup resource limits of one systemd unit.
#
# Live: `systemctl set-property --runtime` (lost at reboot).
# Persistent: yoloman's own drop-in + daemon-reload. systemd's
# `set-property` without --runtime would write into system.control/, which
# other tools also use; a separate file keeps "remove what yoloman set"
# exact.
#
# Comparison uses systemd's own reporting (`systemctl show`), normalised:
# sizes → bytes, CPUQuota → microseconds per second, "[not set]" → "".

_PROPS = {
    "CPUWeight": "int",
    "StartupCPUWeight": "int",
    "IOWeight": "int",
    "TasksMax": "count",
    "CPUQuota": "quota",
    "MemoryMax": "size",
    "MemoryHigh": "size",
    "MemoryLow": "size",
    "MemorySwapMax": "size",
    "AllowedCPUs": "str",
    "AllowedMemoryNodes": "str",
}
_SECTION = {"service": "Service", "slice": "Slice", "socket": "Socket", "mount": "Mount", "swap": "Swap"}
_UNIT_CHARS = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789:_.@-\\"


def main(ctx, params):
    unit = params.get("unit", "")
    if not unit or not _all_in(unit, _UNIT_CHARS):
        fail("unit must be a systemd unit name, got %r" % unit)
    if "." not in unit:
        unit = unit + ".service"
    suffix = unit.rsplit(".", 1)[1]
    state = params.get("state", "present")
    persistent = params.get("persistent", True)
    init = ((ctx.facts().get("kernel_caps") or {}).get("init_system") or {}).get("state", "unknown")
    if init != "systemd":
        fail("unsupported: systemd_resource needs systemd, init system is %s" % init)
    dropin = "/etc/systemd/system/%s.d/90-yoloman-resource.conf" % unit

    props = params.get("properties") or {}
    had_dropin = ctx.file_exists(dropin)
    removed = False
    if state == "absent":
        # Remove yoloman's drop-in; properties given alongside are set live (a rollback of a first,
        # persistent change: no drop-in before, the old values running).
        if had_dropin:
            rm = ctx.run(["rm", "-f", dropin], mutates = True)
            if not rm.skipped:
                if rm.rc != 0:
                    fail("removing %s failed: %s" % (dropin, rm.stderr))
                # The directory goes too when yoloman's file was its only content.
                ctx.run(["rmdir", "--ignore-fail-on-non-empty", dropin.rsplit("/", 1)[0]], mutates = True)
                _daemon_reload(ctx)
            removed = True
        if not props:
            return {"changed": removed, "msg": (("would remove " if ctx.check_mode else "removed ") + dropin) if removed else "no yoloman drop-in for " + unit,
                    "data": {"tunable": "systemd_resource", "target": unit, "persistence": "live", "backend": dropin}}
        persistent = False
    if not props:
        fail("properties is required")
    for k in props:
        if k not in _PROPS:
            fail("property %s not supported (allowed: %s)" % (k, ", ".join(sorted(_PROPS.keys()))))
        v = str(props[k])
        # "" is valid: systemd's empty assignment resets the property to its default
        # (the rollback of a property that was "[not set]").
        if "\n" in v or " " in v:
            fail("property %s has an invalid value %r" % (k, v))
    if persistent and suffix not in _SECTION:
        fail("unsupported: a .%s unit cannot carry a persistent drop-in (use persistent: false)" % suffix)

    loaded = _show(ctx, unit, ["LoadState"])
    if loaded.get("LoadState") != "loaded":
        fail("unit %s is not loaded (LoadState=%s)" % (unit, loaded.get("LoadState", "")))
    show_keys = [_show_key(k) for k in sorted(props.keys())]
    cur = _show(ctx, unit, show_keys)

    before = {}
    after = {}
    stale = []
    for k in sorted(props.keys()):
        want = str(props[k])
        have = cur.get(_show_key(k), "")
        before[k] = have
        after[k] = want
        if _norm(_PROPS[k], want, True) != _norm(_PROPS[k], have, False):
            stale.append("%s=%s" % (k, want))

    changed = removed
    if persistent and not ctx.check_mode and not ctx.file_exists(dropin.rsplit("/", 1)[0]):
        # Before any change: file_write does not create directories, and a live change followed by a
        # failed drop-in write would leave the unit half-configured.
        md = ctx.run(["mkdir", "-p", dropin.rsplit("/", 1)[0]], mutates = True)
        if md.rc != 0:
            fail("creating %s failed: %s" % (dropin.rsplit("/", 1)[0], md.stderr))
    if stale:
        changed = True
        sp = ctx.run(["systemctl", "set-property", "--runtime", unit] + stale, mutates = True)
        if not sp.skipped and sp.rc != 0:
            fail("set-property %s failed: %s" % (unit, sp.stderr))
    data = {
        "tunable": "systemd_resource",
        "target": unit,
        "before": before,
        "after": after,
        "persistence": "live",
        "backend": "systemctl set-property --runtime",
        # One call restores the state before this one: old values, and the drop-in only if it existed.
        "rollback": {"unit": unit, "properties": _rollback_props(before), "persistent": True} if had_dropin else {"unit": unit, "properties": _rollback_props(before), "state": "absent"},
    }
    if persistent:
        lines = ["# Managed by yoloman.systemd_resource (docs/kernel-tuning.md). Remove with state=absent.",
                 "[%s]" % _SECTION[suffix]]
        for k in sorted(props.keys()):
            lines.append("%s=%s" % (k, props[k]))
        if ctx.file_write(dropin, "\n".join(lines) + "\n", mode = "0644"):
            changed = True
            if not ctx.check_mode:
                _daemon_reload(ctx)
        data["persistence"] = "persistent"
        data["backend"] = dropin
    if not ctx.check_mode and stale:
        now = _show(ctx, unit, show_keys)
        data["after"] = {k: now.get(_show_key(k), "") for k in sorted(props.keys())}
    if not changed:
        return {"changed": False, "msg": unit + " limits already as requested", "data": data}
    return {"changed": True, "msg": ("would set " if ctx.check_mode else "set ") + ", ".join(stale or ["drop-in"]) + " on " + unit, "data": data}


def _all_in(s, chars):
    for i in range(len(s)):
        if s[i] not in chars:
            return False
    return True


def _daemon_reload(ctx):
    r = ctx.run(["systemctl", "daemon-reload"], mutates = True)
    if not r.skipped and r.rc != 0:
        fail("systemctl daemon-reload failed: %s" % r.stderr)


def _show_key(k):
    return "CPUQuotaPerSecUSec" if k == "CPUQuota" else k


def _show(ctx, unit, keys):
    r = ctx.run(["systemctl", "show", "-p", ",".join(keys), unit])
    if r.rc != 0:
        fail("systemctl show %s failed: %s" % (unit, r.stderr))
    out = {}
    for line in r.stdout.splitlines():
        k, _, v = line.partition("=")
        out[k] = "" if v == "[not set]" else v
    return out


# Back from systemd's reporting to settable values for the rollback.
def _rollback_props(before):
    out = {}
    for k in before:
        v = before[k]
        if k == "CPUQuota":
            us = _timespan_us(v)
            v = "" if us == None else "%d%%" % (us // 10000)
        out[k] = v
    return out


def _norm(kind, v, desired):
    v = v.strip()
    if kind == "str":
        return v
    if v == "" or v == "infinity" or v == "max":
        return "infinity" if v != "" else ""
    if kind == "int":
        return v
    if kind == "count":
        return v
    if kind == "size":
        mult = {"K": 1024, "M": 1024 * 1024, "G": 1024 * 1024 * 1024, "T": 1024 * 1024 * 1024 * 1024}
        last = v[-1].upper()
        if last in mult and v[:-1].isdigit():
            return str(int(v[:-1]) * mult[last])
        return v
    if kind == "quota":
        if desired and v.endswith("%") and v[:-1].isdigit():
            return str(int(v[:-1]) * 10000)
        us = _timespan_us(v)
        return v if us == None else str(us)
    return v


# systemd timespans as printed by `systemctl show`: "500ms", "1s", "1.500000s", "2min".
def _timespan_us(v):
    if v == "" or v == "infinity":
        return None
    for unit, factor in [("us", 1), ("ms", 1000), ("min", 60000000), ("s", 1000000)]:
        if v.endswith(unit):
            num = v[:-len(unit)]
            whole, _, frac = num.partition(".")
            if not whole.isdigit() or (frac and not frac.isdigit()):
                return None
            us = int(whole) * factor
            if frac:
                us = us + int(frac) * factor // _pow10(len(frac))
            return us
    return None


def _pow10(n):
    r = 1
    for _ in range(n):
        r = r * 10
    return r
