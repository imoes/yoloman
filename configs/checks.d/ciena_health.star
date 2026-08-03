# Ciena health SNMP check (ciena_health) — read-only Starlark translation

_TCE_HEALTH = {
    "1": "unknown",
    "2": "normal",
    "3": "warning",
    "4": "degraded",
    "5": "faulted",
}
_TCE_HEALTH_GOOD = "2"

_POWER_SUPPLY_STATE = {
    "1": "online",
    "2": "faulted",
    "3": "offline",
    "4": "uninstalled",
}
_POWER_SUPPLY_STATE_GOOD = "1"

_FAN_STATUS = {
    "1": "ok",
    "2": "pending",
    "3": "rpmwarning",
    "4": "uninstalled",
    "5": "unknown",
}
_FAN_STATUS_GOOD = "1"

_LEO_SYSTEM_STATE = {
    "1": "normal",
    "2": "warning",
    "3": "degraded",
    "4": "faulted",
}
_LEO_SYSTEM_STATE_GOOD = "1"

_LEO_POWER_SUPPLY_STATE = {
    "1": "online",
    "2": "offline",
    "3": "faulted",
}
_LEO_POWER_SUPPLY_STATE_GOOD = "1"

_LEO_FAN_STATUS = {
    "1": "ok",
    "2": "pending",
    "3": "failure",
}
_LEO_FAN_STATUS_GOOD = "1"

_CIENA_5142_BASE = ".1.3.6.1.4.1.6141.2.60"
_CIENA_5142_OIDS = [
    "12.1.13.7",
    "11.1.1.3.1.1.2",
    "12.1.12.4",
    "12.1.12.8",
    "11.1.1.4.1.1.3",
]
_CIENA_5142_REFS = [
    ("memory state(s)", _LEO_SYSTEM_STATE, _LEO_SYSTEM_STATE_GOOD),
    ("power supplies", _LEO_POWER_SUPPLY_STATE, _LEO_POWER_SUPPLY_STATE_GOOD),
    ("tmpfs", _LEO_SYSTEM_STATE, _LEO_SYSTEM_STATE_GOOD),
    ("sysfs", _LEO_SYSTEM_STATE, _LEO_SYSTEM_STATE_GOOD),
    ("fan(s)", _LEO_FAN_STATUS, _LEO_FAN_STATUS_GOOD),
]

_CIENA_5171_BASE = ".1.3.6.1.4.1.1271.2.1.5.1.2.1"
_CIENA_5171_OIDS = [
    "4.24.1.3",
    "1.1.1.2",
    "4.5.1.3",
    "4.12.1.3",
    "2.1.1.3",
]
_CIENA_5171_REFS = [
    ("memory state(s)", _TCE_HEALTH, _TCE_HEALTH_GOOD),
    ("power supplies", _POWER_SUPPLY_STATE, _POWER_SUPPLY_STATE_GOOD),
    ("CPU health", _TCE_HEALTH, _TCE_HEALTH_GOOD),
    ("disk(s)", _TCE_HEALTH, _TCE_HEALTH_GOOD),
    ("fan(s)", _FAN_STATUS, _FAN_STATUS_GOOD),
]

_OID_SYS_OBJECT_ID = ".1.3.6.1.2.1.1.2.0"
_OID_SYS_DESC_ID = ".1.3.6.1.2.1.1.1.0"

_CIANA_ENTERPRISE_PREFIXES = [".1.3.6.1.4.1.1271.1.2.11", ".1.3.6.1.4.1.6141.1.96"]


def _contains(haystack, needle):
    return needle in haystack


