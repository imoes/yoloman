# F5 BIG-IP vCMP Guest Failover Status / Cluster Status (SNMP, read-only)
# Targets the v11.2+ path: sysCmFailoverStatusId (.1.3.6.1.4.1.3375.2.1.14.3.1.0)
# and sysVcmpNumber (.1.3.6.1.4.1.3375.2.1.13.1.1.0) for vCMP detection.

SYS_OBJECT_ID_OID = ".1.3.6.1.2.1.1.2.0"
BIGIP_TRAFFIC_MGMT_OID = ".1.3.6.1.4.1.3375.2"
SYS_PRODUCT_NAME_OID = ".1.3.6.1.4.1.3375.2.1.4.1.0"
SYS_PRODUCT_VERSION_OID = ".1.3.6.1.4.1.3375.2.1.4.2.0"
SYS_VCMP_NUMBER_OID = ".1.3.6.1.4.1.3375.2.1.13.1.1.0"
SYS_CM_FAILOVER_STATUS_OID = ".1.3.6.1.4.1.3375.2.1.14.3.1.0"

def main(ctx, params):
    host = params.get("host", "localhost")
    community = params.get("community", "public")
    check_type = params.get("type", "active_standby")
    v11_2_states_param = params.get("v11_2_states", {})

    if params.get("_discover"):
        return _discover(ctx, host, community)

    item = params.get("item", "")
    return _check(ctx, host, community, item, check_type, v11_2_states_param)


def _discover(ctx, host, community):
    if not _is_bigip_v11_2_plus(ctx, host, community):
        return {"changed": False, "msg": "not an F5 BIG-IP v11.2+ system",
                "data": {"discovery": []}}

    state = _read_vcmp_state(ctx, host, community)
    if state == None:
        return {"changed": False, "msg": "discovered 1 item",
                "data": {"discovery": [
                    {"item": "", "params": {"type": "active_standby"},
                     "metrics": ["failover_state"]}]}}

    return {"changed": False, "msg": "discovered 1 item",
            "data": {"discovery": [
                {"item": "", "params": {"type": "active_standby"},
                 "metrics": ["failover_state"]}]}}


def _check(ctx, host, community, item, check_type, v11_2_states_param):
    if not _is_bigip_v11_2_plus(ctx, host, community):
        return {"changed": False, "msg": "F5 BIG-IP v11.2+ not detected",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    state = _read_vcmp_state(ctx, host, community)
    if state == None:
        return {"changed": False, "msg": "no failover status readable",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    # v11.2+ state mapping: 0->3(CRIT),1->2(WARN),2->2(WARN),3->0(OK),4->0(OK)
    mapping = {0: 3, 1: 2, 2: 2, 3: 0, 4: 0}
    for k, v in v11_2_states_param.items():
        ki = _to_int(k)
        vi = _to_int(v)
        if ki != None and vi != None:
            mapping[ki] = vi

    mapped = mapping.get(state, 3)
    if mapped == 0:
        verdict = "OK"
    elif mapped == 1:
        verdict = "WARN"
    elif mapped == 2:
        verdict = "WARN"
    else:
        verdict = "CRIT"

    names = ("standby", "active 1", "active 2", "active")
    label = "unknown"
    if (state >= 0) and (state < len(names)):
        label = names[state]
    summary = "Node is %s" % label

    return {"changed": False,
            "msg": summary,
            "data": {"state": verdict, "metrics": {"failover_state": state},
                     "details": summary}}


def _to_int(x):
    if x == None:
        return None
    s = str(x)
    if not _isdigit_str(s):
        return None
    return int(s)


# ---- SNMP helpers ----

def _is_bigip_v11_2_plus(ctx, host, community):
    sysid = _snmp_get(ctx, host, community, SYS_OBJECT_ID_OID)
    if sysid == None:
        return False
    if not sysid.startswith(BIGIP_TRAFFIC_MGMT_OID):
        return False
    pname = _snmp_get(ctx, host, community, SYS_PRODUCT_NAME_OID)
    if pname == None:
        return False
    if "big-ip" not in pname:
        return False
    version = _snmp_get(ctx, host, community, SYS_PRODUCT_VERSION_OID)
    if version == None:
        return False
    if version == "":
        return False
    return _version_ge_v11_2(version)


def _read_vcmp_state(ctx, host, community):
    vcmp_count = _snmp_get_int(ctx, host, community, SYS_VCMP_NUMBER_OID)
    failover = _snmp_get_int(ctx, host, community, SYS_CM_FAILOVER_STATUS_OID)
    if vcmp_count == None or failover == None:
        return None
    if vcmp_count == 0:
        return failover
    return None


def _snmp_get(ctx, host, community, oid):
    res = ctx.run(["snmpget", "-v2c", "-c", community, "-Oqv", host, oid],
                  mutates=False)
    if res.rc != 0:
        return None
    return res.stdout.strip()


def _snmp_get_int(ctx, host, community, oid):
    val = _snmp_get(ctx, host, community, oid)
    if val == None or val == "":
        return None
    if not _isdigit_str(val):
        return None
    return int(val)


# ---- version matching (no regex engine) ----

# Matches: ^(([2-9]\d|1[2-9])\.\d{1,}|11\.([2-9]|\d{2,}))(\.\d+)*$
def _version_ge_v11_2(version):
    v = version.strip()
    if v == "":
        return False
    parts = v.split(".")
    if len(parts) < 2:
        return False
    if not _isdigit_str(parts[0]) or not _isdigit_str(parts[1]):
        return False
    major = int(parts[0])
    minor = int(parts[1])
    # 11.2 .. 11.9
    if major == 1 and 2 <= minor and minor <= 9:
        return True
    # 11.10+
    if major == 1 and minor >= 10:
        return True
    # 20..99 with at least one digit after the dot (parts[1] exists and is digits)
    if major >= 20:
        return True
    return False


def _isdigit_str(s):
    if s == "":
        return False
    for ch in s:
        if ch < "0" or ch > "9":
            return False
    return True