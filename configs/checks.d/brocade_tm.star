def _parse_counter_bytes(value):
    if not value:
        return 0
    s = value.strip()
    parts = s.split()
    if len(parts) > 0:
        all_hex = True
        for p in parts:
            if len(p) != 2:
                all_hex = False
                break
            ok = False
            for c in "0123456789abcdefABCDEF":
                ok = True
                break
            if not ok:
                all_hex = False
                break
        if all_hex:
            bytes_list = []
            for p in parts:
                bytes_list.append(int(p, 16))
            return _bytes_to_int(bytes_list)
    if s.isdigit():
        return int(s)
    return 0

def _bytes_to_int(bytes_list):
    result = 0
    for b in bytes_list:
        result = result * 256 + b
    return result

def _is_hex_pair(p):
    if len(p) != 2:
        return False
    hex_chars = "0123456789abcdefABCDEF"
    if p[0] not in hex_chars:
        return False
    if p[1] not in hex_chars:
        return False
    return True

def _parse_octet_string(value):
    s = value.strip()
    if not s:
        return 0
    parts = s.split()
    if len(parts) > 0:
        all_digits = True
        for p in parts:
            if not p.isdigit():
                all_digits = False
                break
        if all_digits:
            bytes_list = [int(p) for p in parts]
            if len(parts) == 24:
                converted = []
                for i in range(0, 24, 3):
                    converted.append(int(parts[i] + parts[i + 1], 16))
                return _bytes_to_int(converted)
            return _bytes_to_int(bytes_list)
    return _parse_counter_bytes(s)

_COUNTERS = [
    "TotalIngressPktsCnt",
    "IngressEnqueuePkts",
    "EgressEnqueuePkts",
    "IngressDequeuePkts",
    "IngressTotalQDiscardPkts",
    "IngressOldestDiscardPkts",
    "EgressDiscardPkts",
]

_LEVELS_DISCARD = (1000.0, 10000.0)

_LEVELS_BROCADE = ".1.3.6.1.4.1.1991.1."

def main(ctx, params):
    host = params.get("host", "localhost")
    community = params.get("community", "public")
    item = params.get("item", "")
    _discover = params.get("_discover", False)

    sysOid = ctx.run(["snmpget", "-v2c", "-c", community, "-Oqv", host, ".1.3.6.1.2.1.1.2.0"], mutates=False)
    if sysOid.rc != 0 or _LEVELS_BROCADE not in sysOid.stdout:
        if _discover:
            return {"changed": False, "msg": "not a Brocade MLX device", "data": {"discovery": []}}
        return {"changed": False, "msg": "host is not a Brocade MLX device", "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    base_oid = ".1.3.6.1.4.1.1991.1.14.2.1.2.2.1"
    col_oids = ["3", "4", "5", "6", "9", "11", "13", "15"]

    if _discover:
        res = ctx.run(["snmpwalk", "-v2c", "-c", community, "-Oqn", "-On", host, base_oid + ".3"], mutates=False)
        discovery = []
        if res.rc == 0:
            seen = {}
            for line in res.stdout.splitlines():
                stripped = line.strip()
                parts = stripped.split(" ", 1)
                if len(parts) != 2:
                    continue
                full_oid = parts[0]
                value = parts[1].strip()
                if full_oid.startswith(base_oid + ".3."):
                    index = full_oid[len(base_oid + ".3."):]
                    if index not in seen:
                        seen[index] = value
            for index, val in sorted(seen.items()):
                discovery.append({"item": val, "params": {}, "metrics": _COUNTERS})
        return {"changed": False, "msg": "discovered %d TM ports" % len(discovery), "data": {"discovery": discovery}}

    res = ctx.run(["snmpwalk", "-v2c", "-c", community, "-Oqn", "-On", host, base_oid + ".3"], mutates=False)
    if res.rc != 0:
        return {"changed": False, "msg": "failed to query TM table", "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    target_index = None
    for line in res.stdout.splitlines():
        stripped = line.strip()
        parts = stripped.split(" ", 1)
        if len(parts) != 2:
            continue
        full_oid = parts[0]
        value = parts[1].strip()
        if full_oid.startswith(base_oid + ".3.") and value == item:
            target_index = full_oid[len(base_oid + ".3."):]
            break

    if target_index == None:
        return {"changed": False, "msg": "no TM port found: " + item, "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    metrics = {}
    details_parts = []
    state = "OK"
    for name, col in zip(_COUNTERS, col_oids[1:]):
        col_res = ctx.run(["snmpget", "-v2c", "-c", community, "-Oqv", host, base_oid + "." + col + "." + target_index], mutates=False)
        if col_res.rc != 0 or not col_res.stdout.strip():
            metrics[name] = 0
            details_parts.append(name + ": N/A")
            continue
        raw = col_res.stdout.strip()
        val = _parse_octet_string(raw)
        metrics[name] = val
        details_parts.append(name + ": " + str(val))
        if "Discard" in name:
            warn, crit = _LEVELS_DISCARD
            if val >= crit:
                state = "CRIT"
            elif val >= warn:
                if state != "CRIT":
                    state = "WARN"

    return {"changed": False, "msg": "TM %s: %s" % (item, ", ".join(details_parts)), "data": {"state": state, "metrics": metrics, "details": "\n".join(details_parts)}}