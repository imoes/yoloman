def main(ctx, params):
    if params.get("_discover"):
        return _discover(ctx, params)
    return _check(ctx, params)

_SCALEIO_POOL_TABLE_OID = ".1.3.6.1.4.1.43577.1.2"
_SCALEIO_POOL_NAME_OID = ".1.3.6.1.4.1.43577.1.2.1.2"
_SCALEIO_POOL_READ_IOPS_OID = ".1.3.6.1.4.1.43577.1.2.1.3"
_SCALEIO_POOL_READ_BYTES_OID = ".1.3.6.1.4.1.43577.1.2.1.4"
_SCALEIO_POOL_READ_UNIT_OID = ".1.3.6.1.4.1.43577.1.2.1.5"
_SCALEIO_POOL_WRITE_IOPS_OID = ".1.3.6.1.4.1.43577.1.2.1.6"
_SCALEIO_POOL_WRITE_BYTES_OID = ".1.3.6.1.4.1.43577.1.2.1.7"
_SCALEIO_POOL_WRITE_UNIT_OID = ".1.3.6.1.4.1.43577.1.2.1.8"

_KNOWN_UNITS_BYTES = {
    "Bytes": 1.0,
    "KB": 1024.0,
    "MB": 1048576.0,
    "GB": 1073741824.0,
    "TB": 1099511627776.0,
}
_KNOWN_UNITS_MB = {
    "Bytes": 1.0 / 1048576.0,
    "KB": 1.0 / 1024.0,
    "MB": 1.0,
    "GB": 1024.0,
    "TB": 1048576.0,
}

def _convert_throughput(unit, throughput):
    factor = _KNOWN_UNITS_BYTES.get(unit)
    if factor == None:
        return None, unit
    return throughput * factor, None

def _convert_to_mb(unit, value):
    factor = _KNOWN_UNITS_MB.get(unit)
    if factor == None:
        return None, unit
    return value * factor, None

def _probe_for_pools(ctx, params):
    host = params.get("host", "localhost")
    community = params.get("community", "public")
    walk = ctx.run(
        ["snmpwalk", "-v2c", "-c", community, "-Oqn", host,
         _SCALEIO_POOL_TABLE_OID],
        mutates=False,
    )
    if walk.rc != 0:
        return None
    pools = {}
    for line in walk.stdout.splitlines():
        parts = line.split(" ", 1)
        if len(parts) < 2:
            continue
        oid = parts[0]
        val = parts[1]
        idx = oid[len(_SCALEIO_POOL_TABLE_OID) + 1:]
        if not idx:
            continue
        if oid == _SCALEIO_POOL_NAME_OID + "." + idx:
            pools.setdefault(idx, {})["name"] = val
        elif oid == _SCALEIO_POOL_READ_IOPS_OID + "." + idx:
            pools.setdefault(idx, {})["read_ops"] = val
        elif oid == _SCALEIO_POOL_READ_BYTES_OID + "." + idx:
            pools.setdefault(idx, {})["read_bytes"] = val
        elif oid == _SCALEIO_POOL_READ_UNIT_OID + "." + idx:
            pools.setdefault(idx, {})["read_unit"] = val
        elif oid == _SCALEIO_POOL_WRITE_IOPS_OID + "." + idx:
            pools.setdefault(idx, {})["write_ops"] = val
        elif oid == _SCALEIO_POOL_WRITE_BYTES_OID + "." + idx:
            pools.setdefault(idx, {})["write_bytes"] = val
        elif oid == _SCALEIO_POOL_WRITE_UNIT_OID + "." + idx:
            pools.setdefault(idx, {})["write_unit"] = val
    return pools

def _discover(ctx, params):
    pools = _probe_for_pools(ctx, params)
    if pools == None:
        return {"changed": False, "msg": "ScaleIO not reachable via SNMP",
                "data": {"discovery": []}}
    discovery = []
    for idx in sorted(pools.keys()):
        p = pools[idx]
        name = p.get("name", idx)
        discovery.append({
            "item": idx,
            "params": {"warn_read_iops": None, "crit_read_iops": None,
                       "warn_write_iops": None, "crit_write_iops": None,
                       "warn_read_tp": None, "crit_read_tp": None,
                       "warn_write_tp": None, "crit_write_tp": None,
                       "name": name},
            "metrics": ["read_ios", "write_ios", "read_throughput", "write_throughput"],
        })
    return {"changed": False,
            "msg": "discovered %d ScaleIO storage pools" % len(discovery),
            "data": {"discovery": discovery,
                     "host_labels": {"cmk/snmp": "yes"}}}

