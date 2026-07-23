# SNMP OIDs for viprinet_firmware check
_VIPRINET_FIRMWARE_OID = ".1.3.6.1.4.1.35424.1.1"
_OID_FIRMWARE_VERSION = "4"
_OID_FIRMWARE_STATUS = "7"

# Firmware status mapping (from agent-based check)
_FW_STATUS_MAP = {
    "0": "No new firmware available",
    "1": "Update Available",
    "2": "Checking for Updates",
    "3": "Downloading Update",
    "4": "Installing Update",
}


def main(ctx, params):
    # Discovery mode: check if this host has viprinet firmware data
    if params.get("_discover"):
        # Probe firmware version and status via SNMP
        res = ctx.run([
            "/usr/bin/snmpget",
            "-On",
            "-v2c",
            "-c", "public",
            "localhost",
            _VIPRINET_FIRMWARE_OID + "." + _OID_FIRMWARE_VERSION,
            _VIPRINET_FIRMWARE_OID + "." + _OID_FIRMWARE_STATUS
        ], mutates=False)
        
        if res.rc != 0:
            # SNMP probe failed - no viprinet device detected
            return {"changed": False, "msg": "discovered 0 services",
                    "data": {"discovery": []}}
        
        # Simple check: we expect two lines with values
        lines = res.stdout.splitlines()
        if len(lines) < 2:
            return {"changed": False, "msg": "discovered 0 services",
                    "data": {"discovery": []}}
        
        # Check if the system is viprinet (via sysObjectID)
        sysres = ctx.run([
            "/usr/bin/snmpget",
            "-On",
            "-v2c",
            "-c", "public",
            "localhost",
            ".1.3.6.1.2.1.1.2.0"
        ], mutates=False)
        
        if sysres.rc != 0 or ".1.3.6.1.4.1.35424" not in sysres.stdout:
            return {"changed": False, "msg": "discovered 0 services",
                    "data": {"discovery": []}}
        
        # Viprinet device detected - return single service
        return {"changed": False, "msg": "discovered 1 service",
                "data": {"discovery": [
                    {"item": "", "params": {}, "metrics": []}
                ]}}
    
    # Check mode - get firmware info
    res = ctx.run([
        "/usr/bin/snmpget",
        "-On",
        "-v2c",
        "-c", "public",
        "localhost",
        _VIPRINET_FIRMWARE_OID + "." + _OID_FIRMWARE_VERSION,
        _VIPRINET_FIRMWARE_OID + "." + _OID_FIRMWARE_STATUS
    ], mutates=False)
    
    if res.rc != 0:
        return {"changed": False, "msg": "SNMP probe failed",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": "No SNMP data available"}}
    
    lines = res.stdout.splitlines()
    if len(lines) < 2:
        return {"changed": False, "msg": "Incomplete SNMP data",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": "Missing SNMP fields"}}
    
    # Parse version and status
    version = ""
    status_raw = ""
    
    for line in lines:
        parts = line.strip().split(None, 1)
        if len(parts) != 2:
            continue
        oid_part, value_part = parts
        value = value_part.strip()
        if oid_part.endswith(_OID_FIRMWARE_VERSION):
            version = value
        elif oid_part.endswith(_OID_FIRMWARE_STATUS):
            status_raw = value
    
    if not version and not status_raw:
        return {"changed": False, "msg": "No firmware data available",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": "No firmware data available"}}
    
    # Map status
    fw_status = _FW_STATUS_MAP.get(status_raw, None)
    
    if fw_status == None:
        return {"changed": False, "msg": "%s, no firmware status available" % (version if version else "Unknown version"),
                "data": {"state": "UNKNOWN", "metrics": {}, "details": "Firmware status not in expected values"}}
    
    return {
        "changed": False,
        "msg": "%s, %s" % (version if version else "Unknown version", fw_status),
        "data": {
            "state": "OK",
            "metrics": {},
            "details": ""
        }
    }
