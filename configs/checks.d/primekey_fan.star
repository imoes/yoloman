# primekey_fan.check — translated from Checkmk primekey_fan check plugin.
# SNMP based: reads fan speed + status OIDs from the PrimeKey enterprise MIB.

def _snmp_get(ctx, host, community, oid):
    res = ctx.run(
        ["snmpget", "-v2c", "-c", community, "-Oqv", host, oid],
        mutates=False,
    )
    if res.rc != 0:
        return None
    val = res.stdout.strip()
    if val == "":
        return None
    return val

def _to_float(s):
    if s == None:
        return None
    s = s.strip()
    if s == "" or s == "NOSUCHOBJECT" or s == "NOSUCHINSTANCE":
        return None
    if s.startswith("INTEGER: "):
        s = s[len("INTEGER: ") - 1:]
    parts = s.split()
    if len(parts) > 1:
        s = parts[0]
    neg = s.startswith("-")
    body = s[1:] if neg else s
    if body == "" or not body.replace(".", "").isdigit():
        return None
    return float(s)

def main(ctx, params):
    host = params.get("host", "localhost")
    community = params.get("community", "public")

    # Base OID for the PrimeKey fan table (the SNMPTree fetch base).
    # The Checkmk source appends: 49.1, 50.1, 51.1, 52.1, 53.1, 54.1
    base = ".1.3.6.1.4.1.22408.1.1.2.1.4.102.97.110"

    # Per-item OIDs relative to base:
    cpu_fan_oid = base + ".49.1"
    sys_fan1_oid = base + ".50.1"
    sys_fan2_oid = base + ".51.1"
    sys_fan3_oid = base + ".52.1"
    status_cpu_oid = base + ".53.1"
    status_sys_oid = base + ".54.1"

    if params.get("_discover"):
        # Probe that the device is a PrimeKey product first (DETECT_PRIMEKEY =
        # sysObjectID equals .1.3.6.1.4.1.8072.3.2.10). If not present, no items.
        sysid = _snmp_get(ctx, host, community, ".1.3.6.1.2.1.1.2.0")
        if sysid == None or sysid != ".1.3.6.1.4.1.8072.3.2.10":
            return {"changed": False, "msg": "not a PrimeKey device",
                    "data": {"discovery": []}}

        # Read speeds to know which fans actually exist.
        cpu = _to_float(_snmp_get(ctx, host, community, cpu_fan_oid))
        s1 = _to_float(_snmp_get(ctx, host, community, sys_fan1_oid))
        s2 = _to_float(_snmp_get(ctx, host, community, sys_fan2_oid))
        s3 = _to_float(_snmp_get(ctx, host, community, sys_fan3_oid))

        items = []
        lower = params.get("lower", (1000, 0))
        output_metrics = params.get("output_metrics", True)
        p = {"lower": lower, "output_metrics": output_metrics}
        # Only emit items where a real reading was obtained.
        if cpu != None:
            items.append({"item": "CPU", "params": p, "metrics": ["fan"]})
        if s1 != None:
            items.append({"item": "1", "params": p, "metrics": ["fan"]})
        if s2 != None:
            items.append({"item": "2", "params": p, "metrics": ["fan"]})
        if s3 != None:
            items.append({"item": "3", "params": p, "metrics": ["fan"]})

        return {"changed": False,
                "msg": "discovered %d items" % len(items),
                "data": {"discovery": items}}

    # ---- check mode ----
    item = params.get("item", "")

    # Re-probe the PrimeKey device identity.
    sysid = _snmp_get(ctx, host, community, ".1.3.6.1.2.1.1.2.0")
    if sysid == None:
        return {"changed": False, "msg": "PrimeKey device unreachable (SNMP no response)",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    if sysid != ".1.3.6.1.4.1.8072.3.2.10":
        return {"changed": False, "msg": "not a PrimeKey device (sysObjectID=%s)" % sysid,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    # Gather the fan table values.
    cpu = _to_float(_snmp_get(ctx, host, community, cpu_fan_oid))
    s1 = _to_float(_snmp_get(ctx, host, community, sys_fan1_oid))
    s2 = _to_float(_snmp_get(ctx, host, community, sys_fan2_oid))
    s3 = _to_float(_snmp_get(ctx, host, community, sys_fan3_oid))
    cstat = _to_float(_snmp_get(ctx, host, community, status_cpu_oid))
    sstat = _to_float(_snmp_get(ctx, host, community, status_sys_oid))

    # Map item -> speed & failed flag, mirroring parse_fan().
    fans = {}
    if cpu != None:
        fans["CPU"] = {"speed": cpu, "fail": bool(int(cstat)) if cstat != None else False}
    if s1 != None:
        fans["1"] = {"speed": s1, "fail": bool(int(sstat)) if sstat != None else False}
    if s2 != None:
        fans["2"] = {"speed": s2, "fail": bool(int(sstat)) if sstat != None else False}
    if s3 != None:
        fans["3"] = {"speed": s3, "fail": bool(int(sstat)) if sstat != None else False}

    fan = fans.get(item)
    if fan == None:
        return {"changed": False, "msg": "no such fan: %s" % item,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    # check_fan logic: lower levels (speed in RPM). WARN if speed <= warn,
    # CRIT if speed <= crit. Default levels (1000, 0) => crit at 0.
    lower = params.get("lower", (1000, 0))
    warn = lower[0] if len(lower) >= 2 else 1000
    crit = lower[1] if len(lower) >= 2 else 0

    output_metrics = params.get("output_metrics", True)
    speed = fan["speed"]

    state = "OK"
    if fan["fail"]:
        state = "CRIT"
    else:
        if speed != None:
            if crit > 0 and speed <= crit:
                state = "CRIT"
            elif speed <= warn:
                state = "WARN"

    metrics = {}
    if output_metrics and speed != None:
        metrics["fan"] = speed

    details = "Speed: %s RPM" % str(speed) if speed != None else "Speed: unknown"
    if fan["fail"]:
        msg = "Status %s fan not OK" % item
    else:
        msg = "Fan %s: %s RPM" % (item, str(speed)) if speed != None else "Fan %s speed unknown" % item

    return {"changed": False, "msg": msg,
            "data": {"state": state, "metrics": metrics, "details": details}}