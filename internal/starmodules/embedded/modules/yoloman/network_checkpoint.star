# yoloman.network_checkpoint — Cockpit-style auto-rollback for network changes.
#
# Cockpit wraps every connectivity-affecting change in an NM checkpoint that
# auto-reverts after a few seconds unless you confirm you still have a
# connection. We do the same, provider-independently and scoped to the one
# interface config file yoloman.network_interface manages (so the blast radius
# is that file, never the whole /etc/netplan):
#
#   state=create  — back up the managed file for <name> and arm a detached
#                   timer that, after `timeout` seconds, restores it + reloads
#                   the provider UNLESS a confirm marker exists. Returns {id}.
#   state=confirm — drop the confirm marker (cancels the pending revert).
#   state=rollback— restore + reload now (and cancel the timer).
#
# Flow: create → apply the real change → if the UI is still reachable, confirm;
# otherwise the timer restores the previous config on its own. Mutating; the
# runtime enforces the write gate. Contract shape: {changed, msg, data}.

_CKPT_DIR = "/var/lib/yoloman/netckpt"


def main(ctx, params):
    state = params.get("state")
    if state not in ("create", "confirm", "rollback"):
        fail("state must be one of: create, confirm, rollback")
    cid = params.get("id")
    if not cid or not _safe_id(cid):
        fail("id is required and must be [A-Za-z0-9._-]")
    if state == "create":
        name = params.get("name")
        if not name:
            fail("name (the interface) is required for state=create")
        provider = params.get("provider") or _detect_provider(ctx)
        timeout = int(params.get("timeout", 90))
        return _create(ctx, cid, name, provider, timeout)
    if state == "confirm":
        return _confirm(ctx, cid)
    return _rollback(ctx, cid)


def _safe_id(cid):
    allowed = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-"
    for i in range(len(cid)):
        if cid[i] not in allowed:
            return False
    return True


def _marker(cid):
    return "/run/yoloman-netckpt-%s.ok" % cid


def _bak(cid):
    return "%s/%s.bak" % (_CKPT_DIR, cid)


def _meta(cid):
    return "%s/%s.meta" % (_CKPT_DIR, cid)


# ---- provider detection + per-provider target file / reload ----

def _cmd_exists(ctx, cmd):
    return ctx.run(["sh", "-c", "command -v %s" % cmd], mutates=False).rc == 0


def _service_active(ctx, unit):
    res = ctx.run(["systemctl", "is-active", unit], mutates=False)
    return res.rc == 0 and res.stdout.strip() == "active"


def _detect_provider(ctx):
    if _cmd_exists(ctx, "nmcli"):
        st = ctx.run(["nmcli", "-t", "-f", "RUNNING", "general"], mutates=False)
        if st.rc == 0 and "running" in st.stdout.lower():
            return "networkmanager"
    if _cmd_exists(ctx, "netplan"):
        return "netplan"
    if _cmd_exists(ctx, "networkctl") and _service_active(ctx, "systemd-networkd"):
        return "networkd"
    if ctx.file_exists("/etc/network/interfaces"):
        return "ifupdown"
    if _cmd_exists(ctx, "nmcli"):
        return "networkmanager"
    fail("no supported network provider detected")


# target_file: the managed config file yoloman.network_interface writes for
# this interface — the one thing we back up and restore.
def _target_file(provider, name):
    if provider == "netplan":
        return "/etc/netplan/90-yoloman-%s.yaml" % name
    if provider == "networkd":
        return "/etc/systemd/network/90-yoloman-%s.network" % name
    if provider == "ifupdown":
        return "/etc/network/interfaces.d/yoloman-%s" % name
    if provider == "networkmanager":
        return "/etc/NetworkManager/system-connections/%s.nmconnection" % name
    fail("unknown provider %s" % provider)


def _reload_cmd(provider, name):
    if provider == "netplan":
        return "netplan apply"
    if provider == "networkd":
        return "networkctl reload; networkctl reconfigure %s" % name
    if provider == "ifupdown":
        return "ifdown %s 2>/dev/null; ifup %s 2>/dev/null || true" % (name, name)
    if provider == "networkmanager":
        return "nmcli connection reload; nmcli connection up %s 2>/dev/null || true" % name
    return "true"


# ---- create / confirm / rollback ----

def _create(ctx, cid, name, provider, timeout):
    ctx.run(["mkdir", "-p", _CKPT_DIR], mutates=True)
    target = _target_file(provider, name)
    existed = ctx.file_exists(target)
    if existed:
        ctx.file_write(_bak(cid), ctx.file_read(target), mode="0600")
    else:
        # nothing to restore to — record absence so revert removes the file
        ctx.file_write(_bak(cid), "", mode="0600")
    ctx.file_write(_meta(cid), "%s\n%s\n%s\n" % (provider, name, "1" if existed else "0"), mode="0600")

    # Arm the detached revert: sleep, then unless confirmed, restore + reload.
    restore = _restore_snippet(cid, target, existed, provider, name)
    script = "sleep %d\n%s\n" % (timeout, _guarded(cid, restore))
    spath = "%s/%s.sh" % (_CKPT_DIR, cid)
    ctx.file_write(spath, script, mode="0700")
    # setsid detaches from this run's process group so it survives; check_mode
    # skips the launch (mutates=True).
    ctx.run(["sh", "-c", "setsid sh %s </dev/null >/dev/null 2>&1 &" % spath], mutates=True)
    return {
        "changed": True,
        "msg": "armed network checkpoint %s for %s (%s, auto-revert in %ds)" % (cid, name, provider, timeout),
        "data": {"id": cid, "name": name, "provider": provider, "timeout": timeout, "target": target, "marker": _marker(cid)},
    }


# the revert body, guarded by the confirm marker
def _guarded(cid, restore):
    m = _marker(cid)
    return "if [ -f %s ]; then rm -f %s; exit 0; fi\n%s" % (m, m, restore)


def _restore_snippet(cid, target, existed, provider, name):
    reload_cmd = _reload_cmd(provider, name)
    if existed:
        return "cp %s %s\n%s" % (_bak(cid), target, reload_cmd)
    return "rm -f %s\n%s" % (target, reload_cmd)


def _confirm(ctx, cid):
    # Presence of the marker tells the armed timer to skip the revert.
    changed = ctx.file_write(_marker(cid), "ok\n", mode="0600")
    return {"changed": changed, "msg": "confirmed checkpoint %s (auto-revert cancelled)" % cid, "data": {"id": cid}}


def _rollback(ctx, cid):
    if not ctx.file_exists(_meta(cid)):
        return {"changed": False, "msg": "checkpoint %s not found (already reverted/confirmed?)" % cid, "data": {"id": cid}}
    meta = ctx.file_read(_meta(cid)).split("\n")
    provider, name, existed = meta[0], meta[1], (len(meta) > 2 and meta[2] == "1")
    target = _target_file(provider, name)
    # Stop the timer, then restore now.
    ctx.file_write(_marker(cid), "ok\n", mode="0600")
    if existed:
        ctx.file_write(target, ctx.file_read(_bak(cid)), mode="0644")
    elif ctx.file_exists(target):
        ctx.run(["rm", "-f", target], mutates=True)
    ctx.run(["sh", "-c", _reload_cmd(provider, name)], mutates=True)
    return {
        "changed": True,
        "msg": "rolled back checkpoint %s for %s (%s)" % (cid, name, provider),
        "data": {"id": cid, "name": name, "provider": provider},
    }
