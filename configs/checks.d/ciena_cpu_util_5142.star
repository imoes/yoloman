def _get_oid_suffix(oid_full, oid_base):
    """Extract the index suffix from a full OID by removing the base OID prefix."""
    base = oid_base.replace(".", "")
    full = oid_full.replace(".", "")
    if full.startswith(base):
        suffix = full[len(base):]
        if suffix.startswith("0") and len(suffix) > 1:
            suffix = suffix[1:]
        return suffix
    return ""

def _determine_state(value, warn, crit):
    """Determine OK/WARN/CRIT state for a utilization value (higher is worse)."""
    v = float(value)
    w = float(warn)
    c = float(crit)
    if v >= c:
        return "CRIT"
    if v >= w:
        return "WARN"
    return "OK"

def _check_cpu_util_5142(ctx, params):
    """Check CPU utilization for Ciena 5142 - reads scalar OID."""
    warn = params.get("util", [80.0, 90.0])
    if type(warn) == "list":
        warn_val = warn[0]
        crit_val = warn[1]
    else:
        warn_val = 80.0
        crit_val = 90.0

    base_oid = ".1.3.6.1.4.1.6141.2.60.12.1.11"
    col_oid = base_oid + ".9"

    res = ctx.run([
        "snmpget", "-v2c", "-c", params.get("community", "public"),
        "-Oqv", params.get("host", "localhost"), col_oid
    ], mutates=False)

    if res.rc != 0:
        if res.rc == 127:
            return {"changed": False, "msg": "snmpget not available",
                    "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
        return {"changed": False, "msg": "SNMP query failed for CPU utilization",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    val_str = res.stdout.strip()
    if not val_str or not val_str.isdigit():
        return {"changed": False, "msg": "No valid CPU utilization value retrieved",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    util = int(val_str)
    state = _determine_state(util, warn_val, crit_val)
    return {"changed": False, "msg": "CPU utilization: %d%%" % util,
            "data": {"state": state, "metrics": {"util": util},
                     "details": "Utilization over last 60 seconds: %d%% (warn: %s, crit: %s)" % (util, str(warn_val), str(crit_val))}}

def _check_cpu_util_5171(ctx, params):
    """Check CPU utilization for Ciena 5171 - reads table OID with OIDEnd."""
    warn = params.get("util", [80.0, 90.0])
    if type(warn) == "list":
        warn_val = warn[0]
        crit_val = warn[1]
    else:
        warn_val = 80.0
        crit_val = 90.0

    base_oid = ".1.3.6.1.4.1.1271.2.1.5.1.2.1.4.5.1"
    col_oid = base_oid + ".4"

    # Walk the column to get all rows
    res = ctx.run([
        "snmpwalk", "-v2c", "-c", params.get("community", "public"),
        "-Oqn", params.get("host", "localhost"), col_oid
    ], mutates=False)

    if res.rc != 0:
        if res.rc == 127:
            return {"changed": False, "msg": "snmpwalk not available",
                    "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
        return {"changed": False, "msg": "SNMP walk failed for CPU utilization",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    lines = res.stdout.splitlines()
    util = None
    cores = []
    for line in lines:
        idx = line.find(" ")
        if idx < 0:
            continue
        oid_full = line[:idx]
        val_str = line[idx+1:].strip()
        suffix = _get_oid_suffix(oid_full, col_oid)
        if suffix == "1":
            if val_str.isdigit():
                util = int(val_str)
        else:
            index_minus_2 = str(int(suffix) - 2)
            if val_str.isdigit():
                cores.append((index_minus_2, int(val_str)))

    if util == None:
        return {"changed": False, "msg": "No overall CPU utilization value found in SNMP table",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    state = _determine_state(util, warn_val, crit_val)
    metrics = {"util": util}
    for idx, core_val in cores:
        metrics["util_cpu" + idx] = core_val

    detail_msg = "Overall: %d%% (warn: %s, crit: %s)" % (util, str(warn_val), str(crit_val))
    if cores:
        core_strs = ["CPU%s: %d%%" % (c, v) for c, v in cores]
        detail_msg += ", " + ", ".join(core_strs)

    return {"changed": False, "msg": "CPU utilization: %d%%" % util,
            "data": {"state": state, "metrics": metrics, "details": detail_msg}}

def main(ctx, params):
    if params.get("_discover"):
        host = params.get("host", "localhost")
        community = params.get("community", "public")

        # Check if snmp tools are available
        probe = ctx.run(["snmpget", "--version"], mutates=False)
        if probe.rc == 127:
            return {"changed": False, "msg": "snmp tools not available",
                    "data": {"discovery": []}}

        # Get sysObjectID to determine if this is a Ciena device
        sysOid = ".1.3.6.1.2.1.1.2.0"
        sysDesc = ".1.3.6.1.2.1.1.1.0"

        oid_res = ctx.run([
            "snmpget", "-v2c", "-c", community, "-Oqv", host, sysOid
        ], mutates=False)

        if oid_res.rc != 0:
            return {"changed": False, "msg": "Could not reach SNMP agent",
                    "data": {"discovery": []}}

        sys_obj_id = oid_res.stdout.strip()
        if not sys_obj_id:
            return {"changed": False, "msg": "No sysObjectID",
                    "data": {"discovery": []}}

        # Check if this is a Ciena device
        is_ciena = False
        if sys_obj_id.startswith(".1.3.6.1.4.1.1271.1.2.11") or sys_obj_id.startswith(".1.3.6.1.4.1.6141.1.96"):
            is_ciena = True

        if not is_ciena:
            return {"changed": False, "msg": "Not a Ciena device",
                    "data": {"discovery": []}}

        # Check if this is a 5142 or 5171
        desc_res = ctx.run([
            "snmpget", "-v2c", "-c", community, "-Oqv", host, sysDesc
        ], mutates=False)

        if desc_res.rc != 0:
            return {"changed": False, "msg": "Could not read sysDescr",
                    "data": {"discovery": []}}

        sys_desc = desc_res.stdout.strip()

        warn_default = params.get("warn", 80.0)
        crit_default = params.get("crit", 90.0)
        util_param = [warn_default, crit_default]

        if "5142" in sys_desc:
            return {"changed": False, "msg": "discovered 1 item",
                    "data": {"discovery": [
                        {"item": "", "params": {"util": util_param}, "metrics": ["util"]}
                    ], "host_labels": {"cmk/os_family": "ciena"}}}
        elif "5171" in sys_desc:
            return {"changed": False, "msg": "discovered 1 item",
                    "data": {"discovery": [
                        {"item": "", "params": {"util": util_param}, "metrics": ["util"]}
                    ], "host_labels": {"cmk/os_family": "ciena"}}}

        return {"changed": False, "msg": "Not a 5142 or 5171 Ciena device",
                "data": {"discovery": []}}

    # Check mode - determine which variant based on detection
    host = params.get("host", "localhost")
    community = params.get("community", "public")

    # Detect which device type we're monitoring
    sysOid = ".1.3.6.1.2.1.1.2.0"
    sysDesc = ".1.3.6.1.2.1.1.1.0"

    probe = ctx.run(["snmpget", "--version"], mutates=False)
    if probe.rc == 127:
        return {"changed": False, "msg": "snmp tools not available",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    oid_res = ctx.run(["snmpget", "-v2c", "-c", community, "-Oqv", host, sysOid], mutates=False)
    if oid_res.rc != 0:
        return {"changed": False, "msg": "Could not reach SNMP agent",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    sys_obj_id = oid_res.stdout.strip()
    is_ciena = False
    if sys_obj_id.startswith(".1.3.6.1.4.1.1271.1.2.11") or sys_obj_id.startswith(".1.3.6.1.4.1.6141.1.96"):
        is_ciena = True

    if not is_ciena:
        return {"changed": False, "msg": "Not a Ciena device",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    desc_res = ctx.run(["snmpget", "-v2c", "-c", community, "-Oqv", host, sysDesc], mutates=False)
    if desc_res.rc != 0:
        return {"changed": False, "msg": "Could not read sysDescr",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    sys_desc = desc_res.stdout.strip()

    if "5142" in sys_desc:
        return _check_cpu_util_5142(ctx, params)
    elif "5171" in sys_desc:
        return _check_cpu_util_5171(ctx, params)
    else:
        return {"changed": False, "msg": "Not a 5142 or 5171 Ciena device",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}