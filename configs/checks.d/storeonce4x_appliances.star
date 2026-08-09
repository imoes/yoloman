def main(ctx, params):
    if params.get("_discover"):
        return _do_discover(ctx, params)
    return _do_check(ctx, params)


def _do_discover(ctx, params):
    base = params.get("host", "localhost")
    community = params.get("community", "public")
    res = ctx.run(["snmpwalk", "-v2c", "-c", community, "-Oqn", base, ".1.3.6.1.4.1.23271"], mutates=False)
    if res.rc == 127:
        return {"changed": False, "msg": "snmpwalk not installed", "data": {"discovery": []}}
    if res.rc != 0 or not res.stdout:
        return {"changed": False, "msg": "no storeonce federation data", "data": {"discovery": []}}
    fed = _get_snmp_value(ctx, base, community, ".1.3.6.1.4.1.23271.1.1.0")
    if fed == None:
        return {"changed": False, "msg": "not a storeonce4x appliance", "data": {"discovery": []}}
    federation = _safe_json(fed)
    if federation == None:
        return {"changed": False, "msg": "invalid federation json", "data": {"discovery": []}}
    if federation.get("memberCount", 0) == 0:
        return {"changed": False, "msg": "no storeonce appliances", "data": {"discovery": []}}
    out = []
    for member in federation.get("members", []):
        host = member.get("hostname", "")
        if host:
            out.append({"item": host, "params": {"warn": 80, "crit": 90},
                        "metrics": ["combinedFreeBytes", "combinedCapacityBytes", "dedupeRatio"]})
    return {"changed": False, "msg": "discovered %d storeonce appliances" % len(out),
            "data": {"discovery": out}}


def _do_check(ctx, params):
    item = params.get("item", "")
    base = params.get("host", "localhost")
    community = params.get("community", "public")
    federation = _get_federation_data(ctx, base, community)
    if federation == None:
        return {"changed": False, "msg": "storeonce4x appliance data not available",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    if item not in federation:
        return {"changed": False, "msg": "appliance %s not found in federation" % item,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    federation_member = federation[item]
    dashboard_member = _get_dashboard_member(ctx, base, community, item)
    if dashboard_member == None:
        return {"changed": False, "msg": "dashboard data missing for %s" % item,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    combined_free = dashboard_member.get("localFreeBytes", 0) + dashboard_member.get("cloudFreeBytes", 0)
    combined_capacity = dashboard_member.get("localCapacityBytes", 0) + dashboard_member.get("cloudCapacityBytes", 0)
    dedupe_ratio = dashboard_member.get("dedupeRatio", 0)
    app_state = _APP_STATE_MAP.get(federation_member.get("applianceStateString", ""), "UNKNOWN")
    license_state = _LICENSE_MAP.get(dashboard_member.get("licenseStatus", ""), "UNKNOWN")
    details = "State: %s, Serial Number: %s, Software version: %s, Product Name: %s" % (
        federation_member.get("applianceStateString", "unknown"),
        federation_member.get("serialNumber", "unknown"),
        dashboard_member.get("softwareVersion", "unknown"),
        federation_member.get("productName", "unknown"),
    )
    final_state = _worst_state(app_state, license_state)
    return {"changed": False, "msg": details,
            "data": {"state": final_state, "metrics": {
                "combinedFreeBytes": combined_free,
                "combinedCapacityBytes": combined_capacity,
                "dedupeRatio": dedupe_ratio,
            }, "details": "License: %s" % dashboard_member.get("licenseStatusString", "unknown")}}


def _get_snmp_value(ctx, base, community, oid):
    res = ctx.run(["snmpget", "-v2c", "-c", community, "-Oqv", base, oid], mutates=False)
    if res.rc != 0:
        return None
    v = res.stdout.strip()
    if not v:
        return None
    return v


def _get_federation_data(ctx, base, community):
    raw = _get_snmp_value(ctx, base, community, ".1.3.6.1.4.1.23271.1.1.0")
    if raw == None:
        return None
    return _safe_json(raw)


def _get_dashboard_member(ctx, base, community, hostname):
    res = ctx.run(["snmpwalk", "-v2c", "-c", community, "-Oqn", base, ".1.3.6.1.4.1.23271.1.2"], mutates=False)
    if res.rc != 0:
        return None
    for line in res.stdout.splitlines():
        parts = line.split(" ", 1)
        if len(parts) < 2:
            continue
        val = parts[1].strip()
        if val.startswith("STRING: "):
            val = val[len("STRING: "):]
        if val.startswith('"') and val.endswith('"'):
            val = val[1:-1]
        member = _safe_json(val)
        if member == None:
            continue
        if member.get("hostname", "") == hostname:
            return member
    return None


def _safe_json(s):
    if not s:
        return None
    d = json.decode(s)
    if type(d) != "dict":
        return None
    return d


def _worst_state(a, b):
    order = {"OK": 0, "WARN": 1, "CRIT": 2, "UNKNOWN": 3}
    ra = order.get(a, 3)
    rb = order.get(b, 3)
    if ra >= rb:
        return a
    return b


_APP_STATE_MAP = {"Reachable": "OK", "Unreachable": "CRIT", "Unknown": "UNKNOWN"}


_LICENSE_MAP = {
    "OK": "OK",
    "WARNING": "WARN",
    "CRITICAL": "CRIT",
    "NOT_HARDWARE": "UNKNOWN",
    "NOT_APPLICABLE": "UNKNOWN",
}