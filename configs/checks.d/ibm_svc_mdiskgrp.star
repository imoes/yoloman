# ibm_svc_mdiskgrp — Pool Capacity %s
# Read-only Starlark check for IBM SVC / Storwize managed disk groups.

def _to_mb(size):
    if size.endswith("MB"):
        return float(size.replace("MB", ""))
    if size.endswith("GB"):
        return float(size.replace("GB", "")) * 1024
    if size.endswith("TB"):
        return float(size.replace("TB", "")) * 1024 * 1024
    if size.endswith("PB"):
        return float(size.replace("PB", "")) * 1024 * 1024 * 1024
    if size.endswith("EB"):
        return float(size.replace("EB", "")) * 1024 * 1024 * 1024 * 1024
    return float(size)

_HEADER = [
    "id", "name", "status", "mdisk_count", "vdisk_count", "capacity",
    "extent_size", "free_capacity", "virtual_capacity", "used_capacity",
    "real_capacity", "overallocation", "warning", "easy_tier",
    "easy_tier_status", "compression_active", "compression_virtual_capacity",
    "compression_compressed_capacity", "compression_uncompressed_capacity",
    "parent_mdisk_grp_id", "parent_mdisk_grp_name", "child_mdisk_grp_count",
    "child_mdisk_grp_capacity", "type", "encrypt", "owner_type",
    "site_id", "site_name",
]

def _parse_line(line):
    cols = line.split(":")
    if len(cols) < len(_HEADER):
        return {}
    return dict(zip(_HEADER[1:], cols[1:]))

def main(ctx, params):
    discover = params.get("_discover", False)
    host = params.get("host", "localhost")

    # Detect whether this is an IBM SVC / Storwize system by probing svcinfo.
    probe = ctx.run(["svcinfo", "lsmdiskgrp", "-delim", ":"], mutates=False)
    if probe.rc != 0:
        # svcinfo not present or unavailable -> not an SVC host
        if discover:
            return {"changed": False, "msg": "no IBM SVC mdiskgrps found",
                    "data": {"discovery": []}}
        return {"changed": False, "msg": "svcinfo not available or no IBM SVC mdiskgrps",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    out = []
    for line in probe.stdout.splitlines():
        line = line.strip()
        if not line or line.startswith("id:"):
            continue
        d = _parse_line(line)
        if len(d) == 0:
            continue
        out.append(d)

    # ---- DISCOVERY ----
    if discover:
        items = []
        for d in out:
            name = d.get("name", "")
            if not name:
                continue
            items.append({"item": name, "params": {}, "metrics": ["size", "fs_provisioning", "used"]})
        return {"changed": False,
                "msg": "discovered %d mdiskgrps" % len(items),
                "data": {"discovery": items}}

    # ---- CHECK (single item) ----
    item = params.get("item", "")
    warn = params.get("warn", 80)
    crit = params.get("crit", 90)
    prov_levels = params.get("provisioning_levels")

    data = {}
    for d in out:
        if d.get("name") == item:
            data = d
            break

    if len(data) == 0:
        return {"changed": False, "msg": "no such mdiskgrp: " + item,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    status = data.get("status", "")
    if status != "online":
        return {"changed": False, "msg": "Status: %s" % status,
                "data": {"state": "CRIT", "metrics": {}, "details": ""}}

    capacity = _to_mb(data.get("capacity", "0"))
    real_capacity = _to_mb(data.get("real_capacity", "0"))
    virtual_capacity = _to_mb(data.get("virtual_capacity", "0"))

    mb = 1024 * 1024
    avail_mb = capacity - real_capacity
    used_mb = real_capacity
    warn_mb = capacity * warn / 100
    crit_mb = capacity * crit / 100
    used_pct = 100.0 * used_mb / capacity if capacity > 0 else 0.0

    state = "OK"
    if capacity > 0:
        if used_pct >= crit:
            state = "CRIT"
        elif used_pct >= warn:
            state = "WARN"

    details = "Size: %f MB, Used: %f MB, Avail: %f MB (%f%% full)" % (
        capacity, used_mb, avail_mb, used_pct)

    metrics = {"size": capacity, "fs_provisioning": virtual_capacity * mb, "used": used_mb * mb}

    # Provisioning check
    if capacity > 0:
        provisioning = 100.0 * virtual_capacity / capacity
        details += ", Provisioning: %f%%" % provisioning
        prov_state = "OK"
        if prov_levels != None:
            if type(prov_levels) == "dict":
                pw = prov_levels.get("warn", 0)
                pc = prov_levels.get("crit", 0)
            else:
                pw = prov_levels[0]
                pc = prov_levels[1]
            if provisioning >= pc:
                prov_state = "CRIT"
            elif provisioning >= pw:
                prov_state = "WARN"
            details += " (warn/crit at %f%%/%f%%)" % (pw, pc)
            if prov_state != "OK":
                state = prov_state

    return {"changed": False, "msg": details,
            "data": {"state": state, "metrics": metrics, "details": ""}}