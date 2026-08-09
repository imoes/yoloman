# starlark module for mcdata_fcport check
# Reproduces Checkmk's check_plugin_mcdata_fcport

MC_SPEED_BITS = {"2": 1000000000, "3": 2000000000}
MC_OPSTATUS = {"1": "1", "2": "2", "3": "testing", "4": "faulty"}

DEFAULT_WARN = 80
DEFAULT_CRIT = 90

def _hex_to_bytes(hex_str):
    s = hex_str.strip()
    if s.startswith("0x") or s.startswith("0X"):
        s = s[2:]
    if len(s) % 2 != 0:
        s = "0" + s
    out = []
    for i in range(0, len(s), 2):
        out.append(int(s[i:i+2], 16))
    return out

def _bin_to_64(bin_vals):
    total = 0
    power = 1
    rev = list(reversed(bin_vals))
    for i, b in enumerate(rev):
        total += b * power
        power = power * 265
    return total

def _pow(base, exp):
    result = 1
    for _ in range(int(exp)):
        result = result * base
    return result

def _parse_oidbytes_value(val):
    bytes_list = _hex_to_bytes(val)
    return _bin_to_64(bytes_list)

def _walk_oid_table(base_oid, host, community, ctx):
    res = ctx.run(["snmpwalk", "-v2c", "-c", community, "-Oqn", host, base_oid], mutates=False)
    if res.rc != 0:
        return []
    rows = []
    for line in res.stdout.splitlines():
        parts = line.split(" ", 1)
        if len(parts) != 2:
            continue
        oid = parts[0]
        val = parts[1]
        rows.append((oid, val))
    return rows

def _get_sysObjectID(host, community, ctx):
    res = ctx.run(["snmpget", "-v2c", "-c", community, "-Oqv", host, ".1.3.6.1.2.1.1.2.0"], mutates=False)
    if res.rc != 0:
        return ""
    return res.stdout.strip()

def _collect_port_data(host, community, ctx):
    base_oid = ".1.3.6.1.4.1.289.2.1.1.2.3.1.1"

    idx_rows = _walk_oid_table(base_oid + ".1", host, community, ctx)
    opstatus_rows = _walk_oid_table(base_oid + ".3", host, community, ctx)
    speed_rows = _walk_oid_table(base_oid + ".11", host, community, ctx)
    txwords_rows = _walk_oid_table(base_oid + ".67", host, community, ctx)
    rxwords_rows = _walk_oid_table(base_oid + ".68", host, community, ctx)
    txframes_rows = _walk_oid_table(base_oid + ".69", host, community, ctx)
    rxframes_rows = _walk_oid_table(base_oid + ".70", host, community, ctx)
    c3disc_rows = _walk_oid_table(base_oid + ".83", host, community, ctx)
    crcs_rows = _walk_oid_table(base_oid + ".65", host, community, ctx)

    index_data = {}

    for oid, val in idx_rows:
        idx = oid[len(base_oid + ".1") + 1:]
        index_data[idx] = {"index": idx}

    for oid, val in opstatus_rows:
        idx = oid[len(base_oid + ".3") + 1:]
        if idx not in index_data:
            index_data[idx] = {"index": idx}
        index_data[idx]["opStatus"] = val

    for oid, val in speed_rows:
        idx = oid[len(base_oid + ".11") + 1:]
        if idx not in index_data:
            index_data[idx] = {"index": idx}
        index_data[idx]["speed"] = val

    for oid, val in txwords_rows:
        idx = oid[len(base_oid + ".67") + 1:]
        if idx not in index_data:
            index_data[idx] = {"index": idx}
        index_data[idx]["txWords64"] = val

    for oid, val in rxwords_rows:
        idx = oid[len(base_oid + ".68") + 1:]
        if idx not in index_data:
            index_data[idx] = {"index": idx}
        index_data[idx]["rxWords64"] = val

    for oid, val in txframes_rows:
        idx = oid[len(base_oid + ".69") + 1:]
        if idx not in index_data:
            index_data[idx] = {"index": idx}
        index_data[idx]["txFrames64"] = val

    for oid, val in rxframes_rows:
        idx = oid[len(base_oid + ".70") + 1:]
        if idx not in index_data:
            index_data[idx] = {"index": idx}
        index_data[idx]["rxFrames64"] = val

    for oid, val in c3disc_rows:
        idx = oid[len(base_oid + ".83") + 1:]
        if idx not in index_data:
            index_data[idx] = {"index": idx}
        index_data[idx]["c3Discards64"] = val

    for oid, val in crcs_rows:
        idx = oid[len(base_oid + ".65") + 1:]
        if idx not in index_data:
            index_data[idx] = {"index": idx}
        index_data[idx]["crcs"] = val

    return index_data

