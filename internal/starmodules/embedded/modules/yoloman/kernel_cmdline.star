# yoloman.kernel_cmdline — kernel command-line parameters for the next boot.
#
# The running command line cannot change; this module changes what the boot
# loader will pass next time and says so: persistence "pending_reboot" until
# /proc/cmdline agrees. One backend per host, chosen from facts, never two:
#   grubby                 when installed (Fedora/RHEL family; updates every kernel's BLS entry)
#   GRUB defaults + mkconfig  otherwise, when kernel_caps.boot_loader is grub
#   update-extlinux        Alpine (boot_loader extlinux)
# Anything else (systemd-boot, UKI, unknown) is refused with its reason.

_BAD = " \t\n\"'`$\\;|&<>()"


def main(ctx, params):
    add = [str(t) for t in (params.get("add") or [])]
    remove = [str(k) for k in (params.get("remove") or [])]
    if not add and not remove:
        fail("add or remove is required")
    for t in add + remove:
        if not t or _has_any(t, _BAD):
            fail("parameter %r contains whitespace, quotes or shell characters" % t)
    for k in remove:
        if "=" in k:
            fail("remove takes keys, not key=value: %r" % k)

    facts = ctx.facts()
    kc = facts.get("kernel_caps") or {}
    loader = kc.get("boot_loader") or {}
    live = ctx.file_read("/proc/cmdline").split() if ctx.file_exists("/proc/cmdline") else []

    if ctx.run(["sh", "-c", "command -v grubby"]).rc == 0:
        return _grubby(ctx, add, remove, live)
    state = loader.get("state", "unknown")
    if state == "grub":
        return _grub(ctx, facts, loader.get("evidence", ""), add, remove, live)
    if state == "extlinux":
        return _extlinux(ctx, add, remove, live)
    fail("unsupported: boot loader %s (%s); kernel_cmdline handles grubby, GRUB and extlinux" % (state, loader.get("evidence", "")))


def _has_any(s, chars):
    for i in range(len(s)):
        if s[i] in chars:
            return True
    return False


def _key(tok):
    return tok.split("=", 1)[0]


# The new token list plus the rollback that restores the old one.
def _apply(tokens, add, remove):
    out = list(tokens)
    undo_add = []
    undo_remove = []
    for k in remove:
        kept = []
        for t in out:
            if _key(t) == k:
                undo_add.append(t)
            else:
                kept.append(t)
        out = kept
    for t in add:
        k = _key(t)
        found = False
        nxt = []
        for o in out:
            if _key(o) == k:
                if not found:
                    nxt.append(t)
                    found = True
                    if o != t:
                        undo_add.append(o)
            else:
                nxt.append(o)
        if not found:
            nxt.append(t)
            undo_remove.append(k)
        out = nxt
    return out, {"add": undo_add, "remove": undo_remove}


def _persistence(live, add, remove):
    for t in add:
        if t not in live:
            return "pending_reboot"
    for k in remove:
        for t in live:
            if _key(t) == k:
                return "pending_reboot"
    return "persistent"


def _result(ctx, changed, backend, before, after, live, add, remove, rollback):
    return {"changed": changed,
            "msg": ("would change" if ctx.check_mode else "changed") + " the kernel command line for the next boot" if changed else "kernel command line already as requested",
            "data": {
                "tunable": "kernel_cmdline",
                "target": "next boot",
                "before": {"configured": before, "live": live},
                "after": {"configured": after},
                "persistence": _persistence(live, add, remove),
                "backend": backend,
                "rollback": rollback,
            }}


def _grubby(ctx, add, remove, live):
    info = ctx.run(["grubby", "--info=DEFAULT"])
    if info.rc != 0:
        fail("grubby --info=DEFAULT failed: %s" % info.stderr)
    before = []
    for line in info.stdout.splitlines():
        if line.startswith("args="):
            before = line[len("args="):].strip().strip('"').split()
    after, rollback = _apply(before, add, remove)
    if after == before:
        return _result(ctx, False, "grubby", before, after, live, add, remove, rollback)
    argv = ["grubby", "--update-kernel=ALL"]
    if add:
        argv.append("--args=" + " ".join(add))
    if remove:
        argv.append("--remove-args=" + " ".join(remove))
    r = ctx.run(argv, mutates = True)
    if not r.skipped and r.rc != 0:
        fail("grubby failed: %s" % r.stderr)
    return _result(ctx, True, "grubby --update-kernel=ALL", before, after, live, add, remove, rollback)