def _is_float(s):
    if s == None or s == "":
        return False
    if s.startswith("-"):
        s = s[1:]
    parts = s.split(".")
    if len(parts) > 2:
        return False
    for p in parts:
        if p == "" or not p.isdigit():
            return False
    return True

def _to_float(v):
    if v == None:
        return 0.0
    if _is_float(str(v)):
        return float(v)
    return 0.0

def _fmt(v):
    if v == None:
        return "n/a"
    if v == int(v):
        return str(int(v))
    return str(v)

def _check_item(ctx, params, pools, item_id):
    pool = pools.get(item_id)
    if pool == None:
        return {"changed": False,
                "msg": "no such ScaleIO storage pool: " + item_id,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    name = pool.get("name", item_id)

    read_ops_s = pool.get("read_ops", "")
    write_ops_s = pool.get("write_ops", "")
    read_bytes_s = pool.get("read_bytes", "")
    write_bytes_s = pool.get("write_bytes", "")
    read_unit = pool.get("read_unit", "")
    write_unit = pool.get("write_unit", "")

    read_ops = int(read_ops_s) if (read_ops_s != None and read_ops_s.isdigit()) else 0
    write_ops = int(write_ops_s) if (write_ops_s != None and write_ops_s.isdigit()) else 0

    read_bytes_raw = float(read_bytes_s) if _is_float(read_bytes_s) else 0.0
    write_bytes_raw = float(write_bytes_s) if _is_float(write_bytes_s) else 0.0

    read_bytes, read_err = _convert_throughput(read_unit, read_bytes_raw)
    write_bytes, write_err = _convert_throughput(write_unit, write_bytes_raw)

    state = "OK"
    msgs = []
    details = []

    if read_err != None:
        state = "UNKNOWN"
        msgs.append("Unknown read unit: %s" % read_err)
    if write_err != None:
        state = "UNKNOWN"
        msgs.append("Unknown write unit: %s" % write_err)

    metrics = {
        "read_ios": read_ops,
        "write_ios": write_ops,
    }
    if read_bytes != None:
        metrics["read_throughput"] = read_bytes
    if write_bytes != None:
        metrics["write_throughput"] = write_bytes

    warn_read_iops = params.get("warn_read_iops")
    crit_read_iops = params.get("crit_read_iops")
    warn_write_iops = params.get("warn_write_iops")
    crit_write_iops = params.get("crit_write_iops")
    warn_read_tp = params.get("warn_read_tp")
    crit_read_tp = params.get("crit_read_tp")
    warn_write_tp = params.get("warn_write_tp")
    crit_write_tp = params.get("crit_write_tp")

    if read_err == None and write_err == None:
        if (crit_read_iops != None and read_ops >= _to_float(crit_read_iops)) or \
           (crit_write_iops != None and write_ops >= _to_float(crit_write_iops)):
            state = "CRIT"
        elif (warn_read_iops != None and read_ops >= _to_float(warn_read_iops)) or \
             (warn_write_iops != None and write_ops >= _to_float(warn_write_iops)):
            if state == "OK":
                state = "WARN"

        if crit_read_tp != None and read_bytes != None and read_bytes >= _to_float(crit_read_tp):
            state = "CRIT"
        elif warn_read_tp != None and read_bytes != None and read_bytes >= _to_float(warn_read_tp):
            if state == "OK":
                state = "WARN"

        if crit_write_tp != None and write_bytes != None and write_bytes >= _to_float(crit_write_tp):
            state = "CRIT"
        elif warn_write_tp != None and write_bytes != None and write_bytes >= _to_float(warn_write_tp):
            if state == "OK":
                state = "WARN"

    summary = "Name: %s, read: %d ops / %s B/s, write: %d ops / %s B/s" % \
              (name, read_ops,
               _fmt(read_bytes), write_ops, _fmt(write_bytes))
    if msgs:
        summary = summary + "; " + ", ".join(msgs)

    return {"changed": False, "msg": summary,
            "data": {"state": state, "metrics": metrics,
                     "details": "Name: %s" % name}}

def _check(ctx, params):
    item = params.get("item", "")
    pools = _probe_for_pools(ctx, params)
    if pools == None:
        return {"changed": False,
                "msg": "ScaleIO not reachable via SNMP",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    if len(pools) == 0:
        return {"changed": False,
                "msg": "no ScaleIO storage pools found",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    return _check_item(ctx, params, pools, item)