def main(ctx, params):
    if params.get("_discover"):
        # Probe for podman
        ver = ctx.run(["podman", "--version"], mutates=False)
        if ver.rc == 127 or ver.rc != 0:
            return {"changed": False, "msg": "podman not found",
                    "data": {"discovery": []}}

        # Gather container stats: id, mem_total (bytes), mem_used (bytes)
        res = ctx.run(
            ["podman", "stats", "--no-stream", "--format",
             "{{.Container}}\t{{.MemUsage}}", "--cidfile", ""],
            mutates=False)
        if res.rc != 0 and res.rc != 125:
            # rc 125 = no containers running
            if res.rc == 125:
                return {"changed": False, "msg": "no containers",
                        "data": {"discovery": []}}

        out = []
        for line in res.stdout.splitlines():
            f = line.split("\t")
            if len(f) < 2:
                continue
            cid = f[0].strip()
            usage = f[1].strip()
            if not usage or "/" not in usage:
                continue
            parts = usage.split("/")
            used_s = parts[0].strip()
            total_s = parts[1].strip()
            used_b = _parse_mem(used_s)
            total_b = _parse_mem(total_s)
            if used_b == None or total_b == None:
                continue
            if total_b <= 0:
                continue
            out.append({
                "item": cid,
                "params": {"levels": params.get("levels", (150.0, 200.0))},
                "metrics": ["mem_used", "mem_used_percent", "mem_lnx_total_used"],
            })
        return {"changed": False,
                "msg": "discovered %d containers" % len(out),
                "data": {"discovery": out}}

    item = params.get("item", "")
    # Probe podman presence
    ver = ctx.run(["podman", "--version"], mutates=False)
    if ver.rc == 127 or ver.rc != 0:
        return {"changed": False,
                "msg": "podman not found",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    res = ctx.run(
        ["podman", "stats", "--no-stream", "--format",
         "{{.Container}}\t{{.MemUsage}}", item],
        mutates=False)
    found = False
    mem_used_b = 0
    mem_total_b = 0
    for line in res.stdout.splitlines():
        f = line.split("\t")
        if len(f) < 2:
            continue
        cid = f[0].strip()
        if cid != item:
            continue
        usage = f[1].strip()
        if "/" not in usage:
            continue
        parts = usage.split("/")
        used_s = parts[0].strip()
        total_s = parts[1].strip()
        used_b = _parse_mem(used_s)
        total_b = _parse_mem(total_s)
        if used_b == None or total_b == None:
            break
        mem_used_b = used_b
        mem_total_b = total_b
        found = True
        break

    if not found or mem_total_b <= 0:
        return {"changed": False,
                "msg": "container not found: %s" % item,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    mem_free_b = mem_total_b - mem_used_b
    # Compute percent used (of total)
    used_percent = 0.0
    if mem_total_b > 0:
        used_percent = 100.0 * mem_used_b / mem_total_b

    levels = params.get("levels", (150.0, 200.0))
    warn_lvl = levels[0] if len(levels) > 0 else 150.0
    crit_lvl = levels[1] if len(levels) > 1 else 200.0

    # The memory plugin grades against totalvirt (swap+ram). Here no swap,
    # so totalvirt_mb == memtotal_mb. Levels are in percent of total.
    state = "OK"
    used_mb = mem_used_b / (1024.0 * 1024.0)
    total_mb = mem_total_b / (1024.0 * 1024.0)
    if total_mb > 0:
        pct = 100.0 * used_mb / total_mb
        if pct >= crit_lvl:
            state = "CRIT"
        elif pct >= warn_lvl:
            state = "WARN"

    metrics = {
        "mem_used": mem_used_b,
        "mem_used_percent": used_percent,
        "mem_lnx_total_used": mem_used_b,
    }

    summary = "RAM used: %s of %s, %d%%" % (
        _render_bytes(mem_used_b), _render_bytes(mem_total_b), int(used_percent))
    if state != "OK":
        summary = summary + " (%s above level %d)" % (
            state, int(warn_lvl))

    return {"changed": False, "msg": summary,
            "data": {"state": state, "metrics": metrics, "details": ""}}


def _parse_mem(s):
    if s == None or s == "":
        return None
    s = s.strip()
    factor = 1.0
    mult = 1
    if s.endswith("GiB") or s.endswith("GIB"):
        mult = 1024 * 1024 * 1024
        s = s[:-3]
    elif s.endswith("G") or s.endswith("GB"):
        mult = 1000 * 1000 * 1000
        s = s[:-1]
    elif s.endswith("MiB") or s.endswith("MIB"):
        mult = 1024 * 1024
        s = s[:-3]
    elif s.endswith("M") or s.endswith("MB"):
        mult = 1000 * 1000
        s = s[:-1]
    elif s.endswith("KiB") or s.endswith("KIB"):
        mult = 1024
        s = s[:-3]
    elif s.endswith("K") or s.endswith("KB"):
        mult = 1000
        s = s[:-1]
    elif s.endswith("B"):
        s = s[:-1]
    # try numeric
    if not _isdigit_str(s):
        return None
    return int(float(s) * mult)


def _isdigit_str(s):
    if s == None or s == "":
        return False
    seen_dot = False
    for ch in s:
        if ch == ".":
            if seen_dot:
                return False
            seen_dot = True
        elif ch < "0" or ch > "9":
            return False
    return True


def _render_bytes(b):
    if b < 1024:
        return "%dB" % b
    elif b < 1024 * 1024:
        return "%f KiB" % (b / 1024.0)
    elif b < 1024 * 1024 * 1024:
        return "%f MiB" % (b / (1024.0 * 1024.0))
    else:
        return "%f GiB" % (b / (1024.0 * 1024.0 * 1024.0))