# GRUB: edit the file that really defines each variable. Debian's grub-mkconfig
# sources /etc/default/grub.d/*.cfg after /etc/default/grub, so the last
# assignment wins; other distributions read /etc/default/grub only.
def _grub(ctx, facts, grub_cfg, add, remove, live):
    files = ["/etc/default/grub"]
    if facts.get("os_family") == "debian":
        ls = ctx.run(["ls", "/etc/default/grub.d"])
        if ls.rc == 0:
            files = files + sorted(["/etc/default/grub.d/" + n for n in ls.stdout.split() if n.endswith(".cfg")])
    contents = {}
    for f in files:
        if ctx.file_exists(f):
            contents[f] = ctx.file_read(f)
    if "/etc/default/grub" not in contents:
        fail("unsupported: /etc/default/grub missing although the boot loader is grub (%s)" % grub_cfg)

    defs = {}
    for var in ["GRUB_CMDLINE_LINUX", "GRUB_CMDLINE_LINUX_DEFAULT"]:
        where = None
        for f in files:
            if f in contents and _find(contents[f], var) != None:
                where = f
        if where != None:
            val = _find(contents[where], var)
            if _has_any(val, "$`\\"):
                fail("unsupported: %s in %s is computed by the shell (%s); edit it by hand" % (var, where, val))
            defs[var] = (where, val.split())
        else:
            defs[var] = ("/etc/default/grub", [])

    before = defs["GRUB_CMDLINE_LINUX"][1] + defs["GRUB_CMDLINE_LINUX_DEFAULT"][1]
    # Removal acts on both variables; additions go to GRUB_CMDLINE_LINUX (every entry, recovery included).
    lin, rb1 = _apply(defs["GRUB_CMDLINE_LINUX"][1], [t for t in add if _key(t) not in [_key(x) for x in defs["GRUB_CMDLINE_LINUX_DEFAULT"][1]]], remove)
    dflt, rb2 = _apply(defs["GRUB_CMDLINE_LINUX_DEFAULT"][1], [t for t in add if _key(t) in [_key(x) for x in defs["GRUB_CMDLINE_LINUX_DEFAULT"][1]]], remove)
    after = lin + dflt
    rollback = {"add": rb1["add"] + rb2["add"], "remove": rb1["remove"] + rb2["remove"]}
    if after == before:
        return _result(ctx, False, defs["GRUB_CMDLINE_LINUX"][0], before, after, live, add, remove, rollback)

    pending = {}
    for var, tokens in [("GRUB_CMDLINE_LINUX", lin), ("GRUB_CMDLINE_LINUX_DEFAULT", dflt)]:
        where, old = defs[var]
        if tokens == old:
            continue
        text = pending.get(where, contents.get(where, ""))
        pending[where] = _set(text, var, " ".join(tokens))
    for f in pending:
        ctx.file_write(f, pending[f])
    if not ctx.check_mode:
        _regenerate(ctx, facts, grub_cfg)
    return _result(ctx, True, ", ".join(sorted(pending.keys())), before, after, live, add, remove, rollback)


def _regenerate(ctx, facts, grub_cfg):
    if facts.get("os_family") == "debian" and ctx.run(["sh", "-c", "command -v update-grub"]).rc == 0:
        argv = ["update-grub"]
    else:
        if not grub_cfg.endswith("grub.cfg"):
            fail("unsupported: no grub.cfg path to regenerate (boot_loader evidence %r)" % grub_cfg)
        tool = ""
        for t in ["grub2-mkconfig", "grub-mkconfig"]:
            if ctx.run(["sh", "-c", "command -v " + t]).rc == 0:
                tool = t
                break
        if not tool:
            fail("unsupported: neither grub2-mkconfig nor grub-mkconfig is installed")
        argv = [tool, "-o", grub_cfg]
    r = ctx.run(argv, mutates = True)
    if not r.skipped and r.rc != 0:
        fail("%s failed: %s" % (argv[0], r.stderr))


def _extlinux(ctx, add, remove, live):
    path = "/etc/update-extlinux.conf"
    if not ctx.file_exists(path):
        fail("unsupported: %s missing although the boot loader is extlinux" % path)
    text = ctx.file_read(path)
    val = _find(text, "default_kernel_opts")
    if val == None:
        val = ""
    if _has_any(val, "$`\\"):
        fail("unsupported: default_kernel_opts in %s is computed by the shell" % path)
    before = val.split()
    after, rollback = _apply(before, add, remove)
    if after == before:
        return _result(ctx, False, path, before, after, live, add, remove, rollback)
    ctx.file_write(path, _set(text, "default_kernel_opts", " ".join(after)))
    r = ctx.run(["update-extlinux"], mutates = True)
    if not r.skipped and r.rc != 0:
        fail("update-extlinux failed: %s" % r.stderr)
    return _result(ctx, True, path + " + update-extlinux", before, after, live, add, remove, rollback)


# The value of the LAST `VAR=...` line, quotes removed; None when absent.
def _find(text, var):
    val = None
    for line in text.splitlines():
        s = line.strip()
        if s.startswith(var + "="):
            v = s[len(var) + 1:].strip()
            if len(v) >= 2 and v[0] == v[-1] and v[0] in "\"'":
                v = v[1:-1]
            val = v
    return val


# Replace the last `VAR=...` line (or append one), keeping every other line.
def _set(text, var, value):
    lines = text.splitlines()
    idx = -1
    for i in range(len(lines)):
        if lines[i].strip().startswith(var + "="):
            idx = i
    new = '%s="%s"' % (var, value)
    if idx >= 0:
        lines[idx] = new
    else:
        lines.append("# Added by yoloman.kernel_cmdline (docs/kernel-tuning.md)")
        lines.append(new)
    return "\n".join(lines) + "\n"