def main(ctx, params):
    host = params.get("host", "localhost")
    community = params.get("community", "public")

    sysid = _get_sysObjectID(host, community, ctx)
    if not sysid.startswith(".1.3.6.1.4.1.289."):
        return {
            "changed": False,
            "msg": "not an McData device (sysObjectID mismatch)",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }

    index_data = _collect_port_data(host, community, ctx)

    if params.get("_discover"):
        discovery = []
        for idx, data in sorted(index_data.items()):
            name = "%d" % int(idx)
            entry = {
                "item": name,
                "params": {},
                "metrics": ["in_octets", "out_octets", "in_ucast", "out_ucast", "in_err", "out_disc"],
            }
            opstatus = data.get("opStatus", "1")
            status = MC_OPSTATUS.get(opstatus, "unknown")
            entry["service_labels"] = {"oper_status": status}
            discovery.append(entry)
        return {
            "changed": False,
            "msg": "discovered %d ports" % len(discovery),
            "data": {"discovery": discovery},
        }

    item = params.get("item", "")
    raw_index = int(item) if item.isdigit() else None
    if raw_index == None:
        return {
            "changed": False,
            "msg": "invalid item format",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }

    idx = "%d" % raw_index
    data = index_data.get(idx)
    if data == None:
        return {
            "changed": False,
            "msg": "no such port: " + item,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }

    speed_raw = data.get("speed", "0")
    speed = MC_SPEED_BITS.get(speed_raw, 0)

    txwords_raw = data.get("txWords64", "")
    rxwords_raw = data.get("rxWords64", "")
    txframes_raw = data.get("txFrames64", "")
    rxframes_raw = data.get("rxFrames64", "")
    c3disc_raw = data.get("c3Discards64", "")
    crcs_raw = data.get("crcs", "0")

    out_octets = _parse_oidbytes_value(txwords_raw) * 4
    in_octets = _parse_oidbytes_value(rxwords_raw) * 4
    out_ucast = _parse_oidbytes_value(txframes_raw)
    in_ucast = _parse_oidbytes_value(rxframes_raw)
    out_disc = _parse_oidbytes_value(c3disc_raw)
    in_err = int(crcs_raw) if crcs_raw.isdigit() else 0

    metrics = {
        "in_octets": in_octets,
        "out_octets": out_octets,
        "in_ucast": in_ucast,
        "out_ucast": out_ucast,
        "in_err": in_err,
        "out_disc": out_disc,
    }

    warn = params.get("warn", DEFAULT_WARN)
    crit = params.get("crit", DEFAULT_CRIT)

    state = "OK"
    msg_parts = []

    opstatus = data.get("opStatus", "1")
    oper_status = MC_OPSTATUS.get(opstatus, "unknown")
    if oper_status == "testing":
        state = "WARN"
        msg_parts.append("operational status: testing")
    elif oper_status in ("faulty", "unknown"):
        state = "CRIT"
        msg_parts.append("operational status: " + oper_status)
    else:
        msg_parts.append("operational status: up")

    if state == "OK":
        if speed == 0:
            msg_parts.append("no speed info available")
        else:
            speed_mb = speed // 1000000
            msg_parts.append("speed: %d Mbps" % speed_mb)

    detail_msg = ", ".join(msg_parts)

    return {
        "changed": False,
        "msg": detail_msg,
        "data": {"state": state, "metrics": metrics, "details": ""},
    }