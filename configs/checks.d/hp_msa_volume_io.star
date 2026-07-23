def main(ctx, params):
    if params.get("_discover"):
        res = ctx.run(["cat", "/var/lib/yolo-man/agent/hp_msa_volume.json"], mutates=False)
        if res.rc != 0:
            return {"changed": False, "msg": "failed to read hp_msa_volume data", "data": {"discovery": []}}
        if res.stdout == "":
            return {"changed": False, "msg": "empty response from hp_msa_volume data", "data": {"discovery": []}}
        section = json.decode(res.stdout) if res.stdout else {}

        items = ["SUMMARY"]
        for key in section.keys():
            items.append(key)
        items = sorted(items)

        default_params = {"levels": [80.0, 90.0]}
        out = []
        for name in items:
            out.append({"item": name, "params": default_params, "metrics": ["read_throughput", "write_throughput"]})
        return {"changed": False, "msg": "discovered %d items" % len(out), "data": {"discovery": out}}

    item = params.get("item", "")
    res = ctx.run(["cat", "/var/lib/yolo-man/agent/hp_msa_volume.json"], mutates=False)
    if res.rc != 0:
        return {"changed": False, "msg": "failed to read hp_msa_volume data", "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    if res.stdout == "":
        return {"changed": False, "msg": "empty response from hp_msa_volume data", "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    section = json.decode(res.stdout) if res.stdout else {}

    if item != "SUMMARY":
        disk = section.get(item)
        if disk == None:
            return {"changed": False, "msg": "volume %s not found" % item, "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
        name = disk.get("virtual-disk-name", "unknown")
        raidtype = disk.get("raidtype", "unknown")
        return {"changed": False, "msg": "%s (%s)" % (name, raidtype), "data": {"state": "OK", "metrics": {}, "details": ""}}

    new_section = {}
    for name, values in section.items():
        read_str = values.get("data-read-numeric", "")
        write_str = values.get("data-written-numeric", "")
        # Parse numbers safely without try/except
        read_val = float(read_str) if read_str != "" and _is_numeric(read_str) else 0.0
        write_val = float(write_str) if write_str != "" and _is_numeric(write_str) else 0.0
        new_section[name] = {"read_throughput": read_val, "write_throughput": write_val}

    if len(new_section) == 0:
        return {"changed": False, "msg": "no valid volume throughput data", "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    total_read = 0.0
    total_write = 0.0
    for disk_data in new_section.values():
        total_read += disk_data.get("read_throughput", 0.0)
        total_write += disk_data.get("write_throughput", 0.0)

    levels = params.get("levels", [5e6, 10e6])
    warn = levels[0] if type(levels) == "list" and len(levels) >= 1 else 5e6
    crit = levels[1] if type(levels) == "list" and len(levels) >= 2 else 10e6

    state = "OK"
    if total_read >= crit or total_write >= crit:
        state = "CRIT"
    elif total_read >= warn or total_write >= warn:
        state = "WARN"

    msg = "Read: %f MB/s, Write: %f MB/s" % (total_read / 1e6, total_write / 1e6)
    metrics = {"read_throughput": total_read, "write_throughput": total_write}

    return {"changed": False, "msg": msg, "data": {"state": state, "metrics": metrics, "details": ""}}


def _is_numeric(s):
    # Simple check for numeric string (int or float)
    s = s.strip()
    if s == "":
        return False
    # Allow optional leading minus, digits, optional decimal point with more digits
    has_digit = False
    has_dot = False
    for i, c in enumerate(s):
        if c == '-' and i == 0:
            continue
        if c == '.':
            if has_dot:
                return False
            has_dot = True
            continue
        if c < '0' or c > '9':
            return False
        has_digit = True
    return has_digit