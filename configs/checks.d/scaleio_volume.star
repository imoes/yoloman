BYTES_PER_UNIT = {
    "Bytes": 1.0,
    "KB": 1024.0,
    "MB": 1048576.0,
    "GB": 1073741824.0,
    "TB": 1099511627776.0,
}

UNIT_UP = {
    "KB": "MB",
    "MB": "GB",
    "GB": "TB",
}

def _is_numeric(s):
    s = s.strip().lstrip("-")
    if s == "":
        return False
    if "." in s:
        parts = s.split(".", 1)
        return parts[0].isdigit() and parts[1].isdigit()
    return s.isdigit()

def _normalize_size(value, unit):
    for _ in range(4):
        if value > 1024 and unit in UNIT_UP:
            value = value / 1024.0
            unit = UNIT_UP[unit]
        else:
            break
    return (value, unit)

def _parse_bwc(text):
    text = text.replace(",", "")
    parts = text.split()
    if len(parts) < 4:
        return None
    iops_s = parts[0]
    bw_s = parts[2]
    unit = parts[3]
    if not _is_numeric(iops_s) or not _is_numeric(bw_s):
        return None
    if unit not in BYTES_PER_UNIT:
        return {"ok": False, "unit": unit}
    return {
        "ok": True,
        "iops": float(iops_s),
        "bw_bytes": float(bw_s) * BYTES_PER_UNIT[unit],
    }

def _parse_size(text):
    parts = text.strip().split()
    if len(parts) < 2:
        return None
    val_s = parts[0]
    unit = parts[1].strip("()")
    if not _is_numeric(val_s):
        return None
    return {"value": float(val_s), "unit": unit}

def _build_cmd(params):
    cmd = ["scli", "--query_all_volumes", "--approve_certificate"]
    mdm_ip = params.get("mdm_ip", "")
    if mdm_ip != "":
        cmd = cmd + ["--mdm_ip", mdm_ip]
    username = params.get("username", "")
    if username != "":
        cmd = cmd + ["--username", username]
    password = params.get("password", "")
    if password != "":
        cmd = cmd + ["--password", password]
    return cmd

def _parse_volumes(output):
    volumes = {}
    cur_id = ""
    for line in output.splitlines():
        stripped = line.strip()
        if stripped == "" or stripped.startswith("Queried"):
            continue
        if stripped.startswith("Volume ID:"):
            cur_id = stripped.split(":", 1)[1].strip()
            volumes[cur_id] = {
                "name": cur_id,
                "size_value": 0.0,
                "size_unit": "MB",
                "read_iops": 0.0,
                "read_bw": 0.0,
                "write_iops": 0.0,
                "write_bw": 0.0,
                "read_ok": True,
                "write_ok": True,
                "bad_unit": "",
            }
        elif cur_id != "" and stripped.startswith("Volume name:"):
            volumes[cur_id]["name"] = stripped.split(":", 1)[1].strip()
        elif cur_id != "" and (stripped.startswith("Volume size:") or stripped.startswith("User Data Capacity:")):
            size_str = stripped.split(":", 1)[1].strip()
            parsed = _parse_size(size_str)
            if parsed != None:
                volumes[cur_id]["size_value"] = parsed["value"]
                volumes[cur_id]["size_unit"] = parsed["unit"]
        elif cur_id != "" and stripped.startswith("User Data Read BWC:"):
            bwc_str = stripped.split(":", 1)[1].strip()
            parsed = _parse_bwc(bwc_str)
            if parsed == None:
                volumes[cur_id]["read_ok"] = False
            elif not parsed["ok"]:
                volumes[cur_id]["read_ok"] = False
                volumes[cur_id]["bad_unit"] = parsed["unit"]
            else:
                volumes[cur_id]["read_iops"] = parsed["iops"]
                volumes[cur_id]["read_bw"] = parsed["bw_bytes"]
        elif cur_id != "" and stripped.startswith("User Data Write BWC:"):
            bwc_str = stripped.split(":", 1)[1].strip()
            parsed = _parse_bwc(bwc_str)
            if parsed == None:
                volumes[cur_id]["write_ok"] = False
            elif not parsed["ok"]:
                volumes[cur_id]["write_ok"] = False
                if volumes[cur_id]["bad_unit"] == "":
                    volumes[cur_id]["bad_unit"] = parsed["unit"]
            else:
                volumes[cur_id]["write_iops"] = parsed["iops"]
                volumes[cur_id]["write_bw"] = parsed["bw_bytes"]
    return volumes

def _level_state(value, levels):
    if levels == None:
        return "OK"
    warn = levels[0]
    crit = levels[1]
    if value >= crit:
        return "CRIT"
    if value >= warn:
        return "WARN"
    return "OK"

def _worst(a, b):
    if a == "CRIT" or b == "CRIT":
        return "CRIT"
    if a == "WARN" or b == "WARN":
        return "WARN"
    if a == "UNKNOWN" or b == "UNKNOWN":
        return "UNKNOWN"
    return "OK"

def main(ctx, params):
    cmd = _build_cmd(params)
    res = ctx.run(cmd, mutates=False, ok_codes=[0, 1, 2, 3])

    if params.get("_discover"):
        if res.rc != 0:
            return {"changed": False,
                    "msg": "scli error rc=%d" % res.rc,
                    "data": {"discovery": []}}
        volumes = _parse_volumes(res.stdout)
        disc = [
            {"item": vid, "params": {},
             "metrics": ["read_ios", "read_throughput", "write_ios", "write_throughput"]}
            for vid in volumes
        ]
        return {"changed": False,
                "msg": "discovered %d volumes" % len(disc),
                "data": {"discovery": disc}}

    if res.rc != 0:
        return {"changed": False,
                "msg": "scli error rc=%d: %s" % (res.rc, res.stderr),
                "data": {"state": "UNKNOWN", "metrics": {}, "details": res.stderr}}

    item = params.get("item", "")
    volumes = _parse_volumes(res.stdout)
    vol = volumes.get(item)
    if vol == None:
        return {"changed": False,
                "msg": "Volume not found: " + item,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    size_val, size_unit = _normalize_size(vol["size_value"], vol["size_unit"])
    summary = "Name: %s, Size: %f %s" % (vol["name"], size_val, size_unit)

    if not vol["read_ok"] or not vol["write_ok"]:
        return {"changed": False,
                "msg": summary + ", Unknown unit: " + vol["bad_unit"],
                "data": {"state": "UNKNOWN", "metrics": {},
                         "details": "Unknown bandwidth unit: " + vol["bad_unit"]}}

    state = _worst(
        _worst(_level_state(vol["read_bw"], params.get("read_throughput", None)),
               _level_state(vol["write_bw"], params.get("write_throughput", None))),
        _worst(_level_state(vol["read_iops"], params.get("read_ios", None)),
               _level_state(vol["write_iops"], params.get("write_ios", None))),
    )

    return {
        "changed": False,
        "msg": summary,
        "data": {
            "state": state,
            "metrics": {
                "read_ios": vol["read_iops"],
                "read_throughput": vol["read_bw"],
                "write_ios": vol["write_iops"],
                "write_throughput": vol["write_bw"],
            },
            "details": "",
        },
    }