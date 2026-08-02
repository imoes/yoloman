# yoloman.machine_identity — turn a restored disk clone into a distinct machine.
#
# A partclone/image restore produces a byte-for-byte copy of its source: same
# machine-id, same SSH host keys, same hostname. Left alone, every deployed
# machine is a twin — they fight over DHCP leases and present identical SSH
# fingerprints. This module resets that identity in one idempotent step.
#
# It is CHROOT-SAFE by design: it only writes files (never calls hostnamectl,
# which needs a running systemd/dbus the offline target does not have). The
# offline provisioner runs it as `chroot <target> agentic-mcpd run-module
# yoloman.machine_identity --json '{"hostname":"host.example"}'` — so every
# path below is relative to the target root. Contract: {changed, msg, data}.
#
# What it does (all guarded so a re-run reports changed=False):
#   1. machine-id → truncated to EMPTY (systemd regenerates a fresh id at boot
#      when the file exists and is empty; a MISSING file is a different, on some
#      images fatal, condition — so we empty, never delete).
#   2. /var/lib/dbus/machine-id → removed (it follows /etc/machine-id).
#   3. /etc/ssh/ssh_host_* → removed so sshd regenerates unique keys on first start.
#   4. /etc/hostname → the new name.
#   5. /etc/hosts → 127.0.1.1 (Debian's local-FQDN convention) repointed at the
#      new name, replacing any prior line rather than appending a second.
#   6. cloud-init (if present) → preserve_hostname:true + cached instance dropped,
#      so it does not re-clobber the hostname from its stale datasource on boot.

def main(ctx, params):
    hostname = params.get("hostname")
    if not hostname:
        fail("hostname is required")
    short = hostname.split(".")[0]
    changed = False
    done = []

    # 1. machine-id → empty (idempotent: skip if already empty/absent-of-content).
    mid = "/etc/machine-id"
    cur = ctx.file_read(mid) if ctx.file_exists(mid) else ""
    if cur.strip() != "":
        ctx.file_write(mid, "", mode="0444")
        changed = True
        done.append("reset machine-id")

    # 2. dbus machine-id → gone.
    dbus_mid = "/var/lib/dbus/machine-id"
    if ctx.file_exists(dbus_mid):
        ctx.run(["rm", "-f", dbus_mid], mutates=True)
        changed = True
        done.append("removed dbus machine-id")

    # 3. SSH host keys → gone (glob, so shell out — there's no glob file op).
    keys = ctx.run(["sh", "-c", "ls /etc/ssh/ssh_host_* 2>/dev/null"], mutates=False)
    if keys.rc == 0 and keys.stdout.strip():
        ctx.run(["sh", "-c", "rm -f /etc/ssh/ssh_host_*"], mutates=True)
        changed = True
        done.append("dropped ssh host keys")

    # 4. hostname.
    hn = "/etc/hostname"
    want_hn = hostname + "\n"
    cur_hn = ctx.file_read(hn) if ctx.file_exists(hn) else ""
    if cur_hn != want_hn:
        ctx.file_write(hn, want_hn, mode="0644")
        changed = True
        done.append("set hostname")

    # 5. /etc/hosts: repoint (or add) the 127.0.1.1 local-FQDN line.
    if _set_hosts_line(ctx, hostname, short):
        changed = True
        done.append("set /etc/hosts name")

    # 6. cloud-init: stop it re-setting the hostname from a cached datasource.
    if ctx.file_exists("/etc/cloud"):
        if _pin_cloud_init(ctx):
            changed = True
            done.append("pinned cloud-init hostname")

    return {
        "changed": changed,
        "msg": ("reset identity for %s (%s)" % (hostname, ", ".join(done))) if changed
               else "identity already matches %s" % hostname,
        "data": {"hostname": hostname, "short": short, "actions": done},
    }


# Rewrite the 127.0.1.1 line to "<fqdn> <short>", preserving the rest of the
# file. Returns True if the file content changed.
def _set_hosts_line(ctx, hostname, short):
    path = "/etc/hosts"
    want = "127.0.1.1\t%s %s" % (hostname, short)
    old = ctx.file_read(path) if ctx.file_exists(path) else ""
    lines = old.split("\n") if old else []
    out = []
    replaced = False
    for line in lines:
        if line.startswith("127.0.1.1"):
            out.append(want)
            replaced = True
        else:
            out.append(line)
    if not replaced:
        # append before a trailing empty element so we don't double the final newline
        if out and out[-1] == "":
            out.insert(len(out) - 1, want)
        else:
            out.append(want)
    new = "\n".join(out)
    # keep a single trailing newline
    if not new.endswith("\n"):
        new = new + "\n"
    if new == old:
        return False
    ctx.file_write(path, new, mode="0644")
    return True


# preserve_hostname + drop the cached instance identity so cloud-init
# re-initialises as a fresh machine instead of restoring the source's name.
def _pin_cloud_init(ctx):
    cfg = "/etc/cloud/cloud.cfg.d/99-preserve-hostname.cfg"
    want = "preserve_hostname: true\n"
    cur = ctx.file_read(cfg) if ctx.file_exists(cfg) else ""
    changed = False
    if cur != want:
        # file_write does not create parent dirs; cloud.cfg.d may not exist yet.
        ctx.run(["mkdir", "-p", "/etc/cloud/cloud.cfg.d"], mutates=True)
        ctx.file_write(cfg, want, mode="0644")
        changed = True
    # Drop cached instance dirs (best-effort; presence varies by image).
    for d in ("/var/lib/cloud/instance", "/var/lib/cloud/instances"):
        if ctx.file_exists(d):
            ctx.run(["rm", "-rf", d], mutates=True)
            changed = True
    return changed
