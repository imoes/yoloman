def main(ctx, params):
    if params.get("_discover"):
        # HP-UX network interfaces are scanned via lanscan
        res = ctx.run(["lanscan"], mutates=False)
        if res.rc == 127:
            # lanscan not available — not HP-UX, check does not apply
            return {"changed": False, "msg": "lanscan not found, not HP-UX", "data": {"discovery": []}}
        if res.rc != 0:
            return {"changed": False, "msg": "lanscan failed", "data": {"discovery": []}}

        nics = {}
        for line in res.stdout.splitlines():
            if "***" in line:
                continue
            f = line.split()
            if len(f) < 2:
                continue
            # PPA Number line format: "PPA Number 0"
            if len(f) >= 3 and f[0] == "PPA" and f[1] == "Number":
                ppa = f[2]
                if ppa not in nics:
                    nics[ppa] = {"index": ppa}
            # Interface Name line: "Interface Name lan0"
            if len(f) >= 3 and f[0] == "Interface" and f[1] == "Name":
                descr = f[2]
                # associate with last PPA encountered
                if ppa in nics:
                    nics[ppa]["descr"] = descr

        out = []
        for ppa, info in nics.items():
            out.append({
                "item": info.get("descr", "PPA_" + ppa),
                "params": {"warn": 80, "crit": 90},
                "metrics": ["in_octets", "out_octets", "in_ucast", "out_ucast"],
            })

        return {
            "changed": False,
            "msg": "discovered %d interfaces" % len(out),
            "data": {"discovery": out},
        }

    item = params.get("item", "")

    # Check if lanscan is available
    probe = ctx.run(["lanscan"], mutates=False)
    if probe.rc == 127:
        return {
            "changed": False,
            "msg": "lanscan not found — HP-UX networking not available",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }
    if probe.rc != 0:
        return {
            "changed": False,
            "msg": "lanscan failed to enumerate interfaces",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }

    warn = params.get("warn", 80)
    crit = params.get("crit", 90)

    # Get detailed stats for the specific interface
    # On HP-UX, we use netstat -in or lanscan -a for counters
    detail = ctx.run(["lanscan", "-a"], mutates=False)
    if detail.rc == 127:
        return {
            "changed": False,
            "msg": "lanscan not found — HP-UX networking not available",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }

    metrics = {}
    found = False
    for line in detail.stdout.splitlines():
        if "***" in line:
            continue
        f = line.split()
        # Look for the PPA matching our item
        # HP-UX lanscan -a output has columns including PPA, Name, etc.
        # We try to match by interface name or PPA number
        if len(f) >= 2:
            # Check if this line relates to our item
            for field in f:
                if field == item:
                    found = True
                    break
            if not found and len(f) >= 1 and f[0].startswith("PPA"):
                # PPA Number 0 => check if item is "0" or matches
                if len(f) >= 3 and f[2] == item:
                    found = True

    if not found and item != "":
        return {
            "changed": False,
            "msg": "interface %s not found" % item,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }

    # Without real HP-UX counters we cannot grade; report UNKNOWN
    if not found:
        return {
            "changed": False,
            "msg": "no HP-UX interface data available for %s" % item,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }

    return {
        "changed": False,
        "msg": "NIC %s — no counter data" % item,
        "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
    }