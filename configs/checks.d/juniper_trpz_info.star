# ===== module-level constants =====

# SNMP OIDs for Juniper TRPZ info section
JUNIPER_TRPZ_BASE = ".1.3.6.1.4.1.14525.4.2.1"
JUNIPER_TRPZ_SERIAL_OID = "1"
JUNIPER_TRPZ_VERSION_OID = "4"

# Detection: sysObjectID starts with .1.3.6.1.4.1.14525.3 (Juniper TRPZ)
JUNIPER_TRPZ_SYSOBJECTID_PREFIX = ".1.3.6.1.4.1.14525.3"


def main(ctx, params):
    if params.get("_discover"):
        # Discover: Juniper TRPZ devices expose exactly one "Info" service
        res = ctx.run(["snmpget", "-Ovq", "-On", JUNIPER_TRPZ_BASE + "." + JUNIPER_TRPZ_SERIAL_OID], mutates=False)
        # Detection: check sysObjectID prefix via snmpwalk on .1.3.6.1.2.1.1.2.0
        sysobj_res = ctx.run(["snmpget", "-Ovq", "-On", ".1.3.6.1.2.1.1.2.0"], mutates=False)
        if sysobj_res.rc != 0 or not sysobj_res.stdout.startswith(JUNIPER_TRPZ_SYSOBJECTID_PREFIX):
            return {"changed": False, "msg": "discovered 0 items (not Juniper TRPZ)",
                    "data": {"discovery": []}}
        if res.rc != 0 or not res.stdout.strip():
            return {"changed": False, "msg": "discovered 0 items (no serial found)",
                    "data": {"discovery": []}}
        return {"changed": False, "msg": "discovered 1 items",
                "data": {"discovery": [{"item": "", "params": {}, "metrics": []}]}}
    
    # Check mode: fetch serial and version, return OK with message
    serial_res = ctx.run(["snmpget", "-Ovq", "-On", JUNIPER_TRPZ_BASE + "." + JUNIPER_TRPZ_SERIAL_OID], mutates=False)
    version_res = ctx.run(["snmpget", "-Ovq", "-On", JUNIPER_TRPZ_BASE + "." + JUNIPER_TRPZ_VERSION_OID], mutates=False)
    # Detection: confirm it's a Juniper TRPZ device
    sysobj_res = ctx.run(["snmpget", "-Ovq", "-On", ".1.3.6.1.2.1.1.2.0"], mutates=False)
    if sysobj_res.rc != 0 or not sysobj_res.stdout.startswith(JUNIPER_TRPZ_SYSOBJECTID_PREFIX):
        return {"changed": False, "msg": "device is not Juniper TRPZ",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    if serial_res.rc != 0 or not serial_res.stdout.strip():
        return {"changed": False, "msg": "failed to retrieve serial number",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    serial = serial_res.stdout.strip()
    version = version_res.stdout.strip() if version_res.rc == 0 and version_res.stdout.strip() else "unknown"
    message = "S/N: %s, FW Version: %s" % (serial, version)
    return {"changed": False, "msg": message,
            "data": {"state": "OK", "metrics": {}, "details": ""}}
