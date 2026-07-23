_LICENSE_SQL = "SELECT ENFORCED,PERMANENT,LOCKED_DOWN,PRODUCT_USAGE,PRODUCT_LIMIT,VALID,EXPIRATION_DATE FROM SYS.M_LICENSE"

_BYTE_UNITS = [
    ("TiB", 1099511627776),
    ("GiB", 1073741824),
    ("MiB", 1048576),
    ("KiB", 1024),
]

def _render_bytes(n):
    n_f = float(n)
    for unit, divisor in _BYTE_UNITS:
        div_f = float(divisor)
        if n_f >= div_f:
            return "%f %s" % (n_f / div_f, unit)
    return "%d B" % int(n)

def _to_int(v, default=0):
    if type(v) == "int":
        return v
    if type(v) == "float":
        return int(v)
    s = str(v).strip()
    return int(s) if s.isdigit() else default

def _parse_bool_field(s):
    low = str(s).strip().lower()
    if low == "true":
        return True
    if low == "false":
        return False
    return None

def _worst_state(a, b):
    order = {"OK": 0, "WARN": 1, "CRIT": 2, "UNKNOWN": 3}
    return a if order.get(a, 0) >= order.get(b, 0) else b

def _find_hana_instances(ctx):
    if not ctx.file_exists("/usr/sap"):
        return []
    res = ctx.run(["find", "/usr/sap", "-maxdepth", "2", "-type", "d", "-name", "HDB??"], mutates=False)
    instances = []
    for line in res.stdout.splitlines():
        line = line.strip()
        if not line:
            continue
        parts = line.split("/")
        if len(parts) != 5:
            continue
        sid = parts[3]
        hdb = parts[4]
        nr = hdb[3:] if len(hdb) == 5 else ""
        if nr.isdigit() and len(sid) >= 1:
            instances.append((sid, nr))
    return instances

def _hdbsql_cmd(params, instance_nr):
    key = params.get("userstore_key", "")
    if key != "":
        return ["hdbsql", "-U", key, "-d", "SYSTEMDB", "-j", _LICENSE_SQL]
    user = params.get("hana_user", "SYSTEM")
    pwd = params.get("hana_password", "")
    return ["hdbsql", "-i", instance_nr, "-d", "SYSTEMDB", "-u", user, "-p", pwd, "-j", _LICENSE_SQL]

def main(ctx, params):
    if params.get("_discover"):
        instances = _find_hana_instances(ctx)
        discovery = []
        for sid, nr in instances:
            discovery.append({
                "item": "%s %s" % (sid, nr),
                "params": {"license_usage_perc": [80.0, 90.0]},
                "metrics": ["license_size", "license_usage_perc"],
            })
        return {
            "changed": False,
            "msg": "discovered %d SAP HANA instances" % len(discovery),
            "data": {"discovery": discovery},
        }

    item = params.get("item", "")
    parts = item.split(" ", 1)
    if len(parts) != 2:
        return {
            "changed": False,
            "msg": "invalid item (expected 'SID NN'): " + item,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }
    instance_nr = parts[1]

    res = ctx.run(_hdbsql_cmd(params, instance_nr), mutates=False)
    if res.rc != 0:
        return {
            "changed": False,
            "msg": "Login into database failed",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": res.stderr},
        }

    stdout = res.stdout.strip()
    if not stdout:
        return {
            "changed": False,
            "msg": "no data returned by hdbsql",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }

    rows = json.decode(stdout)
    if not rows:
        return {
            "changed": False,
            "msg": "empty license result",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }

    row = rows[0]
    enforced_str = str(row.get("ENFORCED", ""))
    permanent_str = str(row.get("PERMANENT", ""))
    valid_str = str(row.get("VALID", ""))
    expiration_date = str(row.get("EXPIRATION_DATE", "?"))
    size = _to_int(row.get("PRODUCT_USAGE", 0))
    limit = _to_int(row.get("PRODUCT_LIMIT", 0))

    enforced = _parse_bool_field(enforced_str)
    permanent = _parse_bool_field(permanent_str)
    valid = _parse_bool_field(valid_str)

    state = "OK"
    messages = []
    metrics = {}

    if enforced == True:
        size_levels = params.get("license_size", None)
        if size_levels != None:
            warn_s = _to_int(size_levels[0])
            crit_s = _to_int(size_levels[1])
            if size >= crit_s:
                state = _worst_state(state, "CRIT")
            elif size >= warn_s:
                state = _worst_state(state, "WARN")
        messages.append("Size: %s" % _render_bytes(size))
        metrics["license_size"] = size

        if limit == 0:
            messages.append("Usage: cannot calculate")
            state = _worst_state(state, "WARN")
        else:
            usage_perc = 100.0 * float(size) / float(limit)
            metrics["license_usage_perc"] = usage_perc
            usage_levels = params.get("license_usage_perc", [80.0, 90.0])
            warn_u = float(usage_levels[0])
            crit_u = float(usage_levels[1])
            if usage_perc >= crit_u:
                state = _worst_state(state, "CRIT")
            elif usage_perc >= warn_u:
                state = _worst_state(state, "WARN")
            messages.append("Usage: %f%%" % usage_perc)
    elif enforced == None:
        messages.append("Status: unknown[%s]" % enforced_str)
        state = _worst_state(state, "UNKNOWN")
    else:
        messages.append("Status: unlimited")

    if permanent == True:
        messages.append("License: %s" % permanent_str)
    else:
        messages.append("License: not %s" % permanent_str)
        state = _worst_state(state, "WARN")

    if valid != True:
        messages.append("not %s" % valid_str)
        state = _worst_state(state, "WARN")

    if expiration_date != "?":
        messages.append("Expiration date: %s" % expiration_date)
        state = _worst_state(state, "WARN")

    return {
        "changed": False,
        "msg": ", ".join(messages),
        "data": {"state": state, "metrics": metrics, "details": ""},
    }