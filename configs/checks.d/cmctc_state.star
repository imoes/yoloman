# cmctc_state.star — TC unit state (Rittal CMCTC) via SNMP
# READ-ONLY: discovery + check, no mutations.
#
# Data source (Checkmk SNMP section cmctc_state):
#   base OID .1.3.6.1.4.1.2606.4.2  (table-less scalar pair)
#   OID .1  -> status code (1=failed, 2=ok)
#   OID .2  -> units connected
# Detection: sysObjectID .1.3.6.1.2.1.1.2.0 contains ".1.3.6.1.4.1.2606.4".

def _get_oid(ctx, host, community, oid):
    res = ctx.run(["snmpget", "-v2c", "-c", community, "-Oqv", host, oid], mutates=False)
    if res.rc == 0 and len(res.stdout) > 0:
        return res.stdout.strip()
    return None

def _is_cmctc(ctx, host, community):
    oid = ".1.3.6.1.2.1.1.2.0"
    res = ctx.run(["snmpget", "-v2c", "-c", community, "-Onqv", host, oid], mutates=False)
    if res.rc == 0:
        val = res.stdout.strip()
        if val != "" and val.find(".1.3.6.1.4.1.2606.4") != -1:
            return True
    return False

def main(ctx, params):
    host = params.get("host", "localhost")
    community = params.get("community", "public")

    if params.get("_discover"):
        if not _is_cmctc(ctx, host, community):
            return {"changed": False, "msg": "discovered 0 items",
                    "data": {"discovery": []}}
        return {"changed": False, "msg": "discovered 1 item",
                "data": {"discovery": [
                    {"item": "", "params": {}, "metrics": []}
                ]}}

    item = params.get("item", "")
    status_code = _get_oid(ctx, host, community, ".1.3.6.1.4.1.2606.4.2.1")
    units_raw = _get_oid(ctx, host, community, ".1.3.6.1.4.1.2606.4.2.2")

    if status_code == None:
        return {"changed": False,
                "msg": "no TC unit data obtainable via SNMP",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    status_map = {"1": "failed", "2": "ok"}
    status = status_map.get(status_code, "unknown[%s]" % status_code)
    state = "OK" if status == "ok" else "CRIT"

    units_val = None
    if units_raw != None and units_raw.isdigit():
        units_val = int(units_raw)

    details = "Status: %s, Units connected: %s" % (
        status, status_code if units_val == None else units_val)
    return {"changed": False, "msg": details,
            "data": {"state": state, "metrics": {}, "details": details}}