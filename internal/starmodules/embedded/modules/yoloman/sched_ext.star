# yoloman.sched_ext — a BPF CPU scheduler as a kernel-tuning tunable.
#
# The model never writes scheduler code (docs/kernel-tuning.md); it picks an
# existing scx scheduler and its arguments. The kernel verifies the BPF
# program when it loads, and its sched_ext watchdog ejects a scheduler that
# stalls tasks — the fair class (EEVDF) then takes over without help.
#
# yoloman runs the scheduler as ITS OWN service so that "stop what yoloman
# started" is exact. A sched_ext scheduler someone else started (the
# distribution's scx.service, scx_loader) is reported as a conflict, never
# stopped. No automatic restart: an ejected scheduler must stay visible as
# off, not flap.

_STATE = "/sys/kernel/sched_ext/state"
_OPS = "/sys/kernel/sched_ext/root/ops"
_UNIT = "yoloman-sched-ext.service"
_UNIT_FILE = "/etc/systemd/system/yoloman-sched-ext.service"
_RC = "yoloman-sched-ext"
_RC_FILE = "/etc/init.d/yoloman-sched-ext"
_ARG_CHARS = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789=,._:/-"
_NAME_CHARS = "abcdefghijklmnopqrstuvwxyz0123456789_"
_WAIT = 'until [ "$(cat /sys/kernel/sched_ext/state)" = "$1" ]; do sleep 0.2; done'


def main(ctx, params):
    want = params.get("state", "enabled")
    persistent = params.get("persistent", True)
    wait = int(params.get("wait", 10))
    kc = ctx.facts().get("kernel_caps") or {}
    sx = kc.get("sched_ext") or {}
    if sx.get("state") in (None, "unsupported", "unknown"):
        fail("unsupported: sched_ext is %s (%s)" % (sx.get("state", "unknown"), sx.get("reason", "no kernel_caps")))
    init = (kc.get("init_system") or {}).get("state", "unknown")
    if init not in ("systemd", "openrc"):
        fail("unsupported: no service backend for init system %s" % init)

    before = _kernel(ctx)
    ours_active = _active(ctx, init)
    before["yoloman_service"] = "active" if ours_active else "inactive"
    prev = _configured(ctx, init)

    if want == "disabled":
        if not ours_active:
            if before["state"] == "enabled":
                fail("conflict: sched_ext runs %s, which yoloman did not start; stop it where it was started (scx.service, scx_loader)" % before.get("ops", "?"))
            disabled = _set_boot(ctx, init, False)
            return _result(ctx, disabled, "sched_ext already off", before, before, init, prev, "live")
        stop = _svc(ctx, init, "stop")
        if stop.skipped:
            return _result(ctx, True, "would stop " + prev.get("scheduler", "?"), before, {"state": "disabled"}, init, prev, "persistent")
        _set_boot(ctx, init, False)
        _wait_state(ctx, "disabled", wait)
        return _result(ctx, True, "stopped %s; tasks are back in the fair class" % prev.get("scheduler", "?"), before, _kernel(ctx), init, prev, "persistent")

    sched = params.get("scheduler", "")
    if not sched or not _all_in(sched, _NAME_CHARS):
        fail("scheduler is required ([a-z0-9_], without the scx_ prefix), got %r" % sched)
    args = [str(a) for a in (params.get("args") or [])]
    for a in args:
        if not a or not _all_in(a, _ARG_CHARS):
            fail("argument %r has characters outside [A-Za-z0-9=,._:/-]" % a)
    if (kc.get("btf") or {}).get("state") != "present":
        fail("unsupported: BTF is %s; scx schedulers are CO-RE programs and need /sys/kernel/btf/vmlinux" % (kc.get("btf") or {}).get("state", "unknown"))
    which = ctx.run(["sh", "-c", 'command -v "scx_$1"', "sh", sched])
    if which.rc != 0 or not which.stdout.strip():
        fail("tool_unavailable: scx_%s is not installed (install the distribution's scx / scx-scheds package, or build it from upstream with yoloman.scx_install)" % sched)
    binary = which.stdout.strip()
    if before["state"] == "enabled" and not ours_active:
        fail("conflict: sched_ext already runs %s, which yoloman did not start" % before.get("ops", "?"))

    content = _unit_content(init, binary, args)
    path = _UNIT_FILE if init == "systemd" else _RC_FILE
    file_changed = ctx.file_write(path, content, mode = "0644" if init == "systemd" else "0755")
    if not file_changed and ours_active and before["state"] == "enabled":
        # Same scheduler, same args, attached: only boot persistence can differ.
        boot_changed = _set_boot(ctx, init, persistent)
        return _result(ctx, boot_changed, "scx_%s already running" % sched, before, before, init, prev, "persistent" if persistent else "live")
    if ctx.check_mode:
        return _result(ctx, True, "would start scx_%s" % sched, before, {"state": "enabled", "ops": sched + "*"}, init, prev, "persistent" if persistent else "live")

    if init == "systemd":
        _ok(ctx.run(["systemctl", "daemon-reload"], mutates = True), "daemon-reload")
    _ok(_svc(ctx, init, "restart"), "starting scx_" + sched)
    if not _wait_state(ctx, "enabled", wait):
        log = _log(ctx, init)
        _svc(ctx, init, "stop")
        _set_boot(ctx, init, False)
        fail("scx_%s did not attach within %ds (sched_ext state %s); stopped it again. Last log lines:\n%s" % (sched, wait, _kernel(ctx)["state"], log))
    if persistent:
        _set_boot(ctx, init, True)
    return _result(ctx, True, "scx_%s attached" % sched, before, _kernel(ctx), init, prev, "persistent" if persistent else "live")


