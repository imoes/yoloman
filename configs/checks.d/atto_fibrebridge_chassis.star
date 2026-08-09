# Translated Checkmk check: checkmk.atto_fibrebridge_chassis
# Read-only Starlark check module for the yolo-man agent.

def _snmp_get_str(ctx, community, host, oid):
    res = ctx.run(["snmpget", "-v2c", "-c", community, "-Oqv", host, oid], mutates=False)
    if res.rc != 0:
        return None
    return res.stdout.strip()

def _probe_hostid(ctx, community, host):
    # Detect Atotech/Atto Fibrebridge: sysObjectID startswith .1.3.6.1.4.1.4547
    val = _snmp_get_str(ctx, community, host, ".1.3.6.1.2.1.1.2.0")
    if val == None:
        return None
    # -Oqv already strips value; for an OID the value prints numerically
    return val

def _get_int_str(ctx, community, host, oid):
    val = _snmp_get_str(ctx, community, host, oid)
    if val == None:
        return None
    s = val
    # strip any leading/trailing whitespace and surrounding quotes
    s = s.strip().strip('"')
    if s.lstrip("-").isdigit():
        return int(s)
    return None

def main(ctx, params):
    host = params.get("host", "localhost")
    community = params.get("community", "public")

    # Discovery: confirm this is an Atto Fibrebridge device.
    sys_obj = _probe_hostid(ctx, community, host)
    if sys_obj == None or not sys_obj.startswith(".1.3.6.1.4.1.4547"):
        return {"changed": False, "msg": "no Atto Fibrebridge device found",
                "data": {"discovery": []}}

    if params.get("_discover"):
        # Single-service check: one item "" yielding throughput_status.
        return {
            "changed": False,
            "msg": "discovered 1 item",
            "data": {"discovery": [
                {"item": "", "params": {}, "metrics": ["throughput_status"]},
            ]},
        }

    # Check mode: read the throughput status OID base .1.3.6.1.4.1.4547.2.3.2
    # OIDs fetched by SNMPTree in source: 4,5,8,11 -> full OIDs base+oid
    base = ".1.3.6.1.4.1.4547.2.3.2"
    oid_throughput = base + ".11"
    throughput_status = _snmp_get_str(ctx, community, host, oid_throughput)
    if throughput_status == None:
        return {"changed": False, "msg": "could not retrieve throughput status",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    # Map status string to state per the original check logic.
    state = "OK"
    summary = "Normal"
    if throughput_status == "1":
        state = "OK"
        summary = "Normal"
    elif throughput_status == "2":
        state = "WARN"
        summary = "Warning"
    else:
        state = "UNKNOWN"
        summary = "Unknown throughput status: %s" % throughput_status

    return {
        "changed": False,
        "msg": summary,
        "data": {
            "state": state,
            "metrics": {"throughput_status": throughput_status},
            "details": "throughput_status=%s" % throughput_status,
        },
    }