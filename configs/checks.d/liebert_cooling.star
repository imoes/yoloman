def _parse_float(s):
    s = s.strip()
    neg = False
    if s.startswith("-"):
        neg = True
        s = s[1:]
    elif s.startswith("+"):
        s = s[1:]
    if s == "":
        return None
    if "." in s:
        int_part, frac_part = s.split(".", 1)
    else:
        int_part, frac_part = s, ""
    if int_part == "" and frac_part == "":
        return None
    if int_part != "" and not int_part.isdigit():
        return None
    if frac_part != "" and not frac_part.isdigit():
        return None
    val = 0.0
    for ch in int_part:
        val = val * 10.0 + (ord(ch) - 48)
    frac = 0.0
    fdiv = 1.0
    for ch in frac_part:
        frac = frac * 10.0 + (ord(ch) - 48)
        fdiv = fdiv * 10.0
    val = val + frac / fdiv
    return 0.0 - val if neg else val


def _strip_type_tag(s):
    idx = s.find(": ")
    if idx != -1:
        return s[idx + 2:]
    idx2 = s.find(":")
    if idx2 != -1:
        return s[idx2 + 1:].lstrip()
    return s


def _strip_quotes(s):
    s = s.strip()
    if len(s) >= 2 and s[0] == '"' and s[-1] == '"':
        return s[1:-1]
    if len(s) >= 2 and s[0] == "'" and s[-1] == "'":
        return s[1:-1]
    return s


def _snmpget_bare(ctx, host, community, oid):
    res = ctx.run(
        ["snmpget", "-v2c", "-c", community, "-Onqv", host, oid],
        mutates=False,
    )
    if res.rc == 127:
        return None
    if res.rc != 0:
        return None
    return res.stdout.strip()


def _snmpwalk_numeric(ctx, host, community, oid):
    res = ctx.run(
        ["snmpwalk", "-v2c", "-c", community, "-Oqn", host, oid],
        mutates=False,
    )
    if res.rc == 127:
        return None
    if res.rc != 0:
        return None
    lines = []
    for line in res.stdout.split("\n"):
        line = line.strip()
        if line == "":
            continue
        lines.append(line)
    return lines


def _build_name_index_map(ctx, host, community, base):
    names = _snmpwalk_numeric(ctx, host, community, base + ".10")
    if names == None:
        return None
    col_oid = base + ".10."
    name_by_index = {}
    for line in names:
        sp = line.find(" ")
        if sp == -1:
            continue
        full_oid = line[:sp]
        val_raw = line[sp + 1:]
        if not full_oid.startswith(col_oid):
            continue
        idx = full_oid[len(col_oid):]
        val_stripped = _strip_quotes(_strip_type_tag(val_raw))
        if val_stripped != "" and idx != "":
            name_by_index[idx] = val_stripped
    return name_by_index


def _dedup_name(name, seen_names):
    if name in seen_names:
        counter = seen_names[name] + 1
        display = "%s %d" % (name, counter)
        while display in seen_names:
            counter = counter + 1
            display = "%s %d" % (name, counter)
        seen_names[name] = counter
        return display
    else:
        seen_names[name] = 1
        return name


def _lookup_by_index(lines, base, col_suffix, idx):
    col_oid = base + "." + col_suffix + "."
    for line in lines:
        sp = line.find(" ")
        if sp == -1:
            continue
        full_oid = line[:sp]
        val_raw = line[sp + 1:]
        if not full_oid.startswith(col_oid):
            continue
        this_idx = full_oid[len(col_oid):]
        if this_idx == idx:
            return _strip_quotes(_strip_type_tag(val_raw))
    return None