def _all_in(s, chars):
    for i in range(len(s)):
        if s[i] not in chars:
            return False
    return True


def _kernel(ctx):
    out = {"state": ctx.file_read(_STATE).strip()}
    if ctx.file_exists(_OPS):
        out["ops"] = ctx.file_read(_OPS).strip()
    return out


def _active(ctx, init):
    if init == "systemd":
        return ctx.run(["systemctl", "is-active", "--quiet", _UNIT]).rc == 0
    return ctx.run(["rc-service", _RC, "status"]).rc == 0


def _svc(ctx, init, verb):
    if init == "systemd":
        return ctx.run(["systemctl", verb, _UNIT], mutates = True)
    return ctx.run(["rc-service", _RC, verb], mutates = True)


# Boot persistence; returns whether it changed (predicted in check mode).
def _set_boot(ctx, init, on):
    if init == "systemd":
        if not ctx.file_exists(_UNIT_FILE):
            return False
        enabled = ctx.run(["systemctl", "is-enabled", "--quiet", _UNIT]).rc == 0
        if enabled == on:
            return False
        r = ctx.run(["systemctl", "enable" if on else "disable", _UNIT], mutates = True)
    else:
        if not ctx.file_exists(_RC_FILE):
            return False
        enabled = ctx.file_exists("/etc/runlevels/default/" + _RC)
        if enabled == on:
            return False
        r = ctx.run(["rc-update", "add" if on else "del", _RC, "default"], mutates = True)
    if not r.skipped and r.rc != 0:
        fail("changing boot persistence failed: %s" % r.stderr)
    return True


# The scheduler and args yoloman configured last, read back from its own service file.
def _configured(ctx, init):
    path = _UNIT_FILE if init == "systemd" else _RC_FILE
    if not ctx.file_exists(path):
        return {}
    for line in ctx.file_read(path).splitlines():
        line = line.strip()
        cmd = ""
        if line.startswith("ExecStart="):
            cmd = line[len("ExecStart="):]
        elif line.startswith("command=") or line.startswith("command_args="):
            continue
        elif line.startswith("# yoloman-cmd: "):
            cmd = line[len("# yoloman-cmd: "):]
        if cmd:
            parts = cmd.split()
            name = parts[0].rsplit("/", 1)[-1]
            if name.startswith("scx_"):
                name = name[len("scx_"):]
            return {"scheduler": name, "args": parts[1:]}
    return {}


def _unit_content(init, binary, args):
    cmd = " ".join([binary] + args)
    if init == "systemd":
        return "\n".join([
            "# Managed by yoloman.sched_ext (docs/kernel-tuning.md). No Restart=: an ejected scheduler stays off.",
            "[Unit]",
            "Description=yoloman sched_ext scheduler (%s)" % binary.rsplit("/", 1)[-1],
            "ConditionPathExists=/sys/kernel/sched_ext/state",
            "",
            "[Service]",
            "Type=simple",
            "ExecStart=" + cmd,
            "",
            "[Install]",
            "WantedBy=multi-user.target",
        ]) + "\n"
    return "\n".join([
        "#!/sbin/openrc-run",
        "# Managed by yoloman.sched_ext (docs/kernel-tuning.md).",
        "# yoloman-cmd: " + cmd,
        'description="yoloman sched_ext scheduler"',
        'command="%s"' % binary,
        'command_args="%s"' % " ".join(args),
        "command_background=true",
        'pidfile="/run/yoloman-sched-ext.pid"',
    ]) + "\n"


def _wait_state(ctx, state, seconds):
    r = ctx.run(["timeout", str(seconds), "sh", "-c", _WAIT, "sh", state])
    return r.rc == 0


def _log(ctx, init):
    if init == "systemd":
        r = ctx.run(["journalctl", "-u", _UNIT, "-n", "15", "--no-pager", "-o", "cat"])
        return r.stdout.strip()
    return "(OpenRC: see the scheduler's output in /var/log/messages)"


def _ok(r, what):
    if not r.skipped and r.rc != 0:
        fail("%s failed: %s" % (what, r.stderr))


def _result(ctx, changed, msg, before, after, init, prev, persistence):
    if prev.get("scheduler") and before.get("yoloman_service") == "active":
        rollback = {"state": "enabled", "scheduler": prev["scheduler"], "args": prev.get("args", [])}
    else:
        rollback = {"state": "disabled"}
    return {"changed": changed, "msg": msg, "data": {
        "tunable": "sched_ext",
        "target": "cpu scheduler",
        "before": before,
        "after": after,
        "persistence": persistence,
        "backend": _UNIT_FILE if init == "systemd" else _RC_FILE,
        "fallback": "the kernel's fair class (EEVDF) whenever no BPF scheduler is attached",
        "rollback": rollback,
    }}