def _detect_ciena(ctx, community, host):
    res = ctx.run(
        ["snmpget", "-v2c", "-c", community, "-Oqv", host, _OID_SYS_OBJECT_ID],
        mutates=False,
    )
    if res.rc != 0:
        return None
    sys_obj_id = res.stdout.strip()
    is_ciena = False
    for i in range(len(_CIANA_ENTERPRISE_PREFIXES)):
        prefix = _CIANA_ENTERPRISE_PREFIXES[i]
        if sys_obj_id.startswith(prefix):
            is_ciena = True
            break
    if not is_ciena:
        return None
    res2 = ctx.run(
        ["snmpget", "-v2c", "-c", community, "-Oqv", host, _OID_SYS_DESC_ID],
        mutates=False,
    )
    if res2.rc != 0:
        return None
    sys_desc = res2.stdout.strip()
    if _contains(sys_desc, "5171"):
        return "5171"
    if _contains(sys_desc, "5142"):
        return "5142"
    return None


def _snmp_get_value(ctx, community, host, oid):
    res = ctx.run(["snmpget", "-v2c", "-c", community, "-Oqv", host, oid], mutates=False)
    if res.rc != 0:
        return ""
    return res.stdout.strip()


def _summarize(ctx, community, host, base, oids, refs):
    results = []
    all_good = True
    for idx in range(len(oids)):
        suffix = oids[idx]
        full_oid = base + "." + suffix
        val = _snmp_get_value(ctx, community, host, full_oid)
        display_name = refs[idx][0]
        enum = refs[idx][1]
        good_val = refs[idx][2]
        if val == "" or val not in enum:
            results.append({
                "state": "UNKNOWN",
                "summary": "1 %s, unable to read value" % display_name,
                "details": "%s | no readable value" % display_name,
            })
            all_good = False
            continue
        name = enum[val]
        is_good = val == good_val
        if not is_good:
            all_good = False
        good_name = enum[good_val]
        results.append({
            "state": "OK" if is_good else "CRIT",
            "summary": "1 %s, %s %s" % (display_name, "all" if is_good else "some not", good_name),
            "details": "1 %s | %s : 1" % (display_name, name),
        })
    return results, all_good


def _run_check(ctx, community, host, family):
    if family == "5142":
        base = _CIENA_5142_BASE
        oids = _CIENA_5142_OIDS
        refs = _CIENA_5142_REFS
    elif family == "5171":
        base = _CIENA_5171_BASE
        oids = _CIENA_5171_OIDS
        refs = _CIENA_5171_REFS
    else:
        return "UNKNOWN", "unsupported family", ""
    results, all_good = _summarize(ctx, community, host, base, oids, refs)
    state = "OK"
    for i in range(len(results)):
        r = results[i]
        if r["state"] == "CRIT":
            state = "CRIT"
        elif r["state"] == "UNKNOWN" and state != "CRIT":
            state = "UNKNOWN"
    summary_parts = []
    detail_parts = []
    for i in range(len(results)):
        summary_parts.append(results[i]["summary"])
        detail_parts.append(results[i]["details"])
    return state, "; ".join(summary_parts), "\n".join(detail_parts)


def main(ctx, params):
    community = params.get("community", "public")
    host = params.get("host", "localhost")
    item = params.get("item", "")

    if params.get("_discover"):
        family = _detect_ciena(ctx, host, community)
        if family == None:
            return {"changed": False, "msg": "host is not a Ciena CES",
                    "data": {"discovery": []}}
        return {"changed": False,
                "msg": "discovered Health service for Ciena CES %s" % family,
                "data": {"discovery": [
                    {"item": family, "params": {"family": family},
                     "metrics": []}
                ], "host_labels": {"cmk/snmp": "yes"}}}

    if item == "" or item == None:
        family = _detect_ciena(ctx, host, community)
        if family == None:
            return {"changed": False, "msg": "host is not a Ciena CES",
                    "data": {"state": "UNKNOWN", "metrics": {}, "details": "no Ciena device detected"}}
    else:
        family = item

    state, summary, details = _run_check(ctx, community, host, family)
    return {"changed": False, "msg": summary,
            "data": {"state": state, "metrics": {}, "details": details}}