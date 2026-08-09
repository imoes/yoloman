# Translated from Checkmk ucd_diskio check plugin (SNMP-based, UCD-HR MIB disk IO).

def _detect_host(ctx, params):
    host = params.get("host", "localhost")
    community = params.get("community", "public")
    version = params.get("version", "2c")
    return host, community, version

def _snmp_get(ctx, params, oid):
    host, community, version = _detect_host(ctx, params)
    res = ctx.run([
        "snmpget",
        "-v" + version,
        "-c", community,
        "-Oqv",
        host,
        oid,
    ], mutates=False)
    return res

def _snmp_walk(ctx, params, oid):
    host, community, version = _detect_host(ctx, params)
    res = ctx.run([
        "snmpwalk",
        "-v" + version,
        "-c", community,
        "-Oqn",
        host,
        oid,
    ], mutates=False)
    return res

def _strip_type_tag(value):
    idx = value.find(": ")
    if idx >= 0:
        value = value[idx + 2:]
    if len(value) >= 2 and value[0] == '"' and value[-1] == '"':
        value = value[1:-1]
    return value

def _is_digit_str(s):
    if s == "":
        return False
    i = 0
    if s[0] == "-":
        i = 1
        if len(s) == 1:
            return False
    seen_dot = False
    while i < len(s):
        ch = s[i]
        if ch == ".":
            if seen_dot:
                return False
            seen_dot = True
        elif not (ch >= "0" and ch <= "9"):
            return False
        i = i + 1
    return True

def _to_float(value):
    if value == None:
        return None
    v = value.strip()
    if v == "":
        return None
    if v[0] == "-":
        rest = v[1:]
        if rest == "" or not _is_digit_str(rest):
            return None
    elif not _is_digit_str(v):
        return None
    neg = v[0] == "-"
    body = v[1:] if neg else v
    dot = body.find(".")
    intpart = body
    fracpart = ""
    if dot >= 0:
        intpart = body[:dot]
        fracpart = body[dot + 1:]
    if intpart == "":
        intpart = "0"
    if fracpart == "":
        fracpart = "0"
    result = 0.0
    for ch in intpart:
        result = result * 10.0 + (ord(ch) - 48)
    fracval = 0.0
    for ch in reversed(fracpart):
        fracval = (fracval + (ord(ch) - 48)) / 10.0
    result = result + fracval
    if neg:
        result = -result
    return result

def main(ctx, params):
    if params.get("_discover"):
        sysoid = ".1.3.6.1.4.1.2021.13.15.1.1.1"
        res = _snmp_walk(ctx, params, sysoid)
        if res.rc != 0:
            return {
                "changed": False,
                "msg": "SNMP not available",
                "data": {"discovery": []},
            }
        lines = res.stdout.splitlines()
        if not lines:
            return {
                "changed": False,
                "msg": "no UCD diskio devices found",
                "data": {"discovery": []},
            }
        namecol = ".1.3.6.1.4.1.2021.13.15.1.1.2"
        nres = _snmp_walk(ctx, params, namecol)
        if nres.rc != 0:
            return {
                "changed": False,
                "msg": "SNMP not available for device names",
                "data": {"discovery": []},
            }
        discovery = []
        seen = set()
        for line in nres.stdout.splitlines():
            if not line.strip():
                continue
            sp = line.find(" ")
            if sp < 0:
                continue
            oid = line[:sp]
            value = line[sp + 1:]
            value = _strip_type_tag(value)
            idx = oid[len(namecol) + 1:]
            if idx in seen:
                continue
            if not value:
                continue
            seen.add(idx)
            discovery.append({
                "item": value,
                "params": {},
                "metrics": ["read_throughput", "write_throughput", "read_ios", "write_ios", "used_percent"],
            })
        return {
            "changed": False,
            "msg": "discovered %d diskio devices" % len(discovery),
            "data": {"discovery": discovery},
        }

    item = params.get("item", "")

    base = ".1.3.6.1.4.1.2021.13.15.1.1"
    col_index = base + ".1"
    col_name = base + ".2"
    col_read_size = base + ".3"
    col_write_size = base + ".4"
    col_reads = base + ".5"
    col_writes = base + ".6"

    nres = _snmp_walk(ctx, params, col_name)
    if nres.rc != 0:
        return {
            "changed": False,
            "msg": "SNMP not available: " + nres.stderr,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }

    disk_index = None
    found = False
    for line in nres.stdout.splitlines():
        if not line.strip():
            continue
        sp = line.find(" ")
        if sp < 0:
            continue
        oid = line[:sp]
        value = line[sp + 1:]
        value = _strip_type_tag(value)
        idx = oid[len(col_name) + 1:]
        if value == item:
            disk_index = idx
            found = True
            break

    if not found or disk_index == None:
        return {
            "changed": False,
            "msg": "disk not found: " + item,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }

    def _get(col_oid):
        r = _snmp_get(ctx, params, col_oid + "." + disk_index)
        if r.rc != 0:
            return None
        v = r.stdout.strip()
        v = _strip_type_tag(v)
        if not v:
            return None
        return _to_float(v)

    read_size = _get(col_read_size)
    write_size = _get(col_write_size)
    reads = _get(col_reads)
    writes = _get(col_writes)

    if read_size == None and write_size == None and reads == None and writes == None:
        return {
            "changed": False,
            "msg": "no data for disk " + item,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }

    metrics = {}
    if read_size != None:
        metrics["read_throughput"] = read_size
    if write_size != None:
        metrics["write_throughput"] = write_size
    if reads != None:
        metrics["read_ios"] = reads
    if writes != None:
        metrics["write_ios"] = writes

    detail = "[%s] read_b=%s write_b=%s reads=%s writes=%s" % (
        disk_index,
        read_size,
        write_size,
        reads,
        writes,
    )

    return {
        "changed": False,
        "msg": "Disk IO %s: %s" % (item, detail),
        "data": {
            "state": "OK",
            "metrics": metrics,
            "details": detail,
        },
    }