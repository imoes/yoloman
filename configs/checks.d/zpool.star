def _mb(val):
    # Parse human-readable size string like "39.8G" into megabytes
    val = val.strip()
    idx = None
    for i, ch in enumerate(val):
        if ch not in "0123456789.-":
            idx = i
            break
    if idx == None:
        idx = len(val)
    if idx == 0:
        return 0.0
    num_str = val[:idx]
    # Guard instead of try/except: ensure valid number string
    if num_str == "" or num_str == "." or num_str == "-":
        return 0.0
    dot_count = 0
    has_digit = False
    valid = True
    for c in num_str:
        if c == '.':
            dot_count = dot_count + 1
            if dot_count > 1:
                valid = False
        elif c == '-' and not num_str.startswith('-'):
            valid = False
        elif c >= '0' and c <= '9':
            has_digit = True
        elif c != '.':
            valid = False
    if not valid or not has_digit:
        return 0.0
    # Parse integer part and fractional part manually
    sign = 1.0
    if num_str.startswith('-'):
        sign = -1.0
        num_str = num_str[1:]
    if num_str == "":
        return 0.0
    parts = num_str.split(".")
    int_part_str = parts[0] if len(parts) > 0 else "0"
    frac_part_str = parts[1] if len(parts) > 1 else ""
    # Convert int part
    int_part = 0
    for c in int_part_str:
        int_part = int_part * 10 + (ord(c) - ord('0'))
    # Convert frac part
    frac_part = 0
    for i, c in enumerate(frac_part_str):
        frac_part = frac_part * 10 + (ord(c) - ord('0'))
        frac_part = frac_part / 10.0
    num = sign * (int_part + frac_part)
    unit_str = val[idx:].lstrip().lower()
    unit_map = ["b", "k", "m", "g", "t", "p"]
    unit = 2  # default to MB
    for i, u in enumerate(unit_map):
        if unit_str == u:
            unit = i
            break
    # Compute 1024^(unit-2) using multiplication, no ** operator
    exp = unit - 2
    if exp < 0:
        factor = 1.0
        for i in range(-exp):
            factor = factor / 1024.0
    else:
        factor = 1.0
        for i in range(exp):
            factor = factor * 1024.0
    return num * factor

def main(ctx, params):
    if params.get("_discover"):
        res = ctx.run(["zpool", "list", "-H"], mutates=False)
        items = []
        for line in res.stdout.splitlines():
            if not line.strip():
                continue
            fields = line.split("\t")
            if len(fields) < 7:
                continue
            name = fields[0]
            size_mb = _mb(fields[1])
            free_mb = _mb(fields[3])
            alloc_mb = size_mb - free_mb
            items.append({
                "item": name,
                "params": {
                    "levels": params.get("levels", (80.0, 90.0)),
                    "trend_range": params.get("trend_range", 24),
                    "trend_mb": params.get("trend_mb", None),
                    "trend_percent": params.get("trend_percent", None),
                },
                "metrics": ["used_percent", "used_mb", "size_mb"],
            })
        return {
            "changed": False,
            "msg": "discovered %d zpools" % len(items),
            "data": {"discovery": items},
        }

    # Normal check mode
    item = params.get("item", "")
    res = ctx.run(["zpool", "list", "-H", item], mutates=False)
    lines = res.stdout.splitlines()
    if len(lines) == 0:
        return {
            "changed": False,
            "msg": "zpool %s not found" % item,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }
    fields = lines[0].split("\t")
    if len(fields) < 7:
        return {
            "changed": False,
            "msg": "failed to parse zpool output for %s" % item,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }
    name = fields[0]
    size_mb = _mb(fields[1])
    used_mb = _mb(fields[2])
    free_mb = _mb(fields[3])
    used_percent = (used_mb / size_mb * 100.0) if size_mb > 0 else 0.0
    health = fields[5]

    # Determine health state first
    if health != "ONLINE":
        state = "CRIT"
        msg_health = "Health: %s" % health
    else:
        state = "OK"

    # Apply filesystem levels (warn/crit thresholds for usage percent)
    levels = params.get("levels", (80.0, 90.0))
    warn_percent, crit_percent = levels[0], levels[1]
    
    if state == "OK":
        if used_percent >= crit_percent:
            state = "CRIT"
        elif used_percent >= warn_percent:
            state = "WARN"

    details = "%s: Size: %f MB, Used: %f MB (%f%%)" % (item, size_mb, used_mb, used_percent)
    if health != "ONLINE":
        details += ", " + msg_health

    return {
        "changed": False,
        "msg": details,
        "data": {
            "state": state,
            "metrics": {
                "used_percent": used_percent,
                "used_mb": used_mb,
                "size_mb": size_mb,
            },
            "details": "",
        },
    }