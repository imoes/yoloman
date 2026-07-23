def main(ctx, params):
    if params.get("_discover"):
        res = ctx.run([
            "snmpwalk", "-v2c", "-c", params.get("community", "public"),
            "-On", params.get("host", "localhost"),
            ".1.3.6.1.4.1.31770.2.2.6.4.1"
        ], mutates=False)
        items = []
        for line in res.stdout.splitlines():
            if not line.strip():
                continue
            parts = line.strip().split(" = STRING: ")
            if len(parts) != 2:
                continue
            oid_end = parts[0].strip()
            name = parts[1].strip().strip('"')
            if name == "" or name == "UNDEF":
                continue
            fuse_index = int(oid_end.split(".")[-1]) + 1
            items.append({
                "item": "Fuse %d" % fuse_index,
                "params": {},
                "metrics": ["current"]
            })
        return {
            "changed": False,
            "msg": "discovered %d fuses" % len(items),
            "data": {"discovery": items}
        }

    item = params.get("item", "")
    if item.startswith("Fuse "):
        idx_str = item.split(" ")[1]
        fuse_index = int(idx_str) - 1 if idx_str.isdigit() else -1
        if fuse_index < 0:
            return {
                "changed": False,
                "msg": "invalid fuse index in item: " + item,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
            }
    else:
        return {
            "changed": False,
            "msg": "invalid item format: " + item,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }

    res_type = ctx.run([
        "snmpget", "-v2c", "-c", params.get("community", "public"),
        "-On", params.get("host", "localhost"),
        ".1.3.6.1.4.1.31770.2.2.8.2.1.6.0.4.0.0.255.255.%d.7" % fuse_index
    ], mutates=False)
    res_status = ctx.run([
        "snmpget", "-v2c", "-c", params.get("community", "public"),
        "-On", params.get("host", "localhost"),
        ".1.3.6.1.4.1.31770.2.2.8.2.1.7.0.4.0.0.255.255.%d.7" % fuse_index
    ], mutates=False)
    res_scaling = ctx.run([
        "snmpget", "-v2c", "-c", params.get("community", "public"),
        "-On", params.get("host", "localhost"),
        ".1.3.6.1.4.1.31770.2.2.8.2.1.9.0.4.0.0.255.255.%d.7" % fuse_index
    ], mutates=False)
    res_value = ctx.run([
        "snmpget", "-v2c", "-c", params.get("community", "public"),
        "-On", params.get("host", "localhost"),
        ".1.3.6.1.4.1.31770.2.2.8.4.1.5.0.4.0.0.1.255.255.%d.7" % fuse_index
    ], mutates=False)

    def extract_value(output):
        stripped = output.stdout.strip()
        if stripped == "":
            return None
        parts = stripped.split(" = ")
        if len(parts) != 2:
            return None
        val_part = parts[1].strip()
        idx = val_part.find(": ")
        return val_part[idx + 2:].strip() if idx != -1 else val_part

    value_type = extract_value(res_type)
    value_status = extract_value(res_status)
    value_scaling = extract_value(res_scaling)
    value_data = extract_value(res_value)

    if value_data == None or value_scaling == None:
        return {
            "changed": False,
            "msg": "no data for fuse: " + item,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }

    current = 0.0
    state = 3
    status_name = "unknown"

    def _safe_float(s):
        if s == None:
            return 0.0
        s = s.strip()
        if s == "":
            return 0.0
        has_minus = s.startswith("-")
        digits = s[1:] if has_minus else s
        if digits.isdigit():
            return float(int(s))
        return 0.0

    def _pow_int(base, exp):
        if exp == 0:
            return 1.0
        result = 1.0
        i = 0
        while i < exp:
            result = result * base
            i = i + 1
        return result

    scaling_int = 0
    if value_scaling.isdigit() or (value_scaling.startswith("-") and value_scaling[1:].isdigit()):
        scaling_int = int(value_scaling)

    if scaling_int >= 0:
        scale_factor = float(_pow_int(10, scaling_int))
    else:
        scale_factor = 1.0
        i = 0
        while i < -scaling_int:
            scale_factor = scale_factor / 10.0
            i = i + 1

    current = _safe_float(value_data) * scale_factor

    status_map = {
        "0": (0, "expected"),
        "1": (3, "undefined"),
        "2": (0, "OK"),
        "3": (2, "error high"),
        "4": (2, "error low"),
        "5": (1, "warning high"),
        "6": (1, "warning low"),
        "7": (2, "lost"),
        "8": (1, "deactivate"),
        "9": (2, "on alarm identidy"),
        "10": (2, "off alarm identify"),
        "11": (2, "on alarm"),
        "12": (2, "off alarm"),
        "13": (1, "on warning identify"),
        "14": (1, "off warning identify"),
        "15": (1, "on warning"),
        "16": (1, "off warning"),
        "17": (0, "on identify"),
        "18": (0, "off identify"),
        "19": (0, "on"),
        "20": (1, "off"),
        "21": (2, "on child alarm"),
        "22": (2, "off child alarm"),
        "23": (1, "on child warning"),
        "24": (1, "off child warning"),
        "25": (2, "child alarm"),
        "26": (1, "child warning"),
        "27": (2, "lost child"),
        "36": (1, "update in progress"),
        "37": (2, "update error"),
        "38": (1, "ongoing switch"),
        "39": (2, "high"),
        "40": (1, "low"),
        "41": (2, "alarm"),
        "42": (1, "warning"),
        "43": (0, "ok"),
        "44": (1, "disabled"),
        "45": (1, "fw version too new"),
    }
    if value_status.isdigit():
        status_code = int(value_status)
        key = str(status_code)
        if key in status_map:
            state, status_name = status_map[key]
        else:
            state = 3
            status_name = "unknown status code"

    warn = params.get("warn", 10.0)
    crit = params.get("crit", 15.0)
    if state == 0:
        if current >= crit:
            state = 2
        elif current >= warn:
            state = 1

    state_name = ["OK", "WARN", "CRIT", "UNKNOWN"][state]

    return {
        "changed": False,
        "msg": "%s: current %f A" % (item, current),
        "data": {
            "state": state_name,
            "metrics": {"current": current},
            "details": status_name
        }
    }