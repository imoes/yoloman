# discovery + check for cmk.cmctc_config (read-only Starlark module)

# SNMP OIDs for the cmctc_config section
_BASE_OID = ".1.3.6.1.4.1.2606.4.3.1"
_OID_TEMP_UNIT = "1"
_OID_BEEPER = "2"
_OID_ACKNOWLEDGE = "3"
_OID_RELAY_LOGIC = "4"
_OID_WEB_ACCESS = "5"

# Mapping dictionaries (top-level to avoid undefined names)
TEMP_UNIT_MAP = {"1": "celsius", "2": "fahrenheit"}
BEEPER_MAP = {"1": "on", "2": "off"}
ACKNOWLEDGE_MAP = {"1": "disabled", "2": "enabled"}
RELAY_LOGIC_MAP = {"1": "pick up", "2": "release", "3": "off"}
WEB_ACCESS_MAP = {"1": "view only", "2": "full", "3": "disables"}

# Detection: .1.3.6.1.2.1.1.2.0 must contain .1.3.6.1.4.1.2606.4
_DETECT_OID = ".1.3.6.1.2.1.1.2.0"
_DETECT_PREFIX = ".1.3.6.1.4.1.2606.4"


def main(ctx, params):
    if params.get("_discover"):
        # Detect if this host has cmctc devices by checking sysObjectID
        res = ctx.run(["snmpget", "-On", "-v2c", "-c", "public", "localhost", _DETECT_OID], mutates=False)
        if res.rc != 0:
            # Non-critical: detection failure means no service
            return {"changed": False, "msg": "discovery skipped (no match)", "data": {"discovery": []}}
        
        sys_object_id = res.stdout.strip()
        if sys_object_id.find(_DETECT_PREFIX) == -1:
            return {"changed": False, "msg": "discovery skipped (no match)", "data": {"discovery": []}}
        
        # One service for this check (single-service pattern)
        return {"changed": False, "msg": "discovered 1 item", "data": {"discovery": [{"item": "", "params": {}, "metrics": []}]}}
    
    # Check mode: fetch the five config OIDs
    base = _BASE_OID
    oids = [_OID_TEMP_UNIT, _OID_BEEPER, _OID_ACKNOWLEDGE, _OID_RELAY_LOGIC, _OID_WEB_ACCESS]
    oid_str = ",".join([base + "." + o for o in oids])
    
    res = ctx.run(["snmpwalk", "-On", "-v2c", "-c", "public", "localhost", base], mutates=False)
    if res.rc != 0:
        # If the agent cannot reach SNMP, report UNKNOWN
        return {"changed": False, "msg": "SNMP walk failed", "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    
    # Parse lines into a dict oid -> value
    oid_values = {}
    for line in res.stdout.splitlines():
        parts = line.strip().split(" = ")
        if len(parts) != 2:
            continue
        oid_part = parts[0].strip()
        val_part = parts[1].strip()
        # Extract numeric suffix (e.g., .1 -> 1)
        suffix = oid_part.rsplit(".", 1)[-1]
        # Handle different value formats (e.g., INTEGER: 1, STRING: "value")
        if ":" in val_part:
            value = val_part.split(":", 1)[-1].strip()
        else:
            value = val_part
        # Clean up quotes if present
        if value.startswith('"') and value.endswith('"'):
            value = value[1:-1]
        oid_values[suffix] = value
    
    # Gather required values
    temp_id = oid_values.get(_OID_TEMP_UNIT)
    beeper_id = oid_values.get(_OID_BEEPER)
    ack_id = oid_values.get(_OID_ACKNOWLEDGE)
    relay_logic_id = oid_values.get(_OID_RELAY_LOGIC)
    web_access_id = oid_values.get(_OID_WEB_ACCESS)
    
    # Map values to human-readable strings
    temperature_unit = TEMP_UNIT_MAP.get(temp_id, "unknown")
    beeper = BEEPER_MAP.get(beeper_id, "unknown")
    acknowledging = ACKNOWLEDGE_MAP.get(ack_id, "unknown")
    relay_logic = RELAY_LOGIC_MAP.get(relay_logic_id, "unknown")
    web_access = WEB_ACCESS_MAP.get(web_access_id, "unknown")
    
    # Build info text exactly as the original check
    infotext = "Web access: %s, Beeper: %s, Acknowledging: %s, Alarm relay logic in case of alarm: %s, Temperature unit: %s" % (web_access, beeper, acknowledging, relay_logic, temperature_unit)
    
    # Always OK state; no thresholds exist
    return {"changed": False, "msg": infotext, "data": {"state": "OK", "metrics": {}, "details": ""}}