def main(ctx, params):
    host = params.get("host", "localhost")
    community = params.get("community", "public")
    base = ".1.3.6.1.4.1.476.1.42.3.9.20.1"

    sys_oid_node = _snmpget_bare(ctx, host, community, ".1.3.6.1.2.1.1.2.0")
    if params.get("_discover"):
        if sys_oid_node == None:
            return {
                "changed": False,
                "msg": "no SNMP data (snmpget failed or agent absent)",
                "data": {"discovery": []},
            }
        if not sys_oid_node.startswith(".1.3.6.1.4.1.476.1.42"):
            return {
                "changed": False,
                "msg": "device is not a Lievert unit",
                "data": {"discovery": []},
            }

        names = _snmpwalk_numeric(ctx, host, community, base + ".10")
        if names == None:
            return {
                "changed": False,
                "msg": "Lievert cooling SNMP walk failed",
                "data": {"discovery": []},
            }

        name_by_index = {}
        col_oid = base + ".10."
        for line in names:
            sp = line.find(" ")
            if sp == -1:
                continue
            full_oid = line[:sp]
            val_raw = line[sp + 1:]
            if not full_oid.startswith(col_oid):
                continue
            idx = full_oid[len(col_oid):]
            val_stripped = _strip_quotes(_strip_type_tag(val_raw))
            if val_stripped != "" and idx != "":
                name_by_index[idx] = val_stripped

        if len(name_by_index) == 0:
            return {
                "changed": False,
                "msg": "no Lievert cooling items discovered",
                "data": {"discovery": []},
            }

        discovery = []
        seen_names = {}
        for idx in sorted(name_by_index.keys()):
            name = name_by_index[idx]
            item_name = _dedup_name(name, seen_names)
            min_cap = params.get("min_capacity", [90.0, 80.0])
            max_cap = params.get("max_capacity", None)
            item_params = {}
            if min_cap != None:
                item_params["min_capacity"] = min_cap
            if max_cap != None:
                item_params["max_capacity"] = max_cap
            discovery.append({
                "item": item_name,
                "params": item_params,
                "metrics": ["capacity_perc"],
            })

        return {
            "changed": False,
            "msg": "discovered %d Lievert cooling items" % len(discovery),
            "data": {"discovery": discovery},
        }

    # CHECK MODE
    item = params.get("item", "")
    if item == "":
        return {
            "changed": False,
            "msg": "no cooling item specified",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }

    if sys_oid_node == None:
        return {
            "changed": False,
            "msg": "no SNMP data (snmpget failed or agent absent)",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }
    if not sys_oid_node.startswith(".1.3.6.1.4.1.476.1.42"):
        return {
            "changed": False,
            "msg": "device is not a Lievert unit",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }

    name_by_index = _build_name_index_map(ctx, host, community, base)
    if name_by_index == None:
        return {
            "changed": False,
            "msg": "Lievert cooling SNMP walk failed",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }

    # Build display-name -> index map with dedup matching discovery
    name_to_index = {}
    seen_names = {}
    for idx in sorted(name_by_index.keys()):
        name = name_by_index[idx]
        display = _dedup_name(name, seen_names)
        name_to_index[display] = idx

    if item not in name_to_index:
        return {
            "changed": False,
            "msg": "item not found: %s" % item,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }

    idx = name_to_index[item]

    values = _snmpwalk_numeric(ctx, host, community, base + ".20")
    if values == None:
        return {
            "changed": False,
            "msg": "Lievert cooling SNMP walk failed",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }
    value_str = _lookup_by_index(values, base, "20", idx)
    if value_str == None:
        return {
            "changed": False,
            "msg": "value not found for item: %s" % item,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }

    value = _parse_float(value_str)
    if value == None:
        return {
            "changed": False,
            "msg": "could not parse value: %s" % value_str,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }

    units = _snmpwalk_numeric(ctx, host, community, base + ".30")
    unit = ""
    if units != None:
        u = _lookup_by_index(units, base, "30", idx)
        if u != None:
            unit = u

    min_cap = params.get("min_capacity", [90.0, 80.0])
    max_cap = params.get("max_capacity", None)

    state = "OK"
    render = "%f %s" % (value, unit)

    if min_cap != None and len(min_cap) >= 2:
        warn_lo = min_cap[0]
        crit_lo = min_cap[1]
        if value <= crit_lo:
            state = "CRIT"
        elif value <= warn_lo:
            state = "WARN"

    if max_cap != None and len(max_cap) >= 2:
        warn_hi = max_cap[0]
        crit_hi = max_cap[1]
        if value >= crit_hi:
            state = "CRIT"
        elif value >= warn_hi:
            if state == "OK":
                state = "WARN"

    return {
        "changed": False,
        "msg": "%s %s" % (item, render),
        "data": {
            "state": state,
            "metrics": {"capacity_perc": value},
            "details": "",
        },
    }